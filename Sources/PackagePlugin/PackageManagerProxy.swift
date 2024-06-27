//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

/// Provides specialized information and services from the Swift Package Manager
/// or an IDE that supports Swift Packages. Different plugin hosts implement the
/// functionality in whatever way is appropriate for them, but should preserve
/// the same semantics described here.
public struct PackageManager {
    /// Performs a build of all or a subset of products and targets in a package.
    ///
    /// Any errors encountered during the build are reported in the build result,
    /// as is the log of the build commands that were run. This method throws an
    /// error if the input parameters are invalid or in case the build cannot be
    /// started.
    ///
    /// The SwiftPM CLI or any IDE that supports packages may show the progress
    /// of the build as it happens.
    public func build(
        _ subset: BuildSubset,
        parameters: BuildParameters
    ) throws -> BuildResult {
        // Ask the plugin host to build the specified products and targets, and wait for a response.
        // FIXME: We'll want to make this asynchronous when there is back deployment support for it.
        try sendMessageAndWaitForReply(.buildOperationRequest(subset: .init(subset), parameters: .init(parameters))) {
            guard case .buildOperationResponse(let result) = $0 else { return nil }
            return .init(result)
        }
    }

    /// Specifies a subset of products and targets of a package to build.
    public enum BuildSubset {
        /// Represents the subset consisting of all products and of either all
        /// targets or (if `includingTests` is false) just non-test targets.
        case all(includingTests: Bool)

        /// Represents the product with the specified name.
        case product(String)

        /// Represents the target with the specified name.
        case target(String)
    }

    /// Parameters and options to apply during a build.
    public struct BuildParameters {
        /// Whether to build for debug or release.
        public var configuration: BuildConfiguration

        /// Controls the amount of detail in the log returned in the build result.
        public var logging: BuildLogVerbosity

        /// Whether to print build logs to the console
        public var echoLogs: Bool

        /// Additional flags to pass to all C compiler invocations.
        public var otherCFlags: [String] = []

        /// Additional flags to pass to all C++ compiler invocations.
        public var otherCxxFlags: [String] = []

        /// Additional flags to pass to all Swift compiler invocations.
        public var otherSwiftcFlags: [String] = []

        /// Additional flags to pass to all linker invocations.
        public var otherLinkerFlags: [String] = []

        public init(
            configuration: BuildConfiguration = .debug,
            logging: BuildLogVerbosity = .concise,
            echoLogs: Bool = false
        ) {
            self.configuration = configuration
            self.logging = logging
            self.echoLogs = echoLogs
        }
    }

    /// Represents an overall purpose of the build, which affects such things
    /// as optimization and generation of debug symbols.
    public enum BuildConfiguration: String {
        case debug, release, inherit
    }

    /// Represents the amount of detail in a build log.
    public enum BuildLogVerbosity: String {
        case concise, verbose, debug
    }

    /// Represents the results of running a build.
    public struct BuildResult {
        /// Whether the build succeeded or failed.
        public var succeeded: Bool

        /// Log output (the verbatim text in the initial proposal).
        public var logText: String

        /// The artifacts built from the products in the package. Intermediates
        /// such as object files produced from individual targets are not listed.
        public var builtArtifacts: [BuiltArtifact]

        /// Represents a single artifact produced during a build.
        public struct BuiltArtifact {
            /// Full path of the built artifact in the local file system.
            @available(_PackageDescription, deprecated: 6.0, renamed: "url")
            public var path: Path {
                Path(url: self.url)
            }

            /// Full path of the built artifact in the local file system.
            @available(_PackageDescription, introduced: 6.0)
            public var url: URL

            /// The kind of artifact that was built.
            public var kind: Kind

            /// Represents the kind of artifact that was built. The specific file
            /// formats may vary from platform to platform — for example, on macOS
            /// a dynamic library may in fact be built as a framework.
            public enum Kind: String {
                case executable, dynamicLibrary, staticLibrary
            }
        }
    }

    /// Runs all or a specified subset of the unit tests of the package, after
    /// an incremental build if necessary (the same as `swift test` does).
    ///
    /// Any test failures are reported in the test result. This method throws an
    /// error if the input parameters are invalid or in case the test cannot be
    /// started.
    ///
    /// The SwiftPM CLI or any IDE that supports packages may show the progress
    /// of the tests as they happen.
    public func test(
        _ subset: TestSubset,
        parameters: TestParameters
    ) throws -> TestResult {
        // Ask the plugin host to run the specified tests, and wait for a response.
        // FIXME: We'll want to make this asynchronous when there is back deployment support for it.
        try sendMessageAndWaitForReply(.testOperationRequest(subset: .init(subset), parameters: .init(parameters))) {
            guard case .testOperationResponse(let result) = $0 else { return nil }
            return .init(result)
        }
    }

    /// Specifies what tests in a package to run.
    public enum TestSubset {
        /// Represents all tests in the package.
        case all

        /// Represents one or more tests filtered by regular expression, with the
        /// format <test-target>.<test-case> or <test-target>.<test-case>/<test>.
        /// This is the same as the `--filter` option of `swift test`.
        case filtered([String])
    }

