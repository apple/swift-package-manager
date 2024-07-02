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
import struct Basics.Diagnostic
import struct Basics.InternalError
import class Basics.ObservabilityScope
import struct Basics.SwiftVersion
import func Basics.asyncDepthFirstSearch
import func Basics.temp_await
import func Basics.depthFirstSearch
import class Basics.ThreadSafeKeyValueStore
import class Dispatch.DispatchGroup
import struct Dispatch.DispatchTime
import struct OrderedCollections.OrderedDictionary
import struct OrderedCollections.OrderedSet
import protocol PackageGraph.CustomPackageContainer
import struct PackageGraph.GraphLoadingNode
import struct PackageGraph.PackageContainerConstraint
import struct PackageGraph.PackageGraphRoot
import class PackageLoading.ManifestLoader
import struct PackageLoading.ManifestValidator
import struct PackageLoading.ToolsVersionParser
import struct PackageModel.ProvidedLibrary
import class PackageModel.Manifest
import struct PackageModel.PackageIdentity
import struct PackageModel.PackageReference
import enum PackageModel.ProductFilter
import struct PackageModel.ToolsVersion
import protocol TSCBasic.FileSystem
import func TSCBasic.findCycle
import struct TSCBasic.KeyedPair
import struct TSCBasic.StringError
import func TSCBasic.topologicalSort
import func TSCBasic.transitiveClosure
import enum TSCUtility.Diagnostics
import struct TSCUtility.Version

// MARK: - Manifest Loading and caching

extension Workspace {
    /// A struct representing all the current manifests (root + external) in a package graph.
    public struct DependencyManifests {
        /// The package graph root.
        let root: PackageGraphRoot

        /// The dependency manifests in the transitive closure of root manifest.
        let dependencies: [(
            manifest: Manifest,
            dependency: ManagedDependency,
            productFilter: ProductFilter,
            fileSystem: FileSystem
        )]

        private let workspace: Workspace

        private let observabilityScope: ObservabilityScope

        private let _dependencies: LoadableResult<(
            required: OrderedCollections.OrderedSet<PackageReference>,
            missing: OrderedCollections.OrderedSet<PackageReference>
        )>

        private let _constraints: LoadableResult<[PackageContainerConstraint]>

        fileprivate init(
            root: PackageGraphRoot,
            dependencies: [(
                manifest: Manifest,
                dependency: ManagedDependency,
                productFilter: ProductFilter,
                fileSystem: FileSystem
            )],
            workspace: Workspace,
            observabilityScope: ObservabilityScope
        ) {
            self.root = root
            self.dependencies = dependencies
            self.workspace = workspace
            self.observabilityScope = observabilityScope
            self._dependencies = LoadableResult {
                try Self.computeDependencies(
                    root: root,
                    dependencies: dependencies,
                    workspace: workspace,
                    observabilityScope: observabilityScope
                )
            }
            self._constraints = LoadableResult {
                try Self.computeConstraints(
                    dependencies: dependencies,
                    workspace: workspace
                )
            }
        }

        /// Returns all manifests contained in DependencyManifests.
        public var allDependencyManifests: OrderedCollections.OrderedDictionary<
            PackageIdentity,
            (manifest: Manifest, fs: FileSystem)
        > {
            self.dependencies.reduce(into: OrderedCollections.OrderedDictionary<
                PackageIdentity,
                (manifest: Manifest, fs: FileSystem)
            >()) { partial, item in
                partial[item.dependency.packageRef.identity] = (item.manifest, item.fileSystem)
            }
        }

        /// Computes the identities which are declared in the manifests but aren't present in dependencies.
        public var missingPackages: [PackageReference] {
            get throws {
                try self._dependencies.load().missing.elements
            }
        }

        /// Computes the identities which are declared in the manifests but aren't present in dependencies.
        public var requiredPackages: [PackageReference] {
            get throws {
                try self._dependencies.load().required.elements
            }
        }

