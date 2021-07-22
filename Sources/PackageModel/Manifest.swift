/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basics
import TSCBasic
import TSCUtility
import Foundation

/// This contains the declarative specification loaded from package manifest
/// files, and the tools for working with the manifest.
public final class Manifest: ObjectIdentifierProtocol {

    /// The standard filename for the manifest.
    public static let filename = basename + ".swift"

    /// The standard basename for the manifest.
    public static let basename = "Package"

    /// FIXME: deprecate this, there is no value in this once we have real package identifiers
    /// The name of the package.
    //@available(*, deprecated)
    public let name: String

    // FIXME: deprecate this, this is not part of the manifest information, we just use it as a container for this data
    // FIXME: This doesn't belong here, we want the Manifest to be purely tied
    // to the repository state, it shouldn't matter where it is.
    //
    /// The path of the manifest file.
    //@available(*, deprecated)
    public let path: AbsolutePath

    // FIXME: deprecate this, this is not part of the manifest information, we just use it as a container for this data
    // FIXME: This doesn't belong here, we want the Manifest to be purely tied
    // to the repository state, it shouldn't matter where it is.
    //
    /// The repository URL the manifest was loaded from.
    public let packageLocation: String

    // FIXME: deprecated 2/2021, remove once clients migrate
    @available(*, deprecated, message: "use packageLocation instead")
    public var url: String {
        get {
            self.packageLocation
        }
    }

    /// Whether kind of package this manifest is from.
     public let packageKind: PackageReference.Kind

    /// The version this package was loaded from, if known.
    public let version: Version?

    /// The revision this package was loaded from, if known.
    public let revision: String?

    /// The tools version declared in the manifest.
    public let toolsVersion: ToolsVersion

    /// The default localization for resources.
    public let defaultLocalization: String?

    /// The declared platforms in the manifest.
    public let platforms: [PlatformDescription]

    /// The declared package dependencies.
    public let dependencies: [PackageDependencyDescription]

    /// The targets declared in the manifest.
    public let targets: [TargetDescription]

    /// The targets declared in the manifest, keyed by their name.
    public let targetMap: [String: TargetDescription]

    /// The products declared in the manifest.
    public let products: [ProductDescription]

    /// The C language standard flag.
    public let cLanguageStandard: String?

    /// The C++ language standard flag.
    public let cxxLanguageStandard: String?

    /// The supported Swift language versions of the package.
    public let swiftLanguageVersions: [SwiftLanguageVersion]?

    /// The pkg-config name of a system package.
    public let pkgConfig: String?

    /// The system package providers of a system package.
    public let providers: [SystemPackageProviderDescription]?

    /// Targets required for building particular product filters.
    private var _requiredTargets = ThreadSafeKeyValueStore<ProductFilter, [TargetDescription]>()

    /// Dependencies required for building particular product filters.
    private var _requiredDependencies = ThreadSafeKeyValueStore<ProductFilter, [PackageDependencyDescription]>()

    public init(
        name: String,
        path: AbsolutePath,
        packageKind: PackageReference.Kind,
        packageLocation: String,
        defaultLocalization: String? = nil,
        platforms: [PlatformDescription],
        version: TSCUtility.Version? = nil,
        revision: String? = nil,
        toolsVersion: ToolsVersion,
        pkgConfig: String? = nil,
        providers: [SystemPackageProviderDescription]? = nil,
        cLanguageStandard: String? = nil,
        cxxLanguageStandard: String? = nil,
        swiftLanguageVersions: [SwiftLanguageVersion]? = nil,
        dependencies: [PackageDependencyDescription] = [],
        products: [ProductDescription] = [],
        targets: [TargetDescription] = []
    ) {
        self.name = name
        self.path = path
        self.packageKind = packageKind
        self.packageLocation = packageLocation
        self.defaultLocalization = defaultLocalization
        self.platforms = platforms
        self.version = version
        self.revision = revision
        self.toolsVersion = toolsVersion
        self.pkgConfig = pkgConfig
        self.providers = providers
        self.cLanguageStandard = cLanguageStandard
        self.cxxLanguageStandard = cxxLanguageStandard
        self.swiftLanguageVersions = swiftLanguageVersions
        self.dependencies = dependencies
        self.products = products
        self.targets = targets
        self.targetMap = Dictionary(targets.lazy.map({ ($0.name, $0) }), uniquingKeysWith: { $1 })
    }

    /// Returns the targets required for a particular product filter.
    public func targetsRequired(for productFilter: ProductFilter) -> [TargetDescription] {
        #if ENABLE_TARGET_BASED_DEPENDENCY_RESOLUTION
        // If we have already calcualted it, returned the cached value.
        if let targets = _requiredTargets[productFilter] {
            return targets
        } else {
            let targets: [TargetDescription]
            switch productFilter {
            case .everything:
                return self.targets
            case .specific(let productFilter):
                let products = self.products.filter { productFilter.contains($0.name) }
                targets = targetsRequired(for: products)
            }

            _requiredTargets[productFilter] = targets
            return targets
        }
        #else
        return packageKind == .root ? self.targets : targetsRequired(for: products)
        #endif
    }

