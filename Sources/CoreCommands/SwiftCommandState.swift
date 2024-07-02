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

import ArgumentParser
import Basics
import Dispatch
import class Foundation.NSLock
import class Foundation.ProcessInfo
import PackageGraph
import PackageLoading
@_spi(SwiftPMInternal)
import PackageModel
import SPMBuildCore
import Workspace

#if USE_IMPL_ONLY_IMPORTS
@_implementationOnly
@_spi(SwiftPMInternal)
import DriverSupport
#else
@_spi(SwiftPMInternal)
import DriverSupport
#endif

#if canImport(WinSDK)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

import func TSCBasic.exec
import class TSCBasic.FileLock
import protocol TSCBasic.OutputByteStream
import class Basics.AsyncProcess
import enum TSCBasic.ProcessEnv
import enum TSCBasic.ProcessLockError
import var TSCBasic.stderrStream
import class TSCBasic.TerminalController
import class TSCBasic.ThreadSafeOutputByteStream

import TSCUtility // cannot be scoped because of `String.spm_mangleToC99ExtendedIdentifier()`

typealias Diagnostic = Basics.Diagnostic

public struct ToolWorkspaceConfiguration {
    let shouldInstallSignalHandlers: Bool
    let wantsMultipleTestProducts: Bool
    let wantsREPLProduct: Bool

    public init(
        shouldInstallSignalHandlers: Bool = true,
        wantsMultipleTestProducts: Bool = false,
        wantsREPLProduct: Bool = false
    ) {
        self.shouldInstallSignalHandlers = shouldInstallSignalHandlers
        self.wantsMultipleTestProducts = wantsMultipleTestProducts
        self.wantsREPLProduct = wantsREPLProduct
    }
}

public typealias WorkspaceDelegateProvider = (
    _ observabilityScope: ObservabilityScope,
    _ outputHandler: @escaping (String, Bool) -> Void,
    _ progressHandler: @escaping (Int64, Int64, String?) -> Void,
    _ inputHandler: @escaping (String, (String?) -> Void) -> Void
) -> WorkspaceDelegate
public typealias WorkspaceLoaderProvider = (_ fileSystem: FileSystem, _ observabilityScope: ObservabilityScope)
    -> WorkspaceLoader

public protocol _SwiftCommand {
    var globalOptions: GlobalOptions { get }
    var toolWorkspaceConfiguration: ToolWorkspaceConfiguration { get }
    var workspaceDelegateProvider: WorkspaceDelegateProvider { get }
    var workspaceLoaderProvider: WorkspaceLoaderProvider { get }
    func buildSystemProvider(_ swiftCommandState: SwiftCommandState) throws -> BuildSystemProvider
}

extension _SwiftCommand {
    public var toolWorkspaceConfiguration: ToolWorkspaceConfiguration {
        return .init()
    }
}

public protocol SwiftCommand: ParsableCommand, _SwiftCommand {
    func run(_ swiftCommandState: SwiftCommandState) throws
}

extension SwiftCommand {
    public static var _errorLabel: String { "error" }

    public func run() throws {
        let swiftCommandState = try SwiftCommandState(
            options: globalOptions,
            toolWorkspaceConfiguration: self.toolWorkspaceConfiguration,
            workspaceDelegateProvider: self.workspaceDelegateProvider,
            workspaceLoaderProvider: self.workspaceLoaderProvider
        )

        // We use this to attempt to catch misuse of the locking APIs since we only release the lock from here.
        swiftCommandState.setNeedsLocking()

        swiftCommandState.buildSystemProvider = try buildSystemProvider(swiftCommandState)
        var toolError: Error? = .none
        do {
            try self.run(swiftCommandState)
            if swiftCommandState.observabilityScope.errorsReported || swiftCommandState.executionStatus == .failure {
                throw ExitCode.failure
            }
        } catch {
            toolError = error
        }

        swiftCommandState.releaseLockIfNeeded()

        // wait for all observability items to process
        swiftCommandState.waitForObservabilityEvents(timeout: .now() + 5)

        if let toolError {
            throw toolError
        }
    }
}

public protocol AsyncSwiftCommand: AsyncParsableCommand, _SwiftCommand {
    func run(_ swiftCommandState: SwiftCommandState) async throws
}

extension AsyncSwiftCommand {
    public static var _errorLabel: String { "error" }

    // FIXME: It doesn't seem great to have this be duplicated with `SwiftCommand`.
    public func run() async throws {
        let swiftCommandState = try SwiftCommandState(
            options: globalOptions,
            toolWorkspaceConfiguration: self.toolWorkspaceConfiguration,
            workspaceDelegateProvider: self.workspaceDelegateProvider,
            workspaceLoaderProvider: self.workspaceLoaderProvider
        )

        // We use this to attempt to catch misuse of the locking APIs since we only release the lock from here.
        swiftCommandState.setNeedsLocking()

        swiftCommandState.buildSystemProvider = try buildSystemProvider(swiftCommandState)
        var toolError: Error? = .none
        do {
            try await self.run(swiftCommandState)
            if swiftCommandState.observabilityScope.errorsReported || swiftCommandState.executionStatus == .failure {
                throw ExitCode.failure
            }
        } catch {
            toolError = error
        }

        swiftCommandState.releaseLockIfNeeded()

        // wait for all observability items to process
        swiftCommandState.waitForObservabilityEvents(timeout: .now() + 5)

        if let toolError {
            throw toolError
        }
    }
}

