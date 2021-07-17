/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import func Foundation.NSUserName
import class Foundation.ProcessInfo
import func Foundation.NSHomeDirectory
import Dispatch

import ArgumentParser
import TSCLibc
import TSCBasic
import TSCUtility

import PackageModel
import PackageGraph
import SourceControl
import SPMBuildCore
import Build
import XCBuildSupport
import Workspace
import Basics

typealias Diagnostic = TSCBasic.Diagnostic

private class ToolWorkspaceDelegate: WorkspaceDelegate {
    /// The stream to use for reporting progress.
    private let stdoutStream: ThreadSafeOutputByteStream

    /// The progress animation for downloads.
    private let downloadAnimation: NinjaProgressAnimation

    /// Wether the tool is in a verbose mode.
    private let isVerbose: Bool

    private struct DownloadProgress {
        let bytesDownloaded: Int64
        let totalBytesToDownload: Int64
    }

    /// The progress of each individual downloads.
    private var downloadProgress: [String: DownloadProgress] = [:]

    private let queue = DispatchQueue(label: "org.swift.swiftpm.commands.tool-workspace-delegate")
    private let diagnostics: DiagnosticsEngine

    init(_ stdoutStream: OutputByteStream, isVerbose: Bool, diagnostics: DiagnosticsEngine) {
        // FIXME: Implement a class convenience initializer that does this once they are supported
        // https://forums.swift.org/t/allow-self-x-in-class-convenience-initializers/15924
        self.stdoutStream = stdoutStream as? ThreadSafeOutputByteStream ?? ThreadSafeOutputByteStream(stdoutStream)
        self.downloadAnimation = NinjaProgressAnimation(stream: self.stdoutStream)
        self.isVerbose = isVerbose
        self.diagnostics = diagnostics
    }

    func fetchingWillBegin(repository: String, fetchDetails: RepositoryManager.FetchDetails?) {
        queue.async {
            self.stdoutStream <<< "Fetching \(repository)"
            if let fetchDetails = fetchDetails {
                if fetchDetails.fromCache {
                    self.stdoutStream <<< " from cache"
                }
            }
            self.stdoutStream <<< "\n"
            self.stdoutStream.flush()
        }
    }

    func fetchingDidFinish(repository: String, fetchDetails: RepositoryManager.FetchDetails?, diagnostic: Diagnostic?, duration: DispatchTimeInterval) {
        queue.async {
            self.stdoutStream <<< "Fetched \(repository) (\(duration.descriptionInSeconds))"
            self.stdoutStream <<< "\n"
            self.stdoutStream.flush()
        }
    }

    func repositoryWillUpdate(_ repository: String) {
        queue.async {
            self.stdoutStream <<< "Updating \(repository)"
            self.stdoutStream <<< "\n"
            self.stdoutStream.flush()
        }
    }

    func repositoryDidUpdate(_ repository: String, duration: DispatchTimeInterval) {
        queue.async {
            self.stdoutStream <<< "Updated \(repository) (\(duration.descriptionInSeconds))"
            self.stdoutStream <<< "\n"
            self.stdoutStream.flush()
        }
    }

    func dependenciesUpToDate() {
        queue.async {
            self.stdoutStream <<< "Everything is already up-to-date"
            self.stdoutStream <<< "\n"
            self.stdoutStream.flush()
        }
    }

    func willCreateWorkingCopy(repository: String, at path: AbsolutePath) {
        queue.async {
            self.stdoutStream <<< "Creating working copy for \(repository)"
            self.stdoutStream <<< "\n"
            self.stdoutStream.flush()
        }
    }

    func willCheckOut(repository: String, revision: String, at path: AbsolutePath) {
        // noop
    }

    func didCheckOut(repository: String, revision: String, at path: AbsolutePath, error: Diagnostic?) {
        guard case .none = error else {
            return // error will be printed before hand
        }
        queue.async {
            self.stdoutStream <<< "Working copy of \(repository) resolved at \(revision)"
            self.stdoutStream <<< "\n"
            self.stdoutStream.flush()
        }
    }

    func removing(repository: String) {
        queue.async {
            self.stdoutStream <<< "Removing \(repository)"
            self.stdoutStream <<< "\n"
            self.stdoutStream.flush()
        }
    }

