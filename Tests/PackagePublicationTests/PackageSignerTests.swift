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
import TSCclibc // for SPM_posix_spawn_file_actions_addchdir_np_supported
import Workspace
import XCTest

@_implementationOnly import X509 // FIXME: need this import or else SwiftSigningIdentity initializer fails

final class PackageSignerTests: XCTestCase {
    func testSignSourceArchive() async throws {
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

        let packageIdentity = PackageIdentity.plain("org.package")
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

            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(workingDirectory)

            let archivePath = try PackageArchiver.archiveSource(
                packageIdentity: packageIdentity,
                packageVersion: "0.1.0",
                packageDirectory: packageDirectory,
                workingDirectory: workingDirectory,
                workingFilesToCopy: [],
                cancellator: .none,
                fileSystem: localFileSystem,
                observabilityScope: observabilityScope
            )
            let archiveSignaturePath = workingDirectory.appending("archive.sig")

            let certAndKey = try temp_await { getSelfSignedTestCertAndKey(callback: $0) }
            let signingIdentity = try SwiftSigningIdentity(
                derEncodedCertificate: certAndKey.certificate,
                derEncodedPrivateKey: certAndKey.privateKey,
                privateKeyType: signatureFormat.signingKeyType
            )

            var verifierConfiguration = VerifierConfiguration()
            verifierConfiguration.trustedRoots = [certAndKey.certificate] // self-signed cert

            // archive signature
            _ = try PackageSigner.signSourceArchive(
                archivePath: archivePath,
                archiveSignaturePath: archiveSignaturePath,
                signatureProvider: sign(signingIdentity: signingIdentity, observabilityScope: observabilityScope),
                signatureFormat: signatureFormat,
                fileSystem: localFileSystem,
                observabilityScope: observabilityScope
            )

            let archive = try localFileSystem.readFileContents(archivePath).contents
            let signature = try localFileSystem.readFileContents(archiveSignaturePath).contents
            try await validate(
                signature: signature,
                content: archive,
                signatureFormat: signatureFormat,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )
        }
    }

    func testSignMetadata() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the
        // plugin APIs require).
        try XCTSkipIf(
            !UserToolchain.default.supportsSwiftConcurrency(),
            "skipping because test environment doesn't support concurrency"
        )

        let observabilityScope = ObservabilitySystem.makeForTesting().topScope
        let signatureFormat = SignatureFormat.cms_1_0_0

        try await withTemporaryDirectory { temporaryDirectory in
            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(workingDirectory)

            let metadataPath = temporaryDirectory.appending("metadata.json")
            try localFileSystem.writeFileContents(metadataPath, string: "{}")

            let metadataSignaturePath = workingDirectory.appending("metadata.sig")

            let certAndKey = try temp_await { getSelfSignedTestCertAndKey(callback: $0) }
            let signingIdentity = try SwiftSigningIdentity(
                derEncodedCertificate: certAndKey.certificate,
                derEncodedPrivateKey: certAndKey.privateKey,
                privateKeyType: signatureFormat.signingKeyType
            )

            var verifierConfiguration = VerifierConfiguration()
            verifierConfiguration.trustedRoots = [certAndKey.certificate] // self-signed cert

            // metadata signature
            _ = try PackageSigner.signPackageVersionMetadata(
                metadataPath: metadataPath,
                metadataSignaturePath: metadataSignaturePath,
                signatureProvider: sign(signingIdentity: signingIdentity, observabilityScope: observabilityScope),
                signatureFormat: signatureFormat,
                fileSystem: localFileSystem,
                observabilityScope: observabilityScope
            )

            let metadata = try localFileSystem.readFileContents(metadataPath).contents
            let signature = try localFileSystem.readFileContents(metadataSignaturePath).contents
            try await validate(
                signature: signature,
                content: metadata,
                signatureFormat: signatureFormat,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )
        }
    }
}
