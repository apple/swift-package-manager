/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basic
import PackageLoading
import SourceControl
import Utility
import PackageModel

/// Adaptor for exposing repositories as PackageContainerProvider instances.
///
/// This is the root class for bridging the manifest & SCM systems into the
/// interfaces used by the `DependencyResolver` algorithm.
public class RepositoryPackageContainerProvider: PackageContainerProvider {
    public typealias Container = RepositoryPackageContainer

    let repositoryManager: RepositoryManager
    let manifestLoader: ManifestLoaderProtocol

    /// The tools version currently in use. Only the container versions less than and equal to this will be provided by the container.
    let currentToolsVersion: ToolsVersion

    /// The tools version loader.
    let toolsVersionLoader: ToolsVersionLoaderProtocol
    
    /// Create a repository-based package provider.
    ///
    /// - Parameters:
    ///   - repositoryManager: The repository manager responsible for providing repositories.
    ///   - manifestLoader: The manifest loader instance.
    ///   - currentToolsVersion: The current tools version in use.
    ///   - toolsVersionLoader: The tools version loader.
    public init(
        repositoryManager: RepositoryManager,
        manifestLoader: ManifestLoaderProtocol,
        currentToolsVersion: ToolsVersion = ToolsVersion.currentToolsVersion,
        toolsVersionLoader: ToolsVersionLoaderProtocol = ToolsVersionLoader()
    ) {
        self.repositoryManager = repositoryManager
        self.manifestLoader = manifestLoader
        self.currentToolsVersion = currentToolsVersion
        self.toolsVersionLoader = toolsVersionLoader
    }

    public func getContainer(for identifier: Container.Identifier, completion: @escaping (Result<Container, AnyError>) -> Void) {
        // Resolve the container using the repository manager.
        repositoryManager.lookup(repository: identifier) { result in
            // Create the container wrapper.
            let container = result.mapAny { handle -> Container in
                // Open the repository.
                //
                // FIXME: Do we care about holding this open for the lifetime of the container.
                let repository = try handle.open()
                return RepositoryPackageContainer(
                    identifier: identifier,
                    repository: repository,
                    manifestLoader: self.manifestLoader,
                    toolsVersionLoader: self.toolsVersionLoader,
                    currentToolsVersion: self.currentToolsVersion
                )
            }
            completion(container)
        }
    }
}

enum RepositoryPackageResolutionError: Swift.Error {
    /// A requested repository could not be cloned.
    case unavailableRepository
}

/// Abstract repository identifier.
extension RepositorySpecifier: PackageContainerIdentifier {}

public typealias RepositoryPackageConstraint = PackageContainerConstraint<RepositorySpecifier>

/// Adaptor to expose an individual repository as a package container.
public class RepositoryPackageContainer: PackageContainer, CustomStringConvertible {
    public typealias Identifier = RepositorySpecifier

    /// The identifier of the repository.
    public let identifier: RepositorySpecifier

    /// The available version list (in reverse order).
    public var versions: AnySequence<Version> {
        return AnySequence { () -> AnyIterator<Version> in
            var it = self.reversedVersions.makeIterator()
            return AnyIterator{ () -> Version? in
                while let version = it.next() {
                    guard let toolsVersion = try? self.toolsVersion(for: version), self.currentToolsVersion >= toolsVersion else { 
                        continue 
                    }
                    return version
                }
                return nil
            }
        }
    }
    /// The opened repository.
    let repository: Repository

    /// The manifest loader.
    let manifestLoader: ManifestLoaderProtocol

    /// The tools version loader.
    let toolsVersionLoader: ToolsVersionLoaderProtocol 

    let currentToolsVersion: ToolsVersion

    /// The versions in the repository and their corresponding tags.
    let knownVersions: [Version: String]
    
    /// The versions in the repository sorted by latest first.
    let reversedVersions: [Version]

    /// The cached dependency information.
    private var dependenciesCache: [Version: [RepositoryPackageConstraint]] = [:]
    private var dependenciesCacheLock = Lock()
    
    init(identifier: RepositorySpecifier, repository: Repository, manifestLoader: ManifestLoaderProtocol, toolsVersionLoader: ToolsVersionLoaderProtocol, currentToolsVersion: ToolsVersion) {
        self.identifier = identifier
        self.repository = repository
        self.manifestLoader = manifestLoader
        self.toolsVersionLoader = toolsVersionLoader
        self.currentToolsVersion = currentToolsVersion

        // Compute the map of known versions.
        //
        // FIXME: Move this utility to a more stable location.
        self.knownVersions = Git.convertTagsToVersionMap(repository.tags)
        self.reversedVersions = [Version](self.knownVersions.keys).sorted().reversed()
    }

    public var description: String {
        return "RepositoryPackageContainer(\(identifier.url.debugDescription))"
    }

    public func getTag(for version: Version) -> String? {
        return knownVersions[version]
    }

    public func getRevision(for tag: String) throws -> Revision {
        return try repository.resolveRevision(tag: tag)
    }

    func toolsVersion(for version: Version) throws -> ToolsVersion {
        let tag = knownVersions[version]!
        let revision = try repository.resolveRevision(tag: tag)
        let fs = try repository.openFileView(revision: revision)
        return try toolsVersionLoader.load(at: AbsolutePath.root, fileSystem: fs)
    }

    public func getDependencies(at version: Version) throws -> [RepositoryPackageConstraint] {
        // FIXME: Get a caching helper for this.
        return try dependenciesCacheLock.withLock{
            if let result = dependenciesCache[version] {
                return result
            }

            // FIXME: We should have a persistent cache for these.
            let tag = knownVersions[version]!
            let revision = try repository.resolveRevision(tag: tag)
            let fs = try repository.openFileView(revision: revision)
            let manifest = try manifestLoader.load(packagePath: AbsolutePath.root, baseURL: identifier.url, version: version, fileSystem: fs)
            let result = manifest.package.dependencies.map{
                RepositoryPackageConstraint(container: RepositorySpecifier(url: $0.url), versionRequirement: .range($0.versionRange))
            }
            dependenciesCache[version] = result

            return result
        }
    }
}
