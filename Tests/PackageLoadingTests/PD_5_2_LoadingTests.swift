//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageLoading
import PackageModel
import SPMTestSupport
import XCTest

final class PackageDescription5_2LoadingTests: PackageDescriptionLoadingTests {
    override var toolsVersion: ToolsVersion {
        .v5_2
    }

    func testMissingTargetProductDependencyPackage() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Trivial",
                products: [],
                dependencies: [
                    .package(url: "/foo1", from: "1.0.0"),
                ],
                targets: [
                    .target(
                        name: "foo",
                        dependencies: [.product(name: "product")]),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
            if case ManifestParseError.invalidManifestFormat(let error, _, _) = error {
                XCTAssert(error.contains("error: \'product(name:package:)\' is unavailable: the 'package' argument is mandatory as of tools version 5.2"))
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testDependencyNameForTargetDependencyResolution() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Trivial",
                products: [],
                dependencies: [
                    .package(name: "Foo", url: "/foo1", from: "1.0.0"),
                    .package(name: "Foo2", path: "/foo2"),
                    .package(name: "Foo3", url: "/foo3", .upToNextMajor(from: "1.0.0")),
                    .package(name: "Foo4", url: "/foo4", "1.0.0"..<"2.0.0"),
                    .package(name: "Foo5", url: "/foo5", "1.0.0"..."2.0.0"),
                    .package(url: "/bar", from: "1.0.0"),
                    .package(url: "https://github.com/foo/Bar2.git/", from: "1.0.0"),
                    .package(url: "https://github.com/foo/Baz.git", from: "1.0.0"),
                    .package(url: "https://github.com/apple/swift", from: "1.0.0"),
                ],
                targets: [
                    .target(
                        name: "foo",
                        dependencies: [
                          .product(name: "product", package: "Foo"),
                          .product(name: "product", package: "Foo2"),
                          .product(name: "product", package: "Foo3"),
                          .product(name: "product", package: "Foo4"),
                          .product(name: "product", package: "Foo5"),
                          .product(name: "product", package: "bar"),
                          .product(name: "product", package: "bar2"),
                          .product(name: "product", package: "baz"),
                          .product(name: "product", package: "swift")
                        ]
                    ),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.displayName, "Trivial")
        XCTAssertEqual(manifest.dependencies[0].nameForTargetDependencyResolutionOnly, "Foo")
        XCTAssertEqual(manifest.dependencies[1].nameForTargetDependencyResolutionOnly, "Foo2")
        XCTAssertEqual(manifest.dependencies[2].nameForTargetDependencyResolutionOnly, "Foo3")
        XCTAssertEqual(manifest.dependencies[3].nameForTargetDependencyResolutionOnly, "Foo4")
        XCTAssertEqual(manifest.dependencies[4].nameForTargetDependencyResolutionOnly, "Foo5")
        XCTAssertEqual(manifest.dependencies[5].nameForTargetDependencyResolutionOnly, "bar")
        XCTAssertEqual(manifest.dependencies[6].nameForTargetDependencyResolutionOnly, "Bar2")
        XCTAssertEqual(manifest.dependencies[7].nameForTargetDependencyResolutionOnly, "Baz")
        XCTAssertEqual(manifest.dependencies[8].nameForTargetDependencyResolutionOnly, "swift")
    }

    func testTargetDependencyProductInvalidPackage() async throws {
        do {
            let content = """
                import PackageDescription
                let package = Package(
                    name: "Trivial",
                    products: [],
                    dependencies: [
                        .package(url: "http://scm.com/org/foo", from: "1.0.0"),
                        .package(url: "http://scm.com/org/bar", from: "2.0.0"),
                    ],
                    targets: [
                        .target(
                            name: "Target1",
                            dependencies: [.product(name: "product", package: "foo1")]),
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
                result.checkUnordered(diagnostic: "unknown package 'foo1' in dependencies of target 'Target1'; valid packages are: 'foo' (from 'http://scm.com/org/foo'), 'bar' (from 'http://scm.com/org/bar')", severity: .error)
                result.checkUnordered(diagnostic: "unknown dependency 'foos' in target 'Target2'; valid dependencies are: 'foo' (from 'http://scm.com/org/foo'), 'bar' (from 'http://scm.com/org/bar')", severity: .error)
            }
        }

        do {
            let content = """
                import PackageDescription
                let package = Package(
                    name: "Trivial",
                    products: [],
                    dependencies: [
                        .package(name: "Foo", url: "http://scm.com/org/foo", from: "1.0.0"),
                        .package(name: "Bar", url: "http://scm.com/org/bar", from: "2.0.0"),
                    ],
                    targets: [
                        .target(
                            name: "Target1",
                            dependencies: [.product(name: "product", package: "foo1")]),
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
                result.checkUnordered(diagnostic: "unknown package 'foo1' in dependencies of target 'Target1'; valid packages are: 'Foo' (from 'http://scm.com/org/foo'), 'Bar' (from 'http://scm.com/org/bar')", severity: .error)
                result.checkUnordered(diagnostic: "unknown dependency 'foos' in target 'Target2'; valid dependencies are: 'Foo' (from 'http://scm.com/org/foo'), 'Bar' (from 'http://scm.com/org/bar')", severity: .error)
            }
        }

        // packageKind == root has special rules in this case

        do {
            let content = """
                import PackageDescription
                let package = Package(
                    name: "Trivial",
                    products: [],
                    dependencies: [
                        .package(name: "Foo", url: "http://scm.com/org/foo1", from: "1.0.0"),
                    ],
                    targets: [
                        .target(
                            name: "Target1",
                            dependencies: [.product(name: "product", package: "foo1")]),
                        .target(
                            name: "Target2",
                            dependencies: ["foos"]),
                    ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            let (_, validationDiagnostics) = try await loadAndValidateManifest(content, packageKind: .root(.root), observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            testDiagnostics(validationDiagnostics) { result in
                result.check(diagnostic: "unknown package 'foo1' in dependencies of target 'Target1'; valid packages are: 'Foo' (from 'http://scm.com/org/foo1')", severity: .error)
            }
        }


        do {
            let content = """
                import PackageDescription
                let package = Package(
                    name: "Trivial",
                    products: [],
                    dependencies: [
                        .package(path: "/foo"),
                        .package(path: "/bar"),
                    ],
                    targets: [
                        .target(
                            name: "Target1",
                            dependencies: [.product(name: "product", package: "foo1")]),
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
                let fooPkg: AbsolutePath = "/foo"
                let barPkg: AbsolutePath = "/bar"
                result.checkUnordered(diagnostic: "unknown package 'foo1' in dependencies of target 'Target1'; valid packages are: 'foo' (at '\(fooPkg)'), 'bar' (at '\(barPkg)')", severity: .error)
                result.checkUnordered(diagnostic: "unknown dependency 'foos' in target 'Target2'; valid dependencies are: 'foo' (at '\(fooPkg)'), 'bar' (at '\(barPkg)')", severity: .error)
            }
        }

        do {
            let content = """
                import PackageDescription
                let package = Package(
                    name: "Trivial",
                    products: [],
                    dependencies: [
                        .package(name: "Foo", path: "/foo1"),
                        .package(name: "Bar", path: "/bar1"),
                    ],
                    targets: [
                        .target(
                            name: "Target1",
                            dependencies: [.product(name: "product", package: "foo1")]),
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
                let foo1Pkg: AbsolutePath = "/foo1"
                let bar1Pkg: AbsolutePath = "/bar1"
                result.checkUnordered(diagnostic: "unknown package 'foo1' in dependencies of target 'Target1'; valid packages are: 'Foo' (at '\(foo1Pkg)'), 'Bar' (at '\(bar1Pkg)')", severity: .error)
                result.checkUnordered(diagnostic: "unknown dependency 'foos' in target 'Target2'; valid dependencies are: 'Foo' (at '\(foo1Pkg)'), 'Bar' (at '\(bar1Pkg)')", severity: .error)
            }
        }
    }

    func testTargetDependencyReference() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Trivial",
                products: [],
                dependencies: [
                    .package(name: "Foobar", url: "/foobar", from: "1.0.0"),
                    .package(name: "Barfoo", url: "/barfoo", from: "1.0.0"),
                ],
                targets: [
                    .target(
                        name: "foo",
                        dependencies: [.product(name: "Something", package: "Foobar"), "Barfoo"]),
                    .target(
                        name: "bar",
                        dependencies: ["foo"]),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        let dependencies = Dictionary(uniqueKeysWithValues: manifest.dependencies.map{ ($0.nameForTargetDependencyResolutionOnly, $0) })
        let dependencyFoobar = dependencies["Foobar"]!
        let dependencyBarfoo = dependencies["Barfoo"]!
        let targetFoo = manifest.targetMap["foo"]!
        let targetBar = manifest.targetMap["bar"]!
        XCTAssertEqual(manifest.packageDependency(referencedBy: targetFoo.dependencies[0]), dependencyFoobar)
        XCTAssertEqual(manifest.packageDependency(referencedBy: targetFoo.dependencies[1]), dependencyBarfoo)
        XCTAssertEqual(manifest.packageDependency(referencedBy: targetBar.dependencies[0]), nil)
    }

    func testResourcesUnavailable() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "Foo",
               targets: [
                   .target(
                       name: "Foo",
                       resources: [
                           .copy("foo.txt"),
                           .process("bar.txt"),
                       ]
                   ),
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
            if case ManifestParseError.invalidManifestFormat(let error, _, _) = error {
                XCTAssertMatch(error, .contains("is unavailable"))
                XCTAssertMatch(error, .contains("was introduced in PackageDescription 5.3"))
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testBinaryTargetUnavailable() async throws {
        do {
            let content = """
                import PackageDescription
                let package = Package(
                    name: "Foo",
                    products: [],
                    targets: [
                        .binaryTarget(
                            name: "Foo",
                            path: "../Foo.xcframework"),
                    ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.invalidManifestFormat(let error, _, _) = error {
                    XCTAssertMatch(error, .contains("is unavailable"))
                    XCTAssertMatch(error, .contains("was introduced in PackageDescription 5.3"))
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
        }

        do {
            let content = """
                import PackageDescription
                let package = Package(
                    name: "Foo",
                    products: [],
                    targets: [
                        .binaryTarget(
                            name: "Foo",
                            url: "https://foo.com/foo.zip",
                            checksum: "21321441231232"),
                    ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.invalidManifestFormat(let error, _, _) = error {
                    XCTAssertMatch(error, .contains("is unavailable"))
                    XCTAssertMatch(error, .contains("was introduced in PackageDescription 5.3"))
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testConditionalTargetDependenciesUnavailable() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Foo",
                dependencies: [
                    .package(path: "/Baz"),
                ],
                targets: [
                    .target(name: "Foo", dependencies: [
                        .target(name: "Biz"),
                        .target(name: "Bar", condition: .when(platforms: [.linux])),
                    ]),
                    .target(name: "Bar"),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
            if case ManifestParseError.invalidManifestFormat(let error, _, _) = error {
                XCTAssertMatch(error, .contains("is unavailable"))
                XCTAssertMatch(error, .contains("was introduced in PackageDescription 5.3"))
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testDefaultLocalizationUnavailable() async throws {
        do {
            let content = """
                import PackageDescription
                let package = Package(
                    name: "Foo",
                    defaultLocalization: "fr",
                    products: [],
                    targets: [
                        .target(name: "Foo"),
                    ],
                    swiftLanguageVersions: [.v5]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.invalidManifestFormat(let error, _, _) = error {
                    XCTAssertMatch(error, .contains("is unavailable"))
                    XCTAssertMatch(error, .contains("was introduced in PackageDescription 5.3"))
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testManifestLoadingIsSandboxed() async throws {
        #if !os(macOS)
        // Sandboxing is only done on macOS today.
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        let content = """
            import Foundation

            try! String(contentsOf: URL(string: "http://127.0.0.1")!)

            import PackageDescription
            let package = Package(
                name: "Foo",
                targets: [
                    .target(name: "Foo"),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
            if case ManifestParseError.invalidManifestFormat(let error, _, _) = error {
                XCTAssertTrue(error.contains("Operation not permitted"), "unexpected error message: \(error)")
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }
}
