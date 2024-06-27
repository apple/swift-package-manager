//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2015-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ArgumentParser

@_spi(SwiftPMInternal)
import Basics

@_spi(SwiftPMInternal)
import CoreCommands

import Dispatch
import Foundation
import PackageGraph

@_spi(SwiftPMInternal)
import PackageModel

import SPMBuildCore

import func TSCLibc.exit
import Workspace

import struct TSCBasic.ByteString
import enum TSCBasic.JSON
import class Basics.AsyncProcess
import var TSCBasic.stdoutStream
import class TSCBasic.SynchronizedQueue
import class TSCBasic.Thread

private enum TestError: Swift.Error {
    case invalidListTestJSONData(context: String, underlyingError: Error? = nil)
    case testsNotFound
    case testProductNotFound(productName: String)
    case productIsNotTest(productName: String)
    case multipleTestProducts([String])
    case xctestNotAvailable(reason: String)
    case xcodeNotInstalled
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
        case let .xctestNotAvailable(reason):
            return "XCTest not available: \(reason)"
        case .xcodeNotInstalled:
            return "XCTest not available; download and install Xcode to use XCTest on this platform"
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

struct TestCommandOptions: ParsableArguments {
    @OptionGroup()
    var globalOptions: GlobalOptions

    @OptionGroup()
    var sharedOptions: SharedOptions

    /// Which testing libraries to use (and any related options.)
    @OptionGroup()
    var testLibraryOptions: TestLibraryOptions

