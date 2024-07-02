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
import struct Basics.InternalError
import class Basics.ObservabilityScope
import func Basics.os_signpost
import struct Basics.RelativePath
import enum Basics.SignpostName
import func Basics.temp_await
import class Basics.ThreadSafeKeyValueStore
import class Dispatch.DispatchGroup
import struct Dispatch.DispatchTime
import enum Dispatch.DispatchTimeInterval
import struct PackageGraph.Assignment
import enum PackageGraph.BoundVersion
import enum PackageGraph.ContainerUpdateStrategy
import protocol PackageGraph.CustomPackageContainer
import struct PackageGraph.DependencyResolverBinding
import protocol PackageGraph.DependencyResolverDelegate
import struct PackageGraph.Incompatibility
import struct PackageGraph.MultiplexResolverDelegate
import struct PackageGraph.ObservabilityDependencyResolverDelegate
import struct PackageGraph.PackageContainerConstraint
import struct PackageGraph.PackageGraphRoot
import struct PackageGraph.PackageGraphRootInput
import class PackageGraph.PinsStore
import struct PackageGraph.PubGrubDependencyResolver
import struct PackageGraph.Term
import class PackageLoading.ManifestLoader
import struct PackageModel.ProvidedLibrary
import enum PackageModel.PackageDependency
import struct PackageModel.PackageIdentity
import struct PackageModel.PackageReference
import enum PackageModel.ProductFilter
import struct PackageModel.ToolsVersion
import struct SourceControl.Revision
import struct TSCUtility.Version

extension Workspace {
    enum ResolvedFileStrategy {
        case lockFile
        case update(forceResolution: Bool)
        case bestEffort
    }

    func _updateDependencies(
        root: PackageGraphRootInput,
        packages: [String] = [],
        dryRun: Bool = false,
        observabilityScope: ObservabilityScope
    ) async throws -> [(PackageReference, Workspace.PackageStateChange)]? {
        let start = DispatchTime.now()
        self.delegate?.willUpdateDependencies()
        defer {
            self.delegate?.didUpdateDependencies(duration: start.distance(to: .now()))
        }

        // Create cache directories.
        self.createCacheDirectories(observabilityScope: observabilityScope)

        // FIXME: this should not block
        // Load the root manifests and currently checked out manifests.
        let rootManifests = await self.loadRootManifests(
            packages: root.packages,
            observabilityScope: observabilityScope
        )
        let rootManifestsMinimumToolsVersion = rootManifests.values.map(\.toolsVersion).min() ?? ToolsVersion.current
        let resolvedFileOriginHash = try self.computeResolvedFileOriginHash(root: root)

        // Load the current manifests.
        let graphRoot = PackageGraphRoot(
            input: root,
            manifests: rootManifests,
            dependencyMapper: self.dependencyMapper,
            observabilityScope: observabilityScope
        )
        let currentManifests = try await self.loadDependencyManifests(
            root: graphRoot,
            observabilityScope: observabilityScope
        )

        // Abort if we're unable to load the pinsStore or have any diagnostics.
        guard let pinsStore = observabilityScope.trap({ try self.pinsStore.load() }) else { return nil }

        // Ensure we don't have any error at this point.
        guard !observabilityScope.errorsReported else {
            return nil
        }

        // Add unversioned constraints for edited packages.
        var updateConstraints = currentManifests.editedPackagesConstraints

        // Create constraints based on root manifest and pins for the update resolution.
        updateConstraints += try graphRoot.constraints()

        let pins: PinsStore.Pins
        if packages.isEmpty {
            // No input packages so we have to do a full update. Set pins map to empty.
            pins = [:]
        } else {
            // We have input packages so we have to partially update the package graph. Remove
            // the pins for the input packages so only those packages are updated.
            pins = pinsStore.pins
                .filter {
                    !packages.contains($0.value.packageRef.identity.description) && !packages
                        .contains($0.value.packageRef.deprecatedName)
                }
        }

        // Resolve the dependencies.
        let resolver = try self.createResolver(
            pins: pins,
            observabilityScope: observabilityScope
        )
        self.activeResolver = resolver

        let updateResults = self.resolveDependencies(
            resolver: resolver,
            constraints: updateConstraints,
            observabilityScope: observabilityScope
        )

        // Reset the active resolver.
        self.activeResolver = nil

        guard !observabilityScope.errorsReported else {
            return nil
        }

        if dryRun {
            return observabilityScope.trap {
                try self.computePackageStateChanges(
                    root: graphRoot,
                    resolvedDependencies: updateResults,
                    updateBranches: true,
                    observabilityScope: observabilityScope
                )
            }
        }

        // Update the checkouts based on new dependency resolution.
        let packageStateChanges = self.updateDependenciesCheckouts(
            root: graphRoot,
            updateResults: updateResults,
            updateBranches: true,
            observabilityScope: observabilityScope
        )
        guard !observabilityScope.errorsReported else {
            return nil
        }

        // Load the updated manifests.
        let updatedDependencyManifests = try await self.loadDependencyManifests(
            root: graphRoot,
            observabilityScope: observabilityScope
        )
        // If we have missing packages, something is fundamentally wrong with the resolution of the graph
        let stillMissingPackages = try updatedDependencyManifests.missingPackages
        guard stillMissingPackages.isEmpty else {
            observabilityScope.emit(.exhaustedAttempts(missing: stillMissingPackages))
            return nil
        }

        // Update the resolved file.
        try self.saveResolvedFile(
            pinsStore: pinsStore,
            dependencyManifests: updatedDependencyManifests,
            originHash: resolvedFileOriginHash,
            rootManifestsMinimumToolsVersion: rootManifestsMinimumToolsVersion,
            observabilityScope: observabilityScope
        )

        // Update the binary target artifacts.
        let addedOrUpdatedPackages = packageStateChanges.compactMap { $0.1.isAddedOrUpdated ? $0.0 : nil }
        try self.updateBinaryArtifacts(
            manifests: updatedDependencyManifests,
            addedOrUpdatedPackages: addedOrUpdatedPackages,
            observabilityScope: observabilityScope
        )

        return packageStateChanges
    }

