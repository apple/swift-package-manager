//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import class Foundation.ProcessInfo
import PackageModel
import PackageGraph

public struct BuildParameters: Encodable {
    /// Mode for the indexing-while-building feature.
    public enum IndexStoreMode: String, Encodable {
        /// Index store should be enabled.
        case on
        /// Index store should be disabled.
        case off
        /// Index store should be enabled in debug configuration.
        case auto
    }

    /// The path to the data directory.
    public var dataPath: AbsolutePath

    /// The build configuration.
    public var configuration: BuildConfiguration

    /// The toolchain.
    public var toolchain: Toolchain { _toolchain.toolchain }
    private let _toolchain: _Toolchain

    @available(*, deprecated, renamed: "triple", message: "Use separate `BuildParameters` values for host and target.")
    public var targetTriple: Triple { self.triple }

    /// The triple for which the code is built using these build parameters.
    public var triple: Triple

    /// Extra build flags.
    public var flags: BuildFlags

    /// An array of paths to search for pkg-config `.pc` files.
    public var pkgConfigDirectories: [AbsolutePath]

    /// The architectures to build for.
    // FIXME: this may be inconsistent with `targetTriple`.
    public var architectures: [String]?

    /// How many jobs should llbuild and the Swift compiler spawn
    public var workers: UInt32

    /// Which compiler sanitizers should be enabled
    public var sanitizers: EnabledSanitizers

    /// The mode to use for indexing-while-building feature.
    public var indexStoreMode: IndexStoreMode

    /// Whether to create dylibs for dynamic library products.
    public var shouldCreateDylibForDynamicProducts: Bool

    /// The current build environment.
    public var buildEnvironment: BuildEnvironment {
        BuildEnvironment(platform: currentPlatform, configuration: configuration)
    }

    /// The current platform we're building for.
    var currentPlatform: PackageModel.Platform {
        if self.triple.isDarwin() {
            switch self.triple.darwinPlatform {
            case .iOS(.catalyst):
                return .macCatalyst
            case .iOS(.device), .iOS(.simulator):
                return .iOS
            case .tvOS:
                return .tvOS
            case .watchOS:
                return .watchOS
            case .macOS, nil:
                return .macOS
            }
        } else if self.triple.isAndroid() {
            return .android
        } else if self.triple.isWASI() {
            return .wasi
        } else if self.triple.isWindows() {
            return .windows
        } else if self.triple.isOpenBSD() {
            return .openbsd
        } else {
            return .linux
        }
    }

    /// Whether the Xcode build system is used.
    public var isXcodeBuildSystemEnabled: Bool

    public var shouldSkipBuilding: Bool

    /// Build parameters related to debugging.
    public var debuggingParameters: Debugging

    /// Build parameters related to Swift Driver.
    public var driverParameters: Driver

    /// Build parameters related to linking.
    public var linkingParameters: Linking

    /// Build parameters related to output and logging.
    public var outputParameters: Output

    /// Build parameters related to testing.
    public var testingParameters: Testing

    public init(
        dataPath: AbsolutePath,
        configuration: BuildConfiguration,
        toolchain: Toolchain,
        triple: Triple? = nil,
        flags: BuildFlags,
        pkgConfigDirectories: [AbsolutePath] = [],
        architectures: [String]? = nil,
        workers: UInt32 = UInt32(ProcessInfo.processInfo.activeProcessorCount),
        shouldCreateDylibForDynamicProducts: Bool = true,
        sanitizers: EnabledSanitizers = EnabledSanitizers(),
        indexStoreMode: IndexStoreMode = .auto,
        isXcodeBuildSystemEnabled: Bool = false,
        shouldSkipBuilding: Bool = false,
        debuggingParameters: Debugging? = nil,
        driverParameters: Driver = .init(),
        linkingParameters: Linking = .init(),
        outputParameters: Output = .init(),
        testingParameters: Testing? = nil
    ) throws {
        let triple = try triple ?? .getHostTriple(usingSwiftCompiler: toolchain.swiftCompilerPath)
        self.debuggingParameters = debuggingParameters ?? .init(
            triple: triple,
            shouldEnableDebuggingEntitlement: configuration == .debug,
            omitFramePointers: nil
        )

        self.dataPath = dataPath
        self.configuration = configuration
        self._toolchain = _Toolchain(toolchain: toolchain)
        self.triple = triple
        switch self.debuggingParameters.debugInfoFormat {
        case .dwarf:
            var flags = flags
            // DWARF requires lld as link.exe expects CodeView debug info.
            self.flags = flags.merging(triple.isWindows() ? BuildFlags(
                cCompilerFlags: ["-gdwarf"],
                cxxCompilerFlags: ["-gdwarf"],
                swiftCompilerFlags: ["-g", "-use-ld=lld"],
                linkerFlags: ["-debug:dwarf"]
            ) : BuildFlags(cCompilerFlags: ["-g"], cxxCompilerFlags: ["-g"], swiftCompilerFlags: ["-g"]))
        case .codeview:
            if !triple.isWindows() {
                throw StringError("CodeView debug information is currently not supported on \(triple.osName)")
            }
            var flags = flags
            self.flags = flags.merging(BuildFlags(
                cCompilerFlags: ["-g"],
                cxxCompilerFlags: ["-g"],
                swiftCompilerFlags: ["-g", "-debug-info-format=codeview"],
                linkerFlags: ["-debug"]
            ))
        case .none:
            var flags = flags
            self.flags = flags.merging(BuildFlags(
                cCompilerFlags: ["-g0"],
                cxxCompilerFlags: ["-g0"],
                swiftCompilerFlags: ["-gnone"]
            ))
        }
        self.pkgConfigDirectories = pkgConfigDirectories
        self.architectures = architectures
        self.workers = workers
        self.shouldCreateDylibForDynamicProducts = shouldCreateDylibForDynamicProducts
        self.sanitizers = sanitizers
        self.indexStoreMode = indexStoreMode
        self.isXcodeBuildSystemEnabled = isXcodeBuildSystemEnabled
        self.shouldSkipBuilding = shouldSkipBuilding
        self.driverParameters = driverParameters
        self.linkingParameters = linkingParameters
        self.outputParameters = outputParameters
        self.testingParameters = testingParameters ?? .init(configuration: configuration, targetTriple: triple)
    }

