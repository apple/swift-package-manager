//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics

import CoreCommands

import PackageModel
import SPMBuildCore
import Workspace

import class TSCBasic.Process
import var TSCBasic.stderrStream
import var TSCBasic.stdoutStream
import func TSCBasic.withTemporaryFile

/// Internal helper functionality for the SwiftTestTool command and for the
/// plugin support.
///
/// Note: In the long term this should be factored into a reusable module that
/// can run and report results on tests from both CLI and libSwiftPM API.
enum TestingSupport {
    /// Locates XCTestHelper tool inside the libexec directory and bin directory.
    /// Note: It is a fatalError if we are not able to locate the tool.
    ///
    /// - Returns: Path to XCTestHelper tool.
    static func xctestHelperPath(swiftCommandState: SwiftCommandState) throws -> AbsolutePath {
        var triedPaths = [AbsolutePath]()

        func findXCTestHelper(swiftBuildPath: AbsolutePath) -> AbsolutePath? {
            // XCTestHelper tool is installed in libexec.
            let maybePath = swiftBuildPath.parentDirectory.parentDirectory.appending(
                components: "libexec", "swift", "pm", "swiftpm-xctest-helper"
            )
            if swiftCommandState.fileSystem.isFile(maybePath) {
                return maybePath
            } else {
                triedPaths.append(maybePath)
                return nil
            }
        }

        if let firstCLIArgument = CommandLine.arguments.first {
            let runningSwiftBuildPath = try AbsolutePath(validating: firstCLIArgument, relativeTo: swiftCommandState.originalWorkingDirectory)
            if let xctestHelperPath = findXCTestHelper(swiftBuildPath: runningSwiftBuildPath) {
                return xctestHelperPath
            }
        }

        // This will be true during swiftpm development or when using swift.org toolchains.
        let xcodePath = try TSCBasic.Process.checkNonZeroExit(args: "/usr/bin/xcode-select", "--print-path").spm_chomp()
        let installedSwiftBuildPath = try TSCBasic.Process.checkNonZeroExit(
            args: "/usr/bin/xcrun", "--find", "swift-build",
            environment: ["DEVELOPER_DIR": xcodePath]
        ).spm_chomp()
        if let xctestHelperPath = findXCTestHelper(swiftBuildPath: try AbsolutePath(validating: installedSwiftBuildPath)) {
            return xctestHelperPath
        }

        throw InternalError("XCTestHelper binary not found, tried \(triedPaths.map { $0.pathString }.joined(separator: ", "))")
    }

    static func getTestSuites(
        in testProducts: [BuiltTestProduct],
        swiftCommandState: SwiftCommandState,
        enableCodeCoverage: Bool,
        shouldSkipBuilding: Bool,
        experimentalTestOutput: Bool,
        sanitizers: [Sanitizer]
    ) throws -> [AbsolutePath: [TestSuite]] {
        let testSuitesByProduct = try testProducts
            .map {(
                $0.bundlePath,
                try Self.getTestSuites(
                    fromTestAt: $0.bundlePath,
                    swiftCommandState: swiftCommandState,
                    enableCodeCoverage: enableCodeCoverage,
                    shouldSkipBuilding: shouldSkipBuilding,
                    experimentalTestOutput: experimentalTestOutput,
                    sanitizers: sanitizers
                )
            )}
        return try Dictionary(throwingUniqueKeysWithValues: testSuitesByProduct)
    }

    /// Runs the corresponding tool to get tests JSON and create TestSuite array.
    /// On macOS, we use the swiftpm-xctest-helper tool bundled with swiftpm.
    /// On Linux, XCTest can dump the json using `--dump-tests-json` mode.
    ///
    /// - Parameters:
    ///     - path: Path to the XCTest bundle(macOS) or executable(Linux).
    ///
    /// - Throws: TestError, SystemError, TSCUtility.Error
    ///
    /// - Returns: Array of TestSuite
    static func getTestSuites(
        fromTestAt path: AbsolutePath,
        swiftCommandState: SwiftCommandState,
        enableCodeCoverage: Bool,
        shouldSkipBuilding: Bool,
        experimentalTestOutput: Bool,
        sanitizers: [Sanitizer]
    ) throws -> [TestSuite] {
        // Run the correct tool.
        var args = [String]()
        #if os(macOS)
        let data: String = try withTemporaryFile { tempFile in
            args = [try Self.xctestHelperPath(swiftCommandState: swiftCommandState).pathString, path.pathString, tempFile.path.pathString]
            let env = try Self.constructTestEnvironment(
                toolchain: try swiftCommandState.getTargetToolchain(),
                destinationBuildParameters: swiftCommandState.buildParametersForTest(
                    enableCodeCoverage: enableCodeCoverage,
                    shouldSkipBuilding: shouldSkipBuilding,
                    experimentalTestOutput: experimentalTestOutput,
                    library: .xctest
                ),
                sanitizers: sanitizers
            )

            try TSCBasic.Process.checkNonZeroExit(arguments: args, environment: env)
            // Read the temporary file's content.
            return try swiftCommandState.fileSystem.readFileContents(AbsolutePath(tempFile.path))
        }
        #else
        let env = try Self.constructTestEnvironment(
            toolchain: try swiftCommandState.getTargetToolchain(),
            destinationBuildParameters: swiftCommandState.buildParametersForTest(
                enableCodeCoverage: enableCodeCoverage,
                shouldSkipBuilding: shouldSkipBuilding,
                library: .xctest
            ),
            sanitizers: sanitizers
        )
        args = [path.description, "--dump-tests-json"]
        let data = try Process.checkNonZeroExit(arguments: args, environment: env)
        #endif
        // Parse json and return TestSuites.
        return try TestSuite.parse(jsonString: data, context: args.joined(separator: " "))
    }

