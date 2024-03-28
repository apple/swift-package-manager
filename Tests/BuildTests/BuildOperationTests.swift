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

@testable
import Build

@testable
import PackageModel

import Basics
import SPMTestSupport

import SPMBuildCore

import XCTest

import class TSCBasic.BufferedOutputByteStream
import class TSCBasic.InMemoryFileSystem

final class BuildOperationTests: XCTestCase {
    func testDetectUnexpressedDependencies() throws {
        let buildParameters = mockBuildParameters(shouldDisableLocalRpath: false)

        let fs = InMemoryFileSystem(files: [
            "\(buildParameters.dataPath)/debug/Lunch.build/Lunch.d" : "/Best.framework"
        ])

        let observability = ObservabilitySystem.makeForTesting()
        let buildOp = BuildOperation(
            productsBuildParameters: buildParameters,
            toolsBuildParameters: buildParameters,
            cacheBuildManifest: false,
            packageGraphLoader: { fatalError() },
            additionalFileRules: [],
            pkgConfigDirectories: [],
            dependenciesByRootPackageIdentity: [:],
            targetsByRootPackageIdentity: [:],
            outputStream: BufferedOutputByteStream(),
            logLevel: .info,
            fileSystem: fs,
            observabilityScope: observability.topScope
        )
        buildOp.detectUnexpressedDependencies(
            availableLibraries: [
                .init(
                    identities: [
                        .sourceControl(url: .init("https://example.com/org/foo"))
                    ],
                    version: "1.0.0",
                    productName: "Best",
                    schemaVersion: 1
                )
            ],
            targetDependencyMap: ["Lunch": []]
        )

        XCTAssertEqual(
            observability.diagnostics.map { $0.message },
            ["target 'Lunch' has an unexpressed depedency on 'foo'"]
        )
    }
}
