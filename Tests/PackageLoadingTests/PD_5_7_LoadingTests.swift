//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2022 Apple Inc. and the Swift project authors
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

final class PackageDescription5_7LoadingTests: PackageDescriptionLoadingTests {
    override var toolsVersion: ToolsVersion {
        .v5_7
    }

    func testImplicitFoundationImportWorks() async throws {
        let content = """
            import PackageDescription

            _ = FileManager.default

            let package = Package(name: "MyPackage")
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)
        XCTAssertEqual(manifest.displayName, "MyPackage")
    }

    func testRegistryDependencies() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "MyPackage",
               dependencies: [
                   .package(id: "x.foo", from: "1.1.1"),
                   .package(id: "x.bar", exact: "1.1.1"),
                   .package(id: "x.baz", .upToNextMajor(from: "1.1.1")),
                   .package(id: "x.qux", .upToNextMinor(from: "1.1.1")),
                   .package(id: "x.quux", "1.1.1" ..< "3.0.0"),
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        let deps = Dictionary(uniqueKeysWithValues: manifest.dependencies.map{ ($0.identity.description, $0) })
        XCTAssertEqual(deps["x.foo"], .registry(identity: "x.foo", requirement: .range("1.1.1" ..< "2.0.0")))
        XCTAssertEqual(deps["x.bar"], .registry(identity: "x.bar", requirement: .exact("1.1.1")))
        XCTAssertEqual(deps["x.baz"], .registry(identity: "x.baz", requirement: .range("1.1.1" ..< "2.0.0")))
        XCTAssertEqual(deps["x.qux"], .registry(identity: "x.qux", requirement: .range("1.1.1" ..< "1.2.0")))
        XCTAssertEqual(deps["x.quux"], .registry(identity: "x.quux", requirement: .range("1.1.1" ..< "3.0.0")))
    }

    func testConditionalTargetDependencies() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Foo",
                dependencies: [],
                targets: [
                    .target(name: "Foo", dependencies: [
                        .target(name: "Bar", condition: .when(platforms: [])),
                        .target(name: "Baz", condition: .when(platforms: [.linux])),
                    ]),
                    .target(name: "Bar"),
                    .target(name: "Baz"),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        let dependencies = manifest.targets[0].dependencies
        XCTAssertEqual(dependencies[0], .target(name: "Bar", condition: .none))
        XCTAssertEqual(dependencies[1], .target(name: "Baz", condition: .init(platformNames: ["linux"], config: .none)))
    }

    func testConditionalTargetDependenciesDeprecation() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Foo",
                dependencies: [],
                targets: [
                    .target(name: "Foo", dependencies: [
                        .target(name: "Bar", condition: .when(platforms: nil))
                    ]),
                    .target(name: "Bar")
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
            if case ManifestParseError.invalidManifestFormat(let error, _, _) = error {
                XCTAssertMatch(error, .contains("when(platforms:)' was obsoleted"))
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testTargetDeprecatedDependencyCase() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Foo",
                dependencies: [
                   .package(url: "http://localhost/BarPkg", from: "1.1.1"),
                ],
                targets: [
                    .target(name: "Foo",
                            dependencies: [
                                .productItem(name: "Bar", package: "BarPkg", condition: nil),
                            ]),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope)) { error in
            if case ManifestParseError.invalidManifestFormat(let message, _, _) = error {
                XCTAssertMatch(message, .contains("error: 'productItem(name:package:condition:)' is unavailable: use .product(name:package:condition) instead."))
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testPlatforms() async throws {
        let content =  """
            import PackageDescription
            let package = Package(
               name: "Foo",
               platforms: [
                   .macOS(.v13), .iOS(.v16),
                   .tvOS(.v16), .watchOS(.v9),
                   .macCatalyst(.v16), .driverKit(.v22),
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.platforms, [
            PlatformDescription(name: "macos", version: "13.0"),
            PlatformDescription(name: "ios", version: "16.0"),
            PlatformDescription(name: "tvos", version: "16.0"),
            PlatformDescription(name: "watchos", version: "9.0"),
            PlatformDescription(name: "maccatalyst", version: "16.0"),
            PlatformDescription(name: "driverkit", version: "22.0"),
        ])
    }

    func testImportRestrictions() async throws {
        let content =  """
            import PackageDescription
            import BestModule
            let package = Package(name: "Foo")
            """

        let observability = ObservabilitySystem.makeForTesting()
        let manifestLoader = ManifestLoader(toolchain: try UserToolchain.default, importRestrictions: (.v5_7, []))
        await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, customManifestLoader: manifestLoader, observabilityScope: observability.topScope)) { error in
            if case ManifestParseError.importsRestrictedModules(let modules) = error {
                XCTAssertEqual(modules.sorted(), ["BestModule", "Foundation"])
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testTargetDependencyProductInvalidPackage() async throws {
        do {
            let content = """
                import PackageDescription
                let package = Package(
                    name: "Trivial",
                    products: [],
                    dependencies: [
                        .package(id: "org.foo", from: "1.0.0"),
                        .package(id: "org.bar", from: "1.0.0"),
                    ],
                    targets: [
                        .target(
                            name: "Target1",
                            dependencies: [.product(name: "product", package: "org.baz")]),
                        .target(
                            name: "Target2",
                            dependencies: ["foos"]),
                    ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            let (_, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            testDiagnostics(validationDiagnostics) { result in
                result.checkUnordered(diagnostic: "unknown package 'org.baz' in dependencies of target 'Target1'; valid packages are: 'org.foo', 'org.bar'", severity: .error)
                result.checkUnordered(diagnostic: "unknown dependency 'foos' in target 'Target2'; valid dependencies are: 'org.foo', 'org.bar'", severity: .error)
            }
        }
    }
}
