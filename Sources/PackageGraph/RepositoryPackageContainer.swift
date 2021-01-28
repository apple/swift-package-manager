/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Dispatch
import Basics
import TSCBasic
import PackageLoading
import PackageModel
import SourceControl
import TSCUtility

enum RepositoryPackageResolutionError: Swift.Error {
    /// A requested repository could not be cloned.
    case unavailableRepository
}

/// Adaptor to expose an individual repository as a package container.
public class RepositoryPackageContainer: PackageContainer, CustomStringConvertible {
    public typealias Constraint = PackageContainerConstraint

    // A wrapper for getDependencies() errors. This adds additional information
    // about the container to identify it for diagnostics.
    public struct GetDependenciesError: Error, CustomStringConvertible, DiagnosticLocationProviding {

        /// The container (repository) that encountered the error.
        public let containerIdentifier: String

        /// The source control reference (version, branch, revision, etc) that was involved.
        public let reference: String

        /// The actual error that occurred.
        public let underlyingError: Error
        
        /// Optional suggestion for how to resolve the error.
        public let suggestion: String?
        
        public var diagnosticLocation: DiagnosticLocation? {
            return PackageLocation.Remote(url: containerIdentifier, reference: reference)
        }
        
        /// Description shown for errors of this kind.
        public var description: String {
            var desc = "\(underlyingError) in \(containerIdentifier)"
            if let suggestion = suggestion {
                desc += " (\(suggestion))"
            }
            return desc
        }
    }

    public let identifier: PackageReference
    private let repository: Repository
    private let mirrors: DependencyMirrors
    private let manifestLoader: ManifestLoaderProtocol
    private let toolsVersionLoader: ToolsVersionLoaderProtocol
    private let currentToolsVersion: ToolsVersion
    private let verbosity: Verbosity

    /// The cached dependency information.
    private var dependenciesCache = [String: [ProductFilter: (Manifest, [Constraint])]] ()
    private var dependenciesCacheLock = Lock()

    private var knownVersionsCache = ThreadSafeBox<[Version: String]>()
    private var manifestsCache = ThreadSafeKeyValueStore<Revision, Manifest>()
    private var toolsVersionsCache = ThreadSafeKeyValueStore<Version, ToolsVersion>()

    /// This is used to remember if tools version of a particular version is
    /// valid or not.
    internal var validToolsVersionsCache = ThreadSafeKeyValueStore<Version, Bool>()

    init(
        identifier: PackageReference,
        mirrors: DependencyMirrors,
        repository: Repository,
        manifestLoader: ManifestLoaderProtocol,
        toolsVersionLoader: ToolsVersionLoaderProtocol,
        currentToolsVersion: ToolsVersion,
        verbosity: Verbosity
    ) {
        self.identifier = identifier
        self.mirrors = mirrors
        self.repository = repository
        self.manifestLoader = manifestLoader
        self.toolsVersionLoader = toolsVersionLoader
        self.currentToolsVersion = currentToolsVersion
        self.verbosity = verbosity
    }
    
    // Compute the map of known versions.
    private func knownVersions() throws -> [Version: String] {
        try self.knownVersionsCache.memoize() {
            let knownVersionsWithDuplicates = Git.convertTagsToVersionMap(try repository.getTags())

            return knownVersionsWithDuplicates.mapValues({ tags -> String in
                if tags.count == 2 {
                    // FIXME: Warn if the two tags point to different git references.
                    return tags.first(where: { !$0.hasPrefix("v") })!
                }
                assert(tags.count == 1, "Unexpected number of tags")
                return tags[0]
            })
        }
    }

    public func versionsAscending() throws -> [Version] {
        [Version](try self.knownVersions().keys).sorted()
    }
    
    /// The available version list (in reverse order).
    public func toolsVersionsAppropriateVersionsDescending() throws -> [Version] {
        let reversedVersions = try self.versionsDescending()
        return reversedVersions.lazy.filter({
            // If we have the result cached, return that.
            if let result = self.validToolsVersionsCache[$0] {
                return result
            }

            // Otherwise, compute and cache the result.
            let isValid = (try? self.toolsVersion(for: $0)).flatMap(self.isValidToolsVersion(_:)) ?? false
            self.validToolsVersionsCache[$0] = isValid
            return isValid
        })
    }

    public func getTag(for version: Version) -> String? {
        return try? self.knownVersions()[version]
    }

    /// Returns revision for the given tag.
    public func getRevision(forTag tag: String) throws -> Revision {
        return try repository.resolveRevision(tag: tag)
    }

    /// Returns revision for the given identifier.
    public func getRevision(forIdentifier identifier: String) throws -> Revision {
        return try repository.resolveRevision(identifier: identifier)
    }

