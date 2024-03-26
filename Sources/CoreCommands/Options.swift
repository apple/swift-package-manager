//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ArgumentParser

import var Basics.localFileSystem
import struct Basics.AbsolutePath
import struct Basics.Triple
import func Basics.temp_await

import struct Foundation.URL

import enum PackageModel.BuildConfiguration
import struct PackageModel.BuildFlags
import struct PackageModel.EnabledSanitizers
import struct PackageModel.PackageIdentity
import class PackageModel.Manifest
import enum PackageModel.Sanitizer

import struct SPMBuildCore.BuildParameters
import struct SPMBuildCore.BuildSystemProvider

import struct TSCBasic.StringError

import struct TSCUtility.Version

import class Workspace.Workspace
import struct Workspace.WorkspaceConfiguration

package struct GlobalOptions: ParsableArguments {
    package init() {}

    @OptionGroup()
    package var locations: LocationOptions

    @OptionGroup()
    package var caching: CachingOptions

    @OptionGroup()
    package var logging: LoggingOptions

    @OptionGroup()
    package var security: SecurityOptions

    @OptionGroup()
    package var resolver: ResolverOptions

    @OptionGroup()
    package var build: BuildOptions

    @OptionGroup()
    package var linker: LinkerOptions

    @OptionGroup()
    package var traits: TraitOptions
}

package struct LocationOptions: ParsableArguments {
    package init() {}

    @Option(
        name: .customLong("package-path"),
        help: "Specify the package path to operate on (default current directory). This changes the working directory before any other operation",
        completion: .directory
    )
    package var packageDirectory: AbsolutePath?

    @Option(name: .customLong("cache-path"), help: "Specify the shared cache directory path", completion: .directory)
    package var cacheDirectory: AbsolutePath?

    @Option(
        name: .customLong("config-path"),
        help: "Specify the shared configuration directory path",
        completion: .directory
    )
    package var configurationDirectory: AbsolutePath?

    @Option(
        name: .customLong("security-path"),
        help: "Specify the shared security directory path",
        completion: .directory
    )
    package var securityDirectory: AbsolutePath?

    /// The custom .build directory, if provided.
    @Option(
        name: .customLong("scratch-path"),
        help: "Specify a custom scratch directory path (default .build)",
        completion: .directory
    )
    var _scratchDirectory: AbsolutePath?

    @Option(name: .customLong("build-path"), help: .hidden)
    var _deprecated_buildPath: AbsolutePath?

    var scratchDirectory: AbsolutePath? {
        self._scratchDirectory ?? self._deprecated_buildPath
    }

    /// The path to the file containing multiroot package data. This is currently Xcode's workspace file.
    @Option(name: .customLong("multiroot-data-file"), help: .hidden, completion: .directory)
    package var multirootPackageDataFile: AbsolutePath?

    /// Path to the compilation destination describing JSON file.
    @Option(name: .customLong("destination"), help: .hidden, completion: .directory)
    package var customCompileDestination: AbsolutePath?

    /// Path to the directory containing installed Swift SDKs.
    @Option(name: .customLong("experimental-swift-sdks-path"), help: .hidden, completion: .directory)
    package var swiftSDKsDirectory: AbsolutePath?

    @Option(
        name: .customLong("pkg-config-path"),
        help:
        """
        Specify alternative path to search for pkg-config `.pc` files. Use the option multiple times to
        specify more than one path.
        """,
        completion: .directory
    )
    package var pkgConfigDirectories: [AbsolutePath] = []

    @Flag(name: .customLong("ignore-lock"), help: .hidden)
    package var ignoreLock: Bool = false
}

