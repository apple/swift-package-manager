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
import struct PackageGraph.PackageGraph
import class PackageGraph.ResolvedProduct
import class PackageGraph.ResolvedTarget
import struct PackageModel.Sources
import class PackageModel.SwiftTarget
import class PackageModel.Target
import struct SPMBuildCore.BuildParameters
import protocol TSCBasic.FileSystem

extension BuildPlan {
    static func makeDerivedTestTargets(
        _ buildParameters: BuildParameters,
        _ graph: PackageGraph,
        _ fileSystem: FileSystem,
        _ observabilityScope: ObservabilityScope
    ) throws -> [(product: ResolvedProduct, discoveryTargetBuildDescription: SwiftTargetBuildDescription?, entryPointTargetBuildDescription: SwiftTargetBuildDescription)] {
        guard buildParameters.testingParameters.testProductStyle.requiresAdditionalDerivedTestTargets,
              case .entryPointExecutable(let explicitlyEnabledDiscovery, let explicitlySpecifiedPath) =
                buildParameters.testingParameters.testProductStyle
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
                let discoveryMainFile = discoveryDerivedDir.appending(component: TestDiscoveryTool.mainFileName)

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
                    defaultLocalization: testProduct.defaultLocalization,
                    platforms: testProduct.platforms
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
            func generateSynthesizedEntryPointTarget(
                swiftTargetDependencies: [Target.Dependency],
                resolvedTargetDependencies: [ResolvedTarget.Dependency]
            ) throws -> SwiftTargetBuildDescription {
                let entryPointDerivedDir = buildParameters.buildPath.appending(components: "\(testProduct.name).derived")
                let entryPointMainFileName = TestEntryPointTool.mainFileName(for: buildParameters.testingParameters.library)
                let entryPointMainFile = entryPointDerivedDir.appending(component: entryPointMainFileName)
                let entryPointSources = Sources(paths: [entryPointMainFile], root: entryPointDerivedDir)

                let entryPointTarget = SwiftTarget(
                    name: testProduct.name,
                    type: .library,
                    dependencies: testProduct.underlyingProduct.targets.map { .target($0, conditions: []) } + swiftTargetDependencies,
                    packageAccess: true, // test target is allowed access to package decls
                    testEntryPointSources: entryPointSources
                )
                let entryPointResolvedTarget = ResolvedTarget(
                    target: entryPointTarget,
                    dependencies: testProduct.targets.map { .target($0, conditions: []) } + resolvedTargetDependencies,
                    defaultLocalization: testProduct.defaultLocalization,
                    platforms: testProduct.platforms
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

            let discoveryTargets: (target: SwiftTarget, resolved: ResolvedTarget, buildDescription: SwiftTargetBuildDescription)?
            let swiftTargetDependencies: [Target.Dependency]
            let resolvedTargetDependencies: [ResolvedTarget.Dependency]

            switch buildParameters.testingParameters.library {
            case .xctest:
                discoveryTargets = try generateDiscoveryTargets()
                swiftTargetDependencies = [.target(discoveryTargets!.target, conditions: [])]
                resolvedTargetDependencies = [.target(discoveryTargets!.resolved, conditions: [])]
            case .swiftTesting:
                discoveryTargets = nil
                swiftTargetDependencies = testProduct.targets.map { .target($0.underlyingTarget, conditions: []) }
                resolvedTargetDependencies = testProduct.targets.map { .target($0, conditions: []) }
            }

            if let entryPointResolvedTarget = testProduct.testEntryPointTarget {
                if isEntryPointPathSpecifiedExplicitly || explicitlyEnabledDiscovery {
                    if isEntryPointPathSpecifiedExplicitly {
                        // Allow using the explicitly-specified test entry point target, but still perform test discovery and thus declare a dependency on the discovery targets.
                        let entryPointTarget = SwiftTarget(
                            name: entryPointResolvedTarget.underlyingTarget.name,
                            dependencies: entryPointResolvedTarget.underlyingTarget.dependencies + swiftTargetDependencies,
                            packageAccess: entryPointResolvedTarget.packageAccess,
                            testEntryPointSources: entryPointResolvedTarget.underlyingTarget.sources
                        )
                        let entryPointResolvedTarget = ResolvedTarget(
                            target: entryPointTarget,
                            dependencies: entryPointResolvedTarget.dependencies + resolvedTargetDependencies,
                            defaultLocalization: testProduct.defaultLocalization,
                            platforms: testProduct.platforms
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