    /// Parameters that control how the tests are run.
    public struct TestParameters {
        /// Whether to collect code coverage information while running the tests.
        public var enableCodeCoverage: Bool

        public init(enableCodeCoverage: Bool = false) {
            self.enableCodeCoverage = enableCodeCoverage
        }
    }

    /// Represents the result of running unit tests.
    public struct TestResult {
        /// Whether the test run succeeded or failed.
        public var succeeded: Bool

        /// Results for all the test targets that were run (filtered based on
        /// the input subset passed when running the test).
        public var testTargets: [TestTarget]

        /// Path of a generated `.profdata` file suitable for processing using
        /// `llvm-cov`, if `enableCodeCoverage` was set in the test parameters.
        @available(_PackageDescription, deprecated: 6.0, renamed: "codeCoverageDataFileURL")
        public var codeCoverageDataFile: Path? {
            self.codeCoverageDataFileURL.map { Path(url: $0) }
        }

        /// Path of a generated `.profdata` file suitable for processing using
        /// `llvm-cov`, if `enableCodeCoverage` was set in the test parameters.
        @available(_PackageDescription, introduced: 6.0)
        public var codeCoverageDataFileURL: URL?

        /// Represents the results of running some or all of the tests in a
        /// single test target.
        public struct TestTarget {
            public var name: String
            public var testCases: [TestCase]

            /// Represents the results of running some or all of the tests in
            /// a single test case.
            public struct TestCase {
                public var name: String
                public var tests: [Test]

                /// Represents the results of running a single test.
                public struct Test {
                    public var name: String
                    public var result: Result
                    public var duration: Double

                    /// Represents the result of running a single test.
                    public enum Result: String {
                        case succeeded, skipped, failed
                    }
                }
            }
        }
    }

    /// Return a directory containing symbol graph files for the given target
    /// and options. If the symbol graphs need to be created or updated first,
    /// they will be. SwiftPM or an IDE may generate these symbol graph files
    /// in any way it sees fit.
    public func getSymbolGraph(
        for target: Target,
        options: SymbolGraphOptions
    ) throws -> SymbolGraphResult {
        // Ask the plugin host for symbol graph information for the target, and wait for a response.
        // FIXME: We'll want to make this asynchronous when there is back deployment support for it.
        try sendMessageAndWaitForReply(.symbolGraphRequest(targetName: target.name, options: .init(options))) {
            guard case .symbolGraphResponse(let result) = $0 else { return nil }
            return .init(result)
        }
    }

    /// Represents options for symbol graph generation.
    public struct SymbolGraphOptions {
        /// The symbol graph will include symbols at this access level and higher.
        public var minimumAccessLevel: AccessLevel

        /// Represents a Swift access level.
        public enum AccessLevel: String, CaseIterable {
            case `private`, `fileprivate`, `internal`, `public`, open
        }

        /// Whether to include synthesized members.
        public var includeSynthesized: Bool

        /// Whether to include symbols marked as SPI.
        public var includeSPI: Bool

        /// Whether to emit symbols for extensions to external types.
        public var emitExtensionBlocks: Bool

        public init(
            minimumAccessLevel: AccessLevel = .public,
            includeSynthesized: Bool = false,
            includeSPI: Bool = false,
            emitExtensionBlocks: Bool = false
        ) {
            self.minimumAccessLevel = minimumAccessLevel
            self.includeSynthesized = includeSynthesized
            self.includeSPI = includeSPI
            self.emitExtensionBlocks = emitExtensionBlocks
        }
    }

    /// Represents the result of symbol graph generation.
    public struct SymbolGraphResult {
        /// The directory that contains the symbol graph files for the target.
        @available(_PackageDescription, deprecated: 6.0, renamed: "directoryURL")
        public var directoryPath: Path {
            Path(url: self.directoryURL)
        }

        /// The directory that contains the symbol graph files for the target.
        @available(_PackageDescription, introduced: 6.0)
        public var directoryURL: URL
    }
}

extension PackageManager {
    /// Private helper function that sends a message to the host and waits for a reply. The reply handler should return
    /// `nil` for any reply message it doesn't recognize.
    private func sendMessageAndWaitForReply<T>(
        _ message: PluginToHostMessage,
        replyHandler: (HostToPluginMessage) -> T?
    ) throws -> T {
        try pluginHostConnection.sendMessage(message)
        guard let reply = try pluginHostConnection.waitForNextMessage() else {
            throw PackageManagerProxyError.unspecified("internal error: unexpected lack of response message")
        }
        if case .errorResponse(let message) = reply {
            throw PackageManagerProxyError.unspecified(message)
        }
        if let result = replyHandler(reply) {
            return result
        }
        throw PackageManagerProxyError.unspecified("internal error: unexpected response message \(message)")
    }
}

public enum PackageManagerProxyError: Error {
    /// Indicates that the functionality isn't implemented in the plugin host.
    case unimplemented(_ message: String)

    /// An unspecified other kind of error from the Package Manager proxy.
    case unspecified(_ message: String)
}