package struct CachingOptions: ParsableArguments {
    package init() {}

    /// Disables package caching.
    @Flag(
        name: .customLong("dependency-cache"),
        inversion: .prefixedEnableDisable,
        help: "Use a shared cache when fetching dependencies"
    )
    package var useDependenciesCache: Bool = true

    /// Disables manifest caching.
    @Flag(name: .customLong("disable-package-manifest-caching"), help: .hidden)
    package var shouldDisableManifestCaching: Bool = false

    /// Whether to enable llbuild manifest caching.
    @Flag(name: .customLong("build-manifest-caching"), inversion: .prefixedEnableDisable)
    package var cacheBuildManifest: Bool = true

    /// Disables manifest caching.
    @Option(
        name: .customLong("manifest-cache"),
        help: "Caching mode of Package.swift manifests (shared: shared cache, local: package's build directory, none: disabled"
    )
    package var manifestCachingMode: ManifestCachingMode = .shared

    package enum ManifestCachingMode: String, ExpressibleByArgument {
        case none
        case local
        case shared

        package init?(argument: String) {
            self.init(rawValue: argument)
        }
    }
}

package struct LoggingOptions: ParsableArguments {
    package init() {}

    /// The verbosity of informational output.
    @Flag(name: .shortAndLong, help: "Increase verbosity to include informational output")
    package var verbose: Bool = false

    /// The verbosity of informational output.
    @Flag(name: [.long, .customLong("vv")], help: "Increase verbosity to include debug output")
    package var veryVerbose: Bool = false

    /// Whether logging output should be limited to `.error`.
    @Flag(name: .shortAndLong, help: "Decrease verbosity to only include error output.")
    package var quiet: Bool = false
}

package struct SecurityOptions: ParsableArguments {
    package init() {}

    /// Disables sandboxing when executing subprocesses.
    @Flag(name: .customLong("disable-sandbox"), help: "Disable using the sandbox when executing subprocesses")
    package var shouldDisableSandbox: Bool = false

    /// Force usage of the netrc file even in cases where it is not allowed.
    @Flag(name: .customLong("netrc"), help: "Use netrc file even in cases where other credential stores are preferred")
    package var forceNetrc: Bool = false

    /// Whether to load netrc files for authenticating with remote servers
    /// when downloading binary artifacts. This has no effects on registry
    /// communications.
    @Flag(
        inversion: .prefixedEnableDisable,
        exclusivity: .exclusive,
        help: "Load credentials from a netrc file"
    )
    package var netrc: Bool = true

    /// The path to the netrc file used when `netrc` is `true`.
    @Option(
        name: .customLong("netrc-file"),
        help: "Specify the netrc file path",
        completion: .file()
    )
    package var netrcFilePath: AbsolutePath?

    /// Whether to use keychain for authenticating with remote servers
    /// when downloading binary artifacts. This has no effects on registry
    /// communications.
    #if canImport(Security)
    @Flag(
        inversion: .prefixedEnableDisable,
        exclusivity: .exclusive,
        help: "Search credentials in macOS keychain"
    )
    package var keychain: Bool = true
    #else
    @Flag(
        inversion: .prefixedEnableDisable,
        exclusivity: .exclusive,
        help: .hidden
    )
    package var keychain: Bool = false
    #endif

    @Option(name: .customLong("resolver-fingerprint-checking"))
    package var fingerprintCheckingMode: WorkspaceConfiguration.CheckingMode = .strict

    @Option(name: .customLong("resolver-signing-entity-checking"))
    package var signingEntityCheckingMode: WorkspaceConfiguration.CheckingMode = .warn

    @Flag(
        inversion: .prefixedEnableDisable,
        exclusivity: .exclusive,
        help: "Validate signature of a signed package release downloaded from registry"
    )
    package var signatureValidation: Bool = true
}

