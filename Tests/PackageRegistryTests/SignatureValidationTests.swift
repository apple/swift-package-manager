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
import PackageModel
@testable import PackageRegistry
import PackageSigning
import _InternalTestSupport
import X509 // FIXME: need this import or else SwiftSigningIdentity init crashes
import XCTest

import struct TSCUtility.Version

final class SignatureValidationTests: XCTestCase {
    private static let unsignedManifest = """
    // swift-tools-version: 5.7

    import PackageDescription
    let package = Package(
        name: "library",
        products: [ .library(name: "library", targets: ["library"]) ],
        targets: [ .target(name: "library") ]
    )
    """

    func testUnsignedPackage_shouldError() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        var signingConfiguration = RegistryConfiguration.Security.Signing()
        signingConfiguration.onUnsigned = .error // intended for this test; don't change
        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: signingConfiguration
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let signatureValidation = SignatureValidation(
            skipSignatureValidation: false,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode,
            versionMetadataProvider: registryClient.getPackageVersionMetadata,
            delegate: RejectingSignatureValidationDelegate()
        )

        // Package is not signed. With onUnsigned = .error,
        // an error gets thrown.
        await XCTAssertAsyncThrowsError(
            try await signatureValidation.validate(
                registry: registry,
                package: package,
                version: version,
                content: Data(emptyZipFile.contents),
                configuration: configuration.signing(for: package, registry: registry)
            )
        ) { error in
            guard case RegistryError.sourceArchiveNotSigned = error else {
                return XCTFail("Expected RegistryError.sourceArchiveNotSigned, got '\(error)'")
            }
        }
    }

    func testUnsignedPackage_shouldWarn() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        var signingConfiguration = RegistryConfiguration.Security.Signing()
        signingConfiguration.onUnsigned = .warn // intended for this test; don't change
        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: signingConfiguration
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let signatureValidation = SignatureValidation(
            skipSignatureValidation: false,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode,
            versionMetadataProvider: registryClient.getPackageVersionMetadata,
            delegate: RejectingSignatureValidationDelegate()
        )

        let observability = ObservabilitySystem.makeForTesting()

        // Package is not signed. With onUnsigned = .warn,
        // no error gets thrown but there should be a warning
        _ = try await signatureValidation.validate(
            registry: registry,
            package: package,
            version: version,
            content: Data(emptyZipFile.contents),
            configuration: configuration.signing(for: package, registry: registry),
            observabilityScope: observability.topScope
        )

        testDiagnostics(observability.diagnostics) { result in
            let diagnostics = result.check(diagnostic: .contains("is not signed"), severity: .warning)
            XCTAssertEqual(diagnostics?.metadata?.packageIdentity, package.underlying)
        }
    }

    func testUnsignedPackage_shouldPrompt() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        var signingConfiguration = RegistryConfiguration.Security.Signing()
        signingConfiguration.onUnsigned = .prompt // intended for this test; don't change
        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: signingConfiguration
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // prompt returning false
        do {
            let signatureValidation = SignatureValidation(
                skipSignatureValidation: false,
                signingEntityStorage: signingEntityStorage,
                signingEntityCheckingMode: signingEntityCheckingMode,
                versionMetadataProvider: registryClient.getPackageVersionMetadata,
                delegate: RejectingSignatureValidationDelegate()
            )

            // Package is not signed. With onUnsigned = .error,
            // an error gets thrown.
            await XCTAssertAsyncThrowsError(
                try await signatureValidation.validate(
                    registry: registry,
                    package: package,
                    version: version,
                    content: Data(emptyZipFile.contents),
                    configuration: configuration.signing(for: package, registry: registry)
                )
            ) { error in
                guard case RegistryError.sourceArchiveNotSigned = error else {
                    return XCTFail("Expected RegistryError.sourceArchiveNotSigned, got '\(error)'")
                }
            }
        }

        // prompt returning continue
        do {
            let signatureValidation = SignatureValidation(
                skipSignatureValidation: false,
                signingEntityStorage: signingEntityStorage,
                signingEntityCheckingMode: signingEntityCheckingMode,
                versionMetadataProvider: registryClient.getPackageVersionMetadata,
                delegate: AcceptingSignatureValidationDelegate()
            )

            // Package is not signed, signingEntity should be nil
            let signingEntity = try await signatureValidation.validate(
                registry: registry,
                package: package,
                version: version,
                content: Data(emptyZipFile.contents),
                configuration: configuration.signing(for: package, registry: registry)
            )
            XCTAssertNil(signingEntity)
        }
    }

    func testFailedToFetchSignature_shouldError() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: metadataURL,
            errorCode: 404,
            errorDescription: "not found"
        )

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        var signingConfiguration = RegistryConfiguration.Security.Signing()
        signingConfiguration.onUnsigned = .error // intended for this test; don't change
        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: signingConfiguration
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let signatureValidation = SignatureValidation(
            skipSignatureValidation: false,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode,
            versionMetadataProvider: registryClient.getPackageVersionMetadata,
            delegate: RejectingSignatureValidationDelegate()
        )

        // Failed to fetch package metadata / signature
        await XCTAssertAsyncThrowsError(
            try await signatureValidation.validate(
                registry: registry,
                package: package,
                version: version,
                content: Data(emptyZipFile.contents),
                configuration: configuration.signing(for: package, registry: registry)
            )
        ) { error in
            guard case RegistryError.failedRetrievingSourceArchiveSignature = error else {
                return XCTFail("Expected RegistryError.failedRetrievingSourceArchiveSignature, got '\(error)'")
            }
        }
    }

    func testUnsignedArchiveAndManifest_shouldPrompt() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        var signingConfiguration = RegistryConfiguration.Security.Signing()
        signingConfiguration.onUnsigned = .prompt // intended for this test; don't change
        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: signingConfiguration
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // prompt returning false
        do {
            let signatureValidation = SignatureValidation(
                skipSignatureValidation: false,
                signingEntityStorage: signingEntityStorage,
                signingEntityCheckingMode: signingEntityCheckingMode,
                versionMetadataProvider: registryClient.getPackageVersionMetadata,
                delegate: RejectingSignatureValidationDelegate()
            )

            // Package is not signed. With onUnsigned = .prompt, prompt to continue.
            await XCTAssertAsyncThrowsError(
                try await signatureValidation.validate(
                    registry: registry,
                    package: package,
                    version: version,
                    toolsVersion: .none,
                    manifestContent: Self.unsignedManifest,
                    configuration: configuration.signing(for: package, registry: registry)
                )
            ) { error in
                guard case RegistryError.sourceArchiveNotSigned = error else {
                    return XCTFail("Expected RegistryError.sourceArchiveNotSigned, got '\(error)'")
                }
            }
        }

        // prompt returning continue
        do {
            let signatureValidation = SignatureValidation(
                skipSignatureValidation: false,
                signingEntityStorage: signingEntityStorage,
                signingEntityCheckingMode: signingEntityCheckingMode,
                versionMetadataProvider: registryClient.getPackageVersionMetadata,
                delegate: AcceptingSignatureValidationDelegate()
            )

            // Package is not signed, signingEntity should be nil
            let signingEntity = try await signatureValidation.validate(
                registry: registry,
                package: package,
                version: version,
                toolsVersion: .none,
                manifestContent: Self.unsignedManifest,
                configuration: configuration.signing(for: package, registry: registry)
            )
            XCTAssertNil(signingEntity)
        }
    }

    func testUnsignedArchiveAndManifest_nonPrompt() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        var signingConfiguration = RegistryConfiguration.Security.Signing()
        signingConfiguration.onUnsigned = .error // intended for this test; don't change
        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: signingConfiguration
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let signatureValidation = SignatureValidation(
            skipSignatureValidation: false,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode,
            versionMetadataProvider: registryClient.getPackageVersionMetadata,
            delegate: RejectingSignatureValidationDelegate()
        )

        let observability = ObservabilitySystem.makeForTesting()

        // Package is not signed.
        // With the exception of .prompt, we log then continue.
        _ = try await signatureValidation.validate(
            registry: registry,
            package: package,
            version: version,
            toolsVersion: .none,
            manifestContent: Self.unsignedManifest,
            configuration: configuration.signing(for: package, registry: registry),
            observabilityScope: observability.topScope
        )

        testDiagnostics(observability.diagnostics, problemsOnly: false) { result in
            let diagnostics = result.check(diagnostic: .contains("is not signed"), severity: .debug)
            XCTAssertEqual(diagnostics?.metadata?.packageIdentity, package.underlying)
        }
    }

    func testFailedToFetchArchiveSignatureToValidateManifest_diagnostics() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: metadataURL,
            errorCode: 404,
            errorDescription: "not found"
        )

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let signatureValidation = SignatureValidation(
            skipSignatureValidation: false,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode,
            versionMetadataProvider: registryClient.getPackageVersionMetadata,
            delegate: RejectingSignatureValidationDelegate()
        )

        let observability = ObservabilitySystem.makeForTesting()

        // Failed to fetch package metadata / signature.
        // This error is not thrown for manifest but there should be diagnostics.
        _ = try await signatureValidation.validate(
            registry: registry,
            package: package,
            version: version,
            toolsVersion: .none,
            manifestContent: Self.unsignedManifest,
            configuration: configuration.signing(for: package, registry: registry),
            observabilityScope: observability.topScope
        )

        testDiagnostics(observability.diagnostics, problemsOnly: false) { result in
            result.check(
                diagnostic: .contains(
                    "retrieval of source archive signature for \(package) \(version) from \(registry) failed"
                ),
                severity: .debug
            )
        }
    }

    func testSignedArchiveUnsignedManifest() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let keyAndCertChain = try self.ecSelfSignedTestKeyAndCertChain()
        let signingIdentity = try SwiftSigningIdentity(
            derEncodedCertificate: keyAndCertChain.leafCertificate,
            derEncodedPrivateKey: keyAndCertChain.privateKey,
            privateKeyType: .p256
        )
        let signatureFormat = SignatureFormat.cms_1_0_0
        let signatureBytes = try self.sign(
            content: emptyZipFile.contents,
            signingIdentity: signingIdentity,
            format: signatureFormat
        )

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum,
            signatureBytes: signatureBytes,
            signatureFormat: signatureFormat
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        var signingConfiguration = RegistryConfiguration.Security.Signing()
        signingConfiguration.onUnsigned = .error // intended for this test; don't change
        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: signingConfiguration
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let signatureValidation = SignatureValidation(
            skipSignatureValidation: false,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode,
            versionMetadataProvider: registryClient.getPackageVersionMetadata,
            delegate: RejectingSignatureValidationDelegate()
        )

        // Archive is signed, but manifest is not signed
        await XCTAssertAsyncThrowsError(
            try await signatureValidation.validate(
                registry: registry,
                package: package,
                version: version,
                toolsVersion: ToolsVersion.v5_7,
                manifestContent: Self.unsignedManifest,
                configuration: configuration.signing(for: package, registry: registry)
            )
        ) { error in
            guard case RegistryError.manifestNotSigned(_, _, _, let toolsVersion) = error else {
                return XCTFail("Expected RegistryError.manifestNotSigned, got '\(error)'")
            }
            XCTAssertEqual(toolsVersion, ToolsVersion.v5_7)
        }
    }

    func testSignedArchiveUnknownManifestSignatureFormat() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let keyAndCertChain = try self.ecSelfSignedTestKeyAndCertChain()
        let signingIdentity = try SwiftSigningIdentity(
            derEncodedCertificate: keyAndCertChain.leafCertificate,
            derEncodedPrivateKey: keyAndCertChain.privateKey,
            privateKeyType: .p256
        )
        let signatureFormat = SignatureFormat.cms_1_0_0
        let signatureBytes = try self.sign(
            content: emptyZipFile.contents,
            signingIdentity: signingIdentity,
            format: signatureFormat
        )

        let manifestSignatureBytes = try self.sign(
            content: Array(Self.unsignedManifest.utf8),
            signingIdentity: signingIdentity,
            format: signatureFormat
        )
        let manifestContent = """
        \(Self.unsignedManifest)
        // signature: abc-1.0.0;\(Data(manifestSignatureBytes).base64EncodedString())
        """

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum,
            signatureBytes: signatureBytes,
            signatureFormat: signatureFormat
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        var signingConfiguration = RegistryConfiguration.Security.Signing()
        signingConfiguration.onUnsigned = .error // intended for this test; don't change
        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: signingConfiguration
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let signatureValidation = SignatureValidation(
            skipSignatureValidation: false,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode,
            versionMetadataProvider: registryClient.getPackageVersionMetadata,
            delegate: RejectingSignatureValidationDelegate()
        )

        // Archive is signed, but manifest signature format is bad
        await XCTAssertAsyncThrowsError(
            try await signatureValidation.validate(
                registry: registry,
                package: package,
                version: version,
                toolsVersion: .none,
                manifestContent: manifestContent,
                configuration: configuration.signing(for: package, registry: registry)
            )
        ) { error in
            guard case RegistryError.unknownSignatureFormat = error else {
                return XCTFail("Expected RegistryError.unknownSignatureFormat, got '\(error)'")
            }
        }
    }

    func testSignedArchiveMalformedManifestSignature() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let keyAndCertChain = try self.ecSelfSignedTestKeyAndCertChain()
        let signingIdentity = try SwiftSigningIdentity(
            derEncodedCertificate: keyAndCertChain.leafCertificate,
            derEncodedPrivateKey: keyAndCertChain.privateKey,
            privateKeyType: .p256
        )
        let signatureFormat = SignatureFormat.cms_1_0_0
        let signatureBytes = try self.sign(
            content: emptyZipFile.contents,
            signingIdentity: signingIdentity,
            format: signatureFormat
        )

        let manifestContent = """
        \(Self.unsignedManifest)
        // signature: cms-1.0.0;manifest-signature
        """

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum,
            signatureBytes: signatureBytes,
            signatureFormat: signatureFormat
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        var signingConfiguration = RegistryConfiguration.Security.Signing()
        signingConfiguration.onUnsigned = .error // intended for this test; don't change
        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: signingConfiguration
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let signatureValidation = SignatureValidation(
            skipSignatureValidation: false,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode,
            versionMetadataProvider: registryClient.getPackageVersionMetadata,
            delegate: RejectingSignatureValidationDelegate()
        )

        // Archive is signed, but manifest signature is malformed
        await XCTAssertAsyncThrowsError(
            try await signatureValidation.validate(
                registry: registry,
                package: package,
                version: version,
                toolsVersion: .none,
                manifestContent: manifestContent,
                configuration: configuration.signing(for: package, registry: registry)
            )
        ) { error in
            guard case RegistryError.invalidSignature(let reason) = error else {
                return XCTFail("Expected RegistryError.invalidSignature, got '\(error)'")
            }
            XCTAssertTrue(reason.contains("malformed"))
        }
    }

    #if swift(>=5.5.2)
    func testSignedPackage_validSignature() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let keyAndCertChain = try self.ecSelfSignedTestKeyAndCertChain()
        let signingIdentity = try SwiftSigningIdentity(
            derEncodedCertificate: keyAndCertChain.leafCertificate,
            derEncodedPrivateKey: keyAndCertChain.privateKey,
            privateKeyType: .p256
        )
        let signatureFormat = SignatureFormat.cms_1_0_0
        let signatureBytes = try self.sign(
            content: emptyZipFile.contents,
            signingIdentity: signingIdentity,
            format: signatureFormat
        )

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum,
            signatureBytes: signatureBytes,
            signatureFormat: signatureFormat
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        try await withTemporaryDirectory { temporaryDirectory in
            // Write test root to trust roots directory
            let trustRootsDirectoryPath = temporaryDirectory.appending(component: "trust-roots")
            try localFileSystem.createDirectory(trustRootsDirectoryPath)
            try localFileSystem.writeFileContents(
                trustRootsDirectoryPath.appending(component: "test-root.cer"),
                bytes: .init(keyAndCertChain.rootCertificate)
            )

            var signingConfiguration = RegistryConfiguration.Security.Signing()
            signingConfiguration.trustedRootCertificatesPath = trustRootsDirectoryPath.pathString
            signingConfiguration.includeDefaultTrustedRootCertificates = false
            var validationChecks = RegistryConfiguration.Security.Signing.ValidationChecks()
            validationChecks.certificateExpiration = .disabled
            validationChecks.certificateRevocation = .disabled
            signingConfiguration.validationChecks = validationChecks

            configuration.security = RegistryConfiguration.Security(
                default: RegistryConfiguration.Security.Global(
                    signing: signingConfiguration
                )
            )

            let signingEntityStorage = MockPackageSigningEntityStorage()
            let signingEntityCheckingMode = SigningEntityCheckingMode.strict

            let registryClient = makeRegistryClient(
                configuration: configuration,
                httpClient: httpClient,
                signingEntityStorage: signingEntityStorage,
                signingEntityCheckingMode: signingEntityCheckingMode
            )

            let signatureValidation = SignatureValidation(
                skipSignatureValidation: false,
                signingEntityStorage: signingEntityStorage,
                signingEntityCheckingMode: signingEntityCheckingMode,
                versionMetadataProvider: registryClient.getPackageVersionMetadata,
                delegate: RejectingSignatureValidationDelegate()
            )

            // Package signature is valid
            _ = try await signatureValidation.validate(
                registry: registry,
                package: package,
                version: version,
                content: Data(emptyZipFile.contents),
                configuration: configuration.signing(for: package, registry: registry)
            )
        }
    }

    func testSignedPackage_badSignature() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let signatureBytes = Array("bad signature".utf8)
        let signatureFormat = SignatureFormat.cms_1_0_0

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum,
            signatureBytes: signatureBytes,
            signatureFormat: signatureFormat
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: .init()
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let signatureValidation = SignatureValidation(
            skipSignatureValidation: false,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode,
            versionMetadataProvider: registryClient.getPackageVersionMetadata,
            delegate: RejectingSignatureValidationDelegate()
        )

        // Package signature can't be parsed so it is invalid
        await XCTAssertAsyncThrowsError(
            try await signatureValidation.validate(
                registry: registry,
                package: package,
                version: version,
                content: Data(emptyZipFile.contents),
                configuration: configuration.signing(for: package, registry: registry)
            )
        ) { error in
            guard case RegistryError.invalidSignature = error else {
                return XCTFail("Expected RegistryError.invalidSignature, got '\(error)'")
            }
        }
    }

    func testSignedPackage_badSignature_skipSignatureValidation() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = { _, _, completion in
            completion(.failure(StringError("unexpected request")))
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: .init()
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let signatureValidation = SignatureValidation(
            skipSignatureValidation: true, // intended for this test, don't change
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode,
            versionMetadataProvider: registryClient.getPackageVersionMetadata,
            delegate: RejectingSignatureValidationDelegate()
        )

        // Signature is bad, but we are skipping signature
        // validation, so no error is thrown.
        _ = try await signatureValidation.validate(
            registry: registry,
            package: package,
            version: version,
            content: Data(emptyZipFile.contents),
            configuration: configuration.signing(for: package, registry: registry)
        )
    }

    func testSignedPackage_invalidSignature() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let keyAndCertChain = try self.ecSelfSignedTestKeyAndCertChain()
        let signingIdentity = try SwiftSigningIdentity(
            derEncodedCertificate: keyAndCertChain.leafCertificate,
            derEncodedPrivateKey: keyAndCertChain.privateKey,
            privateKeyType: .p256
        )
        let signatureFormat = SignatureFormat.cms_1_0_0
        let signatureBytes = try self.sign(
            content: Array("other zip archive".utf8), // signature is not for emptyZipFile but for something else
            signingIdentity: signingIdentity,
            format: signatureFormat
        )

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum,
            signatureBytes: signatureBytes,
            signatureFormat: signatureFormat
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        try await withTemporaryDirectory { temporaryDirectory in
            // Write test root to trust roots directory
            let trustRootsDirectoryPath = temporaryDirectory.appending(component: "trust-roots")
            try localFileSystem.createDirectory(trustRootsDirectoryPath)
            try localFileSystem.writeFileContents(
                trustRootsDirectoryPath.appending(component: "test-root.cer"),
                bytes: .init(keyAndCertChain.rootCertificate)
            )

            var signingConfiguration = RegistryConfiguration.Security.Signing()
            signingConfiguration.trustedRootCertificatesPath = trustRootsDirectoryPath.pathString
            signingConfiguration.includeDefaultTrustedRootCertificates = false
            var validationChecks = RegistryConfiguration.Security.Signing.ValidationChecks()
            validationChecks.certificateExpiration = .disabled
            validationChecks.certificateRevocation = .disabled
            signingConfiguration.validationChecks = validationChecks

            configuration.security = RegistryConfiguration.Security(
                default: RegistryConfiguration.Security.Global(
                    signing: signingConfiguration
                )
            )

            let signingEntityStorage = MockPackageSigningEntityStorage()
            let signingEntityCheckingMode = SigningEntityCheckingMode.strict

            let registryClient = makeRegistryClient(
                configuration: configuration,
                httpClient: httpClient,
                signingEntityStorage: signingEntityStorage,
                signingEntityCheckingMode: signingEntityCheckingMode
            )

            let signatureValidation = SignatureValidation(
                skipSignatureValidation: false,
                signingEntityStorage: signingEntityStorage,
                signingEntityCheckingMode: signingEntityCheckingMode,
                versionMetadataProvider: registryClient.getPackageVersionMetadata,
                delegate: RejectingSignatureValidationDelegate()
            )

            // Package signature doesn't match content so it's invalid
            await XCTAssertAsyncThrowsError(
                try await signatureValidation.validate(
                    registry: registry,
                    package: package,
                    version: version,
                    content: Data(emptyZipFile.contents),
                    configuration: configuration.signing(for: package, registry: registry)
                )
            ) { error in
                guard case RegistryError.invalidSignature = error else {
                    return XCTFail("Expected RegistryError.invalidSignature, got '\(error)'")
                }
            }
        }
    }

    func testSignedPackage_certificateNotTrusted_shouldError() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let keyAndCertChain = try self.ecSelfSignedTestKeyAndCertChain()
        let signingIdentity = try SwiftSigningIdentity(
            derEncodedCertificate: keyAndCertChain.leafCertificate,
            derEncodedPrivateKey: keyAndCertChain.privateKey,
            privateKeyType: .p256
        )
        let signatureFormat = SignatureFormat.cms_1_0_0
        let signatureBytes = try self.sign(
            content: emptyZipFile.contents,
            signingIdentity: signingIdentity,
            format: signatureFormat
        )

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum,
            signatureBytes: signatureBytes,
            signatureFormat: signatureFormat
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        var signingConfiguration = RegistryConfiguration.Security.Signing()
        signingConfiguration.onUntrustedCertificate = .error // intended for this test; don't change
        // Test root not written to trust roots directory
        signingConfiguration.includeDefaultTrustedRootCertificates = false
        var validationChecks = RegistryConfiguration.Security.Signing.ValidationChecks()
        validationChecks.certificateExpiration = .disabled
        validationChecks.certificateRevocation = .disabled
        signingConfiguration.validationChecks = validationChecks

        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: signingConfiguration
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let signatureValidation = SignatureValidation(
            skipSignatureValidation: false,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode,
            versionMetadataProvider: registryClient.getPackageVersionMetadata,
            delegate: RejectingSignatureValidationDelegate()
        )

        // Test root not trusted; onUntrustedCertificate is set to .error
        await XCTAssertAsyncThrowsError(
            try await signatureValidation.validate(
                registry: registry,
                package: package,
                version: version,
                content: Data(emptyZipFile.contents),
                configuration: configuration.signing(for: package, registry: registry)
            )
        ) { error in
            guard case RegistryError.signerNotTrusted = error else {
                return XCTFail("Expected RegistryError.signerNotTrusted, got '\(error)'")
            }
        }
    }

    func testSignedPackage_certificateNotTrusted_shouldPrompt() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let keyAndCertChain = try self.ecSelfSignedTestKeyAndCertChain()
        let signingIdentity = try SwiftSigningIdentity(
            derEncodedCertificate: keyAndCertChain.leafCertificate,
            derEncodedPrivateKey: keyAndCertChain.privateKey,
            privateKeyType: .p256
        )
        let signatureFormat = SignatureFormat.cms_1_0_0
        let signatureBytes = try self.sign(
            content: emptyZipFile.contents,
            signingIdentity: signingIdentity,
            format: signatureFormat
        )

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum,
            signatureBytes: signatureBytes,
            signatureFormat: signatureFormat
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        var signingConfiguration = RegistryConfiguration.Security.Signing()
        signingConfiguration.onUntrustedCertificate = .prompt // intended for this test; don't change
        // Test root not written to trust roots directory
        signingConfiguration.includeDefaultTrustedRootCertificates = false
        var validationChecks = RegistryConfiguration.Security.Signing.ValidationChecks()
        validationChecks.certificateExpiration = .disabled
        validationChecks.certificateRevocation = .disabled
        signingConfiguration.validationChecks = validationChecks

        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: signingConfiguration
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // prompt returning false
        do {
            let signatureValidation = SignatureValidation(
                skipSignatureValidation: false,
                signingEntityStorage: signingEntityStorage,
                signingEntityCheckingMode: signingEntityCheckingMode,
                versionMetadataProvider: registryClient.getPackageVersionMetadata,
                delegate: RejectingSignatureValidationDelegate()
            )

            // Test root not trusted; onUntrustedCertificate is set to .prompt
            await XCTAssertAsyncThrowsError(
                try await signatureValidation.validate(
                    registry: registry,
                    package: package,
                    version: version,
                    content: Data(emptyZipFile.contents),
                    configuration: configuration.signing(for: package, registry: registry)
                )
            ) { error in
                guard case RegistryError.signerNotTrusted = error else {
                    return XCTFail("Expected RegistryError.signerNotTrusted, got '\(error)'")
                }
            }
        }

        // prompt returning continue
        do {
            let signatureValidation = SignatureValidation(
                skipSignatureValidation: false,
                signingEntityStorage: signingEntityStorage,
                signingEntityCheckingMode: signingEntityCheckingMode,
                versionMetadataProvider: registryClient.getPackageVersionMetadata,
                delegate: AcceptingSignatureValidationDelegate()
            )

            // Package signer is untrusted, signingEntity should be nil
            let signingEntity = try await signatureValidation.validate(
                registry: registry,
                package: package,
                version: version,
                content: Data(emptyZipFile.contents),
                configuration: configuration.signing(for: package, registry: registry)
            )
            XCTAssertNil(signingEntity)
        }
    }

    func testSignedPackage_certificateNotTrusted_shouldWarn() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let keyAndCertChain = try self.ecSelfSignedTestKeyAndCertChain()
        let signingIdentity = try SwiftSigningIdentity(
            derEncodedCertificate: keyAndCertChain.leafCertificate,
            derEncodedPrivateKey: keyAndCertChain.privateKey,
            privateKeyType: .p256
        )
        let signatureFormat = SignatureFormat.cms_1_0_0
        let signatureBytes = try self.sign(
            content: emptyZipFile.contents,
            signingIdentity: signingIdentity,
            format: signatureFormat
        )

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum,
            signatureBytes: signatureBytes,
            signatureFormat: signatureFormat
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        var signingConfiguration = RegistryConfiguration.Security.Signing()
        signingConfiguration.onUntrustedCertificate = .warn // intended for this test; don't change
        // Test root not written to trust roots directory
        signingConfiguration.includeDefaultTrustedRootCertificates = false
        var validationChecks = RegistryConfiguration.Security.Signing.ValidationChecks()
        validationChecks.certificateExpiration = .disabled
        validationChecks.certificateRevocation = .disabled
        signingConfiguration.validationChecks = validationChecks

        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: signingConfiguration
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let signatureValidation = SignatureValidation(
            skipSignatureValidation: false,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode,
            versionMetadataProvider: registryClient.getPackageVersionMetadata,
            delegate: RejectingSignatureValidationDelegate()
        )

        let observability = ObservabilitySystem.makeForTesting()

        // Test root not trusted but onUntrustedCertificate is set to .warn
        _ = try await signatureValidation.validate(
            registry: registry,
            package: package,
            version: version,
            content: Data(emptyZipFile.contents),
            configuration: configuration.signing(for: package, registry: registry),
            observabilityScope: observability.topScope
        )

        testDiagnostics(observability.diagnostics) { result in
            let diagnostics = result.check(diagnostic: .contains("not trusted"), severity: .warning)
            XCTAssertEqual(diagnostics?.metadata?.packageIdentity, package.underlying)
        }
    }

    func testSignedManifest_validSignature() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let keyAndCertChain = try self.ecSelfSignedTestKeyAndCertChain()
        let signingIdentity = try SwiftSigningIdentity(
            derEncodedCertificate: keyAndCertChain.leafCertificate,
            derEncodedPrivateKey: keyAndCertChain.privateKey,
            privateKeyType: .p256
        )
        let signatureFormat = SignatureFormat.cms_1_0_0
        let signatureBytes = try self.sign(
            content: emptyZipFile.contents,
            signingIdentity: signingIdentity,
            format: signatureFormat
        )

        let manifestSignatureBytes = try self.sign(
            content: Array(Self.unsignedManifest.utf8),
            signingIdentity: signingIdentity,
            format: signatureFormat
        )
        let manifestContent = """
        \(Self.unsignedManifest)
        // signature: cms-1.0.0;\(Data(manifestSignatureBytes).base64EncodedString())
        """

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum,
            signatureBytes: signatureBytes,
            signatureFormat: signatureFormat
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        try await withTemporaryDirectory { temporaryDirectory in
            // Write test root to trust roots directory
            let trustRootsDirectoryPath = temporaryDirectory.appending(component: "trust-roots")
            try localFileSystem.createDirectory(trustRootsDirectoryPath)
            try localFileSystem.writeFileContents(
                trustRootsDirectoryPath.appending(component: "test-root.cer"),
                bytes: .init(keyAndCertChain.rootCertificate)
            )

            var signingConfiguration = RegistryConfiguration.Security.Signing()
            signingConfiguration.trustedRootCertificatesPath = trustRootsDirectoryPath.pathString
            signingConfiguration.includeDefaultTrustedRootCertificates = false
            var validationChecks = RegistryConfiguration.Security.Signing.ValidationChecks()
            validationChecks.certificateExpiration = .disabled
            validationChecks.certificateRevocation = .disabled
            signingConfiguration.validationChecks = validationChecks

            configuration.security = RegistryConfiguration.Security(
                default: RegistryConfiguration.Security.Global(
                    signing: signingConfiguration
                )
            )

            let signingEntityStorage = MockPackageSigningEntityStorage()
            let signingEntityCheckingMode = SigningEntityCheckingMode.strict

            let registryClient = makeRegistryClient(
                configuration: configuration,
                httpClient: httpClient,
                signingEntityStorage: signingEntityStorage,
                signingEntityCheckingMode: signingEntityCheckingMode
            )

            let signatureValidation = SignatureValidation(
                skipSignatureValidation: false,
                signingEntityStorage: signingEntityStorage,
                signingEntityCheckingMode: signingEntityCheckingMode,
                versionMetadataProvider: registryClient.getPackageVersionMetadata,
                delegate: RejectingSignatureValidationDelegate()
            )

            // Manifest signature is valid
            _ = try await signatureValidation.validate(
                registry: registry,
                package: package,
                version: version,
                toolsVersion: .none,
                manifestContent: manifestContent,
                configuration: configuration.signing(for: package, registry: registry)
            )
        }
    }

    func testSignedManifest_badSignature() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let keyAndCertChain = try self.ecSelfSignedTestKeyAndCertChain()
        let signingIdentity = try SwiftSigningIdentity(
            derEncodedCertificate: keyAndCertChain.leafCertificate,
            derEncodedPrivateKey: keyAndCertChain.privateKey,
            privateKeyType: .p256
        )
        let signatureFormat = SignatureFormat.cms_1_0_0
        let signatureBytes = try self.sign(
            content: emptyZipFile.contents,
            signingIdentity: signingIdentity,
            format: signatureFormat
        )

        let manifestContent = """
        \(Self.unsignedManifest)
        // signature: cms-1.0.0;\(Data(Array("bad signature".utf8)).base64EncodedString())
        """

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum,
            signatureBytes: signatureBytes,
            signatureFormat: signatureFormat
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: .init()
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let signatureValidation = SignatureValidation(
            skipSignatureValidation: false,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode,
            versionMetadataProvider: registryClient.getPackageVersionMetadata,
            delegate: RejectingSignatureValidationDelegate()
        )

        // Manifest signature can't be parsed so it is invalid
        await XCTAssertAsyncThrowsError(
            try await signatureValidation.validate(
                registry: registry,
                package: package,
                version: version,
                toolsVersion: .none,
                manifestContent: manifestContent,
                configuration: configuration.signing(for: package, registry: registry)
            )
        ) { error in
            guard case RegistryError.invalidSignature = error else {
                return XCTFail("Expected RegistryError.invalidSignature, got '\(error)'")
            }
        }
    }

    func testSignedManifest_badSignature_skipSignatureValidation() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let keyAndCertChain = try self.ecSelfSignedTestKeyAndCertChain()
        let signingIdentity = try SwiftSigningIdentity(
            derEncodedCertificate: keyAndCertChain.leafCertificate,
            derEncodedPrivateKey: keyAndCertChain.privateKey,
            privateKeyType: .p256
        )
        let signatureFormat = SignatureFormat.cms_1_0_0
        let signatureBytes = try self.sign(
            content: emptyZipFile.contents,
            signingIdentity: signingIdentity,
            format: signatureFormat
        )

        let manifestContent = """
        \(Self.unsignedManifest)
        // signature: cms-1.0.0;\(Data(Array("bad signature".utf8)).base64EncodedString())
        """

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum,
            signatureBytes: signatureBytes,
            signatureFormat: signatureFormat
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: .init()
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let signatureValidation = SignatureValidation(
            skipSignatureValidation: true, // intended for this test, don't change
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode,
            versionMetadataProvider: registryClient.getPackageVersionMetadata,
            delegate: RejectingSignatureValidationDelegate()
        )

        // Manifest signature is bad, but we are skipping signature
        // validation, so no error is thrown.
        _ = try await signatureValidation.validate(
            registry: registry,
            package: package,
            version: version,
            toolsVersion: .none,
            manifestContent: manifestContent,
            configuration: configuration.signing(for: package, registry: registry)
        )
    }

    func testSignedManifest_invalidSignature() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let keyAndCertChain = try self.ecSelfSignedTestKeyAndCertChain()
        let signingIdentity = try SwiftSigningIdentity(
            derEncodedCertificate: keyAndCertChain.leafCertificate,
            derEncodedPrivateKey: keyAndCertChain.privateKey,
            privateKeyType: .p256
        )
        let signatureFormat = SignatureFormat.cms_1_0_0
        let signatureBytes = try self.sign(
            content: emptyZipFile.contents,
            signingIdentity: signingIdentity,
            format: signatureFormat
        )

        let manifestSignatureBytes = try self.sign(
            content: Array("not manifest".utf8), // signature is not for manifest but for something else
            signingIdentity: signingIdentity,
            format: signatureFormat
        )
        let manifestContent = """
        \(Self.unsignedManifest)
        // signature: cms-1.0.0;\(Data(manifestSignatureBytes).base64EncodedString())
        """

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum,
            signatureBytes: signatureBytes,
            signatureFormat: signatureFormat
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        try await withTemporaryDirectory { temporaryDirectory in
            // Write test root to trust roots directory
            let trustRootsDirectoryPath = temporaryDirectory.appending(component: "trust-roots")
            try localFileSystem.createDirectory(trustRootsDirectoryPath)
            try localFileSystem.writeFileContents(
                trustRootsDirectoryPath.appending(component: "test-root.cer"),
                bytes: .init(keyAndCertChain.rootCertificate)
            )

            var signingConfiguration = RegistryConfiguration.Security.Signing()
            signingConfiguration.trustedRootCertificatesPath = trustRootsDirectoryPath.pathString
            signingConfiguration.includeDefaultTrustedRootCertificates = false
            var validationChecks = RegistryConfiguration.Security.Signing.ValidationChecks()
            validationChecks.certificateExpiration = .disabled
            validationChecks.certificateRevocation = .disabled
            signingConfiguration.validationChecks = validationChecks

            configuration.security = RegistryConfiguration.Security(
                default: RegistryConfiguration.Security.Global(
                    signing: signingConfiguration
                )
            )

            let signingEntityStorage = MockPackageSigningEntityStorage()
            let signingEntityCheckingMode = SigningEntityCheckingMode.strict

            let registryClient = makeRegistryClient(
                configuration: configuration,
                httpClient: httpClient,
                signingEntityStorage: signingEntityStorage,
                signingEntityCheckingMode: signingEntityCheckingMode
            )

            let signatureValidation = SignatureValidation(
                skipSignatureValidation: false,
                signingEntityStorage: signingEntityStorage,
                signingEntityCheckingMode: signingEntityCheckingMode,
                versionMetadataProvider: registryClient.getPackageVersionMetadata,
                delegate: RejectingSignatureValidationDelegate()
            )

            // Manifest signature doesn't match content so it's invalid
            await XCTAssertAsyncThrowsError(
                try await signatureValidation.validate(
                    registry: registry,
                    package: package,
                    version: version,
                    toolsVersion: .none,
                    manifestContent: manifestContent,
                    configuration: configuration.signing(for: package, registry: registry)
                )
            ) { error in
                guard case RegistryError.invalidSignature = error else {
                    return XCTFail("Expected RegistryError.invalidSignature, got '\(error)'")
                }
            }
        }
    }

    func testSignedManifest_certificateNotTrusted_shouldPrompt() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let keyAndCertChain = try self.ecSelfSignedTestKeyAndCertChain()
        let signingIdentity = try SwiftSigningIdentity(
            derEncodedCertificate: keyAndCertChain.leafCertificate,
            derEncodedPrivateKey: keyAndCertChain.privateKey,
            privateKeyType: .p256
        )
        let signatureFormat = SignatureFormat.cms_1_0_0
        let signatureBytes = try self.sign(
            content: emptyZipFile.contents,
            signingIdentity: signingIdentity,
            format: signatureFormat
        )

        let manifestSignatureBytes = try self.sign(
            content: Array(Self.unsignedManifest.utf8),
            signingIdentity: signingIdentity,
            format: signatureFormat
        )
        let manifestContent = """
        \(Self.unsignedManifest)
        // signature: cms-1.0.0;\(Data(manifestSignatureBytes).base64EncodedString())
        """

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum,
            signatureBytes: signatureBytes,
            signatureFormat: signatureFormat
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        var signingConfiguration = RegistryConfiguration.Security.Signing()
        signingConfiguration.onUntrustedCertificate = .prompt // intended for this test; don't change
        // Test root not written to trust roots directory
        signingConfiguration.includeDefaultTrustedRootCertificates = false
        var validationChecks = RegistryConfiguration.Security.Signing.ValidationChecks()
        validationChecks.certificateExpiration = .disabled
        validationChecks.certificateRevocation = .disabled
        signingConfiguration.validationChecks = validationChecks

        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: signingConfiguration
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // prompt returning false
        do {
            let signatureValidation = SignatureValidation(
                skipSignatureValidation: false,
                signingEntityStorage: signingEntityStorage,
                signingEntityCheckingMode: signingEntityCheckingMode,
                versionMetadataProvider: registryClient.getPackageVersionMetadata,
                delegate: RejectingSignatureValidationDelegate()
            )

            // Test root not trusted; onUntrustedCertificate is set to .prompt
            await XCTAssertAsyncThrowsError(
                try await signatureValidation.validate(
                    registry: registry,
                    package: package,
                    version: version,
                    toolsVersion: .none,
                    manifestContent: manifestContent,
                    configuration: configuration.signing(for: package, registry: registry)
                )
            ) { error in
                guard case RegistryError.signerNotTrusted = error else {
                    return XCTFail("Expected RegistryError.signerNotTrusted, got '\(error)'")
                }
            }
        }

        // prompt returning continue
        do {
            let signatureValidation = SignatureValidation(
                skipSignatureValidation: false,
                signingEntityStorage: signingEntityStorage,
                signingEntityCheckingMode: signingEntityCheckingMode,
                versionMetadataProvider: registryClient.getPackageVersionMetadata,
                delegate: AcceptingSignatureValidationDelegate()
            )

            // Package signer is not trusted, signingEntity should be nil
            let signingEntity = try await signatureValidation.validate(
                registry: registry,
                package: package,
                version: version,
                toolsVersion: .none,
                manifestContent: manifestContent,
                configuration: configuration.signing(for: package, registry: registry)
            )
            XCTAssertNil(signingEntity)
        }
    }

    func testSignedManifest_certificateNotTrusted_nonPrompt() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let package = identity.registry!
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(package.scope)/\(package.name)/\(version)")
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let keyAndCertChain = try self.ecSelfSignedTestKeyAndCertChain()
        let signingIdentity = try SwiftSigningIdentity(
            derEncodedCertificate: keyAndCertChain.leafCertificate,
            derEncodedPrivateKey: keyAndCertChain.privateKey,
            privateKeyType: .p256
        )
        let signatureFormat = SignatureFormat.cms_1_0_0
        let signatureBytes = try self.sign(
            content: emptyZipFile.contents,
            signingIdentity: signingIdentity,
            format: signatureFormat
        )

        let manifestSignatureBytes = try self.sign(
            content: Array(Self.unsignedManifest.utf8),
            signingIdentity: signingIdentity,
            format: signatureFormat
        )
        let manifestContent = """
        \(Self.unsignedManifest)
        // signature: cms-1.0.0;\(Data(manifestSignatureBytes).base64EncodedString())
        """

        // Get metadata endpoint will be called to see if package version is signed
        let handler: LegacyHTTPClient.Handler = LegacyHTTPClient.packageReleaseMetadataAPIHandler(
            metadataURL: metadataURL,
            checksum: checksum,
            signatureBytes: signatureBytes,
            signatureFormat: signatureFormat
        )
        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        var signingConfiguration = RegistryConfiguration.Security.Signing()
        signingConfiguration.onUntrustedCertificate = .error // intended for this test; don't change
        // Test root not written to trust roots directory
        signingConfiguration.includeDefaultTrustedRootCertificates = false
        var validationChecks = RegistryConfiguration.Security.Signing.ValidationChecks()
        validationChecks.certificateExpiration = .disabled
        validationChecks.certificateRevocation = .disabled
        signingConfiguration.validationChecks = validationChecks

        configuration.security = RegistryConfiguration.Security(
            default: RegistryConfiguration.Security.Global(
                signing: signingConfiguration
            )
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let signatureValidation = SignatureValidation(
            skipSignatureValidation: false,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode,
            versionMetadataProvider: registryClient.getPackageVersionMetadata,
            delegate: RejectingSignatureValidationDelegate()
        )

        let observability = ObservabilitySystem.makeForTesting()

        // Test root not trusted.
        // With the exception of .prompt, we log then continue.
        _ = try await signatureValidation.validate(
            registry: registry,
            package: package,
            version: version,
            toolsVersion: .none,
            manifestContent: manifestContent,
            configuration: configuration.signing(for: package, registry: registry),
            observabilityScope: observability.topScope
        )

        testDiagnostics(observability.diagnostics, problemsOnly: false) { result in
            let diagnostics = result.check(diagnostic: .contains("not trusted"), severity: .debug)
            XCTAssertEqual(diagnostics?.metadata?.packageIdentity, package.underlying)
        }
    }
    #endif

    private func sign(
        content: [UInt8],
        signingIdentity: SigningIdentity,
        intermediateCertificates: [[UInt8]] = [],
        format: SignatureFormat = .cms_1_0_0,
        observabilityScope: ObservabilityScope? = nil
    ) throws -> [UInt8] {
        try SignatureProvider.sign(
            content: content,
            identity: signingIdentity,
            intermediateCertificates: intermediateCertificates,
            format: format,
            observabilityScope: observabilityScope ?? ObservabilitySystem.NOOP
        )
    }

    private func ecSelfSignedTestKeyAndCertChain() throws -> KeyAndCertChain {
        try fixture(name: "Signing", createGitRepo: false) { fixturePath in
            let privateKey = try localFileSystem.readFileContents(
                fixturePath.appending(components: "Certificates", "Test_ec_self_signed_key.p8")
            ).contents
            let certificate = try localFileSystem.readFileContents(
                fixturePath.appending(components: "Certificates", "Test_ec_self_signed.cer")
            ).contents

            return KeyAndCertChain(
                privateKey: privateKey,
                certificateChain: [certificate]
            )
        }
    }

    private struct KeyAndCertChain {
        let privateKey: [UInt8]
        let certificateChain: [[UInt8]]

        var leafCertificate: [UInt8] {
            self.certificateChain.first!
        }

        var intermediateCertificates: [[UInt8]] {
            guard self.certificateChain.count > 1 else {
                return []
            }
            return Array(self.certificateChain.dropLast(1)[1...])
        }

        var rootCertificate: [UInt8] {
            self.certificateChain.last!
        }
    }
}

