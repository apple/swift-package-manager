/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Dispatch
import class Foundation.OperationQueue

import TSCBasic
import TSCUtility
import Basics

/// Delegate to notify clients about actions being performed by RepositoryManager.
public protocol RepositoryManagerDelegate: AnyObject {
    /// Called when a repository is about to be fetched.
    func fetchingWillBegin(handle: RepositoryManager.RepositoryHandle, fetchDetails: RepositoryManager.FetchDetails?)

    /// Called when a repository has finished fetching.
    func fetchingDidFinish(handle: RepositoryManager.RepositoryHandle, fetchDetails: RepositoryManager.FetchDetails?, error: Swift.Error?)

    /// Called when a repository has started updating from its remote.
    func handleWillUpdate(handle: RepositoryManager.RepositoryHandle)

    /// Called when a repository has finished updating from its remote.
    func handleDidUpdate(handle: RepositoryManager.RepositoryHandle)

    /// Called every time the progress of a repository fetch operation updates.
    func fetchingRepository(from repository: String, objectsFetched: Int, totalObjectsToFetch: Int)

}

public extension RepositoryManagerDelegate {
    func fetchingWillBegin(handle: RepositoryManager.RepositoryHandle) {}
    func fetchingDidFinish(handle: RepositoryManager.RepositoryHandle, error: Swift.Error?) {}
    func handleWillUpdate(handle: RepositoryManager.RepositoryHandle) {}
    func handleDidUpdate(handle: RepositoryManager.RepositoryHandle) {}
    func fetchingRepository(from repository: String, objectsFetched: Int, totalObjectsToFetch: Int) {}
}

/// Manages a collection of bare repositories.
public class RepositoryManager {

    public typealias LookupResult = Result<RepositoryHandle, Error>
    public typealias LookupCompletion = (LookupResult) -> Void

    /// Handle to a managed repository.
    public class RepositoryHandle {
        enum Status: String {
            /// The repository has not been requested.
            case uninitialized

            /// The repository is being fetched.
            case pending

            /// The repository is available.
            case available

            /// The repository is available in the cache
            case cached

            /// The repository was unable to be fetched.
            case error
        }

        /// The manager this repository is owned by.
        private unowned let manager: RepositoryManager

        /// The repository specifier.
        public let repository: RepositorySpecifier

        /// The subpath of the repository within the manager.
        ///
        /// This is intentionally hidden from the clients so that the manager is
        /// allowed to move repositories transparently.
        fileprivate let subpath: RelativePath

        /// The status of the repository.
        fileprivate var status: Status = .uninitialized

        /// Lock to protect  the operations like updating the state
        /// of the handle and fetching the repositories from its remote.
        private let statusLock = Lock()

        /// Create a handle.
        fileprivate init(manager: RepositoryManager, repository: RepositorySpecifier, subpath: RelativePath) {
            self.manager = manager
            self.repository = repository
            self.subpath = subpath
        }

        /// Create a handle from JSON data.
        fileprivate init(manager: RepositoryManager, json: JSON) throws {
            self.manager = manager
            self.repository = try json.get("repositoryURL")
            self.subpath = try RelativePath(json.get("subpath"))
            self.status = try Status(rawValue: json.get("status"))!
        }

        /// Open the given repository.
        public func open() throws -> Repository {
            precondition(status == .available, "open() called in invalid state")
            return try self.manager.open(self)
        }

        /// Create a working copy at on the local file system.
        ///
        /// - Parameters:
        ///   - path: The path at which to create the working copy; it is
        ///           expected to be non-existent when called.
        ///
        ///   - editable: The clone is expected to be edited by user.
        public func createWorkingCopy(at path: AbsolutePath, editable: Bool) throws -> WorkingCheckout {
            precondition(status == .available, "createWorkingCopy() called in invalid state")
            return try self.manager.createWorkingCopy(self, at: path, editable: editable)
        }

        fileprivate func toJSON() -> JSON {
            return .init([
                "status": status.rawValue,
                "repositoryURL": repository,
                "subpath": subpath,
            ])
        }

        func withStatusLock(_ body: () throws -> Void) rethrows {
            try self.statusLock.withLock(body)
        }
    }

    /// Additional information about a fetch
    public struct FetchDetails: Equatable {
        /// Indicates if the repository was fetched from the cache or from the remote.
        public let fromCache: Bool
        /// Indicates wether the wether the repository was already present in the cache and updated or if a clean fetch was performed.
        public let updatedCache: Bool
    }

