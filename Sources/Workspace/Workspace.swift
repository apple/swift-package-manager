/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basic
import PackageLoading
import PackageModel
import PackageGraph
import SourceControl
import Utility

/// An error in one of the workspace operations
public enum WorkspaceOperationError: Swift.Error {
    /// The requested repository could not be accessed.
    case unavailableRepository

    /// The repository has uncommited changes.
    case hasUncommitedChanges(repo: AbsolutePath)

    /// The repository has unpushed changes.
    case hasUnpushedChanges(repo: AbsolutePath)

    /// The dependency is already in edit mode.
    case dependencyAlreadyInEditMode

    /// The dependency is not in edit mode.
    case dependencyNotInEditMode

    /// The branch already exists in repository.
    case branchAlreadyExists

    /// There are no registered root package paths.
    case noRegisteredPackages

    /// The given path is not a registered root package.
    case pathNotRegistered(path: AbsolutePath)

    /// The root package has incompatible tools version.
    case incompatibleToolsVersion(rootPackage: AbsolutePath, required: ToolsVersion, current: ToolsVersion)
}

/// The delegate interface used by the workspace to report status information.
public protocol WorkspaceDelegate: class {
    /// The workspace is fetching additional repositories in support of
    /// loading a complete package.
    func fetchingMissingRepositories(_ urls: Set<String>)

    /// The workspace has started fetching this repository.
    func fetching(repository: String)

    /// The workspace has started cloning this repository.
    func cloning(repository: String)

    /// The workspace is checking out this repository at a version or revision.
    func checkingOut(repository: String, at reference: String)

    /// The workspace is removing this repository because it is no longer needed.
    func removing(repository: String)

    /// The workspace operation emitted this warning.
    func warning(message: String)
}

private class WorkspaceResolverDelegate: DependencyResolverDelegate {
    typealias Identifier = RepositoryPackageContainer.Identifier

    func added(container identifier: Identifier) {
    }
}

private class WorkspaceRepositoryManagerDelegate: RepositoryManagerDelegate {
    unowned let workspaceDelegate: WorkspaceDelegate

    init(workspaceDelegate: WorkspaceDelegate) {
        self.workspaceDelegate = workspaceDelegate
    }

