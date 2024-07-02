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

@testable
import Build

import class Basics.InMemoryFileSystem
import class Basics.ObservabilitySystem

import class PackageModel.Manifest
import struct PackageModel.TargetDescription

@testable
import struct PackageGraph.ResolvedProduct

@_spi(DontAdoptOutsideOfSwiftPMExposedForBenchmarksAndTestsOnly)
import func PackageGraph.loadModulesGraph

import func _InternalTestSupport.mockBuildParameters
import func _InternalTestSupport.XCTAssertNoDiagnostics
import XCTest

final class ProductBuildDescriptionTests: XCTestCase {
    func testEmbeddedProducts() throws {
        let fs = InMemoryFileSystem(
            emptyFiles:
            "/Pkg/Sources/exe/main.swift"
        )

        let observability = ObservabilitySystem.makeForTesting()
        let graph = try loadModulesGraph(
            fileSystem: fs,
            manifests: [
                Manifest.createRootManifest(
                    displayName: "Pkg",
                    path: "/Pkg",
                    targets: [
                        TargetDescription(
                            name: "exe",
                            settings: [.init(tool: .swift, kind: .enableExperimentalFeature("Embedded"))]
                        ),
                    ]
                ),
            ],
            observabilityScope: observability.topScope
        )
        XCTAssertNoDiagnostics(observability.diagnostics)

        let id = ResolvedProduct.ID(productName: "exe", packageIdentity: .plain("pkg"), buildTriple: .destination)
        let package = try XCTUnwrap(graph.rootPackages.first)
        let product = try XCTUnwrap(graph.allProducts[id])

        let buildDescription = try ProductBuildDescription(
            package: package,
            product: product,
            toolsVersion: .v5_9,
            buildParameters: mockBuildParameters(destination: .target, environment: .init(platform: .macOS)),
            fileSystem: fs,
            observabilityScope: observability.topScope
        )

        XCTAssertTrue(
            try buildDescription.linkArguments()
                .joined(separator: " ")
                .contains("-enable-experimental-feature Embedded")
        )
    }
}