    /// The path under which repositories are stored.
    public let path: AbsolutePath

    /// The path to the directory where all cached git repositories are stored.
    private let cachePath: AbsolutePath?

    // used in tests to disable skipping of local packages.
    var cacheLocalPackages = false

    /// The repository provider.
    public let provider: RepositoryProvider

    /// The delegate interface.
    private let delegate: RepositoryManagerDelegate?

    // FIXME: We should use a more sophisticated map here, which tracks the
    // full specifier but then is capable of efficiently determining if two
    // repositories map to the same location.
    //
    /// The map of registered repositories.
    private var repositories: [String: RepositoryHandle] = [:]

    /// The map of serialized repositories.
    ///
    /// NOTE: This is to be used only for persistence support.
    private var serializedRepositories: [String: JSON] = [:]

    /// Lock to protect concurrent reads and mutations to repositories registry.
    private let lock = Lock()

    /// Operation queue to do concurrent operations on manager.
    ///
    /// We use operation queue (and not dispatch queue) to limit the amount of
    /// concurrent operations.
    private let operationQueue: OperationQueue

    /// The filesystem to operate on.
    public let fileSystem: FileSystem

    /// Simple persistence helper.
    private let persistence: SimplePersistence

    /// Create a new empty manager.
    ///
    /// - Parameters:
    ///   - path: The path under which to store repositories. This should be a
    ///           directory in which the content can be completely managed by this
    ///           instance.
    ///   - provider: The repository provider.
    ///   - delegate: The repository manager delegate.
    ///   - fileSystem: The filesystem to operate on.
    public init(
        path: AbsolutePath,
        provider: RepositoryProvider,
        delegate: RepositoryManagerDelegate? = nil,
        fileSystem: FileSystem = localFileSystem,
        cachePath: AbsolutePath? = nil
    ) {
        self.path = path
        self.provider = provider
        self.delegate = delegate
        self.fileSystem = fileSystem
        self.cachePath = cachePath

        self.operationQueue = OperationQueue()
        self.operationQueue.name = "org.swift.swiftpm.repomanagerqueue-concurrent"
        self.operationQueue.maxConcurrentOperationCount = Concurrency.maxOperations

        self.persistence = SimplePersistence(
            fileSystem: fileSystem,
            schemaVersion: 1,
            statePath: path.appending(component: "checkouts-state.json"))

        // Load the state from disk, if possible.
        do {
            _ = try self.persistence.restoreState(self)
        } catch {
            // State restoration errors are ignored, for now.
            //
            // FIXME: We need to do something better here.
            print("warning: unable to restore checkouts state: \(error)")

            // Try to save the empty state.
            try? self.persistence.saveState(self)
        }
    }

