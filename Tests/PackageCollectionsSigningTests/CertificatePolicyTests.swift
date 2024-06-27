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
@testable import PackageCollectionsSigning
import _InternalTestSupport
import SwiftASN1
import X509
import XCTest

class CertificatePolicyTests: XCTestCase {
    func test_RSA_validate_happyCase() async throws {
        let certChain = try await self.readTestRSACertChain()
        let policy = TestCertificatePolicy(trustedRoots: certChain.suffix(1))

        try await policy.validate(
            certChain: certChain,
            validationTime: TestCertificatePolicy.testCertValidDate
        )
    }

    func test_EC_validate_happyCase() async throws {
        let certChain = try await self.readTestECCertChain()
        let policy = TestCertificatePolicy(trustedRoots: certChain.suffix(1))

        try await policy.validate(
            certChain: certChain,
            validationTime: TestCertificatePolicy.testCertValidDate
        )
    }

    func test_validate_untrustedRoot() async throws {
        let certChain = try await self.readTestRSACertChain()
        // Test root is not trusted
        let policy = TestCertificatePolicy(trustedRoots: nil)

        do {
            try await policy.validate(
                certChain: certChain,
                validationTime: TestCertificatePolicy.testCertValidDate
            )
            XCTFail("Expected error")
        } catch {
            guard CertificatePolicyError.invalidCertChain == error as? CertificatePolicyError else {
                return XCTFail("Expected CertificatePolicyError.invalidCertChain")
            }
        }
    }

    func test_validate_expiredCert() async throws {
        let certChain = try await self.readTestRSACertChain()
        let policy = TestCertificatePolicy(trustedRoots: certChain.suffix(1))

        // Use verify date outside of cert's validity period
        do {
            try await policy.validate(
                certChain: certChain,
                validationTime: TestCertificatePolicy.testCertInvalidDate
            )
            XCTFail("Expected error")
        } catch {
            guard CertificatePolicyError.invalidCertChain == error as? CertificatePolicyError else {
                return XCTFail("Expected CertificatePolicyError.invalidCertChain")
            }
        }
    }

    func test_validate_revoked() async throws {
        #if ENABLE_REAL_CERT_TEST
        #else
        try XCTSkipIf(true)
        #endif

        let certChain = try await self.readTestCertChain(
            paths: { fixturePath in
                [
                    fixturePath.appending(components: "Certificates", "development-revoked.cer"),
                    fixturePath.appending(components: "Certificates", "AppleWWDRCAG3.cer"),
                    fixturePath.appending(components: "Certificates", "AppleIncRoot.cer"),
                ]
            }
        )

        // Apple root certs are in SwiftPM's default trust store
        let policy = DefaultCertificatePolicy(
            trustedRootCertsDir: nil,
            additionalTrustedRootCerts: nil,
            observabilityScope: ObservabilitySystem.NOOP
        )

        do {
            try await policy.validate(certChain: certChain)
            XCTFail("Expected error")
        } catch {
            guard CertificatePolicyError.invalidCertChain == error as? CertificatePolicyError else {
                return XCTFail("Expected CertificatePolicyError.invalidCertChain")
            }
        }
    }

    func test_validate_defaultPolicy() async throws {
        #if ENABLE_REAL_CERT_TEST
        #else
        try XCTSkipIf(true)
        #endif

        let certChain = try await self.readTestCertChain(
            paths: { fixturePath in
                [
                    fixturePath.appending(components: "Certificates", "development.cer"),
                    fixturePath.appending(components: "Certificates", "AppleWWDRCAG3.cer"),
                    fixturePath.appending(components: "Certificates", "AppleIncRoot.cer"),
                ]
            }
        )

        do {
            // Apple root certs are in SwiftPM's default trust store
            let policy = DefaultCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: nil,
                observabilityScope: ObservabilitySystem.NOOP
            )
            try await policy.validate(certChain: certChain)
        }