public final class SwiftCommandState {
    #if os(Windows)
    // unfortunately this is needed for C callback handlers used by Windows shutdown handler
    static var cancellator: Cancellator?
    #endif

    /// The original working directory.
    public let originalWorkingDirectory: AbsolutePath

    /// The options of this tool.
    public let options: GlobalOptions

    /// Path to the root package directory, nil if manifest is not found.
    private let packageRoot: AbsolutePath?

    /// Helper function to get package root or throw error if it is not found.
    public func getPackageRoot() throws -> AbsolutePath {
        guard let packageRoot = packageRoot else {
            throw StringError("Could not find \(Manifest.filename) in this directory or any of its parent directories.")
        }
        return packageRoot
    }

    /// Get the current workspace root object.
    public func getWorkspaceRoot() throws -> PackageGraphRootInput {
        let packages: [AbsolutePath]

        if let workspace = options.locations.multirootPackageDataFile {
            packages = try self.workspaceLoaderProvider(self.fileSystem, self.observabilityScope)
                .load(workspace: workspace)
        } else {
            packages = [try getPackageRoot()]
        }

        return PackageGraphRootInput(packages: packages)
    }

    /// Scratch space (.build) directory.
    public let scratchDirectory: AbsolutePath

    /// Path to the shared security directory
    public let sharedSecurityDirectory: AbsolutePath

    /// Path to the shared cache directory
    public let sharedCacheDirectory: AbsolutePath

    /// Path to the shared configuration directory
    public let sharedConfigurationDirectory: AbsolutePath

    /// Path to the cross-compilation Swift SDKs directory.
    public let sharedSwiftSDKsDirectory: AbsolutePath

    /// Cancellator to handle cancellation of outstanding work when handling SIGINT
    public let cancellator: Cancellator

    /// The execution status of the tool.
    public var executionStatus: ExecutionStatus = .success

    /// Holds the currently active workspace.
    ///
    /// It is not initialized in init() because for some of the commands like package init , usage etc,
    /// workspace is not needed, in-fact it would be an error to ask for the workspace object
    /// for package init because the Manifest file should *not* present.
    private var _workspace: Workspace?
    private var _workspaceDelegate: WorkspaceDelegate?

    private let observabilityHandler: SwiftCommandObservabilityHandler

    /// The observability scope to emit diagnostics event on
    public let observabilityScope: ObservabilityScope

    /// The min severity at which to log diagnostics
    public let logLevel: Basics.Diagnostic.Severity

    // should use sandbox on external subcommands
    public var shouldDisableSandbox: Bool

    /// The file system in use
    public let fileSystem: FileSystem

    /// Provider which can create a `WorkspaceDelegate` if needed.
    private let workspaceDelegateProvider: WorkspaceDelegateProvider

    /// Provider which can create a `WorkspaceLoader` if needed.
    private let workspaceLoaderProvider: WorkspaceLoaderProvider

    private let toolWorkspaceConfiguration: ToolWorkspaceConfiguration

    fileprivate var buildSystemProvider: BuildSystemProvider?

    private let environment: Environment

    private let hostTriple: Basics.Triple?

    /// Create an instance of this tool.
    ///
    /// - parameter options: The command line options to be passed to this tool.
    public convenience init(
        options: GlobalOptions,
        toolWorkspaceConfiguration: ToolWorkspaceConfiguration = .init(),
        workspaceDelegateProvider: @escaping WorkspaceDelegateProvider,
        workspaceLoaderProvider: @escaping WorkspaceLoaderProvider
    ) throws {
        // output from background activities goes to stderr, this includes diagnostics and output from build operations,
        // package resolution that take place as part of another action
        // CLI commands that have user facing output, use stdout directly to emit the final result
        // this means that the build output from "swift build" goes to stdout
        // but the build output from "swift test" goes to stderr, while the tests output go to stdout
        try self.init(
            outputStream: TSCBasic.stderrStream,
            options: options,
            toolWorkspaceConfiguration: toolWorkspaceConfiguration,
            workspaceDelegateProvider: workspaceDelegateProvider,
            workspaceLoaderProvider: workspaceLoaderProvider
        )
    }