    /// Get a handle to a repository.
    ///
    /// This will initiate a clone of the repository automatically, if necessary.
    ///
    /// Note: Recursive lookups are not supported i.e. calling lookup inside
    /// completion block of another lookup will block.
    ///
    /// - Parameters:
    ///   - repository: The repository to look up.
    ///   - skipUpdate: If a repository is availble, skip updating it.
    ///   - completion: The completion block that should be called after lookup finishes.
    public func lookup(
        repository: RepositorySpecifier,
        skipUpdate: Bool = false,
        on queue: DispatchQueue,
        completion: @escaping LookupCompletion
    ) {
        operationQueue.addOperation {
            // First look for the handle.
            let handle = self.getHandle(repository: repository)
            // Dispatch the action we want to take on the serial queue of the handle.
            handle.withStatusLock {
                let result: LookupResult

                switch handle.status {
                case .available:
                    result = LookupResult(catching: {
                        // Update the repository when it is being looked up.
                        let repo = try handle.open()

                        // Skip update if asked to.
                        if skipUpdate {
                            return handle
                        }

                        queue.async {
                            self.delegate?.handleWillUpdate(handle: handle)
                        }

                        try repo.fetch()

                        queue.async {
                            self.delegate?.handleDidUpdate(handle: handle)
                        }

                        return handle
                    })
                case .pending, .uninitialized, .cached, .error:
                    let isCached = handle.status == .cached
                    let repositoryPath = self.path.appending(handle.subpath)
                    // Change the state to pending.
                    handle.status = .pending
                    // Make sure destination is free.
                    try? self.fileSystem.removeFileTree(repositoryPath)

                    // Inform delegate.
                    queue.async {
                        let details = FetchDetails(fromCache: isCached, updatedCache: false)
                        self.delegate?.fetchingWillBegin(handle: handle, fetchDetails: details)
                    }

                    // Fetch the repo.
                    var fetchError: Swift.Error? = nil
                    var fetchDetails: FetchDetails? = nil
                    do {
                        // Start fetching.
                        fetchDetails = try self.fetchAndPopulateCache(handle: handle,
                                                                      repositoryPath: repositoryPath,
                                                                      on: queue)

                        // Update status to available.
                        handle.status = .available
                        result = .success(handle)
                    } catch {
                        handle.status = .error
                        fetchError = error
                        result = .failure(error)
                    }

                    // Inform delegate.
                    queue.async {
                        self.delegate?.fetchingDidFinish(handle: handle, fetchDetails: fetchDetails, error: fetchError)
                    }

                    // Save the manager state.
                    self.lock.withLock {
                        do {
                            // Update the serialized repositories map.
                            //
                            // We do this so we don't have to read the other
                            // handles when saving the sate of this handle.
                            self.serializedRepositories[repository.url] = handle.toJSON()
                            try self.persistence.saveState(self)
                        } catch {
                            // FIXME: Handle failure gracefully, somehow.
                            fatalError("unable to save manager state \(error)")
                        }
                    }
                }
                // Call the completion handler.
                queue.async {
                    completion(result)
                }
            }
        }
    }

    /// Fetches the repository into the cache. If no `cachePath` is set or an error ouccured fall back to fetching the repository without populating the cache.
    /// - Parameters:
    ///   - handle: The specifier of the repository to fetch.
    ///   - repositoryPath: The path where the repository should be fetched to.
    ///   - update: Update a repository that is already cached or alternatively fetch the repository into the cache.
    /// - Throws:
    /// - Returns: Details about the performed fetch.
   @discardableResult
    func fetchAndPopulateCache(
        handle: RepositoryHandle,
        repositoryPath: AbsolutePath,
        on queue: DispatchQueue
    ) throws -> FetchDetails {
        var updatedCache = false
        var fromCache = false

        func updateFetchProgress(progress: FetchProgress) -> Void {
            queue.async {
                if let total = progress.totalSteps {
                    self.delegate?.fetchingRepository(from: handle.repository.url,
                                                      objectsFetched: progress.step,
                                                      totalObjectsToFetch: total)
                }
            }
        }

        // We are expecting handle.repository.url to always be a resolved absolute path.
        let isLocal = (try? AbsolutePath(validating: handle.repository.url)) != nil
        let shouldCacheLocalPackages = ProcessEnv.vars["SWIFTPM_TESTS_PACKAGECACHE"] == "1" || cacheLocalPackages

        if let cachePath = self.cachePath, !(isLocal && !shouldCacheLocalPackages) {
            let cachedRepositoryPath = cachePath.appending(component: handle.repository.fileSystemIdentifier)
            do {
                try self.initializeCacheIfNeeded(cachePath: cachePath)
                try fileSystem.withLock(on: cachePath, type: .shared) {
                    try fileSystem.withLock(on: cachedRepositoryPath, type: .exclusive) {
                        // Fetch the repository into the cache.
                        if (fileSystem.exists(cachedRepositoryPath)) {
                            let repo = try self.provider.open(repository: handle.repository, at: cachedRepositoryPath)
                            try repo.fetch(progress: updateFetchProgress(progress:))
                        } else {
                            try self.provider.fetch(repository: handle.repository, to: cachedRepositoryPath, progress: updateFetchProgress(progress:))
                        }
                        updatedCache = true
                        // Copy the repository from the cache into the repository path.
                        try self.provider.copy(from: cachedRepositoryPath, to: repositoryPath)
                        fromCache = true
                    }
                }
            } catch {
                // Fetch without populating the cache in the case of an error.
                print("Skipping cache due to an error: \(error)")
                // It is possible that we already created the directory before failing, so clear leftover data if present.
                try fileSystem.removeFileTree(repositoryPath)
                try self.provider.fetch(repository: handle.repository, to: repositoryPath, progress: updateFetchProgress(progress:))
                fromCache = false
            }
        } else {
            // Fetch without populating the cache when no `cachePath` is set.
            try self.provider.fetch(repository: handle.repository, to: repositoryPath, progress: updateFetchProgress(progress:))
            fromCache = false
        }
        return FetchDetails(fromCache: fromCache, updatedCache: updatedCache)
    }