    func fetching(handle: RepositoryManager.RepositoryHandle, to path: AbsolutePath) {
        workspaceDelegate.fetching(repository: handle.repository.url)
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
    /// An individual managed dependency.
    ///
    /// Each dependency will have a checkout containing the sources at a
    /// particular revision, and may have an associated version.
    public final class ManagedDependency {
        /// The specifier for the dependency.
        public let repository: RepositorySpecifier

        /// The checked out path of the dependency on disk, relative to the workspace checkouts path.
        public let subpath: RelativePath

        /// The current version of the dependency, if known.
        public let currentVersion: Version?

        /// The dependency is in editable state i.e. user is expected to modify the sources of the dependency.
        /// The version of the dependency will not be considered during dependency resolution.
        public var isInEditableState: Bool {
            return basedOn != nil
        }

        /// A dependency which in editable state is based on a dependency from which it edited from.
        /// This information is useful so it can be restored when users unedit a package.
        let basedOn: ManagedDependency?

        /// The current revision of the dependency.
        ///
        /// This should always be a revision corresponding to the version in the
        /// repository, but in certain circumstances it may not be the *current*
        /// one (e.g., if this data is accessed with a different version of the
        /// package manager, which would cause an alternate version to be
        /// resolved).
        public let currentRevision: Revision?

        fileprivate init(repository: RepositorySpecifier, subpath: RelativePath, currentVersion: Version?, currentRevision: Revision) {
            self.repository = repository
            self.subpath = subpath
            self.currentVersion = currentVersion
            self.currentRevision = currentRevision
            self.basedOn = nil
        }

        private init(basedOn dependency: ManagedDependency, subpath: RelativePath) {
            assert(!dependency.isInEditableState)
            self.basedOn = dependency
            self.repository = dependency.repository
            self.subpath = subpath
            self.currentRevision = nil
            self.currentVersion = nil
        }

        /// Create an editable managed dependency based on a dependency which was *not* in edit state.
        func makingEditable(subpath: RelativePath) -> ManagedDependency {
            return ManagedDependency(basedOn: self, subpath: subpath)
        }

        // MARK: Persistence

        /// Create an instance from JSON data.
        fileprivate init?(json data: JSON) {
            guard case let .dictionary(contents) = data,
                  case let .string(repositoryURL)? = contents["repositoryURL"],
                  case let .string(subpathString)? = contents["subpath"],
                  let currentVersionData = contents["currentVersion"],
                  let basedOnData = contents["basedOn"],
                  let currentRevisionString = contents["currentRevision"] else {
                return nil
            }
            self.repository = RepositorySpecifier(url: repositoryURL)
            self.subpath = RelativePath(subpathString)
            self.currentVersion = Version(json: currentVersionData)
            self.currentRevision = Revision(json: currentRevisionString)
            self.basedOn = ManagedDependency(json: basedOnData) ?? nil
        }

        fileprivate func toJSON() -> JSON {
            return .dictionary([
                    "repositoryURL": .string(repository.url),
                    "subpath": .string(subpath.asString),
                    "currentVersion":  currentVersion.flatMap { JSON.string(String(describing: $0)) } ?? .null,
                    "currentRevision": currentRevision.flatMap { JSON.string($0.identifier) } ?? .null,
                    "basedOn": basedOn?.toJSON() ?? .null,
                ])
        }
    }

    /// A struct representing all the current manifests (root + external) in a package graph.
    public struct DependencyManifests {
        /// The root manifests.
        let roots: [Manifest]

        /// The dependency manifests in the transitive closure of root manifest.
        let dependencies: [(manifest: Manifest, dependency: ManagedDependency)]

        /// Computes the URLs which are declared in the manifests but aren't present in dependencies.
        func missingURLs() -> Set<String> {
            let manifestsMap = Dictionary<String, Manifest>(items:
                roots.map{ ($0.url, $0) } +
                dependencies.map{ ($0.manifest.url, $0.manifest) }
            )

            var requiredURLs = transitiveClosure(roots.map{ $0.url}) { url in
                guard let manifest = manifestsMap[url] else { return [] }
                return manifest.package.dependencies.map{ $0.url }
            }
            for root in roots {
                requiredURLs.insert(root.url)
            }

            let availableURLs = Set<String>(manifestsMap.keys)
            // We should never have loaded a manifest we don't need.
            assert(availableURLs.isSubset(of: requiredURLs))
            // These are the missing URLs.
            return requiredURLs.subtracting(availableURLs)
        }

        /// Find a package given its name.
        public func lookup(package name: String) -> (manifest: Manifest, dependency: ManagedDependency)? {
            return dependencies.first(where: { $0.manifest.name == name })
        }

        /// Find a manifest given its name.
        public func lookup(manifest name: String) -> Manifest? {
            return lookup(package: name)?.manifest
        }

        init(roots: [Manifest], dependencies: [(Manifest, ManagedDependency)]) {
            self.roots = roots
            self.dependencies = dependencies
        }
    }

    /// The delegate interface.
    public let delegate: WorkspaceDelegate

    /// The paths of the registered root packages.
    public private(set) var rootPackages: Set<AbsolutePath>

    /// The path of the workspace data.
    public let dataPath: AbsolutePath

    /// The path for working repository clones (checkouts).
    let checkoutsPath: AbsolutePath

    /// The path where packages which are put in edit mode are checked out.
    let editablesPath: AbsolutePath

    /// The file system on which the workspace will operate.
    private var fileSystem: FileSystem

    /// The Pins store. The pins file will be created when first pin is added to pins store.
    public var pinsStore: PinsStore

    /// The manifest loader to use.
    let manifestLoader: ManifestLoaderProtocol

    /// The tools version currently in use.
    let currentToolsVersion: ToolsVersion

    /// The manifest loader to use.
    let toolsVersionLoader: ToolsVersionLoaderProtocol

    /// The repository manager.
    private let repositoryManager: RepositoryManager

    /// The package container provider.
    private let containerProvider: RepositoryPackageContainerProvider

    /// The current state of managed dependencies.
    private(set) var dependencyMap: [RepositorySpecifier: ManagedDependency]

    /// Enable prefetching containers in resolver.
    let enableResolverPrefetching: Bool

    /// The known set of dependencies.
    public var dependencies: AnySequence<ManagedDependency> {
        return AnySequence<ManagedDependency>(dependencyMap.values)
    }

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
        currentToolsVersion: ToolsVersion = ToolsVersion.currentToolsVersion,
        toolsVersionLoader: ToolsVersionLoaderProtocol = ToolsVersionLoader(),
        delegate: WorkspaceDelegate,
        fileSystem: FileSystem = localFileSystem,
        repositoryProvider: RepositoryProvider = GitRepositoryProvider(),
        enableResolverPrefetching: Bool = false
    ) throws {
        self.rootPackages = []
        self.delegate = delegate
        self.dataPath = dataPath
        self.editablesPath = editablesPath
        self.manifestLoader = manifestLoader
        self.currentToolsVersion = currentToolsVersion
        self.toolsVersionLoader = toolsVersionLoader
        self.enableResolverPrefetching = enableResolverPrefetching 

        let repositoriesPath = self.dataPath.appending(component: "repositories")
        self.repositoryManager = RepositoryManager(
            path: repositoriesPath, provider: repositoryProvider, delegate: WorkspaceRepositoryManagerDelegate(workspaceDelegate: delegate), fileSystem: fileSystem)
        self.checkoutsPath = self.dataPath.appending(component: "checkouts")
        self.containerProvider = RepositoryPackageContainerProvider(
            repositoryManager: repositoryManager, manifestLoader: manifestLoader, toolsVersionLoader: toolsVersionLoader)
        self.fileSystem = fileSystem

        // Initialize the default state.
        self.dependencyMap = [:]

        self.pinsStore = try PinsStore(pinsFile: pinsFile, fileSystem: self.fileSystem)

        // Ensure the cache path exists.
        try createCacheDirectories()

        // Load the state from disk, if possible.
        if try !restoreState() {
            // There was no state, write the default state immediately.
            try saveState()
        }
    }

