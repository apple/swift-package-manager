/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import XCTest

import PackageSyntax

final class AddTargetTests: XCTestCase {
    func testAddTarget() throws {
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
        
        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addTarget(targetName: "NewTarget", factoryMethodName: "target")
        try editor.addTarget(targetName: "NewTargetTests", factoryMethodName: "testTarget")
        try editor.addByNameTargetDependency(target: "NewTargetTests", dependency: "NewTarget")

        XCTAssertEqual(editor.editedManifest, """
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
                        name: "NewTarget",
                        dependencies: []
                    ),
                    .testTarget(
                        name: "NewTargetTests",
                        dependencies: [
                            "NewTarget",
                        ]
                    ),
                ]
            )
            """)
    }

    func testAddTarget2() throws {
        let manifest = """
                // swift-tools-version:5.2
                import PackageDescription

                let package = Package(
                    name: "exec",
                    dependencies: [
                        .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                    ]
                )
                """

        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addTarget(targetName: "NewTarget", factoryMethodName: "target")

        XCTAssertEqual(editor.editedManifest, """
                // swift-tools-version:5.2
                import PackageDescription

                let package = Package(
                    name: "exec",
                    dependencies: [
                        .package(url: "https://github.com/foo/goo", from: "1.0.1"),
                    ],
                    targets: [
                        .target(
                            name: "NewTarget",
                            dependencies: []
                        ),
                    ]
                )
                """)
    }

    func testAddTarget3() throws {
        let manifest = """
                // swift-tools-version:5.2
                import PackageDescription

                let package = Package(
                \tname: "exec",
                \tdependencies: [
                \t\t.package(url: "https://github.com/foo/goo", from: "1.0.1"),
                \t]
                )
                """

        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addTarget(targetName: "NewTarget", factoryMethodName: "target")

        XCTAssertEqual(editor.editedManifest, """
                // swift-tools-version:5.2
                import PackageDescription

                let package = Package(
                \tname: "exec",
                \tdependencies: [
                \t\t.package(url: "https://github.com/foo/goo", from: "1.0.1"),
                \t],
                \ttargets: [
                \t\t.target(
                \t\t\tname: "NewTarget",
                \t\t\tdependencies: []
                \t\t),
                \t]
                )
                """)
    }
}
