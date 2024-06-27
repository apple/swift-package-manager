//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2017 Apple Inc. and the Swift project authors
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

import struct TSCBasic.ByteString

final class PackageDescription5_0LoadingTests: PackageDescriptionLoadingTests {
    override var toolsVersion: ToolsVersion {
        .v5
    }

    func testBasics() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Trivial",
                products: [
                    .executable(name: "tool", targets: ["tool"]),
                    .library(name: "Foo", targets: ["foo"]),
                ],
                dependencies: [
                    .package(url: "/foo1", from: "1.0.0"),
                ],
                targets: [
                    .target(
                        name: "foo",
                        dependencies: ["dep1", .product(name: "product"), .target(name: "target")]),
                    .target(
                        name: "tool"),
                    .testTarget(
                        name: "bar",
                        dependencies: ["foo"]),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.displayName, "Trivial")

        // Check targets.
        let foo = manifest.targetMap["foo"]!
        XCTAssertEqual(foo.name, "foo")
        XCTAssertFalse(foo.isTest)
        XCTAssertEqual(foo.dependencies, ["dep1", .product(name: "product"), .target(name: "target")])

        let bar = manifest.targetMap["bar"]!
        XCTAssertEqual(bar.name, "bar")
        XCTAssertTrue(bar.isTest)
        XCTAssertEqual(bar.dependencies, ["foo"])

        // Check dependencies.
        let deps = Dictionary(uniqueKeysWithValues: manifest.dependencies.map{ ($0.identity.description, $0) })
        XCTAssertEqual(deps["foo1"], .localSourceControl(path: "/foo1", requirement: .upToNextMajor(from: "1.0.0")))

        // Check products.
        let products = Dictionary(uniqueKeysWithValues: manifest.products.map{ ($0.name, $0) })

        let tool = products["tool"]!
        XCTAssertEqual(tool.name, "tool")
        XCTAssertEqual(tool.targets, ["tool"])
        XCTAssertEqual(tool.type, .executable)