    /// Create the cache directories.
    private func createCacheDirectories() throws {
        try fileSystem.createDirectory(repositoryManager.path, recursive: true)
        try fileSystem.createDirectory(checkoutsPath, recursive: true)
    }

    /// Registers the provided path as a root package. It is valid to re-add previously registered path.
    ///
    /// Note: This method just registers the path and does not validate it. A newly registered
    /// package will only be loaded on explicitly calling a related API.
    public func registerPackage(at path: AbsolutePath) {
        rootPackages.insert(path)
    }

    /// Unregister the provided path. This method will throw if the provided path is not a registered package.
    ///
    /// Note: Clients should call a related API to update managed dependencies.
    public func unregisterPackage(at path: AbsolutePath) throws {
        guard rootPackages.contains(path) else {
            throw WorkspaceOperationError.pathNotRegistered(path: path)
        }
        rootPackages.remove(path)
    }

    /// Cleans the build artefacts from workspace data.
    public func clean() throws {
        // These are the things we don't want to remove while cleaning.
        let protectedAssets = Set<String>([
            repositoryManager.path,
            checkoutsPath,
            statePath,
        ].map { path in
            // Assert that these are present inside data directory.
            assert(path.parentDirectory == dataPath)
            return path.basename
        })
        // If we have no data yet, we're done.
        guard fileSystem.exists(dataPath) else {
            return
        }
        for name in try fileSystem.getDirectoryContents(dataPath) {
            guard !protectedAssets.contains(name) else { continue }
            fileSystem.removeFileTree(dataPath.appending(RelativePath(name)))
        }
    }

    /// Resets the entire workspace by removing the data directory.
    public func reset() throws {
        dependencyMap = [:]
        repositoryManager.reset()
        fileSystem.removeFileTree(dataPath)
        try createCacheDirectories()
    }

    /// Puts a dependency in edit mode creating a checkout in editables directory.
    ///
    /// - Parameters:
    ///     - dependency: The dependency to put in edit mode.
    ///     - revision:   If provided, the revision at which the dependency should be checked out to otherwise current revision.
    ///     - packageName: The name of the package corresponding to the dependency. This is used for the checkout directory name.
    ///     - checkoutBranch: If provided, a new branch with this name will be created from the revision provided.
    ///
    /// - throws: WorkspaceOperationError
    public func edit(dependency: ManagedDependency, at revision: Revision?, packageName: String, checkoutBranch: String? = nil) throws {
        // Ensure that the dependency is not already in edit mode.
        guard !dependency.isInEditableState else {
            throw WorkspaceOperationError.dependencyAlreadyInEditMode
        }

        // Compute new path for the dependency.
        let path = editablesPath.appending(component: packageName)
        // Get handle to the repository.
        let handle = try repositoryManager.lookupSynchronously(repository: dependency.repository)

        // If a branch is provided, make sure it isn't already present in the repository.
        if let branch = checkoutBranch {
            let repo = try handle.open()
            guard !repo.exists(revision: Revision(identifier: branch)) else {
                throw WorkspaceOperationError.branchAlreadyExists
            }
        }

        try handle.cloneCheckout(to: path, editable: true)
        let workingRepo = try repositoryManager.provider.openCheckout(at: path)
        try workingRepo.checkout(revision: revision ?? dependency.currentRevision!)
        // Checkout to the new branch if provided.
        if let branch = checkoutBranch {
            try workingRepo.checkout(newBranch: branch)
        }

        // Change its stated to edited.
        dependencyMap[dependency.repository] = dependency.makingEditable(subpath: path.relative(to: editablesPath))
        // Save the state.
        try saveState()
    }

