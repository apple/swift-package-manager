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

import Basics
import OrderedCollections
import PackageLoading
import PackageModel

import struct TSCBasic.KeyedPair
import func TSCBasic.bestMatch
import func TSCBasic.findCycle

extension ModulesGraph {
    /// Load the package graph for the given package path.
    public static func load(
        root: PackageGraphRoot,
        identityResolver: IdentityResolver,
        additionalFileRules: [FileRuleDescription] = [],
        externalManifests: OrderedCollections.OrderedDictionary<PackageIdentity, (manifest: Manifest, fs: FileSystem)>,
        requiredDependencies: [PackageReference] = [],
        unsafeAllowedPackages: Set<PackageReference> = [],
        binaryArtifacts: [PackageIdentity: [String: BinaryArtifact]],
        shouldCreateMultipleTestProducts: Bool = false,
        createREPLProduct: Bool = false,
        customPlatformsRegistry: PlatformRegistry? = .none,
        customXCTestMinimumDeploymentTargets: [PackageModel.Platform: PlatformVersion]? = .none,
        testEntryPointPath: AbsolutePath? = nil,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> ModulesGraph {
        try Self.load(
            root: root,
            identityResolver: identityResolver,
            additionalFileRules: additionalFileRules,
            externalManifests: externalManifests,
            requiredDependencies: requiredDependencies,
            unsafeAllowedPackages: unsafeAllowedPackages,
            binaryArtifacts: binaryArtifacts,
            shouldCreateMultipleTestProducts: shouldCreateMultipleTestProducts,
            createREPLProduct: createREPLProduct,
            traitConfiguration: nil,
            customPlatformsRegistry: customPlatformsRegistry,
            customXCTestMinimumDeploymentTargets: customXCTestMinimumDeploymentTargets,
            testEntryPointPath: testEntryPointPath,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )
    }

    /// Load the package graph for the given package path.
    package static func load(
        root: PackageGraphRoot,
        identityResolver: IdentityResolver,
        additionalFileRules: [FileRuleDescription] = [],
        externalManifests: OrderedCollections.OrderedDictionary<PackageIdentity, (manifest: Manifest, fs: FileSystem)>,
        requiredDependencies: [PackageReference] = [],
        unsafeAllowedPackages: Set<PackageReference> = [],
        binaryArtifacts: [PackageIdentity: [String: BinaryArtifact]],
        shouldCreateMultipleTestProducts: Bool = false,
        createREPLProduct: Bool = false,
        traitConfiguration: TraitConfiguration? = nil,
        customPlatformsRegistry: PlatformRegistry? = .none,
        customXCTestMinimumDeploymentTargets: [PackageModel.Platform: PlatformVersion]? = .none,
        testEntryPointPath: AbsolutePath? = nil,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> ModulesGraph {
        let observabilityScope = observabilityScope.makeChildScope(description: "Loading Package Graph")

        // Create a map of the manifests, keyed by their identity.
        var manifestMap = externalManifests
        // prefer roots
        root.manifests.forEach {
            manifestMap[$0.key] = ($0.value, fileSystem)
        }

        // Construct the root root dependencies set.
        let rootDependencies = Set(root.dependencies.compactMap{
            manifestMap[$0.identity]?.manifest
        })

        let rootManifestNodes = try root.packages.map { identity, package in
            // If we have enabled traits passed then we start with those. If there are no enabled
            // traits passed then the default traits will be used.
            var enabledTraits = traitConfiguration?.enabledTraits

            // If all traits should be enabled we just get the set of all traits of the package
            if traitConfiguration?.enableAllTraits ?? false {
                enabledTraits = Set(package.manifest.traits.map { $0.name })
            }

            return try GraphLoadingNode(
                identity: identity,
                manifest: package.manifest,
                productFilter: .everything,
                enabledTraits: calculateEnabledTraits(
                    identity: identity,
                    manifest: package.manifest,
                    explictlyEnabledTraits: enabledTraits
                )
            )
        }
        let rootDependencyNodes = try root.dependencies.lazy.compactMap { dependency in
            try manifestMap[dependency.identity].map {
                try GraphLoadingNode(
                    identity: dependency.identity,
                    manifest: $0.manifest,
                    productFilter: dependency.productFilter,
                    enabledTraits: []
                )
            }
        }
        let inputManifests = (rootManifestNodes + rootDependencyNodes).map {
            KeyedPair($0, key: $0.identity)
        }

        // Collect the manifests for which we are going to build packages.
        var allNodes = OrderedDictionary<PackageIdentity, GraphLoadingNode>()

        let nodeSuccessorProvider = { (node: KeyedPair<GraphLoadingNode, PackageIdentity>) in
            return try node.item.requiredDependencies.compactMap { dependency in
                return try manifestMap[dependency.identity].map { manifest, _ in
                    // We are going to check the conditionally enabled traits here and enable them if
                    // required. This checks the current node and then enables the conditional
                    // dependencies of the dependency node.
                    let explictlyEnabledTraits = dependency.traits?.filter {
                        guard let conditionTraits = $0.condition?.traits else {
                            return true
                        }
                        return !conditionTraits.intersection(node.item.enabledTraits).isEmpty
                    }.map { $0.name }

                    return try KeyedPair(
                            GraphLoadingNode(
                                identity: dependency.identity,
                                manifest: manifest,
                                productFilter: dependency.productFilter,
                                enabledTraits: calculateEnabledTraits(
                                    identity: dependency.identity,
                                    manifest: manifest,
                                    explictlyEnabledTraits: explictlyEnabledTraits.flatMap { Set($0) }
                                )
                            ),
                            key: dependency.identity
                        )
                }
            }
        }

        // Package dependency cycles feature is gated on tools version 6.0.
        if !root.manifests.allSatisfy({ $1.toolsVersion >= .v6_0 }) {
            if let cycle = try findCycle(inputManifests, successors: nodeSuccessorProvider) {
                let path = (cycle.path + cycle.cycle).map(\.item.manifest)
                observabilityScope.emit(PackageGraphError.dependencyCycleDetected(
                    path: path, cycle: cycle.cycle[0].item.manifest
                ))

                return try ModulesGraph(
                    rootPackages: [],
                    rootDependencies: [],
                    packages: IdentifiableSet(),
                    dependencies: requiredDependencies,
                    binaryArtifacts: binaryArtifacts
                )
            }
        }

        // Cycles in dependencies don't matter as long as there are no module cycles between packages.
        try depthFirstSearch(
            inputManifests,
            successors: nodeSuccessorProvider
        ) {
            allNodes[$0.key] = $0.item
        } onDuplicate: { first, second in
            // We are unifying the enabled traits on duplicate
            allNodes[first.key]?.enabledTraits.formUnion(second.item.enabledTraits)
        }

        // Create the packages.
        var manifestToPackage: [Manifest: Package] = [:]
        for node in allNodes.values {
            let nodeObservabilityScope = observabilityScope.makeChildScope(
                description: "loading package \(node.identity)",
                metadata: .packageMetadata(identity: node.identity, kind: node.manifest.packageKind)
            )

            let manifest = node.manifest
            // Derive the path to the package.
            //
            // FIXME: Lift this out of the manifest.
            let packagePath = manifest.path.parentDirectory
            nodeObservabilityScope.trap {
                // Create a package from the manifest and sources.
                let builder = PackageBuilder(
                    identity: node.identity,
                    manifest: manifest,
                    productFilter: node.productFilter,
                    path: packagePath,
                    additionalFileRules: additionalFileRules,
                    binaryArtifacts: binaryArtifacts[node.identity] ?? [:],                
                    shouldCreateMultipleTestProducts: shouldCreateMultipleTestProducts,
                    testEntryPointPath: testEntryPointPath,
                    createREPLProduct: manifest.packageKind.isRoot ? createREPLProduct : false,
                    fileSystem: fileSystem,
                    observabilityScope: nodeObservabilityScope,
                    enabledTraits: node.enabledTraits
                )
                let package = try builder.construct()
                manifestToPackage[manifest] = package

                // Throw if any of the non-root package is empty.
                if package.modules.isEmpty // System packages have modules in the package but not the manifest.
                    && package.manifest.targets.isEmpty // An unneeded dependency will not have loaded anything from the manifest.
                    && !manifest.packageKind.isRoot {
                    throw PackageGraphError.noModules(package)
                }
            }
        }

        let platformVersionProvider: PlatformVersionProvider
        if let customXCTestMinimumDeploymentTargets {
            platformVersionProvider = .init(implementation: .customXCTestMinimumDeploymentTargets(customXCTestMinimumDeploymentTargets))
        } else {
            platformVersionProvider = .init(implementation: .minimumDeploymentTargetDefault)
        }

        // Resolve dependencies and create resolved packages.
        let resolvedPackages = try createResolvedPackages(
            nodes: Array(allNodes.values),
            identityResolver: identityResolver,
            manifestToPackage: manifestToPackage,
            rootManifests: root.manifests,
            unsafeAllowedPackages: unsafeAllowedPackages,
            platformRegistry: customPlatformsRegistry ?? .default,
            platformVersionProvider: platformVersionProvider,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )

        let rootPackages = resolvedPackages.filter { root.manifests.values.contains($0.manifest) }
        checkAllDependenciesAreUsed(packages: resolvedPackages, rootPackages, observabilityScope: observabilityScope)

        return try ModulesGraph(
            rootPackages: rootPackages,
            rootDependencies: resolvedPackages.filter { rootDependencies.contains($0.manifest) },
            packages: resolvedPackages,
            dependencies: requiredDependencies,
            binaryArtifacts: binaryArtifacts
        )
    }
}

private func checkAllDependenciesAreUsed(
    packages: IdentifiableSet<ResolvedPackage>,
    _ rootPackages: [ResolvedPackage],
    observabilityScope: ObservabilityScope
) {
    for package in rootPackages {
        // List all dependency products dependent on by the package modules.
        let productDependencies = IdentifiableSet(package.modules.flatMap { module in
            return module.dependencies.compactMap { moduleDependency in
                switch moduleDependency {
                case .product(let product, _):
                    return product
                case .module:
                    return nil
                }
            }
        })

        // List all dependencies of modules that are guarded by a trait.
        let traitGuardedProductDependencies = Set(package.underlying.modules.flatMap { module in
            module.dependencies.compactMap { moduleDependency in
                switch moduleDependency {
                case .product(let product, let conditions):
                    if conditions.contains(where: { $0.traitCondition != nil }) {
                        // This is a product dependency that was enabled by a trait
                        return product.name
                    }
                    return nil
                case .module:
                    return nil
                }
            }
        })

        for dependencyId in package.dependencies {
            guard let dependency = packages[dependencyId] else {
                observabilityScope.emit(.error("Unknown package: \(dependencyId)"))
                return
            }

            // We continue if the dependency contains executable products to make sure we don't
            // warn on a valid use-case for a lone dependency: swift run dependency executables.
            guard !dependency.products.contains(where: { $0.type == .executable }) else {
                continue
            }
            // Skip this check if this dependency is a system module because system module packages
            // have no products.
            //
            // FIXME: Do/should we print a warning if a dependency has no products?
            if dependency.products.isEmpty && dependency.modules.filter({ $0.type == .systemModule }).count == 1 {
                continue
            }

            // Skip this check if this dependency contains a command plugin product.
            if dependency.products.contains(where: \.isCommandPlugin) {
                continue
            }

            // Skip this check if traits are enabled since it is valid to add a dependency just
            // to enable traits on it. This is useful if there is a transitive dependency in the graph
            // that can be configured by enabling traits e.g. the depdency has a trait for its logging
            // behaviour. This allows the root package to configure traits of transitive dependencies
            // without emitting an unused dependency warning.
            if !dependency.enabledTraits.isEmpty {
                continue
            }

            // Make sure that any diagnostics we emit below are associated with the package.
            let packageDiagnosticsScope = observabilityScope.makeChildScope(
                description: "Package Dependency Validation",
                metadata: package.underlying.diagnosticsMetadata
            )

            // Otherwise emit a warning if none of the dependency package's products are used.
            let dependencyIsUsed = dependency.products.contains { product in
                // Don't compare by product ID, but by product name to make sure both build triples as properties of
                // `ResolvedProduct.ID` are allowed.
                let usedByPackage = productDependencies.contains { $0.name == product.name }
                // We check if any of the products of this dependency is guarded by a trait.
                let traitGuarded = traitGuardedProductDependencies.contains(product.name)

                // If the product is either used directly or guarded by a trait we consider it as used
                return usedByPackage || traitGuarded
            }

            if !dependencyIsUsed && !observabilityScope.errorsReportedInAnyScope {
                packageDiagnosticsScope.emit(.unusedDependency(dependency.identity.description))
            }
        }
    }
}

fileprivate extension ResolvedProduct {
    /// Returns true if and only if the product represents a command plugin module.
    var isCommandPlugin: Bool {
        guard type == .plugin else { return false }
        guard let module = underlying.modules.compactMap({ $0 as? PluginModule }).first else { return false }
        guard case .command = module.capability else { return false }
        return true
    }
}

/// Create resolved packages from the loaded packages.
private func createResolvedPackages(
    nodes: [GraphLoadingNode],
    identityResolver: IdentityResolver,
    manifestToPackage: [Manifest: Package],
    // FIXME: This shouldn't be needed once <rdar://problem/33693433> is fixed.
    rootManifests: [PackageIdentity: Manifest],
    unsafeAllowedPackages: Set<PackageReference>,
    platformRegistry: PlatformRegistry,
    platformVersionProvider: PlatformVersionProvider,
    fileSystem: FileSystem,
    observabilityScope: ObservabilityScope
) throws -> IdentifiableSet<ResolvedPackage> {

    // Create package builder objects from the input manifests.
    let packageBuilders: [ResolvedPackageBuilder] = nodes.compactMap { node in
        guard let package = manifestToPackage[node.manifest] else {
            return nil
        }
        let isAllowedToVendUnsafeProducts = unsafeAllowedPackages.contains{ $0.identity == package.identity }
        
        let allowedToOverride = rootManifests.values.contains(node.manifest)
        return ResolvedPackageBuilder(
            package,
            productFilter: node.productFilter,
            enabledTraits: node.enabledTraits,
            isAllowedToVendUnsafeProducts: isAllowedToVendUnsafeProducts,
            allowedToOverride: allowedToOverride,
            platformVersionProvider: platformVersionProvider
        )
    }

    // Create a map of package builders keyed by the package identity.
    // This is guaranteed to be unique so we can use spm_createDictionary
    let packagesByIdentity: [PackageIdentity: ResolvedPackageBuilder] = packageBuilders.spm_createDictionary{
        return ($0.package.identity, $0)
    }

    // Resolve module aliases, if specified, for modules and their dependencies
    // across packages. Aliasing will result in module renaming.
    let moduleAliasingUsed = try resolveModuleAliases(
        packageBuilders: packageBuilders,
        observabilityScope: observabilityScope
    )

    // Scan and validate the dependencies
    for packageBuilder in packageBuilders {
        let package = packageBuilder.package

        let packageObservabilityScope = observabilityScope.makeChildScope(
            description: "Validating package dependencies",
            metadata: package.diagnosticsMetadata
        )
        
        var dependencies = OrderedCollections.OrderedDictionary<PackageIdentity, ResolvedPackageBuilder>()
        var dependenciesByNameForModuleDependencyResolution = [String: ResolvedPackageBuilder]()
        var dependencyNamesForModuleDependencyResolutionOnly = [PackageIdentity: String]()

        package.manifest.dependenciesRequired(
            for: packageBuilder.productFilter
        ).forEach { dependency in
            let dependencyPackageRef = dependency.packageRef

            // Otherwise, look it up by its identity.
            if let resolvedPackage = packagesByIdentity[dependency.identity] {
                // check if this resolved package already listed in the dependencies
                // this means that the dependencies share the same identity
                // FIXME: this works but the way we find out about this is based on a side effect, need to improve it
                guard dependencies[resolvedPackage.package.identity] == nil else {
                    let error = PackageGraphError.dependencyAlreadySatisfiedByIdentifier(
                        package: package.identity.description,
                        dependencyLocation: dependencyPackageRef.locationString,
                        otherDependencyURL: resolvedPackage.package.manifest.packageLocation,
                        identity: dependency.identity)
                    return packageObservabilityScope.emit(error)
                }

                // check if the resolved package location is the same as the dependency one
                // if not, this means that the dependencies share the same identity
                // which only allowed when overriding
                if resolvedPackage.package.manifest.canonicalPackageLocation != dependencyPackageRef.canonicalLocation && !resolvedPackage.allowedToOverride {
                    let error = PackageGraphError.dependencyAlreadySatisfiedByIdentifier(
                        package: package.identity.description,
                        dependencyLocation: dependencyPackageRef.locationString,
                        otherDependencyURL: resolvedPackage.package.manifest.packageLocation,
                        identity: dependency.identity)
                    // 9/2021 this is currently emitting a warning only to support
                    // backwards compatibility with older versions of SwiftPM that had too weak of a validation
                    // we will upgrade this to an error in a few versions to tighten up the validation
                    if dependency.explicitNameForModuleDependencyResolutionOnly == .none ||
                        resolvedPackage.package.manifest.displayName == dependency.explicitNameForModuleDependencyResolutionOnly {
                        packageObservabilityScope.emit(warning: error.description + ". this will be escalated to an error in future versions of SwiftPM.")
                    } else {
                        return packageObservabilityScope.emit(error)
                    }
                } else if resolvedPackage.package.manifest.canonicalPackageLocation == dependencyPackageRef.canonicalLocation &&
                            resolvedPackage.package.manifest.packageLocation != dependencyPackageRef.locationString  &&
                            !resolvedPackage.allowedToOverride {
                    packageObservabilityScope.emit(info: "dependency on '\(resolvedPackage.package.identity)' is represented by similar locations ('\(resolvedPackage.package.manifest.packageLocation)' and '\(dependencyPackageRef.locationString)') which are treated as the same canonical location '\(dependencyPackageRef.canonicalLocation)'.")
                }

                // checks if two dependencies have the same explicit name which can cause module based dependency package lookup issue
                if let explicitDependencyName = dependency.explicitNameForModuleDependencyResolutionOnly {
                    if let previouslyResolvedPackage = dependenciesByNameForModuleDependencyResolution[explicitDependencyName] {
                        let error = PackageGraphError.dependencyAlreadySatisfiedByName(
                            package: package.identity.description,
                            dependencyLocation: dependencyPackageRef.locationString,
                            otherDependencyURL: previouslyResolvedPackage.package.manifest.packageLocation,
                            name: explicitDependencyName)
                        return packageObservabilityScope.emit(error)
                    }
                }

                // checks if two dependencies have the same implicit (identity based) name which can cause module based dependency package lookup issue
                if let previouslyResolvedPackage = dependenciesByNameForModuleDependencyResolution[dependency.identity.description] {
                    let error = PackageGraphError.dependencyAlreadySatisfiedByName(
                        package: package.identity.description,
                        dependencyLocation: dependencyPackageRef.locationString,
                        otherDependencyURL: previouslyResolvedPackage.package.manifest.packageLocation,
                        name: dependency.identity.description)
                    return packageObservabilityScope.emit(error)
                }

                let nameForModuleDependencyResolution = dependency.explicitNameForModuleDependencyResolutionOnly ?? dependency.identity.description
                dependenciesByNameForModuleDependencyResolution[nameForModuleDependencyResolution] = resolvedPackage
                dependencyNamesForModuleDependencyResolutionOnly[resolvedPackage.package.identity] = nameForModuleDependencyResolution

                dependencies[resolvedPackage.package.identity] = resolvedPackage
            }
        }

        packageBuilder.dependencies = Array(dependencies.values)
        packageBuilder.dependencyNamesForModuleDependencyResolutionOnly = dependencyNamesForModuleDependencyResolutionOnly

        packageBuilder.defaultLocalization = package.manifest.defaultLocalization

        packageBuilder.supportedPlatforms = computePlatforms(
            package: package,
            platformRegistry: platformRegistry
        )

        // Create module builders for each module in the package.
        let moduleBuilders = package.modules.map {
            ResolvedModuleBuilder(
                packageIdentity: package.identity,
                module: $0,
                observabilityScope: packageObservabilityScope,
                platformVersionProvider: platformVersionProvider
            )
        }
        packageBuilder.modules = moduleBuilders

        // Establish dependencies between the modules. A module can only depend on another module present in the same package.
        let modulesMap = moduleBuilders.spm_createDictionary({ ($0.module, $0) })
        for moduleBuilder in moduleBuilders {
            moduleBuilder.dependencies += try moduleBuilder.module.dependencies.compactMap { dependency in
                switch dependency {
                case .module(let moduleDependency, let conditions):
                    try moduleBuilder.module.validateDependency(module: moduleDependency)
                    guard let moduleBuilder = modulesMap[moduleDependency] else {
                        throw InternalError("unknown target \(moduleDependency.name)")
                    }
                    return .module(moduleBuilder, conditions: conditions)
                case .product:
                    return nil
                }
            }
            moduleBuilder.defaultLocalization = packageBuilder.defaultLocalization
            moduleBuilder.supportedPlatforms = packageBuilder.supportedPlatforms
        }

        // Create product builders for each product in the package. A product can only contain a module present in the same package.
        packageBuilder.products = try package.products.map{
            try ResolvedProductBuilder(product: $0, packageBuilder: packageBuilder, moduleBuilders: $0.modules.map {
                guard let module = modulesMap[$0] else {
                    throw InternalError("unknown target \($0)")
                }
                return module
            })
        }

        // add registry metadata if available
        if fileSystem.exists(package.path.appending(component: RegistryReleaseMetadataStorage.fileName)) {
            packageBuilder.registryMetadata = try RegistryReleaseMetadataStorage.load(
                from: package.path.appending(component: RegistryReleaseMetadataStorage.fileName),
                fileSystem: fileSystem
            )
        }
    }

    let dupProductsChecker = DuplicateProductsChecker(
        packageBuilders: packageBuilders,
        moduleAliasingUsed: moduleAliasingUsed,
        observabilityScope: observabilityScope
    )
    try dupProductsChecker.run(lookupByProductIDs: moduleAliasingUsed, observabilityScope: observabilityScope)

    // The set of all module names.
    var allModuleNames = Set<String>()

    // Track if multiple modules are found with the same name.
    var foundDuplicateModule = false

    for packageBuilder in packageBuilders {
        for moduleBuilder in packageBuilder.modules {
            // Record if we see a duplicate module.
            foundDuplicateModule = foundDuplicateModule || !allModuleNames.insert(moduleBuilder.module.name).inserted
        }
    }

    // Do another pass and establish product dependencies of each module.
    for packageBuilder in packageBuilders {
        let package = packageBuilder.package

        let packageObservabilityScope = observabilityScope.makeChildScope(
            description: "Validating package targets",
            metadata: package.diagnosticsMetadata
        )

        // Get all implicit system library dependencies in this package.
        let implicitSystemLibraryDeps = packageBuilder.dependencies
            .flatMap(\.modules)
            .filter({
                if case let systemLibrary as SystemLibraryModule = $0.module {
                    return systemLibrary.isImplicit
                }
                return false
            })

        let packageDoesNotSupportProductAliases = packageBuilder.package.doesNotSupportProductAliases
        let lookupByProductIDs = !packageDoesNotSupportProductAliases && (packageBuilder.package.manifest.disambiguateByProductIDs || moduleAliasingUsed)

        // Get all the products from dependencies of this package.
        let productDependencies = packageBuilder.dependencies
            .flatMap({ (dependency: ResolvedPackageBuilder) -> [ResolvedProductBuilder] in
                // Filter out synthesized products such as tests and implicit executables.
                // Check if a dependency product is explicitly declared as a product in its package manifest
                let manifestProducts = dependency.package.manifest.products.lazy.map { $0.name }
                let explicitProducts = dependency.package.products.filter { manifestProducts.contains($0.name) }
                let explicitIdsOrNames = Set(explicitProducts.lazy.map({ lookupByProductIDs ? $0.identity : $0.name }))
                return dependency.products.filter({ lookupByProductIDs ? explicitIdsOrNames.contains($0.product.identity) : explicitIdsOrNames.contains($0.product.name) })
            })

        let productDependencyMap: [String: ResolvedProductBuilder]
        if lookupByProductIDs {
            productDependencyMap = try Dictionary(uniqueKeysWithValues: productDependencies.map {
                guard let packageName = packageBuilder.dependencyNamesForModuleDependencyResolutionOnly[$0.packageBuilder.package.identity] else {
                    throw InternalError("could not determine name for dependency on package '\($0.packageBuilder.package.identity)' from package '\(packageBuilder.package.identity)'")
                }
                let key = "\(packageName.lowercased())_\($0.product.name)"
                return (key, $0)
            })
        } else {
            productDependencyMap = try Dictionary(
                productDependencies.map { ($0.product.name, $0) },
                uniquingKeysWith: { lhs, _ in
                    let duplicates = productDependencies.filter { $0.product.name == lhs.product.name }
                    throw emitDuplicateProductDiagnostic(
                        productName: lhs.product.name,
                        packages: duplicates.map(\.packageBuilder.package),
                        moduleAliasingUsed: moduleAliasingUsed,
                        observabilityScope: observabilityScope
                    )
                }
            )
        }

        // Establish dependencies in each module.
        for moduleBuilder in packageBuilder.modules {
            // Directly add all the system module dependencies.
            moduleBuilder.dependencies += implicitSystemLibraryDeps.map { .module($0, conditions: []) }

            // Establish product dependencies.
            for case .product(let productRef, let conditions) in moduleBuilder.module.dependencies {
                if let traitCondition = conditions.compactMap({ $0.traitCondition }).first {
                    if packageBuilder.enabledTraits.intersection(traitCondition.traits).isEmpty {
                        ///  If we land here non of the traits required to enable this depenendcy has been enabled.
                        continue
                    }
                }

                // Find the product in this package's dependency products.
                // Look it up by ID if module aliasing is used, otherwise by name.
                let product = lookupByProductIDs ? productDependencyMap[productRef.identity] : productDependencyMap[productRef.name]
                guard let product else {
                    // Only emit a diagnostic if there are no other diagnostics.
                    // This avoids flooding the diagnostics with product not
                    // found errors when there are more important errors to
                    // resolve (like authentication issues).
                    if !observabilityScope.errorsReportedInAnyScope {
                        // Emit error if a product (not module) declared in the package is also a productRef (dependency)
                        let declProductsAsDependency = package.products.filter { product in
                            lookupByProductIDs ? product.identity == productRef.identity : product.name == productRef.name
                        }.map {$0.modules}.flatMap{$0}.filter { t in
                            t.name != productRef.name
                        }

                        // Find a product name from the available product dependencies that is most similar to the required product name.
                        let bestMatchedProductName = bestMatch(for: productRef.name, from: Array(allModuleNames))
                        var packageContainingBestMatchedProduct: String?
                        if let bestMatchedProductName, productRef.name == bestMatchedProductName {
                            let dependentPackages = packageBuilder.dependencies.map(\.package)
                            for p in dependentPackages where p.modules.contains(where: { $0.name == bestMatchedProductName }) {
                                packageContainingBestMatchedProduct = p.identity.description
                                break
                            }
                        }
                        let error = PackageGraphError.productDependencyNotFound(
                            package: package.identity.description,
                            moduleName: moduleBuilder.module.name,
                            dependencyProductName: productRef.name,
                            dependencyPackageName: productRef.package,
                            dependencyProductInDecl: !declProductsAsDependency.isEmpty,
                            similarProductName: bestMatchedProductName,
                            packageContainingSimilarProduct: packageContainingBestMatchedProduct
                        )
                        packageObservabilityScope.emit(error)
                    }
                    continue
                }

                // Starting in 5.2, and module-based dependency, we require module product dependencies to
                // explicitly reference the package containing the product, or for the product, package and
                // dependency to share the same name. We don't check this in manifest loading for root-packages so
                // we can provide a more detailed diagnostic here.
                if packageBuilder.package.manifest.toolsVersion >= .v5_2 && productRef.package == nil {
                    let referencedPackageIdentity = product.packageBuilder.package.identity
                    guard let referencedPackageDependency = (packageBuilder.package.manifest.dependencies.first { package in
                        return package.identity == referencedPackageIdentity
                    }) else {
                        throw InternalError("dependency reference for \(product.packageBuilder.package.manifest.packageLocation) not found")
                    }
                    let referencedPackageName = referencedPackageDependency.nameForModuleDependencyResolutionOnly
                    if productRef.name != referencedPackageName {
                        let error = PackageGraphError.productDependencyMissingPackage(
                            productName: productRef.name,
                            moduleName: moduleBuilder.module.name,
                            packageIdentifier: referencedPackageName
                        )
                        packageObservabilityScope.emit(error)
                    }
                }

                moduleBuilder.dependencies.append(.product(product, conditions: conditions))
            }
        }
    }

    // If a module with similar name was encountered before, we emit a diagnostic.
    if foundDuplicateModule {
        var duplicateModules = [String: [Package]]()
        for moduleName in Set(allModuleNames).sorted() {
            let packages = packageBuilders
                .filter({ $0.modules.contains(where: { $0.module.name == moduleName }) })
                .map{ $0.package }
            if packages.count > 1 {
                duplicateModules[moduleName, default: []].append(contentsOf: packages)
            }
        }

        var potentiallyDuplicatePackages = [Pair: [String]]()
        for entry in duplicateModules {
            // the duplicate is across exactly two packages
            if entry.value.count == 2 {
                potentiallyDuplicatePackages[Pair(package1: entry.value[0], package2: entry.value[1]), default: []].append(entry.key)
            }
        }

        var duplicateModulesAddressed = [String]()
        for potentiallyDuplicatePackage in potentiallyDuplicatePackages {
            // more than three module matches, or all modules in the package match
            if potentiallyDuplicatePackage.value.count > 3 ||
                (potentiallyDuplicatePackage.value.sorted() == potentiallyDuplicatePackage.key.package1.modules.map({ $0.name }).sorted()
                &&
                potentiallyDuplicatePackage.value.sorted() == potentiallyDuplicatePackage.key.package2.modules.map({ $0.name }).sorted())
            {
                switch (potentiallyDuplicatePackage.key.package1.identity.registry, potentiallyDuplicatePackage.key.package2.identity.registry) {
                case (.some(let registryIdentity), .none):
                    observabilityScope.emit(
                        ModuleError.duplicateModulesScmAndRegistry(
                            registryPackage: registryIdentity,
                            scmPackage: potentiallyDuplicatePackage.key.package2.identity,
                            modules: potentiallyDuplicatePackage.value
                        )
                    )
                case (.none, .some(let registryIdentity)):
                    observabilityScope.emit(
                        ModuleError.duplicateModulesScmAndRegistry(
                            registryPackage: registryIdentity,
                            scmPackage: potentiallyDuplicatePackage.key.package1.identity,
                            modules: potentiallyDuplicatePackage.value
                        )
                    )
                default:
                    observabilityScope.emit(
                        ModuleError.duplicateModules(
                            package: potentiallyDuplicatePackage.key.package1.identity,
                            otherPackage: potentiallyDuplicatePackage.key.package2.identity,
                            modules: potentiallyDuplicatePackage.value
                        )
                    )
                }
                duplicateModulesAddressed += potentiallyDuplicatePackage.value
            }
        }

        for entry in duplicateModules.filter({ !duplicateModulesAddressed.contains($0.key) }) {
            observabilityScope.emit(
                ModuleError.duplicateModule(
                    moduleName: entry.key,
                    packages: entry.value.map { $0.identity })
            )
        }
    }

    do {
        let moduleBuilders = packageBuilders.flatMap {
            $0.modules.map {
                KeyedPair($0, key: $0.module)
            }
        }
        if let cycle = findCycle(moduleBuilders, successors: {
            $0.item.dependencies.flatMap {
                switch $0 {
                case .product(let productBuilder, conditions: _):
                    return productBuilder.moduleBuilders.map { KeyedPair($0, key: $0.module) }
                case .module:
                    return [] // local modules were checked by PackageBuilder.
                }
            }
        }) {
            observabilityScope.emit(
                ModuleError.cycleDetected(
                    (cycle.path.map(\.key.name), cycle.cycle.map(\.key.name))
                )
            )
            return IdentifiableSet()
        }
    }

    return IdentifiableSet(try packageBuilders.map { try $0.construct() })
}

private func emitDuplicateProductDiagnostic(
    productName: String,
    packages: [Package],
    moduleAliasingUsed: Bool,
    observabilityScope: ObservabilityScope
) -> PackageGraphError {
    if moduleAliasingUsed {
        packages.filter { $0.doesNotSupportProductAliases }.forEach {
            // Emit an additional warning about product aliasing in case of older tools-versions.
            observabilityScope.emit(warning: "product aliasing requires tools-version 5.2 or later, so it is not supported by '\($0.identity.description)'")
        }
    }
    return PackageGraphError.duplicateProduct(
        product: productName,
        packages: packages
    )
}

private func calculateEnabledTraits(
    identity: PackageIdentity,
    manifest: Manifest,
    explictlyEnabledTraits: Set<String>?
) throws -> Set<String> {
    // This the point where we flatten the enabled traits and resolve the recursive traits
    var recursiveEnabledTraits = explictlyEnabledTraits ?? []
    let areDefaultsEnabled = recursiveEnabledTraits.remove("default") != nil

    // We are going to calculate which traits are actually enabled for a node here. To do this
    // we have to check if default traits should be used and then flatten all the enabled traits.
    for trait in recursiveEnabledTraits {
        // Check if the enabled trait is a valid trait
        if manifest.traits.first(where: { $0.name == trait }) == nil {
            // The enabled trait is invalid
            throw ModuleError.invalidTrait(package: identity, trait: trait)
        }
    }

    // We have to enable all default traits if no traits are enabled or the defaults are explicitly enabled
    if explictlyEnabledTraits == nil || areDefaultsEnabled {
        recursiveEnabledTraits.formUnion(manifest.traits.first { $0.name == "default" }?.enabledTraits ?? [])
    }

    while true {
        let flattendEnabledTraits = Set(manifest.traits
            .lazy
            .filter { recursiveEnabledTraits.contains($0.name) }
            .map { $0.enabledTraits }
            .joined()
        )
        let newRecursiveEnabledTraits = recursiveEnabledTraits.union(flattendEnabledTraits)
        if newRecursiveEnabledTraits.count == recursiveEnabledTraits.count {
            break
        } else {
            recursiveEnabledTraits = newRecursiveEnabledTraits
        }
    }

    return recursiveEnabledTraits
}

fileprivate extension Package {
    var doesNotSupportProductAliases: Bool {
        // We can never use the identity based lookup for older packages because they lack the necessary information.
        return self.manifest.toolsVersion < .v5_2
    }
}

fileprivate struct Pair: Hashable {
    let package1: Package
    let package2: Package

    static func == (lhs: Pair, rhs: Pair) -> Bool {
        return lhs.package1.identity == rhs.package1.identity &&
            lhs.package2.identity == rhs.package2.identity
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.package1.identity)
        hasher.combine(self.package2.identity)
    }
}

fileprivate extension Product {
    var isDefaultLibrary: Bool {
        return type == .library(.automatic)
    }
}

private class DuplicateProductsChecker {
    var packageIDToBuilder = [PackageIdentity: ResolvedPackageBuilder]()
    var checkedPkgIDs = [PackageIdentity]()

