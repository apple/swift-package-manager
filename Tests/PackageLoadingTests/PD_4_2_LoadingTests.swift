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
import Dispatch
import PackageLoading
import PackageModel
import _InternalTestSupport
import XCTest

import class TSCBasic.InMemoryFileSystem
import enum TSCBasic.PathValidationError

import struct TSCUtility.Version

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
final class PackageDescription4_2LoadingTests: PackageDescriptionLoadingTests {
    override var toolsVersion: ToolsVersion {
        .v4_2
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
                    .package(url: "\(AbsolutePath("/foo1").escapedPathString)", from: "1.0.0"),
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

    func testSwiftLanguageVersions() async throws {
        // Ensure integer values are not accepted.
        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   swiftLanguageVersions: [3, 4]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.invalidManifestFormat(let message, _, _) = error {
                    XCTAssertMatch(
                        message,
                            .and(
                                .contains("'init(name:pkgConfig:providers:products:dependencies:targets:swiftLanguageVersions:cLanguageStandard:cxxLanguageStandard:)' is unavailable"),
                                    .contains("was obsoleted in PackageDescription 4.2")
                            )
                    )
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
        }

        // Check when Swift language versions is empty.
        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   swiftLanguageVersions: []
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssertNoDiagnostics(validationDiagnostics)

            XCTAssertEqual(manifest.swiftLanguageVersions, [])
        }

        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   swiftLanguageVersions: [.v3, .v4, .v4_2, .version("5")]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssertNoDiagnostics(validationDiagnostics)

            XCTAssertEqual(
                manifest.swiftLanguageVersions,
                [.v3, .v4, .v4_2, SwiftLanguageVersion(string: "5")!]
            )
        }

        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   swiftLanguageVersions: [.v5]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.invalidManifestFormat(let message, _, _) = error {
                    XCTAssertMatch(message, .contains("is unavailable"))
                    XCTAssertMatch(message, .contains("was introduced in PackageDescription 5"))
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testPlatforms() async throws {
        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   platforms: nil
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.invalidManifestFormat(let message, _, _) = error {
                    XCTAssertMatch(message, .contains("is unavailable"))
                    XCTAssertMatch(message, .contains("was introduced in PackageDescription 5"))
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
                   platforms: [.macOS(.v10_10)]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.invalidManifestFormat(let message, _, _) = error {
                    XCTAssertMatch(message, .contains("is unavailable"))
                    XCTAssertMatch(message, .contains("was introduced in PackageDescription 5"))
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
                       swiftSettings: [
                           .define("SWIFT", .when(configuration: .release)),
                       ],
                       linkerSettings: [
                           .linkedLibrary("libz"),
                       ]
                   ),
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
            if case ManifestParseError.invalidManifestFormat(let message, _, _) = error {
                XCTAssertMatch(message, .contains("is unavailable"))
                XCTAssertMatch(message, .contains("was introduced in PackageDescription 5"))
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testPackageDependencies() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "Foo",
               dependencies: [
                   .package(url: "\(AbsolutePath("/foo1").escapedPathString)", from: "1.0.0"),
                   .package(url: "\(AbsolutePath("/foo2").escapedPathString)", .revision("58e9de4e7b79e67c72a46e164158e3542e570ab6")),
                   .package(path: "../foo3"),
                   .package(path: "\(AbsolutePath("/path/to/foo4").escapedPathString)"),
                   .package(url: "\(AbsolutePath("/foo5").escapedPathString)", .exact("1.2.3")),
                   .package(url: "\(AbsolutePath("/foo6").escapedPathString)", "1.2.3"..<"2.0.0"),
                   .package(url: "\(AbsolutePath("/foo7").escapedPathString)", .branch("master")),
                   .package(url: "\(AbsolutePath("/foo8").escapedPathString)", .upToNextMinor(from: "1.3.4")),
                   .package(url: "\(AbsolutePath("/foo9").escapedPathString)", .upToNextMajor(from: "1.3.4")),
                   .package(path: "~/path/to/foo10"),
                   .package(path: "~foo11"),
                   .package(path: "~/path/to/~/foo12"),
                   .package(path: "~"),
                   .package(path: "file:///path/to/foo13"),
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        let deps = Dictionary(uniqueKeysWithValues: manifest.dependencies.map{ ($0.identity.description, $0) })
        XCTAssertEqual(deps["foo1"], .localSourceControl(path: "/foo1", requirement: .upToNextMajor(from: "1.0.0")))
        XCTAssertEqual(deps["foo2"], .localSourceControl(path: "/foo2", requirement: .revision("58e9de4e7b79e67c72a46e164158e3542e570ab6")))

        if case .fileSystem(let dep) = deps["foo3"] {
            XCTAssertEqual(dep.path, "/foo3")
        } else {
            XCTFail("expected to be local dependency")
        }

        if case .fileSystem(let dep) = deps["foo4"] {
            XCTAssertEqual(dep.path, "/path/to/foo4")
        } else {
            XCTFail("expected to be local dependency")
        }

        XCTAssertEqual(deps["foo5"], .localSourceControl(path: "/foo5", requirement: .exact("1.2.3")))
        XCTAssertEqual(deps["foo6"], .localSourceControl(path: "/foo6", requirement: .range("1.2.3"..<"2.0.0")))
        XCTAssertEqual(deps["foo7"], .localSourceControl(path: "/foo7", requirement: .branch("master")))
        XCTAssertEqual(deps["foo8"], .localSourceControl(path: "/foo8", requirement: .upToNextMinor(from: "1.3.4")))
        XCTAssertEqual(deps["foo9"], .localSourceControl(path: "/foo9", requirement: .upToNextMajor(from: "1.3.4")))

        let homeDir = "/home/user"
        if case .fileSystem(let dep) = deps["foo10"] {
            XCTAssertEqual(dep.path, try AbsolutePath(validating: "\(homeDir)/path/to/foo10"))
        } else {
            XCTFail("expected to be local dependency")
        }

        if case .fileSystem(let dep) = deps["~foo11"] {
            XCTAssertEqual(dep.path, "/~foo11")
        } else {
            XCTFail("expected to be local dependency")
        }

        if case .fileSystem(let dep) = deps["foo12"] {
            XCTAssertEqual(dep.path, try AbsolutePath(validating: "\(homeDir)/path/to/~/foo12"))
        } else {
            XCTFail("expected to be local dependency")
        }

        if case .fileSystem(let dep) = deps["~"] {
            XCTAssertEqual(dep.path, "/~")
        } else {
            XCTFail("expected to be local dependency")
        }

        if case .fileSystem(let dep) = deps["foo13"] {
            XCTAssertEqual(dep.path, "/path/to/foo13")
        } else {
            XCTFail("expected to be local dependency")
        }
    }

    func testSystemLibraryTargets() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "Foo",
                targets: [
                    .target(
                        name: "foo",
                        dependencies: ["bar"]),
                    .systemLibrary(
                        name: "bar",
                        pkgConfig: "libbar",
                        providers: [
                            .brew(["libgit"]),
                            .apt(["a", "b"]),
                        ]),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        let foo = manifest.targetMap["foo"]!
        XCTAssertEqual(foo.name, "foo")
        XCTAssertFalse(foo.isTest)
        XCTAssertEqual(foo.type, .regular)
        XCTAssertEqual(foo.dependencies, ["bar"])

        let bar = manifest.targetMap["bar"]!
        XCTAssertEqual(bar.name, "bar")
        XCTAssertEqual(bar.type, .system)
        XCTAssertEqual(bar.pkgConfig, "libbar")
        XCTAssertEqual(bar.providers, [.brew(["libgit"]), .apt(["a", "b"])])
    }

    /// Check that we load the manifest appropriate for the current version, if
    /// version specific customization is used.
    func testVersionSpecificLoading() async throws {
        let bogusManifest = "THIS WILL NOT PARSE"
        let trivialManifest =
        """
        // swift-tools-version:4.2
        import PackageDescription
        let package = Package(name: \"Trivial\")
        """
        // Check at each possible spelling.
        let currentVersion = SwiftVersion.current
        let possibleSuffixes = [
            "\(currentVersion.major).\(currentVersion.minor).\(currentVersion.patch)",
            "\(currentVersion.major).\(currentVersion.minor)",
            "\(currentVersion.major)"
        ]
        for (i, key) in possibleSuffixes.enumerated() {
            let root = AbsolutePath.root
            // Create a temporary FS with the version we want to test, and everything else as bogus.
            let fs = InMemoryFileSystem()
            // Write the good manifests.
            try fs.writeFileContents(
                root.appending(component: Manifest.basename + "@swift-\(key).swift"),
                string: trivialManifest)
            // Write the bad manifests.
            let badManifests = [Manifest.filename] + possibleSuffixes[i+1 ..< possibleSuffixes.count].map{
                Manifest.basename + "@swift-\($0).swift"
            }
            try badManifests.forEach {
                try fs.writeFileContents(
                    root.appending(component: $0),
                    string: bogusManifest
                )
            }
            // Check we can load the repository.
            let manifest = try await manifestLoader.load(
                packagePath: root,
                packageKind: .root(.root),
                currentToolsVersion: .v4_2,
                fileSystem: fs,
                observabilityScope: ObservabilitySystem.NOOP
            )
            XCTAssertEqual(manifest.displayName, "Trivial")
        }
    }

    // Check that ancient `Package@swift-3.swift` manifests are properly treated as 3.1 even without a tools-version comment.
    func testVersionSpecificLoadingOfVersion3Manifest() async throws {
        // Create a temporary FS to hold the package manifests.
        let fs = InMemoryFileSystem()
        let observability = ObservabilitySystem.makeForTesting()

        // Write a regular manifest with a tools version comment, and a `Package@swift-3.swift` manifest without one.
        let packageDir = AbsolutePath.root
        let manifestContents = "import PackageDescription\nlet package = Package(name: \"Trivial\")"
        try fs.writeFileContents(
            packageDir.appending(component: Manifest.basename + ".swift"),
            string: "// swift-tools-version:4.0\n" + manifestContents
        )
        try fs.writeFileContents(
            packageDir.appending(component: Manifest.basename + "@swift-3.swift"),
            string: manifestContents
        )
        // Check we can load the manifest.
        let manifest = try await manifestLoader.load(packagePath: packageDir, packageKind: .root(packageDir), currentToolsVersion: .v4_2, fileSystem: fs, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertEqual(manifest.displayName, "Trivial")

        // Switch it around so that the main manifest is now the one that doesn't have a comment.
        try fs.writeFileContents(
            packageDir.appending(component: Manifest.basename + ".swift"),
            string: manifestContents
        )
        try fs.writeFileContents(
            packageDir.appending(component: Manifest.basename + "@swift-4.swift"),
            string: "// swift-tools-version:4.0\n" + manifestContents
        )
        // Check we can load the manifest.
        let manifest2 = try await manifestLoader.load(packagePath: packageDir, packageKind: .root(packageDir), currentToolsVersion: .v4_2, fileSystem: fs, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertEqual(manifest2.displayName, "Trivial")
    }

    func testRuntimeManifestErrors() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Trivial",
                products: [
                    .executable(name: "tool", targets: ["tool"]),
                    .library(name: "Foo", targets: ["Foo"]),
                ],
                dependencies: [
                    .package(url: "/foo1", from: "1.0,0"),
                ],
                targets: [
                    .target(
                        name: "foo",
                        dependencies: ["dep1", .product(name: "product"), .target(name: "target")]),
                    .testTarget(
                        name: "bar",
                        dependencies: ["foo"]),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
            if case ManifestParseError.runtimeManifestErrors(let errors) = error {
                XCTAssertEqual(errors, ["Invalid semantic version string '1.0,0'"])
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testNotAbsoluteDependencyPath() async throws {
        let content = """
        import PackageDescription
        let package = Package(
            name: "Trivial",
            dependencies: [
                .package(path: "https://someurl.com"),
            ],
            targets: [
                .target(
                    name: "foo",
                    dependencies: []),
            ]
        )
        """

        let observability = ObservabilitySystem.makeForTesting()
        await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
            if case ManifestParseError.invalidManifestFormat(let message, let diagnosticFile, _) = error {
                XCTAssertNil(diagnosticFile)
                XCTAssertEqual(message, "'https://someurl.com' is not a valid path for path-based dependencies; use relative or absolute path instead.")
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testFileURLErrors() async throws {
        enum ExpectedError {
          case invalidAbsolutePath
          case relativePath
          case unsupportedHostname

          var manifestError: ManifestParseError? {
            switch self {
            case .invalidAbsolutePath:
              return nil
            case .relativePath:
              return .invalidManifestFormat("file:// URLs cannot be relative, did you mean to use '.package(path:)'?", diagnosticFile: nil, compilerCommandLine: nil)
            case .unsupportedHostname:
              return .invalidManifestFormat("file:// URLs with hostnames are not supported, are you missing a '/'?", diagnosticFile: nil, compilerCommandLine: nil)
            }
          }

          var pathError: TSCBasic.PathValidationError? {
            switch self {
            case .invalidAbsolutePath:
              return .invalidAbsolutePath("")
            default:
              return nil
            }
          }
        }

        let urls: [(String, ExpectedError)] = [
          ("file://../best", .relativePath), // Possible attempt at a relative path.
          ("file://somehost/bar", .unsupportedHostname), // Obviously non-local.
          ("file://localhost/bar", .unsupportedHostname), // Local but non-trivial (e.g. on Windows, this is a UNC path).
          ("file://", .invalidAbsolutePath) // Invalid path.
        ]
        for (url, expectedError) in urls {
            let content = """
            import PackageDescription
            let package = Package(
                name: "Trivial",
                dependencies: [
                    .package(url: "\(url)", from: "1.0.0"),
                ],
                targets: [
                    .target(
                        name: "foo",
                        dependencies: []),
                ]
            )
            """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                switch error {
                case is ManifestParseError:
                    XCTAssertEqual(error as? ManifestParseError, expectedError.manifestError)
                case is TSCBasic.PathValidationError:
                    XCTAssertEqual(error.localizedDescription, expectedError.pathError?.localizedDescription)
                default:
                    XCTFail("unhandled error type: \(error)")
                }
            }
        }
    }

    func testProductTargetNotFound() async throws {
        let content = """
            import PackageDescription

            let package = Package(
                name: "Foo",
                products: [
                    .library(name: "Product", targets: ["B"]),
                ],
                targets: [
                    .target(name: "A"),
                    .target(name: "b"),
                    .target(name: "C"),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (_, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        testDiagnostics(validationDiagnostics) { result in
            result.check(diagnostic: .contains("target 'B' referenced in product 'Product' could not be found; valid targets are: 'A', 'C', 'b'"), severity: .error)
        }
    }

    // run this with TSAN/ASAN to detect concurrency issues
    func testConcurrencyWithWarmup() async throws {
        try await testWithTemporaryDirectory { path in
            let total = 1000
            let manifestPath = path.appending(components: "pkg", "Package.swift")
            try localFileSystem.createDirectory(manifestPath.parentDirectory)
            try localFileSystem.writeFileContents(
                manifestPath,
                string: """
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

            let observability = ObservabilitySystem.makeForTesting()
            let delegate = ManifestTestDelegate()
            let manifestLoader = ManifestLoader(toolchain: try UserToolchain.default, cacheDir: path, delegate: delegate)
            let identityResolver = DefaultIdentityResolver()
            let dependencyMapper = DefaultDependencyMapper(identityResolver: identityResolver)

            // warm up caches
            let manifest = try await manifestLoader.load(
                manifestPath: manifestPath,
                manifestToolsVersion: .v4_2,
                packageIdentity: .plain("Trivial"),
                packageKind: .fileSystem(manifestPath.parentDirectory),
                packageLocation: manifestPath.pathString,
                packageVersion: nil,
                identityResolver: identityResolver,
                dependencyMapper: dependencyMapper,
                fileSystem: localFileSystem,
                observabilityScope: observability.topScope,
                delegateQueue: .sharedConcurrent,
                callbackQueue: .sharedConcurrent
            )

            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssertEqual(manifest.displayName, "Trivial")
            XCTAssertEqual(manifest.targets[0].name, "foo")

            for _ in 0 ..< total {
                let manifest = try await manifestLoader.load(
                    manifestPath: manifestPath,
                    manifestToolsVersion: .v4_2,
                    packageIdentity: .plain("Trivial"),
                    packageKind: .fileSystem(manifestPath.parentDirectory),
                    packageLocation: manifestPath.pathString,
                    packageVersion: nil,
                    identityResolver: identityResolver,
                    dependencyMapper: dependencyMapper,
                    fileSystem: localFileSystem,
                    observabilityScope: observability.topScope,
                    delegateQueue: .sharedConcurrent,
                    callbackQueue: .sharedConcurrent
                )

                XCTAssertNoDiagnostics(observability.diagnostics)
                XCTAssertEqual(manifest.displayName, "Trivial")
                XCTAssertEqual(manifest.targets[0].name, "foo")
            }

            try await XCTAssertAsyncEqual(try await delegate.loaded(timeout: .seconds(1)).count, total+1)
            XCTAssertFalse(observability.hasWarningDiagnostics, observability.diagnostics.description)
            XCTAssertFalse(observability.hasErrorDiagnostics, observability.diagnostics.description)
        }
    }

    // run this with TSAN/ASAN to detect concurrency issues
    func testConcurrencyNoWarmUp() async throws {
#if os(Windows)
        // FIXME: does this actually trigger only on Windows or are other
        // platforms just getting lucky?  I'm feeling lucky.
        throw XCTSkip("Foundation Process.terminationStatus race condition (apple/swift-corelibs-foundation#4589")
#else
        try XCTSkipIfCI()

        try await testWithTemporaryDirectory { path in
            let total = 100
            let observability = ObservabilitySystem.makeForTesting()
            let delegate = ManifestTestDelegate()
            let manifestLoader = ManifestLoader(toolchain: try UserToolchain.default, cacheDir: path, delegate: delegate)
            let identityResolver = DefaultIdentityResolver()
            let dependencyMapper = DefaultDependencyMapper(identityResolver: identityResolver)

            for _ in 0 ..< total {
                let random = Int.random(in: 0 ... total / 4)
                let manifestPath = path.appending(components: "pkg-\(random)", "Package.swift")
                if !localFileSystem.exists(manifestPath) {
                    try localFileSystem.createDirectory(manifestPath.parentDirectory)
                    try localFileSystem.writeFileContents(
                        manifestPath,
                        string: """
                        import PackageDescription
                        let package = Package(
                            name: "Trivial-\(random)",
                            targets: [
                                .target(
                                    name: "foo-\(random)",
                                    dependencies: []),
                            ]
                        )
                        """
                    )
                }

                let manifest = try await manifestLoader.load(
                    manifestPath: manifestPath,
                    manifestToolsVersion: .v4_2,
                    packageIdentity: .plain("Trivial-\(random)"),
                    packageKind: .fileSystem(manifestPath.parentDirectory),
                    packageLocation: manifestPath.pathString,
                    packageVersion: nil,
                    identityResolver: identityResolver,
                    dependencyMapper: dependencyMapper,
                    fileSystem: localFileSystem,
                    observabilityScope: observability.topScope,
                    delegateQueue: .sharedConcurrent,
                    callbackQueue: .sharedConcurrent
                )

                XCTAssertEqual(manifest.displayName, "Trivial-\(random)")
                XCTAssertEqual(manifest.targets[0].name, "foo-\(random)")
            }

            try await XCTAssertAsyncEqual(try await delegate.loaded(timeout: .seconds(1)).count, total)
            XCTAssertFalse(observability.hasWarningDiagnostics, observability.diagnostics.description)
            XCTAssertFalse(observability.hasErrorDiagnostics, observability.diagnostics.description)
        }
#endif
    }
}
