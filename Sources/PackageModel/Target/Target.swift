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
import Dispatch

import protocol TSCUtility.PolymorphicCodableProtocol

public class Target: PolymorphicCodableProtocol {
    public static var implementations: [PolymorphicCodableProtocol.Type] = [
        SwiftTarget.self,
        ClangTarget.self,
        MixedTarget.self,
        SystemLibraryTarget.self,
        BinaryTarget.self,
        PluginTarget.self,
    ]

    /// The target kind.
    public enum Kind: String, Codable {
        case executable
        case library
        case systemModule = "system-target"
        case test
        case binary
        case plugin
        case snippet
        case `macro`
    }

    /// A group a target belongs to that allows customizing access boundaries. A target is treated as
    /// a client outside of the package if `excluded`, inside the package boundary if `package`.
    public enum Group: Codable, Equatable {
        case package
        case excluded
    }
    /// A reference to a product from a target dependency.
    public struct ProductReference: Codable {

        /// The name of the product dependency.
        public let name: String

        /// The name of the package containing the product.
        public let package: String?

        /// Module aliases for targets of this product dependency. The key is an
        /// original target name and the value is a new unique name that also
        /// becomes the name of its .swiftmodule binary.
        public let moduleAliases: [String: String]?

        /// Fully qualified name for this product dependency: package ID + name of the product
        public var identity: String {
            if let package {
                return package.lowercased() + "_" + name
            } else {
                // this is hit only if this product is referenced `.byName(name)`
                // which assumes the name of this product, its package, and its target
                // all have the same name
                return name.lowercased() + "_" + name
            }
        }

        /// Creates a product reference instance.
        public init(name: String, package: String?, moduleAliases: [String: String]? = nil) {
            self.name = name
            self.package = package
            self.moduleAliases = moduleAliases
        }
    }

    /// A target dependency to a target or product.
    public enum Dependency {
        /// A dependency referencing another target, with conditions.
        case target(_ target: Target, conditions: [PackageCondition])

        /// A dependency referencing a product, with conditions.
        case product(_ product: ProductReference, conditions: [PackageCondition])

        /// The target if the dependency is a target dependency.
        public var target: Target? {
            if case .target(let target, _) = self {
                return target
            } else {
                return nil
            }
        }

        /// The product reference if the dependency is a product dependency.
        public var product: ProductReference? {
            if case .product(let product, _) = self {
                return product
            } else {
                return nil
            }
        }

        /// The dependency conditions.
        public var conditions: [PackageCondition] {
            switch self {
            case .target(_, let conditions):
                return conditions
            case .product(_, let conditions):
                return conditions
            }
        }

        /// The name of the target or product of the dependency.
        public var name: String {
            switch self {
            case .target(let target, _):
                return target.name
            case .product(let product, _):
                return product.name
            }
        }
    }

    /// A usage of a plugin target or product. Implemented as a dependency
    /// for now and added to the `dependencies` array, since they currently
    /// have exactly the same characteristics and to avoid duplicating the
    /// implementation for now.
    public typealias PluginUsage = Dependency

    /// The name of the target.
    ///
    /// NOTE: This name is not the language-level target (i.e., the importable
    /// name) name in many cases, instead use c99name if you need uniqueness.
    public private(set) var name: String

    /// Module aliases needed to build this target. The key is an original name of a
    /// dependent target and the value is a new unique name mapped to the name
    /// of its .swiftmodule binary.
    public private(set) var moduleAliases: [String: String]?
    /// Used to store pre-chained / pre-overriden module aliases
    public private(set) var prechainModuleAliases: [String: String]?
    /// Used to store aliases that should be referenced directly in source code
    public private(set) var directRefAliases: [String: [String]]?

    /// Add module aliases (if applicable) for dependencies of this target.
    ///
    /// For example, adding an alias `Bar` for a target name `Foo` will result in
    /// compiling references to `Foo` in source code of this target as `Bar.swiftmodule`.
    /// If the name argument `Foo` is the same as this target's name, this target will be
    /// renamed as `Bar` and the resulting binary will be `Bar.swiftmodule`.
    ///
    /// - Parameters:
    ///   - name: The original name of a dependent target or this target
    ///   - alias: A new unique name mapped to the resulting binary name
    public func addModuleAlias(for name: String, as alias: String) {
        if moduleAliases == nil {
            moduleAliases = [name: alias]
        } else {
            moduleAliases?[name] = alias
        }
    }

    public func removeModuleAlias(for name: String) {
        moduleAliases?.removeValue(forKey: name)
        if moduleAliases?.isEmpty ?? false {
            moduleAliases = nil
        }
    }

    public func addPrechainModuleAlias(for name: String, as alias: String) {
        if prechainModuleAliases == nil {
            prechainModuleAliases = [name: alias]
        } else {
            prechainModuleAliases?[name] = alias
        }
    }
    public func addDirectRefAliases(for name: String, as aliases: [String]) {
        if directRefAliases == nil {
            directRefAliases = [name: aliases]
        } else {
            directRefAliases?[name] = aliases
        }
    }

