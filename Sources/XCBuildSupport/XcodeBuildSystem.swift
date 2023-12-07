//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Dispatch
import class Foundation.JSONEncoder
import PackageGraph
import PackageModel
import SPMBuildCore

import protocol TSCBasic.OutputByteStream
import class TSCBasic.Process
import enum TSCBasic.ProcessEnv
import func TSCBasic.withTemporaryFile
import func TSCBasic.memoize

import class TSCUtility.MultiLinePercentProgressAnimation
import enum TSCUtility.Diagnostics
import protocol TSCUtility.ProgressAnimationProtocol

public final class XcodeBuildSystem: SPMBuildCore.BuildSystem {
    private let buildParameters: BuildParameters
    private let packageGraphLoader: () throws -> PackageGraph
    private let logLevel: Basics.Diagnostic.Severity
    private let xcbuildPath: AbsolutePath
    private var packageGraph: PackageGraph?
    private var pifBuilder: PIFBuilder?
    private let fileSystem: FileSystem
    private let observabilityScope: ObservabilityScope

    /// The output stream for the build delegate.
    private let outputStream: OutputByteStream

    /// The delegate used by the build system.
    public weak var delegate: SPMBuildCore.BuildSystemDelegate?

    public var builtTestProducts: [BuiltTestProduct] {
        do {
            let graph = try getPackageGraph()

            var builtProducts: [BuiltTestProduct] = []

            for package in graph.rootPackages {
                for product in package.products where product.type == .test {
                    let binaryPath = try buildParameters.binaryPath(for: product)
                    builtProducts.append(
                        BuiltTestProduct(
                            productName: product.name,
                            binaryPath: binaryPath,
                            packagePath: package.path,
                            library: buildParameters.testingParameters.library
                        )
                    )
                }
            }

            return builtProducts
        } catch {
            self.observabilityScope.emit(error)
            return []
        }
    }

    public var buildPlan: SPMBuildCore.BuildPlan {
        get throws {
            throw StringError("XCBuild does not provide a build plan")
        }
    }