    @discardableResult
    func _resolve(
        root: PackageGraphRootInput,
        explicitProduct: String?,
        resolvedFileStrategy: ResolvedFileStrategy,
        observabilityScope: ObservabilityScope
    ) async throws -> DependencyManifests {
        let start = DispatchTime.now()
        self.delegate?.willResolveDependencies()
        defer {
            self.delegate?.didResolveDependencies(duration: start.distance(to: .now()))
        }

        switch resolvedFileStrategy {
        case .lockFile:
            observabilityScope.emit(info: "using '\(self.location.resolvedVersionsFile.basename)' file as lock file")
            return try await self._resolveBasedOnResolvedVersionsFile(
                root: root,
                explicitProduct: explicitProduct,
                observabilityScope: observabilityScope
            )
        case .update(let forceResolution):
            return try await resolveAndUpdateResolvedFile(forceResolution: forceResolution)
        case .bestEffort:
            guard !self.state.dependencies.hasEditedDependencies() else {
                return try await resolveAndUpdateResolvedFile(forceResolution: false)
            }
            guard self.fileSystem.exists(self.location.resolvedVersionsFile) else {
                return try await resolveAndUpdateResolvedFile(forceResolution: false)
            }

            guard let pinsStore = try? self.pinsStore.load(), let storedHash = pinsStore.originHash else {
                observabilityScope
                    .emit(
                        debug: "'\(self.location.resolvedVersionsFile.basename)' origin hash is missing. resolving and updating accordingly"
                    )
                return try await resolveAndUpdateResolvedFile(forceResolution: false)
            }

            let currentHash = try self.computeResolvedFileOriginHash(root: root)
            guard storedHash == currentHash else {
                observabilityScope
                    .emit(
                        debug: "'\(self.location.resolvedVersionsFile.basename)' origin hash does do not match manifest dependencies. resolving and updating accordingly"
                    )
                return try await resolveAndUpdateResolvedFile(forceResolution: false)
            }

            observabilityScope
                .emit(
                    debug: "'\(self.location.resolvedVersionsFile.basename)' origin hash matches manifest dependencies, attempting resolution based on this file"
                )
            let (manifests, precomputationResult) = try await self.tryResolveBasedOnResolvedVersionsFile(
                root: root,
                explicitProduct: explicitProduct,
                observabilityScope: observabilityScope
            )
            switch precomputationResult {
            case .notRequired:
                return manifests
            case .required(reason: .errorsPreviouslyReported):
                return manifests
            case .required(let reason):
                // FIXME: ideally this is not done based on a side-effect
                let reasonString = Self.format(workspaceResolveReason: reason)
                observabilityScope
                    .emit(
                        debug: "resolution based on '\(self.location.resolvedVersionsFile.basename)' could not be completed because \(reasonString). resolving and updating accordingly"
                    )
                return try await resolveAndUpdateResolvedFile(forceResolution: false)
            }
        }

        func resolveAndUpdateResolvedFile(forceResolution: Bool) async throws -> DependencyManifests {
            observabilityScope.emit(debug: "resolving and updating '\(self.location.resolvedVersionsFile.basename)'")
            return try await self.resolveAndUpdateResolvedFile(
                root: root,
                explicitProduct: explicitProduct,
                forceResolution: forceResolution,
                constraints: [],
                observabilityScope: observabilityScope
            )
        }
    }

    private func computeResolvedFileOriginHash(root: PackageGraphRootInput) throws -> String {
        var content = try root.packages.reduce(into: "") { partial, element in
            let path = try ManifestLoader.findManifest(
                packagePath: element,
                fileSystem: self.fileSystem,
                currentToolsVersion: self.currentToolsVersion
            )
            try partial.append(self.fileSystem.readFileContents(path))
        }
        content += root.dependencies.reduce(into: "") { partial, element in
            partial += element.locationString
        }
        return content.sha256Checksum
    }