        do {
            // What if `additionalTrustedRootCerts` has a cert that's already in the default trust store?
            let rootCA = certChain.last!
            let policy = DefaultCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: [rootCA],
                observabilityScope: ObservabilitySystem.NOOP
            )
            try await policy.validate(certChain: certChain)
        }

        do {
            // What if the same cert is in both `trustedRootCertsDir` and `additionalTrustedRootCerts`?
            try await withTemporaryDirectory { tmp in
                let rootCA = certChain.last!

                var serializer = DER.Serializer()
                try rootCA.serialize(into: &serializer)
                let rootCABytes = serializer.serializedBytes
                try localFileSystem.writeFileContents(
                    tmp.appending(components: "AppleIncRoot.cer"),
                    bytes: .init(rootCABytes)
                )

                let policy = DefaultCertificatePolicy(
                    trustedRootCertsDir: tmp.asURL,
                    additionalTrustedRootCerts: [rootCA],
                    observabilityScope: ObservabilitySystem.NOOP
                )
                try await policy.validate(certChain: certChain)
            }
        }
    }

    func test_validate_appleSwiftPackageCollectionPolicy_rsa() async throws {
        #if ENABLE_REAL_CERT_TEST
        #else
        try XCTSkipIf(true)
        #endif

        let certChain = try await self.readTestCertChain(
            paths: { fixturePath in
                [
                    fixturePath.appending(components: "Certificates", "swift_package_collection.cer"),
                    fixturePath.appending(components: "Certificates", "AppleWWDRCAG3.cer"),
                    fixturePath.appending(components: "Certificates", "AppleIncRoot.cer"),
                ]
            }
        )

        do {
            // Apple root certs are in SwiftPM's default trust store
            let policy = ADPSwiftPackageCollectionCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: nil,
                observabilityScope: ObservabilitySystem.NOOP
            )
            try await policy.validate(certChain: certChain)
        }

        do {
            // What if `additionalTrustedRootCerts` has a cert that's already in the default trust store?
            let rootCA = certChain.last!
            let policy = ADPSwiftPackageCollectionCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: [rootCA],
                observabilityScope: ObservabilitySystem.NOOP
            )
            try await policy.validate(certChain: certChain)
        }

        do {
            // What if the same cert is in both `trustedRootCertsDir` and `additionalTrustedRootCerts`?
            try await withTemporaryDirectory { tmp in
                let rootCA = certChain.last!

                var serializer = DER.Serializer()
                try rootCA.serialize(into: &serializer)
                let rootCABytes = serializer.serializedBytes
                try localFileSystem.writeFileContents(
                    tmp.appending(components: "AppleIncRoot.cer"),
                    bytes: .init(rootCABytes)
                )

                let policy = ADPSwiftPackageCollectionCertificatePolicy(
                    trustedRootCertsDir: tmp.asURL,
                    additionalTrustedRootCerts: [rootCA],
                    observabilityScope: ObservabilitySystem.NOOP
                )
                try await policy.validate(certChain: certChain)
            }
        }
    }

    func test_validate_appleSwiftPackageCollectionPolicy_ec() async throws {
        #if ENABLE_REAL_CERT_TEST
        #else
        try XCTSkipIf(true)
        #endif

        let certChain = try await self.readTestCertChain(
            paths: { fixturePath in
                [
                    fixturePath.appending(components: "Certificates", "swift_package.cer"),
                    fixturePath.appending(components: "Certificates", "AppleWWDRCAG6.cer"),
                    fixturePath.appending(components: "Certificates", "AppleRootCAG3.cer"),
                ]
            }
        )

        do {
            // Apple root certs are in SwiftPM's default trust store
            let policy = ADPSwiftPackageCollectionCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: nil,
                observabilityScope: ObservabilitySystem.NOOP
            )
            try await policy.validate(certChain: certChain)
        }

        do {
            // What if `additionalTrustedRootCerts` has a cert that's already in the default trust store?
            let rootCA = certChain.last!
            let policy = ADPSwiftPackageCollectionCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: [rootCA],
                observabilityScope: ObservabilitySystem.NOOP
            )
            try await policy.validate(certChain: certChain)
        }

        do {
            // What if the same cert is in both `trustedRootCertsDir` and `additionalTrustedRootCerts`?
            try await withTemporaryDirectory { tmp in
                let rootCA = certChain.last!

                var serializer = DER.Serializer()
                try rootCA.serialize(into: &serializer)
                let rootCABytes = serializer.serializedBytes
                try localFileSystem.writeFileContents(
                    tmp.appending(components: "AppleIncRoot.cer"),
                    bytes: .init(rootCABytes)
                )

                let policy = ADPSwiftPackageCollectionCertificatePolicy(
                    trustedRootCertsDir: tmp.asURL,
                    additionalTrustedRootCerts: [rootCA],
                    observabilityScope: ObservabilitySystem.NOOP
                )
                try await policy.validate(certChain: certChain)
            }
        }
    }

    func test_validate_defaultPolicy_user() async throws {
        #if ENABLE_REAL_CERT_TEST
        #else
        try XCTSkipIf(true)
        #endif

        let certChain = try await self.readTestCertChain(
            paths: { fixturePath in
                [
                    fixturePath.appending(components: "Certificates", "development.cer"),
                    fixturePath.appending(components: "Certificates", "AppleWWDRCAG3.cer"),
                    fixturePath.appending(components: "Certificates", "AppleIncRoot.cer"),
                ]
            }
        )

        do {
            // Apple root certs are in SwiftPM's default trust store
            // Subject user ID matches
            let policy = DefaultCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: nil,
                expectedSubjectUserID: expectedSubjectUserID,
                expectedSubjectOrganizationalUnit: nil,
                observabilityScope: ObservabilitySystem.NOOP
            )
            try await policy.validate(certChain: certChain)
        }

        do {
            // Apple root certs are in SwiftPM's default trust store
            // Subject user ID does not match
            let policy = DefaultCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: nil,
                expectedSubjectUserID: "\(expectedSubjectUserID)-2",
                expectedSubjectOrganizationalUnit: nil,
                observabilityScope: ObservabilitySystem.NOOP
            )

            do {
                try await policy.validate(certChain: certChain)
                XCTFail("Expected error")
            } catch {
                guard CertificatePolicyError.invalidCertChain == error as? CertificatePolicyError else {
                    return XCTFail("Expected CertificatePolicyError.invalidCertChain")
                }
            }
        }

        do {
            // Apple root certs are in SwiftPM's default trust store
            // Subject organizational unit matches
            let policy = DefaultCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: nil,
                expectedSubjectUserID: nil,
                expectedSubjectOrganizationalUnit: expectedSubjectOrgUnit,
                observabilityScope: ObservabilitySystem.NOOP
            )
            try await policy.validate(certChain: certChain)
        }

        do {
            // Apple root certs are in SwiftPM's default trust store
            // Subject organizational unit does not match
            let policy = DefaultCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: nil,
                expectedSubjectUserID: nil,
                expectedSubjectOrganizationalUnit: "\(expectedSubjectOrgUnit)-2",
                observabilityScope: ObservabilitySystem.NOOP
            )

            do {
                try await policy.validate(certChain: certChain)
                XCTFail("Expected error")
            } catch {
                guard CertificatePolicyError.invalidCertChain == error as? CertificatePolicyError else {
                    return XCTFail("Expected CertificatePolicyError.invalidCertChain")
                }
            }
        }
    }

    func test_validate_appleSwiftPackageCollectionPolicy_rsa_user() async throws {
        #if ENABLE_REAL_CERT_TEST
        #else
        try XCTSkipIf(true)
        #endif

        let certChain = try await self.readTestCertChain(
            paths: { fixturePath in
                [
                    fixturePath.appending(components: "Certificates", "swift_package_collection.cer"),
                    fixturePath.appending(components: "Certificates", "AppleWWDRCAG3.cer"),
                    fixturePath.appending(components: "Certificates", "AppleIncRoot.cer"),
                ]
            }
        )

        do {
            // Apple root certs are in SwiftPM's default trust store
            // Subject user ID matches
            let policy = ADPSwiftPackageCollectionCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: nil,
                expectedSubjectUserID: expectedSubjectUserID,
                expectedSubjectOrganizationalUnit: nil,
                observabilityScope: ObservabilitySystem.NOOP
            )
            try await policy.validate(certChain: certChain)
        }

        do {
            // Apple root certs are in SwiftPM's default trust store
            // Subject user ID does not match
            let policy = ADPSwiftPackageCollectionCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: nil,
                expectedSubjectUserID: "\(expectedSubjectUserID)-2",
                expectedSubjectOrganizationalUnit: nil,
                observabilityScope: ObservabilitySystem.NOOP
            )

            do {
                try await policy.validate(certChain: certChain)
                XCTFail("Expected error")
            } catch {
                guard CertificatePolicyError.invalidCertChain == error as? CertificatePolicyError else {
                    return XCTFail("Expected CertificatePolicyError.invalidCertChain")
                }
            }
        }

        do {
            // Apple root certs are in SwiftPM's default trust store
            // Subject organizational unit matches
            let policy = ADPSwiftPackageCollectionCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: nil,
                expectedSubjectUserID: nil,
                expectedSubjectOrganizationalUnit: expectedSubjectOrgUnit,
                observabilityScope: ObservabilitySystem.NOOP
            )
            try await policy.validate(certChain: certChain)
        }

        do {
            // Apple root certs are in SwiftPM's default trust store
            // Subject organizational unit does not match
            let policy = ADPSwiftPackageCollectionCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: nil,
                expectedSubjectUserID: nil,
                expectedSubjectOrganizationalUnit: "\(expectedSubjectOrgUnit)-2",
                observabilityScope: ObservabilitySystem.NOOP
            )

            do {
                try await policy.validate(certChain: certChain)
                XCTFail("Expected error")
            } catch {
                guard CertificatePolicyError.invalidCertChain == error as? CertificatePolicyError else {
                    return XCTFail("Expected CertificatePolicyError.invalidCertChain")
                }
            }
        }
    }

    func test_validate_appleSwiftPackageCollectionPolicy_ec_user() async throws {
        #if ENABLE_REAL_CERT_TEST
        #else
        try XCTSkipIf(true)
        #endif

        let certChain = try await self.readTestCertChain(
            paths: { fixturePath in
                [
                    fixturePath.appending(components: "Certificates", "swift_package.cer"),
                    fixturePath.appending(components: "Certificates", "AppleWWDRCAG6.cer"),
                    fixturePath.appending(components: "Certificates", "AppleRootCAG3.cer"),
                ]
            }
        )

        do {
            // Apple root certs are in SwiftPM's default trust store
            // Subject user ID matches
            let policy = ADPSwiftPackageCollectionCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: nil,
                expectedSubjectUserID: expectedSubjectUserID,
                expectedSubjectOrganizationalUnit: nil,
                observabilityScope: ObservabilitySystem.NOOP
            )
            try await policy.validate(certChain: certChain)
        }

        do {
            // Apple root certs are in SwiftPM's default trust store
            // Subject user ID does not match
            let policy = ADPSwiftPackageCollectionCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: nil,
                expectedSubjectUserID: "\(expectedSubjectUserID)-2",
                expectedSubjectOrganizationalUnit: nil,
                observabilityScope: ObservabilitySystem.NOOP
            )

            do {
                try await policy.validate(certChain: certChain)
                XCTFail("Expected error")
            } catch {
                guard CertificatePolicyError.invalidCertChain == error as? CertificatePolicyError else {
                    return XCTFail("Expected CertificatePolicyError.invalidCertChain")
                }
            }
        }

        do {
            // Apple root certs are in SwiftPM's default trust store
            // Subject organizational unit matches
            let policy = ADPSwiftPackageCollectionCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: nil,
                expectedSubjectUserID: nil,
                expectedSubjectOrganizationalUnit: expectedSubjectOrgUnit,
                observabilityScope: ObservabilitySystem.NOOP
            )
            try await policy.validate(certChain: certChain)
        }

        do {
            // Apple root certs are in SwiftPM's default trust store
            // Subject organizational unit does not match
            let policy = ADPSwiftPackageCollectionCertificatePolicy(
                trustedRootCertsDir: nil,
                additionalTrustedRootCerts: nil,
                expectedSubjectUserID: nil,
                expectedSubjectOrganizationalUnit: "\(expectedSubjectOrgUnit)-2",
                observabilityScope: ObservabilitySystem.NOOP
            )

            do {
                try await policy.validate(certChain: certChain)
                XCTFail("Expected error")
            } catch {
                guard CertificatePolicyError.invalidCertChain == error as? CertificatePolicyError else {
                    return XCTFail("Expected CertificatePolicyError.invalidCertChain")
                }
            }
        }
    }

    private func readTestRSACertChain() async throws -> [Certificate] {
        try await self.readTestCertChain(
            paths: { fixturePath in
                [
                    fixturePath.appending(components: "Certificates", "Test_rsa.cer"),
                    fixturePath.appending(components: "Certificates", "TestIntermediateCA.cer"),
                    fixturePath.appending(components: "Certificates", "TestRootCA.cer"),
                ]
            }
        )
    }

    private func readTestECCertChain() async throws -> [Certificate] {
        try await self.readTestCertChain(
            paths: { fixturePath in
                [
                    fixturePath.appending(components: "Certificates", "Test_ec.cer"),
                    fixturePath.appending(components: "Certificates", "TestIntermediateCA.cer"),
                    fixturePath.appending(components: "Certificates", "TestRootCA.cer"),
                ]
            }
        )
    }

    private func readTestCertChain(paths: (AbsolutePath) -> [AbsolutePath]) async throws -> [Certificate] {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try fixture(name: "Signing", createGitRepo: false) { fixturePath in
                    let certPaths = paths(fixturePath)
                    let certificates = try certPaths.map { certPath in
                        try Certificate(derEncoded: try localFileSystem.readFileContents(certPath).contents)
                    }
                    continuation.resume(returning: certificates)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
