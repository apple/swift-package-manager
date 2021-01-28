/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basics
import TSCBasic
import TSCUtility
import Foundation
import PackageLoading
import PackageModel
import PackageGraph
import SourceControl

/// Enumeration of the different reasons for which the resolver needs to be run.
public enum WorkspaceResolveReason: Equatable {
    /// Resolution was forced.
    case forced

    /// Requirements were added for new packages.
    case newPackages(packages: [PackageReference])

    /// The requirement of a dependency has changed.
    case packageRequirementChange(
        package: PackageReference,
        state: ManagedDependency.State?,
        requirement: PackageRequirement
    )

    /// An unknown reason.
    case other
}

/// The delegate interface used by the workspace to report status information.
public protocol WorkspaceDelegate: AnyObject {

    /// The workspace is about to load a package manifest (which might be in the cache, or might need to be parsed). Note that this does not include speculative loading of manifests that may occr during dependency resolution; rather, it includes only the final manifest loading that happens after a particular package version has been checked out into a working directory.
    func willLoadManifest(packagePath: AbsolutePath, url: String, version: Version?, packageKind: PackageReference.Kind)

    /// The workspace has loaded a package manifest, either successfully or not. The manifest is nil if an error occurs, in which case there will also be at least one error in the list of diagnostics (there may be warnings even if a manifest is loaded successfully).
    func didLoadManifest(packagePath: AbsolutePath, url: String, version: Version?, packageKind: PackageReference.Kind, manifest: Manifest?, diagnostics: [Diagnostic])

    /// The workspace has started fetching this repository.
    func fetchingWillBegin(repository: String, fetchDetails: RepositoryManager.FetchDetails?)

    /// The workspace has started fetching this repository.
    @available(*, deprecated)
    func fetchingWillBegin(repository: String)

    /// The workspace has finished fetching this repository.
    func fetchingDidFinish(repository: String, fetchDetails: RepositoryManager.FetchDetails?, diagnostic: Diagnostic?)

    /// The workspace has finished fetching this repository.
    @available(*, deprecated)
    func fetchingDidFinish(repository: String, diagnostic: Diagnostic?)

    /// The workspace has started updating this repository.
    func repositoryWillUpdate(_ repository: String)

    /// The workspace has finished updating this repository.
    func repositoryDidUpdate(_ repository: String)

    /// The workspace has finished updating and all the dependencies are already up-to-date.
    func dependenciesUpToDate()

    /// The workspace is about to clone a repository from the local cache to a working directory.
    func willClone(repository url: String, to path: AbsolutePath)

    /// The workspace has cloned a repository from the local cache to a working directory. The error indicates whether the operation failed or succeeded.
    func didClone(repository url: String, to path: AbsolutePath, error: Diagnostic?)

    /// The workspace has started cloning this repository. This callback is marginally deprecated in favor of the willClone/didClone pair.
    func cloning(repository: String)

    /// The workspace is about to check out a particular revision of a working directory.
    func willCheckOut(repository url: String, revision: String, at path: AbsolutePath)

    /// The workspace has checked out a particular revision of a working directory. The error indicates whether the operation failed or succeeded.
    func didCheckOut(repository url: String, revision: String, at path: AbsolutePath, error: Diagnostic?)

    /// The workspace is checking out a repository. This callback is marginally deprecated in favor of the willCheckOut/didCheckOut pair.
    func checkingOut(repository: String, atReference reference: String, to path: AbsolutePath)

    /// The workspace is removing this repository because it is no longer needed.
    func removing(repository: String)

    /// Called when the resolver is about to be run.
    func willResolveDependencies(reason: WorkspaceResolveReason)

    /// Called when the Package.resolved file is changed *outside* of libSwiftPM operations.
    ///
    /// This is only fired when activated using Workspace's watchResolvedFile() method.
    func resolvedFileChanged()

    /// The workspace is downloading a binary artifact.
    func downloadingBinaryArtifact(from url: String, bytesDownloaded: Int64, totalBytesToDownload: Int64?)

    /// The workspace finished downloading all binary artifacts.
    func didDownloadBinaryArtifacts()
}

public extension WorkspaceDelegate {
    func willLoadManifest(packagePath: AbsolutePath, url: String, version: Version?, packageKind: PackageReference.Kind) {}
    func didLoadManifest(packagePath: AbsolutePath, url: String, version: Version?, packageKind: PackageReference.Kind, manifest: Manifest?, diagnostics: [Diagnostic]) {}
    func willClone(repository url: String, to path: AbsolutePath) {
        cloning(repository: url)
    }
    func didClone(repository url: String, to path: AbsolutePath, error: Diagnostic?) {}
    func cloning(repository: String) {}
    func willCheckOut(repository url: String, revision: String, at path: AbsolutePath) {
        checkingOut(repository: url, atReference: revision, to: path)
    }
    func didCheckOut(repository url: String, revision: String, at path: AbsolutePath, error: Diagnostic?) {}
    func checkingOut(repository: String, atReference: String, to path: AbsolutePath) {}
    func repositoryWillUpdate(_ repository: String) {}
    func repositoryDidUpdate(_ repository: String) {}
    func willResolveDependencies(reason: WorkspaceResolveReason) {}
    func dependenciesUpToDate() {}
    func resolvedFileChanged() {}
    func downloadingBinaryArtifact(from url: String, bytesDownloaded: Int64, totalBytesToDownload: Int64?) {}
    func didDownloadBinaryArtifacts() {}

    func fetchingWillBegin(repository: String) {}
    func fetchingDidFinish(repository: String, diagnostic: Diagnostic?) {}

    @available(*, deprecated)
    func fetchingWillBegin(repository: String, fetchDetails: RepositoryManager.FetchDetails?) {
        fetchingWillBegin(repository: repository)
    }

    @available(*, deprecated)
    func fetchingDidFinish(repository: String, fetchDetails: RepositoryManager.FetchDetails?, diagnostic: Diagnostic?) {
        fetchingDidFinish(repository: repository, diagnostic: diagnostic)
    }

}

private class WorkspaceRepositoryManagerDelegate: RepositoryManagerDelegate {
    unowned let workspaceDelegate: WorkspaceDelegate

    init(workspaceDelegate: WorkspaceDelegate) {
        self.workspaceDelegate = workspaceDelegate
    }

    func fetchingWillBegin(handle: RepositoryManager.RepositoryHandle, fetchDetails details: RepositoryManager.FetchDetails?) {
        workspaceDelegate.fetchingWillBegin(repository: handle.repository.url, fetchDetails: details)
    }

    func fetchingDidFinish(handle: RepositoryManager.RepositoryHandle, fetchDetails details: RepositoryManager.FetchDetails?, error: Swift.Error?) {
        let diagnostic: Diagnostic? = error.flatMap({
            let engine = DiagnosticsEngine()
            engine.emit($0)
            return engine.diagnostics.first
        })
        workspaceDelegate.fetchingDidFinish(repository: handle.repository.url, fetchDetails: details, diagnostic: diagnostic)
    }

    func handleWillUpdate(handle: RepositoryManager.RepositoryHandle) {
        workspaceDelegate.repositoryWillUpdate(handle.repository.url)
    }

    func handleDidUpdate(handle: RepositoryManager.RepositoryHandle) {
        workspaceDelegate.repositoryDidUpdate(handle.repository.url)
    }
}

/// A workspace represents the state of a working project directory.
///
/// The workspace is responsible for managing the persistent working state of a
/// project directory (e.g., the active set of checked out repositories) and for
/// coordinating the changes to that state.
///
/// This class glues together the basic facilities provided by the dependency
/// resolution, source control, and package graph loading subsystems into a
/// cohesive interface for exposing the high-level operations for the package
/// manager to maintain working package directories.
///
/// This class does *not* support concurrent operations.
public class Workspace {
    /// The delegate interface.
    public weak var delegate: WorkspaceDelegate?

    /// The path of the workspace data.
    public let dataPath: AbsolutePath

    /// The swiftpm config.
    fileprivate let config: Workspace.Configuration

    /// The current persisted state of the workspace.
    public let state: WorkspaceState

    /// The Pins store. The pins file will be created when first pin is added to pins store.
    public let pinsStore: LoadableResult<PinsStore>

    /// The path to the Package.resolved file for this workspace.
    public let resolvedFile: AbsolutePath

    /// The path for working repository clones (checkouts).
    public let checkoutsPath: AbsolutePath

    /// The path for downloaded binary artifacts.
    public let artifactsPath: AbsolutePath

    /// The path where packages which are put in edit mode are checked out.
    public let editablesPath: AbsolutePath

    /// The file system on which the workspace will operate.
    fileprivate var fileSystem: FileSystem

    /// The manifest loader to use.
    public let manifestLoader: ManifestLoaderProtocol

    /// The tools version currently in use.
    fileprivate let currentToolsVersion: ToolsVersion

    /// The manifest loader to use.
    fileprivate let toolsVersionLoader: ToolsVersionLoaderProtocol

    /// The repository manager.
    public let repositoryManager: RepositoryManager

    /// The package container provider.
    fileprivate let containerProvider: RepositoryPackageContainerProvider

    /// The downloader used for downloading binary artifacts.
    fileprivate let downloader: Downloader

    fileprivate let netrcFilePath: AbsolutePath?

    /// The downloader used for unarchiving binary artifacts.
    fileprivate let archiver: Archiver

    /// The algorithm used for generating file checksums.
    fileprivate let checksumAlgorithm: HashAlgorithm

    /// Enable prefetching containers in resolver.
    fileprivate let isResolverPrefetchingEnabled: Bool

    /// Skip updating containers while fetching them.
    fileprivate let skipUpdate: Bool

    /// The active package resolver. This is set during a dependency resolution operation.
    fileprivate var activeResolver: PubgrubDependencyResolver?

    /// Write dependency resolver trace to a file.
    fileprivate let enableResolverTrace: Bool

    fileprivate var resolvedFileWatcher: ResolvedFileWatcher?

    fileprivate let additionalFileRules: [FileRuleDescription]

    private let verbosity: Verbosity

    private let queue = DispatchQueue(label: "org.swift.swiftpm.workspace", attributes: .concurrent)

    /// Create a new package workspace.
    ///
    /// This will automatically load the persisted state for the package, if
    /// present. If the state isn't present then a default state will be
    /// constructed.
    ///
    /// - Parameters:
    ///   - dataPath: The path for the workspace data files.
    ///   - editablesPath: The path where editable packages should be placed.
    ///   - pinsFile: The path to pins file. If pins file is not present, it will be created.
    ///   - manifestLoader: The manifest loader.
    ///   - fileSystem: The file system to operate on.
    ///   - repositoryProvider: The repository provider to use in repository manager.
    /// - Throws: If the state was present, but could not be loaded.
    public init(
        dataPath: AbsolutePath,
        editablesPath: AbsolutePath,
        pinsFile: AbsolutePath,
        manifestLoader: ManifestLoaderProtocol,
        repositoryManager: RepositoryManager? = nil,
        currentToolsVersion: ToolsVersion = ToolsVersion.currentToolsVersion,
        toolsVersionLoader: ToolsVersionLoaderProtocol = ToolsVersionLoader(),
        delegate: WorkspaceDelegate? = nil,
        config: Workspace.Configuration = Workspace.Configuration(),
        fileSystem: FileSystem = localFileSystem,
        repositoryProvider: RepositoryProvider = GitRepositoryProvider(),
        downloader: Downloader = FoundationDownloader(),
        netrcFilePath: AbsolutePath? = nil,
        archiver: Archiver = ZipArchiver(),
        checksumAlgorithm: HashAlgorithm = SHA256(),
        additionalFileRules: [FileRuleDescription] = [],
        isResolverPrefetchingEnabled: Bool = false,
        enablePubgrubResolver: Bool = false,
        skipUpdate: Bool = false,
        enableResolverTrace: Bool = false,
        cachePath: AbsolutePath? = nil,
        verbosity: Verbosity
    ) {
        self.delegate = delegate
        self.dataPath = dataPath
        self.config = config
        self.editablesPath = editablesPath
        self.manifestLoader = manifestLoader
        self.currentToolsVersion = currentToolsVersion
        self.toolsVersionLoader = toolsVersionLoader
        self.downloader = downloader
        self.netrcFilePath = netrcFilePath
        self.archiver = archiver
        self.verbosity = verbosity

        var checksumAlgorithm = checksumAlgorithm
        #if canImport(CryptoKit)
        if checksumAlgorithm is SHA256, #available(macOS 10.15, *) {
            checksumAlgorithm = CryptoKitSHA256()
        }
        #endif
        self.checksumAlgorithm = checksumAlgorithm
        self.isResolverPrefetchingEnabled = isResolverPrefetchingEnabled
        self.skipUpdate = skipUpdate
        self.enableResolverTrace = enableResolverTrace
        self.resolvedFile = pinsFile
        self.additionalFileRules = additionalFileRules