    @discardableResult
    func _resolveBasedOnResolvedVersionsFile(
        root: PackageGraphRootInput,
        explicitProduct: String?,
        observabilityScope: ObservabilityScope
    ) async throws -> DependencyManifests {
        let (manifests, precomputationResult) = try await self.tryResolveBasedOnResolvedVersionsFile(
            root: root,
            explicitProduct: explicitProduct,
            observabilityScope: observabilityScope
        )
        switch precomputationResult {
        case .notRequired:
            return manifests
        case .required(reason: .errorsPreviouslyReported):
            return manifests
        case .required(let reason):
            // FIXME: ideally this is not done based on a side-effect
            let reasonString = Self.format(workspaceResolveReason: reason)
            if !self.fileSystem.exists(self.location.resolvedVersionsFile) {
                observabilityScope
                    .emit(
                        error: "a resolved file is required when automatic dependency resolution is disabled and should be placed at \(self.location.resolvedVersionsFile.pathString). \(reasonString)"
                    )
            } else {
                observabilityScope
                    .emit(
                        error: "an out-of-date resolved file was detected at \(self.location.resolvedVersionsFile.pathString), which is not allowed when automatic dependency resolution is disabled; please make sure to update the file to reflect the changes in dependencies. \(reasonString)"
                    )
            }
            return manifests
        }
    }

    /// Resolves the dependencies according to the entries present in the Package.resolved file.
    ///
    /// This method bypasses the dependency resolution and resolves dependencies
    /// according to the information in the resolved file.
    fileprivate func tryResolveBasedOnResolvedVersionsFile(
        root: PackageGraphRootInput,
        explicitProduct: String?,
        observabilityScope: ObservabilityScope
    ) async throws -> (DependencyManifests, ResolutionPrecomputationResult) {
        // Ensure the cache path exists.
        self.createCacheDirectories(observabilityScope: observabilityScope)

        // FIXME: this should not block
        let rootManifests = await self.loadRootManifests(
            packages: root.packages,
            observabilityScope: observabilityScope
        )
        let graphRoot = PackageGraphRoot(
            input: root,
            manifests: rootManifests,
            explicitProduct: explicitProduct,
            dependencyMapper: self.dependencyMapper,
            observabilityScope: observabilityScope
        )

        // Load the pins store or abort now.
        guard let pinsStore = observabilityScope.trap({ try self.pinsStore.load() }),
              !observabilityScope.errorsReported
        else {
            return try (
                await self.loadDependencyManifests(
                    root: graphRoot,
                    observabilityScope: observabilityScope
                ),
                .notRequired
            )
        }

        // Request all the containers to fetch them in parallel.
        //
        // We just request the packages here, repository manager will
        // automatically manage the parallelism.
        let group = DispatchGroup()
        for pin in pinsStore.pins.values {
            // Provided library doesn't have a container, we need to inject a special depedency.
            if let library = pin.packageRef.matchingPrebuiltLibrary(in: self.providedLibraries),
               case .version(library.version, _) = pin.state
            {
                try self.state.dependencies.add(
                    .providedLibrary(
                        packageRef: pin.packageRef,
                        library: library
                    )
                )
                try self.state.save()
                continue
            }

            group.enter()
            let observabilityScope = observabilityScope.makeChildScope(
                description: "requesting package containers",
                metadata: pin.packageRef.diagnosticsMetadata
            )

            let updateStrategy: ContainerUpdateStrategy = {
                if self.configuration.skipDependenciesUpdates {
                    return .never
                } else {
                    switch pin.state {
                    case .branch(_, let revision):
                        return .ifNeeded(revision: revision)
                    case .revision(let revision):
                        return .ifNeeded(revision: revision)
                    case .version(_, .some(let revision)):
                        return .ifNeeded(revision: revision)
                    case .version(_, .none):
                        return .always
                    }
                }
            }()

            self.packageContainerProvider.getContainer(
                for: pin.packageRef,
                updateStrategy: updateStrategy,
                observabilityScope: observabilityScope,
                on: .sharedConcurrent,
                completion: { _ in group.leave() }
            )
        }
        group.wait()

        // Compute the pins that we need to actually clone.
        //
        // We require cloning if there is no checkout or if the checkout doesn't
        // match with the pin.
        let requiredPins = pinsStore.pins.values.filter { pin in
            // also compare the location in case it has changed
            guard let dependency = state.dependencies[comparingLocation: pin.packageRef] else {
                return true
            }
            switch dependency.state {
            case .sourceControlCheckout(let checkoutState):
                return !pin.state.equals(checkoutState)
            case .registryDownload(let version):
                return !pin.state.equals(version)
            case .providedLibrary:
                return false
            case .edited, .fileSystem, .custom:
                return true
            }
        }

        // Retrieve the required pins.
        for pin in requiredPins {
            observabilityScope.makeChildScope(
                description: "retrieving dependency pins",
                metadata: pin.packageRef.diagnosticsMetadata
            ).trap {
                switch pin.packageRef.kind {
                case .localSourceControl, .remoteSourceControl:
                    _ = try self.checkoutRepository(
                        package: pin.packageRef,
                        at: pin.state,
                        observabilityScope: observabilityScope
                    )
                case .registry:
                    _ = try self.downloadRegistryArchive(
                        package: pin.packageRef,
                        at: pin.state,
                        observabilityScope: observabilityScope
                    )
                default:
                    throw InternalError("invalid pin type \(pin.packageRef.kind)")
                }
            }
        }

        let currentManifests = try await self.loadDependencyManifests(
            root: graphRoot,
            automaticallyAddManagedDependencies: true,
            observabilityScope: observabilityScope
        )

        try self.updateBinaryArtifacts(
            manifests: currentManifests,
            addedOrUpdatedPackages: [],
            observabilityScope: observabilityScope
        )

        let precomputationResult = try self.precomputeResolution(
            root: graphRoot,
            dependencyManifests: currentManifests,
            pinsStore: pinsStore,
            constraints: [],
            observabilityScope: observabilityScope
        )

        return (currentManifests, precomputationResult)
    }

