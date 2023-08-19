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
import PackageModel
import PackagePublication
import PackageSigning
import SPMTestSupport
import Workspace
import XCTest

@_implementationOnly import X509 // FIXME: need this import or else SwiftSigningIdentity initializer fails

final class ManifestSignerTests: XCTestCase {
    func testFindManifests() throws {
        try withTemporaryDirectory { temporaryDirectory in
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

            let manifests = try ManifestSigner.findManifests(
                packageDirectory: packageDirectory,
                fileSystem: localFileSystem
            )
            XCTAssertEqual(manifests.count, 2)
            XCTAssertTrue(manifests.contains("Package.swift"))
            XCTAssertTrue(manifests.contains("Package@swift-\(ToolsVersion.current).swift"))
        }
    }

    func testSignManifest() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the
        // plugin APIs require).
        try XCTSkipIf(
            !UserToolchain.default.supportsSwiftConcurrency(),
            "skipping because test environment doesn't support concurrency"
        )

        let observabilityScope = ObservabilitySystem.makeForTesting().topScope
        let signatureFormat = SignatureFormat.cms_1_0_0

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

            let signedManifestPath = workingDirectory.appending("Package.swift")
            let signedVersionSpecificManifestPath = workingDirectory
                .appending("Package@swift-\(ToolsVersion.current).swift")

            let certAndKey = try temp_await { getSelfSignedTestCertAndKey(callback: $0) }
            let signingIdentity = try SwiftSigningIdentity(
                derEncodedCertificate: certAndKey.certificate,
                derEncodedPrivateKey: certAndKey.privateKey,
                privateKeyType: signatureFormat.signingKeyType
            )

            var verifierConfiguration = VerifierConfiguration()
            verifierConfiguration.trustedRoots = [certAndKey.certificate] // self-signed cert

            // Validate signatures
            try await signAndValidate(
                manifestPath: manifestPath,
                signedManifestPath: signedManifestPath,
                signingIdentity: signingIdentity,
                verifierConfiguration: verifierConfiguration
            )

            try await signAndValidate(
                manifestPath: versionSpecificManifestPath,
                signedManifestPath: signedVersionSpecificManifestPath,
                signingIdentity: signingIdentity,
                verifierConfiguration: verifierConfiguration
            )
        }

        func signAndValidate(
            manifestPath: AbsolutePath,
            signedManifestPath: AbsolutePath,
            signingIdentity: SigningIdentity,
            verifierConfiguration: VerifierConfiguration
        ) async throws {
            // Generate signed manifest
            _ = try ManifestSigner.sign(
                manifestPath: manifestPath,
                signedManifestPath: signedManifestPath,
                signatureProvider: sign(signingIdentity: signingIdentity, observabilityScope: observabilityScope),
                signatureFormat: signatureFormat,
                fileSystem: localFileSystem,
                observabilityScope: observabilityScope
            )

            // Validate signature
            try await validateManifestSignature(
                manifestPath: manifestPath,
                signedManifestPath: signedManifestPath,
                signatureFormat: signatureFormat,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )
        }
    }
}