        let repositoriesPath = self.dataPath.appending(component: "repositories")
        let repositoriesCachePath = cachePath.map { $0.appending(component: "repositories") }
        let repositoryManager = repositoryManager ?? RepositoryManager(
            path: repositoriesPath,
            provider: repositoryProvider,
            delegate: delegate.map(WorkspaceRepositoryManagerDelegate.init(workspaceDelegate:)),
            fileSystem: fileSystem,
            cachePath: repositoriesCachePath)
        self.repositoryManager = repositoryManager

        self.checkoutsPath = self.dataPath.appending(component: "checkouts")
        self.artifactsPath = self.dataPath.appending(component: "artifacts")

        self.containerProvider = RepositoryPackageContainerProvider(
            repositoryManager: repositoryManager,
            mirrors: self.config.mirrors,
            manifestLoader: manifestLoader,
            currentToolsVersion: currentToolsVersion,
            toolsVersionLoader: toolsVersionLoader,
            verbosity: self.verbosity
        )
        self.fileSystem = fileSystem

        self.pinsStore = LoadableResult {
            try PinsStore(pinsFile: pinsFile, fileSystem: fileSystem)
        }
        self.state = WorkspaceState(dataPath: dataPath, fileSystem: fileSystem)
    }

    /// A convenience method for creating a workspace for the given root
    /// package path.
    ///
    /// The root package path is used to compute the build directory and other
    /// default paths.
    public static func create(
        forRootPackage packagePath: AbsolutePath,
        manifestLoader: ManifestLoaderProtocol,
        repositoryManager: RepositoryManager? = nil,
        delegate: WorkspaceDelegate? = nil,
        verbosity: Verbosity
    ) -> Workspace {
        return Workspace(
            dataPath: packagePath.appending(component: ".build"),
            editablesPath: packagePath.appending(component: "Packages"),
            pinsFile: packagePath.appending(component: "Package.resolved"),
            manifestLoader: manifestLoader,
            repositoryManager: repositoryManager,
            delegate: delegate,
            verbosity: verbosity
        )
    }
}

// MARK: - Public API

extension Workspace {

    /// Puts a dependency in edit mode creating a checkout in editables directory.
    ///
    /// - Parameters:
    ///     - packageName: The name of the package to edit.
    ///     - path: If provided, creates or uses the checkout at this location.
    ///     - revision: If provided, the revision at which the dependency
    ///       should be checked out to otherwise current revision.
    ///     - checkoutBranch: If provided, a new branch with this name will be
    ///       created from the revision provided.
    ///     - diagnostics: The diagnostics engine that reports errors, warnings
    ///       and notes.
    public func edit(
        packageName: String,
        path: AbsolutePath? = nil,
        revision: Revision? = nil,
        checkoutBranch: String? = nil,
        diagnostics: DiagnosticsEngine
    ) {
        do {
            try _edit(
                packageName: packageName,
                path: path,
                revision: revision,
                checkoutBranch: checkoutBranch,
                diagnostics: diagnostics)
        } catch {
            diagnostics.emit(error)
        }
    }

    /// Ends the edit mode of an edited dependency.
    ///
    /// This will re-resolve the dependencies after ending edit as the original
    /// checkout may be outdated.
    ///
    /// - Parameters:
    ///     - packageName: The name of the package to edit.
    ///     - forceRemove: If true, the dependency will be unedited even if has unpushed
    ///           or uncommited changes. Otherwise will throw respective errors.
    ///     - root: The workspace root. This is used to resolve the dependencies post unediting.
    ///     - diagnostics: The diagnostics engine that reports errors, warnings
    ///           and notes.
    public func unedit(
        packageName: String,
        forceRemove: Bool,
        root: PackageGraphRootInput,
        diagnostics: DiagnosticsEngine
    ) throws {
        guard let dependency = state.dependencies[forNameOrIdentity: packageName] else {
            diagnostics.emit(.dependencyNotFound(packageName: packageName))
            return
        }

        try unedit(dependency: dependency, forceRemove: forceRemove, root: root, diagnostics: diagnostics)
    }

    /// Resolve a package at the given state.
    ///
    /// Only one of version, branch and revision will be used and in the same
    /// order. If none of these is provided, the dependency will be pinned at
    /// the current checkout state.
    ///
    /// - Parameters:
    ///   - packageName: The name of the package which is being resolved.
    ///   - root: The workspace's root input.
    ///   - version: The version to pin at.
    ///   - branch: The branch to pin at.
    ///   - revision: The revision to pin at.
    ///   - diagnostics: The diagnostics engine that reports errors, warnings
    ///     and notes.
    public func resolve(
        packageName: String,
        root: PackageGraphRootInput,
        version: Version? = nil,
        branch: String? = nil,
        revision: String? = nil,
        diagnostics: DiagnosticsEngine
    ) throws {
        // Look up the dependency and check if we can pin it.
        guard let dependency = state.dependencies[forNameOrIdentity: packageName] else {
            diagnostics.emit(.dependencyNotFound(packageName: packageName))
            return
        }
        guard let currentState = checkoutState(for: dependency, diagnostics: diagnostics) else {
            return
        }

        // Compute the custom or extra constraint we need to impose.
        let requirement: PackageRequirement
        if let version = version {
            requirement = .versionSet(.exact(version))
        } else if let branch = branch {
            requirement = .revision(branch)
        } else if let revision = revision {
            requirement = .revision(revision)
        } else {
            requirement = currentState.requirement
        }
        let constraint = PackageContainerConstraint(
                // If any products are required, the rest of the package graph will supply those constraints.
                container: dependency.packageRef, requirement: requirement, products: .nothing)

        // Run the resolution.
        try self._resolve(root: root, forceResolution: false, extraConstraints: [constraint], diagnostics: diagnostics)
    }

    /// Cleans the build artefacts from workspace data.
    ///
    /// - Parameters:
    ///     - diagnostics: The diagnostics engine that reports errors, warnings
    ///       and notes.
    public func clean(with diagnostics: DiagnosticsEngine) {

        // These are the things we don't want to remove while cleaning.
        let protectedAssets = [
            repositoryManager.path,
            checkoutsPath,
            artifactsPath,
            state.path,
        ].map({ path -> String in
            // Assert that these are present inside data directory.
            assert(path.parentDirectory == dataPath)
            return path.basename
        })

        // If we have no data yet, we're done.
        guard fileSystem.exists(dataPath) else {
            return
        }

        guard let contents = diagnostics.wrap({ try fileSystem.getDirectoryContents(dataPath) }) else {
            return
        }

        // Remove all but protected paths.
        let contentsToRemove = Set(contents).subtracting(protectedAssets)
        for name in contentsToRemove {
            try? fileSystem.removeFileTree(dataPath.appending(RelativePath(name)))
        }
    }

    /// Cleans the build artefacts from workspace data.
    ///
    /// - Parameters:
    ///     - diagnostics: The diagnostics engine that reports errors, warnings
    ///       and notes.
    public func purgeCache(with diagnostics: DiagnosticsEngine) {
        diagnostics.wrap {
            try repositoryManager.purgeCache()
            try manifestLoader.purgeCache()
        }
    }

    /// Resets the entire workspace by removing the data directory.
    ///
    /// - Parameters:
    ///     - diagnostics: The diagnostics engine that reports errors, warnings
    ///       and notes.
    public func reset(with diagnostics: DiagnosticsEngine) {
        let removed = diagnostics.wrap {
            try fileSystem.chmod(.userWritable, path: checkoutsPath, options: [.recursive, .onlyFiles])
            // Reset state.
            try state.reset()
        }

        guard removed else { return }
        repositoryManager.reset()
        try? manifestLoader.resetCache()
        try? fileSystem.removeFileTree(dataPath)
    }

    /// Cancel the active dependency resolution operation.
    public func cancelActiveResolverOperation() {
        // FIXME: Need to add cancel support.
    }

    /// Updates the current dependencies.
    ///
    /// - Parameters:
    ///     - diagnostics: The diagnostics engine that reports errors, warnings
    ///       and notes.
    @discardableResult
    public func updateDependencies(
        root: PackageGraphRootInput,
        packages: [String] = [],
        diagnostics: DiagnosticsEngine,
        dryRun: Bool = false
    ) throws -> [(PackageReference, Workspace.PackageStateChange)]? {
        // Create cache directories.
        createCacheDirectories(with: diagnostics)

        // FIXME: this should not block
        // Load the root manifests and currently checked out manifests.
        let rootManifests = try temp_await { self.loadRootManifests(packages: root.packages, diagnostics: diagnostics, completion: $0) }

        // Load the current manifests.
        let graphRoot = PackageGraphRoot(input: root, manifests: rootManifests)
        let currentManifests = try self.loadDependencyManifests(root: graphRoot, diagnostics: diagnostics)

        // Abort if we're unable to load the pinsStore or have any diagnostics.
        guard let pinsStore = diagnostics.wrap({ try self.pinsStore.load() }) else { return nil }

        // Ensure we don't have any error at this point.
        guard !diagnostics.hasErrors else { return nil }

        // Add unversioned constraints for edited packages.
        var updateConstraints = currentManifests.editedPackagesConstraints()

        // Create constraints based on root manifest and pins for the update resolution.
        updateConstraints += graphRoot.constraints(mirrors: config.mirrors)

        let pinsMap: PinsStore.PinsMap
        if packages.isEmpty {
            // No input packages so we have to do a full update. Set pins map to empty.
            pinsMap = [:]
        } else {
            // We have input packages so we have to partially update the package graph. Remove
            // the pins for the input packages so only those packages are updated.
            pinsMap = pinsStore.pinsMap.filter{ !packages.contains($0.value.packageRef.name) }
        }
        
        // Resolve the dependencies.
        let resolver = self.createResolver(pinsMap: pinsMap)
        self.activeResolver = resolver

        let updateResults = resolveDependencies(
            resolver: resolver,
            constraints: updateConstraints,
            diagnostics: diagnostics
        )

        // Reset the active resolver.
        self.activeResolver = nil

        guard !diagnostics.hasErrors else { return nil }

        if dryRun {
            return diagnostics.wrap { return try computePackageStateChanges(root: graphRoot, resolvedDependencies: updateResults, updateBranches: true) }
        }

        // Update the checkouts based on new dependency resolution.
        let packageStateChanges = updateCheckouts(root: graphRoot, updateResults: updateResults, updateBranches: true, diagnostics: diagnostics)

        // Load the updated manifests.
        let updatedDependencyManifests = try self.loadDependencyManifests(root: graphRoot, diagnostics: diagnostics)

        // Update the pins store.
        pinAll(
            dependencyManifests: updatedDependencyManifests,
            pinsStore: pinsStore,
            diagnostics: diagnostics)

        // Update the binary target artifacts.
        let addedOrUpdatedPackages = packageStateChanges.compactMap({ $0.1.isAddedOrUpdated ? $0.0 : nil })
        try self.updateBinaryArtifacts(
            manifests: updatedDependencyManifests,
            addedOrUpdatedPackages: addedOrUpdatedPackages,
            diagnostics: diagnostics)

        return nil
    }

