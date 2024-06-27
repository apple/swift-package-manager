//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2017-2020 Apple Inc. and the Swift project authors
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

import class TSCBasic.InMemoryFileSystem

final class PackageDescription4_0LoadingTests: PackageDescriptionLoadingTests {
    override var toolsVersion: ToolsVersion {
        .v4
    }

    func testTrivial() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Trivial"
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.displayName, "Trivial")
        XCTAssertEqual(manifest.toolsVersion, .v4)
        XCTAssertEqual(manifest.targets, [])
        XCTAssertEqual(manifest.dependencies, [])
    }

    func testTargetDependencies() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Trivial",
                targets: [
                    .target(name: "foo", dependencies: [
                        "dep1",
                        .target(name: "dep2"),
                        .product(name: "dep3", package: "Pkg"),
                        .product(name: "dep4"),
                    ]),
                    .testTarget(name: "bar", dependencies: [
                        "foo",
                    ])
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.displayName, "Trivial")
        let foo = manifest.targetMap["foo"]!
        XCTAssertEqual(foo.name, "foo")
        XCTAssertFalse(foo.isTest)

        let expectedDependencies: [TargetDescription.Dependency]
        expectedDependencies = [
            "dep1",
            .target(name: "dep2"),
            .product(name: "dep3", package: "Pkg"),
            .product(name: "dep4"),
        ]
        XCTAssertEqual(foo.dependencies, expectedDependencies)

        let bar = manifest.targetMap["bar"]!
        XCTAssertEqual(bar.name, "bar")
        XCTAssertTrue(bar.isTest)
        XCTAssertEqual(bar.dependencies, ["foo"])
    }

    func testCompatibleSwiftVersions() async throws {
        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   swiftLanguageVersions: [3, 4]
                )
                """
            let observability = ObservabilitySystem.makeForTesting()
            let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssertNoDiagnostics(validationDiagnostics)
            XCTAssertEqual(manifest.swiftLanguageVersions?.map({$0.rawValue}), ["3", "4"])
        }

        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   swiftLanguageVersions: []
                )
                """
            let observability = ObservabilitySystem.makeForTesting()
            let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssertNoDiagnostics(validationDiagnostics)
            XCTAssertEqual(manifest.swiftLanguageVersions, [])
        }

        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo")
                """
            let observability = ObservabilitySystem.makeForTesting()
            let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssertNoDiagnostics(validationDiagnostics)
            XCTAssertEqual(manifest.swiftLanguageVersions, nil)
        }
    }

    func testPackageDependencies() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "Foo",
               dependencies: [
                   .package(url: "\(AbsolutePath("/foo1").escapedPathString)", from: "1.0.0"),
                   .package(url: "\(AbsolutePath("/foo2").escapedPathString)", .upToNextMajor(from: "1.0.0")),
                   .package(url: "\(AbsolutePath("/foo3").escapedPathString)", .upToNextMinor(from: "1.0.0")),
                   .package(url: "\(AbsolutePath("/foo4").escapedPathString)", .exact("1.0.0")),
                   .package(url: "\(AbsolutePath("/foo5").escapedPathString)", .branch("main")),
                   .package(url: "\(AbsolutePath("/foo6").escapedPathString)", .revision("58e9de4e7b79e67c72a46e164158e3542e570ab6")),
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        let deps = Dictionary(uniqueKeysWithValues: manifest.dependencies.map{ ($0.identity.description, $0) })
        XCTAssertEqual(deps["foo1"], .localSourceControl(path: "/foo1", requirement: .upToNextMajor(from: "1.0.0")))
        XCTAssertEqual(deps["foo2"], .localSourceControl(path: "/foo2", requirement: .upToNextMajor(from: "1.0.0")))
        XCTAssertEqual(deps["foo3"], .localSourceControl(path: "/foo3", requirement: .upToNextMinor(from: "1.0.0")))
        XCTAssertEqual(deps["foo4"], .localSourceControl(path: "/foo4", requirement: .exact("1.0.0")))
        XCTAssertEqual(deps["foo5"], .localSourceControl(path: "/foo5", requirement: .branch("main")))
        XCTAssertEqual(deps["foo6"], .localSourceControl(path: "/foo6", requirement: .revision("58e9de4e7b79e67c72a46e164158e3542e570ab6")))
    }

    func testProducts() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Foo",
                products: [
                    .executable(name: "tool", targets: ["tool"]),
                    .library(name: "Foo", targets: ["Foo"]),
                    .library(name: "FooDy", type: .dynamic, targets: ["Foo"]),
                ],
                targets: [
                    .target(name: "Foo"),
                    .target(name: "tool"),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        let products = Dictionary(uniqueKeysWithValues: manifest.products.map{ ($0.name, $0) })
        // Check tool.
        let tool = products["tool"]!
        XCTAssertEqual(tool.name, "tool")
        XCTAssertEqual(tool.targets, ["tool"])
        XCTAssertEqual(tool.type, .executable)
        // Check Foo.
        let foo = products["Foo"]!
        XCTAssertEqual(foo.name, "Foo")
        XCTAssertEqual(foo.type, .library(.automatic))
        XCTAssertEqual(foo.targets, ["Foo"])
        // Check FooDy.
        let fooDy = products["FooDy"]!
        XCTAssertEqual(fooDy.name, "FooDy")
        XCTAssertEqual(fooDy.type, .library(.dynamic))
        XCTAssertEqual(fooDy.targets, ["Foo"])
    }

    func testSystemPackage() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "Copenssl",
               pkgConfig: "openssl",
               providers: [
                   .brew(["openssl"]),
                   .apt(["openssl", "libssl-dev"]),
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.displayName, "Copenssl")
        XCTAssertEqual(manifest.pkgConfig, "openssl")
        XCTAssertEqual(manifest.providers, [
            .brew(["openssl"]),
            .apt(["openssl", "libssl-dev"]),
        ])
    }

    func testCTarget() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "libyaml",
               targets: [
                   .target(
                       name: "Foo",
                       publicHeadersPath: "inc"),
                   .target(
                   name: "Bar"),
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        let foo = manifest.targetMap["Foo"]!
        XCTAssertEqual(foo.publicHeadersPath, "inc")

        let bar = manifest.targetMap["Bar"]!
        XCTAssertEqual(bar.publicHeadersPath, nil)
    }

    func testTargetProperties() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "libyaml",
               targets: [
                   .target(
                       name: "Foo",
                       path: "foo/z",
                       exclude: ["bar"],
                       sources: ["bar.swift"],
                       publicHeadersPath: "inc"),
                   .target(
                   name: "Bar"),
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        let foo = manifest.targetMap["Foo"]!
        XCTAssertEqual(foo.publicHeadersPath, "inc")
        XCTAssertEqual(foo.path, "foo/z")
        XCTAssertEqual(foo.exclude, ["bar"])
        XCTAssertEqual(foo.sources ?? [], ["bar.swift"])

        let bar = manifest.targetMap["Bar"]!
        XCTAssertEqual(bar.publicHeadersPath, nil)
        XCTAssertEqual(bar.path, nil)
        XCTAssertEqual(bar.exclude, [])
        XCTAssert(bar.sources == nil)
    }

    func testUnavailableAPIs() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "Foo",
               dependencies: [
                   .package(url: "/foo1", version: "1.0.0"),
                   .package(url: "/foo2", branch: "master"),
                   .package(url: "/foo3", revision: "rev"),
                   .package(url: "/foo4", range: "1.0.0"..<"1.5.0"),
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
            if case ManifestParseError.invalidManifestFormat(let error, _, _) = error {
                XCTAssert(error.contains("error: 'package(url:version:)' is unavailable: use package(url:exact:) instead"), "\(error)")
                XCTAssert(error.contains("error: 'package(url:range:)' is unavailable: use package(url:_:) instead"), "\(error)")
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testLanguageStandards() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "testPackage",
                targets: [
                    .target(name: "Foo"),
                ],
                cLanguageStandard: .iso9899_199409,
                cxxLanguageStandard: .gnucxx14
            )
        """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.displayName, "testPackage")
        XCTAssertEqual(manifest.cLanguageStandard, "iso9899:199409")
        XCTAssertEqual(manifest.cxxLanguageStandard, "gnu++14")
    }

    func testManifestWithWarnings() async throws {
        let fs = InMemoryFileSystem()
        let manifestPath = AbsolutePath.root.appending(component: Manifest.filename)

        let content = """
            import PackageDescription
            func foo() {
                let a = 5
            }
            let package = Package(
                name: "Trivial"
            )
            """

        try fs.writeFileContents(manifestPath, string: content)

        let observability = ObservabilitySystem.makeForTesting()
        let manifest = try await manifestLoader.load(
            manifestPath: manifestPath,
            packageKind: .root(.root),
            toolsVersion: .v4,
            fileSystem: fs,
            observabilityScope: observability.topScope
        )

        XCTAssertEqual(manifest.displayName, "Trivial")
        XCTAssertEqual(manifest.toolsVersion, .v4)
        XCTAssertEqual(manifest.targets, [])
        XCTAssertEqual(manifest.dependencies, [])

        testDiagnostics(observability.diagnostics) { result in
            result.check(diagnostic: .contains("initialization of immutable value 'a' was never used"), severity: .warning)
        }
    }

    func testDuplicateTargets() async throws {
        let content = """
            import PackageDescription

            let package = Package(
                name: "Foo",
                targets: [
                    .target(name: "A"),
                    .target(name: "B"),
                    .target(name: "A"),
                    .target(name: "B"),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (_, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        testDiagnostics(validationDiagnostics) { result in
            result.checkUnordered(diagnostic: "duplicate target named 'A'", severity: .error)
            result.checkUnordered(diagnostic: "duplicate target named 'B'", severity: .error)
        }
    }

    func testEmptyProductTargets() async throws {
        let content = """
            import PackageDescription

            let package = Package(
                name: "Foo",
                products: [
                    .library(name: "Product", targets: []),
                ],
                targets: [
                    .target(name: "Target"),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (_, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        testDiagnostics(validationDiagnostics) { result in
            result.check(diagnostic: "product 'Product' doesn't reference any targets", severity: .error)
        }
    }

    func testProductTargetNotFound() async throws {
        let content = """
            import PackageDescription

            let package = Package(
                name: "Foo",
                products: [
                    .library(name: "Product", targets: ["A", "B"]),
                ],
                targets: [
                    .target(name: "A"),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (_, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        testDiagnostics(validationDiagnostics) { result in
            result.check(diagnostic: "target 'B' referenced in product 'Product' could not be found; valid targets are: 'A'", severity: .error)
        }
    }
}
