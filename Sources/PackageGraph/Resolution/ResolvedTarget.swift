//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import PackageModel

/// Represents a fully resolved target. All the dependencies for this target are also stored as resolved.
public struct ResolvedTarget {
    /// Represents dependency of a resolved target.
    public enum Dependency {
        /// Direct dependency of the target. This target is in the same package and should be statically linked.
        case target(_ target: ResolvedTarget, conditions: [PackageCondition])

        /// The target depends on this product.
        case product(_ product: ResolvedProduct, conditions: [PackageCondition])

        public var target: ResolvedTarget? {
            switch self {
            case .target(let target, _): return target
            case .product: return nil
            }
        }

        public var product: ResolvedProduct? {
            switch self {
            case .target: return nil
            case .product(let product, _): return product
            }
        }

        public var conditions: [PackageCondition] {
            switch self {
            case .target(_, let conditions): return conditions
            case .product(_, let conditions): return conditions
            }
        }

        /// Returns the direct dependencies of the underlying dependency, across the package graph.
        public var dependencies: [ResolvedTarget.Dependency] {
            switch self {
            case .target(let target, _):
                return target.dependencies
            case .product(let product, _):
                return product.targets.map { .target($0, conditions: []) }
            }
        }

        /// Returns the direct dependencies of the underlying dependency, limited to the target's package.
        public var packageDependencies: [ResolvedTarget.Dependency] {
            switch self {
            case .target(let target, _):
                return target.dependencies
            case .product:
                return []
            }
        }

        public func satisfies(_ environment: BuildEnvironment) -> Bool {
            conditions.allSatisfy { $0.satisfies(environment) }
        }
    }

    /// The name of this target.
    public var name: String {
        self.underlying.name
    }

    /// Returns dependencies which satisfy the input build environment, based on their conditions.
    /// - Parameters:
    ///     - environment: The build environment to use to filter dependencies on.
    public func dependencies(satisfying environment: BuildEnvironment) -> [Dependency] {
        return dependencies.filter { $0.satisfies(environment) }
    }

    /// Returns the recursive dependencies, across the whole package-graph.
    public func recursiveDependencies() throws -> [Dependency] {
        try topologicalSort(self.dependencies) { $0.dependencies }
    }

    /// Returns the recursive target dependencies, across the whole package-graph.
    public func recursiveTargetDependencies() throws -> [ResolvedTarget] {
        try topologicalSort(self.dependencies) { $0.dependencies }.compactMap { $0.target }
    }

    /// Returns the recursive dependencies, across the whole package-graph, which satisfy the input build environment,
    /// based on their conditions.
    /// - Parameters:
    ///     - environment: The build environment to use to filter dependencies on.
    public func recursiveDependencies(satisfying environment: BuildEnvironment) throws -> [Dependency] {
        try topologicalSort(dependencies(satisfying: environment)) { dependency in
            dependency.dependencies.filter { $0.satisfies(environment) }
        }
    }

    /// The language-level target name.
    public var c99name: String {
        self.underlying.c99name
    }

    /// Module aliases for dependencies of this target. The key is an
    /// original target name and the value is a new unique name mapped
    /// to the name of its .swiftmodule binary.
    public var moduleAliases: [String: String]? {
        self.underlying.moduleAliases
    }

    /// Allows access to package symbols from other targets in the package
    public var packageAccess: Bool {
        self.underlying.packageAccess
    }

    /// The "type" of target.
    public var type: Target.Kind {
        self.underlying.type
    }

    /// The sources for the target.
    public var sources: Sources {
        self.underlying.sources
    }

    let packageIdentity: PackageIdentity

    /// The underlying target represented in this resolved target.
    public let underlying: Target

    /// The dependencies of this target.
    public internal(set) var dependencies: [Dependency]

    /// The default localization for resources.
    public let defaultLocalization: String?

    /// The list of platforms that are supported by this target.
    public let supportedPlatforms: [SupportedPlatform]

    private let platformVersionProvider: PlatformVersionProvider

