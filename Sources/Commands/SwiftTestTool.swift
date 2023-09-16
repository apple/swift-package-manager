//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2015-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import Basics
import CoreCommands
import Dispatch
import class Foundation.JSONDecoder
import class Foundation.NSLock
import class Foundation.ProcessInfo
import PackageGraph
import PackageModel
import SPMBuildCore
import func TSCLibc.exit
import Workspace

import struct TSCBasic.ByteString
import enum TSCBasic.JSON
import class TSCBasic.Process
import enum TSCBasic.ProcessEnv
import var TSCBasic.stdoutStream
import class TSCBasic.SynchronizedQueue
import class TSCBasic.Thread

import class TSCUtility.NinjaProgressAnimation
import class TSCUtility.PercentProgressAnimation
import protocol TSCUtility.ProgressAnimationProtocol

#if os(Windows)
import func CRT.fflush
import let CRT.stdout
#elseif canImport(Darwin)
import func Darwin.fflush
import let Darwin.stdout
#elseif canImport(Glibc)
import func Glibc.fflush
import let Glibc.stdout
#endif

private enum TestError: Swift.Error {
    case invalidListTestJSONData(context: String, underlyingError: Error? = nil)
    case testsNotFound
    case testProductNotFound(productName: String)
    case productIsNotTest(productName: String)
    case multipleTestProducts([String])
    case xctestNotAvailable
}

extension TestError: CustomStringConvertible {
    var description: String {
        switch self {
        case .testsNotFound:
            return "no tests found; create a target in the 'Tests' directory"
        case .testProductNotFound(let productName):
            return "there is no test product named '\(productName)'"
        case .productIsNotTest(let productName):
            return "the product '\(productName)' is not a test"
        case .invalidListTestJSONData(let context, let underlyingError):
            let underlying = underlyingError != nil ? ", underlying error: \(underlyingError!)" : ""
            return "invalid list test JSON structure, produced by \(context)\(underlying)"
        case .multipleTestProducts(let products):
            return "found multiple test products: \(products.joined(separator: ", ")); use --test-product to select one"
        case .xctestNotAvailable:
            return "XCTest not available"
        }
    }
}

struct SharedOptions: ParsableArguments {
    @Flag(name: .customLong("skip-build"),
          help: "Skip building the test target")
    var shouldSkipBuilding: Bool = false

    /// The test product to use. This is useful when there are multiple test products
    /// to choose from (usually in multiroot packages).
    @Option(help: .hidden)
    var testProduct: String?
}

struct TestToolOptions: ParsableArguments {
    /// If tests should run in parallel mode.
    @Flag(name: .customLong("parallel"),
          help: "Run the tests in parallel.")
    var shouldRunInParallel: Bool = false

    /// Number of tests to execute in parallel
    @Option(name: .customLong("num-workers"),
            help: "Number of tests to execute in parallel.")
    var numberOfWorkers: Int?

    /// List the tests and exit.
    @Flag(name: [.customLong("list-tests"), .customShort("l")],
          help: "Lists test methods in specifier format")
    var _deprecated_shouldListTests: Bool = false

    /// If the path of the exported code coverage JSON should be printed.
    @Flag(name: [.customLong("show-codecov-path"), .customLong("show-code-coverage-path"), .customLong("show-coverage-path")],
          help: "Print the path of the exported code coverage JSON file")
    var shouldPrintCodeCovPath: Bool = false

    var testCaseSpecifier: TestCaseSpecifier {
        if !filter.isEmpty {
            return .regex(filter)
        }

        return _testCaseSpecifier.map { .specific($0) } ?? .none
    }

    @Option(name: [.customShort("s"), .customLong("specifier")])
    var _testCaseSpecifier: String?

    @Option(help: """
        Run test cases matching regular expression, Format: <test-target>.<test-case> \
        or <test-target>.<test-case>/<test>
        """)
    var filter: [String] = []

    @Option(name: .customLong("skip"),
            help: "Skip test cases matching regular expression, Example: --skip PerformanceTests")
    var _testCaseSkip: [String] = []

    /// Path where the xUnit xml file should be generated.
    @Option(name: .customLong("xunit-output"),
            help: "Path where the xUnit xml file should be generated.")
    var xUnitOutput: AbsolutePath?

    /// Generate LinuxMain entries and exit.
    @Flag(name: .customLong("testable-imports"), inversion: .prefixedEnableDisable, help: "Enable or disable testable imports. Enabled by default.")
    var enableTestableImports: Bool = true

    /// Whether to enable code coverage.
    @Flag(name: .customLong("code-coverage"),
          inversion: .prefixedEnableDisable,
          help: "Enable code coverage")
    var enableCodeCoverage: Bool = false

    /// Configure test output.
    @Option(help: ArgumentHelp("", visibility: .hidden))
    public var testOutput: TestOutput = .default

    var enableExperimentalTestOutput: Bool {
        return testOutput == .experimentalSummary
    }
}

/// Tests filtering specifier, which is used to filter tests to run.
public enum TestCaseSpecifier {
    /// No filtering
    case none
    
