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
import class Basics.InMemoryFileSystem
import class Basics.ObservabilitySystem
import class Build.BuildPlan
import class Build.ProductBuildDescription
import enum Build.ModuleBuildDescription
import class Build.SwiftModuleBuildDescription
import struct Basics.Triple
import enum PackageGraph.BuildTriple
import class PackageModel.Manifest
import struct PackageModel.TargetDescription
import enum PackageModel.ProductType
import struct SPMBuildCore.BuildParameters
import func _InternalTestSupport.loadPackageGraph

import func _InternalTestSupport.embeddedCxxInteropPackageGraph
import func _InternalTestSupport.macrosPackageGraph
import func _InternalTestSupport.macrosTestsPackageGraph
import func _InternalTestSupport.mockBuildParameters
import func _InternalTestSupport.mockBuildPlan
import func _InternalTestSupport.toolsExplicitLibrariesGraph
import func _InternalTestSupport.trivialPackageGraph

import struct _InternalTestSupport.BuildPlanResult
import func _InternalTestSupport.XCTAssertMatch
import func _InternalTestSupport.XCTAssertNoDiagnostics

import XCTest

final class CrossCompilationBuildPlanTests: XCTestCase {
    func testEmbeddedWasmTarget() throws {
        var (graph, fs, observabilityScope) = try trivialPackageGraph()

        let triple = try Triple("wasm32-unknown-none-wasm")

        let linkingParameters = BuildParameters.Linking(
            shouldLinkStaticSwiftStdlib: true
        )

        var result = try BuildPlanResult(plan: mockBuildPlan(
            triple: triple,
            graph: graph,
            linkingParameters: linkingParameters,
            fileSystem: fs,
            observabilityScope: observabilityScope
        ))
        result.checkProductsCount(2)
        // There are two additional modules on non-Apple platforms, for test discovery and
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

        (graph, fs, observabilityScope) = try embeddedCxxInteropPackageGraph()

        result = try BuildPlanResult(plan: mockBuildPlan(
            triple: triple,
            graph: graph,
            linkingParameters: linkingParameters,
            fileSystem: fs,
            observabilityScope: observabilityScope
        ))
        result.checkProductsCount(2)
        // There are two additional modules on non-Apple platforms, for test discovery and
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
        let (graph, fs, observabilityScope) = try trivialPackageGraph()

        let result = try BuildPlanResult(plan: mockBuildPlan(
            config: .release,
            triple: .wasi,
            graph: graph,
            linkingParameters: .init(
                linkerDeadStrip: true,
                shouldLinkStaticSwiftStdlib: true
            ),
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

        let (graph, fs, observabilityScope) = try trivialPackageGraph()

        let result = try BuildPlanResult(plan: mockBuildPlan(
            triple: .wasi,
            graph: graph,
            linkingParameters: .init(
                shouldLinkStaticSwiftStdlib: true
            ),
            fileSystem: fs,
            observabilityScope: observabilityScope
        ))
        result.checkProductsCount(2)
        // There are two additional modules on non-Apple platforms, for test discovery and
        // test entry point
        result.checkTargetsCount(5)

        let buildPath = result.plan.productsBuildPath

        let lib = try XCTUnwrap(
            result.allTargets(named: "lib")
                .map { try $0.clang() }
                .first { $0.target.buildTriple == .destination }
        )

        XCTAssertEqual(try lib.basicArguments(isCXX: false), [
            "-target", "wasm32-unknown-wasi",
            "-O0", "-DSWIFT_PACKAGE=1", "-DDEBUG=1",
            "-fblocks",
            "-I", pkgPath.appending(components: "Sources", "lib", "include").pathString,
            "-g",
        ])
        XCTAssertEqual(try lib.objects, [buildPath.appending(components: "lib.build", "lib.c.o")])
        XCTAssertEqual(lib.moduleMap, buildPath.appending(components: "lib.build", "module.modulemap"))

        let exe = try result.moduleBuildDescription(for: "app").swift().compileArguments()
        XCTAssertMatch(
            exe,
            [
                "-enable-batch-mode", "-Onone", "-enable-testing",
                "-j3", "-DSWIFT_PACKAGE", "-DDEBUG", "-Xcc",
                "-fmodule-map-file=\(buildPath.appending(components: "lib.build", "module.modulemap"))",
                "-Xcc", "-I", "-Xcc", "\(pkgPath.appending(components: "Sources", "lib", "include"))",
                "-module-cache-path", "\(buildPath.appending(components: "ModuleCache"))", .anySequence,
                "-swift-version", "4", "-g", .anySequence,
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
            destinationBuildParameters: mockBuildParameters(
                destination: .target,
                shouldLinkStaticSwiftStdlib: true,
                triple: destinationTriple
            ),
            toolsBuildParameters: mockBuildParameters(
                destination: .host,
                triple: toolsTriple
            ),
            graph: graph,
            fileSystem: fs,
            observabilityScope: scope
        )
        let result = try BuildPlanResult(plan: plan)
        result.checkProductsCount(3)
        result.checkTargetsCount(10)

        XCTAssertTrue(try result.allTargets(named: "SwiftSyntax")
            .map { try $0.swift() }
            .contains { $0.target.buildTriple == .tools })
        try result.check(buildTriple: .tools, triple: toolsTriple, for: "MMIOMacros")
        try result.check(buildTriple: .destination, triple: destinationTriple, for: "MMIO")
        try result.check(buildTriple: .destination, triple: destinationTriple, for: "Core")
        try result.check(buildTriple: .destination, triple: destinationTriple, for: "HAL")

        let macroProducts = result.allProducts(named: "MMIOMacros")
        XCTAssertEqual(macroProducts.count, 1)
        let macroProduct = try XCTUnwrap(macroProducts.first)
        XCTAssertEqual(macroProduct.buildParameters.triple, toolsTriple)

        let mmioTargets = try result.allTargets(named: "MMIO").map { try $0.swift() }
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

    func testMacrosTests() throws {
        let (graph, fs, scope) = try macrosTestsPackageGraph()

        let destinationTriple = Triple.arm64Linux
        let toolsTriple = Triple.x86_64MacOS
        let plan = try BuildPlan(
            destinationBuildParameters: mockBuildParameters(
                destination: .target,
                shouldLinkStaticSwiftStdlib: true,
                triple: destinationTriple
            ),
            toolsBuildParameters: mockBuildParameters(
                destination: .host,
                triple: toolsTriple
            ),
            graph: graph,
            fileSystem: fs,
            observabilityScope: scope
        )
        let result = try BuildPlanResult(plan: plan)
        result.checkProductsCount(2)
        result.checkTargetsCount(16)

        XCTAssertTrue(try result.allTargets(named: "SwiftSyntax")
            .map { try $0.swift() }
            .contains { $0.target.buildTriple == .tools })

        try result.check(buildTriple: .tools, triple: toolsTriple, for: "swift-mmioPackageTests")
        try result.check(buildTriple: .tools, triple: toolsTriple, for: "swift-mmioPackageDiscoveredTests")
        try result.check(buildTriple: .tools, triple: toolsTriple, for: "MMIOMacros")
        try result.check(buildTriple: .destination, triple: destinationTriple, for: "MMIO")
        try result.check(buildTriple: .tools, triple: toolsTriple, for: "MMIOMacrosTests")

        let macroProducts = result.allProducts(named: "MMIOMacros")
        XCTAssertEqual(macroProducts.count, 1)
        let macroProduct = try XCTUnwrap(macroProducts.first)
        XCTAssertEqual(macroProduct.buildParameters.triple, toolsTriple)

        let mmioTargets = try result.allTargets(named: "MMIO").map { try $0.swift() }
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

    func testToolsExplicitLibraries() throws {
        let destinationTriple = Triple.arm64Linux
        let toolsTriple = Triple.x86_64MacOS

        for (linkage, productFileName) in [(ProductType.LibraryType.static, "libSwiftSyntax-tool.a"), (.dynamic, "libSwiftSyntax-tool.dylib")] {
            let (graph, fs, scope) = try toolsExplicitLibrariesGraph(linkage: linkage)
            let plan = try BuildPlan(
                destinationBuildParameters: mockBuildParameters(
                    destination: .target,
                    shouldLinkStaticSwiftStdlib: true,
                    triple: destinationTriple
                ),
                toolsBuildParameters: mockBuildParameters(
                    destination: .host,
                    triple: toolsTriple
                ),
                graph: graph,
                fileSystem: fs,
                observabilityScope: scope
            )
            let result = try BuildPlanResult(plan: plan)
            result.checkProductsCount(4)
            result.checkTargetsCount(6)

            XCTAssertTrue(try result.allTargets(named: "SwiftSyntax")
                .map { try $0.swift() }
                .contains { $0.target.buildTriple == .tools })

            try result.check(buildTriple: .tools, triple: toolsTriple, for: "swift-mmioPackageTests")
            try result.check(buildTriple: .tools, triple: toolsTriple, for: "swift-mmioPackageDiscoveredTests")
            try result.check(buildTriple: .tools, triple: toolsTriple, for: "MMIOMacros")
            try result.check(buildTriple: .tools, triple: toolsTriple, for: "MMIOMacrosTests")

            let macroProducts = result.allProducts(named: "MMIOMacros")
            XCTAssertEqual(macroProducts.count, 1)
            let macroProduct = try XCTUnwrap(macroProducts.first)
            XCTAssertEqual(macroProduct.buildParameters.triple, toolsTriple)

            let swiftSyntaxProducts = result.allProducts(named: "SwiftSyntax")
            XCTAssertEqual(swiftSyntaxProducts.count, 2)
            let swiftSyntaxToolsProduct = try XCTUnwrap(swiftSyntaxProducts.first { $0.product.buildTriple == .tools })
            let archiveArguments = try swiftSyntaxToolsProduct.archiveArguments()

            // Verify that produced library file has a correct name
            XCTAssertMatch(archiveArguments, [.contains(productFileName)])
        }
    }
}

extension BuildPlanResult {
    func allTargets(named name: String) throws -> some Collection<ModuleBuildDescription> {
        self.targetMap
            .filter { $0.0.moduleName == name }
            .values
    }

    func allProducts(named name: String) -> some Collection<ProductBuildDescription> {
        self.productMap
            .filter { $0.0.productName == name }
            .values
    }

    func check(
        buildTriple: BuildTriple,
        triple: Triple,
        for target: String,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        let targets = self.targetMap.filter {
            $0.key.moduleName == target && $0.key.buildTriple == buildTriple
        }
        XCTAssertEqual(targets.count, 1, file: file, line: line)

        let target = try XCTUnwrap(
            targets.first?.value,
            file: file,
            line: line
        ).swift()
        XCTAssertMatch(try target.emitCommandLine(), [.contains(triple.tripleString)], file: file, line: line)
    }
}