    /// Loads a package graph from a root package using the resources associated with a particular `swiftc` executable.
    ///
    /// - Parameters:
    ///     - packagePath: The absolute path of the root package.
    ///     - swiftCompiler: The absolute path of a `swiftc` executable.
    ///         Its associated resources will be used by the loader.
    public static func loadGraph(
        packagePath: AbsolutePath,
        swiftCompiler: AbsolutePath,
        swiftCompilerFlags: [String],
        diagnostics: DiagnosticsEngine,
        verbosity: Verbosity
    ) throws -> PackageGraph {
        let resources = try UserManifestResources(swiftCompiler: swiftCompiler, swiftCompilerFlags: swiftCompilerFlags)
        let loader = ManifestLoader(manifestResources: resources)
        let workspace = Workspace.create(forRootPackage: packagePath, manifestLoader: loader, verbosity: verbosity)
        return try workspace.loadPackageGraph(rootPath: packagePath, diagnostics: diagnostics)
    }

    /// Fetch and load the complete package at the given path.
    ///
    /// This will implicitly cause any dependencies not yet present in the
    /// working checkouts to be resolved, cloned, and checked out.
    ///
    /// - Returns: The loaded package graph.
    // FIXME: deprecated 12/2020, remove once clients migrate
    @available(*, deprecated, message: "use throwing variant instead (loadPackageGraph(input:)")
    @discardableResult
    public func loadPackageGraph(
        root: PackageGraphRootInput,
        explicitProduct: String? = nil,
        createMultipleTestProducts: Bool = false,
        createREPLProduct: Bool = false,
        forceResolvedVersions: Bool = false,
        diagnostics: DiagnosticsEngine,
        xcTestMinimumDeploymentTargets: [PackageModel.Platform:PlatformVersion]? = nil
    ) -> PackageGraph {
        try! self.loadPackageGraph(rootInput: root,
                                   explicitProduct: explicitProduct,
                                   createMultipleTestProducts: createMultipleTestProducts,
                                   createREPLProduct: createREPLProduct,
                                   forceResolvedVersions: forceResolvedVersions,
                                   diagnostics: diagnostics,
                                   xcTestMinimumDeploymentTargets: xcTestMinimumDeploymentTargets)
    }

    @discardableResult
    public func loadPackageGraph(
        rootInput root: PackageGraphRootInput,
        explicitProduct: String? = nil,
        createMultipleTestProducts: Bool = false,
        createREPLProduct: Bool = false,
        forceResolvedVersions: Bool = false,
        diagnostics: DiagnosticsEngine,
        xcTestMinimumDeploymentTargets: [PackageModel.Platform:PlatformVersion]? = nil
    ) throws -> PackageGraph {

        // Perform dependency resolution, if required.
        let manifests: DependencyManifests
        if forceResolvedVersions {
            manifests = try self._resolveToResolvedVersion(
                root: root,
                explicitProduct: explicitProduct,
                diagnostics: diagnostics
            )
        } else {
            manifests = try self._resolve(
                root: root,
                explicitProduct: explicitProduct,
                forceResolution: false,
                diagnostics: diagnostics
            )
        }

        let remoteArtifacts = try state.artifacts.compactMap({ artifact -> RemoteArtifact? in
            if case .remote(let url, _, _) = artifact.source {
                guard let path = self.path(for: artifact) else {
                    throw InternalError("failed computing path for \(artifact)")
                }
                return RemoteArtifact(url: url, path: path)
            } else {
                return nil
            }
        })

        // Load the graph.
        return try PackageGraph.load(
            root: manifests.root,
            mirrors: config.mirrors,
            additionalFileRules: additionalFileRules,
            externalManifests: manifests.allDependencyManifests(),
            requiredDependencies: manifests.computePackageURLs().required,
            unsafeAllowedPackages: manifests.unsafeAllowedPackages(),
            remoteArtifacts: remoteArtifacts,
            xcTestMinimumDeploymentTargets: xcTestMinimumDeploymentTargets ?? MinimumDeploymentTarget.default.xcTestMinimumDeploymentTargets,
            diagnostics: diagnostics,
            fileSystem: fileSystem,
            shouldCreateMultipleTestProducts: createMultipleTestProducts,
            createREPLProduct: createREPLProduct
        )
    }


    // FIXME: deprecated 12/2020, remove once clients migrate
    @discardableResult
    @available(*, deprecated, message: "use throwing variant instead (loadPackageGraph(rootPath:)")
    public func loadPackageGraph(
        root: AbsolutePath,
        explicitProduct: String? = nil,
        diagnostics: DiagnosticsEngine
    ) -> PackageGraph {
        try! self.loadPackageGraph(
            rootInput: PackageGraphRootInput(packages: [root], mirrors: config.mirrors),
            explicitProduct: explicitProduct,
            diagnostics: diagnostics
        )
    }

    @discardableResult
    public func loadPackageGraph(
        rootPath: AbsolutePath,
        explicitProduct: String? = nil,
        diagnostics: DiagnosticsEngine
    ) throws -> PackageGraph {
        try self.loadPackageGraph(
            rootInput: PackageGraphRootInput(packages: [rootPath], mirrors: config.mirrors),
            explicitProduct: explicitProduct,
            diagnostics: diagnostics
        )
    }

    /// Perform dependency resolution if needed.
    ///
    /// This method will perform dependency resolution based on the root
    /// manifests and pins file.  Pins are respected as long as they are
    /// satisfied by the root manifest closure requirements.  Any outdated
    /// checkout will be restored according to its pin.
    public func resolve(
        root: PackageGraphRootInput,
        forceResolution: Bool = false,
        diagnostics: DiagnosticsEngine
    ) throws {
        try self._resolve(root: root, forceResolution: forceResolution, diagnostics: diagnostics)
    }

    /// Loads and returns manifests at the given paths.
    public func loadRootManifests(
        packages: [AbsolutePath],
        diagnostics: DiagnosticsEngine,
        completion: @escaping(Result<[Manifest], Error>) -> Void
    ) {
        let lock = Lock()
        let sync = DispatchGroup()
        var rootManifests = [Manifest]()
        Set(packages).forEach { package in
            sync.enter()
            self.loadManifest(packagePath: package, url: package.pathString, packageKind: .root, diagnostics: diagnostics) { result in
                defer { sync.leave() }
                if case .success(let manifest) = result {
                    lock.withLock {
                        rootManifests.append(manifest)
                    }
                }
            }
        }

        sync.notify(queue: self.queue) {
            // Check for duplicate root packages.
            let duplicateRoots = rootManifests.spm_findDuplicateElements(by: \.name)
            if !duplicateRoots.isEmpty {
                let name = duplicateRoots[0][0].name
                diagnostics.emit(error: "found multiple top-level packages named '\(name)'")
                return completion(.success([]))
            }

            completion(.success(rootManifests))
        }
    }

    /// Generates the checksum
    public func checksum(
        forBinaryArtifactAt path: AbsolutePath,
        diagnostics: DiagnosticsEngine
    ) -> String {
        // Validate the path has a supported extension.
        guard let pathExtension = path.extension, archiver.supportedExtensions.contains(pathExtension) else {
            let supportedExtensionList = archiver.supportedExtensions.joined(separator: ", ")
            diagnostics.emit(error: "unexpected file type; supported extensions are: \(supportedExtensionList)")
            return ""
        }

        // Ensure that the path with the accepted extension is a file.
        guard fileSystem.isFile(path) else {
            diagnostics.emit(error: "file not found at path: \(path.pathString)")
            return ""
        }

        return diagnostics.wrap {
            let contents = try fileSystem.readFileContents(path)
            return checksumAlgorithm.hash(contents).hexadecimalRepresentation
        } ?? ""
    }
}

// MARK: - Editing Functions

extension Workspace {

    func checkoutState(
        for dependency: ManagedDependency,
        diagnostics: DiagnosticsEngine
    ) -> CheckoutState? {
        switch dependency.state {
        case .checkout(let checkoutState):
            return checkoutState
        case .edited:
            diagnostics.emit(error: "dependency '\(dependency.packageRef.name)' already in edit mode")
        case .local:
            diagnostics.emit(error: "local dependency '\(dependency.packageRef.name)' can't be edited")
        }
        return nil
    }

    /// Edit implementation.
    fileprivate func _edit(
        packageName: String,
        path: AbsolutePath? = nil,
        revision: Revision? = nil,
        checkoutBranch: String? = nil,
        diagnostics: DiagnosticsEngine
    ) throws {
        // Look up the dependency and check if we can edit it.
        guard let dependency = state.dependencies[forNameOrIdentity: packageName] else {
            diagnostics.emit(.dependencyNotFound(packageName: packageName))
            return
        }

        guard let checkoutState = checkoutState(for: dependency, diagnostics: diagnostics) else {
            return
        }

        // If a path is provided then we use it as destination. If not, we
        // use the folder with packageName inside editablesPath.
        let destination = path ?? editablesPath.appending(component: packageName)

        // If there is something present at the destination, we confirm it has
        // a valid manifest with name same as the package we are trying to edit.
        if fileSystem.exists(destination) {
            // FIXME: this should not block
            let manifest = try temp_await {
                self.loadManifest(packagePath: destination,
                                  url: dependency.packageRef.repository.url,
                                  packageKind: .local,
                                  diagnostics: diagnostics,
                                  completion: $0)
            }

            guard manifest.name == packageName else {
                return diagnostics.emit(error: "package at '\(destination)' is \(manifest.name) but was expecting \(packageName)")
            }

            // Emit warnings for branch and revision, if they're present.
            if let checkoutBranch = checkoutBranch {
                diagnostics.emit(.editBranchNotCheckedOut(
                    packageName: packageName,
                    branchName: checkoutBranch))
            }
            if let revision = revision {
                diagnostics.emit(.editRevisionNotUsed(
                    packageName: packageName,
                    revisionIdentifier: revision.identifier))
            }
        } else {
            // Otherwise, create a checkout at the destination from our repository store.
            //
            // Get handle to the repository.
            // TODO: replace with async/await when available
            let handle = try temp_await {
                repositoryManager.lookup(repository: dependency.packageRef.repository, skipUpdate: true, on: self.queue, completion: $0)
            }
            let repo = try handle.open()

            // Do preliminary checks on branch and revision, if provided.
            if let branch = checkoutBranch, repo.exists(revision: Revision(identifier: branch)) {
                throw WorkspaceDiagnostics.BranchAlreadyExists(branch: branch)
            }
            if let revision = revision, !repo.exists(revision: revision) {
                throw WorkspaceDiagnostics.RevisionDoesNotExist(revision: revision.identifier)
            }

            try handle.cloneCheckout(to: destination, editable: true)
            let workingRepo = try repositoryManager.provider.openCheckout(at: destination)
            try workingRepo.checkout(revision: revision ?? checkoutState.revision)

            // Checkout to the new branch if provided.
            if let branch = checkoutBranch {
                try workingRepo.checkout(newBranch: branch)
            }
        }

        // For unmanaged dependencies, create the symlink under editables dir.
        if let path = path {
            try fileSystem.createDirectory(editablesPath)
            // FIXME: We need this to work with InMem file system too.
            if !(fileSystem is InMemoryFileSystem) {
                let symLinkPath = editablesPath.appending(component: packageName)

                // Cleanup any existing symlink.
                if fileSystem.isSymlink(symLinkPath) {
                    try fileSystem.removeFileTree(symLinkPath)
                }

                // FIXME: We should probably just warn in case we fail to create
                // this symlink, which could happen if there is some non-symlink
                // entry at this location.
                try fileSystem.createSymbolicLink(symLinkPath, pointingAt: path, relative: false)
            }
        }

        // Remove the existing checkout.
        do {
            let oldCheckoutPath = checkoutsPath.appending(dependency.subpath)
            try fileSystem.chmod(.userWritable, path: oldCheckoutPath, options: [.recursive, .onlyFiles])
            try fileSystem.removeFileTree(oldCheckoutPath)
        }

        // Save the new state.
        state.dependencies.add(dependency.editedDependency(subpath: RelativePath(packageName), unmanagedPath: path))
        try state.saveState()
    }