    /// Specify test with fully quantified name
    case specific(String)
    
    /// RegEx patterns for tests to run
    case regex([String])
    
    /// RegEx patterns for tests to skip
    case skip([String])
}

/// Different styles of test output.
public enum TestOutput: String, ExpressibleByArgument {
    /// Whatever `xctest` emits to the console.
    case `default`

    /// Capture XCTest events and provide a summary.
    case experimentalSummary

    /// Let the test process emit parseable output to the console.
    case experimentalParseable
}

/// swift-test tool namespace
public struct SwiftTestTool: SwiftCommand {
    public static var configuration = CommandConfiguration(
        commandName: "test",
        _superCommandName: "swift",
        abstract: "Build and run tests",
        discussion: "SEE ALSO: swift build, swift run, swift package",
        version: SwiftVersion.current.completeDisplayString,
        subcommands: [
            List.self, Last.self
        ],
        helpNames: [.short, .long, .customLong("help", withSingleDash: true)])

    @OptionGroup()
    public var globalOptions: GlobalOptions

    @OptionGroup()
    var sharedOptions: SharedOptions

    @OptionGroup()
    var options: TestToolOptions

    public func run(_ swiftTool: SwiftTool) throws {
        do {
            // Validate commands arguments
            try self.validateArguments(observabilityScope: swiftTool.observabilityScope)

            // validate XCTest available on darwin based systems
            let toolchain = try swiftTool.getTargetToolchain()
            if toolchain.targetTriple.isDarwin() && toolchain.xctestPath == nil {
                throw TestError.xctestNotAvailable
            }
        } catch {
            swiftTool.observabilityScope.emit(error)
            throw ExitCode.failure
        }

        let buildParameters = try swiftTool.buildParametersForTest(options: self.options, sharedOptions: self.sharedOptions)

        // Remove test output from prior runs and validate priors.
        if self.options.enableExperimentalTestOutput {
            if !buildParameters.targetTriple.isDarwin() {
                swiftTool.observabilityScope.emit(error: "The experimental test output feature is only available on Darwin.")
                throw ExitCode.failure
            }
            _ = try? localFileSystem.removeFileTree(buildParameters.testOutputPath)
        }

        if self.options.shouldPrintCodeCovPath {
            let command = try PrintCodeCovPath.parse()
            try command.run(swiftTool)
        } else if self.options._deprecated_shouldListTests {
            // backward compatibility 6/2022 for deprecation of flag into a subcommand
            let command = try List.parse()
            try command.run(swiftTool)
        } else if !self.options.shouldRunInParallel {
            let toolchain = try swiftTool.getTargetToolchain()
            let testProducts = try buildTestsIfNeeded(swiftTool: swiftTool)

            // Clean out the code coverage directory that may contain stale
            // profraw files from a previous run of the code coverage tool.
            if self.options.enableCodeCoverage {
                try swiftTool.fileSystem.removeFileTree(buildParameters.codeCovPath)
            }

            let xctestArg: String?

            switch options.testCaseSpecifier {
            case .none:
                if case .skip = options.skippedTests(fileSystem: swiftTool.fileSystem) {
                    fallthrough
                } else {
                    xctestArg = nil
                }

            case .regex, .specific, .skip:
                // If old specifier `-s` option was used, emit deprecation notice.
                if case .specific = options.testCaseSpecifier {
                    swiftTool.observabilityScope.emit(warning: "'--specifier' option is deprecated; use '--filter' instead")
                }

                // Find the tests we need to run.
                let testSuites = try TestingSupport.getTestSuites(
                    in: testProducts,
                    swiftTool: swiftTool,
                    enableCodeCoverage: options.enableCodeCoverage,
                    shouldSkipBuilding: sharedOptions.shouldSkipBuilding,
                    experimentalTestOutput: options.enableExperimentalTestOutput,
                    sanitizers: globalOptions.build.sanitizers
                )
                let tests = try testSuites
                    .filteredTests(specifier: options.testCaseSpecifier)
                    .skippedTests(specifier: options.skippedTests(fileSystem: swiftTool.fileSystem))

                // If there were no matches, emit a warning.
                if tests.isEmpty {
                    swiftTool.observabilityScope.emit(.noMatchingTests)
                    xctestArg = "''"
                } else {
                    xctestArg = tests.map { $0.specifier }.joined(separator: ",")
                }
            }

            let testEnv = try TestingSupport.constructTestEnvironment(
                toolchain: toolchain,
                buildParameters: buildParameters,
                sanitizers: globalOptions.build.sanitizers
            )

            let runner = TestRunner(
                bundlePaths: testProducts.map { $0.bundlePath },
                xctestArg: xctestArg,
                cancellator: swiftTool.cancellator,
                toolchain: toolchain,
                testEnv: testEnv,
                observabilityScope: swiftTool.observabilityScope
            )

            // Finally, run the tests.
            let ranSuccessfully = runner.test(outputHandler: {
                // command's result output goes on stdout
                // ie "swift test" should output to stdout
                print($0)
                fflush(stdout)
            })
            if !ranSuccessfully {
                swiftTool.executionStatus = .failure
            }

            if self.options.enableCodeCoverage, ranSuccessfully {
                try processCodeCoverage(testProducts, swiftTool: swiftTool)
            }

            if self.options.enableExperimentalTestOutput, !ranSuccessfully {
                try Self.handleTestOutput(buildParameters: buildParameters, packagePath: testProducts[0].packagePath)
            }

        } else {
            let toolchain = try swiftTool.getTargetToolchain()
            let testProducts = try buildTestsIfNeeded(swiftTool: swiftTool)
            let testSuites = try TestingSupport.getTestSuites(
                in: testProducts,
                swiftTool: swiftTool,
                enableCodeCoverage: options.enableCodeCoverage,
                shouldSkipBuilding: sharedOptions.shouldSkipBuilding,
                experimentalTestOutput: options.enableExperimentalTestOutput,
                sanitizers: globalOptions.build.sanitizers
            )
            let tests = try testSuites
                .filteredTests(specifier: options.testCaseSpecifier)
                .skippedTests(specifier: options.skippedTests(fileSystem: swiftTool.fileSystem))

            // If there were no matches, emit a warning and exit.
            if tests.isEmpty {
                swiftTool.observabilityScope.emit(.noMatchingTests)
                return
            }

            // Clean out the code coverage directory that may contain stale
            // profraw files from a previous run of the code coverage tool.
            if self.options.enableCodeCoverage {
                try swiftTool.fileSystem.removeFileTree(buildParameters.codeCovPath)
            }

            // Run the tests using the parallel runner.
            let runner = ParallelTestRunner(
                bundlePaths: testProducts.map { $0.bundlePath },
                cancellator: swiftTool.cancellator,
                toolchain: toolchain,
                numJobs: options.numberOfWorkers ?? ProcessInfo.processInfo.activeProcessorCount,
                buildOptions: globalOptions.build,
                buildParameters: buildParameters,
                shouldOutputSuccess: swiftTool.logLevel <= .info,
                observabilityScope: swiftTool.observabilityScope
            )

            let testResults = try runner.run(tests)

            // Generate xUnit file if requested
            if let xUnitOutput = options.xUnitOutput {
                let generator = XUnitGenerator(
                    fileSystem: swiftTool.fileSystem,
                    results: testResults
                )
                try generator.generate(at: xUnitOutput)
            }

            // process code Coverage if request
            if self.options.enableCodeCoverage, runner.ranSuccessfully {
                try processCodeCoverage(testProducts, swiftTool: swiftTool)
            }

            if !runner.ranSuccessfully {
                swiftTool.executionStatus = .failure
            }

            if self.options.enableExperimentalTestOutput, !runner.ranSuccessfully {
                try Self.handleTestOutput(buildParameters: buildParameters, packagePath: testProducts[0].packagePath)
            }
        }
    }