        /// Returns the list of packages which are allowed to vend products with unsafe flags.
        var unsafeAllowedPackages: Set<PackageReference> {
            var result = Set<PackageReference>()

            for dependency in self.dependencies {
                let dependency = dependency.dependency
                switch dependency.state {
                case .sourceControlCheckout(let checkout):
                    let packageRef = dependency.packageRef

                    if checkout.isBranchOrRevisionBased
                      // FIXME: Remove this once we have a general mechanism
                      //        for passing "safe" flags.
                      || packageRef.identity == .plain("swift-corelibs-foundation")
                    {
                      result.insert(packageRef)
                    }

                case .registryDownload, .edited, .providedLibrary, .custom:
                    continue
                case .fileSystem:
                    result.insert(dependency.packageRef)
                }
            }

            // Root packages are always allowed to use unsafe flags.
            result.formUnion(root.packageReferences)

            return result
        }

        private static func computeDependencies(
            root: PackageGraphRoot,
            dependencies: [(
                manifest: Manifest,
                dependency: ManagedDependency,
                productFilter: ProductFilter,
                fileSystem: FileSystem
            )],
            workspace: Workspace,
            observabilityScope: ObservabilityScope
        ) throws
            -> (
                required: OrderedCollections.OrderedSet<PackageReference>,
                missing: OrderedCollections.OrderedSet<PackageReference>
            )
        {
            let manifestsMap: [PackageIdentity: Manifest] = try Dictionary(
                throwingUniqueKeysWithValues:
                root.packages.map { ($0.key, $0.value.manifest) } +
                    dependencies.map {
                        ($0.dependency.packageRef.identity, $0.manifest)
                    }
            )

            let availableIdentities: Set<PackageReference> = try Set(manifestsMap.map {
                // FIXME: adding this guard to ensure refactoring is correct 9/21
                // we only care about remoteSourceControl for this validation. it would otherwise trigger for
                // a dependency is put into edit mode, which we want to deprecate anyways
                if case .remoteSourceControl = $0.1.packageKind {
                    let effectiveURL = workspace.mirrors.effective(for: $0.1.packageLocation)
                    guard effectiveURL == $0.1.packageKind.locationString else {
                        throw InternalError(
                            "effective url for \($0.1.packageLocation) is \(effectiveURL), different from expected \($0.1.packageKind.locationString)"
                        )
                    }
                }
                return PackageReference(identity: $0.key, kind: $0.1.packageKind)
            })

            var inputIdentities: OrderedCollections.OrderedSet<PackageReference> = []
            let inputNodes: [GraphLoadingNode] = try root.packages.map { identity, package in
                inputIdentities.append(package.reference)
                let node = try GraphLoadingNode(
                    identity: identity,
                    manifest: package.manifest,
                    productFilter: .everything,
                    // We are enabling all traits of the root packages in the workspace integration for now
                    enabledTraits: Set(package.manifest.traits.map { $0.name })
                )
                return node
            } + root.dependencies.compactMap { dependency in
                let package = dependency.packageRef
                inputIdentities.append(package)
                return try manifestsMap[dependency.identity].map { manifest in
                    try GraphLoadingNode(
                        identity: dependency.identity,
                        manifest: manifest,
                        productFilter: dependency.productFilter,
                        // We are enabling all traits of the root packages in the workspace integration for now
                        enabledTraits: Set(manifest.traits.map { $0.name })
                    )
                }
            }

            let topLevelDependencies = root.packages.flatMap { $1.manifest.dependencies.map(\.packageRef) }

            var requiredIdentities: OrderedCollections.OrderedSet<PackageReference> = []
            _ = try transitiveClosure(inputNodes) { node in
                try node.manifest.dependenciesRequired(for: node.productFilter).compactMap { dependency in
                    let package = dependency.packageRef
                    let (inserted, index) = requiredIdentities.append(package)
                    if !inserted {
                        let existing = requiredIdentities.elements[index]
                        // if identity already tracked, compare the locations and used the preferred variant
                        if existing.canonicalLocation == package.canonicalLocation {
                            // same literal location is fine
                            if existing.locationString != package.locationString {
                                // we prefer the top level dependencies
                                if topLevelDependencies.contains(where: {
                                    $0.locationString == existing.locationString
                                }) {
                                    observabilityScope.emit(debug: """
                                    similar variants of package '\(package.identity)' \
                                    found at '\(package.locationString)' and '\(existing.locationString)'. \
                                    using preferred root variant '\(existing.locationString)'
                                    """)
                                } else {
                                    let preferred = [existing, package].sorted(by: {
                                        $0.locationString > $1.locationString
                                    }).first! // safe
                                    observabilityScope.emit(debug: """
                                    similar variants of package '\(package.identity)' \
                                    found at '\(package.locationString)' and '\(existing.locationString)'. \
                                    using preferred variant '\(preferred.locationString)'
                                    """)
                                    if preferred.locationString != existing.locationString {
                                        requiredIdentities.remove(existing)
                                        requiredIdentities.insert(preferred, at: index)
                                    }
                                }
                            }
                        } else {
                            observabilityScope.emit(debug: """
                            '\(package.identity)' from '\(package.locationString)' was omitted \
                            from required dependencies because it has the same identity as the \
                            one from '\(existing.locationString)'
                            """)
                        }
                    }
                    return try manifestsMap[dependency.identity].map { manifest in
                        try GraphLoadingNode(
                            identity: dependency.identity,
                            manifest: manifest,
                            productFilter: dependency.productFilter,
                            // We are enabling all traits of the root packages in the workspace integration for now
                            enabledTraits: Set(manifest.traits.map { $0.name })
                        )
                    }
                }
            }
            requiredIdentities = inputIdentities.union(requiredIdentities)

            // We should never have loaded a manifest we don't need.
            assert(
                availableIdentities.isSubset(of: requiredIdentities),
                "\(availableIdentities) | \(requiredIdentities)"
            )
            // These are the missing package identities.
            let missingIdentities = requiredIdentities.subtracting(availableIdentities)

            return (requiredIdentities, missingIdentities)
        }

