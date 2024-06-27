//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Commands
import Foundation
import PackageLoading
import PackageModel
import PackageRegistry
@testable import PackageRegistryCommand
import PackageSigning
import _InternalTestSupport
import TSCclibc // for SPM_posix_spawn_file_actions_addchdir_np_supported
import Workspace
import XCTest

import enum TSCBasic.JSON
import struct Basics.AsyncProcessResult

let defaultRegistryBaseURL = URL("https://packages.example.com")
let customRegistryBaseURL = URL("https://custom.packages.example.com")

final class PackageRegistryCommandTests: CommandsTestCase {
    @discardableResult
    private func execute(
        _ args: [String],
        packagePath: AbsolutePath? = nil,
        env: Environment? = nil
    ) async throws -> (stdout: String, stderr: String) {
        var environment = env ?? [:]
        // don't ignore local packages when caching
        environment["SWIFTPM_TESTS_PACKAGECACHE"] = "1"
        return try await SwiftPM.Registry.execute(
            args,
            packagePath: packagePath,
            env: environment
        )
    }

    func testUsage() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the
        // plugin APIs require).
        try XCTSkipIf(
            !UserToolchain.default.supportsSwiftConcurrency(),
            "skipping because test environment doesn't support concurrency"
        )

        let stdout = try await execute(["-help"]).stdout
        XCTAssert(stdout.contains("USAGE: swift package-registry"), "got stdout:\n" + stdout)
    }

    func testSeeAlso() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the
        // plugin APIs require).
        try XCTSkipIf(
            !UserToolchain.default.supportsSwiftConcurrency(),
            "skipping because test environment doesn't support concurrency"
        )

        let stdout = try await execute(["--help"]).stdout
        XCTAssert(stdout.contains("SEE ALSO: swift package"), "got stdout:\n" + stdout)
    }

    func testVersion() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the
        // plugin APIs require).
        try XCTSkipIf(
            !UserToolchain.default.supportsSwiftConcurrency(),
            "skipping because test environment doesn't support concurrency"
        )

        let stdout = try await execute(["--version"]).stdout
        XCTAssert(stdout.contains("Swift Package Manager"), "got stdout:\n" + stdout)
    }

    func testLocalConfiguration() async throws {
        try await fixture(name: "DependencyResolution/External/Simple") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")
            let configurationFilePath = AbsolutePath(
                ".swiftpm/configuration/registries.json",
                relativeTo: packageRoot
            )

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))

            // Set default registry
            do {
                try await execute(["set", "\(defaultRegistryBaseURL)"], packagePath: packageRoot)

                let json = try JSON(data: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 1)
                XCTAssertEqual(
                    json["registries"]?.dictionary?["[default]"]?.dictionary?["url"]?.string,
                    "\(defaultRegistryBaseURL)"
                )
                XCTAssertEqual(json["version"], .int(1))
            }

            // Set new default registry
            do {
                try await execute(["set", "\(customRegistryBaseURL)"], packagePath: packageRoot)

                let json = try JSON(data: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 1)
                XCTAssertEqual(
                    json["registries"]?.dictionary?["[default]"]?.dictionary?["url"]?.string,
                    "\(customRegistryBaseURL)"
                )
                XCTAssertEqual(json["version"], .int(1))
            }

            // Set default registry with allow-insecure-http option
            do {
                try await execute(["set", "\(customRegistryBaseURL)", "--allow-insecure-http"], packagePath: packageRoot)

                let json = try JSON(data: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 1)
                XCTAssertEqual(
                    json["registries"]?.dictionary?["[default]"]?.dictionary?["url"]?.string,
                    "\(customRegistryBaseURL)"
                )
                XCTAssertEqual(json["version"], .int(1))
            }

            // Unset default registry
            do {
                try await execute(["unset"], packagePath: packageRoot)

                let json = try JSON(data: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 0)
                XCTAssertEqual(json["version"], .int(1))
            }

            // Set registry for "foo" scope
            do {
                try await execute(
                    ["set", "\(customRegistryBaseURL)", "--scope", "foo"],
                    packagePath: packageRoot
                )

                let json = try JSON(data: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 1)
                XCTAssertEqual(
                    json["registries"]?.dictionary?["foo"]?.dictionary?["url"]?.string,
                    "\(customRegistryBaseURL)"
                )
                XCTAssertEqual(json["version"], .int(1))
            }

            // Set registry for "bar" scope
            do {
                try await execute(
                    ["set", "\(customRegistryBaseURL)", "--scope", "bar"],
                    packagePath: packageRoot
                )

                let json = try JSON(data: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 2)
                XCTAssertEqual(
                    json["registries"]?.dictionary?["foo"]?.dictionary?["url"]?.string,
                    "\(customRegistryBaseURL)"
                )
                XCTAssertEqual(
                    json["registries"]?.dictionary?["bar"]?.dictionary?["url"]?.string,
                    "\(customRegistryBaseURL)"
                )
                XCTAssertEqual(json["version"], .int(1))
            }

            // Unset registry for "foo" scope
            do {
                try await execute(["unset", "--scope", "foo"], packagePath: packageRoot)

                let json = try JSON(data: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 1)
                XCTAssertEqual(
                    json["registries"]?.dictionary?["bar"]?.dictionary?["url"]?.string,
                    "\(customRegistryBaseURL)"
                )
                XCTAssertEqual(json["version"], .int(1))
            }

            XCTAssertTrue(localFileSystem.exists(configurationFilePath))
        }
    }

    // TODO: Test global configuration

    func testSetMissingURL() async throws {
        try await fixture(name: "DependencyResolution/External/Simple") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")
            let configurationFilePath = AbsolutePath(
                ".swiftpm/configuration/registries.json",
                relativeTo: packageRoot
            )

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))

            // Set default registry
            await XCTAssertAsyncThrowsError(try await execute(["set", "--scope", "foo"], packagePath: packageRoot))

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))
        }
    }

    func testSetInvalidURL() async throws {
        try await fixture(name: "DependencyResolution/External/Simple") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")
            let configurationFilePath = AbsolutePath(
                ".swiftpm/configuration/registries.json",
                relativeTo: packageRoot
            )

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))

            // Set default registry
            await XCTAssertAsyncThrowsError(try await execute(["set", "invalid"], packagePath: packageRoot))

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))
        }
    }

    func testSetInsecureURL() async throws {
        try await fixture(name: "DependencyResolution/External/Simple") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")
            let configurationFilePath = AbsolutePath(
                ".swiftpm/configuration/registries.json",
                relativeTo: packageRoot
            )

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))

            // Set default registry
            await XCTAssertAsyncThrowsError(try await execute(["set", "http://package.example.com"], packagePath: packageRoot))

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))
        }
    }

    func testSetAllowedInsecureURL() async throws {
        try await fixture(name: "DependencyResolution/External/Simple") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")
            let configurationFilePath = AbsolutePath(
                ".swiftpm/configuration/registries.json",
                relativeTo: packageRoot
            )

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))

            // Set default registry
            try await execute(["set", "http://package.example.com", "--allow-insecure-http"], packagePath: packageRoot)

            XCTAssertTrue(localFileSystem.exists(configurationFilePath))
        }
    }

    func testSetInvalidScope() async throws {
        try await fixture(name: "DependencyResolution/External/Simple") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")
            let configurationFilePath = AbsolutePath(
                ".swiftpm/configuration/registries.json",
                relativeTo: packageRoot
            )

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))

            // Set default registry
            do {
                await XCTAssertAsyncThrowsError(try await execute(
                    ["set", "--scope", "_invalid_", "\(defaultRegistryBaseURL)"],
                    packagePath: packageRoot
                ))
            }

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))
        }
    }

    func testUnsetMissingEntry() async throws {
        try await fixture(name: "DependencyResolution/External/Simple") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")
            let configurationFilePath = AbsolutePath(
                ".swiftpm/configuration/registries.json",
                relativeTo: packageRoot
            )

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))

            // Set default registry
            do {
                try await execute(["set", "\(defaultRegistryBaseURL)"], packagePath: packageRoot)

                let json = try JSON(data: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 1)
                XCTAssertEqual(
                    json["registries"]?.dictionary?["[default]"]?.dictionary?["url"]?.string,
                    "\(defaultRegistryBaseURL)"
                )
                XCTAssertEqual(json["version"], .int(1))
            }

            // Unset registry for missing "baz" scope
            do {
                await XCTAssertAsyncThrowsError(try await execute(["unset", "--scope", "baz"], packagePath: packageRoot))

                let json = try JSON(data: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 1)
                XCTAssertEqual(
                    json["registries"]?.dictionary?["[default]"]?.dictionary?["url"]?.string,
                    "\(defaultRegistryBaseURL)"
                )
                XCTAssertEqual(json["version"], .int(1))
            }

            XCTAssertTrue(localFileSystem.exists(configurationFilePath))
        }
    }

    // TODO: Test example with login and password

    func testArchiving() async throws {
        #if os(Linux)
        // needed for archiving
        guard SPM_posix_spawn_file_actions_addchdir_np_supported() else {
            throw XCTSkip("working directory not supported on this platform")
        }
        #endif

        let observability = ObservabilitySystem.makeForTesting()

        let packageIdentity = PackageIdentity.plain("org.package")
        let metadataFilename = PackageRegistryCommand.Publish.metadataFilename

        // git repo
        try await withTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("MyPackage")
            try localFileSystem.createDirectory(packageDirectory)

            let initPackage = try InitPackage(
                name: "MyPackage",
                packageType: .executable,
                destinationPath: packageDirectory,
                fileSystem: localFileSystem
            )
            try initPackage.writePackageStructure()
            XCTAssertFileExists(packageDirectory.appending("Package.swift"))

            initGitRepo(packageDirectory)

            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)

            let archivePath = try PackageArchiver.archive(
                packageIdentity: packageIdentity,
                packageVersion: "1.3.5",
                packageDirectory: packageDirectory,
                workingDirectory: workingDirectory,
                workingFilesToCopy: [],
                cancellator: .none,
                observabilityScope: observability.topScope
            )

            try await validatePackageArchive(at: archivePath)
            XCTAssertTrue(archivePath.isDescendant(of: workingDirectory))
        }

        // not a git repo
        try await withTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("MyPackage")
            try localFileSystem.createDirectory(packageDirectory)

            let initPackage = try InitPackage(
                name: "MyPackage",
                packageType: .executable,
                destinationPath: packageDirectory,
                fileSystem: localFileSystem
            )
            try initPackage.writePackageStructure()
            XCTAssertFileExists(packageDirectory.appending("Package.swift"))

            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)

            let archivePath = try PackageArchiver.archive(
                packageIdentity: packageIdentity,
                packageVersion: "1.5.4",
                packageDirectory: packageDirectory,
                workingDirectory: workingDirectory,
                workingFilesToCopy: [],
                cancellator: .none,
                observabilityScope: observability.topScope
            )

            try await validatePackageArchive(at: archivePath)
        }

        // canonical metadata location
        try await withTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("MyPackage")
            try localFileSystem.createDirectory(packageDirectory)

            let initPackage = try InitPackage(
                name: "MyPackage",
                packageType: .executable,
                destinationPath: packageDirectory,
                fileSystem: localFileSystem
            )
            try initPackage.writePackageStructure()
            XCTAssertFileExists(packageDirectory.appending("Package.swift"))

            // metadata file
            try localFileSystem.writeFileContents(
                packageDirectory.appending(component: metadataFilename),
                bytes: ""
            )

            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)

            let archivePath = try PackageArchiver.archive(
                packageIdentity: packageIdentity,
                packageVersion: "0.3.1",
                packageDirectory: packageDirectory,
                workingDirectory: workingDirectory,
                workingFilesToCopy: [],
                cancellator: .none,
                observabilityScope: observability.topScope
            )

            let extractedPath = try await validatePackageArchive(at: archivePath)
            XCTAssertFileExists(extractedPath.appending(component: metadataFilename))
        }

        @discardableResult
        func validatePackageArchive(at archivePath: AbsolutePath) async throws -> AbsolutePath {
            XCTAssertFileExists(archivePath)
            let archiver = ZipArchiver(fileSystem: localFileSystem)
            let extractPath = archivePath.parentDirectory.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(extractPath)
            try await archiver.extract(from: archivePath, to: extractPath)
            try localFileSystem.stripFirstLevel(of: extractPath)
            XCTAssertFileExists(extractPath.appending("Package.swift"))
            return extractPath
        }
    }

    func testPublishingToHTTPRegistry() throws {
        #if os(Linux)
        // needed for archiving
        guard SPM_posix_spawn_file_actions_addchdir_np_supported() else {
            throw XCTSkip("working directory not supported on this platform")
        }
        #endif

        let packageIdentity = "test.my-package"
        let version = "0.1.0"
        let registryURL = "http://packages.example.com"

        _ = try withTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("MyPackage")
            try localFileSystem.createDirectory(packageDirectory)

            let initPackage = try InitPackage(
                name: "MyPackage",
                packageType: .executable,
                destinationPath: packageDirectory,
                fileSystem: localFileSystem
            )
            try initPackage.writePackageStructure()
            XCTAssertFileExists(packageDirectory.appending("Package.swift"))

            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(workingDirectory)

            await XCTAssertAsyncThrowsError(try await SwiftPM.Registry.execute(
                [
                    "publish",
                    packageIdentity,
                    version,
                    "--url=\(registryURL)",
                    "--scratch-directory=\(workingDirectory.pathString)",
                    "--package-path=\(packageDirectory.pathString)",
                    "--dry-run",
                ]
            ))
        }
    }

    func testPublishingToAllowedHTTPRegistry() async throws {
        #if os(Linux)
        // needed for archiving
        guard SPM_posix_spawn_file_actions_addchdir_np_supported() else {
            throw XCTSkip("working directory not supported on this platform")
        }
        #endif

        let packageIdentity = "test.my-package"
        let version = "0.1.0"
        let registryURL = "http://packages.example.com"

        // with no authentication configured for registry
        _ = try await withTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("MyPackage")
            try localFileSystem.createDirectory(packageDirectory)

            let initPackage = try InitPackage(
                name: "MyPackage",
                packageType: .executable,
                destinationPath: packageDirectory,
                fileSystem: localFileSystem
            )
            try initPackage.writePackageStructure()
            XCTAssertFileExists(packageDirectory.appending("Package.swift"))

            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(workingDirectory)

            try await SwiftPM.Registry.execute(
                [
                    "publish",
                    packageIdentity,
                    version,
                    "--url=\(registryURL)",
                    "--scratch-directory=\(workingDirectory.pathString)",
                    "--package-path=\(packageDirectory.pathString)",
                    "--allow-insecure-http",
                    "--dry-run",
                ]
            )
        }

        // with authentication configured for registry
        _ = try await withTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("MyPackage")
            try localFileSystem.createDirectory(packageDirectory)

            let initPackage = try InitPackage(
                name: "MyPackage",
                packageType: .executable,
                destinationPath: packageDirectory,
                fileSystem: localFileSystem
            )
            try initPackage.writePackageStructure()
            XCTAssertFileExists(packageDirectory.appending("Package.swift"))

            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(workingDirectory)

            let configurationFilePath = AbsolutePath(
                ".swiftpm/configuration/registries.json",
                relativeTo: packageDirectory
            )

            try localFileSystem.createDirectory(configurationFilePath.parentDirectory, recursive: true)
            var configuration = RegistryConfiguration()
            try configuration.add(authentication: .init(type: .basic), for: URL(registryURL))
            try localFileSystem.writeFileContents(configurationFilePath, data: JSONEncoder().encode(configuration))

            await XCTAssertAsyncThrowsError(try await SwiftPM.Registry.execute(
                [
                    "publish",
                    packageIdentity,
                    version,
                    "--url=\(registryURL)",
                    "--scratch-directory=\(workingDirectory.pathString)",
                    "--package-path=\(packageDirectory.pathString)",
                    "--allow-insecure-http",
                    "--dry-run",
                ]
            ))
        }
    }

    func testPublishingUnsignedPackage() throws {
        #if os(Linux)
        // needed for archiving
        guard SPM_posix_spawn_file_actions_addchdir_np_supported() else {
            throw XCTSkip("working directory not supported on this platform")
        }
        #endif

        let packageIdentity = "test.my-package"
        let version = "0.1.0"
        let registryURL = "https://packages.example.com"

        // custom metadata path
        _ = try withTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("MyPackage")
            try localFileSystem.createDirectory(packageDirectory)

            let initPackage = try InitPackage(
                name: "MyPackage",
                packageType: .executable,
                destinationPath: packageDirectory,
                fileSystem: localFileSystem
            )
            try initPackage.writePackageStructure()
            XCTAssertFileExists(packageDirectory.appending("Package.swift"))

            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(workingDirectory)

            let metadataPath = temporaryDirectory.appending("metadata.json")
            try localFileSystem.writeFileContents(metadataPath, string: "{}")

            try await SwiftPM.Registry.execute(
                [
                    "publish",
                    packageIdentity,
                    version,
                    "--url=\(registryURL)",
                    "--scratch-directory=\(workingDirectory.pathString)",
                    "--metadata-path=\(metadataPath.pathString)",
                    "--package-path=\(packageDirectory.pathString)",
                    "--dry-run",
                ]
            )

            let archivePath = workingDirectory.appending("\(packageIdentity)-\(version).zip")

            // manifest should not be signed
            let manifest = try localFileSystem.readFileContents(packageDirectory.appending("Package.swift")).contents
            try await validateManifest(
                manifestFile: "Package.swift",
                in: archivePath,
                manifestContent: manifest
            )
        }

        // canonical metadata path
        _ = try withTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("MyPackage")
            try localFileSystem.createDirectory(packageDirectory)

            let initPackage = try InitPackage(
                name: "MyPackage",
                packageType: .executable,
                destinationPath: packageDirectory,
                fileSystem: localFileSystem
            )
            try initPackage.writePackageStructure()
            XCTAssertFileExists(packageDirectory.appending("Package.swift"))

            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(workingDirectory)

            let metadataPath = packageDirectory.appending(PackageRegistryCommand.Publish.metadataFilename)
            try localFileSystem.writeFileContents(metadataPath, string: "{}")

            try await SwiftPM.Registry.execute(
                [
                    "publish",
                    packageIdentity,
                    version,
                    "--url=\(registryURL)",
                    "--scratch-directory=\(workingDirectory.pathString)",
                    "--package-path=\(packageDirectory.pathString)",
                    "--dry-run",
                ]
            )

            let archivePath = workingDirectory.appending("\(packageIdentity)-\(version).zip")

            // manifest should not be signed
            let manifest = try localFileSystem.readFileContents(packageDirectory.appending("Package.swift")).contents
            try await validateManifest(
                manifestFile: "Package.swift",
                in: archivePath,
                manifestContent: manifest
            )
        }

        // no metadata
        _ = try withTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("MyPackage")
            try localFileSystem.createDirectory(packageDirectory)

            let initPackage = try InitPackage(
                name: "MyPackage",
                packageType: .executable,
                destinationPath: packageDirectory,
                fileSystem: localFileSystem
            )
            try initPackage.writePackageStructure()
            XCTAssertFileExists(packageDirectory.appending("Package.swift"))

            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(workingDirectory)

            try await SwiftPM.Registry.execute(
                [
                    "publish",
                    packageIdentity,
                    version,
                    "--url=\(registryURL)",
                    "--scratch-directory=\(workingDirectory.pathString)",
                    "--package-path=\(packageDirectory.pathString)",
                    "--dry-run",
                ]
            )

            let archivePath = workingDirectory.appending("\(packageIdentity)-\(version).zip")

            // manifest should not be signed
            let manifest = try localFileSystem.readFileContents(packageDirectory.appending("Package.swift")).contents
            try await validateManifest(
                manifestFile: "Package.swift",
                in: archivePath,
                manifestContent: manifest
            )
        }

        func validateManifest(
            manifestFile: String,
            in archivePath: AbsolutePath,
            manifestContent: [UInt8]
        ) async throws {
            XCTAssertFileExists(archivePath)
            let archiver = ZipArchiver(fileSystem: localFileSystem)
            let extractPath = archivePath.parentDirectory.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(extractPath)
            try await archiver.extract(from: archivePath, to: extractPath)
            try localFileSystem.stripFirstLevel(of: extractPath)

            let manifestInArchive = try localFileSystem.readFileContents(extractPath.appending(manifestFile)).contents
            XCTAssertEqual(manifestInArchive, manifestContent)
        }
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    func testPublishingSignedPackage() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the
        // plugin APIs require).
        try XCTSkipIf(
            !UserToolchain.default.supportsSwiftConcurrency(),
            "skipping because test environment doesn't support concurrency"
        )

        #if os(Linux)
        // needed for archiving
        guard SPM_posix_spawn_file_actions_addchdir_np_supported() else {
            throw XCTSkip("working directory not supported on this platform")
        }
        #endif

        let observabilityScope = ObservabilitySystem.makeForTesting().topScope

        let packageIdentity = "test.my-package"
        let version = "0.1.0"
        let registryURL = "https://packages.example.com"
        let signatureFormat = SignatureFormat.cms_1_0_0

        // custom metadata path
        try await withTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("MyPackage")
            try localFileSystem.createDirectory(packageDirectory)

            let initPackage = try InitPackage(
                name: "MyPackage",
                packageType: .executable,
                destinationPath: packageDirectory,
                fileSystem: localFileSystem
            )
            try initPackage.writePackageStructure()

            let manifestPath = packageDirectory.appending("Package.swift")
            XCTAssertFileExists(manifestPath)

            let versionSpecificManifestPath = packageDirectory.appending("Package@swift-\(ToolsVersion.current).swift")
            try localFileSystem.copy(from: manifestPath, to: versionSpecificManifestPath)

            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(workingDirectory)

            let metadataPath = temporaryDirectory.appending("metadata.json")
            try localFileSystem.writeFileContents(metadataPath, string: "{}")

            let certificatePath = temporaryDirectory.appending(component: "certificate.cer")
            let intermediateCertificatePath = temporaryDirectory.appending(component: "intermediate.cer")
            let privateKeyPath = temporaryDirectory.appending(component: "private-key.p8")

            try fixture(name: "Signing", createGitRepo: false) { fixturePath in
                try localFileSystem.copy(
                    from: fixturePath.appending(components: "Certificates", "Test_ec.cer"),
                    to: certificatePath
                )
                try localFileSystem.copy(
                    from: fixturePath.appending(components: "Certificates", "Test_ec_key.p8"),
                    to: privateKeyPath
                )
                try localFileSystem.copy(
                    from: fixturePath.appending(components: "Certificates", "TestIntermediateCA.cer"),
                    to: intermediateCertificatePath
                )
            }

            try await SwiftPM.Registry.execute(
                [
                    "publish",
                    packageIdentity,
                    version,
                    "--url=\(registryURL)",
                    "--scratch-directory=\(workingDirectory.pathString)",
                    "--metadata-path=\(metadataPath.pathString)",
                    "--package-path=\(packageDirectory.pathString)",
                    "--private-key-path=\(privateKeyPath.pathString)",
                    "--cert-chain-paths=\(certificatePath.pathString)",
                    "\(intermediateCertificatePath.pathString)",
                    "--dry-run",
                ]
            )

            // Validate signatures
            var verifierConfiguration = VerifierConfiguration()
            verifierConfiguration.trustedRoots = try testRoots()

            // archive signature
            let archivePath = workingDirectory.appending("\(packageIdentity)-\(version).zip")
            let archive = try localFileSystem.readFileContents(archivePath).contents
            let signaturePath = workingDirectory.appending("\(packageIdentity)-\(version).sig")
            let signature = try localFileSystem.readFileContents(signaturePath).contents
            try await self.validateSignature(
                signature: signature,
                content: archive,
                format: signatureFormat,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )

            // metadata signature
            let metadata = try localFileSystem.readFileContents(metadataPath).contents
            let metadataSignaturePath = workingDirectory.appending("\(packageIdentity)-\(version)-metadata.sig")
            let metadataSignature = try localFileSystem.readFileContents(metadataSignaturePath).contents
            try await self.validateSignature(
                signature: metadataSignature,
                content: metadata,
                format: signatureFormat,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )

            // manifest signatures
            let manifest = try localFileSystem.readFileContents(manifestPath).contents
            try await self.validateSignedManifest(
                manifestFile: "Package.swift",
                in: archivePath,
                manifestContent: manifest,
                format: signatureFormat,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )

            let versionSpecificManifest = try localFileSystem.readFileContents(versionSpecificManifestPath).contents
            try await self.validateSignedManifest(
                manifestFile: "Package@swift-\(ToolsVersion.current).swift",
                in: archivePath,
                manifestContent: versionSpecificManifest,
                format: signatureFormat,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )
        }

        // canonical metadata path
        try await withTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("MyPackage")
            try localFileSystem.createDirectory(packageDirectory)

            let initPackage = try InitPackage(
                name: "MyPackage",
                packageType: .executable,
                destinationPath: packageDirectory,
                fileSystem: localFileSystem
            )
            try initPackage.writePackageStructure()

            let manifestPath = packageDirectory.appending("Package.swift")
            XCTAssertFileExists(manifestPath)

            let versionSpecificManifestPath = packageDirectory.appending("Package@swift-\(ToolsVersion.current).swift")
            try localFileSystem.copy(from: manifestPath, to: versionSpecificManifestPath)

            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(workingDirectory)

            let metadataPath = packageDirectory.appending(PackageRegistryCommand.Publish.metadataFilename)
            try localFileSystem.writeFileContents(metadataPath, string: "{}")

            let certificatePath = temporaryDirectory.appending(component: "certificate.cer")
            let intermediateCertificatePath = temporaryDirectory.appending(component: "intermediate.cer")
            let privateKeyPath = temporaryDirectory.appending(component: "private-key.p8")

            try fixture(name: "Signing", createGitRepo: false) { fixturePath in
                try localFileSystem.copy(
                    from: fixturePath.appending(components: "Certificates", "Test_ec.cer"),
                    to: certificatePath
                )
                try localFileSystem.copy(
                    from: fixturePath.appending(components: "Certificates", "Test_ec_key.p8"),
                    to: privateKeyPath
                )
                try localFileSystem.copy(
                    from: fixturePath.appending(components: "Certificates", "TestIntermediateCA.cer"),
                    to: intermediateCertificatePath
                )
            }

            try await SwiftPM.Registry.execute(
                [
                    "publish",
                    packageIdentity,
                    version,
                    "--url=\(registryURL)",
                    "--scratch-directory=\(workingDirectory.pathString)",
                    "--package-path=\(packageDirectory.pathString)",
                    "--private-key-path=\(privateKeyPath.pathString)",
                    "--cert-chain-paths=\(certificatePath.pathString)",
                    "\(intermediateCertificatePath.pathString)",
                    "--dry-run",
                ]
            )

            // Validate signatures
            var verifierConfiguration = VerifierConfiguration()
            verifierConfiguration.trustedRoots = try testRoots()

            // archive signature
            let archivePath = workingDirectory.appending("\(packageIdentity)-\(version).zip")
            let archive = try localFileSystem.readFileContents(archivePath).contents
            let signaturePath = workingDirectory.appending("\(packageIdentity)-\(version).sig")
            let signature = try localFileSystem.readFileContents(signaturePath).contents
            try await self.validateSignature(
                signature: signature,
                content: archive,
                format: signatureFormat,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )

            // metadata signature
            let metadata = try localFileSystem.readFileContents(metadataPath).contents
            let metadataSignaturePath = workingDirectory.appending("\(packageIdentity)-\(version)-metadata.sig")
            let metadataSignature = try localFileSystem.readFileContents(metadataSignaturePath).contents
            try await self.validateSignature(
                signature: metadataSignature,
                content: metadata,
                format: signatureFormat,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )

            // manifest signatures
            let manifest = try localFileSystem.readFileContents(manifestPath).contents
            try await self.validateSignedManifest(
                manifestFile: "Package.swift",
                in: archivePath,
                manifestContent: manifest,
                format: signatureFormat,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )

            let versionSpecificManifest = try localFileSystem.readFileContents(versionSpecificManifestPath).contents
            try await self.validateSignedManifest(
                manifestFile: "Package@swift-\(ToolsVersion.current).swift",
                in: archivePath,
                manifestContent: versionSpecificManifest,
                format: signatureFormat,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )
        }

        // no metadata
        try await withTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("MyPackage")
            try localFileSystem.createDirectory(packageDirectory)

            let initPackage = try InitPackage(
                name: "MyPackage",
                packageType: .executable,
                destinationPath: packageDirectory,
                fileSystem: localFileSystem
            )
            try initPackage.writePackageStructure()

            let manifestPath = packageDirectory.appending("Package.swift")
            XCTAssertFileExists(manifestPath)

            let versionSpecificManifestPath = packageDirectory.appending("Package@swift-\(ToolsVersion.current).swift")
            try localFileSystem.copy(from: manifestPath, to: versionSpecificManifestPath)

            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(workingDirectory)

            let certificatePath = temporaryDirectory.appending(component: "certificate.cer")
            let intermediateCertificatePath = temporaryDirectory.appending(component: "intermediate.cer")
            let privateKeyPath = temporaryDirectory.appending(component: "private-key.p8")

            try fixture(name: "Signing", createGitRepo: false) { fixturePath in
                try localFileSystem.copy(
                    from: fixturePath.appending(components: "Certificates", "Test_ec.cer"),
                    to: certificatePath
                )
                try localFileSystem.copy(
                    from: fixturePath.appending(components: "Certificates", "Test_ec_key.p8"),
                    to: privateKeyPath
                )
                try localFileSystem.copy(
                    from: fixturePath.appending(components: "Certificates", "TestIntermediateCA.cer"),
                    to: intermediateCertificatePath
                )
            }

            try await SwiftPM.Registry.execute(
                [
                    "publish",
                    packageIdentity,
                    version,
                    "--url=\(registryURL)",
                    "--scratch-directory=\(workingDirectory.pathString)",
                    "--package-path=\(packageDirectory.pathString)",
                    "--private-key-path=\(privateKeyPath.pathString)",
                    "--cert-chain-paths=\(certificatePath.pathString)",
                    "\(intermediateCertificatePath.pathString)",
                    "--dry-run",
                ]
            )

            // Validate signatures
            var verifierConfiguration = VerifierConfiguration()
            verifierConfiguration.trustedRoots = try testRoots()

            // archive signature
            let archivePath = workingDirectory.appending("\(packageIdentity)-\(version).zip")
            let archive = try localFileSystem.readFileContents(archivePath).contents
            let signaturePath = workingDirectory.appending("\(packageIdentity)-\(version).sig")
            let signature = try localFileSystem.readFileContents(signaturePath).contents
            try await self.validateSignature(
                signature: signature,
                content: archive,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )

            // no metadata so no signature
            XCTAssertTrue(
                !localFileSystem
                    .exists(workingDirectory.appending("\(packageIdentity)-\(version)-metadata.sig"))
            )

            // manifest signatures
            let manifest = try localFileSystem.readFileContents(manifestPath).contents
            try await self.validateSignedManifest(
                manifestFile: "Package.swift",
                in: archivePath,
                manifestContent: manifest,
                format: signatureFormat,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )

            let versionSpecificManifest = try localFileSystem.readFileContents(versionSpecificManifestPath).contents
            try await self.validateSignedManifest(
                manifestFile: "Package@swift-\(ToolsVersion.current).swift",
                in: archivePath,
                manifestContent: versionSpecificManifest,
                format: signatureFormat,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )
        }
    }

    func testLoginRequiresHTTPS() async {
        let registryURL = URL(string: "http://packages.example.com")!

        await XCTAssertAsyncThrowsError(try await SwiftPM.Registry.execute(["login", "--url", registryURL.absoluteString]))
    }

    func testCreateLoginURL() {
        let registryURL = URL(string: "https://packages.example.com")!

        XCTAssertEqual(try PackageRegistryCommand.Login.loginURL(from: registryURL, loginAPIPath: nil).absoluteString, "https://packages.example.com/login")

        XCTAssertEqual(try PackageRegistryCommand.Login.loginURL(from: registryURL, loginAPIPath: "/secret-sign-in").absoluteString, "https://packages.example.com/secret-sign-in")
    }

    func testCreateLoginURLMaintainsPort() {
        let registryURL = URL(string: "https://packages.example.com:8081")!

        XCTAssertEqual(try PackageRegistryCommand.Login.loginURL(from: registryURL, loginAPIPath: nil).absoluteString, "https://packages.example.com:8081/login")

        XCTAssertEqual(try PackageRegistryCommand.Login.loginURL(from: registryURL, loginAPIPath: "/secret-sign-in").absoluteString, "https://packages.example.com:8081/secret-sign-in")
    }

    func testValidateRegistryURL() throws {
        // Valid
        try URL(string: "https://packages.example.com")!.validateRegistryURL()
        try URL(string: "http://packages.example.com")!.validateRegistryURL(allowHTTP: true)

        // Invalid
        XCTAssertThrowsError(try URL(string: "http://packages.example.com")!.validateRegistryURL())
        XCTAssertThrowsError(try URL(string: "http://packages.example.com")!.validateRegistryURL(allowHTTP: false))
        XCTAssertThrowsError(try URL(string: "ssh://packages.example.com")!.validateRegistryURL())
        XCTAssertThrowsError(try URL(string: "ftp://packages.example.com")!.validateRegistryURL(allowHTTP: true))
    }

    private func testRoots() throws -> [[UInt8]] {
        try fixture(name: "Signing", createGitRepo: false) { fixturePath in
            let rootCA = try localFileSystem
                .readFileContents(fixturePath.appending(components: "Certificates", "TestRootCA.cer")).contents
            return [rootCA]
        }
    }

    private func validateSignature(
        signature: [UInt8],
        content: [UInt8],
        format: SignatureFormat = .cms_1_0_0,
        verifierConfiguration: VerifierConfiguration,
        observabilityScope: ObservabilityScope
    ) async throws {
        let signatureStatus = try await SignatureProvider.status(
            signature: signature,
            content: content,
            format: format,
            verifierConfiguration: verifierConfiguration,
            observabilityScope: observabilityScope
        )
        guard case .valid = signatureStatus else {
            return XCTFail("Expected signature status to be .valid but got \(signatureStatus)")
        }
    }

    private func validateSignedManifest(
        manifestFile: String,
        in archivePath: AbsolutePath,
        manifestContent: [UInt8],
        format: SignatureFormat = .cms_1_0_0,
        verifierConfiguration: VerifierConfiguration,
        observabilityScope: ObservabilityScope
    ) async throws {
        XCTAssertFileExists(archivePath)
        let archiver = ZipArchiver(fileSystem: localFileSystem)
        let extractPath = archivePath.parentDirectory.appending(component: UUID().uuidString)
        try localFileSystem.createDirectory(extractPath)
        try await archiver.extract(from: archivePath, to: extractPath)
        try localFileSystem.stripFirstLevel(of: extractPath)

        let manifestSignature = try ManifestSignatureParser.parse(
            manifestPath: extractPath.appending(manifestFile),
            fileSystem: localFileSystem
        )
        XCTAssertNotNil(manifestSignature)
        XCTAssertEqual(manifestSignature!.contents, manifestContent)
        let signature = manifestSignature!.signature
        try await self.validateSignature(
            signature: signature,
            content: manifestContent,
            format: format,
            verifierConfiguration: verifierConfiguration,
            observabilityScope: observabilityScope
        )
    }
}
