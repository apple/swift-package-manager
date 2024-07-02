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

@testable import Build
@testable import PackageModel

import Basics
import LLBuildManifest
@_spi(DontAdoptOutsideOfSwiftPMExposedForBenchmarksAndTestsOnly)
import PackageGraph
import SPMBuildCore
@_spi(SwiftPMInternal)
import _InternalTestSupport
import XCTest

import class TSCBasic.BufferedOutputByteStream

private func mockBuildOperation(
    productsBuildParameters: BuildParameters,
    toolsBuildParameters: BuildParameters,
    cacheBuildManifest: Bool = false,
    packageGraphLoader: @escaping () -> ModulesGraph = { fatalError() },
    scratchDirectory: AbsolutePath,
    fs: any Basics.FileSystem,
    observabilityScope: ObservabilityScope
) -> BuildOperation {
    return BuildOperation(
        productsBuildParameters: productsBuildParameters,
        toolsBuildParameters: toolsBuildParameters,
        cacheBuildManifest: cacheBuildManifest,
        packageGraphLoader: packageGraphLoader,
        scratchDirectory: scratchDirectory,
        additionalFileRules: [],
        pkgConfigDirectories: [],
        dependenciesByRootPackageIdentity: [:],
        targetsByRootPackageIdentity: [:],
        outputStream: BufferedOutputByteStream(),
        logLevel: .info,
        fileSystem: fs,
        observabilityScope: observabilityScope
    )
}

final class BuildOperationTests: XCTestCase {
    func testDetectUnexpressedDependencies() throws {
        let scratchDirectory = AbsolutePath("/path/to/build")
        let triple = hostTriple
        let targetBuildParameters = mockBuildParameters(
            destination: .target,
            buildPath: scratchDirectory.appending(triple.tripleString),
            shouldDisableLocalRpath: false,
            triple: triple
        )

        let fs = InMemoryFileSystem(files: [
            "\(targetBuildParameters.dataPath)/debug/Lunch.build/Lunch.d" : "/Best.framework"
        ])

        let observability = ObservabilitySystem.makeForTesting()
        let buildOp = mockBuildOperation(
            productsBuildParameters: targetBuildParameters,
            toolsBuildParameters: mockBuildParameters(destination: .host, shouldDisableLocalRpath: false),
            scratchDirectory: scratchDirectory,
            fs: fs, observabilityScope: observability.topScope
        )
        buildOp.detectUnexpressedDependencies(
            availableLibraries: [
                .init(
                    location: "/foo",
                    metadata: .init(
                        identities: [
                            .sourceControl(url: .init("https://example.com/org/foo"))
                        ],
                        version: "1.0.0",
                        productName: "Best",
                        schemaVersion: 1
                    )
                )
            ],
            targetDependencyMap: ["Lunch": []]
        )

        XCTAssertEqual(
            observability.diagnostics.map { $0.message },
            ["target 'Lunch' has an unexpressed depedency on 'foo'"]
        )
    }

