//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation

import class Basics.AsyncProcess

import struct TSCUtility.Version

/// Errors related to Swift SDKs.
public enum SwiftSDKError: Swift.Error {
    /// A bundle archive should contain at least one directory with the `.artifactbundle` extension.
    case invalidBundleArchive(AbsolutePath)

    /// A passed argument is neither a valid file system path nor a URL.
    case invalidPathOrURL(String)

    ///  Bundles installed from remote URLs require a checksum to be provided.
    case checksumNotProvided(URL)

    /// Computed archive checksum does not match the provided checksum.
    case checksumInvalid(computed: String, provided: String)

    /// Couldn't find the Xcode installation.
    case invalidInstallation(String)

    /// The schema version is invalid.
    case invalidSchemaVersion

    /// Name of the Swift SDK bundle is not valid.
    case invalidBundleName(String)

    /// No valid Swift SDKs were decoded from a metadata file.
    case noSwiftSDKDecoded(AbsolutePath)

    /// Path used for storing Swift SDK configuration data is not a directory.
    case pathIsNotDirectory(AbsolutePath)

    /// Swift SDK metadata couldn't be serialized with the latest serialization schema, potentially because it
    /// was deserialized from an earlier incompatible schema version or initialized manually with properties
    /// required for initialization missing.
    case unserializableMetadata

    /// No configuration values are available for this Swift SDK and target triple.
    case swiftSDKNotFound(artifactID: String, hostTriple: Triple, targetTriple: Triple)

    /// A Swift SDK bundle with this name is already installed, can't install a new bundle with the same name.
    case swiftSDKBundleAlreadyInstalled(bundleName: String)

    /// A Swift SDK with this artifact ID is already installed. Can't install a new bundle with this artifact,
    /// installed artifact IDs are expected to be unique.
    case swiftSDKArtifactAlreadyInstalled(installedBundleName: String, newBundleName: String, artifactID: String)

    #if os(macOS)
    /// Quarantine attribute should be removed by the `xattr` command from an installed bundle.
    case quarantineAttributePresent(bundlePath: AbsolutePath)
    #endif
}

extension SwiftSDKError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .checksumInvalid(computed, provided):
            return """
            Computed archive checksum `\(computed) does not match the provided checksum `\(provided)`.
            """

        case .checksumNotProvided(let url):
            return """
            Bundles installed from remote URLs (such as \(url)) require their checksum passed via `--checksum` option.
            The distributor of the bundle must compute it with the `swift package compute-checksum` \
            command and provide it with their Swift SDK installation instructions.
            """
        case .invalidBundleArchive(let archivePath):
            return """
            Swift SDK archive at `\(archivePath)` does not contain at least one directory with the \
            `.artifactbundle` extension.
            """
        case .invalidPathOrURL(let argument):
            return "`\(argument)` is neither a valid filesystem path nor a URL."
        case .invalidSchemaVersion:
            return "unsupported Swift SDK file schema version"
        case .invalidInstallation(let problem):
            return problem
        case .invalidBundleName(let name):
            return """
            invalid bundle name `\(name)`, unpacked Swift SDK bundles are expected to have `.artifactbundle` extension
            """
        case .noSwiftSDKDecoded(let path):
            return "no valid Swift SDKs were decoded from a metadata file at path `\(path)`"
        case .pathIsNotDirectory(let path):
            return "path expected to be a directory is not a directory or doesn't exist: `\(path)`"
        case .unserializableMetadata:
            return """
            Swift SDK configuration couldn't be serialized with the latest serialization schema, potentially because \
            it was deserialized from an earlier incompatible schema version or initialized manually with missing \
            properties required for initialization
            """
        case .swiftSDKNotFound(let artifactID, let hostTriple, let targetTriple):
            return """
            Swift SDK with ID `\(artifactID)`, host triple \(hostTriple), and target triple \(targetTriple) is not \
            currently installed.
            """
        case .swiftSDKBundleAlreadyInstalled(let bundleName):
            return """
            Swift SDK bundle with name `\(bundleName)` is already installed. Can't install a new bundle \
            with the same name.
            """
        case .swiftSDKArtifactAlreadyInstalled(let installedBundleName, let newBundleName, let artifactID):
            return """
            A Swift SDK with artifact ID `\(artifactID)` is already included in an installed bundle with name \
            `\(installedBundleName)`. Can't install a new bundle `\(newBundleName)` with this artifact, artifact IDs \
            are expected to be unique across all installed Swift SDK bundles.
            """
        #if os(macOS)
        case .quarantineAttributePresent(let bundlePath):
            return """
            Quarantine attribute is present on a Swift SDK bundle at path `\(bundlePath)`. If you're certain that the \
            bundle was downloaded from a trusted source, you can remove the attribute with this command:

            xattr -d -r -s com.apple.quarantine "\(bundlePath)"

            and try to install this bundle again.
            """
        #endif
        }
    }
}

@available(*, deprecated, renamed: "SwiftSDK")
public typealias Destination = SwiftSDK

