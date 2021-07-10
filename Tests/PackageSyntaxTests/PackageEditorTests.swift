/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest
import TSCBasic
import TSCUtility
import SPMTestSupport
import SourceControl

import PackageSyntax

final class PackageEditorTests: XCTestCase {

    func testAddDependency5_2_to_5_4() throws {
        for version in ["5.2", "5.3", "5.4"] {
            let manifest = """
                // swift-tools-version:\(version)
                import PackageDescription

                let package = Package(
                    name: "exec",
                    dependencies: [
                        .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                    ],
                    targets: [
                        .target(
                            name: "foo",
                            dependencies: []),
                        .target(
                            name: "bar",
                            dependencies: []),
                        .testTarget(
                            name: "fooTests",
                            dependencies: ["foo", "bar"]),
                    ]
                )
                """

            let fs = InMemoryFileSystem(emptyFiles:
                "/pkg/Package.swift",
                "/pkg/Sources/foo/source.swift",
                "/pkg/Sources/bar/source.swift",
                "/pkg/Tests/fooTests/source.swift",
                "end")

            let manifestPath = AbsolutePath("/pkg/Package.swift")
            try fs.writeFileContents(manifestPath) { $0 <<< manifest }
            try fs.createDirectory(.init("/pkg/repositories"), recursive: false)
            try fs.createDirectory(.init("/pkg/repo"), recursive: false)


            let provider = InMemoryGitRepositoryProvider()
            let repo = InMemoryGitRepository(path: .init("/pkg/repo"), fs: fs)
            try repo.writeFileContents(.init("/Package.swift"), bytes: .init(encodingAsUTF8: """
            // swift-tools-version:5.2
            import PackageDescription

            let package = Package(name: "repo")
            """))
            try repo.commit()
            try repo.tag(name: "1.1.1")
            provider.add(specifier: .init(url: "http://www.githost.com/repo"), repository: repo)

            let context = try PackageEditorContext(
                manifestPath: AbsolutePath("/pkg/Package.swift"),
                repositoryManager: RepositoryManager(path: .init("/pkg/repositories"), provider: provider, fileSystem: fs),
                toolchain: Resources.default.toolchain,
                diagnosticsEngine: .init(),
                fs: fs
            )
            let editor = PackageEditor(context: context)

            try editor.addPackageDependency(url: "http://www.githost.com/repo.git", requirement: .exact("1.1.1"))

            let newManifest = try fs.readFileContents(manifestPath).cString
            XCTAssertEqual(newManifest, """
                // swift-tools-version:\(version)
                import PackageDescription

                let package = Package(
                    name: "exec",
                    dependencies: [
                        .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                        .package(name: "repo", url: "http://www.githost.com/repo.git", .exact("1.1.1")),
                    ],
                    targets: [
                        .target(
                            name: "foo",
                            dependencies: []),
                        .target(
                            name: "bar",
                            dependencies: []),
                        .testTarget(
                            name: "fooTests",
                            dependencies: ["foo", "bar"]),
                    ]
                )
                """)
        }
    }

