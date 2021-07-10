/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest

import PackageSyntax

final class AddPackageDependencyTests: XCTestCase {
    func testAddPackageDependency() throws {
        let manifest = """
            // swift-tools-version:5.2
            import PackageDescription

            let package = Package(
                name: "exec",
                dependencies: [
                ],
                targets: [
                    .target(
                        name: "exec",
                        dependencies: []),
                    .testTarget(
                        name: "execTests",
                        dependencies: ["exec"]),
                ]
            )
            """
        
        
        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .upToNextMajor("1.0.1"),
            branchAndRevisionConvenienceMethodsSupported: false
        )
        
        XCTAssertEqual(editor.editedManifest, """
            // swift-tools-version:5.2
            import PackageDescription

            let package = Package(
                name: "exec",
                dependencies: [
                    .package(name: "goo", url: "https://github.com/foo/goo", .upToNextMajor(from: "1.0.1")),
                ],
                targets: [
                    .target(
                        name: "exec",
                        dependencies: []),
                    .testTarget(
                        name: "execTests",
                        dependencies: ["exec"]),
                ]
            )
            """)
    }

    func testAddPackageDependency2() throws {
        let manifest = """
            let package = Package(
                name: "exec",
                dependencies: [],
                targets: [
                    .target(name: "exec"),
                ]
            )
            """


        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .upToNextMajor("1.0.1"),
            branchAndRevisionConvenienceMethodsSupported: false
        )

        XCTAssertEqual(editor.editedManifest, """
            let package = Package(
                name: "exec",
                dependencies: [
                    .package(name: "goo", url: "https://github.com/foo/goo", .upToNextMajor(from: "1.0.1")),
                ],
                targets: [
                    .target(name: "exec"),
                ]
            )
            """)
    }

    func testAddPackageDependency3() throws {
        let manifest = """
            let package = Package(
                name: "exec",
                dependencies: [
                    // Here is a comment.
                    .package(url: "https://github.com/foo/bar", .branch("master")),
                ],
                targets: [
                    .target(name: "exec"),
                ]
            )
            """


        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .upToNextMajor("1.0.1"),
            branchAndRevisionConvenienceMethodsSupported: false
        )

        // FIXME: preserve comment
        XCTAssertEqual(editor.editedManifest, """
            let package = Package(
                name: "exec",
                dependencies: [
                    .package(url: "https://github.com/foo/bar", .branch("master")),
                    .package(name: "goo", url: "https://github.com/foo/goo", .upToNextMajor(from: "1.0.1")),
                ],
                targets: [
                    .target(name: "exec"),
                ]
            )
            """)
    }

    func testAddPackageDependency4() throws {
        let manifest = """
            let package = Package(
                name: "exec",
                targets: [
                    .target(name: "exec"),
                ]
            )
            """


        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .upToNextMajor("1.0.1"),
            branchAndRevisionConvenienceMethodsSupported: false
        )

        XCTAssertEqual(editor.editedManifest, """
            let package = Package(
                name: "exec",
                dependencies: [
                    .package(name: "goo", url: "https://github.com/foo/goo", .upToNextMajor(from: "1.0.1")),
                ],
                targets: [
                    .target(name: "exec"),
                ]
            )
            """)
    }

    func testAddPackageDependency5() throws {
        // FIXME: This is broken, we end up removing the comment.
        let manifest = """
            let package = Package(
                name: "exec",
                dependencies: [
                    // Here is a comment.
                ],
                targets: [
                    .target(name: "exec"),
                ]
            )
            """


        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .upToNextMajor("1.0.1"),
            branchAndRevisionConvenienceMethodsSupported: false
        )

        XCTAssertEqual(editor.editedManifest, """
            let package = Package(
                name: "exec",
                dependencies: [
                    .package(name: "goo", url: "https://github.com/foo/goo", .upToNextMajor(from: "1.0.1")),
                ],
                targets: [
                    .target(name: "exec"),
                ]
            )
            """)
    }

    func testAddPackageDependency6() throws {
        let manifest = """
            let myDeps = [
                .package(url: "https://github.com/foo/foo", from: "1.0.2"),
            ]

            let package = Package(
                name: "exec",
                dependencies: myDeps + [
                    .package(url: "https://github.com/foo/bar", from: "1.0.3"),
                ],
                targets: [
                    .target(name: "exec"),
                ]
            )
            """


        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .upToNextMajor("1.0.1"),
            branchAndRevisionConvenienceMethodsSupported: false
        )

        XCTAssertEqual(editor.editedManifest, """
            let myDeps = [
                .package(url: "https://github.com/foo/foo", from: "1.0.2"),
            ]

            let package = Package(
                name: "exec",
                dependencies: myDeps + [
                    .package(url: "https://github.com/foo/bar", from: "1.0.3"),
                    .package(name: "goo", url: "https://github.com/foo/goo", .upToNextMajor(from: "1.0.1")),
                ],
                targets: [
                    .target(name: "exec"),
                ]
            )
            """)
    }

    func testAddPackageDependency7() throws {
        let manifest = """
            let package = Package(
                name: "exec",
                dependencies: [
                    .package(url: "https://github.com/foo/bar", from: "1.0.3")
                ],
                targets: [
                    .target(name: "exec")
                ]
            )
            """


        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .upToNextMajor("1.0.1"),
            branchAndRevisionConvenienceMethodsSupported: false
        )

        XCTAssertEqual(editor.editedManifest, """
            let package = Package(
                name: "exec",
                dependencies: [
                    .package(url: "https://github.com/foo/bar", from: "1.0.3"),
                    .package(name: "goo", url: "https://github.com/foo/goo", .upToNextMajor(from: "1.0.1")),
                ],
                targets: [
                    .target(name: "exec")
                ]
            )
            """)
    }

    func testAddPackageDependency8() throws {
        let manifest = """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
                targets: [
                    .target(name: "exec"),
                ]
            )
            """


        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .upToNextMajor("1.0.1"),
            branchAndRevisionConvenienceMethodsSupported: false
        )

        XCTAssertEqual(editor.editedManifest, """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
                dependencies: [
                    .package(name: "goo", url: "https://github.com/foo/goo", .upToNextMajor(from: "1.0.1")),
                ],
                targets: [
                    .target(name: "exec"),
                ]
            )
            """)
    }

    func testAddPackageDependency9() throws {
        let manifest = """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
                swiftLanguageVersions: []
            )
            """


        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .upToNextMajor("1.0.1"),
            branchAndRevisionConvenienceMethodsSupported: false
        )

        XCTAssertEqual(editor.editedManifest, """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
                dependencies: [
                    .package(name: "goo", url: "https://github.com/foo/goo", .upToNextMajor(from: "1.0.1")),
                ],
                swiftLanguageVersions: []
            )
            """)
    }

    func testAddPackageDependency10() throws {
        let manifest = """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
            )
            """


        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .upToNextMajor("1.0.1"),
            branchAndRevisionConvenienceMethodsSupported: false
        )

        XCTAssertEqual(editor.editedManifest, """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
                dependencies: [
                    .package(name: "goo", url: "https://github.com/foo/goo", .upToNextMajor(from: "1.0.1")),
                ]
            )
            """)
    }

    func testAddPackageDependencyWithExactRequirement() throws {
        let manifest = """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
            )
            """


        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .exact("2.0.2"),
            branchAndRevisionConvenienceMethodsSupported: false
        )

        XCTAssertEqual(editor.editedManifest, """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
                dependencies: [
                    .package(name: "goo", url: "https://github.com/foo/goo", .exact("2.0.2")),
                ]
            )
            """)
    }

    func testAddPackageDependencyWithBranchRequirement() throws {
        let manifest = """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
            )
            """


        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .branch("main"),
            branchAndRevisionConvenienceMethodsSupported: false
        )

        XCTAssertEqual(editor.editedManifest, """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
                dependencies: [
                    .package(name: "goo", url: "https://github.com/foo/goo", .branch("main")),
                ]
            )
            """)
    }

    func testAddPackageDependencyWithRevisionRequirement() throws {
        let manifest = """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
            )
            """


        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .revision("abcde"),
            branchAndRevisionConvenienceMethodsSupported: false
        )

        XCTAssertEqual(editor.editedManifest, """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
                dependencies: [
                    .package(name: "goo", url: "https://github.com/foo/goo", .revision("abcde")),
                ]
            )
            """)
    }

    func testAddPackageDependencyWithBranchRequirementUsingConvenienceMethods() throws {
        let manifest = """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
            )
            """


        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .branch("main"),
            branchAndRevisionConvenienceMethodsSupported: true
        )

        XCTAssertEqual(editor.editedManifest, """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
                dependencies: [
                    .package(name: "goo", url: "https://github.com/foo/goo", branch: "main"),
                ]
            )
            """)
    }

    func testAddPackageDependencyWithRevisionRequirementUsingConvenienceMethods() throws {
        let manifest = """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
            )
            """


        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .revision("abcde"),
            branchAndRevisionConvenienceMethodsSupported: true
        )

        XCTAssertEqual(editor.editedManifest, """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
                dependencies: [
                    .package(name: "goo", url: "https://github.com/foo/goo", revision: "abcde"),
                ]
            )
            """)
    }

    func testAddPackageDependencyWithUpToNextMinorRequirement() throws {
        let manifest = """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
            )
            """


        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .upToNextMinor("1.1.1"),
            branchAndRevisionConvenienceMethodsSupported: false
        )

        XCTAssertEqual(editor.editedManifest, """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
                dependencies: [
                    .package(name: "goo", url: "https://github.com/foo/goo", .upToNextMinor(from: "1.1.1")),
                ]
            )
            """)
    }

    func testAddPackageDependenciesWithRangeRequirements() throws {
        let manifest = """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
            )
            """


        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .range("1.1.1", "2.2.2"),
            branchAndRevisionConvenienceMethodsSupported: false
        )
        try editor.addPackageDependency(
            name: "goo",
            url: "https://github.com/foo/goo",
            requirement: .closedRange("2.2.2", "3.3.3"),
            branchAndRevisionConvenienceMethodsSupported: false
        )

        XCTAssertEqual(editor.editedManifest, """
            let package = Package(
                name: "exec",
                platforms: [.iOS],
                dependencies: [
                    .package(name: "goo", url: "https://github.com/foo/goo", "1.1.1"..<"2.2.2"),
                    .package(name: "goo", url: "https://github.com/foo/goo", "2.2.2"..."3.3.3"),
                ]
            )
            """)
    }
}
