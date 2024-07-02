//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import struct Foundation.Date
import struct Foundation.URL
import struct Foundation.UUID
@testable import PackageCollections
import PackageCollectionsModel
import PackageCollectionsSigning
import PackageModel
import SourceControl

import struct TSCUtility.Version

func makeMockSources(count: Int = Int.random(in: 5 ... 10)) -> [PackageCollectionsModel.CollectionSource] {
    let isTrusted: [Bool?] = [true, false, nil]
    return (0 ..< count).map { index in
        .init(type: .json, url: "https://source-\(index)", isTrusted: isTrusted.randomElement()!)
    }
}

fileprivate let platforms: [PackageModel.Platform] = [.macOS, .iOS, .tvOS, .watchOS, .linux, .android, .windows, .wasi, .openbsd]
fileprivate let supportedPlatforms: [PackageModel.SupportedPlatform] = [
    .init(platform: .macOS, version: .init("10.15")),
    .init(platform: .iOS, version: .init("13")),
    .init(platform: .watchOS, version: "6"),
]

func makeMockCollections(count: Int = Int.random(in: 50 ... 100), maxPackages: Int = 50, signed: Bool = true) -> [PackageCollectionsModel.Collection] {
    (0 ..< count).map { collectionIndex in
        let packages = (0 ..< Int.random(in: min(5, maxPackages) ... maxPackages)).map { packageIndex -> PackageCollectionsModel.Package in
            makeMockPackage(id: "package-\(packageIndex)")
        }

        var signature: PackageCollectionsModel.SignatureData?
        if signed {
            signature = .init(
                certificate: PackageCollectionsModel.SignatureData.Certificate(
                    subject: .init(userID: nil, commonName: "subject-\(collectionIndex)", organizationalUnit: nil, organization: nil),
                    issuer: .init(userID: nil, commonName: "issuer-\(collectionIndex)", organizationalUnit: nil, organization: nil)
                ),
                isVerified: true
            )
        }

        return PackageCollectionsModel.Collection(source: .init(type: .json, url: "https://feed-\(collectionIndex)"),
                                                  name: "collection \(collectionIndex)",
                                                  overview: "collection \(collectionIndex) description",
                                                  keywords: (0 ..< Int.random(in: 1 ... 3)).map { "keyword \($0)" },
                                                  packages: packages,
                                                  createdAt: Date(),
                                                  createdBy: PackageCollectionsModel.Collection.Author(name: "Jane Doe"),
                                                  signature: signature)
    }
}

func makeMockPackage(id: String) -> PackageCollectionsModel.Package {
    let versions = (0 ..< Int.random(in: 1 ... 3)).map { versionIndex -> PackageCollectionsModel.Package.Version in
        let targets = (0 ..< Int.random(in: 1 ... 5)).map {
            PackageCollectionsModel.Target(name: "\(id)-target-\($0)",
                                           moduleName: "module-\(id)-target-\($0)")
        }
        let products = (0 ..< Int.random(in: 1 ... 3)).map {
            PackageCollectionsModel.Product(name: "\(id)-product-\($0)",
                                            type: .executable,
                                            targets: targets)
        }
        let minimumPlatformVersions = (0 ..< Int.random(in: 1 ... 2)).map { _ in supportedPlatforms.randomElement()! }
        let toolsVersion = ToolsVersion(string: "5.2")!
        let manifests = [toolsVersion: PackageCollectionsModel.Package.Version.Manifest(
            toolsVersion: toolsVersion,
            packageName: id,
            targets: targets,
            products: products,
            minimumPlatformVersions: minimumPlatformVersions
        )]

        let verifiedCompatibility = (0 ..< Int.random(in: 1 ... 3)).map { _ in
            PackageCollectionsModel.Compatibility(
                platform: platforms.randomElement()!,
                swiftVersion: SwiftLanguageVersion.knownSwiftLanguageVersions.randomElement()!
            )
        }
        let licenseType = PackageCollectionsModel.LicenseType.allCases.randomElement()!
        let license = PackageCollectionsModel.License(type: licenseType, url: "http://\(licenseType).license")

        return PackageCollectionsModel.Package.Version(version: TSCUtility.Version(versionIndex, 0, 0),
                                                       title: nil,
                                                       summary: "\(versionIndex) description",
                                                       manifests: manifests,
                                                       defaultToolsVersion: toolsVersion,
                                                       verifiedCompatibility: verifiedCompatibility,
                                                       license: license,
                                                       author: nil,
                                                       signer: nil,
                                                       createdAt: Date())
    }

    return PackageCollectionsModel.Package(identity: PackageIdentity.plain("test-\(id).\(id)"),
                                           location: "https://\(id)",
                                           summary: "\(id) description",
                                           keywords: (0 ..< Int.random(in: 1 ... 3)).map { "keyword \($0)" },
                                           versions: versions,
                                           watchersCount: Int.random(in: 1 ... 1000),
                                           readmeURL: "https://\(id)-readme",
                                           license: PackageCollectionsModel.License(type: .Apache2_0, url: "https://\(id).license"),
                                           authors: nil,
                                           languages: nil)
}

