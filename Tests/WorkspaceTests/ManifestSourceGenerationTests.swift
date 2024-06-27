//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageGraph
import PackageLoading
import PackageModel
import _InternalTestSupport
import Workspace
import XCTest

extension String {
    fileprivate func nativePathString(escaped: Bool) -> String {
#if _runtime(_ObjC)
        return self
#else
        let fsr = self.fileSystemRepresentation
        defer { fsr.deallocate() }
        if escaped {
            return String(cString: fsr).replacingOccurrences(of: "\\", with: "\\\\")
        }
        return String(cString: fsr)
#endif
    }
}

final class ManifestSourceGenerationTests: XCTestCase {
    /// Private function that writes the contents of a package manifest to a temporary package directory and then loads it, then serializes the loaded manifest back out again and loads it once again, after which it compares that no information was lost. Return the source of the newly generated manifest.
    @discardableResult
    private func testManifestWritingRoundTrip(
        manifestContents: String,
        toolsVersion: ToolsVersion,
        toolsVersionHeaderComment: String? = .none,
        additionalImportModuleNames: [String] = [],
        fs: FileSystem = localFileSystem
    ) async throws -> String {
        try await withTemporaryDirectory { packageDir in
            let observability = ObservabilitySystem.makeForTesting()

            // Write the original manifest file contents, and load it.
            let manifestPath = packageDir.appending(component: Manifest.filename)
            try fs.writeFileContents(manifestPath, string: manifestContents)
            let manifestLoader = ManifestLoader(toolchain: try UserToolchain.default)
            let identityResolver = DefaultIdentityResolver()
            let dependencyMapper = DefaultDependencyMapper(identityResolver: identityResolver)
            let manifest = try await manifestLoader.load(
                manifestPath: manifestPath,
                manifestToolsVersion: toolsVersion,
                packageIdentity: .plain("Root"),
                packageKind: .root(packageDir),
                packageLocation: packageDir.pathString,
                packageVersion: nil,
                identityResolver: identityResolver,
                dependencyMapper: dependencyMapper,
                fileSystem: fs,
                observabilityScope: observability.topScope,
                delegateQueue: .sharedConcurrent,
                callbackQueue: .sharedConcurrent
            )

            XCTAssertNoDiagnostics(observability.diagnostics)

            // Generate source code for the loaded manifest,
            let newContents = try manifest.generateManifestFileContents(
                packageDirectory: packageDir,
                toolsVersionHeaderComment: toolsVersionHeaderComment,
                additionalImportModuleNames: additionalImportModuleNames)

            // Check that the tools version was serialized properly.
            let versionSpacing = (toolsVersion >= .v5_4) ? " " : ""
            XCTAssertMatch(newContents, .prefix("// swift-tools-version:\(versionSpacing)\(toolsVersion.major).\(toolsVersion.minor)"))

            // Write out the generated manifest to replace the old manifest file contents, and load it again.
            try fs.writeFileContents(manifestPath, string: newContents)
            let newManifest = try await manifestLoader.load(
                manifestPath: manifestPath,
                manifestToolsVersion: toolsVersion,
                packageIdentity: .plain("Root"),
                packageKind: .root(packageDir),
                packageLocation: packageDir.pathString,
                packageVersion: nil,
                identityResolver: identityResolver,
                dependencyMapper: dependencyMapper,
                fileSystem: fs,
                observabilityScope: observability.topScope,
                delegateQueue: .sharedConcurrent,
                callbackQueue: .sharedConcurrent
            )

            XCTAssertNoDiagnostics(observability.diagnostics)

            // Check that all the relevant properties survived.
            let failureDetails = "\n--- ORIGINAL MANIFEST CONTENTS ---\n" + manifestContents + "\n--- REWRITTEN MANIFEST CONTENTS ---\n" + newContents
            XCTAssertEqual(newManifest.toolsVersion, manifest.toolsVersion, failureDetails)
            XCTAssertEqual(newManifest.displayName, manifest.displayName, failureDetails)
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

            // Return the generated manifest so that the caller can do further testing on it.
            return newContents
        }
    }

    func testBasics() async throws {
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
        try await testManifestWritingRoundTrip(manifestContents: manifestContents, toolsVersion: .v5_3)
    }