    func warning(message: String) {
        // FIXME: We should emit warnings through the diagnostic engine.
        queue.async {
            self.stdoutStream <<< "warning: " <<< message
            self.stdoutStream <<< "\n"
            self.stdoutStream.flush()
        }
    }

    func willResolveDependencies(reason: WorkspaceResolveReason) {
        guard isVerbose else { return }

        queue.sync {
            self.stdoutStream <<< "Running resolver because "

            switch reason {
            case .forced:
                self.stdoutStream <<< "it was forced"
            case .newPackages(let packages):
                let dependencies = packages.lazy.map({ "'\($0.location)'" }).joined(separator: ", ")
                self.stdoutStream <<< "the following dependencies were added: \(dependencies)"
            case .packageRequirementChange(let package, let state, let requirement):
                self.stdoutStream <<< "dependency '\(package.name)' was "

                switch state {
                case .checkout(let checkoutState)?:
                    switch checkoutState.requirement {
                    case .versionSet(.exact(let version)):
                        self.stdoutStream <<< "resolved to '\(version)'"
                    case .versionSet(_):
                        // Impossible
                        break
                    case .revision(let revision):
                        self.stdoutStream <<< "resolved to '\(revision)'"
                    case .unversioned:
                        self.stdoutStream <<< "unversioned"
                    }
                case .edited?:
                    self.stdoutStream <<< "edited"
                case .local?:
                    self.stdoutStream <<< "versioned"
                case nil:
                    self.stdoutStream <<< "root"
                }

                self.stdoutStream <<< " but now has a "

                switch requirement {
                case .versionSet:
                    self.stdoutStream <<< "different version-based"
                case .revision:
                    self.stdoutStream <<< "different revision-based"
                case .unversioned:
                    self.stdoutStream <<< "unversioned"
                }

                self.stdoutStream <<< " requirement."
            default:
                self.stdoutStream <<< " requirements have changed."
            }

            self.stdoutStream <<< "\n"
            stdoutStream.flush()
        }
    }

    func willComputeVersion(package: PackageIdentity, location: String) {
        queue.async {
            self.stdoutStream <<< "Computing version for \(location)"
            self.stdoutStream <<< "\n"
            self.stdoutStream.flush()
        }
    }

    func didComputeVersion(package: PackageIdentity, location: String, version: String, duration: DispatchTimeInterval) {
        queue.async {
            self.stdoutStream <<< "Computed \(location) at \(version) (\(duration.descriptionInSeconds))"
            self.stdoutStream <<< "\n"
            self.stdoutStream.flush()
        }
    }

    func downloadingBinaryArtifact(from url: String, bytesDownloaded: Int64, totalBytesToDownload: Int64?) {
        queue.async {
            if let totalBytesToDownload = totalBytesToDownload {
                self.downloadProgress[url] = DownloadProgress(
                    bytesDownloaded: bytesDownloaded,
                    totalBytesToDownload: totalBytesToDownload)
            }

            let step = self.downloadProgress.values.reduce(0, { $0 + $1.bytesDownloaded }) / 1024
            let total = self.downloadProgress.values.reduce(0, { $0 + $1.totalBytesToDownload }) / 1024
            self.downloadAnimation.update(step: Int(step), total: Int(total), text: "Downloading binary artifacts")
        }
    }

    func didDownloadBinaryArtifacts() {
        queue.async {
            if self.diagnostics.hasErrors {
                self.downloadAnimation.clear()
            }

            self.downloadAnimation.complete(success: true)
            self.downloadProgress.removeAll()
        }
    }

    // noop
    
    func willLoadManifest(packagePath: AbsolutePath, url: String, version: Version?, packageKind: PackageReference.Kind) {}
    func didLoadManifest(packagePath: AbsolutePath, url: String, version: Version?, packageKind: PackageReference.Kind, manifest: Manifest?, diagnostics: [Diagnostic]) {}
    func didCreateWorkingCopy(repository url: String, at path: AbsolutePath, error: Diagnostic?) {}
    func resolvedFileChanged() {}
}

/// Handler for the main DiagnosticsEngine used by the SwiftTool class.
private final class DiagnosticsEngineHandler {
    /// The standard output stream.
    var stdoutStream = TSCBasic.stdoutStream

    /// The default instance.
    static let `default` = DiagnosticsEngineHandler()

    private init() {}