    /// Returns the tools version of the given version of the package.
    public func toolsVersion(for version: Version) throws -> ToolsVersion {
        try self.toolsVersionsCache.memoize(version) {
            guard let tag = try self.knownVersions()[version] else {
                throw StringError("unknown tag \(version)")
            }
            let revision = try repository.resolveRevision(tag: tag)
            let fs = try repository.openFileView(revision: revision)
            return try toolsVersionLoader.load(at: .root, fileSystem: fs)
        }
    }

    public func getDependencies(at version: Version, productFilter: ProductFilter) throws -> [Constraint] {
        do {
            return try self.getCachedDependencies(forIdentifier: version.description, productFilter: productFilter) {
                guard let tag = try self.knownVersions()[version] else {
                    throw StringError("unknown tag \(version)")
                }
                let revision = try repository.resolveRevision(tag: tag)
                return try self.loadDependencies(at: revision, version: version, productFilter: productFilter)
            }.1
        } catch {
            throw GetDependenciesError(
                containerIdentifier: identifier.repository.url, reference: version.description, underlyingError: error, suggestion: nil)
        }
    }

    public func getDependencies(at revision: String, productFilter: ProductFilter) throws -> [Constraint] {
        do {
            return try self.getCachedDependencies(forIdentifier: revision, productFilter: productFilter) {
                // resolve the revision identifier and return its dependencies.
                let revision = try repository.resolveRevision(identifier: revision)
                return try self.loadDependencies(at: revision, productFilter: productFilter)
            }.1
        } catch {
            // Examine the error to see if we can come up with a more informative and actionable error message.  We know that the revision is expected to be a branch name or a hash (tags are handled through a different code path).
            if let error = error as? GitRepositoryError, error.description.contains("Needed a single revision") {
                // It was a Git process invocation error.  Take a look at the repository to see if we can come up with a reasonable diagnostic.
                if let rev = try? repository.resolveRevision(identifier: revision), repository.exists(revision: rev) {
                    // Revision does exist, so something else must be wrong.
                    throw GetDependenciesError(
                        containerIdentifier: identifier.repository.url, reference: revision, underlyingError: error, suggestion: nil)
                }
                else {
                    // Revision does not exist, so we customize the error.
                    let sha1RegEx = try! RegEx(pattern: #"\A[:xdigit:]{40}\Z"#)
                    let isBranchRev = sha1RegEx.matchGroups(in: revision).compactMap{ $0 }.isEmpty
                    let errorMessage = "could not find " + (isBranchRev ? "a branch named ‘\(revision)’" : "the commit \(revision)")
                    let mainBranchExists = (try? repository.resolveRevision(identifier: "main")) != nil
                    let suggestion = (revision == "master" && mainBranchExists) ? "did you mean ‘main’?" : nil
                    throw GetDependenciesError(
                        containerIdentifier: identifier.repository.url, reference: revision,
                        underlyingError: StringError(errorMessage), suggestion: suggestion)
                }
            }
            // If we get this far without having thrown an error, we wrap and throw the underlying error.
            throw GetDependenciesError(containerIdentifier: identifier.repository.url, reference: revision, underlyingError: error, suggestion: nil)
        }
    }

    private func getCachedDependencies(
        forIdentifier identifier: String,
        productFilter: ProductFilter,
        getDependencies: () throws -> (Manifest, [Constraint])
    ) throws -> (Manifest, [Constraint]) {
        if let result = (self.dependenciesCacheLock.withLock { self.dependenciesCache[identifier, default: [:]][productFilter] }) {
            return result
        }
        let result = try getDependencies()
        self.dependenciesCacheLock.withLock {
            self.dependenciesCache[identifier, default: [:]][productFilter] = result
        }
        return result
    }

    /// Returns dependencies of a container at the given revision.
    private func loadDependencies(
        at revision: Revision,
        version: Version? = nil,
        productFilter: ProductFilter
    ) throws -> (Manifest, [Constraint]) {
        let manifest = try self.loadManifest(at: revision, version: version)
        return (manifest, manifest.dependencyConstraints(productFilter: productFilter, mirrors: mirrors))
    }

    public func getUnversionedDependencies(productFilter: ProductFilter) throws -> [Constraint] {
        // We just return an empty array if requested for unversioned dependencies.
        return []
    }

    public func getUpdatedIdentifier(at boundVersion: BoundVersion) throws -> PackageReference {
        let revision: Revision
        var version: Version?
        switch boundVersion {
        case .version(let v):
            guard let tag = try self.knownVersions()[v] else {
                throw StringError("unknown tag \(v)")
            }
            version = v
            revision = try repository.resolveRevision(tag: tag)
        case .revision(let identifier, _):
            revision = try repository.resolveRevision(identifier: identifier)
        case .unversioned, .excluded:
            assertionFailure("Unexpected type requirement \(boundVersion)")
            return self.identifier
        }

        let manifest = try self.loadManifest(at: revision, version: version)
        return self.identifier.with(newName: manifest.name)
    }

    /// Returns true if the tools version is valid and can be used by this
    /// version of the package manager.
    private func isValidToolsVersion(_ toolsVersion: ToolsVersion) -> Bool {
        do {
            try toolsVersion.validateToolsVersion(currentToolsVersion, packagePath: "")
            return true
        } catch {
            return false
        }
    }

    public func isToolsVersionCompatible(at version: Version) -> Bool {
        return (try? self.toolsVersion(for: version)).flatMap(self.isValidToolsVersion(_:)) ?? false
    }
   
    private func loadManifest(at revision: Revision, version: Version?) throws -> Manifest {
        try self.manifestsCache.memoize(revision) {
            let fs = try repository.openFileView(revision: revision)
            let packageURL = identifier.repository.url

            // Load the tools version.
            let toolsVersion = try toolsVersionLoader.load(at: .root, fileSystem: fs)

            // Validate the tools version.
            try toolsVersion.validateToolsVersion(
                self.currentToolsVersion, version: revision.identifier, packagePath: packageURL)

            // Load the manifest.
            // FIXME: this should not block
            return try temp_await {
                manifestLoader.load(package: AbsolutePath.root,
                                    baseURL: packageURL,
                                    version: version,
                                    toolsVersion: toolsVersion,
                                    packageKind: identifier.kind,
                                    fileSystem: fs,
                                    verbosity: self.verbosity,
                                    on: .global(),
                                    completion: $0)
            }
        }
    }

    public var isRemoteContainer: Bool? {
        return true
    }

    public var description: String {
        return "RepositoryPackageContainer(\(identifier.repository.url.debugDescription))"
    }
}

/// Adaptor for exposing repositories as PackageContainerProvider instances.
///
/// This is the root class for bridging the manifest & SCM systems into the
/// interfaces used by the `DependencyResolver` algorithm.
public class RepositoryPackageContainerProvider: PackageContainerProvider {
    let repositoryManager: RepositoryManager
    let manifestLoader: ManifestLoaderProtocol
    let mirrors: DependencyMirrors