    // marked internal for testing
    internal init(
        outputStream: OutputByteStream,
        options: GlobalOptions,
        toolWorkspaceConfiguration: ToolWorkspaceConfiguration,
        workspaceDelegateProvider: @escaping WorkspaceDelegateProvider,
        workspaceLoaderProvider: @escaping WorkspaceLoaderProvider,
        hostTriple: Basics.Triple? = nil,
        fileSystem: any FileSystem = localFileSystem,
        environment: Environment = .current
    ) throws {
        self.hostTriple = hostTriple
        self.fileSystem = fileSystem
        self.environment = environment
        // first, bootstrap the observability system
        self.logLevel = options.logging.logLevel
        self.observabilityHandler = SwiftCommandObservabilityHandler(outputStream: outputStream, logLevel: self.logLevel)
        let observabilitySystem = ObservabilitySystem(self.observabilityHandler)
        let observabilityScope = observabilitySystem.topScope
        self.observabilityScope = observabilityScope
        self.shouldDisableSandbox = options.security.shouldDisableSandbox
        self.toolWorkspaceConfiguration = toolWorkspaceConfiguration
        self.workspaceDelegateProvider = workspaceDelegateProvider
        self.workspaceLoaderProvider = workspaceLoaderProvider

        let cancellator = Cancellator(observabilityScope: self.observabilityScope)

        // Capture the original working directory ASAP.
        guard let cwd = self.fileSystem.currentWorkingDirectory else {
            self.observabilityScope.emit(error: "couldn't determine the current working directory")
            throw ExitCode.failure
        }
        self.originalWorkingDirectory = cwd

        do {
            try Self.postprocessArgParserResult(options: options, observabilityScope: self.observabilityScope)
            self.options = options

            // Honor package-path option is provided.
            if let packagePath = options.locations.packageDirectory {
                try ProcessEnv.chdir(packagePath)
            }

            if toolWorkspaceConfiguration.shouldInstallSignalHandlers {
                cancellator.installSignalHandlers()
            }
            self.cancellator = cancellator
        } catch {
            self.observabilityScope.emit(error)
            throw ExitCode.failure
        }

        // Create local variables to use while finding build path to avoid capture self before init error.
        let packageRoot = findPackageRoot(fileSystem: fileSystem)

        self.packageRoot = packageRoot
        self.scratchDirectory =
            try BuildSystemUtilities.getEnvBuildPath(workingDir: cwd) ??
            options.locations.scratchDirectory ??
            (packageRoot ?? cwd).appending(".build")

        // make sure common directories are created
        self.sharedSecurityDirectory = try getSharedSecurityDirectory(options: options, fileSystem: fileSystem)
        self.sharedConfigurationDirectory = try getSharedConfigurationDirectory(
            options: options,
            fileSystem: fileSystem
        )
        self.sharedCacheDirectory = try getSharedCacheDirectory(options: options, fileSystem: fileSystem)
        if options.locations.deprecatedSwiftSDKsDirectory != nil {
            self.observabilityScope.emit(
                warning: "`--experimental-swift-sdks-path` is deprecated and will be removed in a future version of SwiftPM. Use `--swift-sdks-path` instead."
            )
        }
        self.sharedSwiftSDKsDirectory = try fileSystem.getSharedSwiftSDKsDirectory(
            explicitDirectory: options.locations.swiftSDKsDirectory ?? options.locations.deprecatedSwiftSDKsDirectory
        )

        // set global process logging handler
        AsyncProcess.loggingHandler = { self.observabilityScope.emit(debug: $0) }
    }

    static func postprocessArgParserResult(options: GlobalOptions, observabilityScope: ObservabilityScope) throws {
        if options.locations.multirootPackageDataFile != nil {
            observabilityScope.emit(.unsupportedFlag("--multiroot-data-file"))
        }

        if options.build.useExplicitModuleBuild && !options.build.useIntegratedSwiftDriver {
            observabilityScope.emit(error: "'--experimental-explicit-module-build' option requires '--use-integrated-swift-driver'")
        }

        if !options.build.architectures.isEmpty && options.build.customCompileTriple != nil {
            observabilityScope.emit(.mutuallyExclusiveArgumentsError(arguments: ["--arch", "--triple"]))
        }

        // --enable-test-discovery should never be called on darwin based platforms
        #if canImport(Darwin)
        if options.build.enableTestDiscovery {
            observabilityScope
                .emit(
                    warning: "'--enable-test-discovery' option is deprecated; tests are automatically discovered on all platforms"
                )
        }
        #endif

        if options.caching.shouldDisableManifestCaching {
            observabilityScope
                .emit(
                    warning: "'--disable-package-manifest-caching' option is deprecated; use '--manifest-caching' instead"
                )
        }

        if let _ = options.security.netrcFilePath, options.security.netrc == false {
            observabilityScope.emit(.mutuallyExclusiveArgumentsError(arguments: ["--disable-netrc", "--netrc-file"]))
        }

        if !options.build._deprecated_manifestFlags.isEmpty {
            observabilityScope.emit(warning: "'-Xmanifest' option is deprecated; use '-Xbuild-tools-swiftc' instead")
        }
    }

    func waitForObservabilityEvents(timeout: DispatchTime) {
        self.observabilityHandler.wait(timeout: timeout)
    }