    /// Ends the edit mode of a dependency which is in edit mode.
    ///
    /// - Parameters:
    ///     - dependency: The dependency to be unedited.
    ///     - forceRemove: If true, the dependency will be unedited even if has
    /// unpushed and uncommited changes. Otherwise will throw respective errors.
    ///
    /// - throws: WorkspaceOperationError
    public func unedit(dependency: ManagedDependency, forceRemove: Bool) throws {
        // If the dependency isn't in edit mode, we can't unedit it.
        guard let basedOn = dependency.basedOn else {
            throw WorkspaceOperationError.dependencyNotInEditMode
        }
        // Form the edit working repo path.
        let path = editablesPath.appending(dependency.subpath)
        // Check for uncommited and unpushed changes if force removal is off.
        if !forceRemove {
            let workingRepo = try repositoryManager.provider.openCheckout(at: path)
            guard !workingRepo.hasUncommitedChanges() else {
                throw WorkspaceOperationError.hasUncommitedChanges(repo: path)
            }
            guard try !workingRepo.hasUnpushedCommits() else {
                throw WorkspaceOperationError.hasUnpushedChanges(repo: path)
            }
        }
        // Remove the editable checkout from disk.
        if fileSystem.exists(path) {
            fileSystem.removeFileTree(path)
        }
        // If this was the last editable dependency, remove the editables directory too.
        if fileSystem.exists(editablesPath), try fileSystem.getDirectoryContents(editablesPath).isEmpty {
            fileSystem.removeFileTree(editablesPath)
        }
        // Restore the dependency state.
        dependencyMap[dependency.repository] = basedOn
        // Save the state.
        try saveState()
    }

    /// Pins a package at a given version.
    ///
    /// - Parameters:
    ///   - dependency: The dependency to pin.
    ///   - packageName: The name of the package which is being pinned.
    ///   - version: The version to pin at.
    ///   - reason: The optional reason for pinning.
    /// - Throws: WorkspaceOperationError, PinOperationError
    public func pin(dependency: ManagedDependency, packageName: String, at version: Version, reason: String? = nil) throws {
        assert(!dependency.isInEditableState, "Can not pin a dependency which is in being edited.")
        // Compute constaints with the new pin and try to resolve dependencies. We only commit the pin if the
        // dependencies can be resolved with new constraints.
        //
        // The constraints consist of three things:
        // * Root manifest contraints without pins.
        // * Exisiting pins except the dependency we're currently pinning.
        // * The constraint for the new pin we're trying to add.
        let constraints = computeRootPackagesConstraints(try loadRootManifests(), includePins: false)
                        + pinsStore.createConstraints().filter({ $0.identifier != dependency.repository }) as [RepositoryPackageConstraint]
                        + [RepositoryPackageConstraint(container: dependency.repository, versionRequirement: .exact(version))]
        // Resolve the dependencies.
        let results = try resolveDependencies(constraints: constraints)
        // Add the record in pins store.
        try pinsStore.pin(package: packageName, repository: dependency.repository, at: version, reason: reason)
        // Update the checkouts based on new dependency resolution.
        try updateCheckouts(with: results)
    }

    /// Pins all of the dependencies to the loaded version.
    ///
    /// - Parameters:
    ///   - reason: The optional reason for pinning.
    ///   - reset: Remove all current pins before pinning dependencies.
    public func pinAll(reason: String? = nil, reset: Bool = false) throws {
        if reset {
            try pinsStore.unpinAll()
        }
        // Load the package graph
        _ = try loadPackageGraph()
        // Load the dependencies.
        let dependencyManifests = try loadDependencyManifests()
        // Start pinning each dependency.
        for dependencyManifest in dependencyManifests.dependencies {
            // Get package name.
            let package = dependencyManifest.manifest.name

            // Get the managed dependency.
            var dependency = dependencyManifest.dependency

            // For editable dependencies, pin the underlying dependency if we have them.
            if dependency.isInEditableState {
                if let basedOn = dependency.basedOn {
                    dependency = basedOn
                } else {
                    delegate.warning(message: "not pinning \(package). It is being edited but is no longer needed.")
                    continue
                }
            }

            // We should have a version loaded to pin. This will never happen right now
            // because we can't have dependencies checked out to a git ref.
            guard let version = dependency.currentVersion else {
                delegate.warning(message: "not pinning \(package) because doesn't have a version loaded.")
                continue
            }
            // Commit the pin.
            try pinsStore.pin(
                package: package,
                repository: dependency.repository,
                at: version,
                reason: reason)
        }
    }

    // MARK: Low-level Operations

    /// Fetch a given `repository` and create a local checkout for it.
    ///
    /// This will first clone the repository into the canonical repositories
    /// location, if necessary, and then check it out from there.
    ///
    /// - Returns: The path of the local repository.
    /// - Throws: If the operation could not be satisfied.
    private func fetch(repository: RepositorySpecifier) throws -> AbsolutePath {
        // If we already have it, fetch to update the repo from its remote.
        if let dependency = dependencyMap[repository] {
            let path = checkoutsPath.appending(dependency.subpath)
            // Fetch the checkout in case there are updates available.
            let workingRepo = try repositoryManager.provider.openCheckout(at: path)
            try workingRepo.fetch()
            return path
        }

        // If not, we need to get the repository from the checkouts.
        let handle = try repositoryManager.lookupSynchronously(repository: repository)

        // Clone the repository into the checkouts.
        let path = checkoutsPath.appending(component: repository.fileSystemIdentifier)
        // Ensure the destination is free.
        fileSystem.removeFileTree(path)
        // Inform the delegate that we're starting cloning.
        delegate.cloning(repository: handle.repository.url)
        try handle.cloneCheckout(to: path, editable: false)

        return path
    }