    func diagnosticsHandler(_ diagnostic: Diagnostic) {
        print(diagnostic: diagnostic, stdoutStream: stderrStream)
    }
}

protocol SwiftCommand: ParsableCommand {
    var swiftOptions: SwiftToolOptions { get }
  
    func run(_ swiftTool: SwiftTool) throws
}

extension SwiftCommand {
    public func run() throws {
        let swiftTool = try SwiftTool(options: swiftOptions)
        try self.run(swiftTool)
        if swiftTool.diagnostics.hasErrors || swiftTool.executionStatus == .failure {
            throw ExitCode.failure
        }
    }

    public static var _errorLabel: String { "error" }
}

public class SwiftTool {
    /// The original working directory.
    let originalWorkingDirectory: AbsolutePath

    /// The options of this tool.
    var options: SwiftToolOptions

    /// Path to the root package directory, nil if manifest is not found.
    let packageRoot: AbsolutePath?

    /// Helper function to get package root or throw error if it is not found.
    func getPackageRoot() throws -> AbsolutePath {
        guard let packageRoot = packageRoot else {
            throw Error.rootManifestFileNotFound
        }
        return packageRoot
    }

    /// Get the current workspace root object.
    func getWorkspaceRoot() throws -> PackageGraphRootInput {
        let packages: [AbsolutePath]

        if let workspace = options.multirootPackageDataFile {
            packages = try XcodeWorkspaceLoader(diagnostics: diagnostics).load(workspace: workspace)
        } else {
            packages = [try getPackageRoot()]
        }

        return PackageGraphRootInput(packages: packages)
    }

    /// Path to the build directory.
    let buildPath: AbsolutePath

    /// The process set to hold the launched processes. These will be terminated on any signal
    /// received by the swift tools.
    let processSet: ProcessSet

    /// The current build system reference. The actual reference is present only during an active build.
    let buildSystemRef: BuildSystemRef

    /// The interrupt handler.
    let interruptHandler: InterruptHandler

    /// The diagnostics engine.
    let diagnostics: DiagnosticsEngine = DiagnosticsEngine(
        handlers: [DiagnosticsEngineHandler.default.diagnosticsHandler])

    /// The execution status of the tool.
    var executionStatus: ExecutionStatus = .success

    /// The stream to print standard output on.
    fileprivate(set) var stdoutStream: OutputByteStream = TSCBasic.stdoutStream

    /// Holds the currently active workspace.
    ///
    /// It is not initialized in init() because for some of the commands like package init , usage etc,
    /// workspace is not needed, infact it would be an error to ask for the workspace object
    /// for package init because the Manifest file should *not* present.
    private var _workspace: Workspace?
    private var _workspaceDelegate: ToolWorkspaceDelegate?

    /// Create an instance of this tool.
    ///
    /// - parameter args: The command line arguments to be passed to this tool.
    public init(options: SwiftToolOptions) throws {
        // Capture the original working directory ASAP.
        guard let cwd = localFileSystem.currentWorkingDirectory else {
            diagnostics.emit(error: "couldn't determine the current working directory")
            throw ExitCode.failure
        }
        originalWorkingDirectory = cwd

        do {
            try Self.postprocessArgParserResult(options: options, diagnostics: diagnostics)
            self.options = options
            
            // Honor package-path option is provided.
            if let packagePath = options.packagePath ?? options.chdir {
                try ProcessEnv.chdir(packagePath)
            }

            // Force building with the native build system on other platforms than macOS.
          #if !os(macOS)
            self.options._buildSystem = .native
          #endif

            let processSet = ProcessSet()
            let buildSystemRef = BuildSystemRef()
            interruptHandler = try InterruptHandler {
                // Terminate all processes on receiving an interrupt signal.
                processSet.terminate()
                buildSystemRef.buildSystem?.cancel()

              #if os(Windows)
                // Exit as if by signal()
                TerminateProcess(GetCurrentProcess(), 3)
              #elseif os(macOS) || os(OpenBSD)
                // Install the default signal handler.
                var action = sigaction()
                action.__sigaction_u.__sa_handler = SIG_DFL
                sigaction(SIGINT, &action, nil)
                kill(getpid(), SIGINT)
              #elseif os(Android)
                // Install the default signal handler.
                var action = sigaction()
                action.sa_handler = SIG_DFL
                sigaction(SIGINT, &action, nil)
                kill(getpid(), SIGINT)
              #else
                var action = sigaction()
                action.__sigaction_handler = unsafeBitCast(
                    SIG_DFL,
                    to: sigaction.__Unnamed_union___sigaction_handler.self)
                sigaction(SIGINT, &action, nil)
                kill(getpid(), SIGINT)
              #endif
            }
            self.processSet = processSet
            self.buildSystemRef = buildSystemRef

        } catch {
            handle(error: error)
            throw ExitCode.failure
        }

        // Create local variables to use while finding build path to avoid capture self before init error.
        let customBuildPath = options.buildPath
        let packageRoot = findPackageRoot()

        self.packageRoot = packageRoot
        self.buildPath = getEnvBuildPath(workingDir: cwd) ??
            customBuildPath ??
            (packageRoot ?? cwd).appending(component: ".build")
        
        // Setup the globals.
        verbosity = Verbosity(rawValue: options.verbosity)
        Process.verbose = verbosity != .concise
    }
    
