/*
 This source file is part of the Swift.org open source project
 
 Copyright (c) 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception
 
 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import XCTest
import SPMTestSupport
import TSCBasic
import PackageModel
import Workspace

class ManifestSourceGenerationTests: XCTestCase {
    
    /// Private function that writes the contents of a package manifest to a temporary package directory and then loads it, then serializes the loaded manifest back out again and loads it once again, after which it compares that no information was lost.
    private func testManifestWritingRoundTrip(manifestContents: String, toolsVersion: ToolsVersion, fs: FileSystem = localFileSystem) throws {
        try withTemporaryDirectory { packageDir in
            // Write the original manifest file contents, and load it.
            try fs.writeFileContents(packageDir.appending(component: Manifest.filename), bytes: ByteString(encodingAsUTF8: manifestContents))
            let manifestLoader = ManifestLoader(manifestResources: Resources.default)
            let manifest = try tsc_await { manifestLoader.load(package: packageDir, baseURL: packageDir.pathString, toolsVersion: toolsVersion, packageKind: .root, verbosity: TSCUtility.verbosity, on: .global(), completion: $0) }

            // Generate source code for the loaded manifest, write it out to replace the manifest file contents, and load it again.
            let newContents = manifest.generatedManifestFileContents
            try fs.writeFileContents(packageDir.appending(component: Manifest.filename), bytes: ByteString(encodingAsUTF8: newContents))
            let newManifest = try tsc_await { manifestLoader.load(package: packageDir, baseURL: packageDir.pathString, toolsVersion: toolsVersion, packageKind: .root, verbosity: TSCUtility.verbosity, on: .global(), completion: $0) }
            
            // Check that all the relevant properties survived.
            let failureDetails = "\n--- ORIGINAL MANIFEST CONTENTS ---\n" + manifestContents + "\n--- REWRITTEN MANIFEST CONTENTS ---\n" + newContents
            XCTAssertEqual(newManifest.toolsVersion, manifest.toolsVersion, failureDetails)
            XCTAssertEqual(newManifest.name, manifest.name, failureDetails)
            XCTAssertEqual(newManifest.defaultLocalization, manifest.defaultLocalization, failureDetails)
            XCTAssertEqual(newManifest.platforms, manifest.platforms, failureDetails)
            XCTAssertEqual(newManifest.pkgConfig, manifest.pkgConfig, failureDetails)
            XCTAssertEqual(newManifest.providers, manifest.providers, failureDetails)
            XCTAssertEqual(newManifest.products, manifest.products, failureDetails)
            XCTAssertEqual(newManifest.dependencies, manifest.dependencies, failureDetails)
            XCTAssertEqual(newManifest.targets, manifest.targets, failureDetails)
            XCTAssertEqual(newManifest.swiftLanguageVersions, manifest.swiftLanguageVersions, failureDetails)
            XCTAssertEqual(newManifest.cLanguageStandard, manifest.cLanguageStandard, failureDetails)
            XCTAssertEqual(newManifest.cxxLanguageStandard, manifest.cxxLanguageStandard, failureDetails)
        }
    }

    func testBasics() throws {
        let manifestContents = """
            // swift-tools-version:5.3
            // The swift-tools-version declares the minimum version of Swift required to build this package.

            import PackageDescription

            let package = Package(
                name: "MyPackage",
                platforms: [
                    .macOS(.v10_14),
                    .iOS(.v13)
                ],
                products: [
                    // Products define the executables and libraries a package produces, and make them visible to other packages.
                    .library(
                        name: "MyPackage",
                        targets: ["MyPackage"]),
                ],
                dependencies: [
                    // Dependencies declare other packages that this package depends on.
                    // .package(url: /* package url */, from: "1.0.0"),
                ],
                targets: [
                    // Targets are the basic building blocks of a package. A target can define a module or a test suite.
                    // Targets can depend on other targets in this package, and on products in packages this package depends on.
                    .target(
                        name: "MyPackage",
                        dependencies: []),
                    .testTarget(
                        name: "MyPackageTests",
                        dependencies: ["MyPackage"]),
                ]
            )
            """
        try testManifestWritingRoundTrip(manifestContents: manifestContents, toolsVersion: .v5_3)
    }


    func testAdvancedFeatures() throws {
        let manifestContents = """
            // swift-tools-version:5.3
            // The swift-tools-version declares the minimum version of Swift required to build this package.

            import PackageDescription

            let package = Package(
                name: "MyPackage",
                products: [
                    // Products define the executables and libraries a package produces, and make them visible to other packages.
                    .library(
                        name: "MyPackage",
                        targets: ["MyPackage"]),
                ],
                dependencies: [
                    // Dependencies declare other packages that this package depends on.
                    .package(path: "/a/b/c"),
                    .package(name: "abc", path: "/a/b/d"),
                ],
                targets: [
                    // Targets are the basic building blocks of a package. A target can define a module or a test suite.
                    // Targets can depend on other targets in this package, and on products in packages this package depends on.
                    .systemLibrary(
                        name: "SystemLibraryTarget",
                        pkgConfig: "libSystemModule",
                        providers: [
                            .brew(["SystemModule"]),
                        ]),
                    .target(
                        name: "MyPackage",
                        dependencies: [
                            .target(name: "SystemLibraryTarget", condition: .when(platforms: [.macOS]))
                        ],
                        linkerSettings: [
                            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../lib/swift/macosx"], .when(platforms: [.iOS])),
                        ]),
                    .testTarget(
                        name: "MyPackageTests",
                        dependencies: ["MyPackage"]),
                ],
                swiftLanguageVersions: [.v5],
                cLanguageStandard: .c11,
                cxxLanguageStandard: .cxx11
            )
            """
        try testManifestWritingRoundTrip(manifestContents: manifestContents, toolsVersion: .v5_3)
    }

    func testResources() throws {
        let manifestContents = """
            // swift-tools-version:5.3
            import PackageDescription

            let package = Package(
                name: "Resources",
                defaultLocalization: "is",
                targets: [
                    .target(
                        name: "SwiftyResource",
                        resources: [
                            .copy("foo.txt"),
                            .process("a/b/c/"),
                        ]
                    ),
                    .target(
                        name: "SeaResource",
                        resources: [
                            .process("foo.txt", localization: .base),
                        ]
                    ),
                    .target(
                        name: "SieResource",
                        resources: [
                            .copy("bar.boo"),
                        ]
                    ),
                ]
            )
            """
        try testManifestWritingRoundTrip(manifestContents: manifestContents, toolsVersion: .v5_3)
    }

    func testBuildSettings() throws {
        let manifestContents = """
            // swift-tools-version:5.3
            import PackageDescription

            let package = Package(
                name: "Localized",
                targets: [
                    .target(name: "exe",
                        cxxSettings: [
                            .headerSearchPath("ProjectName"),
                            .headerSearchPath("../../.."),
                            .define("ABC=DEF"),
                            .define("GHI", to: "JKL")
                        ]
                    ),
                    .target(
                        name: "MyTool",
                        dependencies: ["Utility"],
                        cSettings: [
                            .headerSearchPath("path/relative/to/my/target"),
                            .define("DISABLE_SOMETHING", .when(platforms: [.iOS], configuration: .release)),
                        ],
                        swiftSettings: [
                            .define("ENABLE_SOMETHING", .when(configuration: .release)),
                        ],
                        linkerSettings: [
                            .linkedLibrary("openssl", .when(platforms: [.linux])),
                        ]
                    ),
                ]
            )
            """
        try testManifestWritingRoundTrip(manifestContents: manifestContents, toolsVersion: .v5_3)
    }
}