    private static func handleTestOutput(buildParameters: BuildParameters, packagePath: AbsolutePath) throws {
        guard localFileSystem.exists(buildParameters.testOutputPath) else {
            print("No existing test output found.")
            return
        }

        let lines = try String(contentsOfFile: buildParameters.testOutputPath.pathString).components(separatedBy: "\n")
        let events = try lines.map { try JSONDecoder().decode(TestEventRecord.self, from: $0) }

        let caseEvents = events.compactMap { $0.caseEvent }
        let failureRecords = events.compactMap { $0.caseFailure }
        let expectedFailures = failureRecords.filter({ $0.failureKind.isExpected == true })
        let unexpectedFailures = failureRecords.filter { $0.failureKind.isExpected == false }.sorted(by: { lhs, rhs in
            guard let lhsLocation = lhs.issue.sourceCodeContext.location, let rhsLocation = rhs.issue.sourceCodeContext.location else {
                return lhs.description < rhs.description
            }

            if lhsLocation.file == rhsLocation.file {
                return lhsLocation.line < rhsLocation.line
            } else {
                return lhsLocation.file < rhsLocation.file
            }
        }).map { $0.description(with: packagePath.pathString) }

        let startedTests = caseEvents.filter { $0.event == .start }.count
        let finishedTests = caseEvents.filter { $0.event == .finish }.count
        let totalFailures = expectedFailures.count + unexpectedFailures.count
        print("\nRan \(finishedTests)/\(startedTests) tests, \(totalFailures) failures (\(unexpectedFailures.count) unexpected):\n")
        print("\(unexpectedFailures.joined(separator: "\n"))")
    }