    let moduleAliasingUsed: Bool
    let observabilityScope: ObservabilityScope

    init(packageBuilders: [ResolvedPackageBuilder], moduleAliasingUsed: Bool, observabilityScope: ObservabilityScope) {
        for packageBuilder in packageBuilders {
            let pkgID = packageBuilder.package.identity
            self.packageIDToBuilder[pkgID] = packageBuilder
        }
        self.moduleAliasingUsed = moduleAliasingUsed
        self.observabilityScope = observabilityScope
    }

    func run(lookupByProductIDs: Bool = false, observabilityScope: ObservabilityScope) throws {
        var productToPkgMap = [String: Set<PackageIdentity>]()
        for (pkgID, pkgBuilder) in packageIDToBuilder {
            let useProductIDs = pkgBuilder.package.manifest.disambiguateByProductIDs || lookupByProductIDs
            let depProductRefs = pkgBuilder.package.modules.map{$0.dependencies}.flatMap{$0}.compactMap{$0.product}
            for depRef in depProductRefs {
                if let depPkg =  depRef.package.map(PackageIdentity.plain) {
                    if !checkedPkgIDs.contains(depPkg) {
                        checkedPkgIDs.append(depPkg)
                    }
                    let depProductIDs = packageIDToBuilder[depPkg]?.package.products.filter { $0.identity == depRef.identity }.map { useProductIDs && $0.isDefaultLibrary ? $0.identity : $0.name } ?? []
                    for depID in depProductIDs {
                        productToPkgMap[depID, default: .init()].insert(depPkg)
                    }
                } else {
                    let depPkgs = pkgBuilder.dependencies.filter{ $0.products.contains{ $0.product.name == depRef.name }}.map{ $0.package.identity }
                    productToPkgMap[depRef.name, default: .init()].formUnion(Set(depPkgs))
                    checkedPkgIDs.append(contentsOf: depPkgs)
                }
                if !checkedPkgIDs.contains(pkgID) {
                    checkedPkgIDs.append(pkgID)
                }
            }
            for (depIDOrName, depPkgs) in productToPkgMap.filter({Set($0.value).count > 1}) {
                let name = depIDOrName.components(separatedBy: "_").dropFirst().joined(separator: "_")
                throw emitDuplicateProductDiagnostic(
                    productName: name.isEmpty ? depIDOrName : name,
                    packages: depPkgs.compactMap{ packageIDToBuilder[$0]?.package },
                    moduleAliasingUsed: self.moduleAliasingUsed,
                    observabilityScope: self.observabilityScope
                )
            }
        }

        // Check packages that exist but are not in a dependency graph
        let untrackedPkgs = packageIDToBuilder.filter{ !checkedPkgIDs.contains($0.key) }
        for (pkgID, pkgBuilder) in untrackedPkgs {
            for product in pkgBuilder.products {
                // Check if checking product ID only is safe
                let useIDOnly = lookupByProductIDs && product.product.isDefaultLibrary
                if !useIDOnly {
                    // This untracked pkg could have a product name conflicting with a
                    // product name from another package, but since it's not depended on
                    // by other packages, keep track of both this product's name and ID
                    // just in case other packages are < .v5_8
                    productToPkgMap[product.product.name, default: .init()].insert(pkgID)
                }
                productToPkgMap[product.product.identity, default: .init()].insert(pkgID)
            }
        }

        let duplicates = productToPkgMap.filter{ $0.value.count > 1 }
        for (productName, pkgs) in duplicates {
            throw emitDuplicateProductDiagnostic(
                productName: productName,
                packages: pkgs.compactMap{ packageIDToBuilder[$0]?.package },
                moduleAliasingUsed: self.moduleAliasingUsed,
                observabilityScope: self.observabilityScope
            )
        }
    }
}

private func computePlatforms(
    package: Package,
    platformRegistry: PlatformRegistry
) -> [SupportedPlatform] {
    // the supported platforms as declared in the manifest
    let declaredPlatforms: [SupportedPlatform] = package.manifest.platforms.map { platform in
        let declaredPlatform = platformRegistry.platformByName[platform.platformName]
            ?? PackageModel.Platform.custom(name: platform.platformName, oldestSupportedVersion: platform.version)
        return SupportedPlatform(
            platform: declaredPlatform,
            version: .init(platform.version),
            options: platform.options
        )
    }

    return declaredPlatforms.sorted(by: { $0.platform.name < $1.platform.name })
}

// Track and override module aliases specified for modules in a package graph
private func resolveModuleAliases(packageBuilders: [ResolvedPackageBuilder],
                                  observabilityScope: ObservabilityScope) throws -> Bool {
    // If there are no module aliases specified, return early
    let hasAliases = packageBuilders.contains { $0.package.modules.contains {
            $0.dependencies.contains { dep in
                if case let .product(prodRef, _) = dep {
                    return prodRef.moduleAliases != nil
                }
                return false
            }
        }
    }

    guard hasAliases else { return false }
    var aliasTracker = ModuleAliasTracker()
    for packageBuilder in packageBuilders {
        try aliasTracker.addModuleAliases(modules: packageBuilder.package.modules,
                                          package: packageBuilder.package.identity)
    }

    // Track modules that need module aliases for each package
    for packageBuilder in packageBuilders {
        for product in packageBuilder.package.products {
            aliasTracker.trackModulesPerProduct(product: product,
                                                package: packageBuilder.package.identity)
        }
    }

    // Override module aliases upstream if needed
    aliasTracker.propagateAliases(observabilityScope: observabilityScope)

    // Validate sources (Swift files only) for modules being aliased.
    // Needs to be done after `propagateAliases` since aliases defined
    // upstream can be overridden.
    for packageBuilder in packageBuilders {
        for product in packageBuilder.package.products {
            try aliasTracker.validateAndApplyAliases(product: product,
                                                     package: packageBuilder.package.identity,
                                                     observabilityScope: observabilityScope)
        }
    }

    // Emit diagnostics for any module aliases that did not end up being applied.
    aliasTracker.diagnoseUnappliedAliases(observabilityScope: observabilityScope)

    return true
}

/// A generic builder for `Resolved` models.
private class ResolvedBuilder<T> {
    /// The constructed object, available after the first call to `construct()`.
    private var _constructedObject: T?

