//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import _InternalTestSupport
import XCTest

@testable import PackageCollections
import PackageCollectionsSigning

final class PackageCollectionSourceCertificatePolicyTests: XCTestCase {
    func testCustomData() {
        let sourceCertPolicy = PackageCollectionSourceCertificatePolicy(sourceCertPolicies: [
            "package-collection-1": [
                PackageCollectionSourceCertificatePolicy.CertificatePolicyConfig(
                    certPolicyKey: CertificatePolicyKey.default,
                    base64EncodedRootCerts: ["root-cert-1a", "root-cert-1b"]
                ),
                PackageCollectionSourceCertificatePolicy.CertificatePolicyConfig(
                    certPolicyKey: .default(subjectUserID: "test"),
                    base64EncodedRootCerts: ["root-cert-1c"]
                ),
            ],
            "package-collection-2": [PackageCollectionSourceCertificatePolicy.CertificatePolicyConfig(
                certPolicyKey: CertificatePolicyKey.default,
                base64EncodedRootCerts: ["root-cert-2"]
            )],
        ])
        let source1 = Model.CollectionSource(type: .json, url: "https://package-collection-1")
        let unsignedSource = Model.CollectionSource(type: .json, url: "https://package-collection-unsigned")

        XCTAssertEqual(["root-cert-1a", "root-cert-1b", "root-cert-1c", "root-cert-2"], sourceCertPolicy.allRootCerts?.sorted())

        XCTAssertTrue(sourceCertPolicy.mustBeSigned(source: source1))
        XCTAssertFalse(sourceCertPolicy.mustBeSigned(source: unsignedSource))

        XCTAssertEqual([.default, .default(subjectUserID: "test")], sourceCertPolicy.certificatePolicyKeys(for: source1))
        XCTAssertNil(sourceCertPolicy.certificatePolicyKeys(for: unsignedSource))
    }
}