    /// Create a local clone of the given `repository` checked out to `version`.
    ///
    /// If an existing clone is present, the repository will be reset to the
    /// requested revision, if necessary.
    ///
    /// - Parameters:
    ///   - repository: The repository to clone.
    ///   - revision: The revision to check out.
    ///   - version: The dependency version the repository is being checked out at, if known.
    /// - Returns: The path of the local repository.
    /// - Throws: If the operation could not be satisfied.
    //
    // FIXME: We are probably going to need a delegate interface so we have a
    // mechanism for observing the actions.
    func clone(repository: RepositorySpecifier, at revision: Revision, for version: Version? = nil) throws -> AbsolutePath {
        // Get the repository.
        let path = try fetch(repository: repository)

        // Check out the given revision.
        let workingRepo = try repositoryManager.provider.openCheckout(at: path)
        // Inform the delegate.
        delegate.checkingOut(repository: repository.url, at: version?.description ?? revision.identifier)
        try workingRepo.checkout(revision: revision)

        // Write the state record.
        dependencyMap[repository] = ManagedDependency(
                repository: repository, subpath: path.relative(to: checkoutsPath),
                currentVersion: version, currentRevision: revision)
        try saveState()

        return path
    }

    // FIXME: Eliminate this helper method which gets revision by loading container again.
    func clone(specifier: RepositorySpecifier, version: Version) throws -> AbsolutePath {
        // FIXME: We need to get the revision here, and we don't have a
        // way to get it back out of the resolver which is very
        // annoying. Maybe we should make an SPI on the provider for
        // this?
        let container = try await { containerProvider.getContainer(for: specifier, completion: $0) }
        guard let tag = container.getTag(for: version) else {
            fatalError("Resolved version: \(version) not found for \(specifier).")
        }
        let revision = try container.getRevision(for: tag)
        return try self.clone(repository: specifier, at: revision, for: version)
    }

    /// This enum represents state of an external package.
    enum PackageStateChange {
        /// A new package added.
        case added(Version)

        /// The package is removed.
        case removed

        /// The package is unchanged.
        case unchanged

        /// The package is updated to a new version.
        case updated(old: Version, new: Version)
    }

    /// Updates the current dependencies.
    public func updateDependencies(repin: Bool = false) throws {
        let currentManifests = try loadDependencyManifests()

        // Create constraints based on root manifest and pins for the update resolution.
        var updateConstraints = computeRootPackagesConstraints(currentManifests.roots, includePins: !repin)

        // Add unversioned constraint for edited packages.
        for (externalManifest, managedDependency) in currentManifests.dependencies where managedDependency.isInEditableState {
            let specifier = RepositorySpecifier(url: externalManifest.url)
            let dependencies = externalManifest.package.dependencies.map{
                RepositoryPackageConstraint(container: RepositorySpecifier(url: $0.url), versionRequirement: .range($0.versionRange))
            }
            updateConstraints += [RepositoryPackageConstraint(container: specifier, requirement: .unversioned(dependencies))]
        }

        // Resolve the dependencies.
        let updateResults = try resolveDependencies(constraints: updateConstraints)
        // Update the checkouts based on new dependency resolution.
        try updateCheckouts(with: updateResults)
        // If we're repinning, update the pins store.
        if repin {
            try repinPackages(with: updateResults)
        }
    }

    /// Repin the packages with dependency resolution result.
    private func repinPackages(with updateResults: [(RepositorySpecifier, BoundVersion)]) throws {
        // If autopin is on, pin everything and return.
        if pinsStore.autoPin {
            return try pinAll(reset: true)
        }
        // Otherwise we need to repin only the previous pins.
        // Create a dictionary of result for fast lookup.
        let updateResultsMap = Dictionary(items: updateResults)
        for pin in pinsStore.pins {
            guard let newBinding = updateResultsMap[pin.repository] else {
                // This is a stray pin as it is not present in updated results.
                // FIXME: Use diagnosics engine when we have that.
                delegate.warning(message: "Consider unpinning \(pin.package), it is pinned at \(pin.version) but the dependency is not present.")
                continue
            }
            // We can only pin the version bindings.
            guard case .version(let newVersion) = newBinding else { continue }
            // We don't need to repin if its version did not change.
            guard newVersion != pin.version else { continue }
            // Repin this dependency.
            try pinsStore.pin(package: pin.package, repository: pin.repository, at: newVersion, reason: pin.reason)
        }
    }