        /// Returns constraints of the dependencies, including edited package constraints.
        var dependencyConstraints: [PackageContainerConstraint] {
            get throws {
                try self._constraints.load()
            }
        }

        private static func computeConstraints(
            dependencies: [(
                manifest: Manifest,
                dependency: ManagedDependency,
                productFilter: ProductFilter,
                fileSystem: FileSystem
            )],
            workspace: Workspace
        ) throws -> [PackageContainerConstraint] {
            var allConstraints = [PackageContainerConstraint]()

            for (externalManifest, managedDependency, productFilter, _) in dependencies {
                // For edited packages, add a constraint with unversioned requirement so the
                // resolver doesn't try to resolve it.
                switch managedDependency.state {
                case .edited:
                    // FIXME: We shouldn't need to construct a new package reference object here.
                    // We should get the correct one from managed dependency object.
                    let ref = PackageReference.fileSystem(
                        identity: managedDependency.packageRef.identity,
                        path: workspace.path(to: managedDependency)
                    )
                    let constraint = PackageContainerConstraint(
                        package: ref,
                        requirement: .unversioned,
                        products: productFilter
                    )
                    allConstraints.append(constraint)
                case .sourceControlCheckout, .registryDownload, .fileSystem, .providedLibrary, .custom:
                    break
                }
                allConstraints += try externalManifest.dependencyConstraints(productFilter: productFilter)
            }
            return allConstraints
        }