    public init(
        buildParameters: BuildParameters,
        packageGraphLoader: @escaping () throws -> PackageGraph,
        outputStream: OutputByteStream,
        logLevel: Basics.Diagnostic.Severity,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws {
        self.buildParameters = buildParameters
        self.packageGraphLoader = packageGraphLoader
        self.outputStream = outputStream
        self.logLevel = logLevel
        self.fileSystem = fileSystem
        self.observabilityScope = observabilityScope.makeChildScope(description: "Xcode Build System")

        if let xcbuildTool = ProcessEnv.vars["XCBUILD_TOOL"] {
            xcbuildPath = try AbsolutePath(validating: xcbuildTool)
        } else {
            let xcodeSelectOutput = try TSCBasic.Process.popen(args: "xcode-select", "-p").utf8Output().spm_chomp()
            let xcodeDirectory = try AbsolutePath(validating: xcodeSelectOutput)
            xcbuildPath = try AbsolutePath(validating: "../SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild", relativeTo: xcodeDirectory)
        }

        guard fileSystem.exists(xcbuildPath) else {
            throw StringError("xcbuild executable at '\(xcbuildPath)' does not exist or is not executable")
        }
    }

    public func build(subset: BuildSubset) throws {
        guard !buildParameters.shouldSkipBuilding else {
            return
        }

        let pifBuilder = try getPIFBuilder()
        let pif = try pifBuilder.generatePIF()
        try self.fileSystem.writeIfChanged(path: buildParameters.pifManifest, string: pif)

        var arguments = [
            xcbuildPath.pathString,
            "build",
            buildParameters.pifManifest.pathString,
            "--configuration",
            buildParameters.configuration.xcbuildName,
            "--derivedDataPath",
            buildParameters.dataPath.pathString,
            "--target",
            subset.pifTargetName
        ]

        let buildParamsFile: AbsolutePath?
        // Do not generate a build parameters file if a custom one has been passed.
        if let flags = buildParameters.flags.xcbuildFlags, !flags.contains("--buildParametersFile") {
            buildParamsFile = try createBuildParametersFile()
            if let buildParamsFile {
                arguments += ["--buildParametersFile", buildParamsFile.pathString]
            }
        } else {
            buildParamsFile = nil
        }

        if let flags = buildParameters.flags.xcbuildFlags {
            arguments += flags
        }

        let delegate = createBuildDelegate()
        var hasStdout = false
        var stdoutBuffer: [UInt8] = []
        var stderrBuffer: [UInt8] = []
        let redirection: TSCBasic.Process.OutputRedirection = .stream(stdout: { bytes in
            hasStdout = hasStdout || !bytes.isEmpty
            delegate.parse(bytes: bytes)

            if !delegate.didParseAnyOutput {
                stdoutBuffer.append(contentsOf: bytes)
            }
        }, stderr: { bytes in
            stderrBuffer.append(contentsOf: bytes)
        })

        // We need to sanitize the environment we are passing to XCBuild because we could otherwise interfere with its linked dependencies e.g. when we have a custom swift-driver dynamic library in the path.
        var sanitizedEnvironment = ProcessEnv.vars
        sanitizedEnvironment["DYLD_LIBRARY_PATH"] = nil

        let process = TSCBasic.Process(arguments: arguments, environment: sanitizedEnvironment, outputRedirection: redirection)
        try process.launch()
        let result = try process.waitUntilExit()

        if let buildParamsFile {
            try? self.fileSystem.removeFileTree(buildParamsFile)
        }

        guard result.exitStatus == .terminated(code: 0) else {
            if hasStdout {
                if !delegate.didParseAnyOutput {
                    self.observabilityScope.emit(error: String(decoding: stdoutBuffer, as: UTF8.self))
                }
            } else {
                if !stderrBuffer.isEmpty {
                    self.observabilityScope.emit(error: String(decoding: stderrBuffer, as: UTF8.self))
                } else {
                    self.observabilityScope.emit(error: "Unknown error: stdout and stderr are empty")
                }
            }

            throw Diagnostics.fatalError
        }
    }

    func createBuildParametersFile() throws -> AbsolutePath {
        // Generate the run destination parameters.
        let runDestination = XCBBuildParameters.RunDestination(
            platform: "macosx",
            sdk: "macosx",
            sdkVariant: nil,
            targetArchitecture: buildParameters.targetTriple.archName,
            supportedArchitectures: [],
            disableOnlyActiveArch: true
        )

        // Generate a table of any overriding build settings.
        var settings: [String: String] = [:]
        // An error with determining the override should not be fatal here.
        settings["CC"] = try? buildParameters.toolchain.getClangCompiler().pathString
        // Always specify the path of the effective Swift compiler, which was determined in the same way as for the native build system.
        settings["SWIFT_EXEC"] = buildParameters.toolchain.swiftCompilerPath.pathString
        settings["LIBRARY_SEARCH_PATHS"] = "$(inherited) \(try buildParameters.toolchain.toolchainLibDir.pathString)"
        settings["OTHER_CFLAGS"] = (
            ["$(inherited)"]
            + buildParameters.toolchain.extraFlags.cCompilerFlags.map { $0.spm_shellEscaped() }
            + buildParameters.flags.cCompilerFlags.map { $0.spm_shellEscaped() }
        ).joined(separator: " ")
        settings["OTHER_CPLUSPLUSFLAGS"] = (
            ["$(inherited)"]
            + buildParameters.toolchain.extraFlags.cxxCompilerFlags.map { $0.spm_shellEscaped() }
            + buildParameters.flags.cxxCompilerFlags.map { $0.spm_shellEscaped() }
        ).joined(separator: " ")
        settings["OTHER_SWIFT_FLAGS"] = (
            ["$(inherited)"]
            + buildParameters.toolchain.extraFlags.swiftCompilerFlags.map { $0.spm_shellEscaped() }
            + buildParameters.flags.swiftCompilerFlags.map { $0.spm_shellEscaped() }
        ).joined(separator: " ")
        settings["OTHER_LDFLAGS"] = (
            ["$(inherited)"]
            + buildParameters.toolchain.extraFlags.linkerFlags.map { $0.spm_shellEscaped() }
            + buildParameters.flags.linkerFlags.map { $0.spm_shellEscaped() }
        ).joined(separator: " ")

        // Optionally also set the list of architectures to build for.
        if let architectures = buildParameters.architectures, !architectures.isEmpty {
            settings["ARCHS"] = architectures.joined(separator: " ")
        }

        // Generate the build parameters.
        let params = XCBBuildParameters(
            configurationName: buildParameters.configuration.xcbuildName,
            overrides: .init(synthesized: .init(table: settings)),
            activeRunDestination: runDestination
        )

        // Write out the parameters as a JSON file, and return the path.
        let encoder = JSONEncoder.makeWithDefaults()
        let data = try encoder.encode(params)
        let file = try withTemporaryFile(deleteOnClose: false) { AbsolutePath($0.path) }
        try self.fileSystem.writeFileContents(file, data: data)
        return file
    }

    public func cancel(deadline: DispatchTime) throws {
    }

    /// Returns a new instance of `XCBuildDelegate` for a build operation.
    private func createBuildDelegate() -> XCBuildDelegate {
        let progressAnimation: ProgressAnimationProtocol = self.logLevel.isVerbose
            ? VerboseProgressAnimation(stream: self.outputStream)
            : MultiLinePercentProgressAnimation(stream: self.outputStream, header: "")
        let delegate = XCBuildDelegate(
            buildSystem: self,
            outputStream: self.outputStream,
            progressAnimation: progressAnimation,
            logLevel: self.logLevel,
            observabilityScope: self.observabilityScope
        )
        return delegate
    }

    private func getPIFBuilder() throws -> PIFBuilder {
        try memoize(to: &pifBuilder) {
            let graph = try getPackageGraph()
            let pifBuilder = PIFBuilder(
                graph: graph,
                parameters: .init(buildParameters),
                fileSystem: self.fileSystem,
                observabilityScope: self.observabilityScope
            )
            return pifBuilder
        }
    }

    /// Returns the package graph using the graph loader closure.
    ///
    /// First access will cache the graph.
    public func getPackageGraph() throws -> PackageGraph {
        try memoize(to: &packageGraph) {
            try packageGraphLoader()
        }
    }
}

struct XCBBuildParameters: Encodable {
    struct RunDestination: Encodable {
        var platform: String
        var sdk: String
        var sdkVariant: String?
        var targetArchitecture: String
        var supportedArchitectures: [String]
        var disableOnlyActiveArch: Bool
    }

