//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Dispatch
import PackageModel
import PackageLoading
import PackageGraph

import func XCTest.XCTFail

import struct TSCUtility.Version

public enum MockManifestLoaderError: Swift.Error {
    case unknownRequest(String)
}

/// A mock manifest loader implementation.
///
/// This implementation takes a canned set of manifests for known URLs and
/// versions and exposes them via the `ManifestLoaderProtocol`, for use in
/// testing higher-level clients which use manifests, but don't require testing
/// the loading logic itself.
///
/// This implementation will throw an error if a request to load an unknown
/// manifest is made.
public final class MockManifestLoader: ManifestLoaderProtocol {
    public struct Key: Hashable {
        public let url: String
        public let version: Version?

        public init(url: String, version: Version? = nil) {
            self.url = url
            self.version = version
        }
    }

    public let manifests: ThreadSafeKeyValueStore<Key, Manifest>

    public init(manifests: [Key: Manifest]) {
        self.manifests = ThreadSafeKeyValueStore<Key, Manifest>(manifests)
    }

    public func load(
        manifestPath: AbsolutePath,
        manifestToolsVersion: ToolsVersion,
        packageIdentity: PackageIdentity,
        packageKind: PackageReference.Kind,
        packageLocation: String,
        packageVersion: (version: Version?, revision: String?)?,
        identityResolver: IdentityResolver,
        dependencyMapper: DependencyMapper,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope,
        delegateQueue: DispatchQueue,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Manifest, Error>) -> Void
    ) {
        callbackQueue.async {
            let key = Key(url: packageLocation, version: packageVersion?.version)
            if let result = self.manifests[key] {
                return completion(.success(result))
            } else {
                return completion(.failure(MockManifestLoaderError.unknownRequest("\(key)")))
            }
        }
    }

    public func resetCache(observabilityScope: ObservabilityScope) {}
    public func purgeCache(observabilityScope: ObservabilityScope) {}
}

extension ManifestLoader {
    public func load(
        manifestPath: AbsolutePath,
        packageKind: PackageReference.Kind,
        toolsVersion manifestToolsVersion: ToolsVersion,
        identityResolver: IdentityResolver = DefaultIdentityResolver(),
        dependencyMapper: DependencyMapper? = .none,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) async throws -> Manifest{
        let packageIdentity: PackageIdentity
        let packageLocation: String
        switch packageKind {
        case .root(let path):
            packageIdentity = try identityResolver.resolveIdentity(for: path)
            packageLocation = path.pathString
        case .fileSystem(let path):
            packageIdentity = try identityResolver.resolveIdentity(for: path)
            packageLocation = path.pathString
        case .localSourceControl(let path):
            packageIdentity = try identityResolver.resolveIdentity(for: path)
            packageLocation = path.pathString
        case .remoteSourceControl(let url):
            packageIdentity = try identityResolver.resolveIdentity(for: url)
            packageLocation = url.absoluteString
        case .registry(let identity):
            packageIdentity = identity
            // FIXME: placeholder
            packageLocation = identity.description
        }
        return try await self.load(
            manifestPath: manifestPath,
            manifestToolsVersion: manifestToolsVersion,
            packageIdentity: packageIdentity,
            packageKind: packageKind,
            packageLocation: packageLocation,
            packageVersion: nil,
            identityResolver: identityResolver,
            dependencyMapper: dependencyMapper ?? DefaultDependencyMapper(identityResolver: identityResolver),
            fileSystem: fileSystem,
            observabilityScope: observabilityScope,
            delegateQueue: .sharedConcurrent,
            callbackQueue: .sharedConcurrent
        )
    }
}

extension ManifestLoader {
    public func load(
        packagePath: AbsolutePath,
        packageKind: PackageReference.Kind,
        currentToolsVersion: ToolsVersion,
        identityResolver: IdentityResolver = DefaultIdentityResolver(),
        dependencyMapper: DependencyMapper? = .none,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) async throws -> Manifest{
        let packageIdentity: PackageIdentity
        let packageLocation: String
        switch packageKind {
        case .root(let path):
            packageIdentity = try identityResolver.resolveIdentity(for: path)
            packageLocation = path.pathString
        case .fileSystem(let path):
            packageIdentity = try identityResolver.resolveIdentity(for: path)
            packageLocation = path.pathString
        case .localSourceControl(let path):
            packageIdentity = try identityResolver.resolveIdentity(for: path)
            packageLocation = path.pathString
        case .remoteSourceControl(let url):
            packageIdentity = try identityResolver.resolveIdentity(for: url)
            packageLocation = url.absoluteString
        case .registry(let identity):
            packageIdentity = identity
            // FIXME: placeholder
            packageLocation = identity.description
        }
        return try await self.load(
            packagePath: packagePath,
            packageIdentity: packageIdentity,
            packageKind: packageKind,
            packageLocation: packageLocation,
            packageVersion: nil,
            currentToolsVersion: currentToolsVersion,
            identityResolver: identityResolver,
            dependencyMapper: dependencyMapper ?? DefaultDependencyMapper(identityResolver: identityResolver),
            fileSystem: fileSystem,
            observabilityScope: observabilityScope,
            delegateQueue: .sharedConcurrent,
            callbackQueue: .sharedConcurrent
        )
    }
}