    /// Unedit a managed dependency. See public API unedit(packageName:forceRemove:).
    fileprivate func unedit(
        dependency: ManagedDependency,
        forceRemove: Bool,
        root: PackageGraphRootInput? = nil,
        diagnostics: DiagnosticsEngine
    ) throws {

        // Compute if we need to force remove.
        var forceRemove = forceRemove

        switch dependency.state {
        // If the dependency isn't in edit mode, we can't unedit it.
        case .checkout, .local:
            throw WorkspaceDiagnostics.DependencyNotInEditMode(dependencyName: dependency.packageRef.name)

        case .edited(let path):
            if path != nil {
                // Set force remove to true for unmanaged dependencies.  Note that
                // this only removes the symlink under the editable directory and
                // not the actual unmanaged package.
                forceRemove = true
            }
        }

        // Form the edit working repo path.
        let path = editablesPath.appending(dependency.subpath)
        // Check for uncommited and unpushed changes if force removal is off.
        if !forceRemove {
            let workingRepo = try repositoryManager.provider.openCheckout(at: path)
            guard !workingRepo.hasUncommittedChanges() else {
                throw WorkspaceDiagnostics.UncommitedChanges(repositoryPath: path)
            }
            guard try !workingRepo.hasUnpushedCommits() else {
                throw WorkspaceDiagnostics.UnpushedChanges(repositoryPath: path)
            }
        }
        // Remove the editable checkout from disk.
        if fileSystem.exists(path) {
            try fileSystem.removeFileTree(path)
        }
        // If this was the last editable dependency, remove the editables directory too.
        if fileSystem.exists(editablesPath), try fileSystem.getDirectoryContents(editablesPath).isEmpty {
            try fileSystem.removeFileTree(editablesPath)
        }

        if let checkoutState = dependency.basedOn?.checkoutState {
                // Restore the original checkout.
                //
                // The clone method will automatically update the managed dependency state.
                _ = try clone(package: dependency.packageRef, at: checkoutState)
        } else {
            // The original dependency was removed, update the managed dependency state.
            state.dependencies.remove(forURL: dependency.packageRef.path)
            try state.saveState()
        }

        // Resolve the dependencies if workspace root is provided. We do this to
        // ensure the unedited version of this dependency is resolved properly.
        if let root = root {
            try self.resolve(root: root, diagnostics: diagnostics)
        }
    }

}

// MARK: - Pinning Functions

extension Workspace {

    /// Pins all of the current managed dependencies at their checkout state.
    fileprivate func pinAll(
        dependencyManifests: DependencyManifests,
        pinsStore: PinsStore,
        diagnostics: DiagnosticsEngine
    ) {
        // Reset the pinsStore and start pinning the required dependencies.
        pinsStore.unpinAll()

        let requiredURLs = dependencyManifests.computePackageURLs().required

        for dependency in state.dependencies  {
            if requiredURLs.contains(where: { $0.path == dependency.packageRef.path }) {
                pinsStore.pin(dependency)
            }
        }
        diagnostics.wrap({ try pinsStore.saveState() })

        // Ask resolved file watcher to update its value so we don't fire
        // an extra event if the file was modified by us.
        self.resolvedFileWatcher?.updateValue()
    }
}

fileprivate extension PinsStore {
    /// Pin a managed dependency at its checkout state.
    ///
    /// This method does nothing if the dependency is in edited state.
    func pin(_ dependency: ManagedDependency) {

        // Get the checkout state.
        let checkoutState: CheckoutState
        switch dependency.state {
        case .checkout(let state):
            checkoutState = state
        case .edited, .local:
            return
        }

        self.pin(
            packageRef: dependency.packageRef,
            state: checkoutState)
    }
}

// MARK: - TSCUtility Functions

extension Workspace {
    /// A struct representing all the current manifests (root + external) in a package graph.
    public struct DependencyManifests {
        /// The package graph root.
        let root: PackageGraphRoot

        /// The dependency manifests in the transitive closure of root manifest.
        let dependencies: [(manifest: Manifest, dependency: ManagedDependency, productFilter: ProductFilter)]

        let workspace: Workspace

        fileprivate init(
            root: PackageGraphRoot,
            dependencies: [(Manifest, ManagedDependency, ProductFilter)],
            workspace: Workspace
        ) {
            self.root = root
            self.dependencies = dependencies
            self.workspace = workspace
        }

        /// Returns all manifests contained in DependencyManifests.
        public func allDependencyManifests() -> [Manifest] {
            return self.dependencies.map{ $0.manifest }
        }

        /// Computes the identities which are declared in the manifests but aren't present in dependencies.
        public func missingPackageURLs() -> Set<PackageReference> {
            return self.computePackageURLs().missing
        }

        /// Returns the list of packages which are allowed to vend products with unsafe flags.
        func unsafeAllowedPackages() -> Set<PackageReference> {
            var result = Set<PackageReference>()

            for dependency in self.dependencies {
                let dependency = dependency.dependency
                switch dependency.state {
                case .checkout(let checkout):
                    if checkout.isBranchOrRevisionBased {
                        result.insert(dependency.packageRef)
                    }
                case .edited:
                    continue
                case .local:
                    result.insert(dependency.packageRef)
                }
            }

            // Root packages are always allowed to use unsafe flags.
            result.formUnion(root.packageRefs)

            return result
        }

        func computePackageURLs() -> (required: Set<PackageReference>, missing: Set<PackageReference>) {
            let manifestsMap: [PackageIdentity: Manifest] = Dictionary(uniqueKeysWithValues:
                self.root.manifests.map { (PackageIdentity(url: $0.url), $0) } +
                self.dependencies.map { (PackageIdentity(url: $0.manifest.url), $0.manifest) })

            var inputIdentities: Set<PackageReference> = []
            let inputNodes: [GraphLoadingNode] = self.root.manifests.map{ manifest in
                let identity = PackageIdentity(url: manifest.url)
                let package = PackageReference(identity: identity, path: manifest.url, kind: manifest.packageKind)
                inputIdentities.insert(package)
                let node = GraphLoadingNode(manifest: manifest, productFilter: .everything)
                return node
            } + self.root.dependencies.compactMap{ dependency in
                let url = workspace.config.mirrors.effectiveURL(forURL: dependency.url)
                let identity = PackageIdentity(url: url)
                let package = PackageReference(identity: identity, path: url)
                inputIdentities.insert(package)
                return manifestsMap[identity].map { manifest in
                    GraphLoadingNode(manifest: manifest, productFilter: dependency.productFilter)
                }
            }

            // FIXME: this is dropping legitimate packages with equal identities and should be revised as part of the identity work
            var requiredIdentities: Set<PackageReference> = []
            _ = transitiveClosure(inputNodes) { node in
                return node.manifest.dependenciesRequired(for: node.productFilter).compactMap{ dependency in
                    let url = workspace.config.mirrors.effectiveURL(forURL: dependency.url)
                    let identity = PackageIdentity(url: url)
                    let package = PackageReference(identity: identity, path: url)
                    requiredIdentities.insert(package)
                    return manifestsMap[identity].map { manifest in
                        GraphLoadingNode(manifest: manifest, productFilter: dependency.productFilter)
                    }
                }
            }
            // FIXME: This should be an ordered set.
            requiredIdentities = inputIdentities.union(requiredIdentities)

            let availableIdentities: Set<PackageReference> = Set(manifestsMap.map {
                let url = workspace.config.mirrors.effectiveURL(forURL: $0.1.url)
                return PackageReference(identity: $0.key, path: url, kind: $0.1.packageKind)
            })
            // We should never have loaded a manifest we don't need.
            assert(availableIdentities.isSubset(of: requiredIdentities), "\(availableIdentities) | \(requiredIdentities)")
            // These are the missing package identities.
            let missingIdentities = requiredIdentities.subtracting(availableIdentities)

            return (requiredIdentities, missingIdentities)
        }

        /// Returns constraints of the dependencies, including edited package constraints.
        func dependencyConstraints() -> [PackageContainerConstraint] {
            var allConstraints = [PackageContainerConstraint]()

            for (externalManifest, managedDependency, productFilter) in dependencies {
                // For edited packages, add a constraint with unversioned requirement so the
                // resolver doesn't try to resolve it.
                switch managedDependency.state {
                case .edited:
                    // FIXME: We shouldn't need to construct a new package reference object here.
                    // We should get the correct one from managed dependency object.
                    let ref = PackageReference(
                        identity: managedDependency.packageRef.identity,
                        path: managedDependency.packageRef.path,
                        kind: .local
                    )
                    let constraint = PackageContainerConstraint(
                        container: ref,
                        requirement: .unversioned,
                        products: productFilter)
                    allConstraints.append(constraint)
                case .checkout, .local:
                    break
                }
                allConstraints += externalManifest.dependencyConstraints(
                    productFilter: productFilter,
                    mirrors: workspace.config.mirrors
                )
            }
            return allConstraints
        }

        // FIXME: @testable(internal)
        /// Returns a list of constraints for all 'edited' package.
        public func editedPackagesConstraints() -> [PackageContainerConstraint] {
            var constraints = [PackageContainerConstraint]()

            for (_, managedDependency, productFilter) in dependencies {
                switch managedDependency.state {
                case .checkout, .local: continue
                case .edited: break
                }
                // FIXME: We shouldn't need to construct a new package reference object here.
                // We should get the correct one from managed dependency object.
                let ref = PackageReference(
                    identity: managedDependency.packageRef.identity,
                    path: workspace.path(for: managedDependency).pathString,
                    kind: .local
                )
                let constraint = PackageContainerConstraint(
                    container: ref,
                    requirement: .unversioned,
                    products: productFilter)
                constraints.append(constraint)
            }
            return constraints
        }
    }

    /// Watch the Package.resolved for changes.
    ///
    /// This is useful if clients want to be notified when the Package.resolved
    /// file is changed *outside* of libSwiftPM operations. For example, as part
    /// of a git operation.
    public func watchResolvedFile() throws {
        // Return if we're already watching it.
        guard self.resolvedFileWatcher == nil else { return }
        self.resolvedFileWatcher = try ResolvedFileWatcher(resolvedFile: self.resolvedFile) { [weak self] in
            self?.delegate?.resolvedFileChanged()
        }
    }

    /// Create the cache directories.
    fileprivate func createCacheDirectories(with diagnostics: DiagnosticsEngine) {
        do {
            try fileSystem.createDirectory(repositoryManager.path, recursive: true)
            try fileSystem.createDirectory(checkoutsPath, recursive: true)
            try fileSystem.createDirectory(artifactsPath, recursive: true)
        } catch {
            diagnostics.emit(error)
        }
    }

