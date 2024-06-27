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

import struct Basics.AbsolutePath
import protocol Basics.FileSystem
import struct Basics.InternalError
import class Basics.ObservabilityScope
import struct Basics.SourceControlURL
import class Basics.ThreadSafeKeyValueStore
import func Basics.temp_await
import class PackageGraph.PinsStore
import protocol PackageLoading.ManifestLoaderProtocol
import protocol PackageModel.DependencyMapper
import protocol PackageModel.IdentityResolver
import class PackageModel.Manifest
import enum PackageModel.PackageDependency
import struct PackageModel.PackageIdentity
import struct PackageModel.PackageReference
import struct PackageModel.TargetDescription
import struct PackageModel.ToolsVersion
import class PackageRegistry.RegistryClient
import struct TSCUtility.Version

// Need to import the whole module to get access to `+` operator on `DispatchTimeInterval`
import Dispatch

extension Workspace {
    // the goal of this code is to help align dependency identities across source control and registry origins
    // the issue this solves is that dependencies will have different identities across the origins
    // for example, source control based dependency on http://github.com/apple/swift-nio would have an identifier of
    // "swift-nio"
    // while in the registry, the same package will [likely] have an identifier of "apple.swift-nio"
    // since there is not generally fire sure way to translate one system to the other (urls can vary widely, so the
    // best we would be able to do is guess)
    // what this code does is query the registry of it "knows" what the registry identity of URL is, and then use the
    // registry identity instead of the URL bases one
    // the code also supports a "full swizzle" mode in which it _replaces_ the source control dependency with a registry
    // one which encourages the transition
    // from source control based dependencies to registry based ones

    // TODO:
    // 1. handle mixed situation when some versions on the registry but some on source control. we need a second lookup
    // to make sure the version exists
    // 2. handle registry returning multiple identifiers, how do we choose the right one?
    struct RegistryAwareManifestLoader: ManifestLoaderProtocol {
        private let underlying: ManifestLoaderProtocol
        private let registryClient: RegistryClient
        private let transformationMode: TransformationMode

        private let cacheTTL = DispatchTimeInterval.seconds(300) // 5m
        private let identityLookupCache = ThreadSafeKeyValueStore<
            SourceControlURL,
            (result: Result<PackageIdentity?, Error>, expirationTime: DispatchTime)
        >()

        init(
            underlying: ManifestLoaderProtocol,
            registryClient: RegistryClient,
            transformationMode: TransformationMode
        ) {
            self.underlying = underlying
            self.registryClient = registryClient
            self.transformationMode = transformationMode
        }