        // FIXME: @testable(internal)
        /// Returns a list of constraints for all 'edited' package.
        public var editedPackagesConstraints: [PackageContainerConstraint] {
            var constraints = [PackageContainerConstraint]()

            for (_, managedDependency, productFilter, _) in dependencies {
                switch managedDependency.state {
                case .sourceControlCheckout, .registryDownload, .fileSystem, .providedLibrary, .custom: continue
                case .edited: break
                }
                // FIXME: We shouldn't need to construct a new package reference object here.
                // We should get the correct one from managed dependency object.
                let ref = PackageReference.fileSystem(
                    identity: managedDependency.packageRef.identity,
                    path: workspace.path(to: managedDependency)
                )
                let constraint = PackageContainerConstraint(
                    package: ref,
                    requirement: .unversioned,
                    products: productFilter
                )
                constraints.append(constraint)
            }
            return constraints
        }
    }

    /// Returns the location of the dependency.
    ///
    /// Source control dependencies will return the subpath inside `checkoutsPath` and
    /// Registry dependencies will return the subpath inside `registryDownloadsPath` and
    /// edited dependencies will either return a subpath inside `editablesPath` or
    /// a custom path.
    public func path(to dependency: Workspace.ManagedDependency) -> AbsolutePath {
        switch dependency.state {
        case .sourceControlCheckout:
            return self.location.repositoriesCheckoutSubdirectory(for: dependency)
        case .registryDownload:
            return self.location.registryDownloadSubdirectory(for: dependency)
        case .edited(_, let path):
            return path ?? self.location.editSubdirectory(for: dependency)
        case .fileSystem(let path):
            return path
        case .providedLibrary(let path, _):
            return path
        case .custom(_, let path):
            return path
        }
    }

    /// Returns manifest interpreter flags for a package.
    // TODO: should this be throwing instead?
    public func interpreterFlags(for packagePath: AbsolutePath) -> [String] {
        do {
            guard let manifestLoader = self.manifestLoader as? ManifestLoader else {
                throw StringError("unexpected manifest loader kind")
            }

            let manifestPath = try ManifestLoader.findManifest(
                packagePath: packagePath,
                fileSystem: self.fileSystem,
                currentToolsVersion: self.currentToolsVersion
            )
            let manifestToolsVersion = try ToolsVersionParser.parse(
                manifestPath: manifestPath,
                fileSystem: self.fileSystem
            )

            guard self.currentToolsVersion >= manifestToolsVersion || SwiftVersion.current.isDevelopment,
                  manifestToolsVersion >= ToolsVersion.minimumRequired
            else {
                throw StringError("invalid tools version")
            }
            return manifestLoader.interpreterFlags(for: manifestToolsVersion)
        } catch {
            // We ignore all failures here and return empty array.
            return []
        }
    }