    /// Returns the package dependencies required for a particular products filter.
    public func dependenciesRequired(for productFilter: ProductFilter) -> [PackageDependencyDescription] {
        #if ENABLE_TARGET_BASED_DEPENDENCY_RESOLUTION
        // If we have already calcualted it, returned the cached value.
        if let dependencies = self._requiredDependencies[productFilter] {
            return self.dependencies
        } else {
            let targets = self.targetsRequired(for: productFilter)
            let dependencies = self.dependenciesRequired(for: targets, keepUnused: productFilter == .everything)
            self._requiredDependencies[productFilter] = dependencies
            return self.dependencies
        }
        #else
        guard toolsVersion >= .v5_2 && packageKind != .root else {
            return self.dependencies
        }
        
        var requiredDependencyURLs: Set<PackageIdentity> = []
        
        for target in self.targetsRequired(for: products) {
            for targetDependency in target.dependencies {
                if let dependency = self.packageDependency(referencedBy: targetDependency) {
                    requiredDependencyURLs.insert(dependency.identity)
                }
            }
        }
        
        return self.dependencies.filter { requiredDependencyURLs.contains($0.identity) }
        #endif
    }

    /// Returns the targets required for building the provided products.
    public func targetsRequired(for products: [ProductDescription]) -> [TargetDescription] {
        let targetsByName = Dictionary(targets.map({ ($0.name, $0) }), uniquingKeysWith: { $1 })
        let productTargetNames = products.flatMap({ $0.targets })

        let dependentTargetNames = transitiveClosure(productTargetNames, successors: { targetName in

            if let target = targetsByName[targetName] {
                let dependencies: [String] = target.dependencies.compactMap { dependency in
                    switch dependency {
                    case .target(let name, _),
                         .byName(let name, _):
                        return targetsByName.keys.contains(name) ? name : nil
                    default:
                        return nil
                    }
                }

                let plugins: [String] = target.pluginUsages?.compactMap { pluginUsage in
                    switch pluginUsage {
                    case .plugin(name: let name, package: nil):
                        return targetsByName.keys.contains(name) ? name : nil
                    default:
                        return nil
                    }
                } ?? []

                return dependencies + plugins
            }
            
            return []

            
        })

        let requiredTargetNames = Set(productTargetNames).union(dependentTargetNames)
        let requiredTargets = requiredTargetNames.compactMap{ targetsByName[$0] }
        return requiredTargets
    }

    /// Returns the package dependencies required for building the provided targets.
    ///
    /// The returned dependencies have their particular product filters registered. (To determine product filters without removing any dependencies from the list, specify `keepUnused: true`.)
    private func dependenciesRequired(
        for targets: [TargetDescription],
        keepUnused: Bool = false
    ) -> [PackageDependencyDescription] {

        var registry: (known: [String: ProductFilter], unknown: Set<String>) = ([:], [])
        let availablePackages = Set(dependencies.lazy.map{ $0.nameForTargetDependencyResolutionOnly })

        for target in targets {
            for targetDependency in target.dependencies {
                register(targetDependency: targetDependency, registry: &registry, availablePackages: availablePackages)
            }
        }

        // Products whose package could not be determined are marked as needed on every dependency.
        // (This way none of them filters such a product out.)
        var associations = registry.known
        let unknown = registry.unknown
        if !registry.unknown.isEmpty {
            for package in availablePackages {
                associations[package, default: .nothing].formUnion(.specific(unknown))
            }
        }

        return dependencies.compactMap { dependency in
            if let filter = associations[dependency.nameForTargetDependencyResolutionOnly] {
                return dependency.filtered(by: filter)
            } else if keepUnused {
                // Register that while the dependency was kept, no products are needed.
                return dependency.filtered(by: .nothing)
            } else {
                // Dependencies known to not have any relevant products are discarded.
                return nil
            }
        }
    }

    /// Finds the package dependency referenced by the specified target dependency.
    /// - Returns: Returns `nil` if the dependency is a target dependency, if it is a product dependency but has no
    /// package name (for tools versions less than 5.2), or if there were no dependencies with the provided name.
    public func packageDependency(
        referencedBy targetDependency: TargetDescription.Dependency
    ) -> PackageDependencyDescription? {
        let packageName: String

        switch targetDependency {
        case .product(_, package: let name?, _),
             .byName(name: let name, _):
            packageName = name
        default:
            return nil
        }

        return self.dependencies.first(where: {
            // rdar://80594761 make sure validation is case insensitive
            $0.nameForTargetDependencyResolutionOnly.lowercased() == packageName.lowercased()
        })
    }