    /// Returns the handle for repository if available, otherwise creates a new one.
    ///
    /// Note: This method is thread safe.
    private func getHandle(repository: RepositorySpecifier) -> RepositoryHandle {
        self.lock.withLock {
            // Reset if the state file was deleted during the lifetime of RepositoryManager.
            if !self.serializedRepositories.isEmpty && !self.persistence.stateFileExists() {
                self.unsafeReset()
            }

            let subpath = RelativePath(repository.fileSystemIdentifier)
            let handle: RepositoryHandle

            if let oldHandle = self.repositories[repository.url] {
                handle = oldHandle
            } else if let cachePath = self.cachePath, self.fileSystem.exists(cachePath.appending(subpath)) {
                handle = RepositoryHandle(manager: self, repository: repository, subpath: subpath)
                handle.status = .cached
                self.repositories[repository.url] = handle
            } else {
                handle = RepositoryHandle(manager: self, repository: repository, subpath: subpath)
                self.repositories[repository.url] = handle
            }

            return handle
        }
    }

    /// Open a repository from a handle.
    private func open(_ handle: RepositoryHandle) throws -> Repository {
        try self.provider.open(
            repository: handle.repository, at: self.path.appending(handle.subpath))
    }

    /// Create a working copy of the repository from a handle.
    private func createWorkingCopy(
        _ handle: RepositoryHandle,
        at destinationPath: AbsolutePath,
        editable: Bool
    ) throws -> WorkingCheckout {
        try self.provider.createWorkingCopy(
            repository: handle.repository,
            sourcePath: self.path.appending(handle.subpath),
            at: destinationPath,
            editable: editable)
    }

    /// Removes the repository.
    public func remove(repository: RepositorySpecifier) throws {
        try self.lock.withLock {
            // If repository isn't present, we're done.
            guard let handle = self.repositories[repository.url] else {
                return
            }
            self.repositories[repository.url] = nil
            self.serializedRepositories[repository.url] = nil
            let repositoryPath = self.path.appending(handle.subpath)
            try self.fileSystem.removeFileTree(repositoryPath)
            try self.persistence.saveState(self)
        }
    }

    /// Reset the repository manager.
    ///
    /// Note: This also removes the cloned repositories from the disk.
    public func reset() {
        self.lock.withLock {
            self.unsafeReset()
        }
    }

    /// Performs the reset operation without the serial queue.
    private func unsafeReset() {
        self.repositories = [:]
        self.serializedRepositories = [:]
        try? self.fileSystem.removeFileTree(path)
    }

    /// Sets up the cache directories if they don't already exist.
    public func initializeCacheIfNeeded(cachePath: AbsolutePath) throws {
        // Create the supplied cache directory.
        if !self.fileSystem.exists(cachePath) {
            try self.fileSystem.createDirectory(cachePath, recursive: true)
        }
    }

    /// Purges the cached repositories from the cache.
    public func purgeCache() throws {
        guard let cachePath = self.cachePath else { return }
        try self.fileSystem.withLock(on: cachePath, type: .exclusive) {
            let cachedRepositories = try self.fileSystem.getDirectoryContents(cachePath)
            for repoPath in cachedRepositories {
                try self.fileSystem.removeFileTree(cachePath.appending(component: repoPath))
            }
        }
    }
}

// MARK: Persistence
extension RepositoryManager: SimplePersistanceProtocol {

    public func restore(from json: JSON) throws {
        // Update the serialized repositories.
        //
        // We will use this to save the state so we don't have to read the other
        // handles when saving the sate of a handle.
        self.serializedRepositories = try json.get("repositories")
        self.repositories = try serializedRepositories.mapValues({
            try RepositoryHandle(manager: self, json: $0)
        })
    }

    public func toJSON() -> JSON {
        return JSON(["repositories": JSON(self.serializedRepositories)])
    }
}

extension RepositoryManager.RepositoryHandle: CustomStringConvertible {
    public var description: String {
        return "<\(type(of: self)) subpath:\(subpath)>"
    }
}