package struct ResolverOptions: ParsableArguments {
    package init() {}

    /// Enable prefetching in resolver which will kick off parallel git cloning.
    @Flag(name: .customLong("prefetching"), inversion: .prefixedEnableDisable)
    package var shouldEnableResolverPrefetching: Bool = true

    /// Use Package.resolved file for resolving dependencies.
    @Flag(
        name: [.long, .customLong("disable-automatic-resolution"), .customLong("only-use-versions-from-resolved-file")],
        help: "Only use versions from the Package.resolved file and fail resolution if it is out-of-date"
    )
    package var forceResolvedVersions: Bool = false

    /// Skip updating dependencies from their remote during a resolution.
    @Flag(name: .customLong("skip-update"), help: "Skip updating dependencies from their remote during a resolution")
    package var skipDependencyUpdate: Bool = false

    @Flag(help: "Define automatic transformation of source control based dependencies to registry based ones")
    package var sourceControlToRegistryDependencyTransformation: SourceControlToRegistryDependencyTransformation =
        .disabled

    @Option(help: "Default registry URL to use, instead of the registries.json configuration file")
    package var defaultRegistryURL: URL?

    package enum SourceControlToRegistryDependencyTransformation: EnumerableFlag {
        case disabled
        case identity
        case swizzle

        package static func name(for value: Self) -> NameSpecification {
            switch value {
            case .disabled:
                return .customLong("disable-scm-to-registry-transformation")
            case .identity:
                return .customLong("use-registry-identity-for-scm")
            case .swizzle:
                return .customLong("replace-scm-with-registry")
            }
        }

        package static func help(for value: SourceControlToRegistryDependencyTransformation) -> ArgumentHelp? {
            switch value {
            case .disabled:
                return "disable source control to registry transformation"
            case .identity:
                return "look up source control dependencies in the registry and use their registry identity when possible to help deduplicate across the two origins"
            case .swizzle:
                return "look up source control dependencies in the registry and use the registry to retrieve them instead of source control when possible"
            }
        }
    }
}