        func load(
            manifestPath: AbsolutePath,
            manifestToolsVersion: ToolsVersion,
            packageIdentity: PackageIdentity,
            packageKind: PackageReference.Kind,
            packageLocation: String,
            packageVersion: (version: Version?, revision: String?)?,
            identityResolver: any IdentityResolver,
            dependencyMapper: any DependencyMapper,
            fileSystem: any FileSystem,
            observabilityScope: ObservabilityScope,
            delegateQueue: DispatchQueue,
            callbackQueue: DispatchQueue,
            completion: @escaping (Result<Manifest, Error>) -> Void
        ) {
            self.underlying.load(
                manifestPath: manifestPath,
                manifestToolsVersion: manifestToolsVersion,
                packageIdentity: packageIdentity,
                packageKind: packageKind,
                packageLocation: packageLocation,
                packageVersion: packageVersion,
                identityResolver: identityResolver,
                dependencyMapper: dependencyMapper,
                fileSystem: fileSystem,
                observabilityScope: observabilityScope,
                delegateQueue: delegateQueue,
                callbackQueue: callbackQueue
            ) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let manifest):
                    self.transformSourceControlDependenciesToRegistry(
                        manifest: manifest,
                        transformationMode: transformationMode,
                        observabilityScope: observabilityScope,
                        callbackQueue: callbackQueue,
                        completion: completion
                    )
                }
            }
        }

        func resetCache(observabilityScope: ObservabilityScope) {
            self.underlying.resetCache(observabilityScope: observabilityScope)
        }

        func purgeCache(observabilityScope: ObservabilityScope) {
            self.underlying.purgeCache(observabilityScope: observabilityScope)
        }

        private func transformSourceControlDependenciesToRegistry(
            manifest: Manifest,
            transformationMode: TransformationMode,
            observabilityScope: ObservabilityScope,
            callbackQueue: DispatchQueue,
            completion: @escaping (Result<Manifest, Error>) -> Void
        ) {
            let sync = DispatchGroup()
            let transformations = ThreadSafeKeyValueStore<PackageDependency, PackageIdentity>()
            for dependency in manifest.dependencies {
                if case .sourceControl(let settings) = dependency, case .remote(let url) = settings.location {
                    sync.enter()
                    self.mapRegistryIdentity(
                        url: url,
                        observabilityScope: observabilityScope,
                        callbackQueue: callbackQueue
                    ) { result in
                        defer { sync.leave() }
                        switch result {
                        case .failure(let error):
                            // do not raise error, only report it as warning
                            observabilityScope.emit(
                                warning: "failed querying registry identity for '\(url)'",
                                underlyingError: error
                            )
                        case .success(.some(let identity)):
                            transformations[dependency] = identity
                        case .success(.none):
                            // no identity found
                            break
                        }
                    }
                }
            }

            // update the manifest with the transformed dependencies
            sync.notify(queue: callbackQueue) {
                do {
                    let updatedManifest = try self.transformManifest(
                        manifest: manifest,
                        transformations: transformations.get(),
                        transformationMode: transformationMode,
                        observabilityScope: observabilityScope
                    )
                    completion(.success(updatedManifest))
                } catch {
                    return completion(.failure(error))
                }
            }
        }

        private func transformManifest(
            manifest: Manifest,
            transformations: [PackageDependency: PackageIdentity],
            transformationMode: TransformationMode,
            observabilityScope: ObservabilityScope
        ) throws -> Manifest {
            var targetDependencyPackageNameTransformations = [String: String]()

            var modifiedDependencies = [PackageDependency]()
            for dependency in manifest.dependencies {
                var modifiedDependency = dependency
                if let registryIdentity = transformations[dependency] {
                    guard case .sourceControl(let settings) = dependency, case .remote = settings.location else {
                        // an implementation mistake
                        throw InternalError("unexpected non-source-control dependency: \(dependency)")
                    }
                    switch transformationMode {
                    case .identity:
                        // we replace the *identity* of the dependency in order to align the identities
                        // and de-dupe across source control and registry origins
                        observabilityScope
                            .emit(
                                info: "adjusting '\(dependency.locationString)' identity to registry identity of '\(registryIdentity)'."
                            )
                        modifiedDependency = .sourceControl(
                            identity: registryIdentity,
                            nameForTargetDependencyResolutionOnly: settings.nameForTargetDependencyResolutionOnly,
                            location: settings.location,
                            requirement: settings.requirement,
                            productFilter: settings.productFilter,
                            traits: settings.traits
                        )
                    case .swizzle:
                        // we replace the *entire* source control dependency with a registry one
                        // this helps de-dupe across source control and registry dependencies
                        // and also encourages use of registry over source control
                        switch settings.requirement {
                        case .exact, .range:
                            let requirement = try settings.requirement.asRegistryRequirement()
                            observabilityScope
                                .emit(
                                    info: "swizzling '\(dependency.locationString)' with registry dependency '\(registryIdentity)'."
                                )
                            targetDependencyPackageNameTransformations[dependency
                                .nameForModuleDependencyResolutionOnly] = registryIdentity.description
                            modifiedDependency = .registry(
                                identity: registryIdentity,
                                requirement: requirement,
                                productFilter: settings.productFilter,
                                traits: settings.traits
                            )
                        case .branch, .revision:
                            // branch and revision dependencies are not supported by the registry
                            // in such case, the best we can do is to replace the *identity* of the
                            // source control dependency in order to align the identities
                            // and de-dupe across source control and registry origins
                            observabilityScope
                                .emit(
                                    info: "adjusting '\(dependency.locationString)' identity to registry identity of '\(registryIdentity)'."
                                )
                            modifiedDependency = .sourceControl(
                                identity: registryIdentity,
                                nameForTargetDependencyResolutionOnly: settings.nameForTargetDependencyResolutionOnly,
                                location: settings.location,
                                requirement: settings.requirement,
                                productFilter: settings.productFilter,
                                traits: settings.traits
                            )
                        }
                    }
                }
                modifiedDependencies.append(modifiedDependency)
            }

            var modifiedTargets = manifest.targets
            if !transformations.isEmpty {
                modifiedTargets = []
                for target in manifest.targets {
                    var modifiedDependencies = [TargetDescription.Dependency]()
                    for dependency in target.dependencies {
                        var modifiedDependency = dependency
                        if case .product(let name, let packageName, let moduleAliases, let condition) = dependency,
                           let packageName
                        {
                            // makes sure we use the updated package name for target based dependencies
                            if let modifiedPackageName = targetDependencyPackageNameTransformations[packageName] {
                                modifiedDependency = .product(
                                    name: name,
                                    package: modifiedPackageName,
                                    moduleAliases: moduleAliases,
                                    condition: condition
                                )
                            }
                        }
                        modifiedDependencies.append(modifiedDependency)
                    }

                    try modifiedTargets.append(
                        TargetDescription(
                            name: target.name,
                            dependencies: modifiedDependencies,
                            path: target.path,
                            url: target.url,
                            exclude: target.exclude,
                            sources: target.sources,
                            resources: target.resources,
                            publicHeadersPath: target.publicHeadersPath,
                            type: target.type,
                            packageAccess: target.packageAccess,
                            pkgConfig: target.pkgConfig,
                            providers: target.providers,
                            pluginCapability: target.pluginCapability,
                            settings: target.settings,
                            checksum: target.checksum,
                            pluginUsages: target.pluginUsages
                        )
                    )
                }
            }

            let modifiedManifest = Manifest(
                displayName: manifest.displayName,
                path: manifest.path,
                packageKind: manifest.packageKind,
                packageLocation: manifest.packageLocation,
                defaultLocalization: manifest.defaultLocalization,
                platforms: manifest.platforms,
                version: manifest.version,
                revision: manifest.revision,
                toolsVersion: manifest.toolsVersion,
                pkgConfig: manifest.pkgConfig,
                providers: manifest.providers,
                cLanguageStandard: manifest.cLanguageStandard,
                cxxLanguageStandard: manifest.cxxLanguageStandard,
                swiftLanguageVersions: manifest.swiftLanguageVersions,
                dependencies: modifiedDependencies,
                products: manifest.products,
                targets: modifiedTargets,
                traits: manifest.traits
            )

            return modifiedManifest
        }

        private func mapRegistryIdentity(
            url: SourceControlURL,
            observabilityScope: ObservabilityScope,
            callbackQueue: DispatchQueue,
            completion: @escaping (Result<PackageIdentity?, Error>) -> Void
        ) {
            if let cached = self.identityLookupCache[url], cached.expirationTime > .now() {
                switch cached.result {
                case .success(let identity):
                    return completion(.success(identity))
                case .failure:
                    // server error, do not try again
                    return completion(.success(.none))
                }
            }

            self.registryClient.lookupIdentities(
                scmURL: url,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue
            ) { result in
                switch result {
                case .failure(let error):
                    self.identityLookupCache[url] = (result: .failure(error), expirationTime: .now() + self.cacheTTL)
                    completion(.failure(error))
                case .success(let identities):
                    // FIXME: returns first result... need to consider how to address multiple ones
                    let identity = identities.sorted().first
                    self.identityLookupCache[url] = (result: .success(identity), expirationTime: .now() + self.cacheTTL)
                    completion(.success(identity))
                }
            }
        }

        enum TransformationMode {
            case identity
            case swizzle

            init?(_ seed: WorkspaceConfiguration.SourceControlToRegistryDependencyTransformation) {
                switch seed {
                case .identity:
                    self = .identity
                case .swizzle:
                    self = .swizzle
                case .disabled:
                    return nil
                }
            }
        }
    }
}

