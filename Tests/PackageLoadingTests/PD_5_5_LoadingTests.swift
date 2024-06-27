//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation
import PackageLoading
import PackageModel
import _InternalTestSupport
import XCTest

class PackageDescription5_5LoadingTests: PackageDescriptionLoadingTests {
    override var toolsVersion: ToolsVersion {
        .v5_5
    }

    func testPackageDependencies() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "Foo",
               dependencies: [
                   .package(url: "/foo5", branch: "main"),
                   .package(url: "/foo7", revision: "58e9de4e7b79e67c72a46e164158e3542e570ab6"),
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        let deps = Dictionary(uniqueKeysWithValues: manifest.dependencies.map{ ($0.identity.description, $0) })
        XCTAssertEqual(deps["foo5"], .localSourceControl(path: "/foo5", requirement: .branch("main")))
        XCTAssertEqual(deps["foo7"], .localSourceControl(path: "/foo7", requirement: .revision("58e9de4e7b79e67c72a46e164158e3542e570ab6")))
    }

    func testPlatforms() async throws {
        let content =  """
            import PackageDescription
            let package = Package(
               name: "Foo",
               platforms: [
                   .macOS(.v12), .iOS(.v15),
                   .tvOS(.v15), .watchOS(.v8),
                   .macCatalyst(.v15), .driverKit(.v21),
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.platforms, [
            PlatformDescription(name: "macos", version: "12.0"),
            PlatformDescription(name: "ios", version: "15.0"),
            PlatformDescription(name: "tvos", version: "15.0"),
            PlatformDescription(name: "watchos", version: "8.0"),
            PlatformDescription(name: "maccatalyst", version: "15.0"),
            PlatformDescription(name: "driverkit", version: "21.0"),
        ])
    }
}
