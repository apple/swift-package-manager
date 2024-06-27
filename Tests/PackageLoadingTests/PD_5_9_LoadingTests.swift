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
import PackageLoading
import PackageModel
import _InternalTestSupport
import XCTest

final class PackageDescription5_9LoadingTests: PackageDescriptionLoadingTests {
    override var toolsVersion: ToolsVersion {
        .v5_9
    }

    func testPlatforms() async throws {
        let content =  """
            import PackageDescription
            let package = Package(
               name: "Foo",
               platforms: [
                   .macOS(.v14), .iOS(.v17),
                   .tvOS(.v17), .watchOS(.v10), .visionOS(.v1),
                   .macCatalyst(.v17), .driverKit(.v23),
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.platforms, [
            PlatformDescription(name: "macos", version: "14.0"),
            PlatformDescription(name: "ios", version: "17.0"),
            PlatformDescription(name: "tvos", version: "17.0"),
            PlatformDescription(name: "watchos", version: "10.0"),
            PlatformDescription(name: "visionos", version: "1.0"),
            PlatformDescription(name: "maccatalyst", version: "17.0"),
            PlatformDescription(name: "driverkit", version: "23.0"),
        ])
    }

    func testMacroTargets() async throws {
        let content = """
            import CompilerPluginSupport
            import PackageDescription

            let package = Package(name: "MyPackage",
                targets: [
                    .macro(name: "MyMacro", swiftSettings: [.define("BEST")], linkerSettings: [.linkedLibrary("best")]),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (_, diagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertEqual(diagnostics.count, 0, "unexpected diagnostics: \(diagnostics)")
    }
}
