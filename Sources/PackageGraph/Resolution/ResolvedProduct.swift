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
import PackageModel

public struct ResolvedProduct {
    /// The name of this product.
    public var name: String {
        self.underlying.name
    }

    /// The type of this product.
    public var type: ProductType {
        self.underlying.type
    }

    public let packageIdentity: PackageIdentity

    /// The underlying product.
    public let underlying: Product

    @available(*, deprecated, renamed: "modules")
    public var targets: IdentifiableSet<ResolvedModule> { self.modules }

    /// The top level modules contained in this product.
    public internal(set) var modules: IdentifiableSet<ResolvedModule>

    @available(*, deprecated, renamed: "testEntryPointModule")
    public var testEntryPointTarget: ResolvedModule? { self.testEntryPointModule }

    /// Executable module for test entry point file.
    public let testEntryPointModule: ResolvedModule?

    /// The default localization for resources.
    public let defaultLocalization: String?

    /// The list of platforms that are supported by this product.
    public let supportedPlatforms: [SupportedPlatform]

    public let platformVersionProvider: PlatformVersionProvider

    /// Triple for which this resolved product should be compiled for.
    public internal(set) var buildTriple: BuildTriple {
        didSet {
            self.updateBuildTriplesOfDependencies()
        }
    }

    @available(*, deprecated, renamed: "executableModule")
    public var executableTarget: ResolvedModule { get throws { try self.executableModule } }

    /// The main executable module of this product.
    ///
    /// Note: This property is only valid for executable products.
    public var executableModule: ResolvedModule {
        get throws {
            guard self.type == .executable || self.type == .snippet || self.type == .macro else {
                throw InternalError("`executableTarget` should only be called for executable targets")
            }
            guard let underlyingExecutableModule = modules.map(\.underlying).executables.first,
                  let executableModule = modules.first(where: { $0.underlying == underlyingExecutableModule })
            else {
                throw InternalError("could not determine executable target")
            }
            return executableModule
        }
    }

    @available(*, deprecated, renamed: "init(packageIdentity:product:modules:)")
    public init(
        packageIdentity: PackageIdentity,
        product: Product,
        targets: IdentifiableSet<ResolvedModule>
    ) {
        self.init(packageIdentity: packageIdentity, product: product, modules: targets)
    }

    public init(
        packageIdentity: PackageIdentity,
        product: Product,
        modules: IdentifiableSet<ResolvedModule>
    ) {
        assert(product.modules.count == modules.count && product.modules.map(\.name).sorted() == modules.map(\.name).sorted())
        self.packageIdentity = packageIdentity
        self.underlying = product
        self.modules = modules

        // defaultLocalization is currently shared across the entire package
        // this may need to be enhanced if / when we support localization per module or product
        let defaultLocalization = self.modules.first?.defaultLocalization
        self.defaultLocalization = defaultLocalization

        let (platforms, platformVersionProvider) = Self.computePlatforms(modules: modules)
        self.supportedPlatforms = platforms
        self.platformVersionProvider = platformVersionProvider

        self.testEntryPointModule = product.testEntryPointPath.map { testEntryPointPath in
            // Create an executable resolved module with the entry point file, adding product's modules as dependencies.
            let dependencies: [Module.Dependency] = product.modules.map { .module($0, conditions: []) }
            let swiftModule = SwiftModule(
                name: product.name,
                dependencies: dependencies,
                packageAccess: true, // entry point module so treated as a part of the package
                testEntryPointPath: testEntryPointPath
            )
            return ResolvedModule(
                packageIdentity: packageIdentity,
                underlying: swiftModule,
                dependencies: modules.map { .module($0, conditions: []) },
                defaultLocalization: defaultLocalization ?? .none, // safe since this is a derived product
                supportedPlatforms: platforms,
                platformVersionProvider: platformVersionProvider
            )
        }
        
        if product.type == .test {
            // Make sure that test products are built for the tools triple if it has tools as direct dependencies.
            // Without this workaround, `assertMacroExpansion` in tests can't be built, as it requires macros
            // and SwiftSyntax to be built for the same triple as the tests.
            // See https://github.com/swiftlang/swift-package-manager/pull/7349 for more context.
            var inferredBuildTriple = BuildTriple.destination
            modulesLoop: for module in modules {
                for dependency in module.dependencies {
                    switch dependency {
                    case .module(let moduleDependency, _):
                        if moduleDependency.type == .macro {
                            inferredBuildTriple = .tools
                            break modulesLoop
                        }
                    case .product(let productDependency, _):
                        if productDependency.type == .macro {
                            inferredBuildTriple = .tools
                            break modulesLoop
                        }
                    }
                }
            }
            self.buildTriple = inferredBuildTriple
        } else {
            self.buildTriple = product.buildTriple
        }
        self.updateBuildTriplesOfDependencies()
    }

