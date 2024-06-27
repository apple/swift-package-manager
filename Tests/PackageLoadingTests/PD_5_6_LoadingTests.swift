//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2022 Apple Inc. and the Swift project authors
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

final class PackageDescription5_6LoadingTests: PackageDescriptionLoadingTests {
    override var toolsVersion: ToolsVersion {
        .v5_6
    }

    func testSourceControlDependencies() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "MyPackage",
               dependencies: [
                    // from
                   .package(name: "foo1", url: "http://localhost/foo1", from: "1.1.1"),
                   .package(url: "http://localhost/foo2", from: "1.1.1"),
                    // upToNextMajor
                   .package(name: "bar1", url: "http://localhost/bar1", .upToNextMajor(from: "1.1.1")),
                   .package(url: "http://localhost/bar2", .upToNextMajor(from: "1.1.1")),
                    // upToNextMinor
                   .package(name: "baz1", url: "http://localhost/baz1", .upToNextMinor(from: "1.1.1")),
                   .package(url: "http://localhost/baz2", .upToNextMinor(from: "1.1.1")),
                    // exact
                   .package(name: "qux1", url: "http://localhost/qux1", .exact("1.1.1")),
                   .package(url: "http://localhost/qux2", .exact("1.1.1")),
                   .package(url: "http://localhost/qux3", exact: "1.1.1"),
                    // branch
                   .package(name: "quux1", url: "http://localhost/quux1", .branch("main")),
                   .package(url: "http://localhost/quux2", .branch("main")),
                   .package(url: "http://localhost/quux3", branch: "main"),
                    // revision
                   .package(name: "quuz1", url: "http://localhost/quuz1", .revision("abcdefg")),
                   .package(url: "http://localhost/quuz2", .revision("abcdefg")),
                   .package(url: "http://localhost/quuz3", revision: "abcdefg"),
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertFalse(observability.diagnostics.hasErrors)
        XCTAssertNoDiagnostics(validationDiagnostics)

        let deps = Dictionary(uniqueKeysWithValues: manifest.dependencies.map{ ($0.identity.description, $0) })
        XCTAssertEqual(deps["foo1"], .remoteSourceControl(identity: .plain("foo1"), deprecatedName: "foo1", url: "http://localhost/foo1", requirement: .range("1.1.1" ..< "2.0.0")))
        XCTAssertEqual(deps["foo2"], .remoteSourceControl(identity: .plain("foo2"), url: "http://localhost/foo2", requirement: .range("1.1.1" ..< "2.0.0")))
        XCTAssertEqual(deps["bar1"], .remoteSourceControl(identity: .plain("bar1"), deprecatedName: "bar1", url: "http://localhost/bar1", requirement: .range("1.1.1" ..< "2.0.0")))
        XCTAssertEqual(deps["bar2"], .remoteSourceControl(identity: .plain("bar2"), url: "http://localhost/bar2", requirement: .range("1.1.1" ..< "2.0.0")))
        XCTAssertEqual(deps["baz1"], .remoteSourceControl(identity: .plain("baz1"), deprecatedName: "baz1", url: "http://localhost/baz1", requirement: .range("1.1.1" ..< "1.2.0")))
        XCTAssertEqual(deps["baz2"], .remoteSourceControl(identity: .plain("baz2"), url: "http://localhost/baz2", requirement: .range("1.1.1" ..< "1.2.0")))
        XCTAssertEqual(deps["qux1"], .remoteSourceControl(identity: .plain("qux1"), deprecatedName: "qux1", url: "http://localhost/qux1", requirement: .exact("1.1.1")))
        XCTAssertEqual(deps["qux2"], .remoteSourceControl(identity: .plain("qux2"), url: "http://localhost/qux2", requirement: .exact("1.1.1")))
        XCTAssertEqual(deps["qux3"], .remoteSourceControl(identity: .plain("qux3"), url: "http://localhost/qux3", requirement: .exact("1.1.1")))
        XCTAssertEqual(deps["quux1"], .remoteSourceControl(identity: .plain("quux1"), deprecatedName: "quux1", url: "http://localhost/quux1", requirement: .branch("main")))
        XCTAssertEqual(deps["quux2"], .remoteSourceControl(identity: .plain("quux2"), url: "http://localhost/quux2", requirement: .branch("main")))
        XCTAssertEqual(deps["quux3"], .remoteSourceControl(identity: .plain("quux3"), url: "http://localhost/quux3", requirement: .branch("main")))
        XCTAssertEqual(deps["quuz1"], .remoteSourceControl(identity: .plain("quuz1"), deprecatedName: "quuz1", url: "http://localhost/quuz1", requirement: .revision("abcdefg")))
        XCTAssertEqual(deps["quuz2"], .remoteSourceControl(identity: .plain("quuz2"), url: "http://localhost/quuz2", requirement: .revision("abcdefg")))
        XCTAssertEqual(deps["quuz3"], .remoteSourceControl(identity: .plain("quuz3"), url: "http://localhost/quuz3", requirement: .revision("abcdefg")))
    }