    /// Returns the location of the dependency.
    ///
    /// Checkout dependencies will return the subpath inside `checkoutsPath` and
    /// edited dependencies will either return a subpath inside `editablesPath` or
    /// a custom path.
    public func path(for dependency: ManagedDependency) -> AbsolutePath {
        switch dependency.state {
        case .checkout:
            return checkoutsPath.appending(dependency.subpath)
        case .edited(let path):
            return path ?? editablesPath.appending(dependency.subpath)
        case .local:
            return AbsolutePath(dependency.packageRef.path)
        }
    }

    /// Returns the location of the artifact.
    public func path(for artifact: ManagedArtifact) -> AbsolutePath? {
        switch artifact.source {
        case .remote(_, _, let subpath):
            return artifactsPath.appending(subpath)
        case .local:
            return nil
        }
    }

    /// Returns manifest interpreter flags for a package.
    public func interpreterFlags(for packagePath: AbsolutePath) -> [String] {
        // We ignore all failures here and return empty array.
        guard let manifestLoader = self.manifestLoader as? ManifestLoader,
              let toolsVersion = try? toolsVersionLoader.load(at: packagePath, fileSystem: fileSystem),
              currentToolsVersion >= toolsVersion,
              toolsVersion >= ToolsVersion.minimumRequired else {
            return []
        }
        return manifestLoader.interpreterFlags(for: toolsVersion)
    }

    /// Load the manifests for the current dependency tree.
    ///
    /// This will load the manifests for the root package as well as all the
    /// current dependencies from the working checkouts.
    // @testable internal
    public func loadDependencyManifests(
        root: PackageGraphRoot,
        diagnostics: DiagnosticsEngine
    ) throws -> DependencyManifests {

        // Make a copy of dependencies as we might mutate them in the for loop.
        let dependenciesToCheck = Array(state.dependencies)
        // Remove any managed dependency which has become a root.
        for dependency in dependenciesToCheck {
            if root.packageRefs.contains(dependency.packageRef) {
                diagnostics.wrap {
                    try self.remove(package: dependency.packageRef)
                }
            }
        }

        // Try to load current managed dependencies, or emit and return.
        self.fixManagedDependencies(with: diagnostics)
        guard !diagnostics.hasErrors else {
            return DependencyManifests(root: root, dependencies: [], workspace: self)
        }

        // optimization: preload in parallel
        let rootDependencyManifestsURLs = root.dependencies.map{ config.mirrors.effectiveURL(forURL: $0.url) }
        let rootDependencyManifests = try temp_await { self.loadManifests(forURLs: rootDependencyManifestsURLs, diagnostics: diagnostics, completion: $0) }

        let inputManifests = root.manifests + rootDependencyManifests

        // Map of loaded manifests. We do this to avoid reloading the shared nodes.

        // Compute the transitive closure of available dependencies.
        struct URLAndFilter: Hashable { // Just because a raw tuple cannot be hashable.
            let url: String
            let productFilter: ProductFilter
        }

        // optimization: preload manifest we know about in parallel
        let inputDependenciesURLs = inputManifests.map { $0.dependencies.map{ config.mirrors.effectiveURL(forURL: $0.url) } }.flatMap { $0 }
        // FIXME: this should not block
        var loadedManifests = try temp_await { self.loadManifests(forURLs: inputDependenciesURLs, diagnostics: diagnostics, completion: $0) }.spm_createDictionary{ ($0.url, $0) }

        // continue to load the rest of the manifest for this graph
        let allManifestsWithPossibleDuplicates = try topologicalSort(inputManifests.map{ KeyedPair($0, key: URLAndFilter(url: $0.url, productFilter: .everything)) }) { node in
            return node.item.dependenciesRequired(for: node.key.productFilter).compactMap{ dependency in
                let url = config.mirrors.effectiveURL(forURL: dependency.url)
                // FIXME: this should not block
                // note: loadManifest emits diagnostics in case it fails
                let manifest = loadedManifests[url] ?? temp_await { self.loadManifest(forURL: url, diagnostics: diagnostics, completion: $0) }
                loadedManifests[url] = manifest
                return manifest.flatMap { KeyedPair($0, key: URLAndFilter(url: $0.url, productFilter: dependency.productFilter)) }
            }
        }

        // remove duplicates of the same manifest (by identity)
        var deduplication = [PackageIdentity: Int]()
        var allManifests = [(manifest: Manifest, productFilter: ProductFilter)]()
        for node in allManifestsWithPossibleDuplicates {
            let identity = PackageIdentity(url: node.item.url)
            if let index = deduplication[identity]  {
                let productFilter = allManifests[index].productFilter.merge(node.key.productFilter)
                allManifests[index] = (node.item, productFilter)
            } else {
                deduplication[identity] = allManifests.count
                allManifests.append((node.item, node.key.productFilter))
            }
        }

        let dependencyManifests = allManifests.filter{ !root.manifests.contains($0.manifest) }

        // check for overrides attempts with same name but different path
        let rootManifestsByName = root.manifests.spm_createDictionary{ ($0.name, $0) }
        dependencyManifests.forEach { manifest, _ in
            if let override = rootManifestsByName[manifest.name], override.url != manifest.url  {
                diagnostics.emit(error: "unable to override package '\(manifest.name)' because its identity '\(PackageIdentity(url: manifest.url))' doesn't match override's identity (directory name) '\(PackageIdentity(url: override.url))'")
            }
        }

        let dependencies = try dependencyManifests.map{ manifest, productFilter -> (Manifest, ManagedDependency, ProductFilter) in
            guard let dependency = self.state.dependencies[forURL: manifest.url] else {
                throw InternalError("dependency not found for \(manifest.url)")
            }
            return (manifest, dependency, productFilter)
        }
        return DependencyManifests(root: root, dependencies: dependencies, workspace: self)
    }


    /// Loads the given manifest, if it is present in the managed dependencies.
    fileprivate func loadManifest(forURL packageURL: String, diagnostics: DiagnosticsEngine, completion: @escaping (Manifest?) -> Void) {
        // Check if this dependency is available.
        guard let managedDependency = self.state.dependencies[forURL: packageURL] else {
            return completion(nil)
        }

        // The kind and version, if known.
        let packageKind: PackageReference.Kind
        let version: Version?
        switch managedDependency.state {
        case .checkout(let checkoutState):
            packageKind = .remote
            version = checkoutState.version
        case .edited, .local:
            packageKind = .local
            version = nil
        }

        // Get the path of the package.
        let packagePath = path(for: managedDependency)

        // Load and return the manifest.
        self.loadManifest(packagePath: packagePath,
                          url: managedDependency.packageRef.path,
                          version: version,
                          packageKind: packageKind,
                          diagnostics: diagnostics) { result in
            // error is added to diagnostics in the function above
            completion(try? result.get())
        }
    }

    private func loadManifests(forURLs urls: [String], diagnostics: DiagnosticsEngine, completion: @escaping (Result<[Manifest], Error>) -> Void) {
        // this is allot of boilerplate code but its is important for performance
        let lock = Lock()
        let sync = DispatchGroup()
        var manifests = [Manifest]()
        Set(urls).forEach { url in
            sync.enter()
            self.loadManifest(forURL: url, diagnostics: diagnostics) { manifest in
                defer { sync.leave() }
                if let manifest = manifest {
                    lock.withLock {
                        manifests.append(manifest)
                    }
                }
            }
        }

        sync.notify(queue: self.queue) {
            completion(.success(manifests))
        }
    }

    /// Load the manifest at a given path.
    ///
    /// This is just a helper wrapper to the manifest loader.
    fileprivate func loadManifest(
        packagePath: AbsolutePath,
        url: String,
        version: Version? = nil,
        packageKind: PackageReference.Kind,
        diagnostics: DiagnosticsEngine,
        completion: @escaping (Result<Manifest, Error>) -> Void
    ) {
        // Load the manifest, bracketed by the calls to the delegate callbacks. The delegate callback is only passed any diagnostics emited during the parsing of the manifest, but they are also forwarded up to the caller.
        delegate?.willLoadManifest(packagePath: packagePath, url: url, version: version, packageKind: packageKind)
        let manifestDiagnostics = DiagnosticsEngine(handlers: [{diagnostics.emit($0)}])
        diagnostics.with(location: PackageLocation.Local(packagePath: packagePath)) { diagnostics in
            do {
                // Load the tools version for the package.
                let toolsVersion = try toolsVersionLoader.load(at: packagePath, fileSystem: fileSystem)

                // Validate the tools version.
                try toolsVersion.validateToolsVersion(currentToolsVersion, packagePath: packagePath.pathString)

                // Load the manifest.
                manifestLoader.load(package: packagePath,
                                    baseURL: url,
                                    version: version,
                                    toolsVersion: toolsVersion,
                                    packageKind: packageKind,
                                    diagnostics: diagnostics,
                                    verbosity: self.verbosity,
                                    on: self.queue) { result in

                    switch result {
                    case .failure(let error):
                        diagnostics.emit(error)
                    case .success(let manifest):
                        self.delegate?.didLoadManifest(packagePath: packagePath, url: url, version: version, packageKind: packageKind, manifest: manifest, diagnostics: manifestDiagnostics.diagnostics)
                    }
                    completion(result)
                }
            } catch {
                diagnostics.emit(error)
                completion(.failure(error))
            }
        }
    }

    fileprivate func updateBinaryArtifacts(
        manifests: DependencyManifests,
        addedOrUpdatedPackages: [PackageReference],
        diagnostics: DiagnosticsEngine
    ) throws {
        let updatedArtifacts = try self.artifacts(from: manifests)

        var artifactsToRemove: [ManagedArtifact] = []
        var artifactsToAdd: [ManagedArtifact] = []
        var artifactsToDownload: [ManagedArtifact] = []

        for artifact in state.artifacts {
            if !updatedArtifacts.contains(where: {
                $0.packageRef == artifact.packageRef && $0.targetName == artifact.targetName
            }) {
                artifactsToRemove.append(artifact)
            }
        }

        for artifact in updatedArtifacts {
            let existingArtifact = state.artifacts[
                packageURL: artifact.packageRef.path,
                targetName: artifact.targetName
            ]

            switch artifact.source {
            case .local:
                if let existingArtifact = existingArtifact, case .remote = existingArtifact.source {
                    // If we go from a remote to a local artifact, we can remove the old remote artifact.
                    artifactsToRemove.append(existingArtifact)
                }

                artifactsToAdd.append(artifact)
            case .remote(_, let checksum, _):
                if let existingArtifact = existingArtifact,
                    case .remote(_, let existingChecksum, _) = existingArtifact.source
                {
                    // If we already have an artifact with the same checksum, we don't need to download it again.
                    if checksum == existingChecksum {
                        continue
                    }

                    // If the checksum is different but the package wasn't updated, this is a security risk.
                    if !addedOrUpdatedPackages.contains(artifact.packageRef) {
                        diagnostics.emit(.artifactChecksumChanged(targetName: artifact.targetName))
                        continue
                    }

                    artifactsToRemove.append(existingArtifact)
                }

                artifactsToAdd.append(artifact)
                artifactsToDownload.append(artifact)
            }
        }

        // Remove the artifacts and directories which are not needed anymore.
        diagnostics.wrap {
            for artifact in artifactsToRemove {
                state.artifacts.remove(packageURL: artifact.packageRef.path, targetName: artifact.targetName)

                if let path = path(for: artifact) {
                    try fileSystem.removeFileTree(path)
                }
            }

            for directory in try fileSystem.getDirectoryContents(artifactsPath) {
                let directoryPath = artifactsPath.appending(component: directory)
                if try fileSystem.isDirectory(directoryPath) && fileSystem.getDirectoryContents(directoryPath).isEmpty {
                    try fileSystem.removeFileTree(directoryPath)
                }
            }
        }

        guard !diagnostics.hasErrors else {
            return
        }

        try self.download(artifactsToDownload, diagnostics: diagnostics)

        for artifact in artifactsToAdd {
            state.artifacts.add(artifact)
        }

        diagnostics.wrap {
            try state.saveState()
        }
    }