    /// Updates the current working checkouts i.e. clone or remove based on the provided dependency resolution result.
    private func updateCheckouts(with updateResults: [(RepositorySpecifier, BoundVersion)]) throws {
        // Get the update package states from resolved results.
        let packageStateChanges = computePackageStateChanges(resolvedDependencies: updateResults)
        // Update or clone new packages.
        for (specifier, state) in packageStateChanges {
            switch state {
            case .added(let version):
                _ = try clone(specifier: specifier, version: version)
            case .updated(_, let version):
                _ = try clone(specifier: specifier, version: version)
            case .removed: try remove(specifier: specifier)
            case .unchanged: break
            }
        }
    }

    /// Computes states of the packages based on last stored state.
    private func computePackageStateChanges(resolvedDependencies: [(RepositorySpecifier, BoundVersion)]) -> [RepositorySpecifier: PackageStateChange] {
        var packageStateChanges = [RepositorySpecifier: PackageStateChange]()
        // Set the states from resolved dependencies results.
        for (specifier, binding) in resolvedDependencies {
            switch binding {
            case .excluded:
                fatalError("Unexpected excluded binding")
            case .unversioned:
                // Right not it is only possible to get unversioned binding if a dependency is in editable state.
                assert(dependencyMap[specifier]?.isInEditableState ?? false)
                packageStateChanges[specifier] = .unchanged
            case .version(let version):
                if let currentDependency = dependencyMap[specifier] {
                    // FIXME: PackageStateChange needs to get richer API for updating packages 
                    // which are pinned to a revision, whenever we have that feature.
                    guard let currentVersion = currentDependency.currentVersion else {
                        continue
                    }
                    if currentVersion == version {
                        packageStateChanges[specifier] = .unchanged
                    } else {
                        packageStateChanges[specifier] = .updated(old: currentVersion, new: version)
                    }
                } else {
                    packageStateChanges[specifier] = .added(version)
                }
            }
        }
        // Set the state of any old package that might have been removed.
        for specifier in dependencies.lazy.map({$0.repository}) where packageStateChanges[specifier] == nil{
            packageStateChanges[specifier] = .removed
        }
        return packageStateChanges
    }

    /// Create package constraints based on the root manifests.
    ///
    /// - Parameters:
    ///   - rootManifests: The root manifests.
    ///   - includePins: If the constraints from pins should be included.
    /// - Returns: Array of constraints.
    private func computeRootPackagesConstraints(_ rootManifests: [Manifest], includePins: Bool) -> [RepositoryPackageConstraint] {
        return rootManifests.flatMap{ rootManifest in
            rootManifest.package.dependencies.map{
                RepositoryPackageConstraint(container: RepositorySpecifier(url: $0.url), versionRequirement: .range($0.versionRange))
            }
        } + (includePins ? pinsStore.createConstraints() : [])
    }

    /// Runs the dependency resolver based on constraints provided and returns the results.
    fileprivate func resolveDependencies(constraints: [RepositoryPackageConstraint]) throws -> [(container: WorkspaceResolverDelegate.Identifier, binding: BoundVersion)] {
        let resolverDelegate = WorkspaceResolverDelegate()
        let resolver = DependencyResolver(containerProvider, resolverDelegate, enablePrefetching: enableResolverPrefetching)
        return try resolver.resolve(constraints: constraints)
    }

    /// Load the manifests for the current dependency tree.
    ///
    /// This will load the manifests for the root package as well as all the
    /// current dependencies from the working checkouts.
    ///
    /// Throws: If the root manifest could not be loaded.
    public func loadDependencyManifests() throws -> DependencyManifests {
        // Load the root manifests.
        let rootManifests = try loadRootManifests()

        // Validate that edited dependencies are still present.
        try validateEditedPackages()

        // Compute the transitive closure of available dependencies.
        let dependencies = transitiveClosure(rootManifests.map{ KeyedPair($0, key: $0.url) }) { node in
            return node.item.package.dependencies.flatMap{ dependency in
                // Check if this dependency is available.
                guard let managedDependency = dependencyMap[RepositorySpecifier(url: dependency.url)] else {
                    return nil
                }

                // Select the right base path for the dependency.
                let packagePathBase = managedDependency.isInEditableState ? editablesPath : checkoutsPath
                // If so, load its manifest.
                //
                // This should *never* fail, because we should only have ever
                // got this checkout via loading its manifest successfully.
                //
                // FIXME: Nevertheless, we should handle this failure explicitly.
                //
                // FIXME: We should have a cache for this.
                let manifest: Manifest = try! manifestLoader.load(packagePath: packagePathBase.appending(managedDependency.subpath), baseURL: managedDependency.repository.url, version: managedDependency.currentVersion)

                return KeyedPair(manifest, key: manifest.url)
            }
        }

        return DependencyManifests(roots: rootManifests, dependencies: dependencies.map{ ($0.item, dependencyMap[RepositorySpecifier(url: $0.item.url)]!) })
    }