package struct BuildOptions: ParsableArguments {
    package init() {}

    /// Build configuration.
    @Option(name: .shortAndLong, help: "Build with configuration")
    package var configuration: BuildConfiguration = .debug

    @Option(
        name: .customLong("Xcc", withSingleDash: true),
        parsing: .unconditionalSingleValue,
        help: "Pass flag through to all C compiler invocations"
    )
    var cCompilerFlags: [String] = []

    @Option(
        name: .customLong("Xswiftc", withSingleDash: true),
        parsing: .unconditionalSingleValue,
        help: "Pass flag through to all Swift compiler invocations"
    )
    var swiftCompilerFlags: [String] = []

    @Option(
        name: .customLong("Xlinker", withSingleDash: true),
        parsing: .unconditionalSingleValue,
        help: "Pass flag through to all linker invocations"
    )
    var linkerFlags: [String] = []

    @Option(
        name: .customLong("Xcxx", withSingleDash: true),
        parsing: .unconditionalSingleValue,
        help: "Pass flag through to all C++ compiler invocations"
    )
    var cxxCompilerFlags: [String] = []

    @Option(
        name: .customLong("Xxcbuild", withSingleDash: true),
        parsing: .unconditionalSingleValue,
        help: ArgumentHelp(
            "Pass flag through to the Xcode build system invocations",
            visibility: .hidden
        )
    )
    package var xcbuildFlags: [String] = []

    @Option(
        name: .customLong("Xbuild-tools-swiftc", withSingleDash: true),
        parsing: .unconditionalSingleValue,
        help: ArgumentHelp(
            "Pass flag to Swift compiler invocations for build-time executables (manifest and plugins)",
            visibility: .hidden
        )
    )
    package var _buildToolsSwiftCFlags: [String] = []

    @Option(
        name: .customLong("Xmanifest", withSingleDash: true),
        parsing: .unconditionalSingleValue,
        help: ArgumentHelp(
            "Pass flag to the manifest build invocation. Deprecated: use '-Xbuild-tools-swiftc' instead",
            visibility: .hidden
        )
    )
    package var _deprecated_manifestFlags: [String] = []

    var manifestFlags: [String] {
        self._deprecated_manifestFlags.isEmpty ?
            self._buildToolsSwiftCFlags :
            self._deprecated_manifestFlags
    }

    var pluginSwiftCFlags: [String] {
        self._buildToolsSwiftCFlags
    }

    package var buildFlags: BuildFlags {
        BuildFlags(
            cCompilerFlags: self.cCompilerFlags,
            cxxCompilerFlags: self.cxxCompilerFlags,
            swiftCompilerFlags: self.swiftCompilerFlags,
            linkerFlags: self.linkerFlags,
            xcbuildFlags: self.xcbuildFlags
        )
    }

    /// The compilation destination’s target triple.
    @Option(name: .customLong("triple"), transform: Triple.init)
    package var customCompileTriple: Triple?

    /// Path to the compilation destination’s SDK.
    @Option(name: .customLong("sdk"))
    package var customCompileSDK: AbsolutePath?

    /// Path to the compilation destination’s toolchain.
    @Option(name: .customLong("toolchain"))
    package var customCompileToolchain: AbsolutePath?

    /// The architectures to compile for.
    @Option(
        name: .customLong("arch"),
        help: ArgumentHelp(
            "Build the package for the these architectures",
            visibility: .hidden
        )
    )
    package var architectures: [String] = []

    /// Filter for selecting a specific Swift SDK to build with.
    @Option(name: .customLong("experimental-swift-sdk"), help: .hidden)
    package var swiftSDKSelector: String?

    /// Which compile-time sanitizers should be enabled.
    @Option(
        name: .customLong("sanitize"),
        help: "Turn on runtime checks for erroneous behavior, possible values: \(Sanitizer.formattedValues)"
    )
    package var sanitizers: [Sanitizer] = []

    package var enabledSanitizers: EnabledSanitizers {
        EnabledSanitizers(Set(sanitizers))
    }

    @Flag(help: "Enable or disable indexing-while-building feature")
    package var indexStoreMode: StoreMode = .autoIndexStore

    /// Whether to enable generation of `.swiftinterface`s alongside `.swiftmodule`s.
    @Flag(name: .customLong("enable-parseable-module-interfaces"))
    package var shouldEnableParseableModuleInterfaces: Bool = false

    /// The number of jobs for llbuild to start (aka the number of schedulerLanes)
    @Option(name: .shortAndLong, help: "The number of jobs to spawn in parallel during the build process")
    package var jobs: UInt32?

    /// Whether to use the integrated Swift driver rather than shelling out
    /// to a separate process.
    @Flag()
    package var useIntegratedSwiftDriver: Bool = false

    /// A flag that indicates this build should check whether targets only import
    /// their explicitly-declared dependencies
    @Option()
    package var explicitTargetDependencyImportCheck: TargetDependencyImportCheckingMode = .none

    /// Whether to use the explicit module build flow (with the integrated driver)
    @Flag(name: .customLong("experimental-explicit-module-build"))
    package var useExplicitModuleBuild: Bool = false

    /// The build system to use.
    @Option(name: .customLong("build-system"))
    var _buildSystem: BuildSystemProvider.Kind = .native

    /// The Debug Information Format to use.
    @Option(name: .customLong("debug-info-format", withSingleDash: true))
    package var debugInfoFormat: DebugInfoFormat = .dwarf

    package var buildSystem: BuildSystemProvider.Kind {
        #if os(macOS)
        // Force the Xcode build system if we want to build more than one arch.
        return self.architectures.count > 1 ? .xcode : self._buildSystem
        #else
        // Force building with the native build system on other platforms than macOS.
        return .native
        #endif
    }

    /// Whether to enable test discovery on platforms without Objective-C runtime.
    @Flag(help: .hidden)
    package var enableTestDiscovery: Bool = false

    /// Path of test entry point file to use, instead of synthesizing one or using `XCTMain.swift` in the package (if
    /// present).
    /// This implies `--enable-test-discovery`
    @Option(
        name: .customLong("experimental-test-entry-point-path"),
        help: .hidden
    )
    package var testEntryPointPath: AbsolutePath?

    /// The lto mode to use if any.
    @Option(
        name: .customLong("experimental-lto-mode"),
        help: .hidden
    )
    package var linkTimeOptimizationMode: LinkTimeOptimizationMode?

    @Flag(inversion: .prefixedEnableDisable, help: .hidden)
    package var getTaskAllowEntitlement: Bool? = nil

    // Whether to omit frame pointers
    // this can be removed once the backtracer uses DWARF instead of frame pointers
    @Flag(inversion: .prefixedNo,  help: .hidden)
    package var omitFramePointers: Bool? = nil

    // @Flag works best when there is a default value present
    // if true, false aren't enough and a third state is needed
    // nil should not be the goto. Instead create an enum
    package enum StoreMode: EnumerableFlag {
        case autoIndexStore
        case enableIndexStore
        case disableIndexStore
    }

    package enum TargetDependencyImportCheckingMode: String, Codable, ExpressibleByArgument {
        case none
        case warn
        case error
    }

    /// See `BuildParameters.LinkTimeOptimizationMode` for details.
    package enum LinkTimeOptimizationMode: String, Codable, ExpressibleByArgument {
        /// See `BuildParameters.LinkTimeOptimizationMode.full` for details.
        case full
        /// See `BuildParameters.LinkTimeOptimizationMode.thin` for details.
        case thin
    }

    /// See `BuildParameters.DebugInfoFormat` for details.
    package enum DebugInfoFormat: String, Codable, ExpressibleByArgument {
        /// See `BuildParameters.DebugInfoFormat.dwarf` for details.
        case dwarf
        /// See `BuildParameters.DebugInfoFormat.codeview` for details.
        case codeview
        /// See `BuildParameters.DebugInfoFormat.none` for details.
        case none
    }
}

