//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2015-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation
import LLBuildManifest
import OrderedCollections
import PackageGraph
import PackageLoading
import PackageModel
import SPMBuildCore
@_implementationOnly import SwiftDriver

import enum TSCBasic.ProcessEnv
import func TSCBasic.topologicalSort

import enum TSCUtility.Diagnostics
import var TSCUtility.verbosity

extension String {
    var asSwiftStringLiteralConstant: String {
        return unicodeScalars.reduce("", { $0 + $1.escaped(asASCII: false) })
    }
}

extension Array where Element == String {
    /// Converts a set of C compiler flags into an equivalent set to be
    /// indirected through the Swift compiler instead.
    func asSwiftcCCompilerFlags() -> Self {
        self.flatMap { ["-Xcc", $0] }
    }

    /// Converts a set of C++ compiler flags into an equivalent set to be
    /// indirected through the Swift compiler instead.
    func asSwiftcCXXCompilerFlags() -> Self {
        _ = self.flatMap { ["-Xcxx", $0] }
        // TODO: Pass -Xcxx flags to swiftc (#6491)
        // Remove fatal error when downstream support arrives.
        fatalError("swiftc does support -Xcxx flags yet.")
    }

    /// Converts a set of linker flags into an equivalent set to be indirected
    /// through the Swift compiler instead.
    ///
    /// Some arguments can be passed directly to the Swift compiler. We omit
    /// prefixing these arguments (in both the "-option value" and
    /// "-option[=]value" forms) with "-Xlinker". All other arguments are
    /// prefixed with "-Xlinker".
    func asSwiftcLinkerFlags() -> Self {
        // Arguments that can be passed directly to the Swift compiler and
        // doesn't require -Xlinker prefix.
        //
        // We do this to avoid sending flags like linker search path at the end
        // of the search list.
        let directSwiftLinkerArgs = ["-L"]

        var flags: [String] = []
        var it = self.makeIterator()
        while let flag = it.next() {
            if directSwiftLinkerArgs.contains(flag) {
                // `<option> <value>` variant.
                flags.append(flag)
                guard let nextFlag = it.next() else {
                    // We expected a flag but don't have one.
                    continue
                }
                flags.append(nextFlag)
            } else if directSwiftLinkerArgs.contains(where: { flag.hasPrefix($0) }) {
                // `<option>[=]<value>` variant.
                flags.append(flag)
            } else {
                flags += ["-Xlinker", flag]
            }
        }
        return flags
    }
}

extension BuildParameters {
    /// Returns the directory to be used for module cache.
    public var moduleCache: AbsolutePath {
        get throws {
            // FIXME: We use this hack to let swiftpm's functional test use shared
            // cache so it doesn't become painfully slow.
            if let path = ProcessEnv.vars["SWIFTPM_TESTS_MODULECACHE"] {
                return try AbsolutePath(validating: path)
            }
            return buildPath.appending("ModuleCache")
        }
    }

    /// Returns the compiler arguments for the index store, if enabled.
    func indexStoreArguments(for target: ResolvedTarget) -> [String] {
        let addIndexStoreArguments: Bool
        switch indexStoreMode {
        case .on:
            addIndexStoreArguments = true
        case .off:
            addIndexStoreArguments = false
        case .auto:
            if configuration == .debug {
                addIndexStoreArguments = true
            } else if target.type == .test {
                // Test discovery requires an index store for the test target to discover the tests
                addIndexStoreArguments = true
            } else {
                addIndexStoreArguments = false
            }
        }

        if addIndexStoreArguments {
            return ["-index-store-path", indexStore.pathString]
        }
        return []
    }

    /// Computes the target triple arguments for a given resolved target.
    public func targetTripleArgs(for target: ResolvedTarget) throws -> [String] {
        var args = ["-target"]
        // Compute the triple string for Darwin platform using the platform version.
        if targetTriple.isDarwin() {
            let platform = buildEnvironment.platform
            let supportedPlatform = target.platforms.getDerived(for: platform, usingXCTest: target.type == .test)
            args += [targetTriple.tripleString(forPlatformVersion: supportedPlatform.version.versionString)]
        } else {
            args += [targetTriple.tripleString]
        }
        return args
    }

    /// Computes the linker flags to use in order to rename a module-named main function to 'main' for the target platform, or nil if the linker doesn't support it for the platform.
    func linkerFlagsForRenamingMainFunction(of target: ResolvedTarget) -> [String]? {
        let args: [String]
        if self.targetTriple.isApple() {
            args = ["-alias", "_\(target.c99name)_main", "_main"]
        }
        else if self.targetTriple.isLinux() {
            args = ["--defsym", "main=\(target.c99name)_main"]
        }
        else {
            return nil
        }
        return args.asSwiftcLinkerFlags()
    }

    /// Returns the scoped view of build settings for a given target.
    func createScope(for target: ResolvedTarget) -> BuildSettings.Scope {
        return BuildSettings.Scope(target.underlyingTarget.buildSettings, environment: buildEnvironment)
    }
}

/// A build plan for a package graph.
public class BuildPlan: SPMBuildCore.BuildPlan {

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        /// There is no buildable target in the graph.
        case noBuildableTarget