    /// Creates the environment needed to test related tools.
    static func constructTestEnvironment(
        toolchain: UserToolchain,
        destinationBuildParameters buildParameters: BuildParameters,
        sanitizers: [Sanitizer]
    ) throws -> EnvironmentVariables {
        var env = EnvironmentVariables.process()

        // If the standard output or error stream is NOT a TTY, set the NO_COLOR
        // environment variable. This environment variable is a de facto
        // standard used to inform downstream processes not to add ANSI escape
        // codes to their output. SEE: https://www.no-color.org
        if !stdoutStream.isTTY || !stderrStream.isTTY {
            env["NO_COLOR"] = "1"
        }

        // Add the code coverage related variables.
        if buildParameters.testingParameters.enableCodeCoverage {
            // Defines the path at which the profraw files will be written on test execution.
            //
            // `%m` will create a pool of profraw files and append the data from
            // each execution in one of the files. This doesn't matter for serial
            // execution but is required when the tests are running in parallel as
            // SwiftPM repeatedly invokes the test binary with the test case name as
            // the filter.
            let codecovProfile = buildParameters.buildPath.appending(components: "codecov", "default%m.profraw")
            env["LLVM_PROFILE_FILE"] = codecovProfile.pathString
        }
        #if !os(macOS)
        #if os(Windows)
        if let location = toolchain.xctestPath {
            env.prependPath("Path", value: location.pathString)
        }
        #endif
        return env
        #else
        // Add the sdk platform path if we have it.
        if let sdkPlatformFrameworksPath = try? SwiftSDK.sdkPlatformFrameworkPaths() {
            // appending since we prefer the user setting (if set) to the one we inject
            env.appendPath("DYLD_FRAMEWORK_PATH", value: sdkPlatformFrameworksPath.fwk.pathString)
            env.appendPath("DYLD_LIBRARY_PATH", value: sdkPlatformFrameworksPath.lib.pathString)
        }

        // Fast path when no sanitizers are enabled.
        if sanitizers.isEmpty {
            return env
        }

        // Get the runtime libraries.
        var runtimes = try sanitizers.map({ sanitizer in
            return try toolchain.runtimeLibrary(for: sanitizer).pathString
        })

        // Append any existing value to the front.
        if let existingValue = env["DYLD_INSERT_LIBRARIES"], !existingValue.isEmpty {
            runtimes.insert(existingValue, at: 0)
        }

        env["DYLD_INSERT_LIBRARIES"] = runtimes.joined(separator: ":")
        return env
        #endif
    }
}

extension SwiftCommandState {
    func buildParametersForTest(
        enableCodeCoverage: Bool,
        enableTestability: Bool? = nil,
        shouldSkipBuilding: Bool = false,
        experimentalTestOutput: Bool = false,
        library: BuildParameters.Testing.Library
    ) throws -> BuildParameters {
        var parameters = try self.productsBuildParameters

        var explicitlyEnabledDiscovery = false
        var explicitlySpecifiedPath: AbsolutePath?
        if case let .entryPointExecutable(
            explicitlyEnabledDiscoveryValue,
            explicitlySpecifiedPathValue
        ) = parameters.testingParameters.testProductStyle {
            explicitlyEnabledDiscovery = explicitlyEnabledDiscoveryValue
            explicitlySpecifiedPath = explicitlySpecifiedPathValue
        }
        parameters.testingParameters = .init(
            configuration: parameters.configuration,
            targetTriple: parameters.triple,
            forceTestDiscovery: explicitlyEnabledDiscovery,
            testEntryPointPath: explicitlySpecifiedPath,
            library: library
        )

        parameters.testingParameters.enableCodeCoverage = enableCodeCoverage
        // for test commands, we normally enable building with testability
        // but we let users override this with a flag
        parameters.testingParameters.enableTestability = enableTestability ?? true
        parameters.shouldSkipBuilding = shouldSkipBuilding
        parameters.testingParameters.experimentalTestOutput = experimentalTestOutput
        return parameters
    }
}
