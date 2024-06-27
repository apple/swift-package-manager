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

import _CryptoExtras
import Basics
import Crypto
import Foundation
@testable import PackageCollectionsSigning
import _InternalTestSupport
import X509
import XCTest

class SignatureTests: XCTestCase {
    func test_RS256_generateAndValidate_happyCase() async throws {
        let jsonEncoder = JSONEncoder.makeWithDefaults()
        let jsonDecoder = JSONDecoder.makeWithDefaults()

        let certData = try await self.readTestCertData(
            path: { fixturePath in fixturePath.appending(components: "Certificates", "Test_rsa.cer") }
        )
        let certBase64Encoded = certData.base64EncodedString()
        let certificate = try Certificate(derEncoded: Array(certData))

        let payload = ["foo": "bar"]
        let privateKey = try _RSA.Signing.PrivateKey(pemRepresentation: certRSAPrivateKey)
        let signature = try Signature.generate(
            payload: payload,
            certChainData: [certData],
            jsonEncoder: jsonEncoder,
            signatureAlgorithm: .RS256
        ) {
            try privateKey.signature(for: SHA256.hash(data: $0), padding: Signature.rsaSigningPadding).rawRepresentation
        }

        let parsedSignature = try await Signature.parse(
            signature,
            certChainValidate: { _ in [certificate] },
            jsonDecoder: jsonDecoder
        )
        XCTAssertEqual(try jsonDecoder.decode([String: String].self, from: parsedSignature.payload), payload)
        XCTAssertEqual(parsedSignature.header.algorithm, Signature.Algorithm.RS256)
        XCTAssertEqual(parsedSignature.header.certChain, [certBase64Encoded])
    }

    func test_RS256_generateAndValidate_keyMismatch() async throws {
        let jsonEncoder = JSONEncoder.makeWithDefaults()
        let jsonDecoder = JSONDecoder.makeWithDefaults()

        let certData = try await self.readTestCertData(
            path: { fixturePath in fixturePath.appending(components: "Certificates", "Test_rsa.cer") }
        )
        let certificate = try Certificate(derEncoded: Array(certData))

        let payload = ["foo": "bar"]
        // This is not cert's key so `parse` will fail
        let privateKey = try _RSA.Signing.PrivateKey(pemRepresentation: rsaPrivateKey)
        let signature = try Signature.generate(
            payload: payload,
            certChainData: [certData],
            jsonEncoder: jsonEncoder,
            signatureAlgorithm: .RS256
        ) {
            try privateKey.signature(for: SHA256.hash(data: $0), padding: Signature.rsaSigningPadding).rawRepresentation
        }

        do {
            _ = try await Signature.parse(
                signature,
                certChainValidate: { _ in [certificate] },
                jsonDecoder: jsonDecoder
            )
            XCTFail("Expected error")
        } catch {
            guard SignatureError.invalidSignature == error as? SignatureError else {
                return XCTFail("Expected SignatureError.invalidSignature")
            }
        }
    }

    func test_ES256_generateAndValidate_happyCase() async throws {
        let jsonEncoder = JSONEncoder.makeWithDefaults()
        let jsonDecoder = JSONDecoder.makeWithDefaults()

        let certData = try await self.readTestCertData(
            path: { fixturePath in fixturePath.appending(components: "Certificates", "Test_ec.cer") }
        )
        let certBase64Encoded = certData.base64EncodedString()
        let certificate = try Certificate(derEncoded: Array(certData))

        let payload = ["foo": "bar"]
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: certECPrivateKey)
        let signature = try Signature.generate(
            payload: payload,
            certChainData: [certData],
            jsonEncoder: jsonEncoder,
            signatureAlgorithm: .ES256
        ) {
            try privateKey.signature(for: SHA256.hash(data: $0)).rawRepresentation
        }

        let parsedSignature = try await Signature.parse(
            signature,
            certChainValidate: { _ in [certificate] },
            jsonDecoder: jsonDecoder
        )

        XCTAssertEqual(try jsonDecoder.decode([String: String].self, from: parsedSignature.payload), payload)
        XCTAssertEqual(parsedSignature.header.algorithm, Signature.Algorithm.ES256)
        XCTAssertEqual(parsedSignature.header.certChain, [certBase64Encoded])
    }

    func test_ES256_generateAndValidate_keyMismatch() async throws {
        let jsonEncoder = JSONEncoder.makeWithDefaults()
        let jsonDecoder = JSONDecoder.makeWithDefaults()

        let certData = try await self.readTestCertData(
            path: { fixturePath in fixturePath.appending(components: "Certificates", "Test_ec.cer") }
        )
        let certificate = try Certificate(derEncoded: Array(certData))

        let payload = ["foo": "bar"]
        // This is not cert's key so `parse` will fail
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: ecPrivateKey)
        let signature = try Signature.generate(
            payload: payload,
            certChainData: [certData],
            jsonEncoder: jsonEncoder,
            signatureAlgorithm: .ES256
        ) {
            try privateKey.signature(for: SHA256.hash(data: $0)).rawRepresentation
        }

        do {
            _ = try await Signature.parse(
                signature,
                certChainValidate: { _ in [certificate] },
                jsonDecoder: jsonDecoder
            )
            XCTFail("Expected error")
        } catch {
            guard SignatureError.invalidSignature == error as? SignatureError else {
                return XCTFail("Expected SignatureError.invalidSignature")
            }
        }
    }

    private func readTestCertData(path: (AbsolutePath) -> AbsolutePath) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try fixture(name: "Signing", createGitRepo: false) { fixturePath in
                    let certPath = path(fixturePath)
                    let certData: Data = try localFileSystem.readFileContents(certPath)
                    continuation.resume(returning: certData)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