        public var description: String {
            switch self {
            case .noBuildableTarget:
                return """
                The package does not contain a buildable target. 
                Add at least one `.target` or `.executableTarget` to your `Package.swift`.
                """
            }
        }
    }

    /// The build parameters.
    public let buildParameters: BuildParameters

    /// The build environment.
    private var buildEnvironment: BuildEnvironment {
        buildParameters.buildEnvironment
    }

    /// The package graph.
    public let graph: PackageGraph

    /// The target build description map.
    public let targetMap: [ResolvedTarget: TargetBuildDescription]

    /// The product build description map.
    public let productMap: [ResolvedProduct: ProductBuildDescription]

    /// The plugin descriptions. Plugins are represented in the package graph
    /// as targets, but they are not directly included in the build graph.
    public let pluginDescriptions: [PluginDescription]

    /// The build targets.
    public var targets: AnySequence<TargetBuildDescription> {
        return AnySequence(targetMap.values)
    }

    /// The products in this plan.
    public var buildProducts: AnySequence<SPMBuildCore.ProductBuildDescription> {
        return AnySequence(productMap.values.map { $0 as SPMBuildCore.ProductBuildDescription })
    }

    /// The results of invoking any build tool plugins used by targets in this build.
    public let buildToolPluginInvocationResults: [ResolvedTarget: [BuildToolPluginInvocationResult]]

    /// The results of running any prebuild commands for the targets in this build.  This includes any derived
    /// source files as well as directories to which any changes should cause us to reevaluate the build plan.
    public let prebuildCommandResults: [ResolvedTarget: [PrebuildCommandResult]]

    private var derivedTestTargetsMap: [ResolvedProduct: [ResolvedTarget]] = [:]

    /// Cache for pkgConfig flags.
    private var pkgConfigCache = [SystemLibraryTarget: (cFlags: [String], libs: [String])]()

    /// Cache for library information.
    private var externalLibrariesCache = [BinaryTarget: [LibraryInfo]]()

    /// Cache for tools information.
    private var externalExecutablesCache = [BinaryTarget: [ExecutableInfo]]()

    /// The filesystem to operate on.
    private let fileSystem: FileSystem

    /// ObservabilityScope with which to emit diagnostics
    private let observabilityScope: ObservabilityScope

    private static func makeDerivedTestTargets(
        _ buildParameters: BuildParameters,
        _ graph: PackageGraph,
        _ fileSystem: FileSystem,
        _ observabilityScope: ObservabilityScope
    ) throws -> [(product: ResolvedProduct, discoveryTargetBuildDescription: SwiftTargetBuildDescription?, entryPointTargetBuildDescription: SwiftTargetBuildDescription)] {
        guard buildParameters.testProductStyle.requiresAdditionalDerivedTestTargets,
              case .entryPointExecutable(let explicitlyEnabledDiscovery, let explicitlySpecifiedPath) = buildParameters.testProductStyle
        else {
            throw InternalError("makeTestManifestTargets should not be used for build plan which does not require additional derived test targets")
        }

        let isEntryPointPathSpecifiedExplicitly = explicitlySpecifiedPath != nil

        var isDiscoveryEnabledRedundantly = explicitlyEnabledDiscovery && !isEntryPointPathSpecifiedExplicitly
        var result: [(ResolvedProduct, SwiftTargetBuildDescription?, SwiftTargetBuildDescription)] = []
        for testProduct in graph.allProducts where testProduct.type == .test {
            guard let package = graph.package(for: testProduct) else {
                throw InternalError("package not found for \(testProduct)")
            }
            isDiscoveryEnabledRedundantly = isDiscoveryEnabledRedundantly && nil == testProduct.testEntryPointTarget
            // If a non-explicitly specified test entry point file exists, prefer that over test discovery.
            // This is designed as an escape hatch when test discovery is not appropriate and for backwards
            // compatibility for projects that have existing test entry point files (e.g. XCTMain.swift, LinuxMain.swift).
            let toolsVersion = graph.package(for: testProduct)?.manifest.toolsVersion ?? .v5_5

            // If `testProduct.testEntryPointTarget` is non-nil, it may either represent an `XCTMain.swift` (formerly `LinuxMain.swift`) file
            // if such a file is located in the package, or it may represent a test entry point file at a path specified by the option
            // `--experimental-test-entry-point-path <file>`. The latter is useful because it still performs test discovery and places the discovered
            // tests into a separate target/module named "<PackageName>PackageDiscoveredTests". Then, that entry point file may import that module and
            // obtain that list to pass it to the `XCTMain(...)` function and avoid needing to maintain a list of tests itself.
            if testProduct.testEntryPointTarget != nil && explicitlyEnabledDiscovery && !isEntryPointPathSpecifiedExplicitly {
                let testEntryPointName = testProduct.underlyingProduct.testEntryPointPath?.basename ?? SwiftTarget.defaultTestEntryPointName
                observabilityScope.emit(warning: "'--enable-test-discovery' was specified so the '\(testEntryPointName)' entry point file for '\(testProduct.name)' will be ignored and an entry point will be generated automatically. To use test discovery with a custom entry point file, pass '--experimental-test-entry-point-path <file>'.")
            } else if testProduct.testEntryPointTarget == nil, let testEntryPointPath = explicitlySpecifiedPath, !fileSystem.exists(testEntryPointPath) {
                observabilityScope.emit(error: "'--experimental-test-entry-point-path' was specified but the file '\(testEntryPointPath)' could not be found.")
            }

            /// Generates test discovery targets, which contain derived sources listing the discovered tests.
            func generateDiscoveryTargets() throws -> (target: SwiftTarget, resolved: ResolvedTarget, buildDescription: SwiftTargetBuildDescription) {
                let discoveryTargetName = "\(package.manifest.displayName)PackageDiscoveredTests"
                let discoveryDerivedDir = buildParameters.buildPath.appending(components: "\(discoveryTargetName).derived")
                let discoveryMainFile = discoveryDerivedDir.appending(component: LLBuildManifest.TestDiscoveryTool.mainFileName)

                var discoveryPaths: [AbsolutePath] = []
                discoveryPaths.append(discoveryMainFile)
                for testTarget in testProduct.targets {
                    let path = discoveryDerivedDir.appending(components: testTarget.name + ".swift")
                    discoveryPaths.append(path)
                }

                let discoveryTarget = SwiftTarget(
                    name: discoveryTargetName,
                    dependencies: testProduct.underlyingProduct.targets.map { .target($0, conditions: []) },
                    packageAccess: true, // test target is allowed access to package decls by default
                    testDiscoverySrc: Sources(paths: discoveryPaths, root: discoveryDerivedDir)
                )
                let discoveryResolvedTarget = ResolvedTarget(
                    target: discoveryTarget,
                    dependencies: testProduct.targets.map { .target($0, conditions: []) },
                    defaultLocalization: .none, // safe since this is a derived target
                    platforms: .init(declared: [], derivedXCTestPlatformProvider: .none) // safe since this is a derived target
                )
                let discoveryTargetBuildDescription = try SwiftTargetBuildDescription(
                    package: package,
                    target: discoveryResolvedTarget,
                    toolsVersion: toolsVersion,
                    buildParameters: buildParameters,
                    testTargetRole: .discovery,
                    fileSystem: fileSystem,
                    observabilityScope: observabilityScope
                )

                return (discoveryTarget, discoveryResolvedTarget, discoveryTargetBuildDescription)
            }

            /// Generates a synthesized test entry point target, consisting of a single "main" file which calls the test entry
            /// point API and leverages the test discovery target to reference which tests to run.
            func generateSynthesizedEntryPointTarget(discoveryTarget: SwiftTarget, discoveryResolvedTarget: ResolvedTarget) throws -> SwiftTargetBuildDescription {
                let entryPointDerivedDir = buildParameters.buildPath.appending(components: "\(testProduct.name).derived")
                let entryPointMainFile = entryPointDerivedDir.appending(component: LLBuildManifest.TestEntryPointTool.mainFileName)
                let entryPointSources = Sources(paths: [entryPointMainFile], root: entryPointDerivedDir)

                let entryPointTarget = SwiftTarget(
                    name: testProduct.name,
                    type: .library,
                    dependencies: testProduct.underlyingProduct.targets.map { .target($0, conditions: []) } + [.target(discoveryTarget, conditions: [])],
                    packageAccess: true, // test target is allowed access to package decls
                    testEntryPointSources: entryPointSources
                )
                let entryPointResolvedTarget = ResolvedTarget(
                    target: entryPointTarget,
                    dependencies: testProduct.targets.map { .target($0, conditions: []) } + [.target(discoveryResolvedTarget, conditions: [])],
                    defaultLocalization: .none, // safe since this is a derived target
                    platforms: .init(declared: [], derivedXCTestPlatformProvider: .none) // safe since this is a derived target
                )
                return try SwiftTargetBuildDescription(
                    package: package,
                    target: entryPointResolvedTarget,
                    toolsVersion: toolsVersion,
                    buildParameters: buildParameters,
                    testTargetRole: .entryPoint(isSynthesized: true),
                    fileSystem: fileSystem,
                    observabilityScope: observabilityScope
                )
            }

            if let entryPointResolvedTarget = testProduct.testEntryPointTarget {
                if isEntryPointPathSpecifiedExplicitly || explicitlyEnabledDiscovery {
                    let discoveryTargets = try generateDiscoveryTargets()

                    if isEntryPointPathSpecifiedExplicitly {
                        // Allow using the explicitly-specified test entry point target, but still perform test discovery and thus declare a dependency on the discovery targets.
                        let entryPointTarget = SwiftTarget(
                            name: entryPointResolvedTarget.underlyingTarget.name,
                            dependencies: entryPointResolvedTarget.underlyingTarget.dependencies + [.target(discoveryTargets.target, conditions: [])],
                            packageAccess: entryPointResolvedTarget.packageAccess,
                            testEntryPointSources: entryPointResolvedTarget.underlyingTarget.sources
                        )
                        let entryPointResolvedTarget = ResolvedTarget(
                            target: entryPointTarget,
                            dependencies: entryPointResolvedTarget.dependencies + [.target(discoveryTargets.resolved, conditions: [])],
                            defaultLocalization: .none, // safe since this is a derived target
                            platforms: .init(declared: [], derivedXCTestPlatformProvider: .none) // safe since this is a derived target
                        )
                        let entryPointTargetBuildDescription = try SwiftTargetBuildDescription(
                            package: package,
                            target: entryPointResolvedTarget,
                            toolsVersion: toolsVersion,
                            buildParameters: buildParameters,
                            testTargetRole: .entryPoint(isSynthesized: false),
                            fileSystem: fileSystem,
                            observabilityScope: observabilityScope
                        )

                        result.append((testProduct, discoveryTargets.buildDescription, entryPointTargetBuildDescription))
                    } else {
                        // Ignore test entry point and synthesize one, declaring a dependency on the test discovery targets created above.
                        let entryPointTargetBuildDescription = try generateSynthesizedEntryPointTarget(discoveryTarget: discoveryTargets.target, discoveryResolvedTarget: discoveryTargets.resolved)
                        result.append((testProduct, discoveryTargets.buildDescription, entryPointTargetBuildDescription))
                    }
                } else {
                    // Use the test entry point as-is, without performing test discovery.
                    let entryPointTargetBuildDescription = try SwiftTargetBuildDescription(
                        package: package,
                        target: entryPointResolvedTarget,
                        toolsVersion: toolsVersion,
                        buildParameters: buildParameters,
                        testTargetRole: .entryPoint(isSynthesized: false),
                        fileSystem: fileSystem,
                        observabilityScope: observabilityScope
                    )
                    result.append((testProduct, nil, entryPointTargetBuildDescription))
                }
            } else {
                // Synthesize a test entry point target, declaring a dependency on the test discovery targets.
                let discoveryTargets = try generateDiscoveryTargets()
                let entryPointTargetBuildDescription = try generateSynthesizedEntryPointTarget(discoveryTarget: discoveryTargets.target, discoveryResolvedTarget: discoveryTargets.resolved)
                result.append((testProduct, discoveryTargets.buildDescription, entryPointTargetBuildDescription))
            }
        }

        if isDiscoveryEnabledRedundantly {
            observabilityScope.emit(warning: "'--enable-test-discovery' option is deprecated; tests are automatically discovered on all platforms")
        }

        return result
    }

    /// Create a build plan with build parameters and a package graph.
    public init(
        buildParameters: BuildParameters,
        graph: PackageGraph,
        additionalFileRules: [FileRuleDescription] = [],
        buildToolPluginInvocationResults: [ResolvedTarget: [BuildToolPluginInvocationResult]] = [:],
        prebuildCommandResults: [ResolvedTarget: [PrebuildCommandResult]] = [:],
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws {
        self.buildParameters = buildParameters
        self.graph = graph
        self.buildToolPluginInvocationResults = buildToolPluginInvocationResults
        self.prebuildCommandResults = prebuildCommandResults
        self.fileSystem = fileSystem
        self.observabilityScope = observabilityScope.makeChildScope(description: "Build Plan")

        var productMap: [ResolvedProduct: ProductBuildDescription] = [:]
        // Create product description for each product we have in the package graph that is eligible.
        for product in graph.allProducts where product.shouldCreateProductDescription {
            guard let package = graph.package(for: product) else {
                throw InternalError("unknown package for \(product)")
            }
            // Determine the appropriate tools version to use for the product.
            // This can affect what flags to pass and other semantics.
            let toolsVersion = package.manifest.toolsVersion
            productMap[product] = try ProductBuildDescription(
                package: package,
                product: product,
                toolsVersion: toolsVersion,
                buildParameters: buildParameters,
                fileSystem: fileSystem,
                observabilityScope: observabilityScope
            )
        }
        let macroProductsByTarget = productMap.keys.filter { $0.type == .macro }.reduce(into: [ResolvedTarget: ResolvedProduct]()) {
            if let target = $1.targets.first {
                $0[target] = $1
            }
        }

        // Create build target description for each target which we need to plan.
        // Plugin targets are noted, since they need to be compiled, but they do
        // not get directly incorporated into the build description that will be
        // given to LLBuild.
        var targetMap = [ResolvedTarget: TargetBuildDescription]()
        var pluginDescriptions = [PluginDescription]()
        var shouldGenerateTestObservation = true
        for target in graph.allTargets.sorted(by: { $0.name < $1.name }) {
            // Validate the product dependencies of this target.
            for dependency in target.dependencies {
                guard dependency.satisfies(buildParameters.buildEnvironment) else {
                    continue
                }

                switch dependency {
                case .target: break
                case .product(let product, _):
                    if buildParameters.targetTriple.isDarwin() {
                        try BuildPlan.validateDeploymentVersionOfProductDependency(
                            product: product,
                            forTarget: target,
                            observabilityScope: self.observabilityScope
                        )
                    }
                }
            }

            // Determine the appropriate tools version to use for the target.
            // This can affect what flags to pass and other semantics.
            let toolsVersion = graph.package(for: target)?.manifest.toolsVersion ?? .v5_5

            switch target.underlyingTarget {
            case is SwiftTarget:
                guard let package = graph.package(for: target) else {
                    throw InternalError("package not found for \(target)")
                }

                let requiredMacroProducts = try target.recursiveTargetDependencies().filter { $0.underlyingTarget.type == .macro }.compactMap { macroProductsByTarget[$0] }

                var generateTestObservation = false
                if target.type == .test && shouldGenerateTestObservation {
                    generateTestObservation = true
                    shouldGenerateTestObservation = false // Only generate the code once.
                }

                targetMap[target] = try .swift(SwiftTargetBuildDescription(
                    package: package,
                    target: target,
                    toolsVersion: toolsVersion,
                    additionalFileRules: additionalFileRules,
                    buildParameters: buildParameters,
                    buildToolPluginInvocationResults: buildToolPluginInvocationResults[target] ?? [],
                    prebuildCommandResults: prebuildCommandResults[target] ?? [],
                    requiredMacroProducts: requiredMacroProducts,
                    shouldGenerateTestObservation: generateTestObservation,
                    fileSystem: fileSystem,
                    observabilityScope: observabilityScope)
                )
            case is ClangTarget:
                targetMap[target] = try .clang(ClangTargetBuildDescription(
                    target: target,
                    toolsVersion: toolsVersion,
                    additionalFileRules: additionalFileRules,
                    buildParameters: buildParameters,
                    buildToolPluginInvocationResults: buildToolPluginInvocationResults[target] ?? [],
                    prebuildCommandResults: prebuildCommandResults[target] ?? [],
                    fileSystem: fileSystem,
                    observabilityScope: observabilityScope)
                )
            case is PluginTarget:
                guard let package = graph.package(for: target) else {
                    throw InternalError("package not found for \(target)")
                }
                try pluginDescriptions.append(PluginDescription(
                    target: target,
                    products: package.products.filter{ $0.targets.contains(target) },
                    package: package,
                    toolsVersion: toolsVersion,
                    fileSystem: fileSystem))
            case is SystemLibraryTarget, is BinaryTarget:
                 break
            default:
                 throw InternalError("unhandled \(target.underlyingTarget)")
            }
        }

        /// Ensure we have at least one buildable target.
        guard !targetMap.isEmpty else {
            throw Error.noBuildableTarget
        }

        // Abort now if we have any diagnostics at this point.
        guard !self.observabilityScope.errorsReported else {
            throw Diagnostics.fatalError
        }

        // Plan the derived test targets, if necessary.
        if buildParameters.testProductStyle.requiresAdditionalDerivedTestTargets {
            let derivedTestTargets = try Self.makeDerivedTestTargets(buildParameters, graph, self.fileSystem, self.observabilityScope)
            for item in derivedTestTargets {
                var derivedTestTargets = [item.entryPointTargetBuildDescription.target]

                targetMap[item.entryPointTargetBuildDescription.target] = .swift(item.entryPointTargetBuildDescription)

                if let discoveryTargetBuildDescription = item.discoveryTargetBuildDescription {
                    targetMap[discoveryTargetBuildDescription.target] = .swift(discoveryTargetBuildDescription)
                    derivedTestTargets.append(discoveryTargetBuildDescription.target)
                }

                derivedTestTargetsMap[item.product] = derivedTestTargets
            }
        }

        self.productMap = productMap
        self.targetMap = targetMap
        self.pluginDescriptions = pluginDescriptions

        // Finally plan these targets.
        try plan()
    }

    static func validateDeploymentVersionOfProductDependency(
        product: ResolvedProduct,
        forTarget target: ResolvedTarget,
        observabilityScope: ObservabilityScope
    ) throws {
        // Supported platforms are defined at the package level.
        // This will need to become a bit complicated once we have target-level or product-level platform support.
        let productPlatform = product.platforms.getDerived(for: .macOS, usingXCTest: product.isLinkingXCTest)
        let targetPlatform = target.platforms.getDerived(for: .macOS, usingXCTest: target.type == .test)

        // Check if the version requirement is satisfied.
        //
        // If the product's platform version is greater than ours, then it is incompatible.
        if productPlatform.version > targetPlatform.version {
            observabilityScope.emit(.productRequiresHigherPlatformVersion(
                target: target,
                targetPlatform: targetPlatform,
                product: product.name,
                productPlatform: productPlatform
            ))
        }
    }

    /// Plan the targets and products.
    private func plan() throws {
        // Plan targets.
        for buildTarget in targets {
            switch buildTarget {
            case .swift(let target):
                try self.plan(swiftTarget: target)
            case .clang(let target):
                try self.plan(clangTarget: target)
            }
        }

        // Plan products.
        for buildProduct in buildProducts {
            try plan(buildProduct as! ProductBuildDescription)
        }
        // FIXME: We need to find out if any product has a target on which it depends
        // both static and dynamically and then issue a suitable diagnostic or auto
        // handle that situation.
    }

    /// Plan a product.
    private func plan(_ buildProduct: ProductBuildDescription) throws {
        // Compute the product's dependency.
        let dependencies = try computeDependencies(of: buildProduct.product)

        // Add flags for system targets.
        for systemModule in dependencies.systemModules {
            guard case let target as SystemLibraryTarget = systemModule.underlyingTarget else {
                throw InternalError("This should not be possible.")
            }
            // Add pkgConfig libs arguments.
            buildProduct.additionalFlags += try pkgConfig(for: target).libs
        }

        // Add flags for binary dependencies.
        for binaryPath in dependencies.libraryBinaryPaths {
            if binaryPath.extension == "framework" {
                buildProduct.additionalFlags += ["-framework", binaryPath.basenameWithoutExt]
            } else if binaryPath.basename.starts(with: "lib") {
                buildProduct.additionalFlags += ["-l\(binaryPath.basenameWithoutExt.dropFirst(3))"]
            } else {
                self.observabilityScope.emit(error: "unexpected binary framework")
            }
        }

        // Link C++ if needed.
        // Note: This will come from build settings in future.
        for target in dependencies.staticTargets {
            if case let target as ClangTarget = target.underlyingTarget, target.isCXX {
                if buildParameters.targetTriple.isDarwin() {
                    buildProduct.additionalFlags += ["-lc++"]
                } else if buildParameters.targetTriple.isWindows() {
                    // Don't link any C++ library.
                } else {
                    buildProduct.additionalFlags += ["-lstdc++"]
                }
                break
            }
        }

        for target in dependencies.staticTargets {
            switch target.underlyingTarget {
            case is SwiftTarget:
                // Swift targets are guaranteed to have a corresponding Swift description.
                guard case .swift(let description) = targetMap[target] else {
                    throw InternalError("unknown target \(target)")
                }

                // Based on the debugging strategy, we either need to pass swiftmodule paths to the
                // product or link in the wrapped module object. This is required for properly debugging
                // Swift products. Debugging strategy is computed based on the current platform we're
                // building for and is nil for the release configuration.
                switch buildParameters.debuggingStrategy {
                case .swiftAST:
                    buildProduct.swiftASTs.insert(description.moduleOutputPath)
                case .modulewrap:
                    buildProduct.objects += [description.wrappedModuleOutputPath]
                case nil:
                    break
                }
            default: break
            }
        }

        buildProduct.staticTargets = dependencies.staticTargets
        buildProduct.dylibs = try dependencies.dylibs.map{
            guard let product = productMap[$0] else {
                throw InternalError("unknown product \($0)")
            }
            return product
        }
        buildProduct.objects += try dependencies.staticTargets.flatMap{ targetName -> [AbsolutePath] in
            guard let target = targetMap[targetName] else {
                throw InternalError("unknown target \(targetName)")
            }
            return try target.objects
        }
        buildProduct.libraryBinaryPaths = dependencies.libraryBinaryPaths

        buildProduct.availableTools = dependencies.availableTools
    }

    /// Computes the dependencies of a product.
    private func computeDependencies(
        of product: ResolvedProduct
    ) throws -> (
        dylibs: [ResolvedProduct],
        staticTargets: [ResolvedTarget],
        systemModules: [ResolvedTarget],
        libraryBinaryPaths: Set<AbsolutePath>,
        availableTools: [String: AbsolutePath]
    ) {
        /* Prior to tools-version 5.9, we used to errorneously recursively traverse executable/plugin dependencies and statically include their
         targets. For compatibility reasons, we preserve that behavior for older tools-versions. */
        let shouldExcludePlugins: Bool
        if let toolsVersion = self.graph.package(for: product)?.manifest.toolsVersion {
            shouldExcludePlugins = toolsVersion >= .v5_9
        } else {
            shouldExcludePlugins = false
        }

        // For test targets, we need to consider the first level of transitive dependencies since the first level is always test targets.
        let topLevelDependencies: [PackageModel.Target]
        if product.type == .test {
            topLevelDependencies = product.targets.flatMap { $0.underlyingTarget.dependencies }.compactMap {
                switch $0 {
                case .product:
                    return nil
                case .target(let target, _):
                    return target
                }
            }
        } else {
            topLevelDependencies = []
        }

        // Sort the product targets in topological order.
        let nodes: [ResolvedTarget.Dependency] = product.targets.map { .target($0, conditions: []) }
        let allTargets = try topologicalSort(nodes, successors: { dependency in
            switch dependency {
            // Include all the dependencies of a target.
            case .target(let target, _):
                let isTopLevel = topLevelDependencies.contains(target.underlyingTarget) || product.targets.contains(target)
                let topLevelIsMacro = isTopLevel && product.type == .macro
                let topLevelIsPlugin = isTopLevel && product.type == .plugin
                let topLevelIsTest = isTopLevel && product.type == .test

                if !topLevelIsMacro && !topLevelIsTest && target.type == .macro {
                    return []
                }
                if shouldExcludePlugins, !topLevelIsPlugin && !topLevelIsTest && target.type == .plugin {
                    return []
                }
                return target.dependencies.filter { $0.satisfies(self.buildEnvironment) }

            // For a product dependency, we only include its content only if we
            // need to statically link it.
            case .product(let product, _):
                guard dependency.satisfies(self.buildEnvironment) else {
                    return []
                }

                let productDependencies: [ResolvedTarget.Dependency] = product.targets.map { .target($0, conditions: []) }
                switch product.type {
                case .library(.automatic), .library(.static):
                    return productDependencies
                case .plugin:
                    return shouldExcludePlugins ? [] : productDependencies
                case .library(.dynamic), .test, .executable, .snippet, .macro:
                    return []
                }
            }
        })

        // Create empty arrays to collect our results.
        var linkLibraries = [ResolvedProduct]()
        var staticTargets = [ResolvedTarget]()
        var systemModules = [ResolvedTarget]()
        var libraryBinaryPaths: Set<AbsolutePath> = []
        var availableTools = [String: AbsolutePath]()

        for dependency in allTargets {
            switch dependency {
            case .target(let target, _):
                switch target.type {
                // Executable target have historically only been included if they are directly in the product's
                // target list.  Otherwise they have always been just build-time dependencies.
                // In tool version .v5_5 or greater, we also include executable modules implemented in Swift in
                // any test products... this is to allow testing of executables.  Note that they are also still
                // built as separate products that the test can invoke as subprocesses.
                case .executable, .snippet, .macro:
                    if product.targets.contains(target) {
                        staticTargets.append(target)
                    } else if product.type == .test && (target.underlyingTarget as? SwiftTarget)?.supportsTestableExecutablesFeature == true {
                        // Only "top-level" targets should really be considered here, not transitive ones.
                        let isTopLevel = topLevelDependencies.contains(target.underlyingTarget) || product.targets.contains(target)
                        if let toolsVersion = graph.package(for: product)?.manifest.toolsVersion, toolsVersion >= .v5_5, isTopLevel {
                            staticTargets.append(target)
                        }
                    }
                // Test targets should be included only if they are directly in the product's target list.
                case .test:
                    if product.targets.contains(target) {
                        staticTargets.append(target)
                    }
                // Library targets should always be included.
                case .library:
                    staticTargets.append(target)
                // Add system target to system targets array.
                case .systemModule:
                    systemModules.append(target)
                // Add binary to binary paths set.
                case .binary:
                    guard let binaryTarget = target.underlyingTarget as? BinaryTarget else {
                        throw InternalError("invalid binary target '\(target.name)'")
                    }
                    switch binaryTarget.kind {
                    case .xcframework:
                        let libraries = try self.parseXCFramework(for: binaryTarget)
                        for library in libraries {
                            libraryBinaryPaths.insert(library.libraryPath)
                        }
                    case .artifactsArchive:
                        let tools = try self.parseExecutableArtifactsArchive(for: binaryTarget)
                        for tool in tools {
                            availableTools[tool.name] = tool.executablePath
                        }
                    case .libraryArchive:
                        let libraries = try self.parseLibraryArtifactsArchive(for: binaryTarget)
                        for library in libraries {
                            libraryBinaryPaths.insert(library.libraryPath)
                        }
                    case.unknown:
                        throw InternalError("unknown binary target '\(target.name)' type")
                    }
                case .plugin:
                    continue
                }

            case .product(let product, _):
                // Add the dynamic products to array of libraries to link.
                if product.type == .library(.dynamic) {
                    linkLibraries.append(product)
                }
            }
        }

        // Add derived test targets, if necessary
        if buildParameters.testProductStyle.requiresAdditionalDerivedTestTargets {
            if product.type == .test, let derivedTestTargets = derivedTestTargetsMap[product] {
                staticTargets.append(contentsOf: derivedTestTargets)
            }
        }

        return (linkLibraries, staticTargets, systemModules, libraryBinaryPaths, availableTools)
    }

    /// Plan a Clang target.
    private func plan(clangTarget: ClangTargetBuildDescription) throws {
        for case .target(let dependency, _) in try clangTarget.target.recursiveDependencies(satisfying: buildEnvironment) {
            switch dependency.underlyingTarget {
            case is SwiftTarget:
                if case let .swift(dependencyTargetDescription)? = targetMap[dependency] {
                    if let moduleMap = dependencyTargetDescription.moduleMap {
                        clangTarget.additionalFlags += ["-fmodule-map-file=\(moduleMap)"]
                    }
                }

            case let target as ClangTarget where target.type == .library:
                // Setup search paths for C dependencies:
                clangTarget.additionalFlags += ["-I", target.includeDir.pathString]

                // Add the modulemap of the dependency if it has one.
                if case let .clang(dependencyTargetDescription)? = targetMap[dependency] {
                    if let moduleMap = dependencyTargetDescription.moduleMap {
                        clangTarget.additionalFlags += ["-fmodule-map-file=\(moduleMap)"]
                    }
                }
            case let target as SystemLibraryTarget:
                clangTarget.additionalFlags += ["-fmodule-map-file=\(target.moduleMapPath)"]
                clangTarget.additionalFlags += try pkgConfig(for: target).cFlags
            case let target as BinaryTarget:
                switch target.kind {
                case .xcframework:
                    let libraries = try self.parseXCFramework(for: target)
                    for library in libraries {
                        library.headersPaths.forEach {
                            clangTarget.additionalFlags += ["-I", $0.pathString]
                        }
                        clangTarget.libraryBinaryPaths.insert(library.libraryPath)
                    }

                case .libraryArchive:
                    let libraries = try self.parseLibraryArtifactsArchive(for: target)
                    for library in libraries {
                        library.headersPaths.forEach {
                            clangTarget.additionalFlags += ["-I", $0.pathString]
                        }
                        clangTarget.libraryBinaryPaths.insert(library.libraryPath)
                        if let moduleMapPath = library.moduleMapPath {
                            clangTarget.additionalFlags += ["-fmodule-map-file=\(moduleMapPath)"]
                        }
                    }

                default:
                    observabilityScope.emit(
                        warning: "Kind \(target.kind) of binary target \(target.name) is not supported."
                    )
                }
            default: continue
            }
        }
    }

    /// Plan a Swift target.
    private func plan(swiftTarget: SwiftTargetBuildDescription) throws {
        // We need to iterate recursive dependencies because Swift compiler needs to see all the targets a target
        // depends on.
        for case .target(let dependency, _) in try swiftTarget.target.recursiveDependencies(satisfying: buildEnvironment) {
            switch dependency.underlyingTarget {
            case let underlyingTarget as ClangTarget where underlyingTarget.type == .library:
                guard case let .clang(target)? = targetMap[dependency] else {
                    throw InternalError("unexpected clang target \(underlyingTarget)")
                }
                // Add the path to modulemap of the dependency. Currently we require that all Clang targets have a
                // modulemap but we may want to remove that requirement since it is valid for a target to exist without
                // one. However, in that case it will not be importable in Swift targets. We may want to emit a warning
                // in that case from here.
                guard let moduleMap = target.moduleMap else { break }
                swiftTarget.additionalFlags += [
                    "-Xcc", "-fmodule-map-file=\(moduleMap.pathString)",
                    "-Xcc", "-I", "-Xcc", target.clangTarget.includeDir.pathString,
                ]

            case let target as SystemLibraryTarget:
                swiftTarget.additionalFlags += ["-Xcc", "-fmodule-map-file=\(target.moduleMapPath)"]
                swiftTarget.additionalFlags += try pkgConfig(for: target).cFlags

            case let target as BinaryTarget:
                switch target.kind {
                case .xcframework:
                    let libraries = try self.parseXCFramework(for: target)
                    for library in libraries {
                        library.headersPaths.forEach {
                            swiftTarget.additionalFlags += ["-I", $0.pathString, "-Xcc", "-I", "-Xcc", $0.pathString]
                        }
                        swiftTarget.libraryBinaryPaths.insert(library.libraryPath)
                    }

                case .libraryArchive:
                    let libraries = try self.parseLibraryArtifactsArchive(for: target)
                    for library in libraries {
                        library.headersPaths.forEach {
                            swiftTarget.additionalFlags += ["-I", $0.pathString, "-Xcc", "-I", "-Xcc", $0.pathString]
                        }
                        swiftTarget.libraryBinaryPaths.insert(library.libraryPath)
                        if let moduleMapPath = library.moduleMapPath {
                            swiftTarget.additionalFlags += ["-Xcc", "-fmodule-map-file=\(moduleMapPath)"]
                        }
                    }
                    
                default:
                    observabilityScope.emit(
                        warning: "Kind \(target.kind) of binary target \(target.name) is not supported."
                    )
                }

            default:
                break
            }
        }
    }

    public func createAPIToolCommonArgs(includeLibrarySearchPaths: Bool) throws -> [String] {
        let buildPath = buildParameters.buildPath.pathString
        var arguments = ["-I", buildPath]

        // swift-symbolgraph-extract does not support parsing `-use-ld=lld` and
        // will silently error failing the operation.  Filter out this flag
        // similar to how we filter out the library search path unless
        // explicitly requested.
        var extraSwiftCFlags = buildParameters.toolchain.extraFlags.swiftCompilerFlags.filter { !$0.starts(with: "-use-ld=") }
        if !includeLibrarySearchPaths {
            for index in extraSwiftCFlags.indices.dropLast().reversed() {
                if extraSwiftCFlags[index] == "-L" {
                    // Remove the flag
                    extraSwiftCFlags.remove(at: index)
                    // Remove the argument
                    extraSwiftCFlags.remove(at: index)
                }
            }
        }
        arguments += extraSwiftCFlags

        // Add the search path to the directory containing the modulemap file.
        for target in targets {
            switch target {
            case .swift: break
            case .clang(let targetDescription):
                if let includeDir = targetDescription.moduleMap?.parentDirectory {
                    arguments += ["-I", includeDir.pathString]
                }
            }
        }

        // Add search paths from the system library targets.
        for target in graph.reachableTargets {
            if let systemLib = target.underlyingTarget as? SystemLibraryTarget {
                arguments.append(contentsOf: try self.pkgConfig(for: systemLib).cFlags)
                // Add the path to the module map.
                arguments += ["-I", systemLib.moduleMapPath.parentDirectory.pathString]
            }
        }

        return arguments
    }

    /// Creates arguments required to launch the Swift REPL that will allow
    /// importing the modules in the package graph.
    public func createREPLArguments() throws -> [String] {
        let buildPath = buildParameters.buildPath.pathString
        var arguments = ["repl", "-I" + buildPath, "-L" + buildPath]

        // Link the special REPL product that contains all of the library targets.
        let replProductName = graph.rootPackages[0].identity.description + Product.replProductSuffix
        arguments.append("-l" + replProductName)

        // The graph should have the REPL product.
        assert(graph.allProducts.first(where: { $0.name == replProductName }) != nil)

        // Add the search path to the directory containing the modulemap file.
        for target in targets {
            switch target {
                case .swift: break
            case .clang(let targetDescription):
                if let includeDir = targetDescription.moduleMap?.parentDirectory {
                    arguments += ["-I\(includeDir.pathString)"]
                }
            }
        }

        // Add search paths from the system library targets.
        for target in graph.reachableTargets {
            if let systemLib = target.underlyingTarget as? SystemLibraryTarget {
                arguments += try self.pkgConfig(for: systemLib).cFlags
            }
        }

        return arguments
    }

    /// Get pkgConfig arguments for a system library target.
    private func pkgConfig(for target: SystemLibraryTarget) throws -> (cFlags: [String], libs: [String]) {
        // If we already have these flags, we're done.
        if let flags = pkgConfigCache[target] {
            return flags
        }
        else {
            pkgConfigCache[target] = ([], [])
        }
        let results = try pkgConfigArgs(
            for: target,
            pkgConfigDirectories: buildParameters.pkgConfigDirectories,
            sdkRootPath: buildParameters.toolchain.sdkRootPath,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )
        var ret: [(cFlags: [String], libs: [String])] = []
        for result in results {
            ret.append((result.cFlags, result.libs))
        }

        // Build cache
        var cflagsCache: OrderedCollections.OrderedSet<String> = []
        var libsCache: [String] = []
        for tuple in ret {
            for cFlag in tuple.cFlags {
                cflagsCache.append(cFlag)
            }

            libsCache.append(contentsOf: tuple.libs)
        }

        let result = ([String](cflagsCache), libsCache)
        pkgConfigCache[target] = result
        return result
    }

    /// Extracts the library information from an XCFramework.
    private func parseXCFramework(for target: BinaryTarget) throws -> [LibraryInfo] {
        try self.externalLibrariesCache.memoize(key: target) {
            try target.parseXCFrameworks(for: self.buildParameters.targetTriple, fileSystem: self.fileSystem)
        }
    }

    /// Extracts the executable artifacts from an `.artifactbundle`.
    private func parseExecutableArtifactsArchive(for target: BinaryTarget) throws -> [ExecutableInfo] {
        try self.externalExecutablesCache.memoize(key: target) {
            let execInfos = try target.parseExecutableArtifactArchives(
                for: self.buildParameters.targetTriple,
                fileSystem: self.fileSystem
            )
            return execInfos.filter { !$0.supportedTriples.isEmpty }
        }
    }

    private func parseLibraryArtifactsArchive(for target: BinaryTarget) throws -> [LibraryInfo] {
        try self.externalLibrariesCache.memoize(key: target) {
            try target.parseLibraryArtifactArchives(for: self.buildParameters.targetTriple, fileSystem: self.fileSystem)
        }
    }
}