    /// Processes the code coverage data and emits a json.
    private func processCodeCoverage(_ testProducts: [BuiltTestProduct], swiftTool: SwiftTool) throws {
        let workspace = try swiftTool.getActiveWorkspace()
        let root = try swiftTool.getWorkspaceRoot()
        let rootManifests = try temp_await {
            workspace.loadRootManifests(
                packages: root.packages,
                observabilityScope: swiftTool.observabilityScope,
                completion: $0
            )
        }
        guard let rootManifest = rootManifests.values.first else {
            throw StringError("invalid manifests at \(root.packages)")
        }

        // Merge all the profraw files to produce a single profdata file.
        try mergeCodeCovRawDataFiles(swiftTool: swiftTool)

        let buildParameters = try swiftTool.buildParametersForTest(options: self.options, sharedOptions: self.sharedOptions)
        for product in testProducts {
            // Export the codecov data as JSON.
            let jsonPath = buildParameters.codeCovAsJSONPath(packageName: rootManifest.displayName)
            try exportCodeCovAsJSON(to: jsonPath, testBinary: product.binaryPath, swiftTool: swiftTool)
        }
    }

    /// Merges all profraw profiles in codecoverage directory into default.profdata file.
    private func mergeCodeCovRawDataFiles(swiftTool: SwiftTool) throws {
        // Get the llvm-prof tool.
        let llvmProf = try swiftTool.getTargetToolchain().getLLVMProf()

        // Get the profraw files.
        let buildParameters = try swiftTool.buildParametersForTest(options: self.options, sharedOptions: self.sharedOptions)
        let codeCovFiles = try swiftTool.fileSystem.getDirectoryContents(buildParameters.codeCovPath)

        // Construct arguments for invoking the llvm-prof tool.
        var args = [llvmProf.pathString, "merge", "-sparse"]
        for file in codeCovFiles {
            let filePath = buildParameters.codeCovPath.appending(component: file)
            if filePath.extension == "profraw" {
                args.append(filePath.pathString)
            }
        }
        args += ["-o", buildParameters.codeCovDataFile.pathString]

        try TSCBasic.Process.checkNonZeroExit(arguments: args)
    }

    /// Exports profdata as a JSON file.
    private func exportCodeCovAsJSON(to path: AbsolutePath, testBinary: AbsolutePath, swiftTool: SwiftTool) throws {
        // Export using the llvm-cov tool.
        let llvmCov = try swiftTool.getTargetToolchain().getLLVMCov()
        let buildParameters = try swiftTool.buildParametersForTest(options: self.options, sharedOptions: self.sharedOptions)
        let args = [
            llvmCov.pathString,
            "export",
            "-instr-profile=\(buildParameters.codeCovDataFile)",
            testBinary.pathString
        ]
        let result = try TSCBasic.Process.popen(arguments: args)

        if result.exitStatus != .terminated(code: 0) {
            let output = try result.utf8Output() + result.utf8stderrOutput()
            throw StringError("Unable to export code coverage:\n \(output)")
        }
        try swiftTool.fileSystem.writeFileContents(path, bytes: ByteString(result.output.get()))
    }

    /// Builds the "test" target if enabled in options.
    ///
    /// - Returns: The paths to the build test products.
    private func buildTestsIfNeeded(swiftTool: SwiftTool) throws -> [BuiltTestProduct] {
        let buildParameters = try swiftTool.buildParametersForTest(options: self.options, sharedOptions: self.sharedOptions)
        return try Commands.buildTestsIfNeeded(swiftTool: swiftTool, buildParameters: buildParameters, testProduct: self.sharedOptions.testProduct)
    }

    /// Private function that validates the commands arguments
    ///
    /// - Throws: if a command argument is invalid
    private func validateArguments(observabilityScope: ObservabilityScope) throws {
        // Validation for --num-workers.
        if let workers = options.numberOfWorkers {

            // The --num-worker option should be called with --parallel.
            guard options.shouldRunInParallel else {
                throw StringError("--num-workers must be used with --parallel")
            }

            guard workers > 0 else {
                throw StringError("'--num-workers' must be greater than zero")
            }
        }

        if options._deprecated_shouldListTests {
            observabilityScope.emit(warning: "'--list-tests' option is deprecated; use 'swift test list' instead")
        }
    }

    public init() {}
}

extension SwiftTestTool {
     struct PrintCodeCovPath: SwiftCommand {
         static let configuration = CommandConfiguration(
             commandName: "show-codecov-path",
             abstract: "Print the path of the exported code coverage JSON file"
         )

         @OptionGroup(visibility: .hidden)
         var globalOptions: GlobalOptions

         // for deprecated passthrough from SwiftTestTool (parse will fail otherwise)

         @Flag(name: [.customLong("show-codecov-path"), .customLong("show-code-coverage-path"), .customLong("show-coverage-path")], help: .hidden)
         var _deprecated_passthrough: Bool = false

         func run(_ swiftTool: SwiftTool) throws {
             let workspace = try swiftTool.getActiveWorkspace()
             let root = try swiftTool.getWorkspaceRoot()
             let rootManifests = try temp_await {
                 workspace.loadRootManifests(
                     packages: root.packages,
                     observabilityScope: swiftTool.observabilityScope,
                     completion: $0
                 )
             }
             guard let rootManifest = rootManifests.values.first else {
                 throw StringError("invalid manifests at \(root.packages)")
             }
             let buildParameters = try swiftTool.buildParametersForTest(enableCodeCoverage: true)
             print(buildParameters.codeCovAsJSONPath(packageName: rootManifest.displayName))
         }
     }
 }