    /// Load the manifests for the current dependency tree.
    ///
    /// This will load the manifests for the root package as well as all the
    /// current dependencies from the working checkouts.l
    public func loadDependencyManifests(
        root: PackageGraphRoot,
        automaticallyAddManagedDependencies: Bool = false,
        observabilityScope: ObservabilityScope
    ) async throws -> DependencyManifests {
        let prepopulateManagedDependencies: ([PackageReference]) throws -> Void = { refs in
            // pre-populate managed dependencies if we are asked to do so (this happens when resolving to a resolved
            // file)
            if automaticallyAddManagedDependencies {
                try refs.forEach { ref in
                    // Since we are creating managed dependencies based on the resolved file in this mode, but local
                    // packages aren't part of that file, they will be missing from it. So we're eagerly adding them
                    // here, but explicitly don't add any that are overridden by a root with the same identity since
                    // that would lead to loading the given package twice, once as a root and once as a dependency
                    // which violates various assumptions.
                    if case .fileSystem = ref.kind, !root.manifests.keys.contains(ref.identity) {
                        try self.state.dependencies.add(.fileSystem(packageRef: ref))
                    }
                }
                observabilityScope.trap { try self.state.save() }
            }
        }

        // Utility Just because a raw tuple cannot be hashable.
        struct Key: Hashable {
            let identity: PackageIdentity
            let productFilter: ProductFilter
        }

        // Make a copy of dependencies as we might mutate them in the for loop.
        let dependenciesToCheck = Array(self.state.dependencies)
        // Remove any managed dependency which has become a root.
        for dependency in dependenciesToCheck {
            if root.packages.keys.contains(dependency.packageRef.identity) {
                observabilityScope.makeChildScope(
                    description: "removing managed dependencies",
                    metadata: dependency.packageRef.diagnosticsMetadata
                ).trap {
                    try self.remove(package: dependency.packageRef)
                }
            }
        }

        // Validates that all the managed dependencies are still present in the file system.
        await self.fixManagedDependencies(
            observabilityScope: observabilityScope
        )
        guard !observabilityScope.errorsReported else {
            // return partial results
            return DependencyManifests(
                root: root,
                dependencies: [],
                workspace: self,
                observabilityScope: observabilityScope
            )
        }

        // Load root dependencies manifests (in parallel)
        let rootDependencies = root.dependencies.map(\.packageRef)
        try prepopulateManagedDependencies(rootDependencies)
        let rootDependenciesManifests = await self.loadManagedManifests(
            for: rootDependencies,
            observabilityScope: observabilityScope
        )

        let topLevelManifests = root.manifests.merging(rootDependenciesManifests, uniquingKeysWith: { lhs, _ in
            lhs // prefer roots!
        })

        // optimization: preload first level dependencies manifest (in parallel)
        let firstLevelDependencies = topLevelManifests.values.map { $0.dependencies.map(\.packageRef) }.flatMap { $0 }
        let firstLevelManifests = await self.loadManagedManifests(
            for: firstLevelDependencies,
            observabilityScope: observabilityScope
        )

        // Continue to load the rest of the manifest for this graph
        // Creates a map of loaded manifests. We do this to avoid reloading the shared nodes.
        var loadedManifests = firstLevelManifests
        let successorManifests: (KeyedPair<Manifest, Key>) async throws -> [KeyedPair<Manifest, Key>] = { pair in
            // optimization: preload manifest we know about in parallel
            let dependenciesRequired = pair.item.dependenciesRequired(for: pair.key.productFilter)
            let dependenciesToLoad = dependenciesRequired.map(\.packageRef)
                .filter { !loadedManifests.keys.contains($0.identity) }
            try prepopulateManagedDependencies(dependenciesToLoad)
            let dependenciesManifests = await self.loadManagedManifests(
                for: dependenciesToLoad,
                observabilityScope: observabilityScope
            )
            dependenciesManifests.forEach { loadedManifests[$0.key] = $0.value }
            return dependenciesRequired.compactMap { dependency in
                loadedManifests[dependency.identity].flatMap {
                    // we also compare the location as this function may attempt to load
                    // dependencies that have the same identity but from a different location
                    // which is an error case we diagnose an report about in the GraphLoading part which
                    // is prepared to handle the case where not all manifest are available
                    $0.canonicalPackageLocation == dependency.packageRef.canonicalLocation ?
                        KeyedPair(
                            $0,
                            key: Key(identity: dependency.identity, productFilter: dependency.productFilter)
                        ) :
                        nil
                }
            }
        }

        var allManifests = [(identity: PackageIdentity, manifest: Manifest, productFilter: ProductFilter)]()
        do {
            let manifestGraphRoots = topLevelManifests.map { identity, manifest in
                KeyedPair(
                    manifest,
                    key: Key(identity: identity, productFilter: .everything)
                )
            }

            var deduplication = [PackageIdentity: Int]()
            try await asyncDepthFirstSearch(
                manifestGraphRoots,
                successors: successorManifests
            ) { pair in
                deduplication[pair.key.identity] = allManifests.count
                allManifests.append((pair.key.identity, pair.item, pair.key.productFilter))
            } onDuplicate: { old, new in
                let index = deduplication[old.key.identity]!
                let productFilter = allManifests[index].productFilter.merge(new.key.productFilter)
                allManifests[index] = (new.key.identity, new.item, productFilter)
            }
        }

        let dependencyManifests = allManifests.filter { !root.manifests.values.contains($0.manifest) }

        // TODO: this check should go away when introducing explicit overrides
        // check for overrides attempts with same name but different path
        let rootManifestsByName = Array(root.manifests.values).spm_createDictionary { ($0.displayName, $0) }
        dependencyManifests.forEach { _, manifest, _ in
            if let override = rootManifestsByName[manifest.displayName],
               override.packageLocation != manifest.packageLocation
            {
                observabilityScope
                    .emit(
                        error: "unable to override package '\(manifest.displayName)' because its identity '\(PackageIdentity(urlString: manifest.packageLocation))' doesn't match override's identity (directory name) '\(PackageIdentity(urlString: override.packageLocation))'"
                    )
            }
        }

        let dependencies = try dependencyManifests.map { identity, manifest, productFilter -> (
            Manifest,
            ManagedDependency,
            ProductFilter,
            FileSystem
        ) in
            guard let dependency = self.state.dependencies[identity] else {
                throw InternalError("dependency not found for \(identity) at \(manifest.packageLocation)")
            }

            let packageRef = PackageReference(identity: identity, kind: manifest.packageKind)
            let fileSystem = try self.getFileSystem(
                package: packageRef,
                state: dependency.state,
                observabilityScope: observabilityScope
            )
            return (manifest, dependency, productFilter, fileSystem ?? self.fileSystem)
        }

        return DependencyManifests(
            root: root,
            dependencies: dependencies,
            workspace: self,
            observabilityScope: observabilityScope
        )
    }