/// Swift SDK model type which has information about everything that's required to build a SwiftPM package for a certain
/// platform.
public struct SwiftSDK: Equatable {
    /// The clang/LLVM triple describing the target OS and architecture.
    ///
    /// The triple has the general format <arch><sub>-<vendor>-<sys>-<abi>, where:
    ///  - arch = x86_64, i386, arm, thumb, mips, etc.
    ///  - sub = for ex. on ARM: v5, v6m, v7a, v7m, etc.
    ///  - vendor = pc, apple, nvidia, ibm, etc.
    ///  - sys = none, linux, win32, darwin, cuda, etc.
    ///  - abi = eabi, gnu, android, macho, elf, etc.
    ///
    /// for more information see //https://clang.llvm.org/docs/CrossCompilation.html
    public var targetTriple: Triple?

    /// The clang/LLVM triple describing the host platform that supports this Swift SDK.
    public let hostTriple: Triple?

    // FIXME: this needs to be implemented with either multiple Swift SDKs or making ``SwiftSDK/targetTriple`` an array.
    /// The architectures to build for. We build for host architecture if this is empty.
    public var architectures: [String]? = nil

    /// Whether or not the receiver supports testing.
    @available(*, deprecated, message: "Use `xctestSupport` instead")
    public var supportsTesting: Bool {
        if case .supported = xctestSupport {
            return true
        }
        return false
    }

    /// Whether or not the receiver supports testing using XCTest.
    @_spi(SwiftPMInternal)
    public enum XCTestSupport: Sendable, Equatable {
        /// XCTest is supported.
        case supported

        /// XCTest is not supported.
        ///
        /// - Parameters:
        ///     - reason: A string explaining why XCTest is not supported. If
        ///         `nil`, no additional information is available.
        case unsupported(reason: String?)
    }

    /// Whether or not the receiver supports using XCTest.
    @_spi(SwiftPMInternal)
    public let xctestSupport: XCTestSupport

    /// Root directory path of the SDK used to compile for the target triple.
    @available(*, deprecated, message: "use `pathsConfiguration.sdkRootPath` instead")
    public var sdk: AbsolutePath? {
        get {
            sdkRootDir
        }
        set {
            sdkRootDir = newValue
        }
    }

    /// Root directory path of the SDK used to compile for the target triple.
    @available(*, deprecated, message: "use `pathsConfiguration.sdkRootPath` instead")
    public var sdkRootDir: AbsolutePath? {
        get {
            pathsConfiguration.sdkRootPath
        }
        set {
            pathsConfiguration.sdkRootPath = newValue
        }
    }

    /// Path to a directory containing the toolchain (compilers/linker) to be used for the compilation.
    @available(*, deprecated, message: "use `toolset.rootPaths` instead")
    public var binDir: AbsolutePath {
        toolchainBinDir
    }

    /// Path to a directory containing the toolchain (compilers/linker) to be used for the compilation.
    @available(*, deprecated, message: "use `toolset.rootPaths` instead")
    public var toolchainBinDir: AbsolutePath {
        toolset.rootPaths[0]
    }

    /// Additional flags to be passed to the C compiler.
    @available(*, deprecated, message: "use `toolset` and its properties instead")
    public var extraCCFlags: [String] {
        extraFlags.cCompilerFlags
    }

    /// Additional flags to be passed to the Swift compiler.
    @available(*, deprecated, message: "use `toolset` and its properties instead")
    public var extraSwiftCFlags: [String] {
        extraFlags.swiftCompilerFlags
    }

    /// Additional flags to be passed to the C++ compiler.
    @available(*, deprecated, message: "use `toolset` and its properties instead")
    public var extraCPPFlags: [String] {
        extraFlags.cxxCompilerFlags
    }

    /// Additional flags to be passed to the build tools.
    @available(*, deprecated, message: "use `toolset` and its properties instead")
    public var extraFlags: BuildFlags {
        .init(
            cCompilerFlags: toolset.knownTools[.cCompiler]?.extraCLIOptions ?? [],
            cxxCompilerFlags: toolset.knownTools[.cxxCompiler]?.extraCLIOptions ?? [],
            swiftCompilerFlags: toolset.knownTools[.swiftCompiler]?.extraCLIOptions ?? [],
            linkerFlags: toolset.knownTools[.linker]?.extraCLIOptions ?? [],
            xcbuildFlags: toolset.knownTools[.xcbuild]?.extraCLIOptions ?? []
        )
    }

    /// Set of tools and their properties used for building code for the target triple. While a serialized Swift SDK
    /// metadata may specify multiple toolset files, these files are consolidated into a single ``Toolset`` value during
    /// deserialization.
    public private(set) var toolset: Toolset

    public struct PathsConfiguration: Equatable {
        public init(
            sdkRootPath: AbsolutePath?,
            swiftResourcesPath: AbsolutePath? = nil,
            swiftStaticResourcesPath: AbsolutePath? = nil,
            includeSearchPaths: [AbsolutePath]? = nil,
            librarySearchPaths: [AbsolutePath]? = nil,
            toolsetPaths: [AbsolutePath]? = nil
        ) {
            self.sdkRootPath = sdkRootPath
            self.swiftResourcesPath = swiftResourcesPath
            self.swiftStaticResourcesPath = swiftStaticResourcesPath
            self.includeSearchPaths = includeSearchPaths
            self.librarySearchPaths = librarySearchPaths
            self.toolsetPaths = toolsetPaths
        }

        /// Root directory path of the SDK used to compile for the target triple.
        public var sdkRootPath: AbsolutePath?

