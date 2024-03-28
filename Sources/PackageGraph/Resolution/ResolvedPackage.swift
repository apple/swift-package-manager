//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics

import struct OrderedCollections.OrderedDictionary

import PackageModel

/// A fully resolved package. Contains resolved targets, products and dependencies of the package.
public struct ResolvedPackage {
    // The identity of the package.
    public var identity: PackageIdentity {
        return self.underlying.identity
    }

    /// The manifest describing the package.
    public var manifest: Manifest {
        return self.underlying.manifest
    }

    /// The local path of the package.
    public var path: AbsolutePath {
        return self.underlying.path
    }

    /// The underlying package reference.
    public let underlying: Package

    /// The targets contained in the package.
    public let targets: [ResolvedTarget]

    /// The products produced by the package.
    public let products: [ResolvedProduct]

    /// The dependencies of the package.
    public let dependencies: [ResolvedPackage]

    /// The default localization for resources.
    public let defaultLocalization: String?

    /// The list of platforms that are supported by this target.
    public let supportedPlatforms: [SupportedPlatform]

    /// If the given package's source is a registry release, this provides additional metadata and signature information.
    public let registryMetadata: RegistryReleaseMetadata?

    private let platformVersionProvider: PlatformVersionProvider

    public init(
        underlying: Package,
        defaultLocalization: String?,
        supportedPlatforms: [SupportedPlatform],
        dependencies: [ResolvedPackage],
        targets: [ResolvedTarget],
        products: [ResolvedProduct],
        registryMetadata: RegistryReleaseMetadata?,
        platformVersionProvider: PlatformVersionProvider
    ) {
        self.underlying = underlying

        var processedTargets = OrderedDictionary<ResolvedTarget.ID, ResolvedTarget>(
            uniqueKeysWithValues: targets.map { ($0.id, $0) }
        )
        var processedProducts = [ResolvedProduct]()
        // Make sure that direct macro dependencies of test products are also built for the target triple.
        // Without this workaround, `assertMacroExpansion` in tests can't be built, as it requires macros
        // and SwiftSyntax to be built for the target triple: https://github.com/apple/swift-package-manager/pull/7349
        for var product in products {
            if product.type == .test {
                var productTargets = IdentifiableSet<ResolvedTarget>()
                for var target in product.targets {
                    var targetDependencies = [ResolvedTarget.Dependency]()
                    for dependency in target.dependencies {
                        switch dependency {
                        case .target(var target, let conditions) where target.type == .macro:
                            target.buildTriple = .destination
                            target.updateBuildTriplesOfDependencies(forceUpdate: true)
                            targetDependencies.append(.target(target, conditions: conditions))

                            if target.packageIdentity == underlying.identity {
                                processedTargets[target.id] = target
                            }
                        case .product(var product, let conditions) where product.type == .macro:
                            product.buildTriple = .destination
                            targetDependencies.append(.product(product, conditions: conditions))
                        default:
                            targetDependencies.append(dependency)
                        }
                    }
                    target.dependencies = targetDependencies
                    if target.packageIdentity == underlying.identity {
                        processedTargets[target.id] = target
                    }
                    productTargets.insert(target)
                }
                product.targets = productTargets
            }

            processedProducts.append(product)
        }

        self.products = processedProducts
        self.targets = Array(processedTargets.values)
        self.dependencies = dependencies
        self.defaultLocalization = defaultLocalization
        self.supportedPlatforms = supportedPlatforms
        self.registryMetadata = registryMetadata
        self.platformVersionProvider = platformVersionProvider
    }

    public func getSupportedPlatform(for platform: Platform, usingXCTest: Bool) -> SupportedPlatform {
        self.platformVersionProvider.getDerived(
            declared: self.supportedPlatforms,
            for: platform,
            usingXCTest: usingXCTest
        )
    }
}

extension ResolvedPackage: CustomStringConvertible {
    public var description: String {
        return "<ResolvedPackage: \(self.identity)>"
    }
}

extension ResolvedPackage: Identifiable {
    public var id: PackageIdentity { self.underlying.identity }
}

@available(*, unavailable, message: "Use `Identifiable` conformance or `IdentifiableSet` instead")
extension ResolvedPackage: Hashable {}