    func testAddDependency5_5() throws {
        let manifest = """
                // swift-tools-version:5.5
                import PackageDescription

                let package = Package(
                    name: "exec",
                    dependencies: [
                        .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                    ],
                    targets: [
                        .target(
                            name: "foo",
                            dependencies: []),
                        .target(
                            name: "bar",
                            dependencies: []),
                        .testTarget(
                            name: "fooTests",
                            dependencies: ["foo", "bar"]),
                    ]
                )
                """

        let fs = InMemoryFileSystem(emptyFiles:
                                        "/pkg/Package.swift",
                                    "/pkg/Sources/foo/source.swift",
                                    "/pkg/Sources/bar/source.swift",
                                    "/pkg/Tests/fooTests/source.swift",
                                    "end")

        let manifestPath = AbsolutePath("/pkg/Package.swift")
        try fs.writeFileContents(manifestPath) { $0 <<< manifest }
        try fs.createDirectory(.init("/pkg/repositories"), recursive: false)
        try fs.createDirectory(.init("/pkg/repo"), recursive: false)


        let provider = InMemoryGitRepositoryProvider()
        let repo = InMemoryGitRepository(path: .init("/pkg/repo"), fs: fs)
        try repo.writeFileContents(.init("/Package.swift"), bytes: .init(encodingAsUTF8: """
            // swift-tools-version:5.2
            import PackageDescription

            let package = Package(name: "repo")
            """))
        try repo.commit()
        try repo.tag(name: "1.1.1")
        provider.add(specifier: .init(url: "http://www.githost.com/repo"), repository: repo)

        let context = try PackageEditorContext(
            manifestPath: AbsolutePath("/pkg/Package.swift"),
            repositoryManager: RepositoryManager(path: .init("/pkg/repositories"), provider: provider, fileSystem: fs),
            toolchain: Resources.default.toolchain,
            diagnosticsEngine: .init(),
            fs: fs
        )
        let editor = PackageEditor(context: context)

        try editor.addPackageDependency(url: "http://www.githost.com/repo.git", requirement: .exact("1.1.1"))

        let newManifest = try fs.readFileContents(manifestPath).cString
        XCTAssertEqual(newManifest, """
                // swift-tools-version:5.5
                import PackageDescription

                let package = Package(
                    name: "exec",
                    dependencies: [
                        .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                        .package(url: "http://www.githost.com/repo.git", .exact("1.1.1")),
                    ],
                    targets: [
                        .target(
                            name: "foo",
                            dependencies: []),
                        .target(
                            name: "bar",
                            dependencies: []),
                        .testTarget(
                            name: "fooTests",
                            dependencies: ["foo", "bar"]),
                    ]
                )
                """)
    }

    func testAddTarget5_2() throws {
        let manifest = """
                // swift-tools-version:5.2
                import PackageDescription

                let package = Package(
                    name: "exec",
                    dependencies: [
                        .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                    ],
                    targets: [
                        .target(
                            name: "foo",
                            dependencies: []),
                        .target(
                            name: "bar",
                            dependencies: []),
                        .testTarget(
                            name: "fooTests",
                            dependencies: ["foo", "bar"]),
                    ]
                )
                """

        let fs = InMemoryFileSystem(emptyFiles:
                                        "/pkg/Package.swift",
                                    "/pkg/Sources/foo/source.swift",
                                    "/pkg/Sources/bar/source.swift",
                                    "/pkg/Tests/fooTests/source.swift",
                                    "end")

        let manifestPath = AbsolutePath("/pkg/Package.swift")
        try fs.writeFileContents(manifestPath) { $0 <<< manifest }

        let diags = DiagnosticsEngine()
        let context = try PackageEditorContext(
            manifestPath: AbsolutePath("/pkg/Package.swift"),
            repositoryManager: RepositoryManager(path: .init("/pkg/repositories"), provider: InMemoryGitRepositoryProvider()),
            toolchain: Resources.default.toolchain,
            diagnosticsEngine: diags,
            fs: fs)
        let editor = PackageEditor(context: context)

        XCTAssertThrows(Diagnostics.fatalError) {
            try editor.addTarget(.library(name: "foo", includeTestTarget: true, dependencyNames: []),
                                 productPackageNameMapping: [:])
        }
        XCTAssertEqual(diags.diagnostics.map(\.message.text), ["a target named 'foo' already exists in 'exec'"])
        XCTAssertThrows(Diagnostics.fatalError) {
            try editor.addTarget(.library(name: "Error", includeTestTarget: true, dependencyNames: ["NotFound"]),
                                 productPackageNameMapping: [:])
        }
        XCTAssertEqual(diags.diagnostics.map(\.message.text), ["a target named 'foo' already exists in 'exec'",
                                                               "could not find a product or target named 'NotFound'"])

        try editor.addTarget(.library(name: "baz", includeTestTarget: true, dependencyNames: []),
                             productPackageNameMapping: [:])
        try editor.addTarget(.executable(name: "qux", dependencyNames: ["foo", "baz"]),
                             productPackageNameMapping: [:])
        try editor.addTarget(.test(name: "IntegrationTests", dependencyNames: ["OtherProduct", "goo"]),
                             productPackageNameMapping: ["goo": "goo", "OtherProduct": "goo"])

        let newManifest = try fs.readFileContents(manifestPath).cString
        XCTAssertEqual(newManifest, """
                // swift-tools-version:5.2
                import PackageDescription

                let package = Package(
                    name: "exec",
                    dependencies: [
                        .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                    ],
                    targets: [
                        .target(
                            name: "foo",
                            dependencies: []),
                        .target(
                            name: "bar",
                            dependencies: []),
                        .testTarget(
                            name: "fooTests",
                            dependencies: ["foo", "bar"]),
                        .target(
                            name: "baz",
                            dependencies: []
                        ),
                        .testTarget(
                            name: "bazTests",
                            dependencies: [
                                "baz",
                            ]
                        ),
                        .target(
                            name: "qux",
                            dependencies: [
                                "foo",
                                "baz",
                            ]
                        ),
                        .testTarget(
                            name: "IntegrationTests",
                            dependencies: [
                                .product(name: "OtherProduct", package: "goo"),
                                "goo",
                            ]
                        ),
                    ]
                )
                """)

        XCTAssertTrue(fs.exists(AbsolutePath("/pkg/Sources/baz/baz.swift")))
        XCTAssertTrue(fs.exists(AbsolutePath("/pkg/Tests/bazTests/bazTests.swift")))
        XCTAssertTrue(fs.exists(AbsolutePath("/pkg/Sources/qux/main.swift")))
        XCTAssertFalse(fs.exists(AbsolutePath("/pkg/Tests/quxTests")))
        XCTAssertTrue(fs.exists(AbsolutePath("/pkg/Tests/IntegrationTests/IntegrationTests.swift")))
    }