    /// Loads the given manifests, if it is present in the managed dependencies.
    private func loadManagedManifests(
        for packages: [PackageReference],
        observabilityScope: ObservabilityScope
    ) async -> [PackageIdentity: Manifest] {
        await withTaskGroup(of: (identity: PackageIdentity, manifest: Manifest?).self) { group in
            var result = [PackageIdentity: Manifest]()

            for package in Set(packages) {
                group.addTask {
                    await (package.identity, self.loadManagedManifest(for: package, observabilityScope: observabilityScope))
                }
            }

            return await group.reduce(into: [:]) { dictionary, taskResult in
                dictionary[taskResult.identity] = taskResult.manifest
            }
        }
    }

    /// Loads the given manifest, if it is present in the managed dependencies.
    private func loadManagedManifest(
        for package: PackageReference,
        observabilityScope: ObservabilityScope
    ) async -> Manifest? {
        // Check if this dependency is available.
        // we also compare the location as this function may attempt to load
        // dependencies that have the same identity but from a different location
        // which is an error case we diagnose an report about in the GraphLoading part which
        // is prepared to handle the case where not all manifest are available
        guard let managedDependency = self.state.dependencies[comparingLocation: package] else {
            return nil
        }

        // Get the path of the package.
        let packagePath = self.path(to: managedDependency)

        // The kind and version, if known.
        let packageKind: PackageReference.Kind
        let packageVersion: Version?
        switch managedDependency.state {
        case .sourceControlCheckout(let checkoutState):
            packageKind = managedDependency.packageRef.kind
            switch checkoutState {
            case .version(let checkoutVersion, _):
                packageVersion = checkoutVersion
            default:
                packageVersion = .none
            }
        case .registryDownload(let downloadedVersion):
            packageKind = managedDependency.packageRef.kind
            packageVersion = downloadedVersion
        case .providedLibrary(let path, let version):
            let manifest: Manifest? = try? .forProvidedLibrary(
                fileSystem: fileSystem,
                package: managedDependency.packageRef,
                libraryPath: path,
                version: version
            )
            return manifest
        case .custom(let availableVersion, _):
            packageKind = managedDependency.packageRef.kind
            packageVersion = availableVersion
        case .edited, .fileSystem:
            packageKind = .fileSystem(packagePath)
            packageVersion = .none
        }

        let fileSystem: FileSystem?
        do {
            fileSystem = try self.getFileSystem(
                package: package,
                state: managedDependency.state,
                observabilityScope: observabilityScope
            )
        } catch {
            // only warn here in case of issues since we should not even get here without a valid package container
            observabilityScope.emit(
                warning: "unexpected failure while accessing custom package container",
                underlyingError: error
            )
            fileSystem = nil
        }

        // Load and return the manifest.
        return try? await self.loadManifest(
            packageIdentity: managedDependency.packageRef.identity,
            packageKind: packageKind,
            packagePath: packagePath,
            packageLocation: managedDependency.packageRef.locationString,
            packageVersion: packageVersion,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )
    }

