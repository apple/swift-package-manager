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

import Foundation
import Basics

import struct TSCBasic.CodableRange

import struct TSCUtility.Version

/// Represents a package dependency.
public enum PackageDependency: Equatable, Hashable, Sendable {
    /// A struct representing an enabled trait of a dependency.
    package struct Trait: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
        /// A condition that limits the application of a dependencies trait.
        package struct Condition: Hashable, Sendable, Codable {
            /// The set of traits of this package that enable the dependencie's trait.
            package let traits: Set<String>?

            public init(traits: Set<String>?) {
                self.traits = traits
            }
        }

        /// The name of the enabled trait.
        package var name: String

        /// The condition under which the trait is enabled.
        package var condition: Condition?

        /// Initializes a new enabled trait.
        ///
        /// - Parameters:
        ///   - name: The name of the enabled trait.
        ///   - condition: The condition under which the trait is enabled.
        package init(
            name: String,
            condition: Condition? = nil
        ) {
            self.name = name
            self.condition = condition
        }

        public init(stringLiteral value: StringLiteralType) {
            self.init(name: value)
        }

        /// Initializes a new enabled trait.
        ///
        /// - Parameters:
        ///   - name: The name of the enabled trait.
        ///   - condition: The condition under which the trait is enabled.
        package static func trait(
            name: String,
            condition: Condition? = nil
        ) -> Trait {
            self.init(
                name: name,
                condition: condition
            )
        }
    }

    case fileSystem(FileSystem)
    case sourceControl(SourceControl)
    case registry(Registry)
    
    public struct FileSystem: Equatable, Hashable, Encodable, Sendable {
        public let identity: PackageIdentity
        public let nameForTargetDependencyResolutionOnly: String?
        public let path: AbsolutePath
        public let productFilter: ProductFilter
        package let traits: Set<Trait>?
    }

    public struct SourceControl: Equatable, Hashable, Encodable, Sendable {
        public let identity: PackageIdentity
        public let nameForTargetDependencyResolutionOnly: String?
        public let location: Location
        public let requirement: Requirement
        public let productFilter: ProductFilter
        package let traits: Set<Trait>?

        public enum Requirement: Equatable, Hashable, Sendable {
            case exact(Version)
            case range(Range<Version>)
            case revision(String)
            case branch(String)
        }

        public enum Location: Equatable, Hashable, Sendable {
            case local(AbsolutePath)
            case remote(SourceControlURL)
        }
    }

    public struct Registry: Equatable, Hashable, Encodable, Sendable {
        public let identity: PackageIdentity
        public let requirement: Requirement
        public let productFilter: ProductFilter
        package let traits: Set<Trait>?

        /// The dependency requirement.
        public enum Requirement: Equatable, Hashable, Sendable {
            case exact(Version)
            case range(Range<Version>)
        }
    }

    package var traits: Set<Trait>? {
        switch self {
        case .fileSystem(let settings):
            return settings.traits
        case .sourceControl(let settings):
            return settings.traits
        case .registry(let settings):
            return settings.traits
        }
    }

    public var identity: PackageIdentity {
        switch self {
        case .fileSystem(let settings):
            return settings.identity
        case .sourceControl(let settings):
            return settings.identity
        case .registry(let settings):
            return settings.identity
        }
    }

    // FIXME: we should simplify target based dependencies such that this is no longer required
    // A name to be used *only* for target dependencies resolution
    public var nameForModuleDependencyResolutionOnly: String {
        switch self {
        case .fileSystem(let settings):
            return settings.nameForTargetDependencyResolutionOnly ?? PackageIdentityParser.computeDefaultName(fromPath: settings.path)
        case .sourceControl(let settings):
            switch settings.location {
            case .local(let path):
                return settings.nameForTargetDependencyResolutionOnly ?? PackageIdentityParser.computeDefaultName(fromPath: path)
            case .remote(let url):
                return settings.nameForTargetDependencyResolutionOnly ?? PackageIdentityParser.computeDefaultName(fromURL: url)
            }
        case .registry:
            return self.identity.description
        }
    }

    // FIXME: we should simplify target based dependencies such that this is no longer required
    // A name to be used *only* for target dependencies resolution
    public var explicitNameForModuleDependencyResolutionOnly: String? {
        switch self {
        case .fileSystem(let settings):
            return settings.nameForTargetDependencyResolutionOnly
        case .sourceControl(let settings):
            return settings.nameForTargetDependencyResolutionOnly
        case .registry:
            return nil
        }
    }

    public var productFilter: ProductFilter {
        switch self {
        case .fileSystem(let settings):
            return settings.productFilter
        case .sourceControl(let settings):
            return settings.productFilter
        case .registry(let settings):
            return settings.productFilter
        }
    }

    public func filtered(by productFilter: ProductFilter) -> Self {
        switch self {
        case .fileSystem(let settings):
            return .fileSystem(
                identity: settings.identity,
                nameForTargetDependencyResolutionOnly: settings.nameForTargetDependencyResolutionOnly,
                path: settings.path,
                productFilter: productFilter,
                traits: settings.traits
            )
        case .sourceControl(let settings):
            return .sourceControl(
                identity: settings.identity,
                nameForTargetDependencyResolutionOnly: settings.nameForTargetDependencyResolutionOnly,
                location: settings.location,
                requirement: settings.requirement,
                productFilter: productFilter,
                traits: settings.traits
            )
        case .registry(let settings):
            return .registry(
                identity: settings.identity,
                requirement: settings.requirement,
                productFilter: productFilter,
                traits: settings.traits
            )
        }
    }

    public static func fileSystem(
        identity: PackageIdentity,
        nameForTargetDependencyResolutionOnly: String?,
        path: AbsolutePath,
        productFilter: ProductFilter
    ) -> Self {
        .fileSystem(
            identity: identity,
            nameForTargetDependencyResolutionOnly: nameForTargetDependencyResolutionOnly,
            path: path,
            productFilter: productFilter,
            traits: nil
        )
    }

    package static func fileSystem(
        identity: PackageIdentity,
        nameForTargetDependencyResolutionOnly: String?,
        path: AbsolutePath,
        productFilter: ProductFilter,
        traits: Set<Trait>?
    ) -> Self {
        .fileSystem(
            .init(
                identity: identity,
                nameForTargetDependencyResolutionOnly: nameForTargetDependencyResolutionOnly,
                path: path,
                productFilter: productFilter,
                traits: traits
            )
        )
    }

    public static func localSourceControl(
        identity: PackageIdentity,
        nameForTargetDependencyResolutionOnly: String?,
        path: AbsolutePath,
        requirement: SourceControl.Requirement,
        productFilter: ProductFilter
    ) -> Self {
        .localSourceControl(
            identity: identity,
            nameForTargetDependencyResolutionOnly: nameForTargetDependencyResolutionOnly,
            path: path,
            requirement: requirement,
            productFilter: productFilter,
            traits: nil
        )
    }

    package static func localSourceControl(
        identity: PackageIdentity,
        nameForTargetDependencyResolutionOnly: String?,
        path: AbsolutePath,
        requirement: SourceControl.Requirement,
        productFilter: ProductFilter,
        traits: Set<Trait>?
    ) -> Self {
        .sourceControl(
            identity: identity,
            nameForTargetDependencyResolutionOnly: nameForTargetDependencyResolutionOnly,
            location: .local(path),
            requirement: requirement,
            productFilter: productFilter,
            traits: traits
        )
    }
    
    public static func remoteSourceControl(
        identity: PackageIdentity,
        nameForTargetDependencyResolutionOnly: String?,
        url: SourceControlURL,
        requirement: SourceControl.Requirement,
        productFilter: ProductFilter
    ) -> Self {
        .remoteSourceControl(
            identity: identity,
            nameForTargetDependencyResolutionOnly: nameForTargetDependencyResolutionOnly,
            url: url,
            requirement: requirement,
            productFilter: productFilter,
            traits: nil
        )
    }

    package static func remoteSourceControl(
        identity: PackageIdentity,
        nameForTargetDependencyResolutionOnly: String?,
        url: SourceControlURL,
        requirement: SourceControl.Requirement,
        productFilter: ProductFilter,
        traits: Set<Trait>?
    ) -> Self {
        .sourceControl(
            identity: identity,
            nameForTargetDependencyResolutionOnly: nameForTargetDependencyResolutionOnly,
            location: .remote(url),
            requirement: requirement,
            productFilter: productFilter,
            traits: traits
        )
    }

    public static func sourceControl(
        identity: PackageIdentity,
        nameForTargetDependencyResolutionOnly: String?,
        location: SourceControl.Location,
        requirement: SourceControl.Requirement,
        productFilter: ProductFilter
    ) -> Self {
        .sourceControl(
            identity: identity,
            nameForTargetDependencyResolutionOnly: nameForTargetDependencyResolutionOnly,
            location: location,
            requirement: requirement,
            productFilter: productFilter,
            traits: nil
        )
    }

    package static func sourceControl(
        identity: PackageIdentity,
        nameForTargetDependencyResolutionOnly: String?,
        location: SourceControl.Location,
        requirement: SourceControl.Requirement,
        productFilter: ProductFilter,
        traits: Set<Trait>?
    ) -> Self {
        .sourceControl(
            .init(
                identity: identity,
                nameForTargetDependencyResolutionOnly: nameForTargetDependencyResolutionOnly,
                location: location,
                requirement: requirement,
                productFilter: productFilter,
                traits: traits
            )
        )
    }

    public static func registry(
        identity: PackageIdentity,
        requirement: Registry.Requirement,
        productFilter: ProductFilter
    ) -> Self {
        .registry(
            identity: identity,
            requirement: requirement,
            productFilter: productFilter,
            traits: nil
        )
    }

    package static func registry(
        identity: PackageIdentity,
        requirement: Registry.Requirement,
        productFilter: ProductFilter,
        traits: Set<Trait>?
    ) -> Self {
        .registry(
            .init(
                identity: identity,
                requirement: requirement,
                productFilter: productFilter,
                traits: traits
            )
        )
    }
}