    func testAddTarget5_3() throws {
        let manifest = """
                // swift-tools-version:5.3
                import PackageDescription

                let package = Package(
                    name: "exec",
                    dependencies: [
                        .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                    ],
                    targets: [
                        .target(
                            name: "foo",
                            dependencies: []),
                        .target(
                            name: "bar",
                            dependencies: []),
                        .testTarget(
                            name: "fooTests",
                            dependencies: ["foo", "bar"]),
                    ]
                )
                """

        let fs = InMemoryFileSystem(emptyFiles:
                                        "/pkg/Package.swift",
                                    "/pkg/Sources/foo/source.swift",
                                    "/pkg/Sources/bar/source.swift",
                                    "/pkg/Tests/fooTests/source.swift",
                                    "end")

        let manifestPath = AbsolutePath("/pkg/Package.swift")
        try fs.writeFileContents(manifestPath) { $0 <<< manifest }

        let diags = DiagnosticsEngine()
        let context = try PackageEditorContext(
            manifestPath: AbsolutePath("/pkg/Package.swift"),
            repositoryManager: RepositoryManager(path: .init("/pkg/repositories"), provider: InMemoryGitRepositoryProvider()),
            toolchain: Resources.default.toolchain,
            diagnosticsEngine: diags,
            fs: fs)
        let editor = PackageEditor(context: context)

        XCTAssertThrows(Diagnostics.fatalError) {
            try editor.addTarget(.library(name: "foo", includeTestTarget: true, dependencyNames: []),
                                 productPackageNameMapping: [:])
        }
        XCTAssertEqual(diags.diagnostics.map(\.message.text), ["a target named 'foo' already exists in 'exec'"])
        XCTAssertThrows(Diagnostics.fatalError) {
            try editor.addTarget(.library(name: "Error", includeTestTarget: true, dependencyNames: ["NotFound"]),
                                 productPackageNameMapping: [:])
        }
        XCTAssertEqual(diags.diagnostics.map(\.message.text), ["a target named 'foo' already exists in 'exec'",
                                                               "could not find a product or target named 'NotFound'"])

        try editor.addTarget(.library(name: "baz", includeTestTarget: true, dependencyNames: []),
                             productPackageNameMapping: [:])
        try editor.addTarget(.executable(name: "qux", dependencyNames: ["foo", "baz"]),
                             productPackageNameMapping: [:])
        try editor.addTarget(.test(name: "IntegrationTests", dependencyNames: ["OtherProduct", "goo"]),
                             productPackageNameMapping: ["goo": "goo", "OtherProduct": "goo"])
        try editor.addTarget(.binary(name: "LocalBinary",
                                     urlOrPath: "/some/local/binary/target.xcframework",
                                     checksum: nil),
                             productPackageNameMapping: [:])
        try editor.addTarget(.binary(name: "RemoteBinary",
                                     urlOrPath: "https://mybinaries.com/RemoteBinary.zip",
                                     checksum: "totallylegitchecksum"),
                             productPackageNameMapping: [:])

        let newManifest = try fs.readFileContents(manifestPath).cString
        XCTAssertEqual(newManifest, """
                // swift-tools-version:5.3
                import PackageDescription

                let package = Package(
                    name: "exec",
                    dependencies: [
                        .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                    ],
                    targets: [
                        .target(
                            name: "foo",
                            dependencies: []),
                        .target(
                            name: "bar",
                            dependencies: []),
                        .testTarget(
                            name: "fooTests",
                            dependencies: ["foo", "bar"]),
                        .target(
                            name: "baz",
                            dependencies: []
                        ),
                        .testTarget(
                            name: "bazTests",
                            dependencies: [
                                "baz",
                            ]
                        ),
                        .target(
                            name: "qux",
                            dependencies: [
                                "foo",
                                "baz",
                            ]
                        ),
                        .testTarget(
                            name: "IntegrationTests",
                            dependencies: [
                                .product(name: "OtherProduct", package: "goo"),
                                "goo",
                            ]
                        ),
                        .binaryTarget(
                            name: "LocalBinary",
                            path: "/some/local/binary/target.xcframework"
                        ),
                        .binaryTarget(
                            name: "RemoteBinary",
                            url: "https://mybinaries.com/RemoteBinary.zip",
                            checksum: "totallylegitchecksum"
                        ),
                    ]
                )
                """)

        XCTAssertTrue(fs.exists(AbsolutePath("/pkg/Sources/baz/baz.swift")))
        XCTAssertTrue(fs.exists(AbsolutePath("/pkg/Tests/bazTests/bazTests.swift")))
        XCTAssertTrue(fs.exists(AbsolutePath("/pkg/Sources/qux/main.swift")))
        XCTAssertFalse(fs.exists(AbsolutePath("/pkg/Tests/quxTests")))
        XCTAssertTrue(fs.exists(AbsolutePath("/pkg/Tests/IntegrationTests/IntegrationTests.swift")))
    }