    /// Returns the currently active workspace.
    public func getActiveWorkspace(emitDeprecatedConfigurationWarning: Bool = false) throws -> Workspace {
        if let workspace = _workspace {
            return workspace
        }

        // Before creating the workspace, we need to acquire a lock on the build directory.
        try self.acquireLockIfNeeded()

        if options.resolver.skipDependencyUpdate {
            self.observabilityScope.emit(warning: "'--skip-update' option is deprecated and will be removed in a future release")
        }

        let delegate = self.workspaceDelegateProvider(
            self.observabilityScope,
            self.observabilityHandler.print,
            self.observabilityHandler.progress,
            self.observabilityHandler.prompt
        )
        let isXcodeBuildSystemEnabled = self.options.build.buildSystem == .xcode
        let workspace = try Workspace(
            fileSystem: self.fileSystem,
            location: .init(
                scratchDirectory: self.scratchDirectory,
                editsDirectory: self.getEditsDirectory(),
                resolvedVersionsFile: self.getResolvedVersionsFile(),
                localConfigurationDirectory: try self.getLocalConfigurationDirectory(),
                sharedConfigurationDirectory: self.sharedConfigurationDirectory,
                sharedSecurityDirectory: self.sharedSecurityDirectory,
                sharedCacheDirectory: self.sharedCacheDirectory,
                emitDeprecatedConfigurationWarning: emitDeprecatedConfigurationWarning
            ),
            authorizationProvider: self.getAuthorizationProvider(),
            registryAuthorizationProvider: self.getRegistryAuthorizationProvider(),
            configuration: .init(
                skipDependenciesUpdates: options.resolver.skipDependencyUpdate,
                prefetchBasedOnResolvedFile: options.resolver.shouldEnableResolverPrefetching,
                shouldCreateMultipleTestProducts: toolWorkspaceConfiguration.wantsMultipleTestProducts || options.build.buildSystem == .xcode,
                createREPLProduct: toolWorkspaceConfiguration.wantsREPLProduct,
                additionalFileRules: isXcodeBuildSystemEnabled ? FileRuleDescription.xcbuildFileTypes : FileRuleDescription.swiftpmFileTypes,
                sharedDependenciesCacheEnabled: self.options.caching.useDependenciesCache,
                fingerprintCheckingMode: self.options.security.fingerprintCheckingMode,
                signingEntityCheckingMode: self.options.security.signingEntityCheckingMode,
                skipSignatureValidation: !self.options.security.signatureValidation,
                sourceControlToRegistryDependencyTransformation: self.options.resolver.sourceControlToRegistryDependencyTransformation.workspaceConfiguration,
                defaultRegistry: self.options.resolver.defaultRegistryURL.flatMap {
                    // TODO: should supportsAvailability be a flag as well?
                    .init(url: $0, supportsAvailability: true)
                },
                manifestImportRestrictions: .none
            ),
            cancellator: self.cancellator,
            initializationWarningHandler: { self.observabilityScope.emit(warning: $0) },
            customHostToolchain: self.getHostToolchain(),
            customManifestLoader: self.getManifestLoader(),
            delegate: delegate
        )
        _workspace = workspace
        _workspaceDelegate = delegate
        return workspace
    }

    public func getRootPackageInformation() async throws -> (
        dependencies: [PackageIdentity: [PackageIdentity]],
        targets: [PackageIdentity: [String]]
    ) {
        let workspace = try self.getActiveWorkspace()
        let root = try self.getWorkspaceRoot()
        let rootManifests = await workspace.loadRootManifests(
            packages: root.packages,
            observabilityScope: self.observabilityScope
        )

        var identities = [PackageIdentity: [PackageIdentity]]()
        var targets = [PackageIdentity: [String]]()

        rootManifests.forEach {
            let identity = PackageIdentity(path: $0.key)
            identities[identity] = $0.value.dependencies.map(\.identity)
            targets[identity] = $0.value.targets.map { $0.name.spm_mangledToC99ExtendedIdentifier() }
        }

        return (identities, targets)
    }

    private func getEditsDirectory() throws -> AbsolutePath {
        // TODO: replace multiroot-data-file with explicit overrides
        if let multiRootPackageDataFile = options.locations.multirootPackageDataFile {
            return multiRootPackageDataFile.appending("Packages")
        }
        return try Workspace.DefaultLocations.editsDirectory(forRootPackage: self.getPackageRoot())
    }

    private func getResolvedVersionsFile() throws -> AbsolutePath {
        // TODO: replace multiroot-data-file with explicit overrides
        if let multiRootPackageDataFile = options.locations.multirootPackageDataFile {
            return multiRootPackageDataFile.appending(components: "xcshareddata", "swiftpm", Workspace.DefaultLocations.resolvedFileName)
        }
        return try Workspace.DefaultLocations.resolvedVersionsFile(forRootPackage: self.getPackageRoot())
    }

    internal func getLocalConfigurationDirectory() throws -> AbsolutePath {
        // Otherwise, use the default path.
        // TODO: replace multiroot-data-file with explicit overrides
        if let multiRootPackageDataFile = options.locations.multirootPackageDataFile {
            // migrate from legacy location
            let legacyPath = multiRootPackageDataFile.appending(components: "xcshareddata", "swiftpm", "config")
            let newPath = Workspace.DefaultLocations
                .mirrorsConfigurationFile(
                    at: multiRootPackageDataFile
                        .appending(components: "xcshareddata", "swiftpm", "configuration")
                )
            return try Workspace.migrateMirrorsConfiguration(
                from: legacyPath,
                to: newPath,
                observabilityScope: observabilityScope
            )
        } else {
            // migrate from legacy location
            let legacyPath = try self.getPackageRoot().appending(components: ".swiftpm", "config")
            let newPath = try Workspace.DefaultLocations.mirrorsConfigurationFile(forRootPackage: self.getPackageRoot())
            return try Workspace.migrateMirrorsConfiguration(
                from: legacyPath,
                to: newPath,
                observabilityScope: observabilityScope
            )
        }
    }

    public func getAuthorizationProvider() throws -> AuthorizationProvider? {
        var authorization = Workspace.Configuration.Authorization.default
        if !options.security.netrc {
            authorization.netrc = .disabled
        } else if let configuredPath = options.security.netrcFilePath {
            authorization.netrc = .custom(configuredPath)
        } else {
            authorization.netrc = .user
        }

        #if canImport(Security)
        authorization.keychain = self.options.security.keychain ? .enabled : .disabled
        #endif

        return try authorization.makeAuthorizationProvider(
            fileSystem: self.fileSystem,
            observabilityScope: self.observabilityScope
        )
    }