    /// Load the manifest at a given path.
    ///
    /// This is just a helper wrapper to the manifest loader.
    func loadManifest(
        packageIdentity: PackageIdentity,
        packageKind: PackageReference.Kind,
        packagePath: AbsolutePath,
        packageLocation: String,
        packageVersion: Version? = nil,
        fileSystem: FileSystem? = nil,
        observabilityScope: ObservabilityScope
    ) async throws -> Manifest {
        let fileSystem = fileSystem ?? self.fileSystem

        // Load the manifest, bracketed by the calls to the delegate callbacks.
        delegate?.willLoadManifest(
            packageIdentity: packageIdentity,
            packagePath: packagePath,
            url: packageLocation,
            version: packageVersion,
            packageKind: packageKind
        )

        let manifestLoadingScope = observabilityScope.makeChildScope(description: "Loading manifest") {
            .packageMetadata(identity: packageIdentity, kind: packageKind)
        }

        var manifestLoadingDiagnostics = [Diagnostic]()

        let start = DispatchTime.now()
        let result: Result<Manifest, Error>
        do {
            let manifest = try await self.manifestLoader.load(
                packagePath: packagePath,
                packageIdentity: packageIdentity,
                packageKind: packageKind,
                packageLocation: packageLocation,
                packageVersion: packageVersion.map { (version: $0, revision: nil) },
                currentToolsVersion: self.currentToolsVersion,
                identityResolver: self.identityResolver,
                dependencyMapper: self.dependencyMapper,
                fileSystem: fileSystem,
                observabilityScope: manifestLoadingScope,
                delegateQueue: .sharedConcurrent,
                callbackQueue: .sharedConcurrent
            )
            let duration = start.distance(to: .now())
            let validator = ManifestValidator(
                manifest: manifest,
                sourceControlValidator: self.repositoryManager,
                fileSystem: self.fileSystem
            )
            let validationIssues = validator.validate()
            if !validationIssues.isEmpty {
                // Diagnostics.fatalError indicates that a more specific diagnostic has already been added.
                result = .failure(Diagnostics.fatalError)
                manifestLoadingDiagnostics.append(contentsOf: validationIssues)
            } else {
                result = .success(manifest)
            }
            self.delegate?.didLoadManifest(
                packageIdentity: packageIdentity,
                packagePath: packagePath,
                url: packageLocation,
                version: packageVersion,
                packageKind: packageKind,
                manifest: manifest,
                diagnostics: manifestLoadingDiagnostics,
                duration: duration
            )
        } catch {
            let duration = start.distance(to: .now())
            manifestLoadingDiagnostics.append(.error(error))
            self.delegate?.didLoadManifest(
                packageIdentity: packageIdentity,
                packagePath: packagePath,
                url: packageLocation,
                version: packageVersion,
                packageKind: packageKind,
                manifest: nil,
                diagnostics: manifestLoadingDiagnostics,
                duration: duration
            )
            result = .failure(error)
        }

        manifestLoadingScope.emit(manifestLoadingDiagnostics)
        return try result.get()
    }