        /// Path containing Swift resources for dynamic linking.
        public var swiftResourcesPath: AbsolutePath?

        /// Path containing Swift resources for static linking.
        public var swiftStaticResourcesPath: AbsolutePath?

        /// Array of paths containing headers.
        public var includeSearchPaths: [AbsolutePath]?

        /// Array of paths containing libraries.
        public var librarySearchPaths: [AbsolutePath]?

        /// Array of paths containing toolset files.
        public var toolsetPaths: [AbsolutePath]?

        /// Initialize paths configuration from values deserialized using v3 schema.
        /// - Parameters:
        ///   - properties: properties of the Swift SDK for the given triple.
        ///   - swiftSDKDirectory: directory used for converting relative paths in `properties` to absolute paths.
        fileprivate init(
            _ properties: SerializedDestinationV3.TripleProperties,
            swiftSDKDirectory: AbsolutePath? = nil
        ) throws {
            if let swiftSDKDirectory {
                self.init(
                    sdkRootPath: try AbsolutePath(validating: properties.sdkRootPath, relativeTo: swiftSDKDirectory),
                    swiftResourcesPath: try properties.swiftResourcesPath.map {
                        try AbsolutePath(validating: $0, relativeTo: swiftSDKDirectory)
                    },
                    swiftStaticResourcesPath: try properties.swiftStaticResourcesPath.map {
                        try AbsolutePath(validating: $0, relativeTo: swiftSDKDirectory)
                    },
                    includeSearchPaths: try properties.includeSearchPaths?.map {
                        try AbsolutePath(validating: $0, relativeTo: swiftSDKDirectory)
                    },
                    librarySearchPaths: try properties.librarySearchPaths?.map {
                        try AbsolutePath(validating: $0, relativeTo: swiftSDKDirectory)
                    },
                    toolsetPaths: try properties.toolsetPaths?.map {
                        try AbsolutePath(validating: $0, relativeTo: swiftSDKDirectory)
                    }
                )
            } else {
                self.init(
                    sdkRootPath: try AbsolutePath(validating: properties.sdkRootPath),
                    swiftResourcesPath: try properties.swiftResourcesPath.map {
                        try AbsolutePath(validating: $0)
                    },
                    swiftStaticResourcesPath: try properties.swiftStaticResourcesPath.map {
                        try AbsolutePath(validating: $0)
                    },
                    includeSearchPaths: try properties.includeSearchPaths?.map {
                        try AbsolutePath(validating: $0)
                    },
                    librarySearchPaths: try properties.librarySearchPaths?.map {
                        try AbsolutePath(validating: $0)
                    },
                    toolsetPaths: try properties.toolsetPaths?.map {
                        try AbsolutePath(validating: $0)
                    }
                )
            }
        }

        /// Initialize paths configuration from values deserialized using v4 schema.
        /// - Parameters:
        ///   - properties: properties of a Swift SDK for the given triple.
        ///   - swiftSDKDirectory: directory used for converting relative paths in `properties` to absolute paths.
        fileprivate init(_ properties: SwiftSDKMetadataV4.TripleProperties, swiftSDKDirectory: AbsolutePath? = nil) throws {
            if let swiftSDKDirectory {
                self.init(
                    sdkRootPath: try AbsolutePath(validating: properties.sdkRootPath, relativeTo: swiftSDKDirectory),
                    swiftResourcesPath: try properties.swiftResourcesPath.map {
                        try AbsolutePath(validating: $0, relativeTo: swiftSDKDirectory)
                    },
                    swiftStaticResourcesPath: try properties.swiftStaticResourcesPath.map {
                        try AbsolutePath(validating: $0, relativeTo: swiftSDKDirectory)
                    },
                    includeSearchPaths: try properties.includeSearchPaths?.map {
                        try AbsolutePath(validating: $0, relativeTo: swiftSDKDirectory)
                    },
                    librarySearchPaths: try properties.librarySearchPaths?.map {
                        try AbsolutePath(validating: $0, relativeTo: swiftSDKDirectory)
                    },
                    toolsetPaths: try properties.toolsetPaths?.map {
                        try AbsolutePath(validating: $0, relativeTo: swiftSDKDirectory)
                    }
                )
            } else {
                self.init(
                    sdkRootPath: try AbsolutePath(validating: properties.sdkRootPath),
                    swiftResourcesPath: try properties.swiftResourcesPath.map {
                        try AbsolutePath(validating: $0)
                    },
                    swiftStaticResourcesPath: try properties.swiftStaticResourcesPath.map {
                        try AbsolutePath(validating: $0)
                    },
                    includeSearchPaths: try properties.includeSearchPaths?.map {
                        try AbsolutePath(validating: $0)
                    },
                    librarySearchPaths: try properties.librarySearchPaths?.map {
                        try AbsolutePath(validating: $0)
                    },
                    toolsetPaths: try properties.toolsetPaths?.map {
                        try AbsolutePath(validating: $0)
                    }
                )
            }
        }