private extension PackageModel.SwiftTarget {
    /// Initialize a SwiftTarget representing a test entry point.
    convenience init(
        name: String,
        type: PackageModel.Target.Kind? = nil,
        dependencies: [PackageModel.Target.Dependency],
        packageAccess: Bool,
        testEntryPointSources sources: Sources
    ) {
        self.init(
            name: name,
            type: type ?? .executable,
            path: .root,
            sources: sources,
            dependencies: dependencies,
            packageAccess: packageAccess,
            swiftVersion: .v5,
            usesUnsafeFlags: false
        )
    }
}

extension Basics.Diagnostic {
    static var swiftBackDeployError: Self {
        .warning("Swift compiler no longer supports statically linking the Swift libraries. They're included in the OS by default starting with macOS Mojave 10.14.4 beta 3. For macOS Mojave 10.14.3 and earlier, there's an optional Swift library package that can be downloaded from \"More Downloads\" for Apple Developers at https://developer.apple.com/download/more/")
    }

    static func productRequiresHigherPlatformVersion(
        target: ResolvedTarget,
        targetPlatform: SupportedPlatform,
        product: String,
        productPlatform: SupportedPlatform
    ) -> Self {
        .error("""
            the \(target.type.rawValue) '\(target.name)' requires \
            \(targetPlatform.platform.name) \(targetPlatform.version.versionString), \
            but depends on the product '\(product)' which requires \
            \(productPlatform.platform.name) \(productPlatform.version.versionString); \
            consider changing the \(target.type.rawValue) '\(target.name)' to require \
            \(productPlatform.platform.name) \(productPlatform.version.versionString) or later, \
            or the product '\(product)' to require \
            \(targetPlatform.platform.name) \(targetPlatform.version.versionString) or earlier.
            """)
    }

