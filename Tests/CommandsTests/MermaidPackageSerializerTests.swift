//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import class Basics.InMemoryFileSystem
import class Basics.ObservabilitySystem

@_spi(DontAdoptOutsideOfSwiftPMExposedForBenchmarksAndTestsOnly)
import func PackageGraph.loadModulesGraph

import class PackageModel.Manifest
import struct PackageModel.ProductDescription
import struct PackageModel.TargetDescription
import func _InternalTestSupport.XCTAssertNoDiagnostics

@testable
import Commands

import XCTest

final class MermaidPackageSerializerTests: XCTestCase {
    func testSimplePackage() throws {
        let observability = ObservabilitySystem.makeForTesting()
        let fileSystem = InMemoryFileSystem(
            emptyFiles:
            "/A/Sources/ATarget/main.swift",
            "/A/Tests/ATargetTests/TestCases.swift"
        )
        let graph = try loadModulesGraph(
            fileSystem: fileSystem,
            manifests: [
                Manifest.createRootManifest(
                    displayName: "A",
                    path: "/A",
                    targets: [
                        TargetDescription(name: "ATarget"),
                        TargetDescription(name: "ATargetTests", dependencies: ["ATarget"], type: .test),
                    ]
                ),
            ],
            observabilityScope: observability.topScope
        )
        XCTAssertNoDiagnostics(observability.diagnostics)

        XCTAssertEqual(graph.packages.count, 1)
        let package = try XCTUnwrap(graph.packages.first)
        let serializer = MermaidPackageSerializer(package: package.underlying)
        XCTAssertEqual(
            serializer.renderedMarkdown,
            """
            ```mermaid
            flowchart TB
                subgraph a
                    product:APackageTests[[APackageTests]]-->target:ATargetTests(ATargetTests)
                    product:ATarget[[ATarget]]-->target:ATarget(ATarget)
                    target:ATargetTests(ATargetTests)-->target:ATarget(ATarget)
                end
            ```

            """
        )
    }

    func testDependenciesOnProducts() throws {
        let fileSystem = InMemoryFileSystem(
            emptyFiles:
            "/A/Sources/ATarget/foo.swift",
            "/A/Tests/ATargetTests/foo.swift",
            "/B/Sources/BTarget/foo.swift",
            "/B/Tests/BTargetTests/foo.swift"
        )

        let observability = ObservabilitySystem.makeForTesting()
        let graph = try loadModulesGraph(
            fileSystem: fileSystem,
            manifests: [
                Manifest.createRootManifest(
                    displayName: "A",
                    path: "/A",
                    dependencies: [
                        .localSourceControl(path: "/B", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    targets: [
                        TargetDescription(name: "ATarget", dependencies: ["BLibrary"]),
                        TargetDescription(name: "ATargetTests", dependencies: ["ATarget"], type: .test),
                    ]
                ),
                Manifest.createFileSystemManifest(
                    displayName: "B",
                    path: "/B",
                    products: [
                        ProductDescription(name: "BLibrary", type: .library(.automatic), targets: ["BTarget"]),
                    ],
                    targets: [
                        TargetDescription(name: "BTarget", dependencies: []),
                        TargetDescription(name: "BTargetTests", dependencies: ["BTarget"], type: .test),
                    ]
                ),
            ],
            observabilityScope: observability.topScope
        )
        XCTAssertNoDiagnostics(observability.diagnostics)

        XCTAssertEqual(graph.packages.count, 2)
        let package = try XCTUnwrap(graph.package(for: .plain("A")))
        let serializer = MermaidPackageSerializer(package: package.underlying)
        XCTAssertEqual(
            serializer.renderedMarkdown,
            """
            ```mermaid
            flowchart TB
                subgraph a
                    product:APackageTests[[APackageTests]]-->target:ATargetTests(ATargetTests)
                    target:ATargetTests(ATargetTests)-->target:ATarget(ATarget)
                    target:ATarget(ATarget)-->BLibrary{{BLibrary}}
                end
            ```

            """
        )
    }

    func testDependenciesOnPackages() throws {
        let fileSystem = InMemoryFileSystem(
            emptyFiles:
            "/A/Sources/ATarget/foo.swift",
            "/A/Tests/ATargetTests/foo.swift",
            "/B/Sources/BTarget/foo.swift",
            "/B/Tests/BTargetTests/foo.swift"
        )

        let observability = ObservabilitySystem.makeForTesting()
        let graph = try loadModulesGraph(
            fileSystem: fileSystem,
            manifests: [
                Manifest.createRootManifest(
                    displayName: "A",
                    path: "/A",
                    dependencies: [
                        .localSourceControl(path: "/B", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    targets: [
                        TargetDescription(name: "ATarget", dependencies: [.product(name: "BLibrary", package: "B")]),
                        TargetDescription(name: "ATargetTests", dependencies: ["ATarget"], type: .test),
                    ]
                ),
                Manifest.createFileSystemManifest(
                    displayName: "B",
                    path: "/B",
                    products: [
                        ProductDescription(name: "BLibrary", type: .library(.automatic), targets: ["BTarget"]),
                    ],
                    targets: [
                        TargetDescription(name: "BTarget", dependencies: []),
                        TargetDescription(name: "BTargetTests", dependencies: ["BTarget"], type: .test),
                    ]
                ),
            ],
            observabilityScope: observability.topScope
        )
        XCTAssertNoDiagnostics(observability.diagnostics)

        XCTAssertEqual(graph.packages.count, 2)
        let package = try XCTUnwrap(graph.package(for: .plain("A")))
        let serializer = MermaidPackageSerializer(package: package.underlying)
        XCTAssertEqual(
            serializer.renderedMarkdown,
            """
            ```mermaid
            flowchart TB
                subgraph a
                    product:APackageTests[[APackageTests]]-->target:ATargetTests(ATargetTests)
                    target:ATargetTests(ATargetTests)-->target:ATarget(ATarget)
                end

                subgraph B
                    target:ATarget(ATarget)-->BLibrary{{BLibrary}}
                end
            ```

            """
        )
    }
}