    func testAddTarget5_4_to_5_5() throws {
        for version in ["5.4", "5.5"] {
            let manifest = """
              // swift-tools-version:\(version)
              import PackageDescription

              let package = Package(
                  name: "exec",
                  dependencies: [
                      .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                  ],
                  targets: [
                      .target(
                          name: "foo",
                          dependencies: []),
                      .target(
                          name: "bar",
                          dependencies: []),
                      .testTarget(
                          name: "fooTests",
                          dependencies: ["foo", "bar"]),
                  ]
              )
              """

            let fs = InMemoryFileSystem(emptyFiles:
                                        "/pkg/Package.swift",
                                        "/pkg/Sources/foo/source.swift",
                                        "/pkg/Sources/bar/source.swift",
                                        "/pkg/Tests/fooTests/source.swift",
                                        "end")

            let manifestPath = AbsolutePath("/pkg/Package.swift")
            try fs.writeFileContents(manifestPath) { $0 <<< manifest }

            let diags = DiagnosticsEngine()
            let context = try PackageEditorContext(
                manifestPath: AbsolutePath("/pkg/Package.swift"),
                repositoryManager: RepositoryManager(path: .init("/pkg/repositories"), provider: InMemoryGitRepositoryProvider()),
                toolchain: Resources.default.toolchain,
                diagnosticsEngine: diags,
                fs: fs)
            let editor = PackageEditor(context: context)

            XCTAssertThrows(Diagnostics.fatalError) {
                try editor.addTarget(.library(name: "foo", includeTestTarget: true, dependencyNames: []),
                                     productPackageNameMapping: [:])
            }
            XCTAssertEqual(diags.diagnostics.map(\.message.text), ["a target named 'foo' already exists in 'exec'"])
            XCTAssertThrows(Diagnostics.fatalError) {
                try editor.addTarget(.library(name: "Error", includeTestTarget: true, dependencyNames: ["NotFound"]),
                                     productPackageNameMapping: [:])
            }
            XCTAssertEqual(diags.diagnostics.map(\.message.text), ["a target named 'foo' already exists in 'exec'",
                                                                   "could not find a product or target named 'NotFound'"])

            try editor.addTarget(.library(name: "baz", includeTestTarget: true, dependencyNames: []),
                                 productPackageNameMapping: [:])
            try editor.addTarget(.executable(name: "qux", dependencyNames: ["foo", "baz"]),
                                 productPackageNameMapping: [:])
            try editor.addTarget(.test(name: "IntegrationTests", dependencyNames: ["OtherProduct", "goo"]),
                                 productPackageNameMapping: ["goo": "goo", "OtherProduct": "goo"])
            try editor.addTarget(.binary(name: "LocalBinary",
                                         urlOrPath: "/some/local/binary/target.xcframework",
                                         checksum: nil),
                                 productPackageNameMapping: [:])
            try editor.addTarget(.binary(name: "RemoteBinary",
                                         urlOrPath: "https://mybinaries.com/RemoteBinary.zip",
                                         checksum: "totallylegitchecksum"),
                                 productPackageNameMapping: [:])

            let newManifest = try fs.readFileContents(manifestPath).cString
            XCTAssertEqual(newManifest, """
              // swift-tools-version:\(version)
              import PackageDescription

              let package = Package(
                  name: "exec",
                  dependencies: [
                      .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                  ],
                  targets: [
                      .target(
                          name: "foo",
                          dependencies: []),
                      .target(
                          name: "bar",
                          dependencies: []),
                      .testTarget(
                          name: "fooTests",
                          dependencies: ["foo", "bar"]),
                      .target(
                          name: "baz",
                          dependencies: []
                      ),
                      .testTarget(
                          name: "bazTests",
                          dependencies: [
                              "baz",
                          ]
                      ),
                      .executableTarget(
                          name: "qux",
                          dependencies: [
                              "foo",
                              "baz",
                          ]
                      ),
                      .testTarget(
                          name: "IntegrationTests",
                          dependencies: [
                              .product(name: "OtherProduct", package: "goo"),
                              "goo",
                          ]
                      ),
                      .binaryTarget(
                          name: "LocalBinary",
                          path: "/some/local/binary/target.xcframework"
                      ),
                      .binaryTarget(
                          name: "RemoteBinary",
                          url: "https://mybinaries.com/RemoteBinary.zip",
                          checksum: "totallylegitchecksum"
                      ),
                  ]
              )
              """)

            XCTAssertTrue(fs.exists(AbsolutePath("/pkg/Sources/baz/baz.swift")))
            XCTAssertTrue(fs.exists(AbsolutePath("/pkg/Tests/bazTests/bazTests.swift")))
            XCTAssertTrue(fs.exists(AbsolutePath("/pkg/Sources/qux/main.swift")))
            XCTAssertFalse(fs.exists(AbsolutePath("/pkg/Tests/quxTests")))
            XCTAssertTrue(fs.exists(AbsolutePath("/pkg/Tests/IntegrationTests/IntegrationTests.swift")))
        }
    }