    /// Registers a required product with a particular dependency if possible, or registers it as unknown.
    ///
    /// - Parameters:
    ///   - targetDependency: The target dependency to register.
    ///   - registry: The registry in which to record the assocation.
    ///   - availablePackages: The set of available packages.
    private func register(
        targetDependency: TargetDescription.Dependency,
        registry: inout (known: [String: ProductFilter], unknown: Set<String>),
        availablePackages: Set<String>
    ) {
        switch targetDependency {
        case .target:
            break
        case .product(let product, let package, _):
            if let package = package { // ≥ 5.2
                if !register(
                    product: product,
                    inPackage: package,
                    registry: &registry.known,
                    availablePackages: availablePackages) {
                        // This is an invalid manifest condition diagnosed later. (No such package.)
                        // Treating it as unknown gracefully allows resolution to continue for now.
                    registry.unknown.insert(product)
                }
            } else { // < 5.2
                registry.unknown.insert(product)
            }
        case .byName(let product, _):
            if toolsVersion < .v5_2 {
                // A by‐name entry might be a product from anywhere.
                if targets.contains(where: { $0.name == product }) {
                    // Save the resolver some effort if it is known to only be a target anyway.
                    break
                } else {
                    registry.unknown.insert(product)
                }
            } else { // ≥ 5.2
                // If a by‐name entry is a product, it must be in a package of the same name.
                if !register(
                    product: product,
                    inPackage: product,
                    registry: &registry.known,
                    availablePackages: availablePackages) {
                        // If it doesn’t match a package, it should be a target, not a product.
                        if targets.contains(where: { $0.name == product }) {
                            break
                        } else {
                            // But in case the user is trying to reference a product,
                            // we still need to pass on the invalid reference
                            // so that the resolver fetches all dependencies
                            // in order to provide the diagnostic pass with the information it needs.
                            registry.unknown.insert(product)
                        }
                }
            }
        }
    }

    /// Registers a required product with a particular dependency if possible.
    ///
    /// - Parameters:
    ///   - product: The product to try registering.
    ///   - package: The package to try associating it with.
    ///   - registry: The registry in which to record the association.
    ///   - availablePackages: The set of available packages.
    ///
    /// - Returns: `true` if the particular dependency was found and the product was registered; `false` if no matching dependency was found and the product has not yet been handled.
    private func register(
        product: String,
        inPackage package: String,
        registry: inout [String: ProductFilter],
        availablePackages: Set<String>
    ) -> Bool {
        if let existing = registry[package] {
            registry[package] = existing.union(.specific([product]))
            return true
        } else if availablePackages.contains(package) {
            registry[package] = .specific([product])
            return true
        } else {
            return false
        }
    }
}

extension Manifest: CustomStringConvertible {
    public var description: String {
        return "<Manifest: \(self.name)>"
    }
}

extension Manifest: Encodable {
    private enum CodingKeys: CodingKey {
         case name, path, url, version, targetMap, toolsVersion,
              pkgConfig,providers, cLanguageStandard, cxxLanguageStandard, swiftLanguageVersions,
              dependencies, products, targets, platforms, packageKind, revision,
              defaultLocalization
    }
    /// Coding user info key for dump-package command.
    ///
    /// Presence of this key will hide some keys when encoding the Manifest object.
    public static let dumpPackageKey: CodingUserInfoKey = CodingUserInfoKey(rawValue: "dumpPackage")!

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.name, forKey: .name)

        // Hide the keys that users shouldn't see when
        // we're encoding for the dump-package command.
        if encoder.userInfo[Manifest.dumpPackageKey] == nil {
            try container.encode(self.path, forKey: .path)
            try container.encode(self.packageLocation, forKey: .url)
            try container.encode(self.version, forKey: .version)
            try container.encode(self.targetMap, forKey: .targetMap)
        }

        try container.encode(self.toolsVersion, forKey: .toolsVersion)
        try container.encode(self.pkgConfig, forKey: .pkgConfig)
        try container.encode(self.providers, forKey: .providers)
        try container.encode(self.cLanguageStandard, forKey: .cLanguageStandard)
        try container.encode(self.cxxLanguageStandard, forKey: .cxxLanguageStandard)
        try container.encode(self.swiftLanguageVersions, forKey: .swiftLanguageVersions)
        try container.encode(self.dependencies, forKey: .dependencies)
        try container.encode(self.products, forKey: .products)
        try container.encode(self.targets, forKey: .targets)
        try container.encode(self.platforms, forKey: .platforms)
        try container.encode(self.packageKind, forKey: .packageKind)
    }
}