    func testDetectProductTripleChange() throws {
        let observability = ObservabilitySystem.makeForTesting()
        let fs = InMemoryFileSystem(
            emptyFiles: "/Pkg/Sources/ATarget/foo.swift"
        )
        let packageGraph = try loadModulesGraph(
            fileSystem: fs,
            manifests: [
                .createRootManifest(
                    displayName: "SwitchTriple",
                    path: "/Pkg",
                    targets: [
                        TargetDescription(name: "ATarget"),
                    ]
                ),
            ],
            observabilityScope: observability.topScope
        )
        try withTemporaryDirectory { tmpDir in
            let scratchDirectory = tmpDir.appending(".build")
            let fs = localFileSystem
            let triples = try [Triple("x86_64-unknown-linux-gnu"), Triple("wasm32-unknown-wasi")]
            var llbuildManifestByTriple: [String: String] = [:]

            // Perform initial builds for each triple
            for triple in triples {
                let targetBuildParameters = mockBuildParameters(
                    destination: .target,
                    buildPath: scratchDirectory.appending(triple.tripleString),
                    config: .debug,
                    triple: triple
                )
                let buildOp = mockBuildOperation(
                    productsBuildParameters: targetBuildParameters,
                    toolsBuildParameters: mockBuildParameters(destination: .host),
                    cacheBuildManifest: false,
                    packageGraphLoader: { packageGraph },
                    scratchDirectory: scratchDirectory,
                    fs: fs, observabilityScope: observability.topScope
                )
                // Generate initial llbuild manifest
                let _ = try buildOp.getBuildDescription()
                // Record the initial llbuild manifest as expected one
                llbuildManifestByTriple[triple.tripleString] = try fs.readFileContents(targetBuildParameters.llbuildManifest)
            }

            XCTAssertTrue(fs.exists(scratchDirectory.appending("debug.yaml")))
            // FIXME: There should be a build database with manifest cache after the initial build.
            // The initial build usually triggered with `cacheBuildManifest=false` because llbuild
            // manifest file and description.json are not found. However, with `cacheBuildManifest=false`,
            // `BuildOperation` does not trigger "PackageStructure" build, thus the initial build does
            // not record the manifest cache. So "getBuildDescription" doesn't create build.db for the
            // initial planning and the second build always need full-planning.
            //
            // XCTAssertTrue(fs.exists(scratchDirectory.appending("build.db")))

            // Perform incremental build several times and switch triple for each time
            for _ in 0..<4 {
                for triple in triples {
                    let targetBuildParameters = mockBuildParameters(
                        destination: .target,
                        buildPath: scratchDirectory.appending(triple.tripleString),
                        config: .debug,
                        triple: triple
                    )
                    let buildOp = mockBuildOperation(
                        productsBuildParameters: targetBuildParameters,
                        toolsBuildParameters: mockBuildParameters(destination: .host),
                        cacheBuildManifest: true,
                        packageGraphLoader: { packageGraph },
                        scratchDirectory: scratchDirectory,
                        fs: fs, observabilityScope: observability.topScope
                    )
                    // Generate llbuild manifest
                    let _ = try buildOp.getBuildDescription()

                    // Ensure that llbuild manifest is updated to the expected one
                    let actualManifest: String = try fs.readFileContents(targetBuildParameters.llbuildManifest)
                    let expectedManifest = try XCTUnwrap(llbuildManifestByTriple[triple.tripleString])
                    XCTAssertEqual(actualManifest, expectedManifest)
                }
            }
        }
    }

    func testHostProductsAndTargetsWithoutExplicitDestination() throws {
        let mock  = try macrosTestsPackageGraph()

        let op = mockBuildOperation(
            productsBuildParameters: mockBuildParameters(destination: .target),
            toolsBuildParameters: mockBuildParameters(destination: .host),
            packageGraphLoader: { mock.graph },
            scratchDirectory: AbsolutePath("/.build/\(hostTriple)"),
            fs: mock.fileSystem,
            observabilityScope: mock.observabilityScope
        )

        XCTAssertEqual(
            "MMIOMacros-\(hostTriple)-debug-tool.exe",
            try op.computeLLBuildTargetName(for: .product("MMIOMacros"))
        )

        for target in ["MMIOMacros", "MMIOPlugin", "MMIOMacrosTests", "MMIOMacro+PluginTests"] {
            XCTAssertEqual(
                "\(target)-\(hostTriple)-debug-tool.module",
                try op.computeLLBuildTargetName(for: .target(target))
            )
        }

        let dependencies = try BuildSubset.target("MMIOMacro+PluginTests").recursiveDependencies(
            for: mock.graph,
            observabilityScope: mock.observabilityScope
        )

        XCTAssertNotNil(dependencies)
        XCTAssertTrue(dependencies!.count > 0)

        for dependency in dependencies! {
            XCTAssertEqual(dependency.buildTriple, .tools)
        }
    }
}