    struct XCBSettingsTable: Encodable {
        var table: [String: String]
    }

    struct SettingsOverride: Encodable {
        var synthesized: XCBSettingsTable? = nil
    }

    var configurationName: String
    var overrides: SettingsOverride
    var activeRunDestination: RunDestination
}

extension BuildConfiguration {
    public var xcbuildName: String {
        switch self {
            case .debug: return "Debug"
            case .release: return "Release"
        }
    }
}

extension PIFBuilderParameters {
    public init(_ buildParameters: BuildParameters) {
        self.init(
            enableTestability: buildParameters.testingParameters.enableTestability,
            shouldCreateDylibForDynamicProducts: buildParameters.shouldCreateDylibForDynamicProducts,
            toolchainLibDir: (try? buildParameters.toolchain.toolchainLibDir) ?? .root,
            pkgConfigDirectories: buildParameters.pkgConfigDirectories,
            sdkRootPath: buildParameters.toolchain.sdkRootPath
        )
    }
}

extension BuildSubset {
    var pifTargetName: String {
        switch self {
        case .product(let name):
            return PackagePIFProjectBuilder.targetName(for: name)
        case .target(let name):
            return name
        case .allExcludingTests:
            return PIFBuilder.allExcludingTestsTargetName
        case .allIncludingTests:
            return PIFBuilder.allIncludingTestsTargetName
        }
    }
}

extension Basics.Diagnostic.Severity {
    var isVerbose: Bool {
        return self <= .info
    }
}