    /// Implementation of resolve(root:diagnostics:).
    ///
    /// The extra constraints will be added to the main requirements.
    /// It is useful in situations where a requirement is being
    /// imposed outside of manifest and pins file. E.g., when using a command
    /// like `$ swift package resolve foo --version 1.0.0`.
    @discardableResult
    func resolveAndUpdateResolvedFile(
        root: PackageGraphRootInput,
        explicitProduct: String? = nil,
        forceResolution: Bool,
        constraints: [PackageContainerConstraint],
        observabilityScope: ObservabilityScope
    ) async throws -> DependencyManifests {
        // Ensure the cache path exists and validate that edited dependencies.
        self.createCacheDirectories(observabilityScope: observabilityScope)

        // Load the root manifests and currently checked out manifests.
        let rootManifests = await self.loadRootManifests(
            packages: root.packages,
            observabilityScope: observabilityScope
        )
        let rootManifestsMinimumToolsVersion = rootManifests.values.map(\.toolsVersion).min() ?? ToolsVersion.current
        let resolvedFileOriginHash = try self.computeResolvedFileOriginHash(root: root)

        // Load the current manifests.
        let graphRoot = PackageGraphRoot(
            input: root,
            manifests: rootManifests,
            explicitProduct: explicitProduct,
            dependencyMapper: self.dependencyMapper,
            observabilityScope: observabilityScope
        )
        let currentManifests = try await self.loadDependencyManifests(
            root: graphRoot,
            observabilityScope: observabilityScope
        )
        guard !observabilityScope.errorsReported else {
            return currentManifests
        }

        // load and update the pins store with any changes from loading the top level dependencies
        guard let pinsStore = self.loadAndUpdatePinsStore(
            dependencyManifests: currentManifests,
            rootManifestsMinimumToolsVersion: rootManifestsMinimumToolsVersion,
            observabilityScope: observabilityScope
        ) else {
            // abort if PinsStore reported any errors.
            return currentManifests
        }

        // abort if PinsStore reported any errors.
        guard !observabilityScope.errorsReported else {
            return currentManifests
        }

        // Compute the missing package identities.
        let missingPackages = try currentManifests.missingPackages

        // Compute if we need to run the resolver. We always run the resolver if
        // there are extra constraints.
        if !missingPackages.isEmpty {
            delegate?.willResolveDependencies(reason: .newPackages(packages: Array(missingPackages)))
        } else if !constraints.isEmpty || forceResolution {
            delegate?.willResolveDependencies(reason: .forced)
        } else {
            let result = try self.precomputeResolution(
                root: graphRoot,
                dependencyManifests: currentManifests,
                pinsStore: pinsStore,
                constraints: constraints,
                observabilityScope: observabilityScope
            )

            switch result {
            case .notRequired:
                // since nothing changed we can exit early,
                // but need update resolved file and download an missing binary artifact
                try self.saveResolvedFile(
                    pinsStore: pinsStore,
                    dependencyManifests: currentManifests,
                    originHash: resolvedFileOriginHash,
                    rootManifestsMinimumToolsVersion: rootManifestsMinimumToolsVersion,
                    observabilityScope: observabilityScope
                )

                try self.updateBinaryArtifacts(
                    manifests: currentManifests,
                    addedOrUpdatedPackages: [],
                    observabilityScope: observabilityScope
                )

                return currentManifests
            case .required(let reason):
                delegate?.willResolveDependencies(reason: reason)
            }
        }

        // Create the constraints.
        var computedConstraints = [PackageContainerConstraint]()
        computedConstraints += currentManifests.editedPackagesConstraints
        computedConstraints += try graphRoot.constraints() + constraints

        // Perform dependency resolution.
        let resolver = try self.createResolver(
            pins: pinsStore.pins,
            observabilityScope: observabilityScope
        )
        self.activeResolver = resolver

        let result = self.resolveDependencies(
            resolver: resolver,
            constraints: computedConstraints,
            observabilityScope: observabilityScope
        )

        // Reset the active resolver.
        self.activeResolver = nil

        guard !observabilityScope.errorsReported else {
            return currentManifests
        }

        // Update the checkouts with dependency resolution result.
        let packageStateChanges = self.updateDependenciesCheckouts(
            root: graphRoot,
            updateResults: result,
            observabilityScope: observabilityScope
        )
        guard !observabilityScope.errorsReported else {
            return currentManifests
        }

        // Update the pinsStore.
        let updatedDependencyManifests = try await self.loadDependencyManifests(
            root: graphRoot,
            observabilityScope: observabilityScope
        )
        // If we still have missing packages, something is fundamentally wrong with the resolution of the graph
        let stillMissingPackages = try updatedDependencyManifests.missingPackages
        guard stillMissingPackages.isEmpty else {
            observabilityScope.emit(.exhaustedAttempts(missing: stillMissingPackages))
            return updatedDependencyManifests
        }

        // Update the resolved file.
        try self.saveResolvedFile(
            pinsStore: pinsStore,
            dependencyManifests: updatedDependencyManifests,
            originHash: resolvedFileOriginHash,
            rootManifestsMinimumToolsVersion: rootManifestsMinimumToolsVersion,
            observabilityScope: observabilityScope
        )

        let addedOrUpdatedPackages = packageStateChanges.compactMap { $0.1.isAddedOrUpdated ? $0.0 : nil }
        try self.updateBinaryArtifacts(
            manifests: updatedDependencyManifests,
            addedOrUpdatedPackages: addedOrUpdatedPackages,
            observabilityScope: observabilityScope
        )

        return updatedDependencyManifests
    }

