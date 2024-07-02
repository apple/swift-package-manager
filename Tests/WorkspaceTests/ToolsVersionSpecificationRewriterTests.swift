//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

///
/// This file tests `Workspace.rewriteToolsVersionSpecification(toDefaultManifestIn:specifying:fileSystem:)`.
///

import Basics
import PackageModel
@testable import Workspace
import XCTest

/// Test cases for `rewriteToolsVersionSpecification(toDefaultManifestIn:specifying:fileSystem:)`
final class ToolsVersionSpecificationRewriterTests: XCTestCase {
    
    /// Tests `rewriteToolsVersionSpecification(toDefaultManifestIn:specifying:fileSystem:)`.
    func testNonVersionSpecificManifests() throws {
        // Empty file.
        rewriteToolsVersionSpecificationToDefaultManifest(content: "") { result in
            XCTAssertEqual(result, "// swift-tools-version:4.1.2\n")
        }

        // File with just a new line.
        rewriteToolsVersionSpecificationToDefaultManifest(content: "\n") { result in
            XCTAssertEqual(result, "// swift-tools-version:4.1.2\n\n")
        }

        // File with some contents.
        rewriteToolsVersionSpecificationToDefaultManifest(content: "let package = ... \n") { result in
            XCTAssertEqual(result, "// swift-tools-version:4.1.2\nlet package = ... \n")
        }

        // File already having a valid version specifier.
        let content = """
            // swift-tools-version:3.1.2
            ...
            """

        rewriteToolsVersionSpecificationToDefaultManifest(content: content) { result in
            XCTAssertEqual(result, "// swift-tools-version:4.1.2\n...")
        }

        // Write a version with zero in patch number.
        rewriteToolsVersionSpecificationToDefaultManifest(
            content: """
            // swift-tools-version:3.1.2
            ...
            """,
            version: ToolsVersion(version: "2.1.0")
        ) { result in
            XCTAssertEqual(result, "// swift-tools-version:2.1\n...")
        }

        // Contents with invalid tools version specification (ignoring the validity of the version specifier).
        rewriteToolsVersionSpecificationToDefaultManifest(
            content: """
            // swift-tool-version:3.1.2
            ...
            """
        ) { result in
            XCTAssertEqual(result, "// swift-tools-version:4.1.2\n// swift-tool-version:3.1.2\n...")
        }

        // Contents with invalid version specifier.
        rewriteToolsVersionSpecificationToDefaultManifest(
            content: """
            // swift-tools-version:3.1.2
            ...
            """
        ) { result in
            XCTAssertEqual(result, "// swift-tools-version:4.1.2\n...")
        }

        // Contents with invalid version specifier and some meta data.
        rewriteToolsVersionSpecificationToDefaultManifest(
            content: """
            // swift-tools-version:3.1.2
            ...
            """
        ) { result in
            // Note: Right now we lose the metadata but if we ever start using it, we should preserve it.
            XCTAssertEqual(result, "// swift-tools-version:4.1.2\n...")
        }

        // Try to write a version with prerelease and build meta data.
        let toolsVersion = ToolsVersion(version: "4.1.2-alpha.beta+sha.1234")
        rewriteToolsVersionSpecificationToDefaultManifest(
            content: "let package = ... \n",
            version: toolsVersion
        ) { result in
            XCTAssertEqual(result, "// swift-tools-version:4.1.2\nlet package = ... \n")
        }
    }
    
    func testManifestAccessFailures() throws {
        let toolsVersion = ToolsVersion.v5_3
        
        let inMemoryFileSystem = InMemoryFileSystem()
        let manifestFilePath = AbsolutePath("/pkg/Package.swift/Package.swift")
        try inMemoryFileSystem.createDirectory(manifestFilePath.parentDirectory, recursive: true) // /pkg/Package.swift/
        
        // Test `ManifestAccessError.Kind.isADirectory`
        XCTAssertThrowsError(
            try ToolsVersionSpecificationWriter.rewriteSpecification(
                manifestDirectory: manifestFilePath.parentDirectory.parentDirectory, // /pkg/
                toolsVersion: toolsVersion,
                fileSystem: inMemoryFileSystem
            ),
            "'/pkg/Package.swift' is a directory, and an error should've been thrown"
        ) { error in
            guard let error = error as? ToolsVersionSpecificationWriter.ManifestAccessError else {
                XCTFail("a ManifestAccessError should've been thrown")
                return
            }
            XCTAssertEqual(
                error.kind,
                .isADirectory
            )
            XCTAssertEqual(
                error.description,
                "no accessible Swift Package Manager manifest file found at '\(manifestFilePath.parentDirectory)'; the path is a directory; a file is expected" // /pkg/Package.swift/
            )
        }
        
        // Test `ManifestAccessError.Kind.noSuchFileOrDirectory`
        XCTAssertThrowsError(
            try ToolsVersionSpecificationWriter.rewriteSpecification(
                manifestDirectory: manifestFilePath.parentDirectory, // /pkg/Package.swift/
                toolsVersion: toolsVersion,
                fileSystem: inMemoryFileSystem
            ),
            "'/pkg/Package.swift' is a directory, and an error should've been thrown"
        ) { error in
            guard let error = error as? ToolsVersionSpecificationWriter.ManifestAccessError else {
                XCTFail("a ManifestAccessError should've been thrown")
                return
            }
            XCTAssertEqual(
                error.kind,
                .noSuchFileOrDirectory
            )
            XCTAssertEqual(
                error.description,
                "no accessible Swift Package Manager manifest file found at '\(manifestFilePath)'; a component of the path does not exist, or the path is an empty string" // /pkg/Package.swift/Package.swift
            )
        }
        
        // TODO: Test `ManifestAccessError.Kind.unknown`
    }
    
    // Private functions are not run in tests.
    private func testVersionSpecificManifests() throws {
        // TODO: Add the functionality and tests for version-specific manifests too.
    }

    func testZeroedPatchVersion() {
        XCTAssertEqual(ToolsVersion(version: "4.2.1").zeroedPatch.description, "4.2.0")
        XCTAssertEqual(ToolsVersion(version: "4.2.0").zeroedPatch.description, "4.2.0")
        XCTAssertEqual(ToolsVersion(version: "6.0.129").zeroedPatch.description, "6.0.0")
    }
    
    /// Does the boilerplate filesystem preparations, then calls `rewriteToolsVersionSpecification(toDefaultManifestIn:specifying:fileSystem:)`, for `testNonVersionSpecificManifests()`.
    /// - Parameters:
    ///   - stream: The stream to read from and write to the filesystem.
    ///   - version: The Swift tools version to specify.
    ///   - resultHandler: The result handler.
    func rewriteToolsVersionSpecificationToDefaultManifest(
        content: String,
        version: ToolsVersion = ToolsVersion(version: "4.1.2"),
        resultHandler: (String) -> Void
    ) {
        do {
            let inMemoryFileSystem = InMemoryFileSystem()

            let manifestFilePath = AbsolutePath("/pkg/Package.swift")

            try inMemoryFileSystem.createDirectory(manifestFilePath.parentDirectory, recursive: true)
            try inMemoryFileSystem.writeFileContents(manifestFilePath, string: content)

            try ToolsVersionSpecificationWriter.rewriteSpecification(
                manifestDirectory: manifestFilePath.parentDirectory,
                toolsVersion: version,
                fileSystem: inMemoryFileSystem
            )

            resultHandler(try inMemoryFileSystem.readFileContents(manifestFilePath))
        } catch {
            XCTFail("Failed with error \(error)")
        }
    }
    
}
