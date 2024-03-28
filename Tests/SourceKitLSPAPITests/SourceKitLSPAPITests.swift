//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Build
import PackageGraph
import PackageModel
import SourceKitLSPAPI
import SPMTestSupport
import TSCBasic
import XCTest

class SourceKitLSPAPITests: XCTestCase {
    func testBasicSwiftPackage() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/exe/main.swift",
            "/Pkg/Sources/lib/lib.swift"
        )

        let observability = ObservabilitySystem.makeForTesting()
        let graph = try loadModulesGraph(
            fileSystem: fs,
            manifests: [
                Manifest.createRootManifest(
                    displayName: "Pkg",
                    path: "/Pkg",
                    targets: [
                        TargetDescription(name: "exe", dependencies: ["lib"]),
                        TargetDescription(name: "lib", dependencies: []),
                    ]),
            ],
            observabilityScope: observability.topScope
        )
        XCTAssertNoDiagnostics(observability.diagnostics)

        let buildParameters = mockBuildParameters(shouldLinkStaticSwiftStdlib: true)
        let plan = try BuildPlan(
            destinationBuildParameters: buildParameters,
            toolsBuildParameters: buildParameters,
            graph: graph,
            fileSystem: fs,
            observabilityScope: observability.topScope
        )
        let description = BuildDescription(buildPlan: plan)

        try description.checkArguments(
            for: "exe",
            graph: graph,
            partialArguments: [
                "-module-name", "exe",
                "-emit-dependencies",
                "-emit-module",
                "-emit-module-path", "/path/to/build/\(buildParameters.triple)/debug/exe.build/exe.swiftmodule"
            ]
        )
        try description.checkArguments(
            for: "lib",
            graph: graph,
            partialArguments: [
                "-module-name", "lib",
                "-emit-dependencies",
                "-emit-module",
                "-emit-module-path", "/path/to/build/\(buildParameters.triple)/debug/Modules/lib.swiftmodule"
            ]
        )
    }
}

extension SourceKitLSPAPI.BuildDescription {
    @discardableResult func checkArguments(
        for targetName: String,
        graph: ModulesGraph,
        partialArguments: [String]
    ) throws -> Bool {
        let target = try XCTUnwrap(graph.allTargets.first(where: { $0.name == targetName }))
        let buildTarget = try XCTUnwrap(self.getBuildTarget(for: target))

        guard let file = buildTarget.sources.first else {
            XCTFail("build target \(targetName) contains no files")
            return false
        }

        let arguments = try buildTarget.compileArguments(for: file)
        let result = arguments.contains(partialArguments)

        XCTAssertTrue(result, "could not match \(partialArguments) to actual arguments \(arguments)")
        return result
    }
}