    /// Updates the current working checkouts i.e. clone or remove based on the
    /// provided dependency resolution result.
    ///
    /// - Parameters:
    ///   - updateResults: The updated results from dependency resolution.
    ///   - diagnostics: The diagnostics engine that reports errors, warnings
    ///     and notes.
    ///   - updateBranches: If the branches should be updated in case they're pinned.
    @discardableResult
    fileprivate func updateDependenciesCheckouts(
        root: PackageGraphRoot,
        updateResults: [DependencyResolverBinding],
        updateBranches: Bool = false,
        observabilityScope: ObservabilityScope
    ) -> [(PackageReference, PackageStateChange)] {
        // Get the update package states from resolved results.
        guard let packageStateChanges = observabilityScope.trap({
            try self.computePackageStateChanges(
                root: root,
                resolvedDependencies: updateResults,
                updateBranches: updateBranches,
                observabilityScope: observabilityScope
            )
        }) else {
            return []
        }

        // First remove the checkouts that are no longer required.
        for (packageRef, state) in packageStateChanges {
            observabilityScope.makeChildScope(
                description: "removing unneeded checkouts",
                metadata: packageRef.diagnosticsMetadata
            ).trap {
                switch state {
                case .added, .updated, .unchanged, .usesLibrary:
                    break
                case .removed:
                    try self.remove(package: packageRef)
                }
            }
        }

        // Update or clone new packages.
        for (packageRef, state) in packageStateChanges {
            observabilityScope.makeChildScope(
                description: "updating or cloning new packages",
                metadata: packageRef.diagnosticsMetadata
            ).trap {
                switch state {
                case .added(let state):
                    _ = try self.updateDependency(
                        package: packageRef,
                        requirement: state.requirement,
                        productFilter: state.products,
                        observabilityScope: observabilityScope
                    )
                case .updated(let state):
                    _ = try self.updateDependency(
                        package: packageRef,
                        requirement: state.requirement,
                        productFilter: state.products,
                        observabilityScope: observabilityScope
                    )
                case .removed, .unchanged, .usesLibrary:
                    break
                }
            }
        }

        // Handle provided libraries
        for (packageRef, state) in packageStateChanges {
            observabilityScope.makeChildScope(
                description: "adding provided libraries",
                metadata: packageRef.diagnosticsMetadata
            ).trap {
                if case .usesLibrary(let library) = state {
                    try self.state.dependencies.add(
                        .providedLibrary(packageRef: packageRef, library: library)
                    )
                    try self.state.save()
                }
            }
        }

        // Inform the delegate if nothing was updated.
        if packageStateChanges.filter({ $0.1 == .unchanged }).count == packageStateChanges.count {
            delegate?.dependenciesUpToDate()
        }

        return packageStateChanges
    }