    func testBuildToolPluginTarget() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "Foo",
               targets: [
                   .plugin(
                       name: "Foo",
                       capability: .buildTool()
                    )
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.targets[0].type, .plugin)
        XCTAssertEqual(manifest.targets[0].pluginCapability, .buildTool)
    }

    func testPluginTargetCustomization() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "Foo",
               targets: [
                   .plugin(
                       name: "Foo",
                       capability: .buildTool(),
                       path: "Sources/Foo",
                       exclude: ["IAmOut.swift"],
                       sources: ["CountMeIn.swift"]
                    )
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.targets[0].type, .plugin)
        XCTAssertEqual(manifest.targets[0].pluginCapability, .buildTool)
        XCTAssertEqual(manifest.targets[0].path, "Sources/Foo")
        XCTAssertEqual(manifest.targets[0].exclude, ["IAmOut.swift"])
        XCTAssertEqual(manifest.targets[0].sources, ["CountMeIn.swift"])
    }

    func testCustomPlatforms() async throws {
        // One custom platform.
        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   platforms: [
                       .custom("customos", versionString: "1.0"),
                   ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssertNoDiagnostics(validationDiagnostics)

            XCTAssertEqual(manifest.platforms, [
                PlatformDescription(name: "customos", version: "1.0"),
            ])
        }

        // Two custom platforms.
        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   platforms: [
                       .custom("customos", versionString: "1.0"),
                       .custom("anothercustomos", versionString: "2.3"),
                   ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssertNoDiagnostics(validationDiagnostics)

            XCTAssertEqual(manifest.platforms, [
                PlatformDescription(name: "customos", version: "1.0"),
                PlatformDescription(name: "anothercustomos", version: "2.3"),
            ])
        }

        // Invalid custom platform version.
        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   platforms: [
                       .custom("customos", versionString: "xx"),
                   ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            do {
                _  = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
                XCTFail("manifest loading unexpectedly did not throw an error")
            } catch ManifestParseError.runtimeManifestErrors(let errors) {
                XCTAssertEqual(errors, ["invalid custom platform version xx; xx should be a positive integer"])
            }
        }
    }

    /// Tests use of Context.current.packageDirectory
    func testPackageContextName() async throws {
        let content = """
            import PackageDescription
            let package = Package(name: Context.packageDirectory)
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertNotNil(parsedManifest)
        XCTAssertNotNil(parsedManifest.parentDirectory)
        let name = try XCTUnwrap(parsedManifest.parentDirectory).pathString
        XCTAssertEqual(manifest.displayName, name)
    }

    /// Tests access to the package's directory contents.
    func testPackageContextDirectory() async throws {
        #if os(Windows)
        throw XCTSkip("Skipping since this tests does not fully work without the VFS overlay which is currently disabled on Windows")
        #endif

        let content = """
            import PackageDescription
            import Foundation

            let fileManager = FileManager.default
            let contents = (try? fileManager.contentsOfDirectory(atPath: Context.packageDirectory)) ?? []

            let package = Package(name: contents.joined(separator: ","))
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        // FIXME: temporary filter a diagnostic that shows up on macOS 14.0
        XCTAssertNoDiagnostics(observability.diagnostics.filter { !$0.message.contains("coreservicesd") })
        XCTAssertNoDiagnostics(validationDiagnostics)

        let files = manifest.displayName.split(separator: ",").map(String.init)
        // Since we're loading `/Package.swift` in these tests, the context's package directory is supposed to be /.
        let expectedFiles = try FileManager.default.contentsOfDirectory(atPath: "/")
        XCTAssertEqual(files, expectedFiles)
    }

    func testCommandPluginTarget() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "Foo",
               targets: [
                   .plugin(
                       name: "Foo",
                       capability: .command(
                           intent: .custom(verb: "mycmd", description: "helpful description of mycmd"),
                           permissions: [ .writeToPackageDirectory(reason: "YOLO") ]
                       )
                   )
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.targets[0].type, .plugin)
        XCTAssertEqual(manifest.targets[0].pluginCapability, .command(intent: .custom(verb: "mycmd", description: "helpful description of mycmd"), permissions: [.writeToPackageDirectory(reason: "YOLO")]))
    }
}