    public func getRegistryAuthorizationProvider() throws -> AuthorizationProvider? {
        var authorization = Workspace.Configuration.Authorization.default
        if let configuredPath = options.security.netrcFilePath {
            authorization.netrc = .custom(configuredPath)
        } else {
            authorization.netrc = .user
        }

        // Don't use OS credential store if user wants netrc
        #if canImport(Security)
        authorization.keychain = self.options.security.forceNetrc ? .disabled : .enabled
        #endif

        return try authorization.makeRegistryAuthorizationProvider(
            fileSystem: self.fileSystem,
            observabilityScope: self.observabilityScope
        )
    }

    /// Resolve the dependencies.
    public func resolve() async throws {
        let workspace = try getActiveWorkspace()
        let root = try getWorkspaceRoot()

        try await workspace.resolve(
            root: root,
            forceResolution: false,
            forceResolvedVersions: options.resolver.forceResolvedVersions,
            observabilityScope: self.observabilityScope
        )

        // Throw if there were errors when loading the graph.
        // The actual errors will be printed before exiting.
        guard !self.observabilityScope.errorsReported else {
            throw ExitCode.failure
        }
    }

    /// Fetch and load the complete package graph.
    ///
    /// - Parameters:
    ///   - explicitProduct: The product specified on the command line to a “swift run” or “swift build” command. This
    /// allows executables from dependencies to be run directly without having to hook them up to any particular target.
    @discardableResult
    public func loadPackageGraph(
        explicitProduct: String? = nil,
        testEntryPointPath: AbsolutePath? = nil
    ) async throws -> ModulesGraph {
        try await self.loadPackageGraph(
            explicitProduct: explicitProduct,
            traitConfiguration: nil,
            testEntryPointPath: testEntryPointPath
        )
    }

    /// Fetch and load the complete package graph.
    ///
    /// - Parameters:
    ///   - explicitProduct: The product specified on the command line to a “swift run” or “swift build” command. This
    /// allows executables from dependencies to be run directly without having to hook them up to any particular target.
    @discardableResult
    package func loadPackageGraph(
        explicitProduct: String? = nil,
        traitConfiguration: TraitConfiguration? = nil,
        testEntryPointPath: AbsolutePath? = nil
    ) async throws -> ModulesGraph {
        do {
            let workspace = try getActiveWorkspace()

            // Fetch and load the package graph.
            let graph = try await workspace.loadPackageGraph(
                rootInput: getWorkspaceRoot(),
                explicitProduct: explicitProduct,
                traitConfiguration: traitConfiguration,
                forceResolvedVersions: options.resolver.forceResolvedVersions,
                testEntryPointPath: testEntryPointPath,
                observabilityScope: self.observabilityScope
            )

            // Throw if there were errors when loading the graph.
            // The actual errors will be printed before exiting.
            guard !self.observabilityScope.errorsReported else {
                throw ExitCode.failure
            }
            return graph
        } catch {
            throw error
        }
    }

    public func getPluginScriptRunner(customPluginsDir: AbsolutePath? = .none) throws -> PluginScriptRunner {
        let pluginsDir = try customPluginsDir ?? self.getActiveWorkspace().location.pluginWorkingDirectory
        let cacheDir = pluginsDir.appending("cache")
        let pluginScriptRunner = try DefaultPluginScriptRunner(
            fileSystem: self.fileSystem,
            cacheDir: cacheDir,
            toolchain: self.getHostToolchain(),
            extraPluginSwiftCFlags: self.options.build.pluginSwiftCFlags,
            enableSandbox: !self.shouldDisableSandbox,
            verboseOutput: self.logLevel <= .info
        )
        // register the plugin runner system with the cancellation handler
        self.cancellator.register(name: "plugin runner", handler: pluginScriptRunner)
        return pluginScriptRunner
    }

    /// Returns the user toolchain to compile the actual product.
    public func getTargetToolchain() throws -> UserToolchain {
        try _targetToolchain.get()
    }

    public func getHostToolchain() throws -> UserToolchain {
        try _hostToolchain.get()
    }

    func getManifestLoader() throws -> ManifestLoader {
        try _manifestLoader.get()
    }

    public func canUseCachedBuildManifest() throws -> Bool {
        if !self.options.caching.cacheBuildManifest {
            return false
        }

        let buildParameters = try self.productsBuildParameters
        let haveBuildManifestAndDescription =
            self.fileSystem.exists(buildParameters.llbuildManifest) &&
            self.fileSystem.exists(buildParameters.buildDescriptionPath)

        if !haveBuildManifestAndDescription {
            return false
        }

        // Perform steps for build manifest caching if we can enabled it.
        //
        // FIXME: We don't add edited packages in the package structure command yet (SR-11254).
        let hasEditedPackages = try self.getActiveWorkspace().state.dependencies.contains(where: \.isEdited)
        if hasEditedPackages {
            return false
        }

        return true
    }

