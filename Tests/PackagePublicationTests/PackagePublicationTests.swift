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
import PackageLoading
import PackageModel
import PackagePublication
import PackageSigning
import SPMTestSupport
import TSCclibc // for SPM_posix_spawn_file_actions_addchdir_np_supported
import struct TSCUtility.Version
import Workspace
import XCTest

@_implementationOnly import X509 // FIXME: need this import or else SwiftSigningIdentity initializer fails

final class PackagePublicationTests: XCTestCase {
    func testArchiveAndSign() async throws {
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

        let packageIdentity = PackageIdentity.plain("test.my-package")
        let version = Version("0.1.0")
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

            let metadataPath = temporaryDirectory.appending("metadata.json")
            try localFileSystem.writeFileContents(metadataPath, string: "{}")

            let certAndKey = try temp_await { getSelfSignedTestCertAndKey(callback: $0) }
            let signingIdentity = try SwiftSigningIdentity(
                derEncodedCertificate: certAndKey.certificate,
                derEncodedPrivateKey: certAndKey.privateKey,
                privateKeyType: signatureFormat.signingKeyType
            )

            var verifierConfiguration = VerifierConfiguration()
            verifierConfiguration.trustedRoots = [certAndKey.certificate] // self-signed cert

            _ = try PackagePublication.archiveAndSign(
                packageIdentity: packageIdentity,
                packageVersion: version,
                packageDirectory: packageDirectory,
                metadataPath: metadataPath,
                signingIdentity: signingIdentity,
                intermediateCertificates: [],
                signatureFormat: signatureFormat,
                workingDirectory: workingDirectory,
                cancellator: nil,
                fileSystem: localFileSystem,
                observabilityScope: observabilityScope
            )

            // archive signature
            let archivePath = workingDirectory.appending("\(packageIdentity)-\(version).zip")
            let archive = try localFileSystem.readFileContents(archivePath).contents
            let signaturePath = workingDirectory.appending("\(packageIdentity)-\(version).sig")
            let signature = try localFileSystem.readFileContents(signaturePath).contents
            try await validate(
                signature: signature,
                content: archive,
                signatureFormat: signatureFormat,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )

            // metadata signature
            let metadata = try localFileSystem.readFileContents(metadataPath).contents
            let metadataSignaturePath = workingDirectory.appending("\(packageIdentity)-\(version)-metadata.sig")
            let metadataSignature = try localFileSystem.readFileContents(metadataSignaturePath).contents
            try await validate(
                signature: metadataSignature,
                content: metadata,
                signatureFormat: signatureFormat,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )

            // manifest signature
            try await validateSignedManifest(
                manifestFile: "Package.swift",
                in: archivePath,
                manifestPath: manifestPath,
                verifierConfiguration: verifierConfiguration
            )
        }

        func validateSignedManifest(
            manifestFile: String,
            in archivePath: AbsolutePath,
            manifestPath: AbsolutePath,
            verifierConfiguration: VerifierConfiguration
        ) async throws {
            XCTAssertFileExists(archivePath)
            let archiver = ZipArchiver(fileSystem: localFileSystem)
            let extractPath = archivePath.parentDirectory.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(extractPath)
            try temp_await { archiver.extract(from: archivePath, to: extractPath, completion: $0) }
            try localFileSystem.stripFirstLevel(of: extractPath)

            try await validateManifestSignature(
                manifestPath: manifestPath,
                signedManifestPath: extractPath.appending(manifestFile),
                signatureFormat: signatureFormat,
                verifierConfiguration: verifierConfiguration,
                observabilityScope: observabilityScope
            )
        }
    }
}

// MARK: - read test cert and key

func getSelfSignedTestCertAndKey(callback: (Result<SelfSignedCertAndKey, Error>) -> Void) {
    do {
        try fixture(name: "Signing", createGitRepo: false) { fixturePath in
            let privateKey = try localFileSystem.readFileContents(
                fixturePath.appending(components: "Certificates", "Test_ec_self_signed_key.p8")
            ).contents

            let certificate = try localFileSystem.readFileContents(
                fixturePath.appending(components: "Certificates", "Test_ec_self_signed.cer")
            ).contents

            callback(.success(SelfSignedCertAndKey(
                certificate: certificate,
                privateKey: privateKey
            )))
        }
    } catch {
        callback(.failure(error))
    }
}

struct SelfSignedCertAndKey {
    let certificate: [UInt8]
    let privateKey: [UInt8]
}

// MARK: - Sign and validate

func sign(
    signingIdentity: SigningIdentity,
    observabilityScope: ObservabilityScope
) -> PackagePublication.SignatureProvider {
    { content, signatureFormat in
        try PackageSigning.SignatureProvider.sign(
            content: content,
            identity: signingIdentity,
            intermediateCertificates: [],
            format: signatureFormat,
            observabilityScope: observabilityScope
        )
    }
}

func validate(
    signature: [UInt8],
    content: [UInt8],
    signatureFormat: SignatureFormat,
    verifierConfiguration: VerifierConfiguration,
    observabilityScope: ObservabilityScope
) async throws {
    let signatureStatus = try await SignatureProvider.status(
        signature: signature,
        content: content,
        format: signatureFormat,
        verifierConfiguration: verifierConfiguration,
        observabilityScope: observabilityScope
    )
    guard case .valid = signatureStatus else {
        return XCTFail("Expected signature status to be .valid but got \(signatureStatus)")
    }
}

func validateManifestSignature(
    manifestPath: AbsolutePath,
    signedManifestPath: AbsolutePath,
    signatureFormat: SignatureFormat,
    verifierConfiguration: VerifierConfiguration,
    observabilityScope: ObservabilityScope
) async throws {
    // Parse signed manifest to extract signature
    let manifestSignature = try ManifestSignatureParser.parse(
        manifestPath: signedManifestPath,
        fileSystem: localFileSystem
    )
    XCTAssertNotNil(manifestSignature)

    let manifestContent = try localFileSystem.readFileContents(manifestPath).contents
    XCTAssertEqual(manifestSignature!.contents, manifestContent)

    // Verify signature
    let signature = manifestSignature!.signature
    try await validate(
        signature: signature,
        content: manifestContent,
        signatureFormat: signatureFormat,
        verifierConfiguration: verifierConfiguration,
        observabilityScope: observabilityScope
    )
}