extension Range {
    public static func upToNextMajor(from version: Version) -> Range<Bound> where Bound == Version {
        return version ..< Version(version.major + 1, 0, 0)
    }

    public static func upToNextMinor(from version: Version) -> Range<Bound> where Bound == Version {
        return version ..< Version(version.major, version.minor + 1, 0)
    }
}

extension PackageDependency: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fileSystem(let data):
            return "fileSystem[\(data)]"
        case .sourceControl(let data):
            return "sourceControl[\(data)]"
        case .registry(let data):
            return "registry[\(data)]"
        }
    }
}

extension PackageDependency.SourceControl.Requirement: CustomStringConvertible {
    public var description: String {
        switch self {
        case .exact(let version):
            return version.description
        case .range(let range):
            return range.description
        case .revision(let revision):
            return "revision[\(revision)]"
        case .branch(let branch):
            return "branch[\(branch)]"
        }
    }
}

extension PackageDependency.Registry.Requirement: CustomStringConvertible {
    public var description: String {
        switch self {
        case .exact(let version):
            return version.description
        case .range(let range):
            return range.description
        }
    }
}

extension PackageDependency: Encodable {
    private enum CodingKeys: String, CodingKey {
        case local, fileSystem, scm, sourceControl, registry
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fileSystem(let settings):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .fileSystem)
            try unkeyedContainer.encode(settings)
        case .sourceControl(let settings):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .sourceControl)
            try unkeyedContainer.encode(settings)
        case .registry(let settings):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .registry)
            try unkeyedContainer.encode(settings)
        }
    }
}

extension PackageDependency.SourceControl.Requirement: Encodable {
    private enum CodingKeys: String, CodingKey {
        case exact, range, revision, branch
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .exact(a1):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .exact)
            try unkeyedContainer.encode(a1)
        case let .range(a1):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .range)
            try unkeyedContainer.encode(CodableRange(a1))
        case let .revision(a1):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .revision)
            try unkeyedContainer.encode(a1)
        case let .branch(a1):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .branch)
            try unkeyedContainer.encode(a1)
        }
    }
}

extension PackageDependency.SourceControl.Location: Encodable {
    private enum CodingKeys: String, CodingKey {
        case local, remote
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let path):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .local)
            try unkeyedContainer.encode(path)
        case .remote(let url):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .remote)
            try unkeyedContainer.encode(url)
        }
    }
}

extension PackageDependency.Registry.Requirement: Encodable {
    private enum CodingKeys: String, CodingKey {
        case exact, range
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .exact(a1):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .exact)
            try unkeyedContainer.encode(a1)
        case let .range(a1):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .range)
            try unkeyedContainer.encode(CodableRange(a1))
        }
    }
}
