/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import ArgumentParser
import TSCBasic
import TSCUtility
import PackageModel
import SPMBuildCore
import Build

struct BuildFlagsGroup: ParsableArguments {
    @Option(name: .customLong("Xcc", withSingleDash: true),
            parsing: .unconditionalSingleValue,
            help: "Pass flag through to all C compiler invocations")
    var cCompilerFlags: [String] = []
    
    @Option(name: .customLong("Xswiftc", withSingleDash: true),
            parsing: .unconditionalSingleValue,
            help: "Pass flag through to all Swift compiler invocations")
    var swiftCompilerFlags: [String] = []
    
    @Option(name: .customLong("Xlinker", withSingleDash: true),
            parsing: .unconditionalSingleValue,
            help: "Pass flag through to all linker invocations")
    var linkerFlags: [String] = []
    
    @Option(name: .customLong("Xcxx", withSingleDash: true),
            parsing: .unconditionalSingleValue,
            help: "Pass flag through to all C++ compiler invocations")
    var cxxCompilerFlags: [String] = []
    
    @Option(name: .customLong("Xxcbuild", withSingleDash: true),
            parsing: .unconditionalSingleValue,
            help: ArgumentHelp(
                "Pass flag through to the Xcode build system invocations",
                shouldDisplay: false))
    var xcbuildFlags: [String] = []

    @Option(name: .customLong("Xmanifest", withSingleDash: true),
            parsing: .unconditionalSingleValue,
            help: ArgumentHelp("Pass flag to the manifest build invocation",
                               shouldDisplay: false))
    var manifestFlags: [String] = []

    var buildFlags: BuildFlags {
        BuildFlags(
            xcc: cCompilerFlags,
            xcxx: cxxCompilerFlags,
            xswiftc: swiftCompilerFlags,
            xlinker: linkerFlags)
    }
    
    init() {}
}

extension BuildConfiguration: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}