    static func postprocessArgParserResult(options: SwiftToolOptions, diagnostics: DiagnosticsEngine) throws {
        if options.chdir != nil {
            diagnostics.emit(warning: "'--chdir/-C' option is deprecated; use '--package-path' instead")
        }
        
        if options.multirootPackageDataFile != nil {
            diagnostics.emit(.unsupportedFlag("--multiroot-data-file"))
        }
        
        if options.useExplicitModuleBuild && !options.useIntegratedSwiftDriver {
            diagnostics.emit(error: "'--experimental-explicit-module-build' option requires '--use-integrated-swift-driver'")
        }
        
        if !options.archs.isEmpty && options.customCompileTriple != nil {
            diagnostics.emit(.mutuallyExclusiveArgumentsError(arguments: ["--arch", "--triple"]))
        }

        // --enable-test-discovery should never be called on darwin based platforms
        #if canImport(Darwin)
        if options.enableTestDiscovery {
            diagnostics.emit(warning: "'--enable-test-discovery' option is deprecated; tests are automatically discovered on all platforms")
        }
        #endif

        if options.shouldDisableManifestCaching {
            diagnostics.emit(warning: "'--disable-package-manifest-caching' option is deprecated; use '--manifest-caching' instead")
        }
    }

    func editablesPath() throws -> AbsolutePath {
        if let multiRootPackageDataFile = options.multirootPackageDataFile {
            return multiRootPackageDataFile.appending(component: "Packages")
        }
        return try getPackageRoot().appending(component: "Packages")
    }

    func resolvedFilePath() throws -> AbsolutePath {
        if let multiRootPackageDataFile = options.multirootPackageDataFile {
            return multiRootPackageDataFile.appending(components: "xcshareddata", "swiftpm", "Package.resolved")
        }
        return try getPackageRoot().appending(component: "Package.resolved")
    }

    func configFilePath() throws -> AbsolutePath {
        // Look for the override in the environment.
        if let envPath = ProcessEnv.vars["SWIFTPM_MIRROR_CONFIG"] {
            return try AbsolutePath(validating: envPath)
        }

        // Otherwise, use the default path.
        if let multiRootPackageDataFile = options.multirootPackageDataFile {
            return multiRootPackageDataFile.appending(components: "xcshareddata", "swiftpm", "config")
        }
        return try getPackageRoot().appending(components: ".swiftpm", "config")
    }

    func getSwiftPMConfig() throws -> Workspace.Configuration {
        return try _swiftpmConfig.get()
    }

    private lazy var _swiftpmConfig: Result<Workspace.Configuration, Swift.Error> = {
        return Result(catching: { try Workspace.Configuration(path: try configFilePath()) })
    }()
    
    func resolvedNetrcFilePath() throws -> AbsolutePath? {
        guard options.netrc ||
                options.netrcFilePath != nil ||
                options.netrcOptional else { return nil }
        
        let resolvedPath: AbsolutePath = options.netrcFilePath ?? AbsolutePath("\(NSHomeDirectory())/.netrc")
        guard localFileSystem.exists(resolvedPath) else {
            if !options.netrcOptional {
                diagnostics.emit(error: "Cannot find mandatory .netrc file at \(resolvedPath.pathString).  To make .netrc file optional, use --netrc-optional flag.")
                throw ExitCode.failure
            } else {
                diagnostics.emit(warning: "Did not find optional .netrc file at \(resolvedPath.pathString).")
                return nil
            }
        }
        return resolvedPath
    }

