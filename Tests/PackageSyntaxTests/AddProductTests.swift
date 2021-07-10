/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import XCTest

import PackageSyntax

final class AddProductTests: XCTestCase {
    func testAddProduct() throws {
        let manifest = """
            // swift-tools-version:5.2
            import PackageDescription

            let package = Package(
                name: "exec",
                products: [
                    .executable(name: "abc", targets: ["foo"]),
                ]
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
        try editor.addProduct(name: "exec", type: .executable)
        try editor.addProduct(name: "lib", type: .library(.automatic))
        try editor.addProduct(name: "staticLib", type: .library(.static))
        try editor.addProduct(name: "dynamicLib", type: .library(.dynamic))

        XCTAssertEqual(editor.editedManifest, """
            // swift-tools-version:5.2
            import PackageDescription

            let package = Package(
                name: "exec",
                products: [
                    .executable(name: "abc", targets: ["foo"]),
                    .executable(
                        name: "exec",
                        targets: []
                    ),
                    .library(
                        name: "lib",
                        targets: []
                    ),
                    .library(
                        name: "staticLib",
                        type: .static,
                        targets: []
                    ),
                    .library(
                        name: "dynamicLib",
                        type: .dynamic,
                        targets: []
                    ),
                ]
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

    func testAddProduct2() throws {
        let manifest = """
            // swift-tools-version:5.2
            import PackageDescription

            let package = Package(
                name: "exec",
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
        try editor.addProduct(name: "exec", type: .executable)
        try editor.addProduct(name: "lib", type: .library(.automatic))
        try editor.addProduct(name: "staticLib", type: .library(.static))
        try editor.addProduct(name: "dynamicLib", type: .library(.dynamic))

        // FIXME: weird indentation
        XCTAssertEqual(editor.editedManifest, """
            // swift-tools-version:5.2
            import PackageDescription

            let package = Package(
                name: "exec",
                products: [
                    .executable(
                        name: "exec",
                        targets: []
                    ),
                    .library(
                        name: "lib",
                        targets: []
                    ),
                    .library(
                        name: "staticLib",
                        type: .static,
                        targets: []
                    ),
                    .library(
                        name: "dynamicLib",
                        type: .dynamic,
                        targets: []
                    ),
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

    func testAddProduct3() throws {
        let manifest = """
            // swift-tools-version:5.2
            import PackageDescription

            let package = Package(
            \tname: "exec",
            \ttargets: [
            \t\t.target(
            \t\t\tname: "foo",
            \t\t\tdependencies: []
            \t\t),
            \t]
            )
            """

        let editor = try ManifestRewriter(manifest, diagnosticsEngine: .init())
        try editor.addProduct(name: "exec", type: .executable)

        // FIXME: weird indentation
        XCTAssertEqual(editor.editedManifest, """
            // swift-tools-version:5.2
            import PackageDescription

            let package = Package(
            \tname: "exec",
            \tproducts: [
            \t\t.executable(
            \t\t\tname: "exec",
            \t\t\ttargets: []
            \t\t),
            \t],
            \ttargets: [
            \t\t.target(
            \t\t\tname: "foo",
            \t\t\tdependencies: []
            \t\t),
            \t]
            )
            """)
    }
}