extension AbsolutePath: ExpressibleByArgument {
    public init?(argument: String) {
        if let cwd = localFileSystem.currentWorkingDirectory {
            self.init(argument, relativeTo: cwd)
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

enum BuildSystemKind: String, ExpressibleByArgument, CaseIterable {
    case native
    case xcode
}

public extension Sanitizer {
    init(argument: String) throws {
        if let sanitizer = Sanitizer(rawValue: argument) {
            self = sanitizer
            return
        }

        for sanitizer in Sanitizer.allCases where sanitizer.shortName == argument {
            self = sanitizer
            return
        }

        throw StringError("valid sanitizers: \(Sanitizer.formattedValues)")
    }

    /// All sanitizer options in a comma separated string
    fileprivate static var formattedValues: String {
        return Sanitizer.allCases.map(\.rawValue).joined(separator: ", ")
    }
}

public struct SwiftToolOptions: ParsableArguments {
    @OptionGroup()
    var buildFlagsGroup: BuildFlagsGroup
    
    /// Custom arguments to pass to C compiler, swift compiler and the linker.
    var buildFlags: BuildFlags {
        buildFlagsGroup.buildFlags
    }

    var xcbuildFlags: [String] {
        buildFlagsGroup.xcbuildFlags
    }

    var manifestFlags: [String] {
        buildFlagsGroup.manifestFlags
    }

    /// Build configuration.
    @Option(name: .shortAndLong, help: "Build with configuration")
    var configuration: BuildConfiguration = .debug

    /// The custom build directory, if provided.
    @Option(help: "Specify build/cache directory")
    var buildPath: AbsolutePath?

    @Option(help: "Specify the shared cache directory")
    var cachePath: AbsolutePath?

    // TODO: add actual help when ready to be used
    @Option(help: .hidden)
    var configPath: AbsolutePath?

    /// Disables repository caching.
    @Flag(name: .customLong("repository-cache"), inversion: .prefixedEnableDisable, help: "Use a shared cache when fetching repositories")
    var useRepositoriesCache: Bool = true

    /// The custom working directory that the tool should operate in (deprecated).
    @Option(name: [.long, .customShort("C")])
    var chdir: AbsolutePath?

    /// The custom working directory that the tool should operate in.
    @Option(help: "Change working directory before any other operation")
    var packagePath: AbsolutePath?

    /// The path to the file containing multiroot package data. This is currently Xcode's workspace file.
    @Option(name: .customLong("multiroot-data-file"), completion: .file())
    var multirootPackageDataFile: AbsolutePath?

    /// Enable prefetching in resolver which will kick off parallel git cloning.
    @Flag(name: .customLong("prefetching"), inversion: .prefixedEnableDisable)
    var shouldEnableResolverPrefetching: Bool = true

    // FIXME: We need to allow -vv type options for this.
    /// The verbosity of informational output.
    @Flag(name: .shortAndLong, help: "Increase verbosity of informational output")
    var verbose: Bool = false
    
    var verbosity: Int { verbose ? 1 : 0 }

    /// Disables sandboxing when executing subprocesses.
    @Flag(name: .customLong("disable-sandbox"), help: "Disable using the sandbox when executing subprocesses")
    var shouldDisableSandbox: Bool = false

    /// Disables manifest caching.
    @Flag(name: .customLong("disable-package-manifest-caching"), help: .hidden)
    var shouldDisableManifestCaching: Bool = false

    /// Disables manifest caching.
    @Option(name: .customLong("manifest-cache"), help: "Caching mode of Package.swift manifests (shared: shared cache, local: package's build directory, none: disabled")
    var manifestCachingMode: ManifestCachingMode = .shared

    enum ManifestCachingMode: String, ExpressibleByArgument {
        case none
        case local
        case shared

        init?(argument: String) {
            self.init(rawValue: argument)
        }
    }

    /// Path to the compilation destination describing JSON file.
    @Option(name: .customLong("destination"), completion: .file())
    var customCompileDestination: AbsolutePath?

    /// The compilation destination’s target triple.
    @Option(name: .customLong("triple"), transform: Triple.init)
    var customCompileTriple: Triple?
    
    /// Path to the compilation destination’s SDK.
    @Option(name: .customLong("sdk"))
    var customCompileSDK: AbsolutePath?
    
    /// Path to the compilation destination’s toolchain.
    @Option(name: .customLong("toolchain"))
    var customCompileToolchain: AbsolutePath?

    /// The architectures to compile for.
    @Option(
      name: .customLong("arch"),
      help: ArgumentHelp(
        "Build the package for the these architectures",
        shouldDisplay: false))
    public var archs: [String] = []

    /// If should link the Swift stdlib statically.
    @Flag(name: .customLong("static-swift-stdlib"), inversion: .prefixedNo, help: "Link Swift stdlib statically")
    var shouldLinkStaticSwiftStdlib: Bool = false

    /// Skip updating dependencies from their remote during a resolution.
    @Flag(name: .customLong("skip-update"), help: "Skip updating dependencies from their remote during a resolution")
    var skipDependencyUpdate: Bool = false

    /// Which compile-time sanitizers should be enabled.
    @Option(name: .customLong("sanitize"),
            help: "Turn on runtime checks for erroneous behavior, possible values: \(Sanitizer.formattedValues)",
            transform: { try Sanitizer(argument: $0) })
    var sanitizers: [Sanitizer] = []

    var enabledSanitizers: EnabledSanitizers {
        EnabledSanitizers(Set(sanitizers))
    }
    
    /// Whether to enable code coverage.
    @Flag(name: .customLong("code-coverage"),
          inversion: .prefixedEnableDisable,
          help: "Enable code coverage")
    var shouldEnableCodeCoverage: Bool = false

    // TODO: Does disable-automatic-resolution alias force-resolved-versions?
    
    /// Use Package.resolved file for resolving dependencies.
    @Flag(name: [.long, .customLong("disable-automatic-resolution")], help: "Disable automatic resolution if Package.resolved file is out-of-date")
    var forceResolvedVersions: Bool = false

    // @Flag works best when there is a default value present
    // if true, false aren't enough and a third state is needed
    // nil should not be the goto. Instead create an enum
    enum StoreMode: EnumerableFlag {
        case autoIndexStore
        case enableIndexStore
        case disableIndexStore
        
        /// The mode to use for indexing-while-building feature.
        var indexStoreMode: BuildParameters.IndexStoreMode {
            switch self {
            case .autoIndexStore:
                return .auto
            case .enableIndexStore:
                return .on
            case .disableIndexStore:
                return .off
            }
        }
    }
    
    @Flag(help: "Enable or disable indexing-while-building feature")
    var indexStoreMode: StoreMode = .autoIndexStore

    /// Whether to enable generation of `.swiftinterface`s alongside `.swiftmodule`s.
    @Flag(name: .customLong("enable-parseable-module-interfaces"))
    var shouldEnableParseableModuleInterfaces: Bool = false

    /// Write dependency resolver trace to a file.
    @Flag(name: .customLong("trace-resolver"))
    var enableResolverTrace: Bool = false

    /// The number of jobs for llbuild to start (aka the number of schedulerLanes)
    @Option(name: .shortAndLong, help: "The number of jobs to spawn in parallel during the build process")
    var jobs: UInt32?

    /// Whether to enable test discovery on platforms without Objective-C runtime.
    @Flag(help: .hidden)
    var enableTestDiscovery: Bool = false

    /// Whether to enable llbuild manifest caching.
    @Flag(name: .customLong("build-manifest-caching"), inversion: .prefixedEnableDisable)
    var cacheBuildManifest: Bool = true

    /// Emit the Swift module separately from the object files.
    @Flag()
    var emitSwiftModuleSeparately: Bool = false

    /// Whether to use the integrated Swift driver rather than shelling out
    /// to a separate process.
    @Flag()
    var useIntegratedSwiftDriver: Bool = false

    /// A flag that inidcates this build should skip checking whether targets only import
    /// their explicitly-declared dependencies
    @Flag()
    var disableExplicitTargetDependencyImportChecking: Bool = false

    /// Whether to use the explicit module build flow (with the integrated driver)
    @Flag(name: .customLong("experimental-explicit-module-build"))
    var useExplicitModuleBuild: Bool = false

    /// Whether to output a graphviz file visualization of the combined job graph for all targets
    @Flag(
        name: .customLong("print-manifest-job-graph"),
        help: "Write the command graph for the build manifest as a graphviz file")
    var printManifestGraphviz: Bool = false

    /// The build system to use.
    @Option(name: .customLong("build-system"))
    var _buildSystem: BuildSystemKind = .native

    var buildSystem: BuildSystemKind {
        // Force the Xcode build system if we want to build more than one arch.
        archs.count > 1 ? .xcode : _buildSystem
    }
    
    /// Tells `Workspace` to attempt to locate .netrc file at `NSHomeDirectory`.
    @Flag()
    var netrc: Bool = false
    
    /// Similar to `--netrc`, but this option makes the .netrc usage optional and not mandatory as with the `--netrc` option.
    @Flag(name: .customLong("netrc-optional"))
    var netrcOptional: Bool = false
    
    /// The path to the netrc file which should be use for authentication when downloading binary target artifacts.
    /// Similar to `--netrc`, except that you also provide the path to the actual file to use.
    /// This is useful when you want to provide the information in another directory or with another file name.
    ///  - important: Respects `--netrcOptional` option.
    @Option(name: .customLong("netrc-file"), completion: .file())
    var netrcFilePath: AbsolutePath?
    
    public init() {}
}