    // note: do not customize the OutputStream unless absolutely necessary
    // "customOutputStream" is designed to support build output redirection
    // but it is only expected to be used when invoking builds from "swift build" command.
    // in all other cases, the build output should go to the default which is stderr
    public func createBuildSystem(
        explicitBuildSystem: BuildSystemProvider.Kind? = .none,
        explicitProduct: String? = .none,
        traitConfiguration: TraitConfiguration,
        cacheBuildManifest: Bool = true,
        shouldLinkStaticSwiftStdlib: Bool = false,
        productsBuildParameters: BuildParameters? = .none,
        toolsBuildParameters: BuildParameters? = .none,
        packageGraphLoader: (() throws -> ModulesGraph)? = .none,
        outputStream: OutputByteStream? = .none,
        logLevel: Basics.Diagnostic.Severity? = .none,
        observabilityScope: ObservabilityScope? = .none
    ) throws -> BuildSystem {
        guard let buildSystemProvider else {
            fatalError("build system provider not initialized")
        }

        var productsParameters = try productsBuildParameters ?? self.productsBuildParameters
        productsParameters.linkingParameters.shouldLinkStaticSwiftStdlib = shouldLinkStaticSwiftStdlib

        let buildSystem = try buildSystemProvider.createBuildSystem(
            kind: explicitBuildSystem ?? options.build.buildSystem,
            explicitProduct: explicitProduct,
            traitConfiguration: traitConfiguration,
            cacheBuildManifest: cacheBuildManifest,
            productsBuildParameters: productsParameters,
            toolsBuildParameters: toolsBuildParameters,
            packageGraphLoader: packageGraphLoader,
            outputStream: outputStream,
            logLevel: logLevel,
            observabilityScope: observabilityScope
        )

        // register the build system with the cancellation handler
        self.cancellator.register(name: "build system", handler: buildSystem.cancel)
        return buildSystem
    }

    static let entitlementsMacOSWarning = """
    `--disable-get-task-allow-entitlement` and `--disable-get-task-allow-entitlement` only have an effect \
    when building on macOS.
    """

    private func _buildParams(
        toolchain: UserToolchain,
        destination: BuildParameters.Destination,
        prepareForIndexing: Bool? = nil
    ) throws -> BuildParameters {
        let triple = toolchain.targetTriple

        let dataPath = self.scratchDirectory.appending(
            component: triple.platformBuildPathComponent(buildSystem: options.build.buildSystem)
        )

        if options.build.getTaskAllowEntitlement != nil && !triple.isMacOSX {
            observabilityScope.emit(warning: Self.entitlementsMacOSWarning)
        }

        let prepareForIndexingMode: BuildParameters.PrepareForIndexingMode =
            switch (options.build.prepareForIndexing, options.build.prepareForIndexingNoLazy) {
                case (false, _): .off
                case (true, false): .on
                case (true, true): .noLazy
            }

        return try BuildParameters(
            destination: destination,
            dataPath: dataPath,
            configuration: options.build.configuration,
            toolchain: toolchain,
            triple: triple,
            flags: options.build.buildFlags,
            pkgConfigDirectories: options.locations.pkgConfigDirectories,
            architectures: options.build.architectures,
            workers: options.build.jobs ?? UInt32(ProcessInfo.processInfo.activeProcessorCount),
            sanitizers: options.build.enabledSanitizers,
            indexStoreMode: options.build.indexStoreMode.buildParameter,
            isXcodeBuildSystemEnabled: options.build.buildSystem == .xcode,
            prepareForIndexing: prepareForIndexingMode,
            debuggingParameters: .init(
                debugInfoFormat: options.build.debugInfoFormat.buildParameter,
                triple: triple,
                shouldEnableDebuggingEntitlement:
                    options.build.getTaskAllowEntitlement ?? (options.build.configuration == .debug),
                omitFramePointers: options.build.omitFramePointers
            ),
            driverParameters: .init(
                canRenameEntrypointFunctionName: DriverSupport.checkSupportedFrontendFlags(
                    flags: ["entry-point-function-name"],
                    toolchain: toolchain,
                    fileSystem: self.fileSystem
                ),
                enableParseableModuleInterfaces: options.build.shouldEnableParseableModuleInterfaces,
                explicitTargetDependencyImportCheckingMode: options.build.explicitTargetDependencyImportCheck.modeParameter,
                useIntegratedSwiftDriver: options.build.useIntegratedSwiftDriver,
                useExplicitModuleBuild: options.build.useExplicitModuleBuild,
                isPackageAccessModifierSupported: DriverSupport.isPackageNameSupported(
                    toolchain: toolchain,
                    fileSystem: self.fileSystem
                )
            ),
            linkingParameters: .init(
                linkerDeadStrip: options.linker.linkerDeadStrip,
                linkTimeOptimizationMode: options.build.linkTimeOptimizationMode?.buildParameter,
                shouldDisableLocalRpath: options.linker.shouldDisableLocalRpath
            ),
            outputParameters: .init(
                isVerbose: self.logLevel <= .info
            ),
            testingParameters: .init(
                configuration: options.build.configuration,
                targetTriple: triple,
                forceTestDiscovery: options.build.enableTestDiscovery, // backwards compatibility, remove with --enable-test-discovery
                testEntryPointPath: options.build.testEntryPointPath
            )
        )
    }

    /// Return the build parameters for the host toolchain.
    public var toolsBuildParameters: BuildParameters {
        get throws {
            try _toolsBuildParameters.get()
        }
    }

    private lazy var _toolsBuildParameters: Result<BuildParameters, Swift.Error> = {
        Result(catching: {
            try _buildParams(toolchain: self.getHostToolchain(), destination: .host, prepareForIndexing: false)
        })
    }()

    public var productsBuildParameters: BuildParameters {
        get throws {
            try _productsBuildParameters.get()
        }
    }