        public mutating func merge(with newConfiguration: Self) {
            if let sdkRootPath = newConfiguration.sdkRootPath {
                self.sdkRootPath = sdkRootPath
            }

            if let swiftResourcesPath = newConfiguration.swiftResourcesPath {
                self.swiftResourcesPath = swiftResourcesPath
            }

            if let swiftStaticResourcesPath = newConfiguration.swiftStaticResourcesPath {
                self.swiftStaticResourcesPath = swiftStaticResourcesPath
            }

            if let includeSearchPaths = newConfiguration.includeSearchPaths {
                self.includeSearchPaths = includeSearchPaths
            }

            if let librarySearchPaths = newConfiguration.librarySearchPaths {
                self.librarySearchPaths = librarySearchPaths
            }

            if let toolsetPaths = newConfiguration.toolsetPaths {
                self.toolsetPaths = toolsetPaths
            }
        }
    }

    /// Configuration of file system paths used by this Swift SDK when building.
    public var pathsConfiguration: PathsConfiguration

    /// Creates a Swift SDK with the specified properties.
    @available(*, deprecated, message: "use `init(targetTriple:sdkRootDir:toolset:)` instead")
    public init(
        target: Triple? = nil,
        sdk: AbsolutePath?,
        binDir: AbsolutePath,
        extraCCFlags: [String] = [],
        extraSwiftCFlags: [String] = [],
        extraCPPFlags: [String] = []
    ) {
        self.init(
            targetTriple: target,
            sdkRootDir: sdk,
            toolchainBinDir: binDir,
            extraFlags: BuildFlags(
                cCompilerFlags: extraCCFlags,
                cxxCompilerFlags: extraCPPFlags,
                swiftCompilerFlags: extraSwiftCFlags
            )
        )
    }

    /// Creates a Swift SDK with the specified properties.
    @available(*, deprecated, message: "use `init(hostTriple:targetTriple:toolset:pathsConfiguration:)` instead")
    public init(
        hostTriple: Triple? = nil,
        targetTriple: Triple? = nil,
        sdkRootDir: AbsolutePath?,
        toolchainBinDir: AbsolutePath,
        extraFlags: BuildFlags = BuildFlags()
    ) {
        self.init(
            hostTriple: hostTriple,
            targetTriple: targetTriple,
            toolset: Toolset(toolchainBinDir: toolchainBinDir, buildFlags: extraFlags),
            pathsConfiguration: .init(sdkRootPath: sdkRootDir)
        )
    }

    /// Creates a Swift SDK with the specified properties.
    @available(*, deprecated, message: "use `init(hostTriple:targetTriple:toolset:pathsConfiguration:xctestSupport:)` instead")
    public init(
        hostTriple: Triple? = nil,
        targetTriple: Triple? = nil,
        toolset: Toolset,
        pathsConfiguration: PathsConfiguration,
        supportsTesting: Bool
    ) {
        let xctestSupport: XCTestSupport
        if supportsTesting {
            xctestSupport = .supported
        } else {
            xctestSupport = .unsupported(reason: nil)
        }

        self.init(
            hostTriple: hostTriple,
            targetTriple: targetTriple,
            toolset: toolset,
            pathsConfiguration: pathsConfiguration,
            xctestSupport: xctestSupport
        )
    }

    /// Creates a Swift SDK with the specified properties.
    @_spi(SwiftPMInternal)
    public init(
        hostTriple: Triple? = nil,
        targetTriple: Triple? = nil,
        toolset: Toolset,
        pathsConfiguration: PathsConfiguration,
        xctestSupport: XCTestSupport = .supported
    ) {
        self.hostTriple = hostTriple
        self.targetTriple = targetTriple
        self.toolset = toolset
        self.pathsConfiguration = pathsConfiguration
        self.xctestSupport = xctestSupport
    }

    /// Returns the bin directory for the host.
    private static func hostBinDir(
        fileSystem: FileSystem
    ) throws -> AbsolutePath {
        guard let cwd = fileSystem.currentWorkingDirectory else {
            return try AbsolutePath(validating: CommandLine.arguments[0]).parentDirectory
        }
        return try AbsolutePath(validating: CommandLine.arguments[0], relativeTo: cwd).parentDirectory
    }

    /// The Swift SDK describing the host platform.
    @available(*, deprecated, renamed: "hostSwiftSDK")
    public static func hostDestination(
        _ binDir: AbsolutePath? = nil,
        originalWorkingDirectory: AbsolutePath? = nil,
        environment: Environment
    ) throws -> SwiftSDK {
        try self.hostSwiftSDK(binDir, environment: environment)
    }

