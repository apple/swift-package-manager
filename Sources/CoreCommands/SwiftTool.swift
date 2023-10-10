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
import Basics
import Dispatch
@_implementationOnly import DriverSupport
import class Foundation.NSLock
import class Foundation.ProcessInfo
import PackageGraph
import PackageLoading
import PackageModel
import SPMBuildCore
import Workspace

#if canImport(WinSDK)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import func TSCBasic.exec
import protocol TSCBasic.OutputByteStream
import class TSCBasic.Process
import enum TSCBasic.ProcessEnv
import var TSCBasic.stderrStream
import class TSCBasic.TerminalController
import class TSCBasic.ThreadSafeOutputByteStream

import class TSCUtility.MultiLineNinjaProgressAnimation
import class TSCUtility.NinjaProgressAnimation
import class TSCUtility.PercentProgressAnimation
import protocol TSCUtility.ProgressAnimationProtocol
import var TSCUtility.verbosity

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
    var toolWorkspaceConfiguration: ToolWorkspaceConfiguration { get }
    var workspaceDelegateProvider: WorkspaceDelegateProvider { get }
    var workspaceLoaderProvider: WorkspaceLoaderProvider { get }
    func buildSystemProvider(_ swiftTool: SwiftTool) throws -> BuildSystemProvider
}

extension _SwiftCommand {
    public var toolWorkspaceConfiguration: ToolWorkspaceConfiguration {
        return .init()
    }
}

public protocol SwiftCommand: ParsableCommand, _SwiftCommand {
    var globalOptions: GlobalOptions { get }

    func run(_ swiftTool: SwiftTool) throws
}

extension SwiftCommand {
    public static var _errorLabel: String { "error" }

    public func run() throws {
        let swiftTool = try SwiftTool(
            options: globalOptions,
            toolWorkspaceConfiguration: self.toolWorkspaceConfiguration,
            workspaceDelegateProvider: self.workspaceDelegateProvider,
            workspaceLoaderProvider: self.workspaceLoaderProvider
        )
        swiftTool.buildSystemProvider = try buildSystemProvider(swiftTool)
        var toolError: Error? = .none
        do {
            try self.run(swiftTool)
            if swiftTool.observabilityScope.errorsReported || swiftTool.executionStatus == .failure {
                throw ExitCode.failure
            }
        } catch {
            toolError = error
        }

        // wait for all observability items to process
        swiftTool.waitForObservabilityEvents(timeout: .now() + 5)

        if let toolError {
            throw toolError
        }
    }
}

public protocol AsyncSwiftCommand: AsyncParsableCommand, _SwiftCommand {
    var globalOptions: GlobalOptions { get }

    func run(_ swiftTool: SwiftTool) async throws
}

extension AsyncSwiftCommand {
    public static var _errorLabel: String { "error" }

    public func run() async throws {
        let swiftTool = try SwiftTool(
            options: globalOptions,
            toolWorkspaceConfiguration: self.toolWorkspaceConfiguration,
            workspaceDelegateProvider: self.workspaceDelegateProvider,
            workspaceLoaderProvider: self.workspaceLoaderProvider
        )
        swiftTool.buildSystemProvider = try buildSystemProvider(swiftTool)
        var toolError: Error? = .none
        do {
            try await self.run(swiftTool)
            if swiftTool.observabilityScope.errorsReported || swiftTool.executionStatus == .failure {
                throw ExitCode.failure
            }
        } catch {
            toolError = error
        }

        // wait for all observability items to process
        swiftTool.waitForObservabilityEvents(timeout: .now() + 5)

        if let toolError {
            throw toolError
        }
    }
}

public final class SwiftTool {
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
    public let sharedSecurityDirectory: AbsolutePath?

    /// Path to the shared cache directory
    public let sharedCacheDirectory: AbsolutePath?

    /// Path to the shared configuration directory
    public let sharedConfigurationDirectory: AbsolutePath?

    /// Path to the cross-compilation Swift SDKs directory.
    public let sharedSwiftSDKsDirectory: AbsolutePath?

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

    private let observabilityHandler: SwiftToolObservabilityHandler

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