    @discardableResult
    public func applyAlias() -> Bool {
        // If there's an alias for this target, rename
        if let alias = moduleAliases?[name] {
            self.name = alias
            self.c99name = alias.spm_mangledToC99ExtendedIdentifier()
            return true
        }
        return false
    }

    /// The dependencies of this target.
    public let dependencies: [Dependency]

    /// The language-level target name.
    public private(set) var c99name: String

    /// The bundle name, if one is being generated.
    public var bundleName: String? {
        return resources.isEmpty ? nil : potentialBundleName
    }
    public let potentialBundleName: String?

    /// Suffix that's expected for test targets.
    public static let testModuleNameSuffix = "Tests"

    /// The kind of target.
    public let type: Kind

    /// If true, access to package declarations from other targets is allowed.
    public let packageAccess: Bool

    /// The path of the target.
    public let path: AbsolutePath

    /// The sources for the target.
    public let sources: Sources

    /// The resource files in the target.
    public let resources: [Resource]

    /// Files in the target that were marked as ignored.
    public let ignored: [AbsolutePath]

    /// Other kinds of files in the target.
    public let others: [AbsolutePath]

    /// The build settings assignments of this target.
    public let buildSettings: BuildSettings.AssignmentTable

    /// The usages of package plugins by this target.
    public let pluginUsages: [PluginUsage]

    /// Whether or not this target uses any custom unsafe flags.
    public let usesUnsafeFlags: Bool

    init(
        name: String,
        potentialBundleName: String? = nil,
        type: Kind,
        path: AbsolutePath,
        sources: Sources,
        resources: [Resource] = [],
        ignored: [AbsolutePath] = [],
        others: [AbsolutePath] = [],
        dependencies: [Target.Dependency],
        packageAccess: Bool,
        buildSettings: BuildSettings.AssignmentTable,
        pluginUsages: [PluginUsage],
        usesUnsafeFlags: Bool
    ) {
        self.name = name
        self.potentialBundleName = potentialBundleName
        self.type = type
        self.path = path
        self.sources = sources
        self.resources = resources
        self.ignored = ignored
        self.others = others
        self.dependencies = dependencies
        self.c99name = self.name.spm_mangledToC99ExtendedIdentifier()
        self.packageAccess = packageAccess
        self.buildSettings = buildSettings
        self.pluginUsages = pluginUsages
        self.usesUnsafeFlags = usesUnsafeFlags
    }

    private enum CodingKeys: String, CodingKey {
        case name, potentialBundleName, defaultLocalization, platforms, type, path, sources, resources, ignored, others, packageAccess, buildSettings, pluginUsages, usesUnsafeFlags
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        // FIXME: dependencies property is skipped on purpose as it points to
        // the actual target dependency object.
        try container.encode(name, forKey: .name)
        try container.encode(potentialBundleName, forKey: .potentialBundleName)
        try container.encode(type, forKey: .type)
        try container.encode(path, forKey: .path)
        try container.encode(sources, forKey: .sources)
        try container.encode(resources, forKey: .resources)
        try container.encode(ignored, forKey: .ignored)
        try container.encode(others, forKey: .others)
        try container.encode(packageAccess, forKey: .packageAccess)
        try container.encode(buildSettings, forKey: .buildSettings)
        // FIXME: pluginUsages property is skipped on purpose as it points to
        // the actual target dependency object.
        try container.encode(usesUnsafeFlags, forKey: .usesUnsafeFlags)
    }

    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.potentialBundleName = try container.decodeIfPresent(String.self, forKey: .potentialBundleName)
        self.type = try container.decode(Kind.self, forKey: .type)
        self.path = try container.decode(AbsolutePath.self, forKey: .path)
        self.sources = try container.decode(Sources.self, forKey: .sources)
        self.resources = try container.decode([Resource].self, forKey: .resources)
        self.ignored = try container.decode([AbsolutePath].self, forKey: .ignored)
        self.others = try container.decode([AbsolutePath].self, forKey: .others)
        // FIXME: dependencies property is skipped on purpose as it points to
        // the actual target dependency object.
        self.dependencies = []
        self.c99name = self.name.spm_mangledToC99ExtendedIdentifier()
        self.packageAccess = try container.decode(Bool.self, forKey: .packageAccess)
        self.buildSettings = try container.decode(BuildSettings.AssignmentTable.self, forKey: .buildSettings)
        // FIXME: pluginUsages property is skipped on purpose as it points to
        // the actual target dependency object.
        self.pluginUsages = []
        self.usesUnsafeFlags = try container.decode(Bool.self, forKey: .usesUnsafeFlags)
    }
}

extension Target: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public static func == (lhs: Target, rhs: Target) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
}

extension Target: CustomStringConvertible {
    public var description: String {
        return "<\(Swift.type(of: self)): \(name)>"
    }
}

public extension Sequence where Iterator.Element == Target {
    var executables: [Target] {
        return filter {
            switch $0.type {
            case .binary:
                return ($0 as? BinaryTarget)?.containsExecutable == true
            case .executable, .snippet, .macro:
                return true
            default:
                return false
            }
        }
    }
}