    static func binaryTargetsNotSupported() -> Self {
        .error("binary targets are not supported on this platform")
    }
}

extension BuildParameters {
    /// Returns a named bundle's path inside the build directory.
    func bundlePath(named name: String) -> AbsolutePath {
        return buildPath.appending(component: name + targetTriple.nsbundleExtension)
    }
}

/// Generate the resource bundle Info.plist.
func generateResourceInfoPlist(
    fileSystem: FileSystem,
    target: ResolvedTarget,
    path: AbsolutePath
) throws -> Bool {
    guard let defaultLocalization = target.defaultLocalization else {
        return false
    }

    try fileSystem.writeIfChanged(
        path: path,
        string: """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>\(defaultLocalization)</string>
        </dict>
        </plist>
        """
    )
    return true
}

extension Basics.Triple {
    var isSupportingStaticStdlib: Bool {
        isLinux() || arch == .wasm32
    }
}

extension ResolvedPackage {
    var isRemote: Bool {
        switch self.underlyingPackage.manifest.packageKind {
        case .registry, .remoteSourceControl, .localSourceControl:
            return true
        case .root, .fileSystem:
            return false
        }
    }
}

extension ResolvedProduct {
    private var isAutomaticLibrary: Bool {
        return self.type == .library(.automatic)
    }

    private var isBinaryOnly: Bool {
        return self.targets.filter({ !($0.underlyingTarget is BinaryTarget) }).isEmpty
    }

    private var isPlugin: Bool {
        return self.type == .plugin
    }

    // We shouldn't create product descriptions for automatic libraries, plugins or products which consist solely of binary targets, because they don't produce any output.
    fileprivate var shouldCreateProductDescription: Bool {
        return !isAutomaticLibrary && !isBinaryOnly && !isPlugin
    }
}

