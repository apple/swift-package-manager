//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import _InternalTestSupport
import XCTest

@testable import PackageCollectionsModel

class PackageCollectionModelTests: XCTestCase {
    typealias Model = PackageCollectionModel.V1

    func testCollectionCodable() throws {
        let packages = [
            Model.Collection.Package(
                url: "https://package-collection-tests.com/repos/foobar.git",
                identity: "foo.bar",
                summary: "Package Foobar",
                keywords: ["test package"],
                versions: [
                    Model.Collection.Package.Version(
                        version: "1.3.2",
                        summary: "Fix a few bugs",
                        manifests: [
                            "5.2": Model.Collection.Package.Version.Manifest(
                                toolsVersion: "5.2",
                                packageName: "Foobar",
                                targets: [.init(name: "Foo", moduleName: "Foo")],
                                products: [.init(name: "Bar", type: .library(.automatic), targets: ["Foo"])],
                                minimumPlatformVersions: [.init(name: "macOS", version: "10.15")]
                            ),
                        ],
                        defaultToolsVersion: "5.2",
                        verifiedCompatibility: [Model.Compatibility(platform: Model.Platform(name: "macOS"), swiftVersion: "5.2")],
                        license: .init(name: "Apache-2.0", url: "https://package-collection-tests.com/repos/foobar/LICENSE"),
                        author: .init(name: "J. Appleseed"),
                        signer: .init(
                            type: "ADP",
                            commonName: "J. Appleseed",
                            organizationalUnitName: "A1",
                            organizationName: "Appleseed Inc."
                        ),
                        createdAt: Date()
                    ),
                ],
                readmeURL: "https://package-collection-tests.com/repos/foobar/README",
                license: .init(name: "Apache-2.0", url: "https://package-collection-tests.com/repos/foobar/LICENSE")
            ),
        ]
        let collection = Model.Collection(
            name: "Test Package Collection",
            overview: "A test package collection",
            keywords: ["swift packages"],
            packages: packages,
            formatVersion: .v1_0,
            revision: 3,
            generatedAt: Date(),
            generatedBy: .init(name: "Jane Doe")
        )

        let data = try JSONEncoder().encode(collection)
        let decoded = try JSONDecoder().decode(Model.Collection.self, from: data)
        XCTAssertEqual(collection, decoded)
    }

    func testSignedCollectionCodable() throws {
        let packages = [
            Model.Collection.Package(
                url: "https://package-collection-tests.com/repos/foobar.git",
                identity: "foo.bar",
                summary: "Package Foobar",
                keywords: ["test package"],
                versions: [
                    Model.Collection.Package.Version(
                        version: "1.3.2",
                        summary: "Fix a few bugs",
                        manifests: [
                            "5.2": Model.Collection.Package.Version.Manifest(
                                toolsVersion: "5.2",
                                packageName: "Foobar",
                                targets: [.init(name: "Foo", moduleName: "Foo")],
                                products: [.init(name: "Bar", type: .library(.automatic), targets: ["Foo"])],
                                minimumPlatformVersions: [.init(name: "macOS", version: "10.15")]
                            ),
                        ],
                        defaultToolsVersion: "5.2",
                        verifiedCompatibility: [Model.Compatibility(platform: Model.Platform(name: "macOS"), swiftVersion: "5.2")],
                        license: .init(name: "Apache-2.0", url: "https://package-collection-tests.com/repos/foobar/LICENSE"),
                        author: .init(name: "J. Appleseed"),
                        signer: .init(
                            type: "ADP",
                            commonName: "J. Appleseed",
                            organizationalUnitName: "A1",
                            organizationName: "Appleseed Inc."
                        ),
                        createdAt: Date()
                    ),
                ],
                readmeURL: "https://package-collection-tests.com/repos/foobar/README",
                license: .init(name: "Apache-2.0", url: "https://package-collection-tests.com/repos/foobar/LICENSE")
            ),
        ]
        let collection = Model.Collection(
            name: "Test Package Collection",
            overview: "A test package collection",
            keywords: ["swift packages"],
            packages: packages,
            formatVersion: .v1_0,
            revision: 3,
            generatedAt: Date(),
            generatedBy: .init(name: "Jane Doe")
        )
        let signature = Model.Signature(
            signature: "<SIGNATURE>",
            certificate: Model.Signature.Certificate(
                subject: .init(userID: "Test User ID", commonName: "Test Subject", organizationalUnit: "Test Org Unit", organization: "Test Org"),
                issuer: .init(userID: nil, commonName: "Test Issuer", organizationalUnit: nil, organization: nil)
            )
        )
        let signedCollection = Model.SignedCollection(collection: collection, signature: signature)

        let data = try JSONEncoder().encode(signedCollection)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Model.SignedCollection.self, from: data)
        XCTAssertEqual(signedCollection, decoded)
    }
}