    /// If tests should run in parallel mode.
    @Flag(name: .customLong("parallel"),
          inversion: .prefixedNo,
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

    /// Path where swift-testing's JSON configuration should be read.
    @Option(name: .customLong("experimental-configuration-path"),
            help: .hidden)
    var configurationPath: AbsolutePath?

    /// Path where swift-testing's JSON output should be written.
    @Option(name: .customLong("experimental-event-stream-output"),
            help: .hidden)
    var eventStreamOutputPath: AbsolutePath?

    /// The schema version of swift-testing's JSON input/output.
    @Option(name: .customLong("experimental-event-stream-version"),
            help: .hidden)
    var eventStreamVersion: Int?

    @OptionGroup(visibility: .hidden)
    package var traits: TraitOptions
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
public struct SwiftTestCommand: AsyncSwiftCommand {
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

    public var globalOptions: GlobalOptions {
        options.globalOptions
    }

    @OptionGroup()
    var options: TestCommandOptions

    // MARK: - XCTest

    private func xctestRun(_ swiftCommandState: SwiftCommandState) async throws {
        // validate XCTest available on darwin based systems
        let toolchain = try swiftCommandState.getTargetToolchain()
        if case let .unsupported(reason) = try swiftCommandState.getHostToolchain().swiftSDK.xctestSupport {
            if let reason {
                throw TestError.xctestNotAvailable(reason: reason)
            } else {
                throw TestError.xcodeNotInstalled
            }
        } else if toolchain.targetTriple.isDarwin() && toolchain.xctestPath == nil {
            throw TestError.xcodeNotInstalled
        }

        let (productsBuildParameters, _) = try swiftCommandState.buildParametersForTest(options: self.options, library: .xctest)

        // Remove test output from prior runs and validate priors.
        if self.options.enableExperimentalTestOutput && productsBuildParameters.triple.supportsTestSummary {
            _ = try? localFileSystem.removeFileTree(productsBuildParameters.testOutputPath)
        }

        let testProducts = try buildTestsIfNeeded(swiftCommandState: swiftCommandState, library: .xctest)
        if !self.options.shouldRunInParallel {
            let xctestArgs = try xctestArgs(for: testProducts, swiftCommandState: swiftCommandState)
            try await runTestProducts(
                testProducts,
                additionalArguments: xctestArgs,
                productsBuildParameters: productsBuildParameters,
                swiftCommandState: swiftCommandState,
                library: .xctest
            )
        } else {
            let testSuites = try TestingSupport.getTestSuites(
                in: testProducts,
                swiftCommandState: swiftCommandState,
                enableCodeCoverage: options.enableCodeCoverage,
                shouldSkipBuilding: options.sharedOptions.shouldSkipBuilding,
                experimentalTestOutput: options.enableExperimentalTestOutput,
                sanitizers: globalOptions.build.sanitizers
            )
            let tests = try testSuites
                .filteredTests(specifier: options.testCaseSpecifier)
                .skippedTests(specifier: options.skippedTests(fileSystem: swiftCommandState.fileSystem))

            // If there were no matches, emit a warning and exit.
            if tests.isEmpty {
                swiftCommandState.observabilityScope.emit(.noMatchingTests)
                try generateXUnitOutputIfRequested(for: [], swiftCommandState: swiftCommandState)
                return
            }

            // Clean out the code coverage directory that may contain stale
            // profraw files from a previous run of the code coverage tool.
            if self.options.enableCodeCoverage {
                try swiftCommandState.fileSystem.removeFileTree(productsBuildParameters.codeCovPath)
            }

            // Run the tests using the parallel runner.
            let runner = ParallelTestRunner(
                bundlePaths: testProducts.map { $0.bundlePath },
                cancellator: swiftCommandState.cancellator,
                toolchain: toolchain,
                numJobs: options.numberOfWorkers ?? ProcessInfo.processInfo.activeProcessorCount,
                buildOptions: globalOptions.build,
                productsBuildParameters: productsBuildParameters,
                shouldOutputSuccess: swiftCommandState.logLevel <= .info,
                observabilityScope: swiftCommandState.observabilityScope
            )

            let testResults = try runner.run(tests)

            try generateXUnitOutputIfRequested(for: testResults, swiftCommandState: swiftCommandState)

            // process code Coverage if request
            if self.options.enableCodeCoverage, runner.ranSuccessfully {
                try await processCodeCoverage(testProducts, swiftCommandState: swiftCommandState, library: .xctest)
            }

            if !runner.ranSuccessfully {
                swiftCommandState.executionStatus = .failure
            }

            if self.options.enableExperimentalTestOutput, !runner.ranSuccessfully {
                try Self.handleTestOutput(productsBuildParameters: productsBuildParameters, packagePath: testProducts[0].packagePath)
            }
        }
    }

    private func xctestArgs(for testProducts: [BuiltTestProduct], swiftCommandState: SwiftCommandState) throws -> [String] {
        switch options.testCaseSpecifier {
        case .none:
            if case .skip = options.skippedTests(fileSystem: swiftCommandState.fileSystem) {
                fallthrough
            } else {
                return []
            }

        case .regex, .specific, .skip:
            // If old specifier `-s` option was used, emit deprecation notice.
            if case .specific = options.testCaseSpecifier {
                swiftCommandState.observabilityScope.emit(warning: "'--specifier' option is deprecated; use '--filter' instead")
            }

            // Find the tests we need to run.
            let testSuites = try TestingSupport.getTestSuites(
                in: testProducts,
                swiftCommandState: swiftCommandState,
                enableCodeCoverage: options.enableCodeCoverage,
                shouldSkipBuilding: options.sharedOptions.shouldSkipBuilding,
                experimentalTestOutput: options.enableExperimentalTestOutput,
                sanitizers: globalOptions.build.sanitizers
            )
            let tests = try testSuites
                .filteredTests(specifier: options.testCaseSpecifier)
                .skippedTests(specifier: options.skippedTests(fileSystem: swiftCommandState.fileSystem))

            // If there were no matches, emit a warning.
            if tests.isEmpty {
                swiftCommandState.observabilityScope.emit(.noMatchingTests)
            }

            return TestRunner.xctestArguments(forTestSpecifiers: tests.map(\.specifier))
        }
    }

    /// Generate xUnit file if requested.
    private func generateXUnitOutputIfRequested(
        for testResults: [ParallelTestRunner.TestResult],
        swiftCommandState: SwiftCommandState
    ) throws {
        guard let xUnitOutput = options.xUnitOutput else {
            return
        }

        let generator = XUnitGenerator(
            fileSystem: swiftCommandState.fileSystem,
            results: testResults
        )
        try generator.generate(at: xUnitOutput)
    }

    // MARK: - swift-testing

    private func swiftTestingRun(_ swiftCommandState: SwiftCommandState) async throws {
        let (productsBuildParameters, _) = try swiftCommandState.buildParametersForTest(options: self.options, library: .swiftTesting)
        let testProducts = try buildTestsIfNeeded(swiftCommandState: swiftCommandState, library: .swiftTesting)
        let additionalArguments = Array(CommandLine.arguments.dropFirst())
        try await runTestProducts(
            testProducts,
            additionalArguments: additionalArguments,
            productsBuildParameters: productsBuildParameters,
            swiftCommandState: swiftCommandState,
            library: .swiftTesting
        )
    }

    // MARK: - Common implementation

    public func run(_ swiftCommandState: SwiftCommandState) async throws {
        do {
            // Validate commands arguments
            try self.validateArguments(observabilityScope: swiftCommandState.observabilityScope)
        } catch {
            swiftCommandState.observabilityScope.emit(error)
            throw ExitCode.failure
        }

        if self.options.shouldPrintCodeCovPath {
            try printCodeCovPath(swiftCommandState)
        } else if self.options._deprecated_shouldListTests {
            // backward compatibility 6/2022 for deprecation of flag into a subcommand
            let command = try List.parse()
            try command.run(swiftCommandState)
        } else {
            if try options.testLibraryOptions.enableSwiftTestingLibrarySupport(swiftCommandState: swiftCommandState) {
                try await swiftTestingRun(swiftCommandState)
            }
            if options.testLibraryOptions.enableXCTestSupport {
                try await xctestRun(swiftCommandState)
            }
        }
    }

    private func runTestProducts(
        _ testProducts: [BuiltTestProduct],
        additionalArguments: [String],
        productsBuildParameters: BuildParameters,
        swiftCommandState: SwiftCommandState,
        library: BuildParameters.Testing.Library
    ) async throws {
        // Clean out the code coverage directory that may contain stale
        // profraw files from a previous run of the code coverage tool.
        if self.options.enableCodeCoverage {
            try swiftCommandState.fileSystem.removeFileTree(productsBuildParameters.codeCovPath)
        }

        let toolchain = try swiftCommandState.getTargetToolchain()
        let testEnv = try TestingSupport.constructTestEnvironment(
            toolchain: toolchain,
            destinationBuildParameters: productsBuildParameters,
            sanitizers: globalOptions.build.sanitizers,
            library: library
        )

        let runner = TestRunner(
            bundlePaths: testProducts.map { library == .xctest ? $0.bundlePath : $0.binaryPath },
            additionalArguments: additionalArguments,
            cancellator: swiftCommandState.cancellator,
            toolchain: toolchain,
            testEnv: testEnv,
            observabilityScope: swiftCommandState.observabilityScope,
            library: library
        )

        // Finally, run the tests.
        let ranSuccessfully = runner.test(outputHandler: {
            // command's result output goes on stdout
            // ie "swift test" should output to stdout
            print($0, terminator: "")
        })
        if !ranSuccessfully {
            swiftCommandState.executionStatus = .failure
        }

        if self.options.enableCodeCoverage, ranSuccessfully {
            try await processCodeCoverage(testProducts, swiftCommandState: swiftCommandState, library: library)
        }

        if self.options.enableExperimentalTestOutput, !ranSuccessfully {
            try Self.handleTestOutput(productsBuildParameters: productsBuildParameters, packagePath: testProducts[0].packagePath)
        }
    }

    private static func handleTestOutput(productsBuildParameters: BuildParameters, packagePath: AbsolutePath) throws {
        guard localFileSystem.exists(productsBuildParameters.testOutputPath) else {
            print("No existing test output found.")
            return
        }

        let lines = try String(contentsOfFile: productsBuildParameters.testOutputPath.pathString).components(separatedBy: "\n")
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
    private func processCodeCoverage(
        _ testProducts: [BuiltTestProduct],
        swiftCommandState: SwiftCommandState,
        library: BuildParameters.Testing.Library
    ) async throws {
        let workspace = try swiftCommandState.getActiveWorkspace()
        let root = try swiftCommandState.getWorkspaceRoot()
        let rootManifests = try await workspace.loadRootManifests(
            packages: root.packages,
            observabilityScope: swiftCommandState.observabilityScope
        )
        guard let rootManifest = rootManifests.values.first else {
            throw StringError("invalid manifests at \(root.packages)")
        }

        // Merge all the profraw files to produce a single profdata file.
        try mergeCodeCovRawDataFiles(swiftCommandState: swiftCommandState, library: library)

        let (productsBuildParameters, _) = try swiftCommandState.buildParametersForTest(options: self.options, library: library)
        for product in testProducts {
            // Export the codecov data as JSON.
            let jsonPath = productsBuildParameters.codeCovAsJSONPath(packageName: rootManifest.displayName)
            try exportCodeCovAsJSON(to: jsonPath, testBinary: product.binaryPath, swiftCommandState: swiftCommandState, library: library)
        }
    }

    /// Merges all profraw profiles in codecoverage directory into default.profdata file.
    private func mergeCodeCovRawDataFiles(swiftCommandState: SwiftCommandState, library: BuildParameters.Testing.Library) throws {
        // Get the llvm-prof tool.
        let llvmProf = try swiftCommandState.getTargetToolchain().getLLVMProf()

        // Get the profraw files.
        let (productsBuildParameters, _) = try swiftCommandState.buildParametersForTest(options: self.options, library: library)
        let codeCovFiles = try swiftCommandState.fileSystem.getDirectoryContents(productsBuildParameters.codeCovPath)

        // Construct arguments for invoking the llvm-prof tool.
        var args = [llvmProf.pathString, "merge", "-sparse"]
        for file in codeCovFiles {
            let filePath = productsBuildParameters.codeCovPath.appending(component: file)
            if filePath.extension == "profraw" {
                args.append(filePath.pathString)
            }
        }
        args += ["-o", productsBuildParameters.codeCovDataFile.pathString]

        try AsyncProcess.checkNonZeroExit(arguments: args)
    }

    /// Exports profdata as a JSON file.
    private func exportCodeCovAsJSON(
        to path: AbsolutePath,
        testBinary: AbsolutePath,
        swiftCommandState: SwiftCommandState,
        library: BuildParameters.Testing.Library
    ) throws {
        // Export using the llvm-cov tool.
        let llvmCov = try swiftCommandState.getTargetToolchain().getLLVMCov()
        let (productsBuildParameters, _) = try swiftCommandState.buildParametersForTest(options: self.options, library: library)
        let args = [
            llvmCov.pathString,
            "export",
            "-instr-profile=\(productsBuildParameters.codeCovDataFile)",
            testBinary.pathString
        ]
        let result = try AsyncProcess.popen(arguments: args)

        if result.exitStatus != .terminated(code: 0) {
            let output = try result.utf8Output() + result.utf8stderrOutput()
            throw StringError("Unable to export code coverage:\n \(output)")
        }
        try swiftCommandState.fileSystem.writeFileContents(path, bytes: ByteString(result.output.get()))
    }

    /// Builds the "test" target if enabled in options.
    ///
    /// - Returns: The paths to the build test products.
    private func buildTestsIfNeeded(
        swiftCommandState: SwiftCommandState,
        library: BuildParameters.Testing.Library
    ) throws -> [BuiltTestProduct] {
        let (productsBuildParameters, toolsBuildParameters) = try swiftCommandState.buildParametersForTest(options: self.options, library: library)
        return try Commands.buildTestsIfNeeded(
            swiftCommandState: swiftCommandState,
            productsBuildParameters: productsBuildParameters,
            toolsBuildParameters: toolsBuildParameters,
            testProduct: self.options.sharedOptions.testProduct,
            traitConfiguration: .init(traitOptions: self.options.traits)
        )
    }

    /// Private function that validates the commands arguments
    ///
    /// - Throws: if a command argument is invalid
    private func validateArguments(observabilityScope: ObservabilityScope) throws {
        // Validation for --num-workers.
        if let workers = options.numberOfWorkers {

            // The --num-worker option should be called with --parallel. Since
            // this option does not affect swift-testing at this time, we can
            // effectively ignore that it defaults to enabling parallelization.
            guard options.shouldRunInParallel else {
                throw StringError("--num-workers must be used with --parallel")
            }

            guard workers > 0 else {
                throw StringError("'--num-workers' must be greater than zero")
            }

            if !options.testLibraryOptions.enableXCTestSupport {
                throw StringError("'--num-workers' is only supported when testing with XCTest")
            }
        }

        if options._deprecated_shouldListTests {
            observabilityScope.emit(warning: "'--list-tests' option is deprecated; use 'swift test list' instead")
        }
    }

    public init() {}
}

extension SwiftTestCommand {
    func printCodeCovPath(_ swiftCommandState: SwiftCommandState) throws {
        let workspace = try swiftCommandState.getActiveWorkspace()
        let root = try swiftCommandState.getWorkspaceRoot()
        let rootManifests = try temp_await {
            workspace.loadRootManifests(
                packages: root.packages,
                observabilityScope: swiftCommandState.observabilityScope,
                completion: $0
            )
        }
        guard let rootManifest = rootManifests.values.first else {
            throw StringError("invalid manifests at \(root.packages)")
        }
        let (productsBuildParameters, _) = try swiftCommandState.buildParametersForTest(enableCodeCoverage: true, library: .xctest)
        print(productsBuildParameters.codeCovAsJSONPath(packageName: rootManifest.displayName))
     }
 }

extension SwiftTestCommand {
    struct Last: SwiftCommand {
        @OptionGroup(visibility: .hidden)
        var globalOptions: GlobalOptions

        func run(_ swiftCommandState: SwiftCommandState) throws {
            try SwiftTestCommand.handleTestOutput(
                productsBuildParameters: try swiftCommandState.productsBuildParameters,
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

        /// Which testing libraries to use (and any related options.)
        @OptionGroup()
        var testLibraryOptions: TestLibraryOptions

        @OptionGroup(visibility: .hidden)
        package var traits: TraitOptions

        // for deprecated passthrough from SwiftTestTool (parse will fail otherwise)
        @Flag(name: [.customLong("list-tests"), .customShort("l")], help: .hidden)
        var _deprecated_passthrough: Bool = false

        // MARK: - XCTest

        private func xctestRun(_ swiftCommandState: SwiftCommandState) throws {
          let (productsBuildParameters, toolsBuildParameters) = try swiftCommandState.buildParametersForTest(
                enableCodeCoverage: false,
                shouldSkipBuilding: sharedOptions.shouldSkipBuilding,
                library: .xctest
            )
            let testProducts = try buildTestsIfNeeded(
                swiftCommandState: swiftCommandState,
                productsBuildParameters: productsBuildParameters,
                toolsBuildParameters: toolsBuildParameters
            )
            let testSuites = try TestingSupport.getTestSuites(
                in: testProducts,
                swiftCommandState: swiftCommandState,
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

        // MARK: - swift-testing

        private func swiftTestingRun(_ swiftCommandState: SwiftCommandState) throws {
            let (productsBuildParameters, toolsBuildParameters) = try swiftCommandState.buildParametersForTest(
                enableCodeCoverage: false,
                shouldSkipBuilding: sharedOptions.shouldSkipBuilding,
                library: .swiftTesting
            )
            let testProducts = try buildTestsIfNeeded(
                swiftCommandState: swiftCommandState,
                productsBuildParameters: productsBuildParameters,
                toolsBuildParameters: toolsBuildParameters
            )

            let toolchain = try swiftCommandState.getTargetToolchain()
            let testEnv = try TestingSupport.constructTestEnvironment(
                toolchain: toolchain,
                destinationBuildParameters: productsBuildParameters,
                sanitizers: globalOptions.build.sanitizers,
                library: .swiftTesting
            )

            let additionalArguments = ["--list-tests"] + CommandLine.arguments.dropFirst()
            let runner = TestRunner(
                bundlePaths: testProducts.map(\.binaryPath),
                additionalArguments: additionalArguments,
                cancellator: swiftCommandState.cancellator,
                toolchain: toolchain,
                testEnv: testEnv,
                observabilityScope: swiftCommandState.observabilityScope,
                library: .swiftTesting
            )

            // Finally, run the tests.
            let ranSuccessfully = runner.test(outputHandler: {
                // command's result output goes on stdout
                // ie "swift test" should output to stdout
                print($0, terminator: "")
            })
            if !ranSuccessfully {
                swiftCommandState.executionStatus = .failure
            }
        }

        // MARK: - Common implementation

        func run(_ swiftCommandState: SwiftCommandState) throws {
            if try testLibraryOptions.enableSwiftTestingLibrarySupport(swiftCommandState: swiftCommandState) {
                try swiftTestingRun(swiftCommandState)
            }
            if testLibraryOptions.enableXCTestSupport {
                try xctestRun(swiftCommandState)
            }
        }

        private func buildTestsIfNeeded(
            swiftCommandState: SwiftCommandState,
            productsBuildParameters: BuildParameters,
            toolsBuildParameters: BuildParameters
        ) throws -> [BuiltTestProduct] {
            return try Commands.buildTestsIfNeeded(
                swiftCommandState: swiftCommandState,
                productsBuildParameters: productsBuildParameters,
                toolsBuildParameters: toolsBuildParameters,
                testProduct: self.sharedOptions.testProduct,
                traitConfiguration: .init(traitOptions: self.traits)
            )
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
/// Note: Executes the XCTest with inherited environment as it is convenient to pass sensitive
/// information like username, password etc to test cases via environment variables.
final class TestRunner {
    /// Path to valid XCTest binaries.
    private let bundlePaths: [AbsolutePath]

    /// Arguments to pass to the test runner process, if any.
    private let additionalArguments: [String]

    private let cancellator: Cancellator

    // The toolchain to use.
    private let toolchain: UserToolchain

    private let testEnv: Environment

    /// ObservabilityScope  to emit diagnostics.
    private let observabilityScope: ObservabilityScope

    /// Which testing library to use with this test run.
    private let library: BuildParameters.Testing.Library

    /// Get the arguments used on this platform to pass test specifiers to XCTest.
    static func xctestArguments<S>(forTestSpecifiers testSpecifiers: S) -> [String] where S: Collection, S.Element == String {
        let testSpecifier: String
        if testSpecifiers.isEmpty {
            testSpecifier = "''"
        } else {
            testSpecifier = testSpecifiers.joined(separator: ",")
        }

#if os(macOS)
        return ["-XCTest", testSpecifier]
#else
        return [testSpecifier]
#endif
    }

    /// Creates an instance of TestRunner.
    ///
    /// - Parameters:
    ///     - testPaths: Paths to valid XCTest binaries.
    ///     - additionalArguments: Arguments to pass to the test runner process.
    init(
        bundlePaths: [AbsolutePath],
        additionalArguments: [String],
        cancellator: Cancellator,
        toolchain: UserToolchain,
        testEnv: Environment,
        observabilityScope: ObservabilityScope,
        library: BuildParameters.Testing.Library
    ) {
        self.bundlePaths = bundlePaths
        self.additionalArguments = additionalArguments
        self.cancellator = cancellator
        self.toolchain = toolchain
        self.testEnv = testEnv
        self.observabilityScope = observabilityScope.makeChildScope(description: "Test Runner")
        self.library = library
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
        if library == .xctest {
            guard let xctestPath = self.toolchain.xctestPath else {
                throw TestError.xcodeNotInstalled
            }
            args = [xctestPath.pathString]
            args += additionalArguments
            args += [testPath.pathString]
            return args
        }
        #endif

        args += [testPath.description]
        args += additionalArguments

        return args
    }

    private func test(at path: AbsolutePath, outputHandler: @escaping (String) -> Void) -> Bool {
        let testObservabilityScope = self.observabilityScope.makeChildScope(description: "running test at \(path)")

        do {
            let outputHandler = { (bytes: [UInt8]) in
                if let output = String(bytes: bytes, encoding: .utf8) {
                    outputHandler(output)
                }
            }
            let outputRedirection = AsyncProcess.OutputRedirection.stream(
                stdout: outputHandler,
                stderr: outputHandler
            )
            let process = AsyncProcess(arguments: try args(forTestAt: path), environment: self.testEnv, outputRedirection: outputRedirection)
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
            case .signalled(let signal) where ![SIGINT, SIGKILL, SIGTERM].contains(signal):
                testObservabilityScope.emit(error: "Exited with unexpected signal code \(signal)")
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
    private let productsBuildParameters: BuildParameters

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
        productsBuildParameters: BuildParameters,
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
        if Environment.current["SWIFTPM_TEST_RUNNER_PROGRESS_BAR"] == "lit" {
            self.progressAnimation = ProgressAnimation.percent(
                stream: TSCBasic.stdoutStream,
                verbose: false,
                header: "Testing:"
            )
        } else {
            self.progressAnimation = ProgressAnimation.ninja(
                stream: TSCBasic.stdoutStream,
                verbose: false
            )
        }

        self.buildOptions = buildOptions
        self.productsBuildParameters = productsBuildParameters

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
            destinationBuildParameters: self.productsBuildParameters,
            sanitizers: self.buildOptions.sanitizers,
            library: .xctest // swift-testing does not use ParallelTestRunner
        )

        // Enqueue all the tests.
        try enqueueTests(tests)

        // Create the worker threads.
        let workers: [Thread] = (0..<numJobs).map({ _ in
            let thread = Thread {
                // Dequeue a specifier and run it till we encounter nil.
                while let test = self.pendingTests.dequeue() {
                    let additionalArguments = TestRunner.xctestArguments(forTestSpecifiers: CollectionOfOne(test.specifier))
                    let testRunner = TestRunner(
                        bundlePaths: [test.productPath],
                        additionalArguments: additionalArguments,
                        cancellator: self.cancellator,
                        toolchain: self.toolchain,
                        testEnv: testEnv,
                        observabilityScope: self.observabilityScope,
                        library: .xctest
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
            if (!test.success || shouldOutputSuccess) && !productsBuildParameters.testingParameters.experimentalTestOutput {
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

extension SwiftCommandState {
    func buildParametersForTest(
        options: TestCommandOptions,
        library: BuildParameters.Testing.Library
    ) throws -> (productsBuildParameters: BuildParameters, toolsBuildParameters: BuildParameters) {
        var result = try self.buildParametersForTest(
            enableCodeCoverage: options.enableCodeCoverage,
            enableTestability: options.enableTestableImports,
            shouldSkipBuilding: options.sharedOptions.shouldSkipBuilding,
            experimentalTestOutput: options.enableExperimentalTestOutput,
            library: library
        )
        if try options.testLibraryOptions.enableSwiftTestingLibrarySupport(swiftCommandState: self) {
            result.productsBuildParameters.flags.swiftCompilerFlags += ["-DSWIFT_PM_SUPPORTS_SWIFT_TESTING"]
            result.toolsBuildParameters.flags.swiftCompilerFlags += ["-DSWIFT_PM_SUPPORTS_SWIFT_TESTING"]
        }
        return result
    }
}

extension TestCommandOptions {
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
        guard let override = Environment.current["_SWIFTPM_SKIP_TESTS_LIST"] else {
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
private func buildTestsIfNeeded(
    swiftCommandState: SwiftCommandState,
    productsBuildParameters: BuildParameters,
    toolsBuildParameters: BuildParameters,
    testProduct: String?,
    traitConfiguration: TraitConfiguration
) throws -> [BuiltTestProduct] {
    let buildSystem = try swiftCommandState.createBuildSystem(
        traitConfiguration: traitConfiguration,
        productsBuildParameters: productsBuildParameters,
        toolsBuildParameters: toolsBuildParameters
    )

    let subset: BuildSubset = if let testProduct {
        .product(testProduct)
    } else {
        .allIncludingTests
    }

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