    private let driverSupport = DriverSupport()

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
        workspaceLoaderProvider: @escaping WorkspaceLoaderProvider
    ) throws {
        self.fileSystem = localFileSystem
        // first, bootstrap the observability system
        self.logLevel = options.logging.logLevel
        self.observabilityHandler = SwiftToolObservabilityHandler(outputStream: outputStream, logLevel: self.logLevel)
        let observabilitySystem = ObservabilitySystem(self.observabilityHandler)
        self.observabilityScope = observabilitySystem.topScope
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
        self.sharedSwiftSDKsDirectory = try fileSystem.getSharedSwiftSDKsDirectory(
            explicitDirectory: options.locations.swiftSDKsDirectory
        )

        // set global process logging handler
        Process.loggingHandler = { self.observabilityScope.emit(debug: $0) }
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
    public func resolve() throws {
        let workspace = try getActiveWorkspace()
        let root = try getWorkspaceRoot()

        try workspace.resolve(
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
    ) throws -> PackageGraph {
        do {
            let workspace = try getActiveWorkspace()

            // Fetch and load the package graph.
            let graph = try workspace.loadPackageGraph(
                rootInput: getWorkspaceRoot(),
                explicitProduct: explicitProduct,
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

        let buildParameters = try self.buildParameters()
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
        cacheBuildManifest: Bool = true,
        customBuildParameters: BuildParameters? = .none,
        customPackageGraphLoader: (() throws -> PackageGraph)? = .none,
        customOutputStream: OutputByteStream? = .none,
        customLogLevel: Basics.Diagnostic.Severity? = .none,
        customObservabilityScope: ObservabilityScope? = .none
    ) throws -> BuildSystem {
        guard let buildSystemProvider else {
            fatalError("build system provider not initialized")
        }

        let buildSystem = try buildSystemProvider.createBuildSystem(
            kind: explicitBuildSystem ?? options.build.buildSystem,
            explicitProduct: explicitProduct,
            cacheBuildManifest: cacheBuildManifest,
            customBuildParameters: customBuildParameters,
            customPackageGraphLoader: customPackageGraphLoader,
            customOutputStream: customOutputStream,
            customLogLevel: customLogLevel,
            customObservabilityScope: customObservabilityScope
        )

        // register the build system with the cancellation handler
        self.cancellator.register(name: "build system", handler: buildSystem.cancel)
        return buildSystem
    }

    private func _buildParams(toolchain: UserToolchain) throws -> BuildParameters {
        let hostTriple = try self.getHostToolchain().targetTriple
        let targetTriple = toolchain.targetTriple

        let dataPath = self.scratchDirectory.appending(
            component: targetTriple.platformBuildPathComponent(buildSystem: options.build.buildSystem)
        )

        return try BuildParameters(
            dataPath: dataPath,
            configuration: options.build.configuration,
            toolchain: toolchain,
            hostTriple: hostTriple,
            targetTriple: targetTriple,
            flags: options.build.buildFlags,
            pkgConfigDirectories: options.locations.pkgConfigDirectories,
            architectures: options.build.architectures,
            workers: options.build.jobs ?? UInt32(ProcessInfo.processInfo.activeProcessorCount),
            shouldLinkStaticSwiftStdlib: options.linker.shouldLinkStaticSwiftStdlib,
            shouldDisableLocalRpath: options.linker.shouldDisableLocalRpath,
            canRenameEntrypointFunctionName: driverSupport.checkSupportedFrontendFlags(
                flags: ["entry-point-function-name"],
                toolchain: toolchain,
                fileSystem: self.fileSystem
            ),
            sanitizers: options.build.enabledSanitizers,
            enableCodeCoverage: false, // set by test commands when appropriate
            indexStoreMode: options.build.indexStoreMode.buildParameter,
            enableParseableModuleInterfaces: options.build.shouldEnableParseableModuleInterfaces,
            useIntegratedSwiftDriver: options.build.useIntegratedSwiftDriver,
            useExplicitModuleBuild: options.build.useExplicitModuleBuild,
            isXcodeBuildSystemEnabled: options.build.buildSystem == .xcode,
            forceTestDiscovery: options.build.enableTestDiscovery, // backwards compatibility, remove with --enable-test-discovery
            testEntryPointPath: options.build.testEntryPointPath,
            explicitTargetDependencyImportCheckingMode: options.build.explicitTargetDependencyImportCheck.modeParameter,
            linkerDeadStrip: options.linker.linkerDeadStrip,
            verboseOutput: self.logLevel <= .info,
            linkTimeOptimizationMode: options.build.linkTimeOptimizationMode?.buildParameter,
            debugInfoFormat: options.build.debugInfoFormat.buildParameter
        )
    }

    /// Return the build parameters for the host toolchain.
    public func hostBuildParameters() throws -> BuildParameters {
        return try _hostBuildParameters.get()
    }

    private lazy var _hostBuildParameters: Result<BuildParameters, Swift.Error> = {
        return Result(catching: {
            try _buildParams(toolchain: self.getHostToolchain())
        })
    }()

    /// Return the build parameters.
    public func buildParameters() throws -> BuildParameters {
        return try _buildParameters.get()
    }

    private lazy var _buildParameters: Result<BuildParameters, Swift.Error> = {
        return Result(catching: {
            try _buildParams(toolchain: self.getTargetToolchain())
        })
    }()

    /// Lazily compute the target toolchain.
    private lazy var _targetToolchain: Result<UserToolchain, Swift.Error> = {
        var swiftSDK: SwiftSDK
        let hostSwiftSDK: SwiftSDK
        do {
            let hostToolchain = try _hostToolchain.get()
            hostSwiftSDK = hostToolchain.swiftSDK
            let hostTriple = hostToolchain.targetTriple

            // Create custom toolchain if present.
            if let customDestination = options.locations.customCompileDestination {
                let swiftSDKs = try SwiftSDK.decode(
                    fromFile: customDestination,
                    fileSystem: fileSystem,
                    observabilityScope: observabilityScope
                )
                if swiftSDKs.count == 1 {
                    swiftSDK = swiftSDKs[0]
                } else if swiftSDKs.count > 1,
                          let triple = options.build.customCompileTriple,
                          let matchingSDK = swiftSDKs.first(where: { $0.targetTriple == triple })
                {
                    swiftSDK = matchingSDK
                } else {
                    return .failure(SwiftSDKError.noSwiftSDKDecoded(customDestination))
                }
            } else if let targetTriple = options.build.customCompileTriple,
                      let targetSwiftSDK = SwiftSDK.defaultSwiftSDK(for: targetTriple, hostSDK: hostSwiftSDK)
            {
                swiftSDK = targetSwiftSDK
            } else if let swiftSDKSelector = options.build.swiftSDKSelector {
                do {
                    swiftSDK = try SwiftSDKBundle.selectBundle(
                        fromBundlesAt: sharedSwiftSDKsDirectory,
                        fileSystem: fileSystem,
                        matching: swiftSDKSelector,
                        hostTriple: hostTriple,
                        observabilityScope: observabilityScope
                    )
                } catch {
                    // If a user-installed bundle for the selector doesn't exist, check if the
                    // selector is recognized as a default SDK.
                    if let targetTriple = try? Triple(swiftSDKSelector),
                       let defaultSDK = SwiftSDK.defaultSwiftSDK(for: targetTriple, hostSDK: hostSwiftSDK) {
                        swiftSDK = defaultSDK
                    } else {
                        throw error
                    }
                }
            } else {
                // Otherwise use the host toolchain.
                swiftSDK = hostSwiftSDK
            }
        } catch {
            return .failure(error)
        }
        // Apply any manual overrides.
        if let triple = options.build.customCompileTriple {
            swiftSDK.targetTriple = triple
        }
        if let binDir = options.build.customCompileToolchain {
            swiftSDK.add(toolsetRootPath: binDir.appending(components: "usr", "bin"))
        }
        if let sdk = options.build.customCompileSDK {
            swiftSDK.pathsConfiguration.sdkRootPath = sdk
        }
        swiftSDK.architectures = options.build.architectures.isEmpty ? nil : options.build.architectures

        // Check if we ended up with the host toolchain.
        if hostSwiftSDK == swiftSDK {
            return self._hostToolchain
        }

        return Result(catching: { try UserToolchain(swiftSDK: swiftSDK) })
    }()

    /// Lazily compute the host toolchain used to compile the package description.
    private lazy var _hostToolchain: Result<UserToolchain, Swift.Error> = {
        return Result(catching: {
            try UserToolchain(swiftSDK: SwiftSDK.hostSwiftSDK(
                originalWorkingDirectory: self.originalWorkingDirectory))
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
                cachePath = self.sharedCacheDirectory.map{ Workspace.DefaultLocations.manifestsDirectory(at: $0) }
            }

            var extraManifestFlags = self.options.build.manifestFlags
            // Disable the implicit concurrency import if the compiler in use supports it to avoid warnings if we are building against an older SDK that does not contain a Concurrency module.
            if driverSupport.checkSupportedFrontendFlags(flags: ["disable-implicit-concurrency-module-import"], toolchain: try self.buildParameters().toolchain, fileSystem: self.fileSystem) {
                extraManifestFlags += ["-Xfrontend", "-disable-implicit-concurrency-module-import"]
            }
            // Disable the implicit string processing import if the compiler in use supports it to avoid warnings if we are building against an older SDK that does not contain a StringProcessing module.
            if driverSupport.checkSupportedFrontendFlags(flags: ["disable-implicit-string-processing-module-import"], toolchain: try self.buildParameters().toolchain, fileSystem: self.fileSystem) {
                extraManifestFlags += ["-Xfrontend", "-disable-implicit-string-processing-module-import"]
            }

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

private func getSharedSecurityDirectory(options: GlobalOptions, fileSystem: FileSystem) throws -> AbsolutePath? {
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

private func getSharedConfigurationDirectory(options: GlobalOptions, fileSystem: FileSystem) throws -> AbsolutePath? {
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

private func getSharedCacheDirectory(options: GlobalOptions, fileSystem: FileSystem) throws -> AbsolutePath? {
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

extension SwiftTool {
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