extension SwiftTestTool {
    struct Last: SwiftCommand {
        @OptionGroup(visibility: .hidden)
        var globalOptions: GlobalOptions

        func run(_ swiftTool: SwiftTool) throws {
            try SwiftTestTool.handleTestOutput(
                buildParameters: try swiftTool.buildParameters(),
                packagePath: localFileSystem.currentWorkingDirectory ?? .root // by definition runs in the current working directory
            )
        }
    }

    struct List: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Lists test methods in specifier format"
        )

        @OptionGroup(visibility: .hidden)
        var globalOptions: GlobalOptions

        @OptionGroup()
        var sharedOptions: SharedOptions

        // for deprecated passthrough from SwiftTestTool (parse will fail otherwise)
        @Flag(name: [.customLong("list-tests"), .customShort("l")], help: .hidden)
        var _deprecated_passthrough: Bool = false

        func run(_ swiftTool: SwiftTool) throws {
            let testProducts = try buildTestsIfNeeded(swiftTool: swiftTool)
            let testSuites = try TestingSupport.getTestSuites(
                in: testProducts,
                swiftTool: swiftTool,
                enableCodeCoverage: false,
                shouldSkipBuilding: sharedOptions.shouldSkipBuilding,
                experimentalTestOutput: false,
                sanitizers: globalOptions.build.sanitizers
            )

            // Print the tests.
            for test in testSuites.allTests {
                print(test.specifier)
            }
        }

        private func buildTestsIfNeeded(swiftTool: SwiftTool) throws -> [BuiltTestProduct] {
            let buildParameters = try swiftTool.buildParametersForTest(enableCodeCoverage: false, shouldSkipBuilding: sharedOptions.shouldSkipBuilding)
            return try Commands.buildTestsIfNeeded(swiftTool: swiftTool, buildParameters: buildParameters, testProduct: self.sharedOptions.testProduct)
        }
    }
}

/// A structure representing an individual unit test.
struct UnitTest {
    /// The path to the test product containing the test.
    let productPath: AbsolutePath

    /// The name of the unit test.
    let name: String

    /// The name of the test case.
    let testCase: String

    /// The specifier argument which can be passed to XCTest.
    var specifier: String {
        return testCase + "/" + name
    }
}

/// A class to run tests on a XCTest binary.
///
/// Note: Executes the XCTest with inherited environment as it is convenient to pass senstive
/// information like username, password etc to test cases via environment variables.
final class TestRunner {
    /// Path to valid XCTest binaries.
    private let bundlePaths: [AbsolutePath]

    /// Arguments to pass to XCTest if any.
    private let xctestArg: String?

    private let cancellator: Cancellator

    // The toolchain to use.
    private let toolchain: UserToolchain

    private let testEnv: [String: String]

    /// ObservabilityScope  to emit diagnostics.
    private let observabilityScope: ObservabilityScope

    /// Creates an instance of TestRunner.
    ///
    /// - Parameters:
    ///     - testPaths: Paths to valid XCTest binaries.
    ///     - xctestArg: Arguments to pass to XCTest.
    init(
        bundlePaths: [AbsolutePath],
        xctestArg: String? = nil,
        cancellator: Cancellator,
        toolchain: UserToolchain,
        testEnv: [String: String],
        observabilityScope: ObservabilityScope
    ) {
        self.bundlePaths = bundlePaths
        self.xctestArg = xctestArg
        self.cancellator = cancellator
        self.toolchain = toolchain
        self.testEnv = testEnv
        self.observabilityScope = observabilityScope.makeChildScope(description: "Test Runner")
    }

    /// Executes and returns execution status. Prints test output on standard streams if requested
    /// - Returns: Boolean indicating if test execution returned code 0, and the output stream result
    public func test(outputHandler: @escaping (String) -> Void) -> Bool {
        var success = true
        for path in self.bundlePaths {
            let testSuccess = self.test(at: path, outputHandler: outputHandler)
            success = success && testSuccess
        }
        return success
    }

    /// Constructs arguments to execute XCTest.
    private func args(forTestAt testPath: AbsolutePath) throws -> [String] {
        var args: [String] = []
        #if os(macOS)
        guard let xctestPath = self.toolchain.xctestPath else {
            throw TestError.xctestNotAvailable
        }
        args = [xctestPath.pathString]
        if let xctestArg {
            args += ["-XCTest", xctestArg]
        }
        args += [testPath.pathString]
        #else
        args += [testPath.description]
        if let xctestArg {
            args += [xctestArg]
        }
        #endif
        return args
    }