extension SignatureValidation {
    fileprivate func validate(
        registry: Registry,
        package: PackageIdentity.RegistryIdentity,
        version: Version,
        content: Data,
        configuration: RegistryConfiguration.Security.Signing,
        observabilityScope: ObservabilityScope? = nil
    ) async throws -> SigningEntity? {
        try await self.validate(
            registry: registry,
            package: package,
            version: version,
            content: content,
            configuration: configuration,
            timeout: nil,
            fileSystem: localFileSystem,
            observabilityScope: observabilityScope ?? ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
    }

    fileprivate func validate(
        registry: Registry,
        package: PackageIdentity.RegistryIdentity,
        version: Version,
        toolsVersion: ToolsVersion?,
        manifestContent: String,
        configuration: RegistryConfiguration.Security.Signing,
        observabilityScope: ObservabilityScope? = nil
    ) async throws -> SigningEntity? {
        try await self.validate(
            registry: registry,
            package: package,
            version: version,
            toolsVersion: toolsVersion,
            manifestContent: manifestContent,
            configuration: configuration,
            timeout: nil,
            fileSystem: localFileSystem,
            observabilityScope: observabilityScope ?? ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
    }
}

private struct RejectingSignatureValidationDelegate: SignatureValidation.Delegate {
    func onUnsigned(
        registry: Registry,
        package: PackageIdentity,
        version: Version,
        completion: (Bool) -> Void
    ) {
        completion(false)
    }

    func onUntrusted(
        registry: Registry,
        package: PackageIdentity,
        version: Version,
        completion: (Bool) -> Void
    ) {
        completion(false)
    }
}

private struct AcceptingSignatureValidationDelegate: SignatureValidation.Delegate {
    func onUnsigned(
        registry: Registry,
        package: PackageIdentity,
        version: Version,
        completion: (Bool) -> Void
    ) {
        completion(true)
    }

    func onUntrusted(
        registry: Registry,
        package: PackageIdentity,
        version: Version,
        completion: (Bool) -> Void
    ) {
        completion(true)
    }
}

extension PackageSigningEntityStorage {
    fileprivate func get(package: PackageIdentity) async throws -> PackageSigners {
        try await self.get(
            package: package,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
    }
}

extension LegacyHTTPClient {
    static func packageReleaseMetadataAPIHandler(
        metadataURL: URL,
        checksum: String
    ) -> LegacyHTTPClient.Handler {
        { request, _, completion in
            switch (request.method, request.url) {
            case (.get, metadataURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                let data = """
                {
                    "id": "mona.LinkedList",
                    "version": "1.1.1",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "description": "One thing links to another."
                    }
                }
                """.data(using: .utf8)!

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/json"),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }
    }

    static func packageReleaseMetadataAPIHandler(
        metadataURL: URL,
        checksum: String,
        signatureBytes: [UInt8],
        signatureFormat: SignatureFormat
    ) -> LegacyHTTPClient.Handler {
        { request, _, completion in
            switch (request.method, request.url) {
            case (.get, metadataURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                let data = """
                {
                    "id": "mona.LinkedList",
                    "version": "1.1.1",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)",
                            "signing": {
                                "signatureBase64Encoded": "\(Data(signatureBytes).base64EncodedString())",
                                "signatureFormat": "\(signatureFormat.rawValue)"
                            }
                        }
                    ],
                    "metadata": {
                        "description": "One thing links to another."
                    }
                }
                """.data(using: .utf8)!

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/json"),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }
    }
}