    private func getCachePath(fileSystem: FileSystem = localFileSystem) throws -> AbsolutePath? {
        if let explicitCachePath = options.cachePath {
            // Create the explicit cache path if necessary
            if !fileSystem.exists(explicitCachePath) {
                try fileSystem.createDirectory(explicitCachePath, recursive: true)
            }
            return explicitCachePath
        }

        do {
            return try fileSystem.getOrCreateSwiftPMCacheDirectory()
        } catch {
            self.diagnostics.emit(warning: "Failed creating default cache locations, \(error)")
            return nil
        }
    }

    func getConfigPath(fileSystem: FileSystem = localFileSystem) throws -> AbsolutePath? {
        if let explicitConfigPath = options.configPath {
            // Create the explicit config path if necessary
            if !fileSystem.exists(explicitConfigPath) {
                try fileSystem.createDirectory(explicitConfigPath, recursive: true)
            }
            return explicitConfigPath
        }

        do {
            return try fileSystem.getOrCreateSwiftPMConfigDirectory()
        } catch {
            self.diagnostics.emit(warning: "Failed creating default config locations, \(error)")
            return nil
        }
    }

    /// Returns the currently active workspace.
    func getActiveWorkspace() throws -> Workspace {
        if let workspace = _workspace {
            return workspace
        }

        let isVerbose = options.verbosity != 0
        let delegate = ToolWorkspaceDelegate(self.stdoutStream, isVerbose: isVerbose, diagnostics: diagnostics)
        let provider = GitRepositoryProvider(processSet: processSet)
        let cachePath = self.options.useRepositoriesCache ? try self.getCachePath() : .none
        _  = try self.getConfigPath() // TODO: actually use this in the workspace 
        let isXcodeBuildSystemEnabled = self.options.buildSystem == .xcode
        let workspace = Workspace(
            dataPath: buildPath,
            editablesPath: try editablesPath(),
            pinsFile: try resolvedFilePath(),
            manifestLoader: try getManifestLoader(),
            toolsVersionLoader: ToolsVersionLoader(),
            delegate: delegate,
            config: try getSwiftPMConfig(),
            repositoryProvider: provider,
            netrcFilePath: try resolvedNetrcFilePath(),
            additionalFileRules: isXcodeBuildSystemEnabled ? FileRuleDescription.xcbuildFileTypes : [],
            isResolverPrefetchingEnabled: options.shouldEnableResolverPrefetching,
            skipUpdate: options.skipDependencyUpdate,
            enableResolverTrace: options.enableResolverTrace,
            cachePath: cachePath
        )
        _workspace = workspace
        _workspaceDelegate = delegate
        return workspace
    }

    /// Start redirecting the standard output stream to the standard error stream.
    func redirectStdoutToStderr() {
        self.stdoutStream = TSCBasic.stderrStream
        DiagnosticsEngineHandler.default.stdoutStream = TSCBasic.stderrStream
    }

    /// Resolve the dependencies.
    func resolve() throws {
        let workspace = try getActiveWorkspace()
        let root = try getWorkspaceRoot()

        if options.forceResolvedVersions {
            try workspace.resolveToResolvedVersion(root: root, diagnostics: diagnostics)
        } else {
            try workspace.resolve(root: root, diagnostics: diagnostics)
        }

        // Throw if there were errors when loading the graph.
        // The actual errors will be printed before exiting.
        guard !diagnostics.hasErrors else {
            throw ExitCode.failure
        }
    }

    /// Fetch and load the complete package graph.
    ///
    /// - Parameters:
    ///   - explicitProduct: The product specified on the command line to a “swift run” or “swift build” command. This allows executables from dependencies to be run directly without having to hook them up to any particular target.
    @discardableResult
    func loadPackageGraph(
        explicitProduct: String? = nil,
        createMultipleTestProducts: Bool = false,
        createREPLProduct: Bool = false
    ) throws -> PackageGraph {
        do {
            let workspace = try getActiveWorkspace()

            // Fetch and load the package graph.
            let graph = try workspace.loadPackageGraph(
                rootInput: getWorkspaceRoot(),
                explicitProduct: explicitProduct,
                createMultipleTestProducts: createMultipleTestProducts,
                createREPLProduct: createREPLProduct,
                forceResolvedVersions: options.forceResolvedVersions,
                diagnostics: diagnostics
            )

            // Throw if there were errors when loading the graph.
            // The actual errors will be printed before exiting.
            guard !diagnostics.hasErrors else {
                throw ExitCode.failure
            }
            return graph
        } catch {
            throw error
        }
    }
    
