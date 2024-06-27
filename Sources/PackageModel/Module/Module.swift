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

@available(*, deprecated, renamed: "Module")
public typealias Target = Module

public class Module {
    /// Description of the module type used in `swift package describe` output. Preserved for backwards compatibility.
    public class var typeDescription: String { fatalError("implement in a subclass") }
    /// The module kind.
    public enum Kind: String {
        case executable
        case library
        case systemModule = "system-target"
        case test
        case binary
        case plugin
        case snippet
        case `macro`
        case providedLibrary
    }

    /// A group a module belongs to that allows customizing access boundaries. A module is treated as
    /// a client outside of the package if `excluded`, inside the package boundary if `package`.
    public enum Group: Equatable {
        case package
        case excluded
    }

    /// A reference to a product from a module dependency.
    public struct ProductReference {
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
                // which assumes the name of this product, its package, and its module
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

    /// A module dependency to a module or product.
    public enum Dependency {
        /// A dependency referencing another target, with conditions.
        case module(_ target: Module, conditions: [PackageCondition])

        /// A dependency referencing a product, with conditions.
        case product(_ product: ProductReference, conditions: [PackageCondition])


        @available(*, deprecated, renamed: "module")
        public var target: Module? { self.module }

        /// The module if the dependency is a target dependency.
        public var module: Module? {
            if case .module(let target, _) = self {
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
            case .module(_, let conditions):
                return conditions
            case .product(_, let conditions):
                return conditions
            }
        }

        /// The name of the target or product of the dependency.
        public var name: String {
            switch self {
            case .module(let target, _):
                return target.name
            case .product(let product, _):
                return product.name
            }
        }
    }

    /// A usage of a plugin module or product. Implemented as a dependency
    /// for now and added to the `dependencies` array, since they currently
    /// have exactly the same characteristics and to avoid duplicating the
    /// implementation for now.
    public typealias PluginUsage = Dependency

    /// The name of the module.
    ///
    /// NOTE: This name is not the language-level module (i.e., the importable
    /// name) name in many cases, instead use ``Target/c99name`` if you need uniqueness.
    public private(set) var name: String

    /// Module aliases needed to build this module. The key is an original name of a
    /// dependent module and the value is a new unique name mapped to the name
    /// of its .swiftmodule binary.
    public private(set) var moduleAliases: [String: String]?
    /// Used to store pre-chained / pre-overriden module aliases
    public private(set) var prechainModuleAliases: [String: String]?
    /// Used to store aliases that should be referenced directly in source code
    public private(set) var directRefAliases: [String: [String]]?

    /// Add module aliases (if applicable) for dependencies of this module.
    ///
    /// For example, adding an alias `Bar` for a module name `Foo` will result in
    /// compiling references to `Foo` in source code of this module as `Bar.swiftmodule`.
    /// If the name argument `Foo` is the same as this module's name, this module will be
    /// renamed as `Bar` and the resulting binary will be `Bar.swiftmodule`.
    ///
    /// - Parameters:
    ///   - name: The original name of a dependent module or this module
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
        // If there's an alias for this module, rename
        if let alias = moduleAliases?[name] {
            self.name = alias
            self.c99name = alias.spm_mangledToC99ExtendedIdentifier()
            return true
        }
        return false
    }

    /// The dependencies of this module.
    public let dependencies: [Dependency]

    /// The language-level module name.
    public private(set) var c99name: String

    /// The bundle name, if one is being generated.
    public var bundleName: String? {
        return resources.isEmpty ? nil : potentialBundleName
    }
    public let potentialBundleName: String?

    /// Suffix that's expected for test targets.
    public static let testModuleNameSuffix = "Tests"

    /// The kind of module.
    public let type: Kind

    /// If true, access to package declarations from other modules is allowed.
    public let packageAccess: Bool

    /// The path of the module.
    public let path: AbsolutePath

    /// The sources for the module.
    public let sources: Sources

    /// The resource files in the module.
    public let resources: [Resource]

    /// Files in the target that were marked as ignored.
    public let ignored: [AbsolutePath]

    /// Other kinds of files in the module.
    public let others: [AbsolutePath]

    /// The build settings assignments of this module.
    public let buildSettings: BuildSettings.AssignmentTable

    @_spi(SwiftPMInternal)
    public let buildSettingsDescription: [TargetBuildSettingDescription.Setting]

    /// The usages of package plugins by this module.
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
        dependencies: [Module.Dependency],
        packageAccess: Bool,
        buildSettings: BuildSettings.AssignmentTable,
        buildSettingsDescription: [TargetBuildSettingDescription.Setting],
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
        self.buildSettingsDescription = buildSettingsDescription
        self.pluginUsages = pluginUsages
        self.usesUnsafeFlags = usesUnsafeFlags
    }

    @_spi(SwiftPMInternal)
    public var isEmbeddedSwiftTarget: Bool {
        for case .enableExperimentalFeature("Embedded") in self.buildSettingsDescription.swiftSettings.map(\.kind) {
            return true
        }

        return false
    }
}

extension Module: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public static func == (lhs: Module, rhs: Module) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
}

extension Module: CustomStringConvertible {
    public var description: String {
        return "<\(Swift.type(of: self)): \(name)>"
    }
}

public extension Sequence where Iterator.Element == Module {
    var executables: [Module] {
        return filter {
            switch $0.type {
            case .binary:
                return ($0 as? BinaryModule)?.containsExecutable == true
            case .executable, .snippet, .macro:
                return true
            default:
                return false
            }
        }
    }
}

extension [TargetBuildSettingDescription.Setting] {
    @_spi(SwiftPMInternal)
    public var swiftSettings: Self {
        self.filter { $0.tool == .swift }
    }
}