    /// Validates that all the edited dependencies are still present in the file system.
    /// If some checkout dependency is removed form the file system, clone it again.
    /// If some edited dependency is removed from the file system, mark it as unedited and
    /// fallback on the original checkout.
    private func fixManagedDependencies(
        observabilityScope: ObservabilityScope
    ) async {
        // Reset managed dependencies if the state file was removed during the lifetime of the Workspace object.
        if !self.state.dependencies.isEmpty && !self.state.stateFileExists() {
            try? self.state.reset()
        }

        // Make a copy of dependencies as we might mutate them in the for loop.
        let allDependencies = Array(self.state.dependencies)
        for dependency in allDependencies {
            await observabilityScope.makeChildScope(
                description: "copying managed dependencies",
                metadata: dependency.packageRef.diagnosticsMetadata
            ).asyncTrap {
                // If the dependency is present, we're done.
                let dependencyPath = self.path(to: dependency)
                if fileSystem.isDirectory(dependencyPath) {
                    return
                }

                switch dependency.state {
                case .sourceControlCheckout(let checkoutState):
                    // If some checkout dependency has been removed, retrieve it again.
                    _ = try self.checkoutRepository(
                        package: dependency.packageRef,
                        at: checkoutState,
                        observabilityScope: observabilityScope
                    )
                    observabilityScope
                        .emit(.checkedOutDependencyMissing(packageName: dependency.packageRef.identity.description))

                case .registryDownload(let version):
                    // If some downloaded dependency has been removed, retrieve it again.
                    _ = try self.downloadRegistryArchive(
                        package: dependency.packageRef,
                        at: version,
                        observabilityScope: observabilityScope
                    )
                    observabilityScope
                        .emit(.registryDependencyMissing(packageName: dependency.packageRef.identity.description))

                case .custom(let version, let path):
                    let container = try temp_await {
                        self.packageContainerProvider.getContainer(
                            for: dependency.packageRef,
                            updateStrategy: .never,
                            observabilityScope: observabilityScope,
                            on: .sharedConcurrent,
                            completion: $0
                        )
                    }
                    if let customContainer = container as? CustomPackageContainer {
                        let newPath = try customContainer.retrieve(at: version, observabilityScope: observabilityScope)
                        observabilityScope
                            .emit(.customDependencyMissing(packageName: dependency.packageRef.identity.description))

                        // FIXME: We should be able to handle this case and also allow changed paths for registry and SCM downloads.
                        if newPath != path {
                            observabilityScope
                                .emit(error: "custom dependency was retrieved at a different path: \(newPath)")
                        }
                    } else {
                        observabilityScope.emit(error: "invalid custom dependency container: \(container)")
                    }
                case .edited:
                    // If some edited dependency has been removed, mark it as unedited.
                    //
                    // Note: We don't resolve the dependencies when unediting
                    // here because we expect this method to be called as part
                    // of some other resolve operation (i.e. resolve, update, etc).
                    try await self.unedit(
                        dependency: dependency,
                        forceRemove: true,
                        observabilityScope: observabilityScope
                    )

                    observabilityScope
                        .emit(.editedDependencyMissing(packageName: dependency.packageRef.identity.description))

                case .providedLibrary(_, version: _):
                    // TODO: If the dependency is not available we can turn it into a source control dependency
                    break

                case .fileSystem:
                    self.state.dependencies.remove(dependency.packageRef.identity)
                    try self.state.save()
                }
            }
        }
    }

    private func getFileSystem(
        package: PackageReference,
        state: Workspace.ManagedDependency.State,
        observabilityScope: ObservabilityScope
    ) throws -> FileSystem? {
        // Only custom containers may provide a file system.
        guard self.customPackageContainerProvider != nil else {
            return nil
        }

        switch state {
        // File-system based dependencies do not provide a custom file system object.
        case .fileSystem:
            return nil
        case .custom:
            let container = try temp_await {
                self.packageContainerProvider.getContainer(
                    for: package,
                    updateStrategy: .never,
                    observabilityScope: observabilityScope,
                    on: .sharedConcurrent,
                    completion: $0
                )
            }
            guard let customContainer = container as? CustomPackageContainer else {
                observabilityScope.emit(error: "invalid custom dependency container: \(container)")
                return nil
            }
            return try customContainer.getFileSystem()
        default:
            observabilityScope.emit(error: "invalid managed dependency state for custom dependency: \(state)")
            return nil
        }
    }
}