    /// The tools version currently in use. Only the container versions less than and equal to this will be provided by
    /// the container.
    let currentToolsVersion: ToolsVersion

    /// The tools version loader.
    let toolsVersionLoader: ToolsVersionLoaderProtocol

    private let verbosity: Verbosity

    /// Create a repository-based package provider.
    ///
    /// - Parameters:
    ///   - repositoryManager: The repository manager responsible for providing repositories.
    ///   - manifestLoader: The manifest loader instance.
    ///   - currentToolsVersion: The current tools version in use.
    ///   - toolsVersionLoader: The tools version loader.
    public init(
        repositoryManager: RepositoryManager,
        mirrors: DependencyMirrors = [:],
        manifestLoader: ManifestLoaderProtocol,
        currentToolsVersion: ToolsVersion = ToolsVersion.currentToolsVersion,
        toolsVersionLoader: ToolsVersionLoaderProtocol = ToolsVersionLoader(),
        verbosity: Verbosity
    ) {
        self.repositoryManager = repositoryManager
        self.mirrors = mirrors
        self.manifestLoader = manifestLoader
        self.currentToolsVersion = currentToolsVersion
        self.toolsVersionLoader = toolsVersionLoader
        self.verbosity = verbosity
    }

    public func getContainer(
        for identifier: PackageReference,
        skipUpdate: Bool,
        on queue: DispatchQueue,
        completion: @escaping (Result<PackageContainer, Swift.Error>) -> Void
    ) {
        // If the container is local, just create and return a local package container.
        if identifier.kind != .remote {
            return queue.async {
                let container = LocalPackageContainer(identifier,
                    mirrors: self.mirrors,
                    manifestLoader: self.manifestLoader,
                    toolsVersionLoader: self.toolsVersionLoader,
                    currentToolsVersion: self.currentToolsVersion,
                    fs: self.repositoryManager.fileSystem,
                    verbosity: self.verbosity)
                completion(.success(container))
            }
        }

        // Resolve the container using the repository manager.
        repositoryManager.lookup(repository: identifier.repository, skipUpdate: skipUpdate, on: queue) { result in
            queue.async {
                // Create the container wrapper.
                let result = result.tryMap { handle -> PackageContainer in
                    // Open the repository.
                    //
                    // FIXME: Do we care about holding this open for the lifetime of the container.
                    let repository = try handle.open()
                    return RepositoryPackageContainer(
                        identifier: identifier,
                        mirrors: self.mirrors,
                        repository: repository,
                        manifestLoader: self.manifestLoader,
                        toolsVersionLoader: self.toolsVersionLoader,
                        currentToolsVersion: self.currentToolsVersion,
                        verbosity: self.verbosity
                    )
                }
                completion(result)
            }
        }
    }
}