        let fooProduct = products["Foo"]!
        XCTAssertEqual(fooProduct.name, "Foo")
        XCTAssertEqual(fooProduct.type, .library(.automatic))
        XCTAssertEqual(fooProduct.targets, ["foo"])
    }

    func testSwiftLanguageVersion() async throws {
        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   swiftLanguageVersions: [.v4, .v4_2, .v5]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssertNoDiagnostics(validationDiagnostics)

            XCTAssertEqual(manifest.swiftLanguageVersions, [.v4, .v4_2, .v5])
        }

        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   swiftLanguageVersions: [.v3]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.invalidManifestFormat(let message, _, _) = error {
                    XCTAssertMatch(message, .contains("'v3' is unavailable"))
                    XCTAssertMatch(message, .contains("'v3' was obsoleted in PackageDescription 5"))
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
                   swiftLanguageVersions: [.version("")]
                )
            """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.runtimeManifestErrors(let messages) = error {
                    XCTAssertEqual(messages, ["invalid Swift language version: "])
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testPlatformOptions() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "Foo",
               platforms: [
                   .macOS("10.13.option1.option2"), .iOS("12.2.option2"),
                   .tvOS("12.3.4.option5.option7.option9")
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.platforms, [
            PlatformDescription(name: "macos", version: "10.13", options: ["option1", "option2"]),
            PlatformDescription(name: "ios", version: "12.2", options: ["option2"]),
            PlatformDescription(name: "tvos", version: "12.3.4", options: ["option5", "option7", "option9"]),
        ])
    }

    func testPlatforms() async throws {
        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   platforms: [
                       .macOS(.v10_13), .iOS("12.2"),
                       .tvOS(.v12), .watchOS(.v3),
                   ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssertNoDiagnostics(validationDiagnostics)

            XCTAssertEqual(manifest.platforms, [
                PlatformDescription(name: "macos", version: "10.13"),
                PlatformDescription(name: "ios", version: "12.2"),
                PlatformDescription(name: "tvos", version: "12.0"),
                PlatformDescription(name: "watchos", version: "3.0"),
            ])
        }

        // Test invalid custom versions.
        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   platforms: [
                       .macOS("-11.2"), .iOS("12.x.2"), .tvOS("10..2"), .watchOS("1.0"),
                   ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.runtimeManifestErrors(let errors) = error {
                    XCTAssertEqual(errors, [
                        "invalid macOS version -11.2; -11 should be a positive integer",
                        "invalid iOS version 12.x.2; x should be a positive integer",
                        "invalid tvOS version 10..2; found an empty component",
                        "invalid watchOS version 1.0; the minimum major version should be 2",
                    ])
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
        }

        // Duplicates.
        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   platforms: [
                       .macOS(.v10_10), .macOS(.v10_12),
                   ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.runtimeManifestErrors(let errors) = error {
                    XCTAssertEqual(errors, ["found multiple declaration for the platform: macos"])
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
        }

        // Empty.
        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   platforms: []
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.runtimeManifestErrors(let errors) = error {
                    XCTAssertEqual(errors, ["supported platforms can't be empty"])
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
        }

        // Newer OS version.
        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   platforms: [
                       .macOS(.v11), .iOS(.v14),
                   ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.invalidManifestFormat(let message, _, _) = error {
                    XCTAssertMatch(message, .contains("error: 'v11' is unavailable"))
                    XCTAssertMatch(message, .contains("note: 'v11' was introduced in PackageDescription 5.3"))
                    XCTAssertMatch(message, .contains("note: 'v14' was introduced in PackageDescription 5.3"))
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
        }

        // Newer OS version alias (now marked as unavailable).
        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   platforms: [
                       .macOS(.v10_16), .iOS(.v14),
                   ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.invalidManifestFormat(let message, _, _) = error {
                    XCTAssertMatch(message, .contains("error: 'v10_16' has been renamed to 'v11'"))
                    XCTAssertMatch(message, .contains("note: 'v10_16' has been explicitly marked unavailable here"))
                    XCTAssertMatch(message, .contains("note: 'v14' was introduced in PackageDescription 5.3"))
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testBuildSettings() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "Foo",
               targets: [
                   .target(
                       name: "Foo",
                       cSettings: [
                           .headerSearchPath("path/to/foo"),
                           .define("C", .when(platforms: [.linux])),
                           .define("CC", to: "4", .when(platforms: [.linux], configuration: .release)),
                       ],
                       cxxSettings: [
                           .headerSearchPath("path/to/bar"),
                           .define("CXX"),
                       ],
                       swiftSettings: [
                           .define("SWIFT", .when(configuration: .release)),
                           .define("SWIFT_DEBUG", .when(platforms: [.watchOS], configuration: .debug)),
                       ],
                       linkerSettings: [
                           .linkedLibrary("libz"),
                           .linkedFramework("CoreData", .when(platforms: [.macOS, .tvOS])),
                       ]
                   ),
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        let settings = manifest.targets[0].settings

        XCTAssertEqual(settings[0], .init(tool: .c, kind: .headerSearchPath("path/to/foo")))
        XCTAssertEqual(settings[1], .init(tool: .c, kind: .define("C"), condition: .init(platformNames: ["linux"])))
        XCTAssertEqual(settings[2], .init(tool: .c, kind: .define("CC=4"), condition: .init(platformNames: ["linux"], config: "release")))

        XCTAssertEqual(settings[3], .init(tool: .cxx, kind: .headerSearchPath("path/to/bar")))
        XCTAssertEqual(settings[4], .init(tool: .cxx, kind: .define("CXX")))

        XCTAssertEqual(settings[5], .init(tool: .swift, kind: .define("SWIFT"), condition: .init(config: "release")))
        XCTAssertEqual(settings[6], .init(tool: .swift, kind: .define("SWIFT_DEBUG"), condition: .init(platformNames: ["watchos"], config: "debug")))

        XCTAssertEqual(settings[7], .init(tool: .linker, kind: .linkedLibrary("libz")))
        XCTAssertEqual(settings[8], .init(tool: .linker, kind: .linkedFramework("CoreData"), condition: .init(platformNames: ["macos", "tvos"])))
    }

    func testSerializedDiagnostics() async throws {
        try await testWithTemporaryDirectory { path in
            let fs = localFileSystem
            let manifestPath = path.appending(components: "pkg", "Package.swift")

            let loader = ManifestLoader(
                toolchain: try UserToolchain.default,
                serializedDiagnostics: true,
                cacheDir: path)

            do {
                let observability = ObservabilitySystem.makeForTesting()

                try fs.createDirectory(manifestPath.parentDirectory)
                try fs.writeFileContents(
                    manifestPath,
                    string: """
                    import PackageDescription
                    let package = Package(
                    name: "Trivial",
                        targets: [
                            .target(
                                name: "foo",
                                dependencies: []),

                    )
                    """
                )

                do {
                    _ = try await loader.load(
                        manifestPath: manifestPath,
                        packageKind: .fileSystem(manifestPath.parentDirectory),
                        toolsVersion: .v5,
                        fileSystem: fs,
                        observabilityScope: observability.topScope
                    )
                } catch ManifestParseError.invalidManifestFormat(let error, let diagnosticFile, _) {
                    XCTAssertMatch(error, .contains("expected expression in container literal"))
                    let contents = try localFileSystem.readFileContents(diagnosticFile!)
                    XCTAssertNotNil(contents)
                }
            }

            do {
                let observability = ObservabilitySystem.makeForTesting()

                try fs.writeFileContents(
                    manifestPath,
                    string: """
                    import PackageDescription
                    func foo() {
                        let a = 5
                    }
                    let package = Package(
                        name: "Trivial",
                        targets: [
                            .target(
                                name: "foo",
                                dependencies: []),
                        ]
                    )
                    """
                )

                _ = try await loader.load(
                    manifestPath: manifestPath,
                    packageKind: .fileSystem(manifestPath.parentDirectory),
                    toolsVersion: .v5,
                    fileSystem: fs,
                    observabilityScope: observability.topScope
                )

                testDiagnostics(observability.diagnostics) { result in
                    let diagnostic = result.check(diagnostic: .contains("initialization of immutable value"), severity: .warning)
                    let contents = try diagnostic?.metadata?.manifestLoadingDiagnosticFile.map { try localFileSystem.readFileContents($0) }
                    XCTAssertNotNil(contents)
                }
            }
        }
    }

    func testInvalidBuildSettings() async throws {
        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   targets: [
                       .target(
                           name: "Foo",
                           cSettings: [
                               .headerSearchPath("$(BYE)/path/to/foo/$(SRCROOT)/$(HELLO)"),
                           ]
                       ),
                   ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.runtimeManifestErrors(let errors) = error {
                    XCTAssertEqual(errors, ["the build setting 'headerSearchPath' contains invalid component(s): $(BYE) $(SRCROOT) $(HELLO)"])
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
                   targets: [
                       .target(
                           name: "Foo",
                           cSettings: []
                       ),
                   ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            _ = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
        }
    }

    func testWindowsPlatform() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "Foo",
               targets: [
                   .target(
                       name: "foo",
                       cSettings: [
                           .define("LLVM_ON_WIN32", .when(platforms: [.windows])),
                       ]
                   ),
               ]
            )
            """

        do {
            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.invalidManifestFormat(let message, _, _) = error {
                    XCTAssertMatch(message, .contains("is unavailable"))
                    XCTAssertMatch(message, .contains("was introduced in PackageDescription 5.2"))
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
        }

        do {
            let observability = ObservabilitySystem.makeForTesting()
            let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, toolsVersion: .v5_2, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssertNoDiagnostics(validationDiagnostics)

            XCTAssertEqual(manifest.displayName, "Foo")

            // Check targets.
            let foo = manifest.targetMap["foo"]!
            XCTAssertEqual(foo.name, "foo")
            XCTAssertFalse(foo.isTest)
            XCTAssertEqual(foo.dependencies, [])

            let settings = foo.settings
            XCTAssertEqual(settings[0], .init(tool: .c, kind: .define("LLVM_ON_WIN32"), condition: .init(platformNames: ["windows"])))
        }
    }

    func testPackageNameUnavailable() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Trivial",
                products: [],
                dependencies: [
                    .package(name: "Foo", url: "/foo1", from: "1.0.0"),
                ],
                targets: [
                    .target(
                        name: "foo",
                        dependencies: [.product(name: "product", package: "Foo")]),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
            if case ManifestParseError.invalidManifestFormat(let message, _, _) = error {
                XCTAssertMatch(message, .contains("is unavailable"))
                XCTAssertMatch(message, .contains("was introduced in PackageDescription 5.2"))
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testManifestWithPrintStatements() async throws {
        let content = """
            import PackageDescription
            print(String(repeating: "Hello manifest... ", count: 65536))
            let package = Package(
                name: "PackageWithChattyManifest"
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(validationDiagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.displayName, "PackageWithChattyManifest")
        XCTAssertEqual(manifest.toolsVersion, .v5)
        XCTAssertEqual(manifest.targets, [])
        XCTAssertEqual(manifest.dependencies, [])
    }

    func testManifestLoaderEnvironment() async throws {
        try await testWithTemporaryDirectory { path in
            let fs = localFileSystem

            let packagePath = path.appending("pkg")
            try fs.createDirectory(packagePath)
            let manifestPath = packagePath.appending("Package.swift")
            try fs.writeFileContents(
                manifestPath,
                string: """
                // swift-tools-version:5
                import PackageDescription

                let package = Package(
                    name: "Trivial",
                    targets: [
                        .target(
                            name: "foo",
                            dependencies: []),
                    ]
                )
                """
            )

            let moduleTraceFilePath = path.appending("swift-module-trace")
            var env = Environment.current
            env["SWIFT_LOADED_MODULE_TRACE_FILE"] = moduleTraceFilePath.pathString
            let toolchain = try UserToolchain(swiftSDK: SwiftSDK.default, environment: env)
            let manifestLoader = ManifestLoader(
                toolchain: toolchain,
                serializedDiagnostics: true,
                isManifestSandboxEnabled: false,
                cacheDir: nil)

            let observability = ObservabilitySystem.makeForTesting()
            let manifest = try await manifestLoader.load(
                manifestPath: manifestPath,
                packageKind: .fileSystem(manifestPath.parentDirectory),
                toolsVersion: .v5,
                fileSystem: fs,
                observabilityScope: observability.topScope
            )

            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssertEqual(manifest.displayName, "Trivial")

            let moduleTraceJSON: String = try localFileSystem.readFileContents(moduleTraceFilePath)
            XCTAssertMatch(moduleTraceJSON, .contains("PackageDescription"))
        }
    }
}