    private func updateDependency(
        package: PackageReference,
        requirement: PackageStateChange.Requirement,
        productFilter: ProductFilter,
        observabilityScope: ObservabilityScope
    ) throws -> AbsolutePath {
        switch requirement {
        case .version(let version):
            // FIXME: this should not block
            let container = try temp_await {
                packageContainerProvider.getContainer(
                    for: package,
                    updateStrategy: .never,
                    observabilityScope: observabilityScope,
                    on: .sharedConcurrent,
                    completion: $0
                )
            }

            if let container = container as? SourceControlPackageContainer {
                // FIXME: We need to get the revision here, and we don't have a
                // way to get it back out of the resolver which is very
                // annoying. Maybe we should make an SPI on the provider for this?
                guard let tag = container.getTag(for: version) else {
                    throw try InternalError(
                        "unable to get tag for \(package) \(version); available versions \(container.versionsDescending())"
                    )
                }
                let revision = try container.getRevision(forTag: tag)
                try container.checkIntegrity(version: version, revision: revision)
                return try self.checkoutRepository(
                    package: package,
                    at: .version(version, revision: revision),
                    observabilityScope: observabilityScope
                )
            } else if let _ = container as? RegistryPackageContainer {
                return try self.downloadRegistryArchive(
                    package: package,
                    at: version,
                    observabilityScope: observabilityScope
                )
            } else if let customContainer = container as? CustomPackageContainer {
                let path = try customContainer.retrieve(at: version, observabilityScope: observabilityScope)
                let dependency = try ManagedDependency(
                    packageRef: package,
                    state: .custom(version: version, path: path),
                    subpath: RelativePath(validating: "")
                )
                self.state.dependencies.add(dependency)
                try self.state.save()
                return path
            } else {
                throw InternalError("invalid container for \(package.identity) of type \(package.kind)")
            }

        case .revision(let revision, .none):
            return try self.checkoutRepository(
                package: package,
                at: .revision(revision),
                observabilityScope: observabilityScope
            )

        case .revision(let revision, .some(let branch)):
            return try self.checkoutRepository(
                package: package,
                at: .branch(name: branch, revision: revision),
                observabilityScope: observabilityScope
            )

        case .unversioned:
            let dependency = try ManagedDependency.fileSystem(packageRef: package)
            // this is silly since we just created it above, but no good way to force cast it and extract the path
            guard case .fileSystem(let path) = dependency.state else {
                throw InternalError("invalid package type: \(package.kind)")
            }

            self.state.dependencies.add(dependency)
            try self.state.save()
            return path
        }
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
        constraints: [PackageContainerConstraint],
        observabilityScope: ObservabilityScope
    ) throws -> ResolutionPrecomputationResult {
        let computedConstraints =
            try root.constraints() +
            // Include constraints from the manifests in the graph root.
            root.manifests.values.flatMap { try $0.dependencyConstraints(productFilter: .everything) } +
            dependencyManifests.dependencyConstraints +
            constraints

        let precomputationProvider = ResolverPrecomputationProvider(
            root: root,
            dependencyManifests: dependencyManifests
        )
        let resolver = PubGrubDependencyResolver(
            provider: precomputationProvider,
            pins: pinsStore.pins,
            availableLibraries: self.providedLibraries,
            observabilityScope: observabilityScope
        )
        let result = resolver.solve(constraints: computedConstraints)

        guard !observabilityScope.errorsReported else {
            return .required(reason: .errorsPreviouslyReported)
        }

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
        case .failure(let error):
            return .required(reason: .other("\(error.interpolationDescription)"))
        }
    }

    /// Validates that each checked out managed dependency has an entry in pinsStore.
    private func loadAndUpdatePinsStore(
        dependencyManifests: DependencyManifests,
        rootManifestsMinimumToolsVersion: ToolsVersion,
        observabilityScope: ObservabilityScope
    ) -> PinsStore? {
        guard let pinsStore = observabilityScope.trap({ try self.pinsStore.load() }) else {
            return nil
        }

        guard let requiredDependencies = observabilityScope
            .trap({ try dependencyManifests.requiredPackages.filter(\.kind.isPinnable) })
        else {
            return nil
        }
        for dependency in self.state.dependencies.filter(\.packageRef.kind.isPinnable) {
            // a required dependency that is already loaded (managed) should be represented in the pins store.
            // also comparing location as it may have changed at this point
            if requiredDependencies.contains(where: { $0.equalsIncludingLocation(dependency.packageRef) }) {
                // if pin not found, or location is different (it may have changed at this point) pin it
                if pinsStore.pins[comparingLocation: dependency.packageRef] == .none {
                    pinsStore.pin(dependency)
                }
            } else if let pin = pinsStore.pins[dependency.packageRef.identity] {
                // otherwise, it should *not* be in the pins store.
                pinsStore.remove(pin)
            }
        }

        return pinsStore
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

        /// The package is replaced with a prebuilt library
        case usesLibrary(ProvidedLibrary)

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
            case .usesLibrary(let library):
                return "usesLibrary(\(library.metadata.productName))"
            }
        }

        public var isAddedOrUpdated: Bool {
            switch self {
            case .added, .updated:
                true
            case .unchanged, .removed, .usesLibrary:
                false
            }
        }
    }

    /// Computes states of the packages based on last stored state.
    fileprivate func computePackageStateChanges(
        root: PackageGraphRoot,
        resolvedDependencies: [DependencyResolverBinding],
        updateBranches: Bool,
        observabilityScope: ObservabilityScope
    ) throws -> [(PackageReference, PackageStateChange)] {
        // Load pins store and managed dependencies.
        let pinsStore = try self.pinsStore.load()
        var packageStateChanges: [PackageIdentity: (PackageReference, PackageStateChange)] = [:]

        // Set the states from resolved dependencies results.
        for binding in resolvedDependencies {
            // Get the existing managed dependency for this package ref, if any.

            // first find by identity only since edit location may be different by design
            var currentDependency = self.state.dependencies[binding.package.identity]
            // Check if this is an edited dependency.
            if case .edited(let basedOn, _) = currentDependency?.state, let originalReference = basedOn?.packageRef {
                packageStateChanges[originalReference.identity] = (originalReference, .unchanged)
            } else {
                // if not edited, also compare by location since it may have changed
                currentDependency = self.state.dependencies[comparingLocation: binding.package]
            }

            switch binding.boundVersion {
            case .excluded:
                throw InternalError("Unexpected excluded binding")

            case .unversioned:
                // Ignore the root packages.
                if root.packages.keys.contains(binding.package.identity) {
                    continue
                }

                if let currentDependency {
                    switch currentDependency.state {
                    case .fileSystem, .edited:
                        packageStateChanges[binding.package.identity] = (binding.package, .unchanged)
                    case .sourceControlCheckout:
                        let newState = PackageStateChange.State(requirement: .unversioned, products: binding.products)
                        packageStateChanges[binding.package.identity] = (binding.package, .updated(newState))
                    case .registryDownload:
                        throw InternalError("Unexpected unversioned binding for downloaded dependency")
                    case .providedLibrary:
                        throw InternalError("Unexpected unversioned binding for library dependency")
                    case .custom:
                        throw InternalError("Unexpected unversioned binding for custom dependency")
                    }
                } else {
                    let newState = PackageStateChange.State(requirement: .unversioned, products: binding.products)
                    packageStateChanges[binding.package.identity] = (binding.package, .added(newState))
                }

            case .revision(let identifier, let branch):
                // Get the latest revision from the container.
                // TODO: replace with async/await when available
                guard let container = try (temp_await {
                    packageContainerProvider.getContainer(
                        for: binding.package,
                        updateStrategy: .never,
                        observabilityScope: observabilityScope,
                        on: .sharedConcurrent,
                        completion: $0
                    )
                }) as? SourceControlPackageContainer else {
                    throw InternalError(
                        "invalid container for \(binding.package) expected a SourceControlPackageContainer"
                    )
                }
                var revision = try container.getRevision(forIdentifier: identifier)
                let branch = branch ?? (identifier == revision.identifier ? nil : identifier)

                // If we have a branch and we shouldn't be updating the
                // branches, use the revision from pin instead (if present).
                if branch != nil, !updateBranches {
                    if case .branch(branch, let pinRevision) = pinsStore.pins.values
                        .first(where: { $0.packageRef == binding.package })?.state
                    {
                        revision = Revision(identifier: pinRevision)
                    }
                }

                // First check if we have this dependency.
                if let currentDependency {
                    // If current state and new state are equal, we don't need
                    // to do anything.
                    let newState: CheckoutState
                    if let branch {
                        newState = .branch(name: branch, revision: revision)
                    } else {
                        newState = .revision(revision)
                    }
                    if case .sourceControlCheckout(let checkoutState) = currentDependency.state,
                       checkoutState == newState
                    {
                        packageStateChanges[binding.package.identity] = (binding.package, .unchanged)
                    } else {
                        // Otherwise, we need to update this dependency to this revision.
                        let newState = PackageStateChange.State(
                            requirement: .revision(revision, branch: branch),
                            products: binding.products
                        )
                        packageStateChanges[binding.package.identity] = (binding.package, .updated(newState))
                    }
                } else {
                    let newState = PackageStateChange.State(
                        requirement: .revision(revision, branch: branch),
                        products: binding.products
                    )
                    packageStateChanges[binding.package.identity] = (binding.package, .added(newState))
                }

            case .version(let version, let library):
                let stateChange: PackageStateChange = switch currentDependency?.state {
                case .sourceControlCheckout(.version(version, _)),
                     .registryDownload(version),
                     .providedLibrary(_, version: version),
                     .custom(version, _):
                    library.flatMap { .usesLibrary($0) } ?? .unchanged
                case .edited, .fileSystem, .sourceControlCheckout, .registryDownload, .providedLibrary, .custom:
                    .updated(.init(requirement: .version(version), products: binding.products))
                case nil:
                    library.flatMap { .usesLibrary($0) } ?? .added(.init(
                        requirement: .version(version),
                        products: binding.products
                    ))
                }
                packageStateChanges[binding.package.identity] = (binding.package, stateChange)
            }
        }
        // Set the state of any old package that might have been removed.
        for packageRef in self.state.dependencies.lazy.map(\.packageRef)
            where packageStateChanges[packageRef.identity] == nil
        {
            packageStateChanges[packageRef.identity] = (packageRef, .removed)
        }

        return Array(packageStateChanges.values)
    }

    /// Creates resolver for the workspace.
    fileprivate func createResolver(
        pins: PinsStore.Pins,
        observabilityScope: ObservabilityScope
    ) throws -> PubGrubDependencyResolver {
        var delegate: DependencyResolverDelegate
        let observabilityDelegate = ObservabilityDependencyResolverDelegate(observabilityScope: observabilityScope)
        if let workspaceDelegate = self.delegate {
            delegate = MultiplexResolverDelegate([
                observabilityDelegate,
                WorkspaceDependencyResolverDelegate(workspaceDelegate),
            ])
        } else {
            delegate = observabilityDelegate
        }

        return PubGrubDependencyResolver(
            provider: packageContainerProvider,
            pins: pins,
            availableLibraries: self.providedLibraries,
            skipDependenciesUpdates: self.configuration.skipDependenciesUpdates,
            prefetchBasedOnResolvedFile: self.configuration.prefetchBasedOnResolvedFile,
            observabilityScope: observabilityScope,
            delegate: delegate
        )
    }

    /// Runs the dependency resolver based on constraints provided and returns the results.
    fileprivate func resolveDependencies(
        resolver: PubGrubDependencyResolver,
        constraints: [PackageContainerConstraint],
        observabilityScope: ObservabilityScope
    ) -> [DependencyResolverBinding] {
        os_signpost(.begin, name: SignpostName.pubgrub)
        let result = resolver.solve(constraints: constraints)

        os_signpost(.end, name: SignpostName.pubgrub)

        // Take an action based on the result.
        switch result {
        case .success(let bindings):
            return bindings
        case .failure(let error):
            observabilityScope.emit(error)
            return []
        }
    }

    /// Create the cache directories.
    fileprivate func createCacheDirectories(observabilityScope: ObservabilityScope) {
        observabilityScope.trap {
            try fileSystem.createDirectory(self.repositoryManager.path, recursive: true)
            try fileSystem.createDirectory(self.location.repositoriesCheckoutsDirectory, recursive: true)
            try fileSystem.createDirectory(self.location.artifactsDirectory, recursive: true)
        }
    }
}