    /// Construct the object with the accumulated data.
    ///
    /// Note that once the object is constructed, future calls to
    /// this method will return the same object.
    final func construct() throws -> T {
        if let _constructedObject {
            return _constructedObject
        }
        let constructedObject = try self.constructImpl()
        _constructedObject = constructedObject
        return constructedObject
    }

    /// The object construction implementation.
    func constructImpl() throws -> T {
        fatalError("Should be implemented by subclasses")
    }
}

/// Builder for resolved product.
private final class ResolvedProductBuilder: ResolvedBuilder<ResolvedProduct> {
    /// The reference to its package.
    unowned let packageBuilder: ResolvedPackageBuilder

    /// The product reference.
    let product: Product

    /// The module builders in the product.
    let moduleBuilders: [ResolvedModuleBuilder]

    init(product: Product, packageBuilder: ResolvedPackageBuilder, moduleBuilders: [ResolvedModuleBuilder]) {
        self.product = product
        self.packageBuilder = packageBuilder
        self.moduleBuilders = moduleBuilders
    }

    override func constructImpl() throws -> ResolvedProduct {
        return ResolvedProduct(
            packageIdentity: packageBuilder.package.identity,
            product: product,
            modules: IdentifiableSet(try moduleBuilders.map { try $0.construct() })
        )
    }
}

/// Builder for resolved module.
private final class ResolvedModuleBuilder: ResolvedBuilder<ResolvedModule> {
    /// Enumeration to represent module dependencies.
    enum Dependency {