    /// Invoke plugins for any reachable targets in the graph, and return a mapping from targets to corresponding evaluation results.
    func invokePlugins(graph: PackageGraph) throws -> [ResolvedTarget: [PluginInvocationResult]] {
        do {
            // Configure the plugin invocation inputs.

            // The `plugins` directory is inside the workspace's main data directory, and contains all temporary
            // files related to all plugins in the workspace.
            let buildEnvironment = try buildParameters().buildEnvironment
            let dataDir = try self.getActiveWorkspace().dataPath
            let pluginsDir = dataDir.appending(component: "plugins")
            
            // The `cache` directory is in the plugins directory and is where the plugin script runner caches
            // compiled plugin binaries and any other derived information.
            let cacheDir = pluginsDir.appending(component: "cache")
            let pluginScriptRunner = try DefaultPluginScriptRunner(cacheDir: cacheDir, manifestResources: self._hostToolchain.get().manifestResources)
            
            // The `outputs` directory contains subdirectories for each combination of package, target, and plugin.
            // Each usage of a plugin has an output directory that is writable by the plugin, where it can write
            // additional files, and to which it can configure tools to write their outputs, etc.
            let outputDir = pluginsDir.appending(component: "outputs")
            
            // The `tools` directory contains any command line tools (executables) that are available for any commands
            // defined by the executable.
            // FIXME: At the moment we just pass the built products directory for the host. We will need to extend this
            // with a map of the names of tools available to each plugin. In particular this would not work with any
            // binary targets.
            let builtToolsDir = dataDir.appending(components: try self._hostToolchain.get().triple.tripleString, buildEnvironment.configuration.dirname)
            let diagnostics = DiagnosticsEngine()
            
            // Create the cache directory, if needed.
            try localFileSystem.createDirectory(cacheDir, recursive: true)

            // Ask the graph to invoke plugins, and return the result.
            let result = try graph.invokePlugins(outputDir: outputDir, builtToolsDir: builtToolsDir, pluginScriptRunner: pluginScriptRunner, diagnostics: diagnostics, fileSystem: localFileSystem)
            return result
        }
        catch {
            throw error
        }
    }

    /// Returns the user toolchain to compile the actual product.
    func getToolchain() throws -> UserToolchain {
        return try _destinationToolchain.get()
    }

    func getManifestLoader() throws -> ManifestLoader {
        return try _manifestLoader.get()
    }

    private func canUseCachedBuildManifest() throws -> Bool {
        if !self.options.cacheBuildManifest {
            return false
        }

        let buildParameters = try self.buildParameters()
        let haveBuildManifestAndDescription =
            localFileSystem.exists(buildParameters.llbuildManifest) &&
            localFileSystem.exists(buildParameters.buildDescriptionPath)

        if !haveBuildManifestAndDescription {
            return false
        }

        // Perform steps for build manifest caching if we can enabled it.
        //
        // FIXME: We don't add edited packages in the package structure command yet (SR-11254).
        let hasEditedPackages = try self.getActiveWorkspace().state.dependencies.contains(where: { $0.isEdited })
        if hasEditedPackages {
            return false
        }

        return true
    }

    func createBuildOperation(explicitProduct: String? = nil, cacheBuildManifest: Bool = true) throws -> BuildOperation {
        // Load a custom package graph which has a special product for REPL.
        let graphLoader = { try self.loadPackageGraph(explicitProduct: explicitProduct) }

        // Construct the build operation.
        let buildOp = try BuildOperation(
            buildParameters: buildParameters(),
            cacheBuildManifest: cacheBuildManifest && self.canUseCachedBuildManifest(),
            packageGraphLoader: graphLoader,
            pluginInvoker: { _ in [:] },
            diagnostics: diagnostics,
            stdoutStream: self.stdoutStream
        )

        // Save the instance so it can be cancelled from the int handler.
        buildSystemRef.buildSystem = buildOp
        return buildOp
    }