func makeMockPackageBasicMetadata() -> PackageCollectionsModel.PackageBasicMetadata {
    return .init(summary: UUID().uuidString,
                 keywords: (0 ..< Int.random(in: 1 ... 3)).map { "keyword \($0)" },
                 versions: (0 ..< Int.random(in: 1 ... 10)).map { .init(
                    version: TSCUtility.Version($0, 0, 0),
                    title: "title \($0)",
                    summary: "description \($0)",
                    author: nil,
                    createdAt: Date()
                 )},
                 watchersCount: Int.random(in: 0 ... 50),
                 readmeURL: "https://package-readme",
                 license: PackageCollectionsModel.License(type: .Apache2_0, url: "https://package-license"),
                 authors: (0 ..< Int.random(in: 1 ... 10)).map { .init(username: "\($0)", url: nil, service: nil) },
                 languages: ["Swift"])
}

func makeMockStorage(_ collectionsStorageConfig: SQLitePackageCollectionsStorage.Configuration = .init()) -> PackageCollections.Storage {
    let mockFileSystem = InMemoryFileSystem()
    return .init(
        sources: FilePackageCollectionsSourcesStorage(fileSystem: mockFileSystem),
        collections: SQLitePackageCollectionsStorage(
            location: .memory,
            configuration: collectionsStorageConfig,
            observabilityScope: ObservabilitySystem.NOOP
        )
    )
}

struct MockCollectionsProvider: PackageCollectionProvider {
    let collections: [PackageCollectionsModel.Collection]
    let collectionsWithInvalidSignature: Set<PackageCollectionsModel.CollectionSource>?

    init(_ collections: [PackageCollectionsModel.Collection], collectionsWithInvalidSignature: Set<PackageCollectionsModel.CollectionSource>? = nil) {
        self.collections = collections
        self.collectionsWithInvalidSignature = collectionsWithInvalidSignature
    }

    func get(_ source: PackageCollectionsModel.CollectionSource) async throws -> PackageCollectionsModel.Collection {
        if let collection = (self.collections.first { $0.source == source }) {
            if self.collectionsWithInvalidSignature?.contains(source) ?? false {
                throw PackageCollectionError.invalidSignature
            }
            return collection
        }
        throw NotFoundError("\(source)")
    }
}

struct MockMetadataProvider: PackageMetadataProvider {
    let name: String = "MockMetadataProvider"

    let packages: [PackageIdentity: PackageCollectionsModel.PackageBasicMetadata]

    init(_ packages: [PackageIdentity: PackageCollectionsModel.PackageBasicMetadata]) {
        self.packages = packages
    }

    func get(
        identity: PackageIdentity,
        location: String
    ) async -> (Result<PackageCollectionsModel.PackageBasicMetadata, Error>, PackageMetadataProviderContext?) {
        guard let packageMetadata = self.packages[identity] else {
            return (.failure(NotFoundError("\(identity)")), nil)
        }
        return (.success(packageMetadata), nil)
    }
}

struct MockCollectionSignatureValidator: PackageCollectionSignatureValidator {
    let collections: Set<String>
    let certPolicyKeys: Set<CertificatePolicyKey>
    let hasTrustedRootCerts: Bool

    init(_ collections: Set<String> = [], certPolicyKeys: Set<CertificatePolicyKey> = [], hasTrustedRootCerts: Bool = true) {
        self.collections = collections
        self.certPolicyKeys = certPolicyKeys
        self.hasTrustedRootCerts = hasTrustedRootCerts
    }

    func validate(
        signedCollection: PackageCollectionModel.V1.SignedCollection,
        certPolicyKey: CertificatePolicyKey
    ) async throws {
        guard self.hasTrustedRootCerts else {
            throw PackageCollectionSigningError.noTrustedRootCertsConfigured
        }

        if self.collections.contains(signedCollection.collection.name) || self.certPolicyKeys.contains(certPolicyKey) {
            return
        } else {
            throw PackageCollectionSigningError.invalidSignature
        }
    }
}