    private func test(at path: AbsolutePath, outputHandler: @escaping (String) -> Void) -> Bool {
        let testObservabilityScope = self.observabilityScope.makeChildScope(description: "running test at \(path)")

        do {
            let outputHandler = { (bytes: [UInt8]) in
                if let output = String(bytes: bytes, encoding: .utf8)?.spm_chuzzle() {
                    outputHandler(output)
                }
            }
            let outputRedirection = Process.OutputRedirection.stream(
                stdout: outputHandler,
                stderr: outputHandler
            )
            let process = TSCBasic.Process(arguments: try args(forTestAt: path), environment: self.testEnv, outputRedirection: outputRedirection)
            guard let terminationKey = self.cancellator.register(process) else {
                return false // terminating
            }
            defer { self.cancellator.deregister(terminationKey) }
            try process.launch()
            let result = try process.waitUntilExit()
            switch result.exitStatus {
            case .terminated(code: 0):
                return true
            #if !os(Windows)
            case .signalled(let signal):
                testObservabilityScope.emit(error: "Exited with signal code \(signal)")
                return false
            #endif
            default:
                return false
            }
        } catch {
            testObservabilityScope.emit(error)
            return false
        }
    }
}

/// A class to run tests in parallel.
final class ParallelTestRunner {
    /// An enum representing result of a unit test execution.
    struct TestResult {
        var unitTest: UnitTest
        var output: String
        var success: Bool
        var duration: DispatchTimeInterval
    }

    /// Path to XCTest binaries.
    private let bundlePaths: [AbsolutePath]

    /// The queue containing list of tests to run (producer).
    private let pendingTests = SynchronizedQueue<UnitTest?>()

    /// The queue containing tests which are finished running.
    private let finishedTests = SynchronizedQueue<TestResult?>()

    /// Instance of a terminal progress animation.
    private let progressAnimation: ProgressAnimationProtocol

    /// Number of tests that will be executed.
    private var numTests = 0

    /// Number of the current tests that has been executed.
    private var numCurrentTest = 0

    /// True if all tests executed successfully.
    private(set) var ranSuccessfully = true

    private let cancellator: Cancellator

    private let toolchain: UserToolchain

    private let buildOptions: BuildOptions
    private let buildParameters: BuildParameters

    /// Number of tests to execute in parallel.
    private let numJobs: Int

    /// Whether to display output from successful tests.
    private let shouldOutputSuccess: Bool

    /// ObservabilityScope to emit diagnostics.
    private let observabilityScope: ObservabilityScope

    init(
        bundlePaths: [AbsolutePath],
        cancellator: Cancellator,
        toolchain: UserToolchain,
        numJobs: Int,
        buildOptions: BuildOptions,
        buildParameters: BuildParameters,
        shouldOutputSuccess: Bool,
        observabilityScope: ObservabilityScope
    ) {
        self.bundlePaths = bundlePaths
        self.cancellator = cancellator
        self.toolchain = toolchain
        self.numJobs = numJobs
        self.shouldOutputSuccess = shouldOutputSuccess
        self.observabilityScope = observabilityScope.makeChildScope(description: "Parallel Test Runner")

        // command's result output goes on stdout
        // ie "swift test" should output to stdout
        if ProcessEnv.vars["SWIFTPM_TEST_RUNNER_PROGRESS_BAR"] == "lit" {
            progressAnimation = PercentProgressAnimation(stream: TSCBasic.stdoutStream, header: "Testing:")
        } else {
            progressAnimation = NinjaProgressAnimation(stream: TSCBasic.stdoutStream)
        }

        self.buildOptions = buildOptions
        self.buildParameters = buildParameters

        assert(numJobs > 0, "num jobs should be > 0")
    }

    /// Updates the progress bar status.
    private func updateProgress(for test: UnitTest) {
        numCurrentTest += 1
        progressAnimation.update(step: numCurrentTest, total: numTests, text: "Testing \(test.specifier)")
    }

    private func enqueueTests(_ tests: [UnitTest]) throws {
        // Enqueue all the tests.
        for test in tests {
            pendingTests.enqueue(test)
        }
        self.numTests = tests.count
        self.numCurrentTest = 0
        // Enqueue the sentinels, we stop a thread when it encounters a sentinel in the queue.
        for _ in 0..<numJobs {
            pendingTests.enqueue(nil)
        }
    }

