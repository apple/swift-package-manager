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

import Build
import Foundation
import LLBuildManifest
import _InternalTestSupport
import TSCBasic
import XCTest
import class Basics.ObservabilitySystem
@_spi(DontAdoptOutsideOfSwiftPMExposedForBenchmarksAndTestsOnly)
import func PackageGraph.loadModulesGraph
import class PackageModel.Manifest
import struct PackageModel.TargetDescription

class PrepareForIndexTests: XCTestCase {
    func testPrepare() throws {
        let (graph, fs, scope) = try macrosPackageGraph()

        let plan = try BuildPlan(
            destinationBuildParameters: mockBuildParameters(destination: .target, prepareForIndexing: true),
            toolsBuildParameters: mockBuildParameters(destination: .host, prepareForIndexing: false),
            graph: graph,
            fileSystem: fs,
            observabilityScope: scope
        )

        let builder = LLBuildManifestBuilder(plan, fileSystem: fs, observabilityScope: scope)
        let manifest = try builder.generatePrepareManifest(at: "/manifest")

        // Make sure we're building the swift modules
        let outputs = manifest.commands.flatMap(\.value.tool.outputs).map(\.name)
        XCTAssertTrue(outputs.contains(where: { $0.hasSuffix(".swiftmodule") }))

        // Ensure swiftmodules built with correct arguments
        let coreCommands = manifest.commands.values.filter {
            $0.tool.outputs.contains(where: {
                $0.name.hasSuffix("debug/Core.build/Core.swiftmodule")
            })
        }
        XCTAssertEqual(coreCommands.count, 1)
        let coreSwiftc = try XCTUnwrap(coreCommands.first?.tool as? SwiftCompilerTool)
        XCTAssertTrue(coreSwiftc.otherArguments.contains("-experimental-skip-all-function-bodies"))

        // Ensure tools are built normally
        let toolCommands = manifest.commands.values.filter {
            $0.tool.outputs.contains(where: {
                $0.name.hasSuffix("debug/Modules-tool/SwiftSyntax.swiftmodule")
            })
        }
        XCTAssertEqual(toolCommands.count, 1)
        let toolSwiftc = try XCTUnwrap(toolCommands.first?.tool as? SwiftCompilerTool)
        XCTAssertFalse(toolSwiftc.otherArguments.contains("-experimental-skip-all-function-bodies"))

        // Make sure only object files for tools are built
        XCTAssertTrue(
            outputs.filter { $0.hasSuffix(".o") }.allSatisfy { $0.contains("-tool.build/") },
            "outputs:\n\t\(outputs.filter { $0.hasSuffix(".o") }.joined(separator: "\n\t"))"
        )
    }

    func testCModuleTarget() throws {
        let (graph, fs, scope) = try trivialPackageGraph()

        let plan = try BuildPlan(
            destinationBuildParameters: mockBuildParameters(destination: .target, prepareForIndexing: true),
            toolsBuildParameters: mockBuildParameters(destination: .host, prepareForIndexing: false),
            graph: graph,
            fileSystem: fs,
            observabilityScope: scope
        )
        let builder = LLBuildManifestBuilder(plan, fileSystem: fs, observabilityScope: scope)
        let manifest = try builder.generatePrepareManifest(at: "/manifest")

        // Ensure our C module is here.
        let lib = try XCTUnwrap(graph.module(for: "lib", destination: .destination))
        let name = lib.getLLBuildTargetName(buildParameters: plan.destinationBuildParameters)
        XCTAssertTrue(manifest.targets.keys.contains(name))
    }

    // enable-testing requires the non-exportable-decls, make sure they aren't skipped.
    func testEnableTesting() throws {
        let fs = InMemoryFileSystem(
            emptyFiles:
            "/Pkg/Sources/lib/lib.swift",
            "/Pkg/Tests/test/TestCase.swift"
        )

        let observability = ObservabilitySystem.makeForTesting()
        let scope = observability.topScope

        let graph = try loadModulesGraph(
            fileSystem: fs,
            manifests: [
                Manifest.createRootManifest(
                    displayName: "Pkg",
                    path: "/Pkg",
                    targets: [
                        TargetDescription(name: "lib", dependencies: []),
                        TargetDescription(name: "test", dependencies: ["lib"], type: .test),
                    ]
                ),
            ],
            observabilityScope: scope
        )
        XCTAssertNoDiagnostics(observability.diagnostics)

        // Under debug, enable-testing is turned on by default. Make sure the flag is not added.
        let debugPlan = try BuildPlan(
            destinationBuildParameters: mockBuildParameters(destination: .target, config: .debug, prepareForIndexing: true),
            toolsBuildParameters: mockBuildParameters(destination: .host, prepareForIndexing: false),
            graph: graph,
            fileSystem: fs,
            observabilityScope: observability.topScope
        )
        let debugBuilder = LLBuildManifestBuilder(debugPlan, fileSystem: fs, observabilityScope: scope)
        let debugManifest = try debugBuilder.generatePrepareManifest(at: "/manifest")

        XCTAssertNil(debugManifest.commands.values.first(where: {
            guard let swiftCommand = $0.tool as? SwiftCompilerTool,
                swiftCommand.outputs.contains(where: { $0.name.hasSuffix("/lib.swiftmodule")})
            else {
                return false
            }
            return swiftCommand.otherArguments.contains("-experimental-skip-non-exportable-decls")
                && !swiftCommand.otherArguments.contains("-enable-testing")
        }))

        // Under release, enable-testing is turned off by default so we should see our flag
        let releasePlan = try BuildPlan(
            destinationBuildParameters: mockBuildParameters(destination: .target, config: .release, prepareForIndexing: true),
            toolsBuildParameters: mockBuildParameters(destination: .host, prepareForIndexing: false),
            graph: graph,
            fileSystem: fs,
            observabilityScope: observability.topScope
        )
        let releaseBuilder = LLBuildManifestBuilder(releasePlan, fileSystem: fs, observabilityScope: scope)
        let releaseManifest = try releaseBuilder.generatePrepareManifest(at: "/manifest")

        XCTAssertEqual(releaseManifest.commands.values.filter({
            guard let swiftCommand = $0.tool as? SwiftCompilerTool,
                swiftCommand.outputs.contains(where: { $0.name.hasSuffix("/lib.swiftmodule")})
            else {
                return false
            }
            return swiftCommand.otherArguments.contains("-experimental-skip-non-exportable-decls")
                && !swiftCommand.otherArguments.contains("-enable-testing")
        }).count, 1)
    }
}