    /// The Swift SDK for the host platform.
    public static func hostSwiftSDK(
        _ binDir: AbsolutePath? = nil,
        environment: Environment = .current,
        observabilityScope: ObservabilityScope? = nil,
        fileSystem: any FileSystem = localFileSystem
    ) throws -> SwiftSDK {
        // Select the correct binDir.
        if environment["SWIFTPM_CUSTOM_BINDIR"] != nil {
            print("SWIFTPM_CUSTOM_BINDIR was deprecated in favor of SWIFTPM_CUSTOM_BIN_DIR")
        }
        let customBinDir = (environment["SWIFTPM_CUSTOM_BIN_DIR"] ?? environment["SWIFTPM_CUSTOM_BINDIR"])
            .flatMap { try? AbsolutePath(validating: $0) }
        let binDir = try customBinDir ?? binDir ?? SwiftSDK.hostBinDir(fileSystem: fileSystem)

        let sdkPath: AbsolutePath?
        #if os(macOS)
        // Get the SDK.
        if let value = environment["SDKROOT"] {
            sdkPath = try AbsolutePath(validating: value)
        } else {
            // No value in env, so search for it.
            let sdkPathStr = try AsyncProcess.checkNonZeroExit(
                arguments: ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
                environment: environment
            ).spm_chomp()
            guard !sdkPathStr.isEmpty else {
                throw SwiftSDKError.invalidInstallation("default SDK not found")
            }
            sdkPath = try AbsolutePath(validating: sdkPathStr)
        }
        #else
        sdkPath = nil
        #endif

        // Compute common arguments for clang and swift.
        let xctestSupport: XCTestSupport
        var extraCCFlags: [String] = []
        var extraSwiftCFlags: [String] = []
        #if os(macOS)
        do {
            let sdkPaths = try SwiftSDK.sdkPlatformFrameworkPaths(environment: environment)
            extraCCFlags += ["-F", sdkPaths.fwk.pathString]
            extraSwiftCFlags += ["-F", sdkPaths.fwk.pathString]
            extraSwiftCFlags += ["-I", sdkPaths.lib.pathString]
            extraSwiftCFlags += ["-L", sdkPaths.lib.pathString]
            xctestSupport = .supported
        } catch {
            xctestSupport = .unsupported(reason: String(describing: error))
        }
        #else
        xctestSupport = .supported
        #endif

        #if !os(Windows)
        extraCCFlags += ["-fPIC"]
        #endif

        return SwiftSDK(
            toolset: .init(
                knownTools: [
                    .cCompiler: .init(extraCLIOptions: extraCCFlags),
                    .swiftCompiler: .init(extraCLIOptions: extraSwiftCFlags),
                ],
                rootPaths: [binDir]
            ),
            pathsConfiguration: .init(sdkRootPath: sdkPath),
            xctestSupport: xctestSupport
        )
    }

    /// Returns `macosx` sdk platform framework path.
    public static func sdkPlatformFrameworkPaths(
        environment: Environment = .current
    ) throws -> (fwk: AbsolutePath, lib: AbsolutePath) {
        if let path = _sdkPlatformFrameworkPath {
            return path
        }
        let platformPath = try AsyncProcess.checkNonZeroExit(
            arguments: ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-platform-path"],
            environment: environment
        ).spm_chomp()

        guard !platformPath.isEmpty else {
            throw StringError("could not determine SDK platform path")
        }

        // For XCTest framework.
        let fwk = try AbsolutePath(validating: platformPath).appending(
            components: "Developer", "Library", "Frameworks"
        )

        // For XCTest Swift library.
        let lib = try AbsolutePath(validating: platformPath).appending(
            components: "Developer", "usr", "lib"
        )

        let sdkPlatformFrameworkPath = (fwk, lib)
        _sdkPlatformFrameworkPath = sdkPlatformFrameworkPath
        return sdkPlatformFrameworkPath
    }

    // FIXME: convert this from a tuple to a proper struct with documented properties
    /// Cache storage for sdk platform path.
    private static var _sdkPlatformFrameworkPath: (fwk: AbsolutePath, lib: AbsolutePath)? = nil

    /// Returns a default Swift SDK for a given target environment
    @available(*, deprecated, renamed: "defaultSwiftSDK")
    public static func defaultDestination(for triple: Triple, host: SwiftSDK) -> SwiftSDK? {
        if triple.isWASI() {
            let wasiSysroot = host.toolset.rootPaths.first?
                .parentDirectory // usr
                .appending(components: "share", "wasi-sysroot")
            return SwiftSDK(
                targetTriple: triple,
                toolset: host.toolset,
                pathsConfiguration: .init(sdkRootPath: wasiSysroot)
            )
        }
        return nil
    }

    /// Returns a default Swift SDK of a given target environment.
    public static func defaultSwiftSDK(for targetTriple: Triple, hostSDK: SwiftSDK) -> SwiftSDK? {
        if targetTriple.isWASI() {
            let wasiSysroot = hostSDK.toolset.rootPaths.first?
                .parentDirectory // usr
                .appending(components: "share", "wasi-sysroot")
            return SwiftSDK(
                targetTriple: targetTriple,
                toolset: hostSDK.toolset,
                pathsConfiguration: .init(sdkRootPath: wasiSysroot)
            )
        }
        return nil
    }