    mutating func updateBuildTriplesOfDependencies() {
        self.modules = IdentifiableSet(self.modules.map {
            var module = $0
            module.buildTriple = self.buildTriple
            return module
        })
    }

    @available(*, deprecated, renamed: "containsSwiftModules")
    public var containsSwiftTargets: Bool { self.containsSwiftModules }

    /// True if this product contains Swift modules.
    public var containsSwiftModules: Bool {
        //  C modules can't import Swift modules in SwiftPM (at least not right
        // now), so we can just look at the top-level modules.
        //
        // If that ever changes, we'll need to do something more complex here,
        // recursively checking dependencies for SwiftModules, and considering
        // dynamic library modules to be Swift modules (since the dylib could
        // contain Swift code we don't know about as part of this build).
        self.modules.contains { $0.underlying is SwiftModule }
    }

    @available(*, deprecated, renamed: "recursiveModuleDependencies")
    public func recursiveTargetDependencies() throws -> [ResolvedModule] { try self.recursiveModuleDependencies() }

    /// Returns the recursive module dependencies.
    public func recursiveModuleDependencies() throws -> [ResolvedModule] {
        let recursiveDependencies = try modules.lazy.flatMap { try $0.recursiveModuleDependencies() }
        return Array(IdentifiableSet(self.modules).union(recursiveDependencies))
    }

    private static func computePlatforms(
        modules: IdentifiableSet<ResolvedModule>
    ) -> ([SupportedPlatform], PlatformVersionProvider) {
        let declaredPlatforms = modules.reduce(into: [SupportedPlatform]()) { partial, item in
            merge(into: &partial, platforms: item.supportedPlatforms)
        }

        return (
            declaredPlatforms.sorted(by: { $0.platform.name < $1.platform.name }),
            PlatformVersionProvider(implementation: .mergingFromModules(modules))
        )
    }

    public func getSupportedPlatform(for platform: Platform, usingXCTest: Bool) -> SupportedPlatform {
        self.platformVersionProvider.getDerived(
            declared: self.supportedPlatforms,
            for: platform,
            usingXCTest: usingXCTest
        )
    }

    func diagnoseInvalidUseOfUnsafeFlags(_ diagnosticsEmitter: DiagnosticsEmitter) throws {
        // Diagnose if any module in this product uses an unsafe flag.
        for module in try self.recursiveModuleDependencies() {
            if module.underlying.usesUnsafeFlags {
                diagnosticsEmitter.emit(.productUsesUnsafeFlags(product: self.name, target: module.name))
            }
        }
    }
}

extension ResolvedProduct: CustomStringConvertible {
    public var description: String {
        "<ResolvedProduct: \(self.name), \(self.type), \(self.buildTriple)>"
    }
}

extension ResolvedProduct {
    public var isLinkingXCTest: Bool {
        // To retain existing behavior, we have to check both the product type, as well as the types of all of its
        // modules.
        self.type == .test || self.modules.contains(where: { $0.type == .test })
    }
}

extension ResolvedProduct: Identifiable {
    /// Resolved module identity that uniquely identifies it in a resolution graph.
    public struct ID: Hashable {
        public let productName: String
        let packageIdentity: PackageIdentity
        public var buildTriple: BuildTriple
    }

    public var id: ID {
        ID(productName: self.name, packageIdentity: self.packageIdentity, buildTriple: self.buildTriple)
    }
}

@available(*, unavailable, message: "Use `Identifiable` conformance or `IdentifiableSet` instead")
extension ResolvedProduct: Hashable {}
