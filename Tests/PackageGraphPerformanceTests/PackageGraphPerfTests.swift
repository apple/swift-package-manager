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
import OrderedCollections

@_spi(DontAdoptOutsideOfSwiftPMExposedForBenchmarksAndTestsOnly)
import PackageGraph

import PackageLoading
import PackageModel
import _InternalTestSupport
import XCTest

import class TSCBasic.InMemoryFileSystem

import class TSCTestSupport.XCTestCasePerf

final class PackageGraphPerfTests: XCTestCasePerf {
    func testLoading100Packages() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif

        let N = 100
        let files = (1...N).map { "/Foo\($0)/source.swift" }
        let fs = InMemoryFileSystem(emptyFiles: files)

        let identityResolver = DefaultIdentityResolver()
        var externalManifests = OrderedCollections.OrderedDictionary<PackageIdentity, (manifest: Manifest, fs: FileSystem)>()
        var rootManifest: Manifest!
        for pkg in 1...N {
            let name = "Foo\(pkg)"
            let location = "/" + name

            let dependencies: [PackageDependency]
            let targets: [TargetDescription]
            // Create package.
            if pkg == N {
                dependencies = []
                targets = [try TargetDescription(name: name, path: ".")]
            } else {
                let depName = "Foo\(pkg + 1)"
                let depUrl = "/\(depName)"
                dependencies = [.localSourceControl(
                    deprecatedName: depName,
                    path: try .init(validating: depUrl),
                    requirement: .upToNextMajor(from: "1.0.0")
                )]
                targets = [try TargetDescription(
                    name: name,
                    dependencies: [.byName(name: depName, condition: nil)],
                    path: "."
                )]
            }
            // Create manifest.
            let isRoot = pkg == 1
            let manifest = Manifest.createManifest(
                displayName: name,
                path: try AbsolutePath(validating: location).appending(component: Manifest.filename),
                packageKind: isRoot ? .root(try .init(validating: location)) : .localSourceControl(try .init(validating: location)),
                packageLocation: location,
                platforms: [],
                version: "1.0.0",
                toolsVersion: .v4_2,
                dependencies: dependencies,
                products: [
                    try ProductDescription(name: name, type: .library(.automatic), targets: [name])
                ],
                targets: targets
            )
            if isRoot {
                rootManifest = manifest
            } else {
                let identity = try identityResolver.resolveIdentity(for: manifest.packageKind)
                externalManifests[identity] = (manifest, fs)
            }
        }

        measure {
            let observability = ObservabilitySystem.makeForTesting()
            let g = try! ModulesGraph.load(
                root: PackageGraphRoot(
                    input: PackageGraphRootInput(packages: [rootManifest.path]),
                    manifests: [rootManifest.path: rootManifest],
                    observabilityScope: observability.topScope
                ),
                identityResolver: identityResolver,
                externalManifests: externalManifests,
                binaryArtifacts: [:],
                fileSystem: fs,
                observabilityScope: observability.topScope
            )
            XCTAssertEqual(g.packages.count, N)
            XCTAssertNoDiagnostics(observability.diagnostics)
        }
    }

    func testEfficientCycleDetection() throws {
        let lastPackageNumber = 20
        let packageNumberSequence = (1...lastPackageNumber)

        let fs = InMemoryFileSystem(
            emptyFiles: packageNumberSequence.map({ "/Package\($0)/Sources/Target\($0)/s.swift" }) + 
                ["/PackageA/Sources/TargetA/s.swift"]
        )

        let packageSequence: [Manifest] = try packageNumberSequence.map { (sequenceNumber: Int) -> Manifest in
            let dependencySequence = sequenceNumber < lastPackageNumber ? Array((sequenceNumber + 1)...lastPackageNumber) : []
            return Manifest.createFileSystemManifest(
                displayName: "Package\(sequenceNumber)",
                path: try .init(validating: "/Package\(sequenceNumber)"),
                toolsVersion: .v5_7,
                dependencies: try dependencySequence.map({ .fileSystem(path: try .init(validating: "/Package\($0)")) }),
                products: [
                    try .init(
                        name: "Package\(sequenceNumber)",
                        type: .library(.dynamic),
                        targets: ["Target\(sequenceNumber)"]
                    )
                ],
                targets: [
                    try .init(
                        name: "Target\(sequenceNumber)",
                        dependencies: dependencySequence.map {
                            .product(name: "Target\($0)", package: "Package\($0)")
                        }
                    )
                ]
            )
        }

        let root = Manifest.createRootManifest(
            displayName: "PackageA",
            path: "/PackageA",
            toolsVersion: .v5_7,
            dependencies: try packageNumberSequence.map({ .fileSystem(path: try .init(validating: "/Package\($0)")) }),
            targets: [try .init(name: "TargetA", dependencies: ["Target1"]) ]
        )

        let observability = ObservabilitySystem.makeForTesting()

        let N = 1
        measure {
            do {
                for _ in 0..<N {
                    _ = try loadModulesGraph(
                        fileSystem: fs,
                        manifests: [root] + packageSequence,
                        observabilityScope: observability.topScope
                    )
                }
            } catch {
                XCTFail("Loading package graph is not expected to fail in this test.")
            }
        }
    }

    func testRecursiveDependencies() throws {
        var resolvedTarget = ResolvedModule.mock(packageIdentity: "pkg", name: "t0")
        for i in 1..<1000 {
            resolvedTarget = ResolvedModule.mock(packageIdentity: "pkg", name: "t\(i)", deps: resolvedTarget)
        }        

        let N = 10
        measure {
            do {
                for _ in 0..<N {
                    _ = try resolvedTarget.recursiveModuleDependencies()
                }
            } catch {
                XCTFail("Loading package graph is not expected to fail in this test.")
            }
        }
    }
}