    /// Computes the target Swift SDK for the given options.
    @_spi(SwiftPMInternal)
    public static func deriveTargetSwiftSDK(
      hostSwiftSDK: SwiftSDK,
      hostTriple: Triple,
      customCompileDestination: AbsolutePath? = nil,
      customCompileTriple: Triple? = nil,
      customCompileToolchain: AbsolutePath? = nil,
      customCompileSDK: AbsolutePath? = nil,
      swiftSDKSelector: String? = nil,
      architectures: [String] = [],
      store: SwiftSDKBundleStore,
      observabilityScope: ObservabilityScope,
      fileSystem: FileSystem
    ) throws -> SwiftSDK {
        var swiftSDK: SwiftSDK
        var isBasedOnHostSDK: Bool = false
        // Create custom toolchain if present.
        if let customDestination = customCompileDestination {
            let swiftSDKs = try SwiftSDK.decode(
                fromFile: customDestination,
                fileSystem: fileSystem,
                observabilityScope: observabilityScope
            )
            if swiftSDKs.count == 1 {
                swiftSDK = swiftSDKs[0]
            } else if swiftSDKs.count > 1,
                      let triple = customCompileTriple,
                      let matchingSDK = swiftSDKs.first(where: { $0.targetTriple == triple })
            {
                swiftSDK = matchingSDK
            } else {
                throw SwiftSDKError.noSwiftSDKDecoded(customDestination)
            }
        } else if let triple = customCompileTriple,
                  let targetSwiftSDK = SwiftSDK.defaultSwiftSDK(for: triple, hostSDK: hostSwiftSDK)
        {
            swiftSDK = targetSwiftSDK
        } else if let swiftSDKSelector {
            swiftSDK = try store.selectBundle(matching: swiftSDKSelector, hostTriple: hostTriple)
        } else {
            // Otherwise use the host toolchain.
            swiftSDK = hostSwiftSDK
            isBasedOnHostSDK = true
        }
        // Apply any manual overrides.
        if let triple = customCompileTriple {
            swiftSDK.targetTriple = triple
        }
        if let binDir = customCompileToolchain {
            if !fileSystem.exists(binDir) {
                observabilityScope.emit(
                    warning: """
                        Toolchain directory specified through a command-line option doesn't exist and is ignored: `\(
                            binDir
                        )`
                        """
                )
            }

            // `--tooolchain` should override existing anything in the SDK and search paths.
            swiftSDK.prepend(toolsetRootPath: binDir.appending(components: "usr", "bin"))
        }
        if let sdk = customCompileSDK {
            swiftSDK.pathsConfiguration.sdkRootPath = sdk
        }
        swiftSDK.architectures = architectures.isEmpty ? nil : architectures

        if !isBasedOnHostSDK {
            // Append the host toolchain's toolset paths at the end for the case the target Swift SDK
            // doesn't have some of the tools (e.g. swift-frontend might be shared between the host and
            // target Swift SDKs).
            hostSwiftSDK.toolset.rootPaths.forEach { swiftSDK.append(toolsetRootPath: $0) }
        }

        return swiftSDK
    }

    /// Propagates toolchain and SDK paths known to the Swift SDK to `swiftc` CLI options.
    public mutating func applyPathCLIOptions() {
        var properties = self.toolset.knownTools[.swiftCompiler] ?? .init(extraCLIOptions: [])
        properties.extraCLIOptions.append(contentsOf: self.toolset.rootPaths.flatMap { ["-tools-directory", $0.pathString] })

        if let sdkDirPath = self.pathsConfiguration.sdkRootPath?.pathString {
            properties.extraCLIOptions.append(contentsOf: ["-sdk", sdkDirPath])
        }

        self.toolset.knownTools[.swiftCompiler] = properties
    }

    /// Prepends a path to the array of toolset root paths.
    ///
    /// Note: Use this operation if you want new root path to take priority over existing paths.
    ///
    /// - Parameter toolsetRootPath: new path to add to Swift SDK's toolset.
    public mutating func prepend(toolsetRootPath path: AbsolutePath) {
        self.toolset.rootPaths.insert(path, at: 0)
    }

    /// Appends a path to the array of toolset root paths.
    ///
    /// Note: The paths are evaluated in insertion order which means that newly added path would
    /// have a lower priority vs. existing paths.
    ///
    /// - Parameter toolsetRootPath: new path to add to Swift SDK's toolset.
    public mutating func append(toolsetRootPath: AbsolutePath) {
        self.toolset.rootPaths.append(toolsetRootPath)
    }
}