    func testCustomPlatform() async throws {
        let manifestContents = """
            // swift-tools-version:5.6
            // The swift-tools-version declares the minimum version of Swift required to build this package.

            import PackageDescription

            let package = Package(
                name: "MyPackage",
                platforms: [
                    .custom("customOS", versionString: "1.0")
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
        try await testManifestWritingRoundTrip(manifestContents: manifestContents, toolsVersion: .v5_6)
    }

    func testAdvancedFeatures() async throws {
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
        try await testManifestWritingRoundTrip(manifestContents: manifestContents, toolsVersion: .v5_3)
    }

    func testPackageDependencyVariations() async throws {
        let manifestContents = """
            // swift-tools-version:5.4
            import PackageDescription

            #if os(Windows)
            let absolutePath = "file:///C:/Users/user/SourceCache/path/to/MyPkg16"
            #else
            let absolutePath = "file:///path/to/MyPkg16"
            #endif

            let package = Package(
                name: "MyPackage",
                dependencies: [
                   .package(url: "https://example.com/MyPkg1", from: "1.0.0"),
                   .package(url: "https://example.com/MyPkg2", .revision("58e9de4e7b79e67c72a46e164158e3542e570ab6")),
                   .package(url: "https://example.com/MyPkg5", .exact("1.2.3")),
                   .package(url: "https://example.com/MyPkg6", "1.2.3"..<"2.0.0"),
                   .package(url: "https://example.com/MyPkg7", .branch("main")),
                   .package(url: "https://example.com/MyPkg8", .upToNextMinor(from: "1.3.4")),
                   .package(url: "ssh://git@example.com/MyPkg9", .branch("my branch with spaces")),
                   .package(url: "../MyPkg10", from: "0.1.0"),
                   .package(path: "../MyPkg11"),
                   .package(path: "packages/path/to/MyPkg12"),
                   .package(path: "~/path/to/MyPkg13"),
                   .package(path: "~MyPkg14"),
                   .package(path: "~/path/to/~/MyPkg15"),
                   .package(path: "~"),
                   .package(path: absolutePath),
                ]
            )
            """
        let newContents = try await testManifestWritingRoundTrip(manifestContents: manifestContents, toolsVersion: .v5_3)

        // Check some things about the contents of the manifest.
        XCTAssertTrue(newContents.contains("url: \"\("../MyPkg10".nativePathString(escaped: true))\""), newContents)
        XCTAssertTrue(newContents.contains("path: \"\("../MyPkg11".nativePathString(escaped: true))\""), newContents)
        XCTAssertTrue(newContents.contains("path: \"\("packages/path/to/MyPkg12".nativePathString(escaped: true))"), newContents)
    }

    func testResources() async throws {
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
        try await testManifestWritingRoundTrip(manifestContents: manifestContents, toolsVersion: .v5_3)
    }

    func testBuildSettings() async throws {
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
        try await testManifestWritingRoundTrip(manifestContents: manifestContents, toolsVersion: .v5_3)
    }

    func testPluginTargets() async throws {
        let manifestContents = """
            // swift-tools-version:5.5
            import PackageDescription

            let package = Package(
                name: "Plugins",
                targets: [
                    .plugin(
                        name: "MyPlugin",
                        capability: .buildTool(),
                        dependencies: ["MyTool"]
                    ),
                    .executableTarget(
                        name: "MyTool"
                    ),
                ]
            )
            """
        try await testManifestWritingRoundTrip(manifestContents: manifestContents, toolsVersion: .v5_5)
    }

    func testCustomToolsVersionHeaderComment() async throws {
        let manifestContents = """
            // swift-tools-version:5.5
            import PackageDescription

            let package = Package(
                name: "Plugins",
                targets: [
                    .plugin(
                        name: "MyPlugin",
                        capability: .buildTool(),
                        dependencies: ["MyTool"]
                    ),
                    .executableTarget(
                        name: "MyTool"
                    ),
                ]
            )
            """
        let newContents = try await testManifestWritingRoundTrip(manifestContents: manifestContents, toolsVersion: .v5_5, toolsVersionHeaderComment: "a comment")

        XCTAssertTrue(newContents.hasPrefix("// swift-tools-version: 5.5; a comment\n"), "contents: \(newContents)")
    }

    func testAdditionalModuleImports() async throws {
        let manifestContents = """
            // swift-tools-version:5.5
            import PackageDescription
            import Foundation

            let package = Package(
                name: "MyPkg",
                targets: [
                    .executableTarget(
                        name: "MyExec"
                    ),
                ]
            )
            """
        let newContents = try await testManifestWritingRoundTrip(manifestContents: manifestContents, toolsVersion: .v5_5, additionalImportModuleNames: ["Foundation"])

        XCTAssertTrue(newContents.contains("import Foundation\n"), "contents: \(newContents)")
    }

    func testLatestPlatformVersions() async throws {
        let manifestContents = """
            // swift-tools-version: 5.9
            // The swift-tools-version declares the minimum version of Swift required to build this package.

            import PackageDescription

            let package = Package(
                name: "MyPackage",
                platforms: [
                    .macOS(.v14),
                    .iOS(.v17),
                    .tvOS(.v17),
                    .watchOS(.v10),
                    .visionOS(.v1),
                    .macCatalyst(.v17),
                    .driverKit(.v23)
                ],
                targets: [
                ]
            )
            """
        try await testManifestWritingRoundTrip(manifestContents: manifestContents, toolsVersion: .v5_9)
    }

    func testTargetPlatformConditions() async throws {
        let manifestContents = """
            // swift-tools-version: 5.9
            // The swift-tools-version declares the minimum version of Swift required to build this package.

            import PackageDescription

            let package = Package(
                name: "MyPackage",
                targets: [
                    .target(
                        name: "MyExe",
                        dependencies: [
                            .target(name: "MyLib", condition: .when(platforms: [
                                .macOS, .macCatalyst, .iOS, .tvOS, .watchOS, .visionOS,
                                .driverKit, .linux, .windows, .android, .wasi, .openbsd
                            ]))
                        ]
                    ),
                    .target(
                        name: "MyLib"
                    ),
                ]
            )
            """
        try await testManifestWritingRoundTrip(manifestContents: manifestContents, toolsVersion: .v5_9)
    }
    
    func testCustomProductSourceGeneration() throws {
        // Create a manifest containing a product for which we'd like to do custom source fragment generation.
        let packageDir = AbsolutePath("/tmp/MyLibrary")
        let manifest = Manifest.createManifest(
            displayName: "MyLibrary",
            path: packageDir.appending("Package.swift"),
            packageKind: .root("/tmp/MyLibrary"),
            packageLocation: packageDir.pathString,
            platforms: [],
            toolsVersion: .v5_5,
            products: [
                try .init(name: "Foo", type: .library(.static), targets: ["Bar"])
            ]
        )

        // Generate the manifest contents, using a custom source generator for the product type.
        let contents = manifest.generateManifestFileContents(packageDirectory: packageDir, customProductTypeSourceGenerator: { product in
            // This example handles library types in a custom way, for testing purposes.
            var params: [SourceCodeFragment] = []
            params.append(SourceCodeFragment(key: "name", string: product.name))
            if !product.targets.isEmpty {
                params.append(SourceCodeFragment(key: "targets", strings: product.targets))
            }
            // Handle .library specially (by not emitting as multiline), otherwise asking for default behavior.
            if case .library(let type) = product.type {
                if type != .automatic {
                    params.append(SourceCodeFragment(key: "type", enum: type.rawValue))
                }
                return SourceCodeFragment(enum: "library", subnodes: params, multiline: false)
            }
            else {
                return nil
            }
        })

        // Check that we generated what we expected.
        XCTAssertTrue(contents.contains(".library(name: \"Foo\", targets: [\"Bar\"], type: .static)"), "contents: \(contents)")
    }

    func testModuleAliasGeneration() async throws {
        let manifest = Manifest.createRootManifest(
            displayName: "thisPkg",
            path: "/thisPkg",
            toolsVersion: .v5_7,
            dependencies: [
                .localSourceControl(path: "/fooPkg", requirement: .upToNextMajor(from: "1.0.0")),
                .localSourceControl(path: "/barPkg", requirement: .upToNextMajor(from: "2.0.0")),
            ],
            targets: [
                try TargetDescription(name: "exe",
                                  dependencies: ["Logging",
                                                 .product(name: "Foo",
                                                          package: "fooPkg",
                                                          moduleAliases: ["Logging": "FooLogging"]
                                                         ),
                                                 .product(name: "Bar",
                                                          package: "barPkg",
                                                          moduleAliases: ["Logging": "BarLogging"]
                                                         )
                                                ]),
                try TargetDescription(name: "Logging", dependencies: []),
            ])
        let contents = try manifest.generateManifestFileContents(packageDirectory: manifest.path.parentDirectory)
        let parts =
        """
            dependencies: [
                "Logging",
                .product(name: "Foo", package: "fooPkg", moduleAliases: [
                    "Logging": "FooLogging"
                ]),
                .product(name: "Bar", package: "barPkg", moduleAliases: [
                    "Logging": "BarLogging"
                ])
            ]
        """
        let trimmedContents = contents.components(separatedBy: CharacterSet.whitespacesAndNewlines)
        let trimmedParts = parts.components(separatedBy: CharacterSet.whitespacesAndNewlines)
        let isContained = trimmedParts.allSatisfy(trimmedContents.contains(_:))
        XCTAssertTrue(isContained)

        try await testManifestWritingRoundTrip(manifestContents: contents, toolsVersion: .v5_8)
    }

    func testUpcomingAndExperimentalFeatures() async throws {
        let manifestContents = """
            // swift-tools-version:5.8
            import PackageDescription

            let package = Package(
                name: "UpcomingAndExperimentalFeatures",
                targets: [
                    .target(
                        name: "MyTool",
                        swiftSettings: [
                            .enableUpcomingFeature("UpcomingFeatureOne"),
                            .enableUpcomingFeature("UpcomingFeatureTwo"),
                            .enableExperimentalFeature("ExperimentalFeature")
                        ]
                    ),
                ]
            )
            """
        try await testManifestWritingRoundTrip(manifestContents: manifestContents, toolsVersion: .v5_8)
    }

    func testPluginNetworkingPermissionGeneration() async throws {
        let manifest = Manifest.createRootManifest(
            displayName: "thisPkg",
            path: "/thisPkg",
            toolsVersion: .v5_9,
            dependencies: [],
            targets: [
                try TargetDescription(name: "MyPlugin", type: .plugin, pluginCapability: .command(intent: .custom(verb: "foo", description: "bar"), permissions: [.allowNetworkConnections(scope: .all(ports: [23, 42, 443, 8080]), reason: "internet good")]))
            ])
        let contents = try manifest.generateManifestFileContents(packageDirectory: manifest.path.parentDirectory)
        try await testManifestWritingRoundTrip(manifestContents: contents, toolsVersion: .v5_9)
    }

    func testManifestGenerationWithSwiftLanguageVersion() async throws {
        try await UserToolchain.default.skipUnlessAtLeastSwift6()
        let manifest = Manifest.createRootManifest(
            displayName: "pkg",
            path: "/pkg",
            toolsVersion: .v6_0,
            dependencies: [],
            targets: [
                try TargetDescription(
                    name: "v5",
                    type: .executable,
                    settings: [
                        .init(tool: .swift, kind: .swiftLanguageMode(.v6))
                    ]
                ),
                try TargetDescription(
                    name: "custom",
                    type: .executable,
                    settings: [
                        .init(tool: .swift, kind: .swiftLanguageMode(.init(string: "5.10")!))
                    ]
                ),
                try TargetDescription(
                    name: "conditional",
                    type: .executable,
                    settings: [
                        .init(tool: .swift, kind: .swiftLanguageMode(.v5), condition: .init(platformNames: ["linux"])),
                        .init(tool: .swift, kind: .swiftLanguageMode(.v4), condition: .init(platformNames: ["macos"], config: "debug"))
                    ]
                )
            ])
        let contents = try manifest.generateManifestFileContents(packageDirectory: manifest.path.parentDirectory)
        try await testManifestWritingRoundTrip(manifestContents: contents, toolsVersion: .v6_0)
    }
}