    func testAddProduct5_2_to_5_5() throws {
        for version in ["5.2", "5.3", "5.4", "5.5"] {
            let manifest = """
                // swift-tools-version:\(version)
                import PackageDescription

                let package = Package(
                    name: "exec",
                    products: [
                        .executable(name: "abc", targets: ["foo"]),
                    ],
                    dependencies: [
                        .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                    ],
                    targets: [
                        .target(
                            name: "foo",
                            dependencies: []),
                        .target(
                            name: "bar",
                            dependencies: []),
                        .testTarget(
                            name: "fooTests",
                            dependencies: ["foo", "bar"]),
                    ]
                )
                """

            let fs = InMemoryFileSystem(emptyFiles:
                "/pkg/Package.swift",
                "/pkg/Sources/foo/source.swift",
                "/pkg/Sources/bar/source.swift",
                "/pkg/Tests/fooTests/source.swift",
                "end")

            let manifestPath = AbsolutePath("/pkg/Package.swift")
            try fs.writeFileContents(manifestPath) { $0 <<< manifest }

            let diags = DiagnosticsEngine()
            let context = try PackageEditorContext(
                manifestPath: AbsolutePath("/pkg/Package.swift"),
                repositoryManager: RepositoryManager(path: .init("/pkg/repositories"), provider: InMemoryGitRepositoryProvider()),
                toolchain: Resources.default.toolchain,
                diagnosticsEngine: diags,
                fs: fs)
            let editor = PackageEditor(context: context)

            XCTAssertThrows(Diagnostics.fatalError) {
                try editor.addProduct(name: "abc", type: .library(.automatic), targets: [])
            }

            XCTAssertThrows(Diagnostics.fatalError) {
                try editor.addProduct(name: "SomeProduct", type: .library(.automatic), targets: ["nonexistent"])
            }

            XCTAssertEqual(diags.diagnostics.map(\.message.text), ["a product named 'abc' already exists in 'exec'",
                                                                   "no target named 'nonexistent' in 'exec'"])

            try editor.addProduct(name: "xyz", type: .executable, targets: ["bar"])
            try editor.addProduct(name: "libxyz", type: .library(.dynamic), targets: ["foo", "bar"])

            let newManifest = try fs.readFileContents(manifestPath).cString
            XCTAssertEqual(newManifest, """
                // swift-tools-version:\(version)
                import PackageDescription

                let package = Package(
                    name: "exec",
                    products: [
                        .executable(name: "abc", targets: ["foo"]),
                        .executable(
                            name: "xyz",
                            targets: [
                                "bar",
                            ]
                        ),
                        .library(
                            name: "libxyz",
                            type: .dynamic,
                            targets: [
                                "foo",
                                "bar",
                            ]
                        ),
                    ],
                    dependencies: [
                        .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                    ],
                    targets: [
                        .target(
                            name: "foo",
                            dependencies: []),
                        .target(
                            name: "bar",
                            dependencies: []),
                        .testTarget(
                            name: "fooTests",
                            dependencies: ["foo", "bar"]),
                    ]
                )
                """)
        }
    }