package struct LinkerOptions: ParsableArguments {
    package init() {}

    @Flag(
        name: .customLong("dead-strip"),
        inversion: .prefixedEnableDisable,
        help: "Disable/enable dead code stripping by the linker"
    )
    package var linkerDeadStrip: Bool = true

    /// Disables adding $ORIGIN/@loader_path to the rpath, useful when deploying
    @Flag(name: .customLong("disable-local-rpath"), help: "Disable adding $ORIGIN/@loader_path to the rpath by default")
    package var shouldDisableLocalRpath: Bool = false
}

/// Which testing libraries to use (and any related options.)
package struct TestLibraryOptions: ParsableArguments {
    package init() {}

    /// Whether to enable support for XCTest (as explicitly specified by the user.)
    ///
    /// Callers will generally want to use ``enableXCTestSupport`` since it will
    /// have the correct default value if the user didn't specify one.
    @Flag(name: .customLong("xctest"),
          inversion: .prefixedEnableDisable,
          help: "Enable support for XCTest")
    package var explicitlyEnableXCTestSupport: Bool?

    /// Whether to enable support for XCTest.
    package var enableXCTestSupport: Bool {
        // Default to enabled.
        explicitlyEnableXCTestSupport ?? true
    }

    /// Whether to enable support for swift-testing (as explicitly specified by the user.)
    ///
    /// Callers (other than `swift package init`) will generally want to use
    /// ``enableSwiftTestingLibrarySupport(swiftCommandState:)`` since it will
    /// take into account whether the package has a dependency on swift-testing.
    @Flag(name: .customLong("experimental-swift-testing"),
          inversion: .prefixedEnableDisable,
          help: "Enable experimental support for swift-testing")
    package var explicitlyEnableSwiftTestingLibrarySupport: Bool?

    /// Whether to enable support for swift-testing.
    package func enableSwiftTestingLibrarySupport(
        swiftCommandState: SwiftCommandState
    ) throws -> Bool {
        // Honor the user's explicit command-line selection, if any.
        if let callerSuppliedValue = explicitlyEnableSwiftTestingLibrarySupport {
            return callerSuppliedValue
        }

        // If the active package has a dependency on swift-testing, automatically enable support for it so that extra steps are not needed.
        let workspace = try swiftCommandState.getActiveWorkspace()
        let root = try swiftCommandState.getWorkspaceRoot()
        let rootManifests = try temp_await {
            workspace.loadRootManifests(
                packages: root.packages,
                observabilityScope: swiftCommandState.observabilityScope,
                completion: $0
            )
        }

        // Is swift-testing among the dependencies of the package being built?
        // If so, enable support.
        let isEnabledByDependency = rootManifests.values.lazy
            .flatMap(\.dependencies)
            .map(\.identity)
            .map(String.init(describing:))
            .contains("swift-testing")
        if isEnabledByDependency {
            swiftCommandState.observabilityScope.emit(debug: "Enabling swift-testing support due to its presence as a package dependency.")
            return true
        }

        // Is swift-testing the package being built itself (unlikely)? If so,
        // enable support.
        let isEnabledByName = root.packages.lazy
            .map(PackageIdentity.init(path:))
            .map(String.init(describing:))
            .contains("swift-testing")
        if isEnabledByName {
            swiftCommandState.observabilityScope.emit(debug: "Enabling swift-testing support because it is a root package.")
            return true
        }

        // Default to disabled since swift-testing is experimental (opt-in.)
        return false
    }

    /// Get the set of enabled testing libraries.
    package func enabledTestingLibraries(
        swiftCommandState: SwiftCommandState
    ) throws -> Set<BuildParameters.Testing.Library> {
        var result = Set<BuildParameters.Testing.Library>()

        if enableXCTestSupport {
            result.insert(.xctest)
        }
        if try enableSwiftTestingLibrarySupport(swiftCommandState: swiftCommandState) {
            result.insert(.swiftTesting)
        }

        return result
    }
}