    func createBuildSystem(explicitProduct: String? = nil, buildParameters: BuildParameters? = nil) throws -> BuildSystem {
        let buildSystem: BuildSystem
        switch options.buildSystem {
        case .native:
            let graphLoader = { try self.loadPackageGraph(explicitProduct: explicitProduct) }
            let pluginInvoker = { try self.invokePlugins(graph: $0) }
            buildSystem = try BuildOperation(
                buildParameters: buildParameters ?? self.buildParameters(),
                cacheBuildManifest: self.canUseCachedBuildManifest(),
                packageGraphLoader: graphLoader,
                pluginInvoker: pluginInvoker,
                diagnostics: diagnostics,
                stdoutStream: stdoutStream
            )
        case .xcode:
            let graphLoader = { try self.loadPackageGraph(explicitProduct: explicitProduct, createMultipleTestProducts: true) }
            // FIXME: Implement the custom build command provider also.
            buildSystem = try XcodeBuildSystem(
                buildParameters: buildParameters ?? self.buildParameters(),
                packageGraphLoader: graphLoader,
                isVerbose: verbosity != .concise,
                diagnostics: diagnostics,
                stdoutStream: stdoutStream
            )
        }

        // Save the instance so it can be cancelled from the int handler.
        buildSystemRef.buildSystem = buildSystem
        return buildSystem
    }

    /// Return the build parameters.
    func buildParameters() throws -> BuildParameters {
        return try _buildParameters.get()
    }

    private lazy var _buildParameters: Result<BuildParameters, Swift.Error> = {
        return Result(catching: {
            let toolchain = try self.getToolchain()
            let triple = toolchain.triple

            // Use "apple" as the subdirectory because in theory Xcode build system
            // can be used to build for any Apple platform and it has it's own
            // conventions for build subpaths based on platforms.
            let dataPath = buildPath.appending(
                 component: options.buildSystem == .xcode ? "apple" : triple.tripleString)
            return BuildParameters(
                dataPath: dataPath,
                configuration: options.configuration,
                toolchain: toolchain,
                destinationTriple: triple,
                archs: options.archs,
                flags: options.buildFlags,
                xcbuildFlags: options.xcbuildFlags,
                jobs: options.jobs ?? UInt32(ProcessInfo.processInfo.activeProcessorCount),
                shouldLinkStaticSwiftStdlib: options.shouldLinkStaticSwiftStdlib,
                sanitizers: options.enabledSanitizers,
                enableCodeCoverage: options.shouldEnableCodeCoverage,
                indexStoreMode: options.indexStoreMode.indexStoreMode,
                enableParseableModuleInterfaces: options.shouldEnableParseableModuleInterfaces,
                emitSwiftModuleSeparately: options.emitSwiftModuleSeparately,
                useIntegratedSwiftDriver: options.useIntegratedSwiftDriver,
                useExplicitModuleBuild: options.useExplicitModuleBuild,
                isXcodeBuildSystemEnabled: options.buildSystem == .xcode,
                printManifestGraphviz: options.printManifestGraphviz,
                forceTestDiscovery: options.enableTestDiscovery // backwards compatibility, remove with --enable-test-discovery
            )
        })
    }()

    /// Lazily compute the destination toolchain.
    private lazy var _destinationToolchain: Result<UserToolchain, Swift.Error> = {
        var destination: Destination
        let hostDestination: Destination
        do {
            hostDestination = try self._hostToolchain.get().destination
            // Create custom toolchain if present.
            if let customDestination = self.options.customCompileDestination {
                destination = try Destination(fromFile: customDestination)
            } else {
                // Otherwise use the host toolchain.
                destination = hostDestination
            }
        } catch {
            return .failure(error)
        }
        // Apply any manual overrides.
        if let triple = self.options.customCompileTriple {
            destination.target = triple
        }
        if let binDir = self.options.customCompileToolchain {
            destination.binDir = binDir.appending(components: "usr", "bin")
        }
        if let sdk = self.options.customCompileSDK {
            destination.sdk = sdk
        } else if let target = destination.target, target.isWASI() {
            // Set default SDK path when target is WASI whose SDK is embeded
            // in Swift toolchain
            do {
                let compilers = try UserToolchain.determineSwiftCompilers(binDir: destination.binDir)
                destination.sdk = compilers.compile
                    .parentDirectory // bin
                    .parentDirectory // usr
                    .appending(components: "share", "wasi-sysroot")
            } catch {
                return .failure(error)
            }
        }
        destination.archs = options.archs

        // Check if we ended up with the host toolchain.
        if hostDestination == destination {
            return self._hostToolchain
        }

        return Result(catching: { try UserToolchain(destination: destination) })
    }()