    /// Validates that all the edited dependencies are still present in the file system.
    /// If some edited dependency is removed from the file system, mark it as unedited and
    /// fallback on the original checkout.
    private func validateEditedPackages() throws {
        for dependency in dependencies where dependency.isInEditableState {
            // If some edited dependency has been removed, mark it as unedited.
            let dependencyPath = editablesPath.appending(dependency.subpath)
            if !fileSystem.exists(dependencyPath) {
                try unedit(dependency: dependency, forceRemove: true)
                // FIXME: Use diagnosics engine when we have that.
                delegate.warning(message: "\(dependencyPath.asString) was being edited but has been removed, falling back to original checkout.")
            }
        }
    }

    /// Fetch and load the complete package at the given path.
    ///
    /// This will implicitly cause any dependencies not yet present in the
    /// working checkouts to be resolved, cloned, and checked out.
    ///
    /// When fetching additional dependencies, the existing checkout versions
    /// will never be re-bound (or even re-fetched) as a result of this
    /// operation. This implies that the resulting local state may not match
    /// what would be computed from a fresh clone, but this makes for a more
    /// consistent command line development experience.
    ///
    /// - Returns: The loaded package graph.
    /// - Throws: Rethrows errors from dependency resolution (if required) and package graph loading.
    @discardableResult
    public func loadPackageGraph() throws -> PackageGraph {
        // First, load the active manifest sets.
        let currentManifests = try loadDependencyManifests()

        // Look for any missing URLs.
        let missingURLs = currentManifests.missingURLs()
        if missingURLs.isEmpty {
            // If not, we are done.
            return try PackageGraphLoader().load(rootManifests: currentManifests.roots, externalManifests: currentManifests.dependencies.map{$0.manifest}, fileSystem: fileSystem)
        }

        // If so, we need to resolve and fetch them. Start by informing the
        // delegate of what is happening.
        delegate.fetchingMissingRepositories(missingURLs)

        // First, add the root package constraints.
        var constraints = computeRootPackagesConstraints(currentManifests.roots, includePins: true)

        // Add constraints to pin to *exactly* all the checkouts we have.
        for (externalManifest, managedDependency) in currentManifests.dependencies {
            let specifier = RepositorySpecifier(url: externalManifest.url)

            if managedDependency.isInEditableState {
                let dependencies = externalManifest.package.dependencies.map{
                    RepositoryPackageConstraint(container: RepositorySpecifier(url: $0.url), versionRequirement: .range($0.versionRange))
                }
                constraints += [RepositoryPackageConstraint(container: specifier, requirement: .unversioned(dependencies))]
            } else if let version = managedDependency.currentVersion {
                // If this specifier is pinned, we should already have it checked out at that version.
                // We also don't need to add the constraint again.
                if let pin = pinsStore.pinsMap[externalManifest.name] {
                    assert(version == pin.version)
                    continue
                }
                // If we know the manifest is at a particular version, use that.
                // FIXME: This backfires in certain cases when the graph is resolvable but this constraint makes the resolution unsatisfiable.
                constraints.append(RepositoryPackageConstraint(container: specifier, versionRequirement: .exact(version)))
            } else {
                // FIXME: Otherwise, we need to be able to constraint precisely to the revision we have.
                fatalError("FIXME: Unimplemented.")
            }
        }

        // Perform dependency resolution using the constraint set induced by the active checkouts.
        let result = try resolveDependencies(constraints: constraints)
        let packageStateChanges = computePackageStateChanges(resolvedDependencies: result)

        // Create a checkout for each of the resolved versions.
        //
        // FIXME: We are not validating that the resulting solution includes
        // everything we already have... this can't be the case given the way we
        // currently provide constraints, but if we provided only the root and
        // then the restrictions (to the current assignment) it would be
        // possible.
        var externalManifests = currentManifests.dependencies.map{$0.manifest}
        for (specifier, state) in packageStateChanges {
            switch state {
            case .added(let version):
                let path = try clone(specifier: specifier, version: version)
                let manifest = try! manifestLoader.load(packagePath: path, baseURL: specifier.url, version: version)
                externalManifests.append(manifest)
            case .updated(_):
                // FIXME: Issue suitable diagnostics for cases where an
                // update is needed, or cases where the range is invalid.
                fatalError("unexpected dependency resolution result")
            case .removed: try remove(specifier: specifier)
            case .unchanged: break
            }
        }

        // If autopin is enabled, reset and pin everything.
        if pinsStore.autoPin {
            try pinAll(reset: true)
        }

        // We've loaded the complete set of manifests, load the graph.
        return try PackageGraphLoader().load(rootManifests: currentManifests.roots, externalManifests: externalManifests, fileSystem: fileSystem)
    }