public struct TraitOptions: ParsableArguments {
    public init() {}

    /// The traits to enable for the package.
    @Option(help: " Enables the passed traits of the package. Multiple traits can be specified by providing a comma separated list e.g. `--traits Trait1,Trait2`.")
    public var traits: String?

    /// Enables all traits of the package.
    @Flag(help: "Enables all traits of the package.")
    public var enableAllTraits: Bool = false

    /// Disables all default traits of the package.
    @Flag(help: "Disables all default traits of the package.")
    public var disableDefaultTraits: Bool = false
}

// MARK: - Extensions

extension BuildConfiguration {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}

extension AbsolutePath {
    public init?(argument: String) {
        if let cwd = localFileSystem.currentWorkingDirectory {
            guard let path = try? AbsolutePath(validating: argument, relativeTo: cwd) else {
                return nil
            }
            self = path
        } else {
            guard let path = try? AbsolutePath(validating: argument) else {
                return nil
            }
            self = path
        }
    }

    public static var defaultCompletionKind: CompletionKind {
        // This type is most commonly used to select a directory, not a file.
        // Specify '.file()' in an argument declaration when necessary.
        .directory
    }
}

extension WorkspaceConfiguration.CheckingMode {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}

extension Sanitizer {
    public init?(argument: String) {
        if let sanitizer = Sanitizer(rawValue: argument) {
            self = sanitizer
            return
        }

        for sanitizer in Sanitizer.allCases where sanitizer.shortName == argument {
            self = sanitizer
            return
        }

        return nil
    }

    /// All sanitizer options in a comma separated string
    fileprivate static var formattedValues: String {
        Sanitizer.allCases.map(\.rawValue).joined(separator: ", ")
    }
}

extension PackageIdentity {
    public init?(argument: String) {
        self = .plain(argument)
    }
}

extension URL {
    public init?(argument: String) {
        self.init(string: argument)
    }
}

#if swift(<6.0)
extension BuildConfiguration: ExpressibleByArgument {}
extension AbsolutePath: ExpressibleByArgument {}
extension WorkspaceConfiguration.CheckingMode: ExpressibleByArgument {}
extension Sanitizer: ExpressibleByArgument {}
extension BuildSystemProvider.Kind: ExpressibleByArgument {}
extension Version: ExpressibleByArgument {}
extension PackageIdentity: ExpressibleByArgument {}
extension URL: ExpressibleByArgument {}
#else
extension BuildConfiguration: @retroactive ExpressibleByArgument {}
extension AbsolutePath: @retroactive ExpressibleByArgument {}
extension WorkspaceConfiguration.CheckingMode: @retroactive ExpressibleByArgument {}
extension Sanitizer: @retroactive ExpressibleByArgument {}
extension BuildSystemProvider.Kind: @retroactive ExpressibleByArgument {}
extension Version: @retroactive ExpressibleByArgument {}
extension PackageIdentity: @retroactive ExpressibleByArgument {}
extension URL: @retroactive ExpressibleByArgument {}
#endif