    func testToolsVersionTest() throws {
        let manifest = """
            // swift-tools-version:5.0
            import PackageDescription

            let package = Package(
                name: "exec",
                dependencies: [
                    .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                ],
                targets: [
                    .target(
                        name: "foo",
                        dependencies: []),
                ]
            )
            """

        let fs = InMemoryFileSystem(emptyFiles:
            "/pkg/Package.swift",
            "/pkg/Sources/foo/source.swift",
            "end")

        let manifestPath = AbsolutePath("/pkg/Package.swift")
        try fs.writeFileContents(manifestPath) { $0 <<< manifest }

        let diags = DiagnosticsEngine()
        let context = try PackageEditorContext(
            manifestPath: AbsolutePath("/pkg/Package.swift"),
            repositoryManager: RepositoryManager(path: .init("/pkg/repositories"), provider: InMemoryGitRepositoryProvider()),
            toolchain: Resources.default.toolchain, diagnosticsEngine: diags, fs: fs)
        let editor = PackageEditor(context: context)

        XCTAssertThrows(Diagnostics.fatalError) {
            try editor.addTarget(.library(name: "bar", includeTestTarget: true, dependencyNames: []),
                                 productPackageNameMapping: [:])
        }
        XCTAssertEqual(diags.diagnostics.map(\.message.text),
                       ["command line editing of manifests is only supported for packages with a swift-tools-version of 5.2 and later"])
    }

