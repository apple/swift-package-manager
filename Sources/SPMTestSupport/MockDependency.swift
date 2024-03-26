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
import Foundation
import PackageLoading
import PackageModel

package typealias SourceControlRequirement = PackageDependency.SourceControl.Requirement
package typealias RegistryRequirement = PackageDependency.Registry.Requirement

package struct MockDependency {
    package let deprecatedName: String?
    package let location: Location
    package let products: ProductFilter

    init(deprecatedName: String? = nil, location: Location, products: ProductFilter = .everything) {
        self.deprecatedName = deprecatedName
        self.location = location
        self.products = products
    }

    package func convert(baseURL: AbsolutePath, identityResolver: IdentityResolver) throws -> PackageDependency {
        switch self.location {
        case .fileSystem(let path):
            let absolutePath = baseURL.appending(path)
            let mappedLocation = identityResolver.mappedLocation(for: absolutePath.pathString)
            guard let mappedPath = try? AbsolutePath(validating: mappedLocation) else {
                throw StringError("invalid mapping of '\(path)' to '\(mappedLocation)', no requirement information available.")
            }
            let identity = try identityResolver.resolveIdentity(for: mappedPath)
            return .fileSystem(
                identity: identity,
                deprecatedName: self.deprecatedName,
                path: mappedPath,
                productFilter: self.products
            )
        case .localSourceControl(let path, let requirement):
            let absolutePath = baseURL.appending(path)
            let mappedLocation = identityResolver.mappedLocation(for: absolutePath.pathString)
            guard let mappedPath = try? AbsolutePath(validating: mappedLocation) else {
                throw StringError("invalid mapping of '\(path)' to '\(mappedLocation)', no requirement information available.")
            }
            let identity = try identityResolver.resolveIdentity(for: mappedPath)
            return .localSourceControl(
                identity: identity,
                deprecatedName: self.deprecatedName,
                path: mappedPath,
                requirement: requirement,
                productFilter: self.products
            )
        case .remoteSourceControl(let url, let _requirement):
            let mappedLocation = identityResolver.mappedLocation(for: url.absoluteString)
            if PackageIdentity.plain(mappedLocation).isRegistry {
                let identity = PackageIdentity.plain(mappedLocation)
                let requirement: RegistryRequirement
                switch _requirement {
                case .branch, .revision:
                    throw StringError("invalid mapping of source control to registry, requirement information mismatch.")
                case .exact(let value):
                    requirement = .exact(value)
                case .range(let value):
                    requirement = .range(value)
                }
                return .registry(
                    identity: identity,
                    requirement: requirement,
                    productFilter: self.products,
                    traits: .init(enabledTraits: .init())
                )

            } else {
                let mappedURL = SourceControlURL(mappedLocation)
                let identity = try identityResolver.resolveIdentity(for: mappedURL)
                return .remoteSourceControl(
                    identity: identity,
                    deprecatedName: self.deprecatedName,
                    url: mappedURL,
                    requirement: _requirement,
                    productFilter: self.products
                )
            }
        case .registry(let identity, let _requirement):
            let mappedLocation = identityResolver.mappedLocation(for: identity.description)
            if PackageIdentity.plain(mappedLocation).isRegistry {
                let identity = PackageIdentity.plain(mappedLocation)
                return .registry(
                    identity: identity,
                    requirement: _requirement,
                    productFilter: self.products,
                    traits: .init(enabledTraits: .init())
                )
            } else {
                let mappedURL = SourceControlURL(mappedLocation)
                let identity = try identityResolver.resolveIdentity(for: mappedURL)
                let requirement: SourceControlRequirement
                switch _requirement {
                case .exact(let value):
                    requirement = .exact(value)
                case .range(let value):
                    requirement = .range(value)
                }
                return .remoteSourceControl(
                    identity: identity,
                    deprecatedName: self.deprecatedName,
                    url: mappedURL,
                    requirement: requirement,
                    productFilter: self.products
                )
            }
        }
        
    }

    package static func fileSystem(path: String, products: ProductFilter = .everything) -> MockDependency {
        try! MockDependency(location: .fileSystem(path: RelativePath(validating: path)), products: products)
    }

    package static func sourceControl(path: String, requirement: SourceControlRequirement, products: ProductFilter = .everything) -> MockDependency {
        try! .sourceControl(path: RelativePath(validating: path), requirement: requirement, products: products)
    }

    package static func sourceControl(path: RelativePath, requirement: SourceControlRequirement, products: ProductFilter = .everything) -> MockDependency {
        MockDependency(location: .localSourceControl(path: path, requirement: requirement), products: products)
    }

    package static func sourceControlWithDeprecatedName(name: String, path: String, requirement: SourceControlRequirement, products: ProductFilter = .everything) -> MockDependency {
        try! MockDependency(deprecatedName: name, location: .localSourceControl(path: RelativePath(validating: path), requirement: requirement), products: products)
    }

    package static func sourceControl(url: String, requirement: SourceControlRequirement, products: ProductFilter = .everything) -> MockDependency {
        .sourceControl(url: SourceControlURL(url), requirement: requirement, products: products)
    }

    package static func sourceControl(url: SourceControlURL, requirement: SourceControlRequirement, products: ProductFilter = .everything) -> MockDependency {
        MockDependency(location: .remoteSourceControl(url: url, requirement: requirement), products: products)
    }

    package static func registry(identity: String, requirement: RegistryRequirement, products: ProductFilter = .everything) -> MockDependency {
        .registry(identity: .plain(identity), requirement: requirement)
    }

    package static func registry(identity: PackageIdentity, requirement: RegistryRequirement, products: ProductFilter = .everything) -> MockDependency {
        MockDependency(location: .registry(identity: identity, requirement: requirement), products: products)
    }

    package enum Location {
        case fileSystem(path: RelativePath)
        case localSourceControl(path: RelativePath, requirement: SourceControlRequirement)
        case remoteSourceControl(url: SourceControlURL, requirement: SourceControlRequirement)
        case registry(identity: PackageIdentity, requirement: RegistryRequirement)
    }
}