    private lazy var _productsBuildParameters: Result<BuildParameters, Swift.Error> = {
        Result(catching: {
            try _buildParams(toolchain: self.getTargetToolchain(), destination: .target)
        })
    }()

    /// Lazily compute the target toolchain.z
    private lazy var _targetToolchain: Result<UserToolchain, Swift.Error> = {
        let swiftSDK: SwiftSDK
        let hostSwiftSDK: SwiftSDK
        let store = SwiftSDKBundleStore(
            swiftSDKsDirectory: self.sharedSwiftSDKsDirectory,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope,
            outputHandler: { print($0.description) }
        )
        do {
            let hostToolchain = try _hostToolchain.get()
            hostSwiftSDK = hostToolchain.swiftSDK

            if options.build.deprecatedSwiftSDKSelector != nil {
                self.observabilityScope.emit(
                    warning: "`--experimental-swift-sdk` is deprecated and will be removed in a future version of SwiftPM. Use `--swift-sdk` instead."
                )
            }
            swiftSDK = try SwiftSDK.deriveTargetSwiftSDK(
                hostSwiftSDK: hostSwiftSDK,
                hostTriple: hostToolchain.targetTriple,
                customCompileDestination: options.locations.customCompileDestination,
                customCompileTriple: options.build.customCompileTriple,
                customCompileToolchain: options.build.customCompileToolchain,
                customCompileSDK: options.build.customCompileSDK,
                swiftSDKSelector: options.build.swiftSDKSelector ?? options.build.deprecatedSwiftSDKSelector,
                architectures: options.build.architectures,
                store: store,
                observabilityScope: self.observabilityScope,
                fileSystem: self.fileSystem
            )
        } catch {
            return .failure(error)
        }
        // Check if we ended up with the host toolchain.
        if hostSwiftSDK == swiftSDK {
            return self._hostToolchain
        }

        return Result(catching: {
            try UserToolchain(swiftSDK: swiftSDK, environment: self.environment, fileSystem: self.fileSystem)
        })
    }()

    /// Lazily compute the host toolchain used to compile the package description.
    private lazy var _hostToolchain: Result<UserToolchain, Swift.Error> = {
        return Result(catching: {
            var hostSwiftSDK = try SwiftSDK.hostSwiftSDK(
                environment: self.environment,
                observabilityScope: self.observabilityScope
            )
            hostSwiftSDK.targetTriple = self.hostTriple

            return try UserToolchain(
                swiftSDK: hostSwiftSDK,
                environment: self.environment,
                fileSystem: self.fileSystem
            )
        })
    }()

    private lazy var _manifestLoader: Result<ManifestLoader, Swift.Error> = {
        return Result(catching: {
            let cachePath: AbsolutePath?
            switch (self.options.caching.shouldDisableManifestCaching, self.options.caching.manifestCachingMode) {
            case (true, _):
                // backwards compatibility
                cachePath = .none
            case (false, .none):
                cachePath = .none
            case (false, .local):
                cachePath = self.scratchDirectory
            case (false, .shared):
                cachePath = Workspace.DefaultLocations.manifestsDirectory(at: self.sharedCacheDirectory)
            }

            var extraManifestFlags = self.options.build.manifestFlags
            if self.logLevel <= .info {
                extraManifestFlags.append("-v")
            }

            return try ManifestLoader(
                // Always use the host toolchain's resources for parsing manifest.
                toolchain: self.getHostToolchain(),
                isManifestSandboxEnabled: !self.shouldDisableSandbox,
                cacheDir: cachePath,
                extraManifestFlags: extraManifestFlags,
                importRestrictions: .none
            )
        })
    }()

    /// An enum indicating the execution status of run commands.
    public enum ExecutionStatus {
        case success
        case failure
    }

    // MARK: - Locking

    // This is used to attempt to prevent accidental misuse of the locking APIs.
    private enum WorkspaceLockState {
        case unspecified
        case needsLocking
        case locked
        case unlocked
    }

    private var workspaceLockState: WorkspaceLockState = .unspecified
    private var workspaceLock: FileLock?

    fileprivate func setNeedsLocking() {
        assert(workspaceLockState == .unspecified, "attempting to `setNeedsLocking()` from unexpected state: \(workspaceLockState)")
        workspaceLockState = .needsLocking
    }

    fileprivate func acquireLockIfNeeded() throws {
        guard packageRoot != nil else {
            return
        }
        assert(workspaceLockState == .needsLocking, "attempting to `acquireLockIfNeeded()` from unexpected state: \(workspaceLockState)")
        guard workspaceLock == nil else {
            throw InternalError("acquireLockIfNeeded() called multiple times")
        }
        workspaceLockState = .locked

        let workspaceLock = try FileLock.prepareLock(fileToLock: self.scratchDirectory)

        // Try a non-blocking lock first so that we can inform the user about an already running SwiftPM.
        do {
            try workspaceLock.lock(type: .exclusive, blocking: false)
        } catch let ProcessLockError.unableToAquireLock(errno) {
            if errno == EWOULDBLOCK {
                if self.options.locations.ignoreLock {
                    self.outputStream.write("Another instance of SwiftPM is already running using '\(self.scratchDirectory)', but this will be ignored since `--ignore-lock` has been passed".utf8)
                    self.outputStream.flush()
                } else {
                    self.outputStream.write("Another instance of SwiftPM is already running using '\(self.scratchDirectory)', waiting until that process has finished execution...".utf8)
                    self.outputStream.flush()

                    // Only if we fail because there's an existing lock we need to acquire again as blocking.
                    try workspaceLock.lock(type: .exclusive, blocking: true)
                }
            }
        }

        self.workspaceLock = workspaceLock
    }