    private func artifacts(from manifests: DependencyManifests) throws -> [ManagedArtifact] {
        let packageAndManifests: [(PackageReference, Manifest)] =
            zip(manifests.root.packageRefs, manifests.root.manifests) + // Root package and manifests.
            manifests.dependencies.map({ manifest, managed, _ in (managed.packageRef, manifest) }) // Dependency package and manifests.

        var artifacts: [ManagedArtifact] = []

        for (packageRef, manifest) in packageAndManifests {
            for target in manifest.targets where target.type == .binary {
                if let path = target.path {
                    let artifact = ManagedArtifact.local(packageRef: packageRef, targetName: target.name, path: path)
                    artifacts.append(artifact)
                } else if let url = target.url, let checksum = target.checksum {
                    let subpath = artifactSubpath(packageRef: packageRef, targetName: target.name)
                    let artifact = ManagedArtifact.remote(
                        packageRef: packageRef,
                        targetName: target.name,
                        url: url,
                        checksum: checksum,
                        subpath: subpath)
                    artifacts.append(artifact)
                } else {
                    throw InternalError("a binary target should have either a path or a URL and a checksum")
                }
            }
        }

        return artifacts
    }

    private func artifactSubpath(packageRef: PackageReference, targetName: String) -> RelativePath {
        RelativePath("\(packageRef.name)/\(targetName).xcframework")
    }

    private func download(_ artifacts: [ManagedArtifact], diagnostics: DiagnosticsEngine) throws {
        let group = DispatchGroup()
        let tempDiagnostics = DiagnosticsEngine()

        var authProvider: AuthorizationProviding? = nil
        var didDownloadAnyArtifact = false
        #if os(macOS)
        // Netrc feature currently only supported on macOS 10.13+ due to dependency
        // on NSTextCheckingResult.range(with:)
        if #available(macOS 10.13, *) {
            authProvider = try? Netrc.load(fromFileAtPath: netrcFilePath).get()
        }
        #endif
        for artifact in artifacts {
            group.enter()
            defer { group.leave() }

            guard case .remote(let url, let checksum, _) = artifact.source, let destination = path(for: artifact) else {
                throw InternalError("Can't download local artifact")
            }

            guard let parsedURL = URL(string: url) else {
                throw StringError("invalid url \(url)")
            }

            let parentDirectory = destination.parentDirectory

            do {
                try fileSystem.createDirectory(parentDirectory, recursive: true)
            } catch {
                tempDiagnostics.emit(error)
                continue
            }

            let archivePath = parentDirectory.appending(component: parsedURL.lastPathComponent)

            group.enter()
            didDownloadAnyArtifact = true
            downloader.downloadFile(
                at: parsedURL,
                to: archivePath,
                withAuthorizationProvider: authProvider,
                progress: { bytesDownloaded, totalBytesToDownload in
                    self.delegate?.downloadingBinaryArtifact(
                        from: url,
                        bytesDownloaded: bytesDownloaded,
                        totalBytesToDownload: totalBytesToDownload)
                },
                completion: { downloadResult in
                    defer { group.leave() }

                    switch downloadResult {
                    case .success:
                        let archiveChecksum = self.checksum(
                            forBinaryArtifactAt: archivePath,
                            diagnostics: tempDiagnostics)
                        guard archiveChecksum == checksum else {
                            tempDiagnostics.emit(.artifactInvalidChecksum(targetName: artifact.targetName, expectedChecksum: checksum, actualChecksum: archiveChecksum))
                            tempDiagnostics.wrap { try self.fileSystem.removeFileTree(archivePath) }
                            return
                        }

                        group.enter()
                        self.archiver.extract(from: archivePath, to: parentDirectory, completion: { extractResult in
                            defer { group.leave() }

                            switch extractResult {
                            case .success:
                                if let expectedPath = self.path(for: artifact), !self.fileSystem.isDirectory(expectedPath) {
                                    tempDiagnostics.emit(.artifactNotFound(targetName: artifact.targetName, artifactName: expectedPath.basename))
                                }
                            case .failure(let error):
                                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                                tempDiagnostics.emit(.artifactFailedExtraction(targetName: artifact.targetName, reason: reason))
                            }

                            tempDiagnostics.wrap { try self.fileSystem.removeFileTree(archivePath) }
                        })
                    case .failure(let error):
                        let reason = error.errorDescription ?? error.localizedDescription
                        tempDiagnostics.emit(.artifactFailedDownload(targetName: artifact.targetName, reason: reason))
                    }
                })
        }

        group.wait()

        if didDownloadAnyArtifact {
            delegate?.didDownloadBinaryArtifacts()
        }

        for diagnostic in tempDiagnostics.diagnostics {
            diagnostics.emit(diagnostic.message, location: diagnostic.location)
        }
    }
}

// MARK: - Dependency Management

extension Workspace {

    /// Resolves the dependencies according to the entries present in the Package.resolved file.
    ///
    /// This method bypasses the dependency resolution and resolves dependencies
    /// according to the information in the resolved file.
    public func resolveToResolvedVersion(
        root: PackageGraphRootInput,
        diagnostics: DiagnosticsEngine
    ) throws {
        try self._resolveToResolvedVersion(root: root, diagnostics: diagnostics)
    }

    /// Resolves the dependencies according to the entries present in the Package.resolved file.
    ///
    /// This method bypasses the dependency resolution and resolves dependencies
    /// according to the information in the resolved file.
    @discardableResult
    fileprivate func _resolveToResolvedVersion(
        root: PackageGraphRootInput,
        explicitProduct: String? = nil,
        diagnostics: DiagnosticsEngine
    ) throws -> DependencyManifests {
        // Ensure the cache path exists.
        createCacheDirectories(with: diagnostics)

        // FIXME: this should not block
        let rootManifests = try temp_await { self.loadRootManifests(packages: root.packages, diagnostics: diagnostics, completion: $0) }
        let graphRoot = PackageGraphRoot(input: root, manifests: rootManifests, explicitProduct: explicitProduct)

        // Load the pins store or abort now.
        guard let pinsStore = diagnostics.wrap({ try self.pinsStore.load() }), !diagnostics.hasErrors else {
            return try self.loadDependencyManifests(root: graphRoot, diagnostics: diagnostics)
        }

        // Request all the containers to fetch them in parallel.
        //
        // We just request the packages here, repository manager will
        // automatically manage the parallelism.
        // FIXME: this should not block
        let pins = pinsStore.pins.map({ $0 })
        DispatchQueue.concurrentPerform(iterations: pins.count) { idx in
            _ = try? temp_await {
                containerProvider.getContainer(for: pins[idx].packageRef, skipUpdate: true, on: self.queue, completion: $0)
            }
        }

        // Compute the pins that we need to actually clone.
        //
        // We require cloning if there is no checkout or if the checkout doesn't
        // match with the pin.
        let requiredPins = pins.filter({ pin in
            guard let dependency = state.dependencies[forURL: pin.packageRef.path] else {
                return true
            }
            switch dependency.state {
            case .checkout(let checkoutState):
                return pin.state != checkoutState
            case .edited, .local:
                return true
            }
        })

        // Clone the required pins.
        for pin in requiredPins {
            diagnostics.wrap {
                _ = try self.clone(package: pin.packageRef, at: pin.state)
            }
        }

        // Save state for local packages, if any.
        //
        // FIXME: This will only work for top-level local packages right now.
        for rootManifest in rootManifests {
            let dependencies = rootManifest.dependencies.filter{ $0.requirement == .localPackage }
            for localPackage in dependencies {
                let package = localPackage.createPackageRef(mirrors: self.config.mirrors)
                state.dependencies.add(ManagedDependency.local(packageRef: package))
            }
        }
        diagnostics.wrap { try state.saveState() }

        let currentManifests = try self.loadDependencyManifests(root: graphRoot, diagnostics: diagnostics)

        let precomputationResult = precomputeResolution(
            root: graphRoot,
            dependencyManifests: currentManifests,
            pinsStore: pinsStore
        )

        if precomputationResult.isRequired {
            diagnostics.emit(error: "cannot update Package.resolved file because automatic resolution is disabled")
        }

        try self.updateBinaryArtifacts(manifests: currentManifests, addedOrUpdatedPackages: [], diagnostics: diagnostics)

        return currentManifests
    }

    /// Implementation of resolve(root:diagnostics:).
    ///
    /// The extra constraints will be added to the main requirements.
    /// It is useful in situations where a requirement is being
    /// imposed outside of manifest and pins file. E.g., when using a command
    /// like `$ swift package resolve foo --version 1.0.0`.
    @discardableResult
    fileprivate func _resolve(
        root: PackageGraphRootInput,
        explicitProduct: String? = nil,
        forceResolution: Bool,
        extraConstraints: [PackageContainerConstraint] = [],
        diagnostics: DiagnosticsEngine,
        retryOnPackagePathMismatch: Bool = true,
        resetPinsStoreOnFailure: Bool = true
    ) throws -> DependencyManifests {

        // Ensure the cache path exists and validate that edited dependencies.
        createCacheDirectories(with: diagnostics)

        // FIXME: this should not block
        // Load the root manifests and currently checked out manifests.
        let rootManifests = try temp_await { self.loadRootManifests(packages: root.packages, diagnostics: diagnostics, completion: $0) }

        // Load the current manifests.
        let graphRoot = PackageGraphRoot(input: root, manifests: rootManifests, explicitProduct: explicitProduct)
        let currentManifests = try self.loadDependencyManifests(root: graphRoot, diagnostics: diagnostics)
        guard !diagnostics.hasErrors else {
            return currentManifests
        }

        validatePinsStore(dependencyManifests: currentManifests, diagnostics: diagnostics)

        // Abort if pinsStore is unloadable or if diagnostics has errors.
        guard !diagnostics.hasErrors, let pinsStore = diagnostics.wrap({ try pinsStore.load() }) else {
            return currentManifests
        }

        // Compute the missing package identities.
        let missingPackageURLs = currentManifests.missingPackageURLs()

        // Compute if we need to run the resolver. We always run the resolver if
        // there are extra constraints.
        if !missingPackageURLs.isEmpty {
            delegate?.willResolveDependencies(reason: .newPackages(packages: Array(missingPackageURLs)))
        } else if !extraConstraints.isEmpty || forceResolution {
            delegate?.willResolveDependencies(reason: .forced)
        } else {
            let result = precomputeResolution(
                root: graphRoot,
                dependencyManifests: currentManifests,
                pinsStore: pinsStore,
                extraConstraints: extraConstraints
            )

            switch result {
            case .notRequired:
                try self.updateBinaryArtifacts(
                    manifests: currentManifests,
                    addedOrUpdatedPackages: [],
                    diagnostics: diagnostics)

                return currentManifests
            case .required(let reason):
                delegate?.willResolveDependencies(reason: reason)
            }
        }

        // Create the constraints.
        var constraints = [PackageContainerConstraint]()
        constraints += currentManifests.editedPackagesConstraints()
        constraints += graphRoot.constraints(mirrors: config.mirrors) + extraConstraints

        // Perform dependency resolution.
        let resolver = createResolver(pinsMap: pinsStore.pinsMap)
        self.activeResolver = resolver

        let result = resolveDependencies(
            resolver: resolver,
            constraints: constraints,
            diagnostics: diagnostics)

        // Reset the active resolver.
        self.activeResolver = nil

        guard !diagnostics.hasErrors else {
            return currentManifests
        }

        // Update the checkouts with dependency resolution result.
        let packageStateChanges = updateCheckouts(root: graphRoot, updateResults: result, diagnostics: diagnostics)
        guard !diagnostics.hasErrors else {
            return currentManifests
        }

        // Update the pinsStore.
        let updatedDependencyManifests = try self.loadDependencyManifests(root: graphRoot, diagnostics: diagnostics)

        // If we still have required URLs, we probably cloned a wrong URL for
        // some package dependency.
        //
        // This would usually happen when we're resolving from scratch and the
        // resolved file has an outdated entry for a transitive dependency whose
        // URL was changed. For e.g., the resolved file could refer to a dependency
        // through a ssh url but its new reference is now changed to http.
        let missing = updatedDependencyManifests.computePackageURLs().missing
        if !missing.isEmpty {
            if retryOnPackagePathMismatch {
                // Retry resolution which will most likely resolve correctly now since
                // we have the manifest files of all the dependencies.
                return try self._resolve(
                    root: root,
                    explicitProduct: explicitProduct,
                    forceResolution: forceResolution,
                    extraConstraints: extraConstraints,
                    diagnostics: diagnostics,
                    retryOnPackagePathMismatch: false,
                    resetPinsStoreOnFailure: resetPinsStoreOnFailure
                )
            } else if resetPinsStoreOnFailure, !pinsStore.pinsMap.isEmpty {
                // If we weren't able to resolve properly even after a retry, it
                // could mean that the dependency at fault has a different
                // version of the manifest file which contains dependencies that
                // have also changed their package references.
                pinsStore.unpinAll()
                try pinsStore.saveState()
                // try again with pins reset
                return try self._resolve(
                    root: root,
                    explicitProduct: explicitProduct,
                    forceResolution: forceResolution,
                    extraConstraints: extraConstraints,
                    diagnostics: diagnostics,
                    retryOnPackagePathMismatch: false,
                    resetPinsStoreOnFailure: false
                )
            } else {
                // give up
                let missing = missing.map{ $0.description }
                diagnostics.emit(error: "exhausted attempts to resolve the dependencies graph, with '\(missing.joined(separator: "', '"))' unresolved.")
                return updatedDependencyManifests
            }
        }

        self.pinAll(dependencyManifests: updatedDependencyManifests, pinsStore: pinsStore, diagnostics: diagnostics)

        let addedOrUpdatedPackages = packageStateChanges.compactMap({ $0.1.isAddedOrUpdated ? $0.0 : nil })
        try self.updateBinaryArtifacts(
            manifests: updatedDependencyManifests,
            addedOrUpdatedPackages: addedOrUpdatedPackages,
            diagnostics: diagnostics)

        return updatedDependencyManifests
    }