extension PackageDependency.SourceControl.Requirement {
    fileprivate func asRegistryRequirement() throws -> PackageDependency.Registry.Requirement {
        switch self {
        case .range(let versions):
            return .range(versions)
        case .exact(let version):
            return .exact(version)
        case .branch, .revision:
            throw InternalError("invalid source control to registry requirement transformation")
        }
    }
}

// MARK: - Registry Source archive management

extension Workspace {
    func downloadRegistryArchive(
        package: PackageReference,
        at version: Version,
        observabilityScope: ObservabilityScope
    ) throws -> AbsolutePath {
        // FIXME: this should not block
        let downloadPath = try temp_await {
            self.registryDownloadsManager.lookup(
                package: package.identity,
                version: version,
                observabilityScope: observabilityScope,
                delegateQueue: .sharedConcurrent,
                callbackQueue: .sharedConcurrent,
                completion: $0
            )
        }

        // Record the new state.
        observabilityScope.emit(
            debug: "adding '\(package.identity)' (\(package.locationString)) to managed dependencies",
            metadata: package.diagnosticsMetadata
        )
        try self.state.dependencies.add(
            .registryDownload(
                packageRef: package,
                version: version,
                subpath: downloadPath.relative(to: self.location.registryDownloadDirectory)
            )
        )
        try self.state.save()

        return downloadPath
    }

    func downloadRegistryArchive(
        package: PackageReference,
        at pinState: PinsStore.PinState,
        observabilityScope: ObservabilityScope
    ) throws -> AbsolutePath {
        switch pinState {
        case .version(let version, _):
            return try self.downloadRegistryArchive(
                package: package,
                at: version,
                observabilityScope: observabilityScope
            )
        default:
            throw InternalError("invalid pin state: \(pinState)")
        }
    }

    func removeRegistryArchive(for dependency: ManagedDependency) throws {
        guard case .registryDownload = dependency.state else {
            throw InternalError("cannot remove source archive for \(dependency) with state \(dependency.state)")
        }

        let downloadPath = self.location.registryDownloadSubdirectory(for: dependency)
        try self.fileSystem.removeFileTree(downloadPath)

        // remove the local copy
        try registryDownloadsManager.remove(package: dependency.packageRef.identity)
    }
}