    /// Executes the tests spawning parallel workers. Blocks calling thread until all workers are finished.
    func run(_ tests: [UnitTest]) throws -> [TestResult] {
        assert(!tests.isEmpty, "There should be at least one test to execute.")

        let testEnv = try TestingSupport.constructTestEnvironment(
            toolchain: self.toolchain,
            buildParameters: self.buildParameters,
            sanitizers: self.buildOptions.sanitizers
        )

        // Enqueue all the tests.
        try enqueueTests(tests)

        // Create the worker threads.
        let workers: [Thread] = (0..<numJobs).map({ _ in
            let thread = Thread {
                // Dequeue a specifier and run it till we encounter nil.
                while let test = self.pendingTests.dequeue() {
                    let testRunner = TestRunner(
                        bundlePaths: [test.productPath],
                        xctestArg: test.specifier,
                        cancellator: self.cancellator,
                        toolchain: self.toolchain,
                        testEnv: testEnv,
                        observabilityScope: self.observabilityScope
                    )
                    var output = ""
                    let outputLock = NSLock()
                    let start = DispatchTime.now()
                    let success = testRunner.test(outputHandler: { _output in outputLock.withLock{ output += _output }})
                    let duration = start.distance(to: .now())
                    if !success {
                        self.ranSuccessfully = false
                    }
                    self.finishedTests.enqueue(TestResult(
                        unitTest: test,
                        output: output,
                        success: success,
                        duration: duration
                    ))
                }
            }
            thread.start()
            return thread
        })

        // List of processed tests.
        let processedTests = ThreadSafeArrayStore<TestResult>()

        // Report (consume) the tests which have finished running.
        while let result = finishedTests.dequeue() {
            updateProgress(for: result.unitTest)

            // Store the result.
            processedTests.append(result)

            // We can't enqueue a sentinel into finished tests queue because we won't know
            // which test is last one so exit this when all the tests have finished running.
            if numCurrentTest == numTests {
                break
            }
        }

        // Wait till all threads finish execution.
        workers.forEach { $0.join() }

        // Report the completion.
        progressAnimation.complete(success: processedTests.get().contains(where: { !$0.success }))

        // Print test results.
        for test in processedTests.get() {
            if (!test.success || shouldOutputSuccess) && !buildParameters.experimentalTestOutput {
                // command's result output goes on stdout
                // ie "swift test" should output to stdout
                print(test.output)
            }
        }

        return processedTests.get()
    }

}

/// A struct to hold the XCTestSuite data.
struct TestSuite {

    /// A struct to hold a XCTestCase data.
    struct TestCase {
        /// Name of the test case.
        let name: String

        /// Array of test methods in this test case.
        let tests: [String]
    }

    /// The name of the test suite.
    let name: String

    /// Array of test cases in this test suite.
    let tests: [TestCase]

    /// Parses a JSON String to array of TestSuite.
    ///
    /// - Parameters:
    ///     - jsonString: JSON string to be parsed.
    ///     - context: the commandline which produced the given JSON.
    ///
    /// - Throws: JSONDecodingError, TestError
    ///
    /// - Returns: Array of TestSuite.
    static func parse(jsonString: String, context: String) throws -> [TestSuite] {
        let json: JSON
        do {
            json = try JSON(string: jsonString)
        } catch {
            throw TestError.invalidListTestJSONData(context: context, underlyingError: error)
        }
        return try TestSuite.parse(json: json, context: context)
    }

    /// Parses the JSON object into array of TestSuite.
    ///
    /// - Parameters:
    ///     - json: An object of JSON.
    ///     - context: the commandline which produced the given JSON.
    ///
    /// - Throws: TestError
    ///
    /// - Returns: Array of TestSuite.
    static func parse(json: JSON, context: String) throws -> [TestSuite] {
        guard case let .dictionary(contents) = json,
              case let .array(testSuites)? = contents["tests"] else {
            throw TestError.invalidListTestJSONData(context: context)
        }

        return try testSuites.map({ testSuite in
            guard case let .dictionary(testSuiteData) = testSuite,
                  case let .string(name)? = testSuiteData["name"],
                  case let .array(allTestsData)? = testSuiteData["tests"] else {
                throw TestError.invalidListTestJSONData(context: context)
            }

            let testCases: [TestSuite.TestCase] = try allTestsData.map({ testCase in
                guard case let .dictionary(testCaseData) = testCase,
                      case let .string(name)? = testCaseData["name"],
                      case let .array(tests)? = testCaseData["tests"] else {
                    throw TestError.invalidListTestJSONData(context: context)
                }
                let testMethods: [String] = try tests.map({ test in
                    guard case let .dictionary(testData) = test,
                          case let .string(testMethod)? = testData["name"] else {
                        throw TestError.invalidListTestJSONData(context: context)
                    }
                    return testMethod
                })
                return TestSuite.TestCase(name: name, tests: testMethods)
            })

            return TestSuite(name: name, tests: testCases)
        })
    }
}


fileprivate extension Dictionary where Key == AbsolutePath, Value == [TestSuite] {
    /// Returns all the unit tests of the test suites.
    var allTests: [UnitTest] {
        var allTests: [UnitTest] = []
        for (bundlePath, testSuites) in self {
            for testSuite in testSuites {
                for testCase in testSuite.tests {
                    for test in testCase.tests {
                        allTests.append(UnitTest(productPath: bundlePath, name: test, testCase: testCase.name))
                    }
                }
            }
        }
        return allTests
    }

    /// Return tests matching the provided specifier
    func filteredTests(specifier: TestCaseSpecifier) throws -> [UnitTest] {
        switch specifier {
        case .none:
            return allTests
        case .regex(let patterns):
            return allTests.filter({ test in
                patterns.contains { pattern in
                    test.specifier.range(of: pattern,
                                         options: .regularExpression) != nil
                }
            })
        case .specific(let name):
            return allTests.filter{ $0.specifier == name }
        case .skip:
            throw InternalError("Tests to skip should never have been passed here.")
        }
    }
}