    /// The path to the build directory (inside the data directory).
    public var buildPath: AbsolutePath {
        if isXcodeBuildSystemEnabled {
            return dataPath.appending(components: "Products", configuration.dirname.capitalized)
        } else {
            return dataPath.appending(component: configuration.dirname)
        }
    }

    /// The path to the index store directory.
    public var indexStore: AbsolutePath {
        assert(indexStoreMode != .off, "index store is disabled")
        return buildPath.appending(components: "index", "store")
    }

    /// The path to the code coverage directory.
    public var codeCovPath: AbsolutePath {
        return buildPath.appending("codecov")
    }

    /// The path to the code coverage profdata file.
    public var codeCovDataFile: AbsolutePath {
        return codeCovPath.appending("default.profdata")
    }

    public var llbuildManifest: AbsolutePath {
        // FIXME: this path isn't specific to `BuildParameters` due to its use of `..`
        // FIXME: it should be calculated in a different place
        return dataPath.appending(components: "..", configuration.dirname + ".yaml")
    }

    public var pifManifest: AbsolutePath {
        // FIXME: this path isn't specific to `BuildParameters` due to its use of `..`
        // FIXME: it should be calculated in a different place
        return dataPath.appending(components: "..", "manifest.pif")
    }

    public var buildDescriptionPath: AbsolutePath {
        // FIXME: this path isn't specific to `BuildParameters`, should be moved one directory level higher
        return buildPath.appending(components: "description.json")
    }

    public var testOutputPath: AbsolutePath {
        return buildPath.appending(component: "testOutput.txt")
    }
    /// Returns the path to the binary of a product for the current build parameters.
    public func binaryPath(for product: ResolvedProduct) throws -> AbsolutePath {
        return try buildPath.appending(binaryRelativePath(for: product))
    }

    /// Returns the path to the dynamic library of a product for the current build parameters.
    func potentialDynamicLibraryPath(for product: ResolvedProduct) throws -> RelativePath {
        try RelativePath(validating: "\(self.triple.dynamicLibraryPrefix)\(product.name)\(self.triple.dynamicLibraryExtension)")
    }

    /// Returns the path to the binary of a product for the current build parameters, relative to the build directory.
    public func binaryRelativePath(for product: ResolvedProduct) throws -> RelativePath {
        let potentialExecutablePath = try RelativePath(validating: "\(product.name)\(self.suffix(triple: product.buildTriple))\(self.triple.executableExtension)")

        switch product.type {
        case .executable, .snippet:
            return potentialExecutablePath
        case .library(.static):
            return try RelativePath(validating: "lib\(product.name)\(self.triple.staticLibraryExtension)")
        case .library(.dynamic):
            return try potentialDynamicLibraryPath(for: product)
        case .library(.automatic), .plugin:
            fatalError()
        case .test:
            guard !self.triple.isWasm else {
                return try RelativePath(validating: "\(product.name).wasm")
            }
            switch testingParameters.library {
            case .xctest:
                let base = "\(product.name).xctest"
                if self.triple.isDarwin() {
                    return try RelativePath(validating: "\(base)/Contents/MacOS/\(product.name)")
                } else {
                    return try RelativePath(validating: base)
                }
            case .swiftTesting:
                return try RelativePath(validating: "\(product.name).swift-testing")
            }
        case .macro:
            #if BUILD_MACROS_AS_DYLIBS
            return try potentialDynamicLibraryPath(for: product)
            #else
            return potentialExecutablePath
            #endif
        }
    }
}

/// A shim struct for toolchain so we can encode it without having to write encode(to:) for
/// entire BuildParameters by hand.
private struct _Toolchain: Encodable {
    let toolchain: Toolchain

    enum CodingKeys: String, CodingKey {
        case swiftCompiler
        case clangCompiler
        case extraCCFlags
        case extraSwiftCFlags
        case extraCPPFlags
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolchain.swiftCompilerPath, forKey: .swiftCompiler)
        try container.encode(toolchain.getClangCompiler(), forKey: .clangCompiler)

        try container.encode(toolchain.extraFlags.cCompilerFlags, forKey: .extraCCFlags)
        // Maintaining `extraCPPFlags` key for compatibility with older encoding.
        try container.encode(toolchain.extraFlags.cxxCompilerFlags, forKey: .extraCPPFlags)
        try container.encode(toolchain.extraFlags.swiftCompilerFlags, forKey: .extraSwiftCFlags)
        try container.encode(toolchain.swiftCompilerPath, forKey: .swiftCompiler)
    }
}

extension BuildParameters {
    /// Whether to build Swift code with whole module optimization (WMO)
    /// enabled.
    public var useWholeModuleOptimization: Bool {
        switch configuration {
        case .debug:
            return false

        case .release:
            return true
        }
    }
}

extension Triple {
    public var supportsTestSummary: Bool {
        return !self.isWindows()
    }
}

extension BuildParameters {
    /// Suffix appended to build manifest nodes to distinguish nodes created for tools from nodes created for
    /// end products, i.e. nodes for host vs target triples.
    package func suffix(triple: BuildTriple) -> String {
        if triple == .tools { "-tool" } else { "" }
    }
}