extension PluginToHostMessage.BuildSubset {
    fileprivate init(_ subset: PackageManager.BuildSubset) {
        switch subset {
        case .all(let includingTests):
            self = .all(includingTests: includingTests)
        case .product(let name):
            self = .product(name)
        case .target(let name):
            self = .target(name)
        }
    }
}

extension PluginToHostMessage.BuildParameters {
    fileprivate init(_ parameters: PackageManager.BuildParameters) {
        self.configuration = .init(parameters.configuration)
        self.logging = .init(parameters.logging)
        self.echoLogs = parameters.echoLogs
        self.otherCFlags = parameters.otherCFlags
        self.otherCxxFlags = parameters.otherCxxFlags
        self.otherSwiftcFlags = parameters.otherSwiftcFlags
        self.otherLinkerFlags = parameters.otherLinkerFlags
    }
}

extension PluginToHostMessage.BuildParameters.Configuration {
    fileprivate init(_ configuration: PackageManager.BuildConfiguration) {
        switch configuration {
        case .debug:
            self = .debug
        case .release:
            self = .release
        case .inherit:
            self = .inherit
        }
    }
}

extension PluginToHostMessage.BuildParameters.LogVerbosity {
    fileprivate init(_ verbosity: PackageManager.BuildLogVerbosity) {
        switch verbosity {
        case .concise:
            self = .concise
        case .verbose:
            self = .verbose
        case .debug:
            self = .debug
        }
    }
}

extension PackageManager.BuildResult {
    fileprivate init(_ result: HostToPluginMessage.BuildResult) {
        self.succeeded = result.succeeded
        self.logText = result.logText
        self.builtArtifacts = result.builtArtifacts.map { .init($0) }
    }
}

extension PackageManager.BuildResult.BuiltArtifact {
    fileprivate init(_ artifact: HostToPluginMessage.BuildResult.BuiltArtifact) {
        self.kind = .init(artifact.kind)
        self.url = artifact.path
    }
}

extension PackageManager.BuildResult.BuiltArtifact.Kind {
    fileprivate init(_ kind: HostToPluginMessage.BuildResult.BuiltArtifact.Kind) {
        switch kind {
        case .executable:
            self = .executable
        case .dynamicLibrary:
            self = .dynamicLibrary
        case .staticLibrary:
            self = .staticLibrary
        }
    }
}

extension PluginToHostMessage.TestSubset {
    fileprivate init(_ subset: PackageManager.TestSubset) {
        switch subset {
        case .all:
            self = .all
        case .filtered(let regexes):
            self = .filtered(regexes)
        }
    }
}

extension PluginToHostMessage.TestParameters {
    fileprivate init(_ parameters: PackageManager.TestParameters) {
        self.enableCodeCoverage = parameters.enableCodeCoverage
    }
}

extension PackageManager.TestResult {
    fileprivate init(_ result: HostToPluginMessage.TestResult) {
        self.succeeded = result.succeeded
        self.testTargets = result.testTargets.map { .init($0) }
        self.codeCoverageDataFileURL = result.codeCoverageDataFile.map { URL(fileURLWithPath: $0) }
    }
}

extension PackageManager.TestResult.TestTarget {
    fileprivate init(_ testTarget: HostToPluginMessage.TestResult.TestTarget) {
        self.name = testTarget.name
        self.testCases = testTarget.testCases.map { .init($0) }
    }
}

extension PackageManager.TestResult.TestTarget.TestCase {
    fileprivate init(_ testCase: HostToPluginMessage.TestResult.TestTarget.TestCase) {
        self.name = testCase.name
        self.tests = testCase.tests.map { .init($0) }
    }
}

extension PackageManager.TestResult.TestTarget.TestCase.Test {
    fileprivate init(_ test: HostToPluginMessage.TestResult.TestTarget.TestCase.Test) {
        self.name = test.name
        self.result = .init(test.result)
        self.duration = test.duration
    }
}

extension PackageManager.TestResult.TestTarget.TestCase.Test.Result {
    fileprivate init(_ result: HostToPluginMessage.TestResult.TestTarget.TestCase.Test.Result) {
        switch result {
        case .succeeded:
            self = .succeeded
        case .skipped:
            self = .skipped
        case .failed:
            self = .failed
        }
    }
}

extension PluginToHostMessage.SymbolGraphOptions {
    fileprivate init(_ options: PackageManager.SymbolGraphOptions) {
        self.minimumAccessLevel = .init(options.minimumAccessLevel)
        self.includeSynthesized = options.includeSynthesized
        self.includeSPI = options.includeSPI
        self.emitExtensionBlocks = options.emitExtensionBlocks
    }
}

extension PluginToHostMessage.SymbolGraphOptions.AccessLevel {
    fileprivate init(_ accessLevel: PackageManager.SymbolGraphOptions.AccessLevel) {
        switch accessLevel {
        case .private:
            self = .private
        case .fileprivate:
            self = .fileprivate
        case .internal:
            self = .internal
        case .public:
            self = .public
        case .open:
            self = .open
        }
    }
}

extension PackageManager.SymbolGraphResult {
    fileprivate init(_ result: HostToPluginMessage.SymbolGraphResult) {
        self.directoryURL = result.directoryPath
    }
}
