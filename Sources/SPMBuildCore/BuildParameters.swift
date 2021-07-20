/*
 This source file is part of the Swift.org open source project

 Copyright 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import class Foundation.ProcessInfo

import TSCBasic
import TSCUtility
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

    /// Represents the debugging strategy.
    ///
    /// Swift binaries requires the swiftmodule files in order for lldb to work.
    /// On Darwin, linker can directly take the swiftmodule file path using the
    /// -add_ast_path flag. On other platforms, we convert the swiftmodule into
    /// an object file using Swift's modulewrap tool.
    public enum DebuggingStrategy {
        case swiftAST
        case modulewrap
    }

    /// Represents the test discovery strategy.
    public enum TestDiscoveryStrategy: Encodable {
        // Rely on objective C runtime
        case objectiveC
        // Use a test-manifest that lists the tests
        // generate: Whether test-manifest generation is forced
        //           This flag is or backwards compatibility, remove with --enable-test-discovery
        case manifest(generate: Bool)

        public enum DiscriminatorKeys: String, Codable {
            case objectiveC
            case manifest
        }

        public enum CodingKeys: CodingKey {
            case _case
            case generate
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .objectiveC:
                try container.encode(DiscriminatorKeys.objectiveC, forKey: ._case)
            case .manifest(let generate):
                try container.encode(DiscriminatorKeys.manifest, forKey: ._case)
                try container.encode(generate, forKey: .generate)
            }
        }
    }

    /// The path to the data directory.
    public var dataPath: AbsolutePath

    /// The build configuration.
    public var configuration: BuildConfiguration

    /// The toolchain.
    public var toolchain: Toolchain { _toolchain.toolchain }
    private let _toolchain: _Toolchain

    /// Host triple.
    public var hostTriple: Triple

    /// Destination triple.
    public var triple: Triple

    /// The architectures to build for.
    public var archs: [String]

    /// Extra build flags.
    public var flags: BuildFlags

    /// The tools version to use.
    public var toolsVersion: ToolsVersion

    /// How many jobs should llbuild and the Swift compiler spawn
    public var jobs: UInt32

    /// If should link the Swift stdlib statically.
    public var shouldLinkStaticSwiftStdlib: Bool

    /// Which compiler sanitizers should be enabled
    public var sanitizers: EnabledSanitizers

    /// If should enable llbuild manifest caching.
    public var shouldEnableManifestCaching: Bool

    /// The mode to use for indexing-while-building feature.
    public var indexStoreMode: IndexStoreMode

    /// Whether to enable code coverage.
    public var enableCodeCoverage: Bool

    /// Whether to enable generation of `.swiftinterface` files alongside
    /// `.swiftmodule`s.
    public var enableParseableModuleInterfaces: Bool

    /// Emit Swift module separately from object files. This can enable more parallelism
    /// since downstream targets can begin compiling without waiting for the entire
    /// module to finish building.
    public var emitSwiftModuleSeparately: Bool

    /// Whether to use the integrated Swift driver rather than shelling out
    /// to a separate process.
    public var useIntegratedSwiftDriver: Bool

    /// Whether to use the explicit module build flow (with the integrated driver)
    public var useExplicitModuleBuild: Bool

    /// A flag that inidcates this build should skip checking whether targets only import
    /// their explicitly-declared dependencies
    public var disableExplicitTargetDependencyImportChecking: Bool

    /// Whether to output a graphviz file visualization of the combined job graph for all targets
    public var printManifestGraphviz: Bool

    /// Whether to create dylibs for dynamic library products.
    public var shouldCreateDylibForDynamicProducts: Bool

    /// The current build environment.
    public var buildEnvironment: BuildEnvironment {
        BuildEnvironment(platform: currentPlatform, configuration: configuration)
    }

    /// The current platform we're building for.
    var currentPlatform: PackageModel.Platform {
        if self.triple.isDarwin() {
            return .macOS
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

    /// Extra arguments to pass when using xcbuild.
    public var xcbuildFlags: [String]
        
    // Whether building for testability is enabled.
    public var enableTestability: Bool
    
    // What strategy to use to discover tests
    public var testDiscoveryStrategy: TestDiscoveryStrategy

    public init(
        dataPath: AbsolutePath,
        configuration: BuildConfiguration,
        toolchain: Toolchain,
        hostTriple: Triple? = nil,
        destinationTriple: Triple? = nil,
        archs: [String] = [],
        flags: BuildFlags,
        xcbuildFlags: [String] = [],
        toolsVersion: ToolsVersion = ToolsVersion.currentToolsVersion,
        jobs: UInt32 = UInt32(ProcessInfo.processInfo.activeProcessorCount),
        shouldLinkStaticSwiftStdlib: Bool = false,
        shouldEnableManifestCaching: Bool = false,
        shouldCreateDylibForDynamicProducts: Bool = true,
        sanitizers: EnabledSanitizers = EnabledSanitizers(),
        enableCodeCoverage: Bool = false,
        indexStoreMode: IndexStoreMode = .auto,
        enableParseableModuleInterfaces: Bool = false,
        emitSwiftModuleSeparately: Bool = false,
        useIntegratedSwiftDriver: Bool = false,
        useExplicitModuleBuild: Bool = false,
        isXcodeBuildSystemEnabled: Bool = false,
        printManifestGraphviz: Bool = false,
        enableTestability: Bool? = nil,
        forceTestDiscovery: Bool = false,
        disableExplicitTargetDependencyImportChecking: Bool = false
    ) {
        let triple = destinationTriple ?? .getHostTriple(usingSwiftCompiler: toolchain.swiftCompiler)

        self.dataPath = dataPath
        self.configuration = configuration
        self._toolchain = _Toolchain(toolchain: toolchain)
        self.hostTriple = hostTriple ?? .getHostTriple(usingSwiftCompiler: toolchain.swiftCompiler)
        self.triple = triple
        self.archs = archs
        self.flags = flags
        self.xcbuildFlags = xcbuildFlags
        self.toolsVersion = toolsVersion
        self.jobs = jobs
        self.shouldLinkStaticSwiftStdlib = shouldLinkStaticSwiftStdlib
        self.shouldEnableManifestCaching = shouldEnableManifestCaching
        self.shouldCreateDylibForDynamicProducts = shouldCreateDylibForDynamicProducts
        self.sanitizers = sanitizers
        self.enableCodeCoverage = enableCodeCoverage
        self.indexStoreMode = indexStoreMode
        self.enableParseableModuleInterfaces = enableParseableModuleInterfaces
        self.emitSwiftModuleSeparately = emitSwiftModuleSeparately
        self.useIntegratedSwiftDriver = useIntegratedSwiftDriver
        self.useExplicitModuleBuild = useExplicitModuleBuild
        self.isXcodeBuildSystemEnabled = isXcodeBuildSystemEnabled
        self.printManifestGraphviz = printManifestGraphviz
        // decide on testability based on debug/release config
        self.enableTestability = enableTestability ?? (.debug == configuration)
        // decide if to enable the use of test manifests based on platform. this is likely to change in the future
        self.testDiscoveryStrategy = triple.isDarwin() ? .objectiveC : .manifest(generate: forceTestDiscovery)
        self.disableExplicitTargetDependencyImportChecking = disableExplicitTargetDependencyImportChecking
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
        return buildPath.appending(component: "codecov")
    }

    /// The path to the code coverage profdata file.
    public var codeCovDataFile: AbsolutePath {
        return codeCovPath.appending(component: "default.profdata")
    }

    public var llbuildManifest: AbsolutePath {
        return dataPath.appending(components: "..", configuration.dirname + ".yaml")
    }

    public var pifManifest: AbsolutePath {
        return dataPath.appending(components: "..", "manifest.pif")
    }

    public var buildDescriptionPath: AbsolutePath {
        return buildPath.appending(components: "description.json")
    }

    /// The debugging strategy according to the current build parameters.
    public var debuggingStrategy: DebuggingStrategy? {
        guard configuration == .debug else {
            return nil
        }

        if triple.isDarwin() {
            return .swiftAST
        }
        return .modulewrap
    }

    /// Returns the path to the binary of a product for the current build parameters.
    public func binaryPath(for product: ResolvedProduct) -> AbsolutePath {
        return buildPath.appending(binaryRelativePath(for: product))
    }

    /// Returns the path to the binary of a product for the current build parameters, relative to the build directory.
    public func binaryRelativePath(for product: ResolvedProduct) -> RelativePath {
        switch product.type {
        case .executable:
            return RelativePath("\(product.name)\(triple.executableExtension)")
        case .library(.static):
            return RelativePath("lib\(product.name)\(triple.staticLibraryExtension)")
        case .library(.dynamic):
            return RelativePath("\(triple.dynamicLibraryPrefix)\(product.name)\(triple.dynamicLibraryExtension)")
        case .library(.automatic), .plugin:
            fatalError()
        case .test:
            guard !triple.isWASI() else {
                return RelativePath("\(product.name).wasm")
            }

            let base = "\(product.name).xctest"
            if triple.isDarwin() {
                return RelativePath("\(base)/Contents/MacOS/\(product.name)")
            } else {
                return RelativePath(base)
            }
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
        try container.encode(toolchain.swiftCompiler, forKey: .swiftCompiler)
        try container.encode(toolchain.getClangCompiler(), forKey: .clangCompiler)

        try container.encode(toolchain.extraCCFlags, forKey: .extraCCFlags)
        try container.encode(toolchain.extraCPPFlags, forKey: .extraCPPFlags)
        try container.encode(toolchain.extraSwiftCFlags, forKey: .extraSwiftCFlags)
        try container.encode(toolchain.swiftCompiler, forKey: .swiftCompiler)
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