    public enum ResolutionPrecomputationResult: Equatable {
        case required(reason: WorkspaceResolveReason)
        case notRequired

        public var isRequired: Bool {
            switch self {
            case .required: return true
            case .notRequired: return false
            }
        }
    }

    /// Computes if dependency resolution is required based on input constraints and pins.
    ///
    /// - Returns: Returns a result defining whether dependency resolution is required and the reason for it.
    // @testable internal
    public func precomputeResolution(
        root: PackageGraphRoot,
        dependencyManifests: DependencyManifests,
        pinsStore: PinsStore,
        extraConstraints: [PackageContainerConstraint] = []
    ) -> ResolutionPrecomputationResult {
        let constraints =
            root.constraints(mirrors: config.mirrors) +
            // Include constraints from the manifests in the graph root.
            root.manifests.flatMap({ $0.dependencyConstraints(productFilter: .everything, mirrors: config.mirrors) }) +
            dependencyManifests.dependencyConstraints() +
            extraConstraints

        let precomputationProvider = ResolverPrecomputationProvider(
            root: root,
            dependencyManifests: dependencyManifests,
            mirrors: config.mirrors
        )

        let resolver = PubgrubDependencyResolver(provider: precomputationProvider, pinsMap: pinsStore.pinsMap)
        let result = resolver.solve(constraints: constraints)

        switch result {
        case .success:
            return .notRequired
        case .failure(ResolverPrecomputationError.missingPackage(let package)):
            return .required(reason: .newPackages(packages: [package]))
        case .failure(ResolverPrecomputationError.differentRequirement(let package, let state, let requirement)):
            return .required(reason: .packageRequirementChange(
                package: package,
                state: state,
                requirement: requirement
            ))
        default:
            return .required(reason: .other)
        }
    }

    /// Validates that each checked out managed dependency has an entry in pinsStore.
    private func validatePinsStore(dependencyManifests: DependencyManifests, diagnostics: DiagnosticsEngine) {
        guard let pinsStore = diagnostics.wrap({ try pinsStore.load() }) else {
            return
        }

        let pins = pinsStore.pinsMap.keys
        let requiredURLs = dependencyManifests.computePackageURLs().required

        for dependency in state.dependencies {
            switch dependency.state {
            case .checkout: break
            case .edited, .local: continue
            }

            let identity = dependency.packageRef.identity

            if requiredURLs.contains(where: { $0.path == dependency.packageRef.path }) {
                // If required identity contains this dependency, it should be in the pins store.
                if let pin = pinsStore.pinsMap[identity], pin.packageRef.path == dependency.packageRef.path {
                    continue
                }
            } else if !pins.contains(identity) {
                // Otherwise, it should *not* be in the pins store.
                continue
            }

            return self.pinAll(dependencyManifests: dependencyManifests, pinsStore: pinsStore, diagnostics: diagnostics)
        }
    }

    /// This enum represents state of an external package.
    public enum PackageStateChange: Equatable, CustomStringConvertible {

        /// The requirement imposed by the the state.
        public enum Requirement: Equatable, CustomStringConvertible {
            /// A version requirement.
            case version(Version)

            /// A revision requirement.
            case revision(Revision, branch: String?)

            case unversioned

            public var description: String {
                switch self {
                case .version(let version):
                    return "requirement(\(version))"
                case .revision(let revision, let branch):
                    return "requirement(\(revision) \(branch ?? ""))"
                case .unversioned:
                    return "requirement(unversioned)"
                }
            }

            public var prettyPrinted: String {
                switch self {
                case .version(let version):
                    return "\(version)"
                case .revision(let revision, let branch):
                    return "\(revision) \(branch ?? "")"
                case .unversioned:
                    return "unversioned"
                }
            }
        }
        public struct State: Equatable {
            public let requirement: Requirement
            public let products: ProductFilter
            public init(requirement: Requirement, products: ProductFilter) {
                self.requirement = requirement
                self.products = products
            }
        }

        /// The package is added.
        case added(State)

        /// The package is removed.
        case removed

        /// The package is unchanged.
        case unchanged

        /// The package is updated.
        case updated(State)

        public var description: String {
            switch self {
            case .added(let requirement):
                return "added(\(requirement))"
            case .removed:
                return "removed"
            case .unchanged:
                return "unchanged"
            case .updated(let requirement):
                return "updated(\(requirement))"
            }
        }

        public var isAddedOrUpdated: Bool {
            switch self {
            case .added, .updated:
                return true
            case .unchanged, .removed:
                return false
            }
        }
    }

    /// Computes states of the packages based on last stored state.
    fileprivate func computePackageStateChanges(
        root: PackageGraphRoot,
        resolvedDependencies: [(PackageReference, BoundVersion, ProductFilter)],
        updateBranches: Bool
    ) throws -> [(PackageReference, PackageStateChange)] {
        // Load pins store and managed dependendencies.
        let pinsStore = try self.pinsStore.load()
        var packageStateChanges: [String: (PackageReference, PackageStateChange)] = [:]

        // Set the states from resolved dependencies results.
        for (packageRef, binding, products) in resolvedDependencies {
            // Get the existing managed dependency for this package ref, if any.
            let currentDependency: ManagedDependency?
            if let existingDependency = state.dependencies[forURL: packageRef.path] {
                currentDependency = existingDependency
            } else {
                // Check if this is a edited dependency.
                //
                // This is a little bit ugly but can probably be cleaned up by
                // putting information in the PackageReference type. We change
                // the package reference for edited packages which causes the
                // original checkout in somewhat of a dangling state when computing
                // the state changes this method. We basically need to ensure that
                // the edited checkout is unchanged.
                if let editedDependency = state.dependencies.first(where: {
                    guard $0.basedOn != nil else { return false }
                    return path(for: $0).pathString == packageRef.path
                }) {
                    currentDependency = editedDependency
                    let originalReference = editedDependency.basedOn!.packageRef // forced unwrap safe
                    packageStateChanges[originalReference.path] = (originalReference, .unchanged)
                } else {
                    currentDependency = nil
                }
            }

            switch binding {
            case .excluded:
                throw InternalError("Unexpected excluded binding")

            case .unversioned:
                // Ignore the root packages.
                if root.packageRefs.contains(packageRef) {
                    continue
                }

                if let currentDependency = currentDependency {
                    switch currentDependency.state {
                    case .local, .edited:
                        packageStateChanges[packageRef.path] = (packageRef, .unchanged)
                    case .checkout:
                        let newState = PackageStateChange.State(requirement: .unversioned, products: products)
                        packageStateChanges[packageRef.path] = (packageRef, .updated(newState))
                    }
                } else {
                    let newState = PackageStateChange.State(requirement: .unversioned, products: products)
                    packageStateChanges[packageRef.path] = (packageRef, .added(newState))
                }

            case .revision(let identifier, let branch):
                // Get the latest revision from the container.
                // TODO: replace with async/await when available
                guard let container = (try temp_await {
                    containerProvider.getContainer(for: packageRef, skipUpdate: true, on: self.queue, completion: $0)
                }) as? RepositoryPackageContainer else {
                    throw InternalError("invalid container for \(packageRef) expected a RepositoryPackageContainer")
                }
                var revision = try container.getRevision(forIdentifier: identifier)
                let branch = branch ?? (identifier == revision.identifier ? nil : identifier)

                // If we have a branch and we shouldn't be updating the
                // branches, use the revision from pin instead (if present).
                if branch != nil {
                    if let pin = pinsStore.pins.first(where: { $0.packageRef == packageRef }),
                        !updateBranches,
                        pin.state.branch == branch {
                        revision = pin.state.revision
                    }
                }

                // First check if we have this dependency.
                if let currentDependency = currentDependency {
                    // If current state and new state are equal, we don't need
                    // to do anything.
                    let newState = CheckoutState(revision: revision, branch: branch)
                    if case .checkout(let checkoutState) = currentDependency.state, checkoutState == newState {
                        packageStateChanges[packageRef.path] = (packageRef, .unchanged)
                    } else {
                        // Otherwise, we need to update this dependency to this revision.
                        let newState = PackageStateChange.State(requirement: .revision(revision, branch: branch), products: products)
                        packageStateChanges[packageRef.path] = (packageRef, .updated(newState))
                    }
                } else {
                    let newState = PackageStateChange.State(requirement: .revision(revision, branch: branch), products: products)
                    packageStateChanges[packageRef.path] = (packageRef, .added(newState))
                }

            case .version(let version):
                if let currentDependency = currentDependency {
                    if case .checkout(let checkoutState) = currentDependency.state, checkoutState.version == version {
                        packageStateChanges[packageRef.path] = (packageRef, .unchanged)
                    } else {
                        let newState = PackageStateChange.State(requirement: .version(version), products: products)
                        packageStateChanges[packageRef.path] = (packageRef, .updated(newState))
                    }
                } else {
                    let newState = PackageStateChange.State(requirement: .version(version), products: products)
                    packageStateChanges[packageRef.path] = (packageRef, .added(newState))
                }
            }
        }
        // Set the state of any old package that might have been removed.
        for packageRef in state.dependencies.lazy.map({ $0.packageRef }) where packageStateChanges[packageRef.path] == nil {
            packageStateChanges[packageRef.path] = (packageRef, .removed)
        }

        return Array(packageStateChanges.values)
    }