    func testEditingManifestsWithComplexArgumentExpressions() throws {
        let manifest = """
            // swift-tools-version:5.3
            import PackageDescription

            let flag = false
            let extraDeps: [Package.Dependency] = []

            let package = Package(
                name: "exec",
                products: [
                    .library(name: "Library", targets: ["foo"])
                ].filter { _ in true },
                dependencies: extraDeps + [
                    .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                ],
                targets: flag ? [] : [
                    .target(
                        name: "foo",
                        dependencies: []),
                ]
            )
            """

        let fs = InMemoryFileSystem(emptyFiles:
            "/pkg/Package.swift",
            "/pkg/Sources/foo/source.swift",
            "end")

        let manifestPath = AbsolutePath("/pkg/Package.swift")
        try fs.writeFileContents(manifestPath) { $0 <<< manifest }

        try fs.createDirectory(.init("/pkg/repositories"), recursive: false)
        try fs.createDirectory(.init("/pkg/repo"), recursive: false)


        let provider = InMemoryGitRepositoryProvider()
        let repo = InMemoryGitRepository(path: .init("/pkg/repo"), fs: fs)
        try repo.writeFileContents(.init("/Package.swift"), bytes: .init(encodingAsUTF8: """
        // swift-tools-version:5.2
        import PackageDescription

        let package = Package(name: "repo")
        """))
        try repo.commit()
        try repo.tag(name: "1.1.1")
        provider.add(specifier: .init(url: "http://www.githost.com/repo"), repository: repo)

        let diags = DiagnosticsEngine()
        let context = try PackageEditorContext(
            manifestPath: AbsolutePath("/pkg/Package.swift"),
            repositoryManager: RepositoryManager(path: .init("/pkg/repositories"),
                                                 provider: provider,
                                                 fileSystem: fs),
            toolchain: Resources.default.toolchain,
            diagnosticsEngine: diags,
            fs: fs)
        let editor = PackageEditor(context: context)
        try editor.addPackageDependency(url: "http://www.githost.com/repo.git", requirement: .exact("1.1.1"))
        XCTAssertThrows(Diagnostics.fatalError) {
            try editor.addTarget(.library(name: "Library", includeTestTarget: false, dependencyNames: []),
                                 productPackageNameMapping: [:])
        }
        XCTAssertEqual(diags.diagnostics.map(\.message.text),
                       ["'targets' argument is not an array literal or concatenation of array literals"])
        XCTAssertThrows(Diagnostics.fatalError) {
            try editor.addProduct(name: "Executable", type: .executable, targets: ["foo"])
        }
        XCTAssertEqual(diags.diagnostics.map(\.message.text),
                       ["'targets' argument is not an array literal or concatenation of array literals",
                        "'products' argument is not an array literal or concatenation of array literals"])

        let newManifest = try fs.readFileContents(manifestPath).cString
        XCTAssertEqual(newManifest, """
        // swift-tools-version:5.3
        import PackageDescription

        let flag = false
        let extraDeps: [Package.Dependency] = []

        let package = Package(
            name: "exec",
            products: [
                .library(name: "Library", targets: ["foo"])
            ].filter { _ in true },
            dependencies: extraDeps + [
                .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                .package(name: "repo", url: "http://www.githost.com/repo.git", .exact("1.1.1")),
            ],
            targets: flag ? [] : [
                .target(
                    name: "foo",
                    dependencies: []),
            ]
        )
        """)
    }

    func testEditingConditionalPackageInit() throws {
        let manifest = """
            // swift-tools-version:5.3
            import PackageDescription

            #if os(macOS)
            let package = Package(
                name: "macOSPackage"
            )
            #else
            let package = Package(
                name: "otherPlatformsPackage"
            )
            #endif
            """

        let fs = InMemoryFileSystem(emptyFiles:
            "/pkg/Package.swift",
            "/pkg/Sources/foo/source.swift",
            "end")

        let manifestPath = AbsolutePath("/pkg/Package.swift")
        try fs.writeFileContents(manifestPath) { $0 <<< manifest }

        try fs.createDirectory(.init("/pkg/repositories"), recursive: false)

        let diags = DiagnosticsEngine()
        let context = try PackageEditorContext(
            manifestPath: AbsolutePath("/pkg/Package.swift"),
            repositoryManager: RepositoryManager(path: .init("/pkg/repositories"),
                                                 provider: InMemoryGitRepositoryProvider(),
                                                 fileSystem: fs),
            toolchain: Resources.default.toolchain,
            diagnosticsEngine: diags,
            fs: fs)
        let editor = PackageEditor(context: context)
        XCTAssertThrows(Diagnostics.fatalError) {
            try editor.addTarget(.library(name: "Library", includeTestTarget: false, dependencyNames: []),
                                 productPackageNameMapping: [:])
        }
        XCTAssertEqual(diags.diagnostics.map(\.message.text), ["found multiple Package initializers"])
    }
}