extension SwiftSDK {
    /// Load a ``SwiftSDK`` description from a JSON representation from disk.
    public static func decode(
        fromFile path: AbsolutePath,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> [SwiftSDK] {
        let decoder = JSONDecoder.makeWithDefaults()
        do {
            let version = try decoder.decode(path: path, fileSystem: fileSystem, as: SemanticVersionInfo.self)
            return try Self.decode(
                semanticVersion: version,
                fromFile: path,
                fileSystem: fileSystem,
                decoder: decoder,
                observabilityScope: observabilityScope
            )
        } catch DecodingError.keyNotFound {
            let version = try decoder.decode(path: path, fileSystem: fileSystem, as: VersionInfo.self)
            return try [SwiftSDK(legacy: version, fromFile: path, fileSystem: fileSystem, decoder: decoder)]
        }
    }

    /// Load a ``SwiftSDK`` description from a semantically versioned JSON representation from disk.
    private static func decode(
        semanticVersion: SemanticVersionInfo,
        fromFile path: AbsolutePath,
        fileSystem: FileSystem,
        decoder: JSONDecoder,
        observabilityScope: ObservabilityScope
    ) throws -> [SwiftSDK] {
        switch semanticVersion.schemaVersion {
        case Version(3, 0, 0):
            let swiftSDKs = try decoder.decode(path: path, fileSystem: fileSystem, as: SerializedDestinationV3.self)
            let swiftSDKDirectory = path.parentDirectory

            return try swiftSDKs.runTimeTriples.map { triple, properties in
                let triple = try Triple(triple)

                let pathStrings = properties.toolsetPaths ?? []
                let toolset = try pathStrings.reduce(into: Toolset(knownTools: [:], rootPaths: [])) {
                    try $0.merge(
                        with: Toolset(
                            from: .init(validating: $1, relativeTo: swiftSDKDirectory),
                            at: fileSystem,
                            observabilityScope
                        )
                    )
                }

                return try SwiftSDK(
                    targetTriple: triple,
                    properties: properties,
                    toolset: toolset,
                    swiftSDKDirectory: swiftSDKDirectory
                )
            }

        case Version(4, 0, 0):
            let swiftSDKs = try decoder.decode(path: path, fileSystem: fileSystem, as: SwiftSDKMetadataV4.self)
            let swiftSDKDirectory = path.parentDirectory

            return try swiftSDKs.targetTriples.map { triple, properties in
                let triple = try Triple(triple)

                let pathStrings = properties.toolsetPaths ?? []
                let toolset = try pathStrings.reduce(into: Toolset(knownTools: [:], rootPaths: [])) {
                    try $0.merge(
                        with: Toolset(
                            from: .init(validating: $1, relativeTo: swiftSDKDirectory),
                            at: fileSystem,
                            observabilityScope
                        )
                    )
                }

                return try SwiftSDK(
                    targetTriple: triple,
                    properties: properties,
                    toolset: toolset,
                    swiftSDKDirectory: swiftSDKDirectory
                )
            }
        default:
            throw SwiftSDKError.invalidSchemaVersion
        }
    }

    /// Initialize new Swift SDK from values deserialized using v4 schema.
    /// - Parameters:
    ///   - targetTriple: triple of the machine running code built with this Swift SDK.
    ///   - properties: properties of the Swift SDK for the given triple.
    ///   - toolset: combined toolset used by this Swift SDK.
    ///   - swiftSDKDirectory: directory used for converting relative paths in `properties` to absolute paths.
    init(
        targetTriple: Triple,
        properties: SwiftSDKMetadataV4.TripleProperties,
        toolset: Toolset = .init(),
        swiftSDKDirectory: AbsolutePath? = nil
    ) throws {
        self.init(
            targetTriple: targetTriple,
            toolset: toolset,
            pathsConfiguration: try .init(properties, swiftSDKDirectory: swiftSDKDirectory)
        )
    }

    /// Initialize new Swift SDK from values deserialized using the v3 schema.
    /// - Parameters:
    ///   - targetTriple: triple of the machine running code built with this Swift SDK.
    ///   - properties: properties of the destination for the given triple.
    ///   - toolset: combined toolset used by this destination.
    ///   - swiftSDKDirectory: directory used for converting relative paths in `properties` to absolute paths.
    private init(
        targetTriple: Triple,
        properties: SerializedDestinationV3.TripleProperties,
        toolset: Toolset = .init(),
        swiftSDKDirectory: AbsolutePath? = nil
    ) throws {
        self.init(
            targetTriple: targetTriple,
            toolset: toolset,
            pathsConfiguration: try .init(properties, swiftSDKDirectory: swiftSDKDirectory)
        )
    }

    /// Load a ``SwiftSDK`` description from a legacy JSON representation from disk.
    private init(
        legacy version: VersionInfo,
        fromFile path: AbsolutePath,
        fileSystem: FileSystem,
        decoder: JSONDecoder
    ) throws {
        // Check schema version.
        switch version.version {
        case 1:
            let serializedMetadata = try decoder.decode(
                path: path, 
                fileSystem: fileSystem,
                as: SerializedDestinationV1.self
            )
            try self.init(
                targetTriple: serializedMetadata.target.map { try Triple($0) },
                toolset: .init(
                    toolchainBinDir: serializedMetadata.binDir,
                    buildFlags: .init(
                        cCompilerFlags: serializedMetadata.extraCCFlags,
                        cxxCompilerFlags: serializedMetadata.extraCPPFlags,
                        swiftCompilerFlags: serializedMetadata.extraSwiftCFlags
                    )
                ),
                pathsConfiguration: .init(sdkRootPath: serializedMetadata.sdk)
            )
        case 2:
            let serializedMetadata = try decoder.decode(path: path, fileSystem: fileSystem, as: SerializedDestinationV2.self)
            let swiftSDKDirectory = path.parentDirectory

            try self.init(
                hostTriple: serializedMetadata.hostTriples.map(Triple.init).first,
                targetTriple: serializedMetadata.targetTriples.map(Triple.init).first,
                toolset: .init(
                    toolchainBinDir: AbsolutePath(
                        validating: serializedMetadata.toolchainBinDir,
                        relativeTo: swiftSDKDirectory
                    ),
                    buildFlags: .init(
                        cCompilerFlags: serializedMetadata.extraCCFlags,
                        cxxCompilerFlags: serializedMetadata.extraCXXFlags,
                        swiftCompilerFlags: serializedMetadata.extraSwiftCFlags,
                        linkerFlags: serializedMetadata.extraLinkerFlags
                    )
                ),
                pathsConfiguration: .init(
                    sdkRootPath: AbsolutePath(validating: serializedMetadata.sdkRootDir, relativeTo: swiftSDKDirectory)
                )
            )
        default:
            throw SwiftSDKError.invalidSchemaVersion
        }
    }

    /// Encodes a Swift SDK into its serialized form, which is a pair of its run time triple and paths configuration.
    /// Returns a pair that can be used to reconstruct a `SerializedDestinationV3` value for storage. `nil` if
    /// required configuration properties aren't available on `self`, which can happen if `Swift SDK` was decoded
    /// from different schema versions or constructed manually without providing valid values for such properties.
    var serialized: (Triple, SerializedDestinationV3.TripleProperties) {
        get throws {
            guard let targetTriple = self.targetTriple, let sdkRootDir = self.pathsConfiguration.sdkRootPath else {
                throw SwiftSDKError.unserializableMetadata
            }
            
            return (
                targetTriple,
                .init(
                    sdkRootPath: sdkRootDir.pathString,
                    swiftResourcesPath: self.pathsConfiguration.swiftResourcesPath?.pathString,
                    swiftStaticResourcesPath: self.pathsConfiguration.swiftStaticResourcesPath?.pathString,
                    includeSearchPaths: self.pathsConfiguration.includeSearchPaths?.map(\.pathString),
                    librarySearchPaths: self.pathsConfiguration.librarySearchPaths?.map(\.pathString),
                    toolsetPaths: self.pathsConfiguration.toolsetPaths?.map(\.pathString)
                )
            )
        }
    }
}

/// Integer version of the schema of `destination.json` files used for cross-compilation.
private struct VersionInfo: Codable {
    let version: Int
}

/// Semantic version of the schema of `destination.json` files used for cross-compilation.
private struct SemanticVersionInfo: Decodable {
    let schemaVersion: Version