        /// Dependency to another module, with conditions.
        case module(_ module: ResolvedModuleBuilder, conditions: [PackageCondition])

        /// Dependency to a product, with conditions.
        case product(_ product: ResolvedProductBuilder, conditions: [PackageCondition])
    }

    /// The reference to its package.
    let packageIdentity: PackageIdentity

    /// The module reference.
    let module: Module

    /// The module dependencies of this module.
    var dependencies: [Dependency] = []

    /// The defaultLocalization for this package
    var defaultLocalization: String? = nil

    /// The platforms supported by this package.
    var supportedPlatforms: [SupportedPlatform] = []

    let observabilityScope: ObservabilityScope
    let platformVersionProvider: PlatformVersionProvider

    init(
        packageIdentity: PackageIdentity,
        module: Module,
        observabilityScope: ObservabilityScope,
        platformVersionProvider: PlatformVersionProvider
    ) {
        self.packageIdentity = packageIdentity
        self.module = module
        self.observabilityScope = observabilityScope
        self.platformVersionProvider = platformVersionProvider
    }

    override func constructImpl() throws -> ResolvedModule {
        let diagnosticsEmitter = self.observabilityScope.makeDiagnosticsEmitter() {
            var metadata = ObservabilityMetadata()
            metadata.moduleName = module.name
            return metadata
        }

        let dependencies = try self.dependencies.map { dependency -> ResolvedModule.Dependency in
            switch dependency {
            case .module(let moduleBuilder, let conditions):
                return .module(try moduleBuilder.construct(), conditions: conditions)
            case .product(let productBuilder, let conditions):
                try self.module.validateDependency(
                    product: productBuilder.product,
                    productPackage: productBuilder.packageBuilder.package.identity
                )
                let product = try productBuilder.construct()
                if !productBuilder.packageBuilder.isAllowedToVendUnsafeProducts {
                    try product.diagnoseInvalidUseOfUnsafeFlags(diagnosticsEmitter)
                }
                return .product(product, conditions: conditions)
            }
        }

        return ResolvedModule(
            packageIdentity: self.packageIdentity,
            underlying: self.module,
            dependencies: dependencies,
            defaultLocalization: self.defaultLocalization,
            supportedPlatforms: self.supportedPlatforms,
            platformVersionProvider: self.platformVersionProvider
        )
    }
}

extension Module {
    func validateDependency(module: Module) throws {
        if self.type == .plugin && module.type == .library {
            throw PackageGraphError.unsupportedPluginDependency(
                moduleName: self.name,
                dependencyName: module.name,
                dependencyType: module.type.rawValue,
                dependencyPackage: nil
            )
        }
    }