    /// Creates resolver for the workspace.
    fileprivate func createResolver(pinsMap: PinsStore.PinsMap) -> PubgrubDependencyResolver {
        let traceFile = enableResolverTrace ? self.dataPath.appending(components: "resolver.trace") : nil

        return PubgrubDependencyResolver(
            provider: containerProvider,
            pinsMap: pinsMap,
            isPrefetchingEnabled: isResolverPrefetchingEnabled,
            skipUpdate: skipUpdate, traceFile: traceFile
        )
    }

    /// Runs the dependency resolver based on constraints provided and returns the results.
    fileprivate func resolveDependencies(
        resolver: PubgrubDependencyResolver,
        constraints: [PackageContainerConstraint],
        diagnostics: DiagnosticsEngine
    ) -> [(container: PackageReference, binding: BoundVersion, products: ProductFilter)] {

        os_signpost(.begin, log: .swiftpm, name: SignpostName.resolution)
        let result = resolver.solve(constraints: constraints)
        os_signpost(.end, log: .swiftpm, name: SignpostName.resolution)

        // Take an action based on the result.
        switch result {
        case .success(let bindings):
            return bindings
        case .failure(let error):
            diagnostics.emit(error)
            return []
        }
    }

    /// Validates that all the edited dependencies are still present in the file system.
    /// If some checkout dependency is reomved form the file system, clone it again.
    /// If some edited dependency is removed from the file system, mark it as unedited and
    /// fallback on the original checkout.
    fileprivate func fixManagedDependencies(with diagnostics: DiagnosticsEngine) {

        // Reset managed dependencies if the state file was removed during the lifetime of the Workspace object.
        if !state.dependencies.isEmpty && !state.stateFileExists() {
            try? state.reset()
        }

        // Make a copy of dependencies as we might mutate them in the for loop.
        let allDependencies = Array(state.dependencies)
        for dependency in allDependencies {
            diagnostics.wrap {

                // If the dependency is present, we're done.
                let dependencyPath = path(for: dependency)
                guard !fileSystem.isDirectory(dependencyPath) else { return }

                switch dependency.state {
                case .checkout(let checkoutState):
                    // If some checkout dependency has been removed, clone it again.
                    _ = try clone(package: dependency.packageRef, at: checkoutState)
                    diagnostics.emit(.checkedOutDependencyMissing(packageName: dependency.packageRef.name))

                case .edited:
                    // If some edited dependency has been removed, mark it as unedited.
                    //
                    // Note: We don't resolve the dependencies when unediting
                    // here because we expect this method to be called as part
                    // of some other resolve operation (i.e. resolve, update, etc).
                    try unedit(dependency: dependency, forceRemove: true, diagnostics: diagnostics)

                    diagnostics.emit(.editedDependencyMissing(packageName: dependency.packageRef.name))

                case .local:
                    state.dependencies.remove(forURL: dependency.packageRef.path)
                    try state.saveState()
                }
            }
        }
    }
}

// MARK: - Repository Management

extension Workspace {

    /// Updates the current working checkouts i.e. clone or remove based on the
    /// provided dependency resolution result.
    ///
    /// - Parameters:
    ///   - updateResults: The updated results from dependency resolution.
    ///   - diagnostics: The diagnostics engine that reports errors, warnings
    ///     and notes.
    ///   - updateBranches: If the branches should be updated in case they're pinned.
    @discardableResult
    fileprivate func updateCheckouts(
        root: PackageGraphRoot,
        updateResults: [(PackageReference, BoundVersion, ProductFilter)],
        updateBranches: Bool = false,
        diagnostics: DiagnosticsEngine
    ) -> [(PackageReference, PackageStateChange)] {
        // Get the update package states from resolved results.
        guard let packageStateChanges = diagnostics.wrap({
            try computePackageStateChanges(root: root, resolvedDependencies: updateResults, updateBranches: updateBranches)
        }) else {
            return []
        }

        // First remove the checkouts that are no longer required.
        for (packageRef, state) in packageStateChanges {
            diagnostics.wrap {
                switch state {
                case .added, .updated, .unchanged: break
                case .removed:
                    try remove(package: packageRef)
                }
            }
        }

        // Update or clone new packages.
        for (packageRef, state) in packageStateChanges {
            diagnostics.wrap {
                switch state {
                case .added(let state):
                    _ = try clone(package: packageRef, requirement: state.requirement, productFilter: state.products)
                case .updated(let state):
                    _ = try clone(package: packageRef, requirement: state.requirement, productFilter: state.products)
                case .removed, .unchanged: break
                }
            }
        }

        // Inform the delegate if nothing was updated.
        if packageStateChanges.filter({ $0.1 == .unchanged }).count == packageStateChanges.count {
            delegate?.dependenciesUpToDate()
        }

        return packageStateChanges
    }

    /// Fetch a given `repository` and create a local checkout for it.
    ///
    /// This will first clone the repository into the canonical repositories
    /// location, if necessary, and then check it out from there.
    ///
    /// - Returns: The path of the local repository.
    /// - Throws: If the operation could not be satisfied.
    private func fetch(package: PackageReference) throws -> AbsolutePath {
        // If we already have it, fetch to update the repo from its remote.
        if let dependency = state.dependencies[forURL: package.path] {
            let path = checkoutsPath.appending(dependency.subpath)

            // Make sure the directory is not missing (we will have to clone again
            // if not).
            fetch: if fileSystem.isDirectory(path) {
                // Fetch the checkout in case there are updates available.
                let workingRepo = try repositoryManager.provider.openCheckout(at: path)

                // Ensure that the alternative object store is still valid.
                //
                // This can become invalid if the build directory is moved.
                guard workingRepo.isAlternateObjectStoreValid() else {
                    break fetch
                }

                // The fetch operation may update contents of the checkout, so
                // we need do mutable-immutable dance.
                try fileSystem.chmod(.userWritable, path: path, options: [.recursive, .onlyFiles])
                try workingRepo.fetch()
                try? fileSystem.chmod(.userUnWritable, path: path, options: [.recursive, .onlyFiles])

                return path
            }
        }

        // If not, we need to get the repository from the checkouts.
        // FIXME: this should not block
        let handle = try temp_await {
            repositoryManager.lookup(repository: package.repository, skipUpdate: true, on: self.queue, completion: $0)
        }

        // Clone the repository into the checkouts.
        let path = checkoutsPath.appending(component: package.repository.basename)

        try fileSystem.chmod(.userWritable, path: path, options: [.recursive, .onlyFiles])
        try fileSystem.removeFileTree(path)

        // Inform the delegate that we're starting cloning.
        delegate?.willClone(repository: handle.repository.url, to: path)
        try handle.cloneCheckout(to: path, editable: false)
        delegate?.didClone(repository: handle.repository.url, to: path, error: nil)

        return path
    }

    /// Create a local clone of the given `repository` checked out to `version`.
    ///
    /// If an existing clone is present, the repository will be reset to the
    /// requested revision, if necessary.
    ///
    /// - Parameters:
    ///   - package: The package to clone.
    ///   - checkoutState: The state to check out.
    /// - Returns: The path of the local repository.
    /// - Throws: If the operation could not be satisfied.
    func clone(
        package: PackageReference,
        at checkoutState: CheckoutState
    ) throws -> AbsolutePath {
        // Get the repository.
        let path = try fetch(package: package)

        // Check out the given revision.
        let workingRepo = try repositoryManager.provider.openCheckout(at: path)

        // Inform the delegate.
        delegate?.willCheckOut(repository: package.repository.url, revision: checkoutState.description, at: path)

        // Do mutable-immutable dance because checkout operation modifies the disk state.
        try fileSystem.chmod(.userWritable, path: path, options: [.recursive, .onlyFiles])
        try workingRepo.checkout(revision: checkoutState.revision)
        try? fileSystem.chmod(.userUnWritable, path: path, options: [.recursive, .onlyFiles])

        // Write the state record.
        state.dependencies.add(ManagedDependency(
            packageRef: package,
            subpath: path.relative(to: checkoutsPath),
            checkoutState: checkoutState))
        try state.saveState()

        delegate?.didCheckOut(repository: package.repository.url, revision: checkoutState.description, at: path, error: nil)

        return path
    }

    private func clone(
        package: PackageReference,
        requirement: PackageStateChange.Requirement,
        productFilter: ProductFilter
    ) throws -> AbsolutePath {
        let checkoutState: CheckoutState

        switch requirement {
        case .version(let version):
            // FIXME: We need to get the revision here, and we don't have a
            // way to get it back out of the resolver which is very
            // annoying. Maybe we should make an SPI on the provider for
            // this?
            // FIXME: this should not block
            guard let container = (try temp_await {
                containerProvider.getContainer(for: package, skipUpdate: true, on: self.queue, completion: $0)
            }) as? RepositoryPackageContainer else {
                throw InternalError("invalid container for \(package) expected a RepositoryPackageContainer")
            }
            guard let tag = container.getTag(for: version) else {
                throw InternalError("unable to get tag for \(package) \(version); available versions \(try container.versionsDescending())")
            }
            let revision = try container.getRevision(forTag: tag)
            checkoutState = CheckoutState(revision: revision, version: version)

        case .revision(let revision, let branch):
            checkoutState = CheckoutState(revision: revision, branch: branch)

        case .unversioned:
            state.dependencies.add(ManagedDependency.local(packageRef: package))
            try state.saveState()
            return AbsolutePath(package.path)
        }

        return try self.clone(package: package, at: checkoutState)
    }

    /// Removes the clone and checkout of the provided specifier.
    fileprivate func remove(package: PackageReference) throws {

        guard let dependency = state.dependencies[forURL: package.path] else {
            throw InternalError("trying to remove \(package.name) which isn't in workspace")
        }

        // We only need to update the managed dependency structure to "remove"
        // a local package.
        //
        // Note that we don't actually remove a local package from disk.
        switch dependency.state {
        case .local:
            state.dependencies.remove(forURL: package.path)
            try state.saveState()
            return
        case .checkout, .edited:
            break
        }

        // Inform the delegate.
        delegate?.removing(repository: dependency.packageRef.repository.url)

        // Compute the dependency which we need to remove.
        let dependencyToRemove: ManagedDependency

        if let basedOn = dependency.basedOn {
            // Remove the underlying dependency for edited packages.
            dependencyToRemove = basedOn
            dependency.basedOn = nil
            state.dependencies.add(dependency)
        } else {
            dependencyToRemove = dependency
            state.dependencies.remove(forURL: dependencyToRemove.packageRef.path)
        }

        // Remove the checkout.
        let dependencyPath = checkoutsPath.appending(dependencyToRemove.subpath)
        let checkedOutRepo = try repositoryManager.provider.openCheckout(at: dependencyPath)
        guard !checkedOutRepo.hasUncommittedChanges() else {
            throw WorkspaceDiagnostics.UncommitedChanges(repositoryPath: dependencyPath)
        }

        try fileSystem.chmod(.userWritable, path: dependencyPath, options: [.recursive, .onlyFiles])
        try fileSystem.removeFileTree(dependencyPath)

        // Remove the clone.
        try repositoryManager.remove(repository: dependencyToRemove.packageRef.repository)

        // Save the state.
        try state.saveState()
    }
}

/// A result which can be loaded.
///
/// It is useful for objects that holds a state on disk and needs to be
/// loaded frequently.
public final class LoadableResult<Value> {

    /// The constructor closure for the value.
    private let construct: () throws -> Value

    /// Create a loadable result.
    public init(_ construct: @escaping () throws -> Value) {
        self.construct = construct
    }

    /// Load and return the result.
    public func loadResult() -> Result<Value, Error> {
        return Result(catching: {
            try self.construct()
        })
    }

    /// Load and return the value.
    public func load() throws -> Value {
        return try loadResult().get()
    }
}