    enum CodingKeys: String, CodingKey {
        case schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let versionString = try container.decode(String.self, forKey: .schemaVersion)
        self.schemaVersion = try Version(versionString: versionString, usesLenientParsing: true)
    }
}

/// Represents v1 schema of `destination.json` files used for cross-compilation.
private struct SerializedDestinationV1: Codable {
    let target: String?
    let sdk: AbsolutePath?
    let binDir: AbsolutePath
    let extraCCFlags: [String]
    let extraSwiftCFlags: [String]
    let extraCPPFlags: [String]

    enum CodingKeys: String, CodingKey {
        case target
        case sdk
        case binDir = "toolchain-bin-dir"
        case extraCCFlags = "extra-cc-flags"
        case extraSwiftCFlags = "extra-swiftc-flags"
        case extraCPPFlags = "extra-cpp-flags"
    }
}

/// Represents v2 schema of `destination.json` files used for cross-compilation.
private struct SerializedDestinationV2: Codable {
    let sdkRootDir: String
    let toolchainBinDir: String
    let hostTriples: [String]
    let targetTriples: [String]
    let extraCCFlags: [String]
    let extraSwiftCFlags: [String]
    let extraCXXFlags: [String]
    let extraLinkerFlags: [String]
}

/// Represents v3 schema of `destination.json` files used for cross-compilation.
struct SerializedDestinationV3: Decodable {
    struct TripleProperties: Codable {
        /// Path relative to `destination.json` containing SDK root.
        var sdkRootPath: String

        /// Path relative to `destination.json` containing Swift resources for dynamic linking.
        var swiftResourcesPath: String?

        /// Path relative to `destination.json` containing Swift resources for static linking.
        var swiftStaticResourcesPath: String?

        /// Array of paths relative to `destination.json` containing headers.
        var includeSearchPaths: [String]?

        /// Array of paths relative to `destination.json` containing libraries.
        var librarySearchPaths: [String]?

        /// Array of paths relative to `destination.json` containing toolset files.
        var toolsetPaths: [String]?
    }

    /// Mapping of triple strings to corresponding properties of such run-time triple.
    let runTimeTriples: [String: TripleProperties]
}

/// Represents v4 schema of `swift-sdk.json` (previously `destination.json`) files used for cross-compilation.
struct SwiftSDKMetadataV4: Decodable {
    struct TripleProperties: Codable {
        /// Path relative to `swift-sdk.json` containing SDK root.
        var sdkRootPath: String

        /// Path relative to `swift-sdk.json` containing Swift resources for dynamic linking.
        var swiftResourcesPath: String?

        /// Path relative to `swift-sdk.json` containing Swift resources for static linking.
        var swiftStaticResourcesPath: String?

        /// Array of paths relative to `swift-sdk.json` containing headers.
        var includeSearchPaths: [String]?

        /// Array of paths relative to `swift-sdk.json` containing libraries.
        var librarySearchPaths: [String]?

        /// Array of paths relative to `swift-sdk.json` containing toolset files.
        var toolsetPaths: [String]?
    }

    /// Mapping of triple strings to corresponding properties of such target triple.
    let targetTriples: [String: TripleProperties]
}

extension Optional where Wrapped == AbsolutePath {
    fileprivate var configurationString: String {
        self?.pathString ?? "not set"
    }
}

extension Optional where Wrapped == [AbsolutePath] {
    fileprivate var configurationString: String {
        self?.map(\.pathString).description ?? "not set"
    }
}

extension SwiftSDK.PathsConfiguration: CustomStringConvertible {
    public var description: String {
        """
        sdkRootPath: \(sdkRootPath.configurationString)
        swiftResourcesPath: \(swiftResourcesPath.configurationString)
        swiftStaticResourcesPath: \(swiftStaticResourcesPath.configurationString)
        includeSearchPaths: \(includeSearchPaths.configurationString)
        librarySearchPaths: \(librarySearchPaths.configurationString)
        toolsetPaths: \(toolsetPaths.configurationString)
        """
    }
}