    func validateDependency(product: Product, productPackage: PackageIdentity) throws {
        if self.type == .plugin && product.type.isLibrary {
            throw PackageGraphError.unsupportedPluginDependency(
                moduleName: self.name,
                dependencyName: product.name,
                dependencyType: product.type.description,
                dependencyPackage: productPackage.description
            )
        }
    }
}
/// Builder for resolved package.
private final class ResolvedPackageBuilder: ResolvedBuilder<ResolvedPackage> {
    /// The package reference.
    let package: Package

    /// The product filter applied to the package.
    let productFilter: ProductFilter

    /// Package can vend unsafe products
    let isAllowedToVendUnsafeProducts: Bool

    /// Package can be overridden
    let allowedToOverride: Bool

    /// The modules in the package.
    var modules: [ResolvedModuleBuilder] = []

    /// The products in this package.
    var products: [ResolvedProductBuilder] = []

    /// The enabled traits of this package.
    var enabledTraits: Set<String> = []

    /// The dependencies of this package.
    var dependencies: [ResolvedPackageBuilder] = []

    /// Map from package identity to the local name for module dependency resolution that has been given to that package through the dependency declaration.
    var dependencyNamesForModuleDependencyResolutionOnly: [PackageIdentity: String] = [:]

    /// The defaultLocalization for this package.
    var defaultLocalization: String? = nil