private struct WorkspaceDependencyResolverDelegate: DependencyResolverDelegate {
    private weak var workspaceDelegate: Workspace.Delegate?
    private let resolving = ThreadSafeKeyValueStore<PackageIdentity, Bool>()

    init(_ delegate: Workspace.Delegate) {
        self.workspaceDelegate = delegate
    }

    func willResolve(term: Term) {
        // this may be called multiple time by the resolver for various version ranges, but we only want to propagate
        // once since we report at package level
        self.resolving.memoize(term.node.package.identity) {
            self.workspaceDelegate?.willComputeVersion(
                package: term.node.package.identity,
                location: term.node.package.locationString
            )
            return true
        }
    }

    func didResolve(term: Term, version: Version, duration: DispatchTimeInterval) {
        self.workspaceDelegate?.didComputeVersion(
            package: term.node.package.identity,
            location: term.node.package.locationString,
            version: version.description,
            duration: duration
        )
    }

    // noop
    func derived(term: Term) {}
    func conflict(conflict: Incompatibility) {}
    func satisfied(term: Term, by assignment: Assignment, incompatibility: Incompatibility) {}
    func partiallySatisfied(
        term: Term,
        by assignment: Assignment,
        incompatibility: Incompatibility,
        difference: Term
    ) {}
    func failedToResolve(incompatibility: Incompatibility) {}
    func solved(result: [DependencyResolverBinding]) {}
}

// FIXME: the manifest loading logic should be changed to use identity instead of location once identity is unique
// at that time we should remove this
// @available(*, deprecated)
extension PackageDependency {
    var locationString: String {
        switch self {
        case .fileSystem(let settings):
            return settings.path.pathString
        case .sourceControl(let settings):
            switch settings.location {
            case .local(let path):
                return path.pathString
            case .remote(let url):
                return url.absoluteString
            }
        case .registry:
            // FIXME: placeholder
            return self.identity.description
        }
    }
}

extension Workspace.ManagedDependencies {
    fileprivate func hasEditedDependencies() -> Bool {
        self.contains(where: {
            switch $0.state {
            case .edited:
                return true
            default:
                return false
            }
        })
    }
}