    fileprivate func releaseLockIfNeeded() {
        // Never having acquired the lock is not an error case.
        assert(workspaceLockState == .locked || workspaceLockState == .needsLocking, "attempting to `releaseLockIfNeeded()` from unexpected state: \(workspaceLockState)")
        workspaceLockState = .unlocked

        workspaceLock?.unlock()
    }
}

/// Returns path of the nearest directory containing the manifest file w.r.t
/// current working directory.
private func findPackageRoot(fileSystem: FileSystem) -> AbsolutePath? {
    guard var root = fileSystem.currentWorkingDirectory else {
        return nil
    }
    // FIXME: It would be nice to move this to a generalized method which takes path and predicate and
    // finds the lowest path for which the predicate is true.
    while !fileSystem.isFile(root.appending(component: Manifest.filename)) {
        root = root.parentDirectory
        guard !root.isRoot else {
            return nil
        }
    }
    return root
}

private func getSharedSecurityDirectory(options: GlobalOptions, fileSystem: FileSystem) throws -> AbsolutePath {
    if let explicitSecurityDirectory = options.locations.securityDirectory {
        // Create the explicit security path if necessary
        if !fileSystem.exists(explicitSecurityDirectory) {
            try fileSystem.createDirectory(explicitSecurityDirectory, recursive: true)
        }
        return explicitSecurityDirectory
    } else {
        // further validation is done in workspace
        return try fileSystem.swiftPMSecurityDirectory
    }
}

private func getSharedConfigurationDirectory(options: GlobalOptions, fileSystem: FileSystem) throws -> AbsolutePath {
    if let explicitConfigurationDirectory = options.locations.configurationDirectory {
        // Create the explicit config path if necessary
        if !fileSystem.exists(explicitConfigurationDirectory) {
            try fileSystem.createDirectory(explicitConfigurationDirectory, recursive: true)
        }
        return explicitConfigurationDirectory
    } else {
        // further validation is done in workspace
        return try fileSystem.swiftPMConfigurationDirectory
    }
}

private func getSharedCacheDirectory(options: GlobalOptions, fileSystem: FileSystem) throws -> AbsolutePath {
    if let explicitCacheDirectory = options.locations.cacheDirectory {
        // Create the explicit cache path if necessary
        if !fileSystem.exists(explicitCacheDirectory) {
            try fileSystem.createDirectory(explicitCacheDirectory, recursive: true)
        }
        return explicitCacheDirectory
    } else {
        // further validation is done in workspace
        return try fileSystem.swiftPMCacheDirectory
    }
}

extension Basics.Diagnostic {
    static func unsupportedFlag(_ flag: String) -> Self {
        .warning("\(flag) is an *unsupported* option which can be removed at any time; do not rely on it")
    }
}

// MARK: - Support for loading external workspaces

public protocol WorkspaceLoader {
    func load(workspace: AbsolutePath) throws -> [AbsolutePath]
}

// MARK: - Diagnostics

extension SwiftCommandState {
    // FIXME: deprecate these one we are further along refactoring the call sites that use it
    /// The stream to print standard output on.
    public var outputStream: OutputByteStream {
        self.observabilityHandler.outputStream
    }
}

extension Workspace.ManagedDependency {
    fileprivate var isEdited: Bool {
        if case .edited = self.state { return true }
        return false
    }
}

extension LoggingOptions {
    fileprivate var logLevel: Diagnostic.Severity {
        if self.verbose {
            return .info
        } else if self.veryVerbose {
            return .debug
        } else if self.quiet {
            return .error
        } else {
            return .warning
        }
    }
}

extension ResolverOptions.SourceControlToRegistryDependencyTransformation {
    fileprivate var workspaceConfiguration: WorkspaceConfiguration.SourceControlToRegistryDependencyTransformation {
        switch self {
        case .disabled:
            return .disabled
        case .identity:
            return .identity
        case .swizzle:
            return .swizzle
        }
    }
}

extension BuildOptions.StoreMode {
    fileprivate var buildParameter: BuildParameters.IndexStoreMode {
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

extension BuildOptions.TargetDependencyImportCheckingMode {
    fileprivate var modeParameter: BuildParameters.TargetDependencyImportCheckingMode {
        switch self {
        case .none:
            return .none
        case .warn:
            return .warn
        case .error:
            return .error
        }
    }
}

extension BuildOptions.LinkTimeOptimizationMode {
    fileprivate var buildParameter: BuildParameters.LinkTimeOptimizationMode? {
        switch self {
        case .full:
            return .full
        case .thin:
            return .thin
        }
    }
}

extension BuildOptions.DebugInfoFormat {
    fileprivate var buildParameter: BuildParameters.DebugInfoFormat {
        switch self {
        case .dwarf:
            return .dwarf
        case .codeview:
            return .codeview
        case .none:
            return .none
        }
    }
}

extension Basics.Diagnostic {
    public static func mutuallyExclusiveArgumentsError(arguments: [String]) -> Self {
        .error(arguments.map { "'\($0)'" }.spm_localizedJoin(type: .conjunction) + " are mutually exclusive")
    }
}
