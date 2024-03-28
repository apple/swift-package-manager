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

import struct Basics.AbsolutePath
import class Basics.ObservabilitySystem
import class Build.BuildPlan
import class Build.ProductBuildDescription
import class Build.SwiftTargetBuildDescription
import struct Basics.Triple
import enum PackageGraph.BuildTriple
import class PackageModel.Manifest
import struct PackageModel.TargetDescription
import func SPMTestSupport.loadPackageGraph

import func SPMTestSupport.embeddedCxxInteropPackageGraph
import func SPMTestSupport.macrosPackageGraph
import func SPMTestSupport.mockBuildParameters
import func SPMTestSupport.trivialPackageGraph

import struct SPMTestSupport.BuildPlanResult
import func SPMTestSupport.XCTAssertMatch
import func SPMTestSupport.XCTAssertNoDiagnostics
import class TSCBasic.InMemoryFileSystem

import XCTest

final class CrossCompilationBuildPlanTests: XCTestCase {
    func testEmbeddedWasmTarget() throws {
        var (graph, fs, observabilityScope) = try trivialPackageGraph(pkgRootPath: "/Pkg")

        let triple = try Triple("wasm32-unknown-none-wasm")
        var parameters = mockBuildParameters(triple: triple)
        parameters.linkingParameters.shouldLinkStaticSwiftStdlib = true
        var result = try BuildPlanResult(plan: BuildPlan(
            buildParameters: parameters,
            graph: graph,
            fileSystem: fs,
            observabilityScope: observabilityScope
        ))
        result.checkProductsCount(2)
        // There are two additional targets on non-Apple platforms, for test discovery and
        // test entry point
        result.checkTargetsCount(5)

        let buildPath = result.plan.productsBuildPath
        var appBuildDescription = try result.buildProduct(for: "app")
        XCTAssertEqual(
            try appBuildDescription.linkArguments(),
            [
                result.plan.destinationBuildParameters.toolchain.swiftCompilerPath.pathString,
                "-L", buildPath.pathString,
                "-o", buildPath.appending(components: "app.wasm").pathString,
                "-module-name", "app", "-static-stdlib", "-emit-executable",
                "@\(buildPath.appending(components: "app.product", "Objects.LinkFileList"))",
                "-target", triple.tripleString,
                "-g",
            ]
        )

        (graph, fs, observabilityScope) = try embeddedCxxInteropPackageGraph(pkgRootPath: "/Pkg")

        result = try BuildPlanResult(plan: BuildPlan(
            buildParameters: parameters,
            graph: graph,
            fileSystem: fs,
            observabilityScope: observabilityScope
        ))
        result.checkProductsCount(2)
        // There are two additional targets on non-Apple platforms, for test discovery and
        // test entry point
        result.checkTargetsCount(5)

        appBuildDescription = try result.buildProduct(for: "app")
        XCTAssertEqual(
            try appBuildDescription.linkArguments(),
            [
                result.plan.destinationBuildParameters.toolchain.swiftCompilerPath.pathString,
                "-L", buildPath.pathString,
                "-o", buildPath.appending(components: "app.wasm").pathString,
                "-module-name", "app", "-static-stdlib", "-emit-executable",
                "@\(buildPath.appending(components: "app.product", "Objects.LinkFileList"))",
                "-enable-experimental-feature", "Embedded",
                "-target", triple.tripleString,
                "-g",
            ]
        )
    }

    func testWasmTargetRelease() throws {
        let pkgPath = AbsolutePath("/Pkg")

        let (graph, fs, observabilityScope) = try trivialPackageGraph(pkgRootPath: pkgPath)

        var parameters = mockBuildParameters(
            config: .release, triple: .wasi, linkerDeadStrip: true
        )
        parameters.linkingParameters.shouldLinkStaticSwiftStdlib = true
        let result = try BuildPlanResult(plan: BuildPlan(
            buildParameters: parameters,
            graph: graph,
            fileSystem: fs,
            observabilityScope: observabilityScope
        ))
        let buildPath = result.plan.productsBuildPath

        let appBuildDescription = try result.buildProduct(for: "app")
        XCTAssertEqual(
            try appBuildDescription.linkArguments(),
            [
                result.plan.destinationBuildParameters.toolchain.swiftCompilerPath.pathString,
                "-L", buildPath.pathString,
                "-o", buildPath.appending(components: "app.wasm").pathString,
                "-module-name", "app", "-static-stdlib", "-emit-executable",
                "-Xlinker", "--gc-sections",
                "@\(buildPath.appending(components: "app.product", "Objects.LinkFileList"))",
                "-target", "wasm32-unknown-wasi",
                "-g",
            ]
        )
    }