fileprivate extension Array where Element == UnitTest {
    /// Skip tests matching the provided specifier
    func skippedTests(specifier: TestCaseSpecifier) throws -> [UnitTest] {
        switch specifier {
        case .none:
            return self
        case .skip(let skippedTests):
            var result = self
            for skippedTest in skippedTests {
                result = result.filter{
                    $0.specifier.range(of: skippedTest, options: .regularExpression) == nil
                }
            }
            return result
        case .regex, .specific:
            throw InternalError("Tests to filter should never have been passed here.")
        }
    }
}

/// xUnit XML file generator for a swift-test run.
final class XUnitGenerator {
    typealias TestResult = ParallelTestRunner.TestResult

    /// The file system to use
    let fileSystem: FileSystem

    /// The test results.
    let results: [TestResult]

    init(fileSystem: FileSystem, results: [TestResult]) {
        self.fileSystem = fileSystem
        self.results = results
    }

    /// Generate the file at the given path.
    func generate(at path: AbsolutePath) throws {
        var content =
            """
            <?xml version="1.0" encoding="UTF-8"?>

            <testsuites>

            """

        // Get the failure count.
        let failures = results.filter({ !$0.success }).count
        let duration = results.compactMap({ $0.duration.timeInterval() }).reduce(0.0, +)

        // We need better output reporting from XCTest.
        content +=
            """
            <testsuite name="TestResults" errors="0" tests="\(results.count)" failures="\(failures)" time="\(duration)">

            """

        // Generate a testcase entry for each result.
        //
        // FIXME: This is very minimal right now. We should allow including test output etc.
        for result in results {
            let test = result.unitTest
            let duration = result.duration.timeInterval() ?? 0.0
            content +=
                """
                <testcase classname="\(test.testCase)" name="\(test.name)" time="\(duration)">

                """

            if !result.success {
                content += "<failure message=\"failed\"></failure>\n"
            }

            content += "</testcase>\n"
        }

        content +=
            """
            </testsuite>
            </testsuites>

            """

        try self.fileSystem.writeFileContents(path, string: content)
    }
}

extension SwiftTool {
    func buildParametersForTest(options: TestToolOptions, sharedOptions: SharedOptions) throws -> BuildParameters {
        try self.buildParametersForTest(
            enableCodeCoverage: options.enableCodeCoverage,
            enableTestability: options.enableTestableImports,
            shouldSkipBuilding: sharedOptions.shouldSkipBuilding,
            experimentalTestOutput: options.enableExperimentalTestOutput
        )
    }
}

extension TestToolOptions {
    func skippedTests(fileSystem: FileSystem) -> TestCaseSpecifier {
        // TODO: Remove this once the environment variable is no longer used.
        if let override = skippedTestsOverride(fileSystem: fileSystem) {
            return override
        }

        return self._testCaseSkip.isEmpty
            ? .none
        : .skip(self._testCaseSkip)
    }

    /// Returns the test case specifier if overridden in the env.
    private func skippedTestsOverride(fileSystem: FileSystem) -> TestCaseSpecifier? {
        guard let override = ProcessEnv.vars["_SWIFTPM_SKIP_TESTS_LIST"] else {
            return nil
        }

        do {
            let skipTests: [String.SubSequence]
            // Read from the file if it exists.
            if let path = try? AbsolutePath(validating: override), fileSystem.exists(path) {
                let contents: String = try fileSystem.readFileContents(path)
                skipTests = contents.split(separator: "\n", omittingEmptySubsequences: true)
            } else {
                // Otherwise, read the env variable.
                skipTests = override.split(separator: ":", omittingEmptySubsequences: true)
            }

            return .skip(skipTests.map(String.init))
        } catch {
            // FIXME: We should surface errors from here.
        }
        return nil
    }
}

extension BuildParameters {
    fileprivate func codeCovAsJSONPath(packageName: String) -> AbsolutePath {
        return self.codeCovPath.appending(component: packageName + ".json")
    }
}

private extension Basics.Diagnostic {
    static var noMatchingTests: Self {
        .warning("No matching test cases were run")
    }
}

/// Builds the "test" target if enabled in options.
///
/// - Returns: The paths to the build test products.
private func buildTestsIfNeeded(swiftTool: SwiftTool, buildParameters: BuildParameters, testProduct: String?) throws -> [BuiltTestProduct] {
    let buildSystem = try swiftTool.createBuildSystem(customBuildParameters: buildParameters)

    let subset = testProduct.map(BuildSubset.product) ?? .allIncludingTests
    try buildSystem.build(subset: subset)

    // Find the test product.
    let testProducts = buildSystem.builtTestProducts
    guard !testProducts.isEmpty else {
        if let testProduct {
            throw TestError.productIsNotTest(productName: testProduct)
        } else {
            throw TestError.testsNotFound
        }
    }

    if let testProductName = testProduct {
        guard let selectedTestProduct = testProducts.first(where: { $0.productName == testProductName }) else {
            throw TestError.testProductNotFound(productName: testProductName)
        }

        return [selectedTestProduct]
    } else {
        return testProducts
    }
}
