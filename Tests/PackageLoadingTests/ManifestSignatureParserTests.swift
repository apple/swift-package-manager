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
import Foundation
import PackageLoading
import _InternalTestSupport
import XCTest

class ManifestSignatureParserTests: XCTestCase {
    func testSignedManifest() throws {
        try testWithTemporaryDirectory { tmpPath in
            let manifestPath = tmpPath.appending("Package.swift")
            let signatureBytes = Array(UUID().uuidString.utf8)

            try localFileSystem.writeFileContents(
                manifestPath,
                string: """
                // swift-tools-version: 5.7

                import PackageDescription
                let package = Package(
                    name: "library",
                    products: [ .library(name: "library", targets: ["library"]) ],
                    targets: [ .target(name: "library") ]
                )

                // signature: cms-1.0.0;\(Data(signatureBytes).base64EncodedString())
                """
            )

            let components = try ManifestSignatureParser.parse(manifestPath: manifestPath, fileSystem: localFileSystem)
            XCTAssertNotNil(components)
            XCTAssertEqual(components?.contents, Array("""
            // swift-tools-version: 5.7

            import PackageDescription
            let package = Package(
                name: "library",
                products: [ .library(name: "library", targets: ["library"]) ],
                targets: [ .target(name: "library") ]
            )

            """.utf8))
            XCTAssertEqual(components?.signatureFormat, "cms-1.0.0")
            XCTAssertEqual(components?.signature, signatureBytes)
        }
    }

    func testManifestSignatureWithLeadingAndTrailingWhitespace() throws {
        try testWithTemporaryDirectory { tmpPath in
            let manifestPath = tmpPath.appending("Package.swift")
            let signatureBytes = Array(UUID().uuidString.utf8)

            try localFileSystem.writeFileContents(
                manifestPath,
                string: """
                // swift-tools-version: 5.7

                import PackageDescription
                let package = Package(
                    name: "library",
                    products: [ .library(name: "library", targets: ["library"]) ],
                    targets: [ .target(name: "library") ]
                )

                   // signature: cms-1.0.0;\(Data(signatureBytes).base64EncodedString())


                """
            )

            let components = try ManifestSignatureParser.parse(manifestPath: manifestPath, fileSystem: localFileSystem)
            XCTAssertNotNil(components)
            XCTAssertEqual(components?.contents, Array("""
            // swift-tools-version: 5.7

            import PackageDescription
            let package = Package(
                name: "library",
                products: [ .library(name: "library", targets: ["library"]) ],
                targets: [ .target(name: "library") ]
            )

            """.utf8))
            XCTAssertEqual(components?.signatureFormat, "cms-1.0.0")
            XCTAssertEqual(components?.signature, signatureBytes)
        }
    }

    func testUnsignedManifest() throws {
        try testWithTemporaryDirectory { tmpPath in
            let manifestPath = tmpPath.appending("Package.swift")
            try localFileSystem.writeFileContents(
                manifestPath,
                string: """
                // swift-tools-version: 5.7

                import PackageDescription
                let package = Package(
                    name: "library",
                    products: [ .library(name: "library", targets: ["library"]) ],
                    targets: [ .target(name: "library") ]
                )

                """
            )

            let components = try ManifestSignatureParser.parse(manifestPath: manifestPath, fileSystem: localFileSystem)
            XCTAssertNil(components)
        }
    }

    func testManifestWithCommentAsLastLine() throws {
        try testWithTemporaryDirectory { tmpPath in
            let manifestPath = tmpPath.appending("Package.swift")
            try localFileSystem.writeFileContents(
                manifestPath,
                string: """
                // swift-tools-version: 5.7

                import PackageDescription
                let package = Package(
                    name: "library",
                    products: [ .library(name: "library", targets: ["library"]) ],
                    targets: [ .target(name: "library") ]
                )

                // xxx
                """
            )

            let components = try ManifestSignatureParser.parse(manifestPath: manifestPath, fileSystem: localFileSystem)
            XCTAssertNil(components)
        }
    }

    func testManifestWithIncompleteSignatureLine1() throws {
        try testWithTemporaryDirectory { tmpPath in
            let manifestPath = tmpPath.appending("Package.swift")
            try localFileSystem.writeFileContents(
                manifestPath,
                string: """
                // swift-tools-version: 5.7

                import PackageDescription
                let package = Package(
                    name: "library",
                    products: [ .library(name: "library", targets: ["library"]) ],
                    targets: [ .target(name: "library") ]
                )

                // signature
                """
            )

            let components = try ManifestSignatureParser.parse(manifestPath: manifestPath, fileSystem: localFileSystem)
            XCTAssertNil(components)
        }
    }

    func testManifestWithIncompleteSignatureLine2() throws {
        try testWithTemporaryDirectory { tmpPath in
            let manifestPath = tmpPath.appending("Package.swift")
            try localFileSystem.writeFileContents(
                manifestPath,
                string: """
                // swift-tools-version: 5.7

                import PackageDescription
                let package = Package(
                    name: "library",
                    products: [ .library(name: "library", targets: ["library"]) ],
                    targets: [ .target(name: "library") ]
                )

                // signature:
                """
            )

            let components = try ManifestSignatureParser.parse(manifestPath: manifestPath, fileSystem: localFileSystem)
            XCTAssertNil(components)
        }
    }

    func testManifestWithIncompleteSignatureLine3() throws {
        try testWithTemporaryDirectory { tmpPath in
            let manifestPath = tmpPath.appending("Package.swift")
            try localFileSystem.writeFileContents(
                manifestPath,
                string: """
                // swift-tools-version: 5.7

                import PackageDescription
                let package = Package(
                    name: "library",
                    products: [ .library(name: "library", targets: ["library"]) ],
                    targets: [ .target(name: "library") ]
                )

                    // signature: cms
                """
            )

            let components = try ManifestSignatureParser.parse(manifestPath: manifestPath, fileSystem: localFileSystem)
            XCTAssertNil(components)
        }
    }

    func testManifestWithIncompleteSignatureLine4() throws {
        try testWithTemporaryDirectory { tmpPath in
            let manifestPath = tmpPath.appending("Package.swift")
            try localFileSystem.writeFileContents(
                manifestPath,
                string: """
                // swift-tools-version: 5.7

                import PackageDescription
                let package = Package(
                    name: "library",
                    products: [ .library(name: "library", targets: ["library"]) ],
                    targets: [ .target(name: "library") ]
                )

                    // signature: cms;
                """
            )

            let components = try ManifestSignatureParser.parse(manifestPath: manifestPath, fileSystem: localFileSystem)
            XCTAssertNil(components)
        }
    }

    func testManifestWithMalformedSignature() throws {
        try testWithTemporaryDirectory { tmpPath in
            let manifestPath = tmpPath.appending("Package.swift")
            try localFileSystem.writeFileContents(
                manifestPath,
                string: """
                // swift-tools-version: 5.7

                import PackageDescription
                let package = Package(
                    name: "library",
                    products: [ .library(name: "library", targets: ["library"]) ],
                    targets: [ .target(name: "library") ]
                )

                    // signature: cms-1.0.0;signature-not-base64-encoded
                """
            )

            XCTAssertThrowsError(
                try ManifestSignatureParser.parse(manifestPath: manifestPath, fileSystem: localFileSystem)
            ) { error in
                guard case ManifestSignatureParser.Error.malformedManifestSignature = error else {
                    return XCTFail("Expected .malformedManifestSignature error, got \(error)")
                }
            }
        }
    }
}