    func testWASITarget() throws {
        let pkgPath = AbsolutePath("/Pkg")

        let (graph, fs, observabilityScope) = try trivialPackageGraph(pkgRootPath: pkgPath)

        var parameters = mockBuildParameters(triple: .wasi)
        parameters.linkingParameters.shouldLinkStaticSwiftStdlib = true
        let result = try BuildPlanResult(plan: BuildPlan(
            buildParameters: parameters,
            graph: graph,
            fileSystem: fs,
            observabilityScope: observabilityScope
        ))
        result.checkProductsCount(2)
        // There are two additional targets on non-Apple platforms, for test discovery and
        // test entry point
        result.checkTargetsCount(5)

        let buildPath = result.plan.productsBuildPath

        let lib = try result.target(for: "lib").clangTarget()
        XCTAssertEqual(try lib.basicArguments(isCXX: false), [
            "-target", "wasm32-unknown-wasi",
            "-O0", "-DSWIFT_PACKAGE=1", "-DDEBUG=1",
            "-fblocks",
            "-I", pkgPath.appending(components: "Sources", "lib", "include").pathString,
            "-g",
        ])
        XCTAssertEqual(try lib.objects, [buildPath.appending(components: "lib.build", "lib.c.o")])
        XCTAssertEqual(lib.moduleMap, buildPath.appending(components: "lib.build", "module.modulemap"))

        let exe = try result.target(for: "app").swiftTarget().compileArguments()
        XCTAssertMatch(
            exe,
            [
                "-swift-version", "4", "-enable-batch-mode", "-Onone", "-enable-testing",
                "-j3", "-DSWIFT_PACKAGE", "-DDEBUG", "-Xcc",
                "-fmodule-map-file=\(buildPath.appending(components: "lib.build", "module.modulemap"))",
                "-Xcc", "-I", "-Xcc", "\(pkgPath.appending(components: "Sources", "lib", "include"))",
                "-module-cache-path", "\(buildPath.appending(components: "ModuleCache"))", .anySequence,
                "-g", .anySequence,
            ]
        )

        let appBuildDescription = try result.buildProduct(for: "app")
        XCTAssertEqual(
            try appBuildDescription.linkArguments(),
            [
                result.plan.destinationBuildParameters.toolchain.swiftCompilerPath.pathString,
                "-L", buildPath.pathString,
                "-o", buildPath.appending(components: "app.wasm").pathString,
                "-module-name", "app", "-static-stdlib", "-emit-executable",
                "@\(buildPath.appending(components: "app.product", "Objects.LinkFileList"))",
                "-target", "wasm32-unknown-wasi",
                "-g",
            ]
        )

        let executablePathExtension = try appBuildDescription.binaryPath.extension
        XCTAssertEqual(executablePathExtension, "wasm")

        let testBuildDescription = try result.buildProduct(for: "PkgPackageTests")
        XCTAssertEqual(
            try testBuildDescription.linkArguments(),
            [
                result.plan.destinationBuildParameters.toolchain.swiftCompilerPath.pathString,
                "-L", buildPath.pathString,
                "-o", buildPath.appending(components: "PkgPackageTests.wasm").pathString,
                "-module-name", "PkgPackageTests",
                "-emit-executable",
                "@\(buildPath.appending(components: "PkgPackageTests.product", "Objects.LinkFileList"))",
                "-target", "wasm32-unknown-wasi",
                "-g",
            ]
        )

        let testPathExtension = try testBuildDescription.binaryPath.extension
        XCTAssertEqual(testPathExtension, "wasm")
    }

    func testMacros() throws {
        let (graph, fs, scope) = try macrosPackageGraph()

        let destinationTriple = Triple.arm64Linux
        let toolsTriple = Triple.x86_64MacOS
        let plan = try BuildPlan(
            destinationBuildParameters: mockBuildParameters(shouldLinkStaticSwiftStdlib: true, triple: destinationTriple),
            toolsBuildParameters: mockBuildParameters(triple: toolsTriple),
            graph: graph,
            fileSystem: fs,
            observabilityScope: scope
        )
        let result = try BuildPlanResult(plan: plan)
        result.checkProductsCount(3)
        result.checkTargetsCount(10)

        XCTAssertTrue(try result.allTargets(named: "SwiftSyntax").contains { $0.target.buildTriple == .tools })
        try result.check(buildTriple: .tools, triple: toolsTriple, for: "MMIOMacros")
        try result.check(buildTriple: .destination, triple: destinationTriple, for: "MMIO")
        try result.check(buildTriple: .destination, triple: destinationTriple, for: "Core")
        try result.check(buildTriple: .destination, triple: destinationTriple, for: "HAL")

        let macroProducts = result.allProducts(named: "MMIOMacros")
        XCTAssertEqual(macroProducts.count, 1)
        let macroProduct = try XCTUnwrap(macroProducts.first)
        XCTAssertEqual(macroProduct.buildParameters.triple, toolsTriple)

        let mmioTargets = try result.allTargets(named: "MMIO")
        XCTAssertEqual(mmioTargets.count, 1)
        let mmioTarget = try XCTUnwrap(mmioTargets.first)
        let compileArguments = try mmioTarget.emitCommandLine()
        XCTAssertMatch(
            compileArguments,
            [
                "-I", .equal(mmioTarget.moduleOutputPath.parentDirectory.pathString),
                .anySequence,
                "-Xfrontend", "-load-plugin-executable",
                // Verify that macros are located in the tools triple directory.
                "-Xfrontend", .contains(toolsTriple.tripleString)
            ]
        )
    }
}

extension BuildPlanResult {
    func allTargets(named name: String) throws -> [SwiftTargetBuildDescription] {
        try self.targetMap
            .filter { $0.0.targetName == name }
            .map { try $1.swiftTarget() }
    }

    func allProducts(named name: String) -> [ProductBuildDescription] {
        self.productMap
            .filter { $0.0.productName == name }
            .map { $1 }
    }

    func check(
        buildTriple: BuildTriple,
        triple: Triple,
        for target: String,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        let target = try XCTUnwrap(
            self.targetMap.first {
                $0.key.targetName == target && $0.key.buildTriple == buildTriple
            }?.value,
            file: file,
            line: line
        ).swiftTarget()
        XCTAssertMatch(try target.emitCommandLine(), [.contains(triple.tripleString)], file: file, line: line)
    }
}