    /// The platforms supported by this package.
    var supportedPlatforms: [SupportedPlatform] = []

    /// If the given package's source is a registry release, this provides additional metadata and signature information.
    var registryMetadata: RegistryReleaseMetadata?

    let platformVersionProvider: PlatformVersionProvider

    init(
        _ package: Package,
        productFilter: ProductFilter,
        enabledTraits: Set<String>,
        isAllowedToVendUnsafeProducts: Bool,
        allowedToOverride: Bool,
        platformVersionProvider: PlatformVersionProvider
    ) {
        self.package = package
        self.productFilter = productFilter
        self.enabledTraits = enabledTraits
        self.isAllowedToVendUnsafeProducts = isAllowedToVendUnsafeProducts
        self.allowedToOverride = allowedToOverride
        self.platformVersionProvider = platformVersionProvider
    }

    override func constructImpl() throws -> ResolvedPackage {
        let products = try self.products.map { try $0.construct() }
        var modules = products.reduce(into: IdentifiableSet()) { $0.formUnion($1.modules) }
        try modules.formUnion(self.modules.map { try $0.construct() })

        return ResolvedPackage(
            underlying: self.package,
            defaultLocalization: self.defaultLocalization,
            supportedPlatforms: self.supportedPlatforms,
            dependencies: self.dependencies.map { $0.package.identity },
            enabledTraits: self.enabledTraits,
            modules: modules,
            products: products,
            registryMetadata: self.registryMetadata,
            platformVersionProvider: self.platformVersionProvider
        )
    }
}