    /// Removes the clone and checkout of the provided specifier.
    func remove(specifier: RepositorySpecifier) throws {
        guard var dependency = dependencyMap[specifier] else {
            fatalError("This should never happen, trying to remove \(specifier) which isn't in workspace")
        }

        // If this dependency is based on a dependency, switch to that because we don't want to touch the editable checkout here.
        //
        // FIXME: This will remove also the data about the editable dependency and it will not be possible to "unedit" that dependency anymore.
        // To do that we need to persist the value of isInEditableState and also store the package names in managed dependencies, because 
        // it will not be possible to lookup these dependencies using their manifests as we won't have them anymore.
        // https://bugs.swift.org/browse/SR-3689
        if let basedOn = dependency.basedOn {
            dependency = basedOn
        }

        // Inform the delegate.
        delegate.removing(repository: dependency.repository.url)

        // Remove the repository from dependencies.
        dependencyMap[dependency.repository] = nil

        // Remove the checkout.
        let dependencyPath = checkoutsPath.appending(dependency.subpath)
        let checkedOutRepo = try repositoryManager.provider.openCheckout(at: dependencyPath)
        guard !checkedOutRepo.hasUncommitedChanges() else {
            throw WorkspaceOperationError.hasUncommitedChanges(repo: dependencyPath)
        }
        fileSystem.removeFileTree(dependencyPath)

        // Remove the clone.
        try repositoryManager.remove(repository: dependency.repository)

        // Save the state.
        try saveState()
    }

    /// Loads and returns the root manifests.
    private func loadRootManifests() throws -> [Manifest] {
        // Ensure we have at least one registered root package path.
        guard rootPackages.count > 0 else {
            throw WorkspaceOperationError.noRegisteredPackages
        }
        return try rootPackages.map {
            let toolsVersion = try toolsVersionLoader.load(at: $0, fileSystem: fileSystem)
            guard currentToolsVersion >= toolsVersion else {
                throw WorkspaceOperationError.incompatibleToolsVersion(rootPackage: $0, required: toolsVersion, current: currentToolsVersion)
            }
            return try manifestLoader.load(packagePath: $0, baseURL: $0.asString, version: nil)
        }
    }
    
    // MARK: Persistence

    // FIXME: A lot of the persistence mechanism here is copied from
    // `RepositoryManager`. It would be nice to get actual infrastructure around
    // persistence to handle the boilerplate parts.

    private enum PersistenceError: Swift.Error {
        /// The schema does not match the current version.
        case invalidVersion

        /// There was a missing or malformed key.
        case unexpectedData
    }

    /// The current schema version for the persisted information.
    ///
    /// We currently discard any restored state if we detect a schema change.
    private static let currentSchemaVersion = 1

    /// The path at which we persist the manager state.
    var statePath: AbsolutePath {
        return dataPath.appending(component: "workspace-state.json")
    }

    /// Restore the manager state from disk.
    ///
    /// - Throws: A PersistenceError if the state was available, but could not
    /// be restored.
    ///
    /// - Returns: True if the state was restored, or false if the state wasn't
    /// available.
    private func restoreState() throws -> Bool {
        // If the state doesn't exist, don't try to load and fail.
        if !fileSystem.exists(statePath) {
            return false
        }

        // Load the state.
        let json = try JSON(bytes: try fileSystem.readFileContents(statePath))

        // Load the state from JSON.
        guard case let .dictionary(contents) = json,
        case let .int(version)? = contents["version"] else {
            throw PersistenceError.unexpectedData
        }
        guard version == Workspace.currentSchemaVersion else {
            throw PersistenceError.invalidVersion
        }
        guard case let .array(dependenciesData)? = contents["dependencies"] else {
            throw PersistenceError.unexpectedData
        }

        // Load the repositories.
        var dependencies = [RepositorySpecifier: ManagedDependency]()
        for dependencyData in dependenciesData {
            guard let repo = ManagedDependency(json: dependencyData) else {
                throw PersistenceError.unexpectedData
            }
            dependencies[repo.repository] = repo
        }

        self.dependencyMap = dependencies

        return true
    }

    /// Write the manager state to disk.
    private func saveState() throws {
        var data = [String: JSON]()
        data["version"] = .int(Workspace.currentSchemaVersion)
        data["dependencies"] = .array(dependencies.map{ $0.toJSON() })

        // FIXME: This should write atomically.
        try fileSystem.writeFileContents(statePath, bytes: JSON.dictionary(data).toBytes())
    }
}

extension Version {
    init?(json: JSON) {
        guard case .string(let str) = json else { return nil }
        self.init(str)
    }
}

extension Revision {
    init?(json: JSON) {
        guard case .string(let str) = json else { return nil }
        self.init(identifier: str)
    }
}
