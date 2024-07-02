//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Dispatch
import PackageGraph
import PackageLoading
import PackageModel
import PackageRegistry

import struct TSCUtility.Version

public class RegistryPackageContainer: PackageContainer {
    public let package: PackageReference

    private let registryClient: RegistryClient
    private let identityResolver: IdentityResolver
    private let dependencyMapper: DependencyMapper
    private let manifestLoader: ManifestLoaderProtocol
    private let currentToolsVersion: ToolsVersion
    private let observabilityScope: ObservabilityScope

    private var knownVersionsCache = ThreadSafeBox<[Version]>()
    private var toolsVersionsCache = ThreadSafeKeyValueStore<Version, ToolsVersion>()
    private var validToolsVersionsCache = ThreadSafeKeyValueStore<Version, Bool>()
    private var manifestsCache = ThreadSafeKeyValueStore<Version, Manifest>()
    private var availableManifestsCache = ThreadSafeKeyValueStore<Version, (manifests: [String: (toolsVersion: ToolsVersion, content: String?)], fileSystem: FileSystem)>()

    public init(
        package: PackageReference,
        identityResolver: IdentityResolver,
        dependencyMapper: DependencyMapper,
        registryClient: RegistryClient,
        manifestLoader: ManifestLoaderProtocol,
        currentToolsVersion: ToolsVersion,
        observabilityScope: ObservabilityScope
    ) {
        self.package = package
        self.identityResolver = identityResolver
        self.dependencyMapper = dependencyMapper
        self.registryClient = registryClient
        self.manifestLoader = manifestLoader
        self.currentToolsVersion = currentToolsVersion
        self.observabilityScope = observabilityScope.makeChildScope(
            description: "RegistryPackageContainer",
            metadata: package.diagnosticsMetadata)
    }

    // MARK: - PackageContainer

    public func isToolsVersionCompatible(at version: Version) -> Bool {
        self.validToolsVersionsCache.memoize(version) {
            do {
                let toolsVersion = try self.toolsVersion(for: version)
                try toolsVersion.validateToolsVersion(currentToolsVersion, packageIdentity: package.identity)
                return true
            } catch {
                return false
            }
        }
    }

    public func toolsVersion(for version: Version) throws -> ToolsVersion {
        try self.toolsVersionsCache.memoize(version) {
            let result = try temp_await {
                self.getAvailableManifestsFilesystem(version: version, completion: $0)
            }
            // find the manifest path and parse it's tools-version
            let manifestPath = try ManifestLoader.findManifest(packagePath: .root, fileSystem: result.fileSystem, currentToolsVersion: self.currentToolsVersion)
            return try ToolsVersionParser.parse(manifestPath: manifestPath, fileSystem: result.fileSystem)
        }
    }

    public func versionsDescending() throws -> [Version] {
        try self.knownVersionsCache.memoize {
            let metadata = try temp_await {
                self.registryClient.getPackageMetadata(
                    package: self.package.identity,
                    observabilityScope: self.observabilityScope,
                    callbackQueue: .sharedConcurrent,
                    completion: $0
                )
            }
            return metadata.versions.sorted(by: >)
        }
    }

    public func versionsAscending() throws -> [Version] {
        try self.versionsDescending().reversed()
    }

    public func toolsVersionsAppropriateVersionsDescending() throws -> [Version] {
        try self.versionsDescending().filter(self.isToolsVersionCompatible(at:))
    }

    public func getDependencies(at version: Version, productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        let manifest = try self.loadManifest(version: version)
        return try manifest.dependencyConstraints(productFilter: productFilter)
    }

    public func getDependencies(at revision: String, productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        throw InternalError("getDependencies for revision not supported by RegistryPackageContainer")
    }

    public func getUnversionedDependencies(productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        throw InternalError("getUnversionedDependencies not supported by RegistryPackageContainer")
    }

    public func loadPackageReference(at boundVersion: BoundVersion) throws -> PackageReference {
        return self.package
    }

    // marked internal for testing
    internal func loadManifest(version: Version) throws -> Manifest {
        return try self.manifestsCache.memoize(version) {
            try temp_await {
                self.loadManifest(version: version, completion: $0)
            }
        }
    }
    