    /// Lazily compute the host toolchain used to compile the package description.
    private lazy var _hostToolchain: Result<UserToolchain, Swift.Error> = {
        return Result(catching: {
            try UserToolchain(destination: Destination.hostDestination(
                        originalWorkingDirectory: self.originalWorkingDirectory))
        })
    }()

    private lazy var _manifestLoader: Result<ManifestLoader, Swift.Error> = {
        return Result(catching: {
            let cachePath: AbsolutePath?
            switch (self.options.shouldDisableManifestCaching, self.options.manifestCachingMode) {
            case (true, _):
                // backwards compatibility
                cachePath = nil
            case (false, .none):
                cachePath = nil
            case (false, .local):
                cachePath = self.buildPath
            case (false, .shared):
                cachePath = try self.getCachePath().map{ $0.appending(component: "manifests") }
            }

            var  extraManifestFlags = self.options.manifestFlags
            // Disable the implicit concurrency import if the compiler in use supports it to avoid warnings if we are building against an older SDK that does not contain a Concurrency module.
            if SwiftTargetBuildDescription.checkSupportedFrontendFlags(flags: ["disable-implicit-concurrency-module-import"], fs: localFileSystem) {
                extraManifestFlags += ["-Xfrontend", "-disable-implicit-concurrency-module-import"]
            }

            return try ManifestLoader(
                // Always use the host toolchain's resources for parsing manifest.
                manifestResources: self._hostToolchain.get().manifestResources,
                isManifestSandboxEnabled: !self.options.shouldDisableSandbox,
                cacheDir: cachePath,
                extraManifestFlags: extraManifestFlags
            )
        })
    }()

    /// An enum indicating the execution status of run commands.
    enum ExecutionStatus {
        case success
        case failure
    }
}

/// Returns path of the nearest directory containing the manifest file w.r.t
/// current working directory.
private func findPackageRoot() -> AbsolutePath? {
    guard var root = localFileSystem.currentWorkingDirectory else {
        return nil
    }
    // FIXME: It would be nice to move this to a generalized method which takes path and predicate and
    // finds the lowest path for which the predicate is true.
    while !localFileSystem.isFile(root.appending(component: Manifest.filename)) {
        root = root.parentDirectory
        guard !root.isRoot else {
            return nil
        }
    }
    return root
}

/// Returns the build path from the environment, if present.
private func getEnvBuildPath(workingDir: AbsolutePath) -> AbsolutePath? {
    // Don't rely on build path from env for SwiftPM's own tests.
    guard ProcessEnv.vars["SWIFTPM_TESTS_MODULECACHE"] == nil else { return nil }
    guard let env = ProcessEnv.vars["SWIFTPM_BUILD_DIR"] else { return nil }
    return AbsolutePath(env, relativeTo: workingDir)
}

/// A wrapper to hold the build system so we can use it inside
/// the int. handler without requiring to initialize it.
final class BuildSystemRef {
    var buildSystem: BuildSystem?
}

extension Diagnostic.Message {
    static func unsupportedFlag(_ flag: String) -> Diagnostic.Message {
        .warning("\(flag) is an *unsupported* option which can be removed at any time; do not rely on it")
    }
}

extension DispatchTimeInterval {
    var descriptionInSeconds: String {
        switch self {
        case .seconds(let value):
            return "\(value)s"
        case .milliseconds(let value):
            return String(format: "%.2f", Double(value)/Double(1000)) + "s"
        case .microseconds(let value):
            return String(format: "%.2f", Double(value)/Double(1_000_000)) + "s"
        case .nanoseconds(let value):
            return String(format: "%.2f", Double(value)/Double(1_000_000_000)) + "s"
        case .never:
            return "n/a"
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        @unknown default:
            return "n/a"
        #endif
        }
    }
}