    /// Triple for which this resolved target should be compiled for.
    public internal (set) var buildTriple: BuildTriple {
        didSet {
            self.updateBuildTriplesOfDependencies()
        }
    }

    /// Create a resolved target instance.
    public init(
        packageIdentity: PackageIdentity,
        underlying: Target,
        dependencies: [ResolvedTarget.Dependency],
        defaultLocalization: String? = nil,
        supportedPlatforms: [SupportedPlatform],
        platformVersionProvider: PlatformVersionProvider
    ) {
        self.packageIdentity = packageIdentity
        self.underlying = underlying
        self.dependencies = dependencies
        self.defaultLocalization = defaultLocalization
        self.supportedPlatforms = supportedPlatforms
        self.platformVersionProvider = platformVersionProvider
        self.buildTriple = underlying.buildTriple
        self.updateBuildTriplesOfDependencies()
    }

    mutating func updateBuildTriplesOfDependencies(forceUpdate: Bool = false) {
        if forceUpdate || self.buildTriple == .tools {
            for (i, dependency) in dependencies.enumerated() {
                let updatedDependency: Dependency
                switch dependency {
                case .target(var target, let conditions):
                    target.buildTriple = self.buildTriple
                    updatedDependency = .target(target, conditions: conditions)
                case .product(var product, let conditions):
                    product.buildTriple = self.buildTriple
                    updatedDependency = .product(product, conditions: conditions)
                }

                dependencies[i] = updatedDependency
            }
        }
    }

    public func getSupportedPlatform(for platform: Platform, usingXCTest: Bool) -> SupportedPlatform {
        self.platformVersionProvider.getDerived(
            declared: self.supportedPlatforms,
            for: platform,
            usingXCTest: usingXCTest
        )
    }
}

extension ResolvedTarget: CustomStringConvertible {
    public var description: String {
        return "<ResolvedTarget: \(self.name) | \(self.buildTriple)>"
    }
}

extension ResolvedTarget.Dependency: CustomStringConvertible {
    public var description: String {
        var str = "<ResolvedTarget.Dependency: "
        switch self {
        case .product(let p, _):
            str += p.description
        case .target(let t, _):
            str += t.description
        }
        str += ">"
        return str
    }
}

extension ResolvedTarget.Dependency: Identifiable {
    public struct ID: Hashable {
        enum Kind: Hashable {
            case target
            case product
        }

        let kind: Kind
        let packageIdentity: PackageIdentity
        let name: String
    }

    public var id: ID {
        switch self {
        case .target(let target, _):
            return .init(kind: .target, packageIdentity: target.packageIdentity, name: target.name)
        case .product(let product, _):
            return .init(kind: .product, packageIdentity: product.packageIdentity, name: product.name)
        }
    }
}

extension ResolvedTarget.Dependency: Equatable {
    public static func == (lhs: ResolvedTarget.Dependency, rhs: ResolvedTarget.Dependency) -> Bool {
        switch (lhs, rhs) {
        case (.target(let lhsTarget, _), .target(let rhsTarget, _)):
            return lhsTarget.id == rhsTarget.id
        case (.product(let lhsProduct, _), .product(let rhsProduct, _)):
            return lhsProduct.id == rhsProduct.id
        case (.product, .target), (.target, .product):
            return false
        }
    }
}

extension ResolvedTarget.Dependency: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .target(let target, _):
            hasher.combine(target.id)
        case .product(let product, _):
            hasher.combine(product.id)
        }
    }
}

extension ResolvedTarget: Identifiable {
    /// Resolved target identity that uniquely identifies it in a resolution graph.
    public struct ID: Hashable {
        public let targetName: String
        let packageIdentity: PackageIdentity
        public var buildTriple: BuildTriple
    }

    public var id: ID {
        ID(targetName: self.name, packageIdentity: self.packageIdentity, buildTriple: self.buildTriple)
    }
}

@available(*, unavailable, message: "Use `Identifiable` conformance or `IdentifiableSet` instead")
extension ResolvedTarget: Hashable {}