    private func loadManifest(version: Version,  completion: @escaping (Result<Manifest, Error>) -> Void) {
        self.getAvailableManifestsFilesystem(version: version) { result in
            switch result {
            case .failure(let error):
                return completion(.failure(error))
            case .success(let result):
                do {
                    let manifests = result.manifests
                    let fileSystem = result.fileSystem

                    // first, decide the tools-version we should use
                    guard let defaultManifestToolsVersion = manifests.first(where: { $0.key == Manifest.filename })?.value.toolsVersion else {
                        throw StringError("Could not find the '\(Manifest.filename)' file for '\(self.package.identity)' '\(version)'")
                    }
                    // find the preferred manifest path and parse it's tools-version
                    let preferredToolsVersionManifestPath = try ManifestLoader.findManifest(packagePath: .root, fileSystem: fileSystem, currentToolsVersion: self.currentToolsVersion)
                    let preferredToolsVersion = try ToolsVersionParser.parse(manifestPath: preferredToolsVersionManifestPath, fileSystem: fileSystem)
                    // load the manifest content
                    let loadManifest = {
                        self.manifestLoader.load(
                            packagePath: .root,
                            packageIdentity: self.package.identity,
                            packageKind: self.package.kind,
                            packageLocation: self.package.locationString,
                            packageVersion: (version: version, revision: nil),
                            currentToolsVersion: self.currentToolsVersion,
                            identityResolver: self.identityResolver,
                            dependencyMapper: self.dependencyMapper,
                            fileSystem: result.fileSystem,
                            observabilityScope: self.observabilityScope,
                            delegateQueue: .sharedConcurrent,
                            callbackQueue: .sharedConcurrent,
                            completion: completion
                        )
                    }

                    if preferredToolsVersion == defaultManifestToolsVersion {
                        // default tools version - we already have the content on disk from getAvailableManifestsFileSystem()
                        loadManifest()
                    } else {
                        // custom tools-version, we need to fetch the content from the server
                        self.registryClient.getManifestContent(
                            package: self.package.identity,
                            version: version,
                            customToolsVersion: preferredToolsVersion,
                            observabilityScope: self.observabilityScope,
                            callbackQueue: .sharedConcurrent
                        ) { result in
                            switch result {
                            case .failure(let error):
                                return completion(.failure(error))
                            case .success(let manifestContent):
                                do {
                                    // find the fake manifest so we can replace it with the real manifest content
                                    guard let placeholderManifestFileName = try fileSystem.getDirectoryContents(.root).first(where: { file in
                                        if file == Manifest.basename + "@swift-\(preferredToolsVersion).swift" {
                                            return true
                                        } else if preferredToolsVersion.patch == 0, file == Manifest.basename + "@swift-\(preferredToolsVersion.major).\(preferredToolsVersion.minor).swift" {
                                            return true
                                        } else {
                                            return false
                                        }
                                    }) else {
                                        throw StringError("failed locating placeholder manifest for \(preferredToolsVersion)")
                                    }
                                    // replace the fake manifest with the real manifest content
                                    let manifestPath = AbsolutePath.root.appending(component: placeholderManifestFileName)
                                    try fileSystem.removeFileTree(manifestPath)
                                    try fileSystem.writeFileContents(manifestPath, string: manifestContent)
                                    // finally, load the manifest
                                    loadManifest()
                                } catch {
                                    return completion(.failure(error))
                                }
                            }
                        }
                    }
                } catch {
                    return completion(.failure(error))
                }
            }
        }
    }

    private func getAvailableManifestsFilesystem(version: Version, completion: @escaping (Result<(manifests: [String: (toolsVersion: ToolsVersion, content: String?)], fileSystem: FileSystem), Error>) -> Void) {
        // try cached first
        if let availableManifests = self.availableManifestsCache[version] {
            return completion(.success(availableManifests))
        }
        // get from server
        self.registryClient.getAvailableManifests(
            package: self.package.identity,
            version: version,
            observabilityScope: self.observabilityScope,
            callbackQueue: .sharedConcurrent
        ) { result in
            completion(result.tryMap { manifests in
                // ToolsVersionLoader is designed to scan files to decide which is the best tools-version
                // as such, this writes a fake manifest based on the information returned by the registry
                // with only the header line which is all that is needed by ToolsVersionLoader
                let fileSystem = InMemoryFileSystem()
                for manifest in manifests {
                    let content = manifest.value.content ?? "// swift-tools-version:\(manifest.value.toolsVersion)"
                    try fileSystem.writeFileContents(AbsolutePath.root.appending(component: manifest.key), string: content)
                }
                self.availableManifestsCache[version] = (manifests: manifests, fileSystem: fileSystem)
                return (manifests: manifests, fileSystem: fileSystem)
            })
        }
    }
}

// MARK: - CustomStringConvertible

extension RegistryPackageContainer: CustomStringConvertible {
    public var description: String {
        return "RegistryPackageContainer(\(package.identity))"
    }
}
