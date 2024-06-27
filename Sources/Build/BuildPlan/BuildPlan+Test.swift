//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2015-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import class Basics.ObservabilityScope
import struct Basics.InternalError
import struct Basics.AbsolutePath
import struct LLBuildManifest.TestDiscoveryTool
import struct LLBuildManifest.TestEntryPointTool
import struct PackageGraph.ModulesGraph
import struct PackageGraph.ResolvedPackage
import struct PackageGraph.ResolvedProduct
import struct PackageGraph.ResolvedModule
import struct PackageModel.Sources
import class PackageModel.SwiftModule
import class PackageModel.Module
import struct SPMBuildCore.BuildParameters
import protocol TSCBasic.FileSystem

extension BuildPlan {
    static func makeDerivedTestTargets(
        testProducts: [(product: ResolvedProduct, buildDescription: ProductBuildDescription)],
        destinationBuildParameters: BuildParameters,
        toolsBuildParameters: BuildParameters,
        shouldDisableSandbox: Bool,
        _ fileSystem: FileSystem,
        _ observabilityScope: ObservabilityScope
    ) throws -> [(product: ResolvedProduct, discoveryTargetBuildDescription: SwiftModuleBuildDescription?, entryPointTargetBuildDescription: SwiftModuleBuildDescription)] {
        guard destinationBuildParameters.testingParameters.testProductStyle.requiresAdditionalDerivedTestTargets,
              case .entryPointExecutable(let explicitlyEnabledDiscovery, let explicitlySpecifiedPath) =
                destinationBuildParameters.testingParameters.testProductStyle
        else {
            throw InternalError("makeTestManifestTargets should not be used for build plan which does not require additional derived test targets")
        }

        let isEntryPointPathSpecifiedExplicitly = explicitlySpecifiedPath != nil

        var isDiscoveryEnabledRedundantly = explicitlyEnabledDiscovery && !isEntryPointPathSpecifiedExplicitly
        var result: [(ResolvedProduct, SwiftModuleBuildDescription?, SwiftModuleBuildDescription)] = []
        for (testProduct, testBuildDescription) in testProducts {
            let package = testBuildDescription.package

            isDiscoveryEnabledRedundantly = isDiscoveryEnabledRedundantly && nil == testProduct.testEntryPointModule
            // If a non-explicitly specified test entry point file exists, prefer that over test discovery.
            // This is designed as an escape hatch when test discovery is not appropriate and for backwards
            // compatibility for projects that have existing test entry point files (e.g. XCTMain.swift, LinuxMain.swift).
            let toolsVersion = package.manifest.toolsVersion

            // If `testProduct.testEntryPointTarget` is non-nil, it may either represent an `XCTMain.swift` (formerly `LinuxMain.swift`) file
            // if such a file is located in the package, or it may represent a test entry point file at a path specified by the option
            // `--experimental-test-entry-point-path <file>`. The latter is useful because it still performs test discovery and places the discovered
            // tests into a separate target/module named "<PackageName>PackageDiscoveredTests". Then, that entry point file may import that module and
            // obtain that list to pass it to the `XCTMain(...)` function and avoid needing to maintain a list of tests itself.
            if testProduct.testEntryPointModule != nil && explicitlyEnabledDiscovery && !isEntryPointPathSpecifiedExplicitly {
                let testEntryPointName = testProduct.underlying.testEntryPointPath?.basename ?? SwiftModule.defaultTestEntryPointName
                observabilityScope.emit(warning: "'--enable-test-discovery' was specified so the '\(testEntryPointName)' entry point file for '\(testProduct.name)' will be ignored and an entry point will be generated automatically. To use test discovery with a custom entry point file, pass '--experimental-test-entry-point-path <file>'.")
            } else if testProduct.testEntryPointModule == nil, let testEntryPointPath = explicitlySpecifiedPath, !fileSystem.exists(testEntryPointPath) {
                observabilityScope.emit(error: "'--experimental-test-entry-point-path' was specified but the file '\(testEntryPointPath)' could not be found.")
            }

            /// Generates test discovery modules, which contain derived sources listing the discovered tests.
            func generateDiscoveryTargets() throws -> (target: SwiftModule, resolved: ResolvedModule, buildDescription: SwiftModuleBuildDescription) {
                let discoveryTargetName = "\(package.manifest.displayName)PackageDiscoveredTests"
                let discoveryDerivedDir = destinationBuildParameters.buildPath.appending(components: "\(discoveryTargetName).derived")
                let discoveryMainFile = discoveryDerivedDir.appending(component: TestDiscoveryTool.mainFileName)

                var discoveryPaths: [AbsolutePath] = []
                discoveryPaths.append(discoveryMainFile)
                for testTarget in testProduct.modules {
                    let path = discoveryDerivedDir.appending(components: testTarget.name + ".swift")
                    discoveryPaths.append(path)
                }

                let discoveryTarget = SwiftModule(
                    name: discoveryTargetName,
                    dependencies: testProduct.underlying.modules.map { .module($0, conditions: []) },
                    packageAccess: true, // test target is allowed access to package decls by default
                    testDiscoverySrc: Sources(paths: discoveryPaths, root: discoveryDerivedDir)
                )
                var discoveryResolvedModule = ResolvedModule(
                    packageIdentity: testProduct.packageIdentity,
                    underlying: discoveryTarget,
                    dependencies: testProduct.modules.map { .module($0, conditions: []) },
                    defaultLocalization: testProduct.defaultLocalization,
                    supportedPlatforms: testProduct.supportedPlatforms,
                    platformVersionProvider: testProduct.platformVersionProvider
                )
                discoveryResolvedModule.buildTriple = testProduct.buildTriple

                let discoveryTargetBuildDescription = try SwiftModuleBuildDescription(
                    package: package,
                    target: discoveryResolvedModule,
                    toolsVersion: toolsVersion,
                    buildParameters: testBuildDescription.buildParameters,
                    testTargetRole: .discovery,
                    shouldDisableSandbox: shouldDisableSandbox,
                    fileSystem: fileSystem,
                    observabilityScope: observabilityScope
                )

                return (discoveryTarget, discoveryResolvedModule, discoveryTargetBuildDescription)
            }

            /// Generates a synthesized test entry point target, consisting of a single "main" file which calls the test entry
            /// point API and leverages the test discovery target to reference which tests to run.
            func generateSynthesizedEntryPointTarget(
                swiftTargetDependencies: [Module.Dependency],
                resolvedTargetDependencies: [ResolvedModule.Dependency]
            ) throws -> SwiftModuleBuildDescription {
                let entryPointDerivedDir = destinationBuildParameters.buildPath.appending(components: "\(testProduct.name).derived")
                let entryPointMainFileName = TestEntryPointTool.mainFileName(for: destinationBuildParameters.testingParameters.library)
                let entryPointMainFile = entryPointDerivedDir.appending(component: entryPointMainFileName)
                let entryPointSources = Sources(paths: [entryPointMainFile], root: entryPointDerivedDir)

                let entryPointTarget = SwiftModule(
                    name: testProduct.name,
                    type: .library,
                    dependencies: testProduct.underlying.modules.map { .module($0, conditions: []) } + swiftTargetDependencies,
                    packageAccess: true, // test target is allowed access to package decls
                    testEntryPointSources: entryPointSources
                )
                var entryPointResolvedTarget = ResolvedModule(
                    packageIdentity: testProduct.packageIdentity,
                    underlying: entryPointTarget,
                    dependencies: testProduct.modules.map { .module($0, conditions: []) } + resolvedTargetDependencies,
                    defaultLocalization: testProduct.defaultLocalization,
                    supportedPlatforms: testProduct.supportedPlatforms,
                    platformVersionProvider: testProduct.platformVersionProvider
                )
                entryPointResolvedTarget.buildTriple = testProduct.buildTriple

                return try SwiftModuleBuildDescription(
                    package: package,
                    target: entryPointResolvedTarget,
                    toolsVersion: toolsVersion,
                    buildParameters: testBuildDescription.buildParameters,
                    testTargetRole: .entryPoint(isSynthesized: true),
                    shouldDisableSandbox: shouldDisableSandbox,
                    fileSystem: fileSystem,
                    observabilityScope: observabilityScope
                )
            }

            let discoveryTargets: (target: SwiftModule, resolved: ResolvedModule, buildDescription: SwiftModuleBuildDescription)?
            let swiftTargetDependencies: [Module.Dependency]
            let resolvedTargetDependencies: [ResolvedModule.Dependency]

            switch destinationBuildParameters.testingParameters.library {
            case .xctest:
                discoveryTargets = try generateDiscoveryTargets()
                swiftTargetDependencies = [.module(discoveryTargets!.target, conditions: [])]
                resolvedTargetDependencies = [.module(discoveryTargets!.resolved, conditions: [])]
            case .swiftTesting:
                discoveryTargets = nil
                swiftTargetDependencies = testProduct.modules.map { .module($0.underlying, conditions: []) }
                resolvedTargetDependencies = testProduct.modules.map { .module($0, conditions: []) }
            }

            if let entryPointResolvedTarget = testProduct.testEntryPointModule {
                if isEntryPointPathSpecifiedExplicitly || explicitlyEnabledDiscovery {
                    if isEntryPointPathSpecifiedExplicitly {
                        // Allow using the explicitly-specified test entry point target, but still perform test discovery and thus declare a dependency on the discovery modules.
                        let entryPointTarget = SwiftModule(
                            name: entryPointResolvedTarget.underlying.name,
                            dependencies: entryPointResolvedTarget.underlying.dependencies + swiftTargetDependencies,
                            packageAccess: entryPointResolvedTarget.packageAccess,
                            testEntryPointSources: entryPointResolvedTarget.underlying.sources
                        )
                        let entryPointResolvedTarget = ResolvedModule(
                            packageIdentity: testProduct.packageIdentity,
                            underlying: entryPointTarget,
                            dependencies: entryPointResolvedTarget.dependencies + resolvedTargetDependencies,
                            defaultLocalization: testProduct.defaultLocalization,
                            supportedPlatforms: testProduct.supportedPlatforms,
                            platformVersionProvider: testProduct.platformVersionProvider
                        )
                        let entryPointTargetBuildDescription = try SwiftModuleBuildDescription(
                            package: package,
                            target: entryPointResolvedTarget,
                            toolsVersion: toolsVersion,
                            buildParameters: destinationBuildParameters,
                            testTargetRole: .entryPoint(isSynthesized: false),
                            shouldDisableSandbox: shouldDisableSandbox,
                            fileSystem: fileSystem,
                            observabilityScope: observabilityScope
                        )

                        result.append((testProduct, discoveryTargets?.buildDescription, entryPointTargetBuildDescription))
                    } else {
                        // Ignore test entry point and synthesize one, declaring a dependency on the test discovery targets created above.
                        let entryPointTargetBuildDescription = try generateSynthesizedEntryPointTarget(
                            swiftTargetDependencies: swiftTargetDependencies,
                            resolvedTargetDependencies: resolvedTargetDependencies
                        )
                        result.append((testProduct, discoveryTargets?.buildDescription, entryPointTargetBuildDescription))
                    }
                } else {
                    // Use the test entry point as-is, without performing test discovery.
                    let entryPointTargetBuildDescription = try SwiftModuleBuildDescription(
                        package: package,
                        target: entryPointResolvedTarget,
                        toolsVersion: toolsVersion,
                        buildParameters: destinationBuildParameters,
                        testTargetRole: .entryPoint(isSynthesized: false),
                        shouldDisableSandbox: shouldDisableSandbox,
                        fileSystem: fileSystem,
                        observabilityScope: observabilityScope
                    )
                    result.append((testProduct, nil, entryPointTargetBuildDescription))
                }
            } else {
                // Synthesize a test entry point target, declaring a dependency on the test discovery targets.
                let entryPointTargetBuildDescription = try generateSynthesizedEntryPointTarget(
                    swiftTargetDependencies: swiftTargetDependencies,
                    resolvedTargetDependencies: resolvedTargetDependencies
                )
                result.append((testProduct, discoveryTargets?.buildDescription, entryPointTargetBuildDescription))
            }
        }

        if isDiscoveryEnabledRedundantly {
            observabilityScope.emit(warning: "'--enable-test-discovery' option is deprecated; tests are automatically discovered on all platforms")
        }

        return result
    }
}

private extension PackageModel.SwiftModule {
    /// Initialize a SwiftTarget representing a test entry point.
    convenience init(
        name: String,
        type: PackageModel.Module.Kind? = nil,
        dependencies: [PackageModel.Module.Dependency],
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
            usesUnsafeFlags: false
        )
    }
}
