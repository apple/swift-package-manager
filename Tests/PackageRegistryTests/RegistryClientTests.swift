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
import Foundation
import PackageFingerprint
import PackageLoading
import PackageModel
@testable import PackageRegistry
import PackageSigning
import _InternalTestSupport
import XCTest

import protocol TSCBasic.HashAlgorithm
import class TSCBasic.InMemoryFileSystem

import struct TSCUtility.Version

final class RegistryClientTests: XCTestCase {
    func testGetPackageMetadata() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let releasesURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)")

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, releasesURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                let data = #"""
                {
                    "releases": {
                        "1.1.1": {
                            "url": "https://packages.example.com/mona/LinkedList/1.1.1"
                        },
                        "1.1.0": {
                            "url": "https://packages.example.com/mona/LinkedList/1.1.0",
                            "problem": {
                                "status": 410,
                                "title": "Gone",
                                "detail": "this release was removed from the registry"
                            }
                        },
                        "1.0.0": {
                            "url": "https://packages.example.com/mona/LinkedList/1.0.0"
                        }
                    }
                }
                """#.data(using: .utf8)!

                let links = """
                <https://github.com/mona/LinkedList>; rel="canonical",
                <ssh://git@github.com:mona/LinkedList.git>; rel="alternate",
                <git@github.com:mona/LinkedList.git>; rel="alternate",
                <https://gitlab.com/mona/LinkedList>; rel="alternate"
                """

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/json"),
                        .init(name: "Content-Version", value: "1"),
                        .init(name: "Link", value: links),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        let metadata = try await registryClient.getPackageMetadata(package: identity)
        XCTAssertEqual(metadata.versions, ["1.1.1", "1.0.0"])
        XCTAssertEqual(metadata.alternateLocations!, [
            SourceControlURL("https://github.com/mona/LinkedList"),
            SourceControlURL("ssh://git@github.com:mona/LinkedList.git"),
            SourceControlURL("git@github.com:mona/LinkedList.git"),
            SourceControlURL("https://gitlab.com/mona/LinkedList"),
        ])
    }

    func testGetPackageMetadata_NotFound() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let releasesURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)")

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: releasesURL,
            errorCode: 404,
            errorDescription: UUID().uuidString
        )

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(try await registryClient.getPackageMetadata(package: identity)) { error in
            guard case RegistryError.failedRetrievingReleases(
                registry: configuration.defaultRegistry!,
                package: identity,
                error: RegistryError.packageNotFound
            ) = error else {
                return XCTFail("unexpected error: '\(error)'")
            }
        }
    }

    func testGetPackageMetadata_ServerError() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let releasesURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)")

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: releasesURL,
            errorCode: Int.random(in: 405 ..< 500),
            errorDescription: UUID().uuidString
        )

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(try await registryClient.getPackageMetadata(package: identity)) { error in
            guard case RegistryError
                .failedRetrievingReleases(
                    registry: configuration.defaultRegistry!,
                    package: identity,
                    error: RegistryError.serverError(
                        code: serverErrorHandler.errorCode,
                        details: serverErrorHandler.errorDescription
                    )
                ) = error
            else {
                return XCTFail("unexpected error: '\(error)'")
            }
        }
    }

    func testGetPackageMetadata_RegistryNotAvailable() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")

        let serverErrorHandler = UnavailableServerErrorHandler(registryURL: registryURL)

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: true)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(try await registryClient.getPackageMetadata(package: identity)) { error in
            guard case RegistryError.registryNotAvailable(registry) = error
            else {
                return XCTFail("unexpected error: '\(error)'")
            }
        }
    }

    func testGetPackageVersionMetadata() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let releaseURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, releaseURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                let data = #"""
                {
                    "id": "mona.LinkedList",
                    "version": "1.1.1",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"
                        }
                    ],
                    "metadata": {
                        "author": {
                            "name": "J. Appleseed"
                        },
                        "licenseURL": "https://github.com/mona/LinkedList/license",
                        "readmeURL": "https://github.com/mona/LinkedList/readme",
                        "repositoryURLs": [
                            "https://github.com/mona/LinkedList",
                            "ssh://git@github.com:mona/LinkedList.git",
                            "git@github.com:mona/LinkedList.git"
                        ]
                    }
                }
                """#.data(using: .utf8)!

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

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        let metadata = try await registryClient.getPackageVersionMetadata(package: identity, version: version)
        XCTAssertEqual(metadata.resources.count, 1)
        XCTAssertEqual(metadata.resources[0].name, "source-archive")
        XCTAssertEqual(metadata.resources[0].type, "application/zip")
        XCTAssertEqual(
            metadata.resources[0].checksum,
            "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"
        )
        XCTAssertEqual(metadata.author?.name, "J. Appleseed")
        XCTAssertEqual(metadata.licenseURL, URL("https://github.com/mona/LinkedList/license"))
        XCTAssertEqual(metadata.readmeURL, URL("https://github.com/mona/LinkedList/readme"))
        XCTAssertEqual(metadata.repositoryURLs!, [
            SourceControlURL("https://github.com/mona/LinkedList"),
            SourceControlURL("ssh://git@github.com:mona/LinkedList.git"),
            SourceControlURL("git@github.com:mona/LinkedList.git"),
        ])
    }

    func testGetPackageVersionMetadata_404() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let releaseURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: releaseURL,
            errorCode: 404,
            errorDescription: UUID().uuidString
        )

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(
            try await registryClient
                .getPackageVersionMetadata(package: identity, version: version)
        ) { error in
            guard case RegistryError
                .failedRetrievingReleaseInfo(
                    registry: configuration.defaultRegistry!,
                    package: identity,
                    version: version,
                    error: RegistryError.packageVersionNotFound
                ) = error
            else {
                return XCTFail("unexpected error: '\(error)'")
            }
        }
    }

    func testGetPackageVersionMetadata_ServerError() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let releaseURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: releaseURL,
            errorCode: Int.random(in: 405 ..< 500),
            errorDescription: UUID().uuidString
        )

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(
            try await registryClient
                .getPackageVersionMetadata(package: identity, version: version)
        ) { error in
            guard case RegistryError
                .failedRetrievingReleaseInfo(
                    registry: configuration.defaultRegistry!,
                    package: identity,
                    version: version,
                    error: RegistryError.serverError(
                        code: serverErrorHandler.errorCode,
                        details: serverErrorHandler.errorDescription
                    )
                ) = error
            else {
                return XCTFail("unexpected error: '\(error)'")
            }
        }
    }

    func testGetPackageVersionMetadata_RegistryNotAvailable() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")

        let serverErrorHandler = UnavailableServerErrorHandler(registryURL: registryURL)

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: true)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(
            try await registryClient
                .getPackageVersionMetadata(package: identity, version: version)
        ) { error in
            guard case RegistryError.registryNotAvailable(registry) = error
            else {
                return XCTFail("unexpected error: '\(error)'")
            }
        }
    }

    func testAvailableManifests() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let manifestURL =
            URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)/Package.swift")

        let checksumAlgorithm: HashAlgorithm = MockHashAlgorithm()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let defaultManifest = """
        // swift-tools-version:5.5
        import PackageDescription

        let package = Package(
            name: "LinkedList",
            products: [
                .library(name: "LinkedList", targets: ["LinkedList"])
            ],
            targets: [
                .target(name: "LinkedList"),
                .testTarget(name: "LinkedListTests", dependencies: ["LinkedList"]),
            ],
            swiftLanguageVersions: [.v4, .v5]
        )
        """

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "author": {
                            "name": "J. Appleseed"
                        },
                        "licenseURL": "https://github.com/mona/LinkedList/license",
                        "readmeURL": "https://github.com/mona/LinkedList/readme",
                        "repositoryURLs": [
                            "https://github.com/mona/LinkedList",
                            "ssh://git@github.com:mona/LinkedList.git",
                            "git@github.com:mona/LinkedList.git"
                        ]
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
            case (.get, manifestURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+swift")

                let defaultManifestData = Data(defaultManifest.utf8)

                let links = """
                <http://packages.example.com/mona/LinkedList/1.1.1/Package.swift?swift-version=4>; rel="alternate"; filename="Package@swift-4.swift"; swift-tools-version="4.0",
                <http://packages.example.com/mona/LinkedList/1.1.1/Package.swift?swift-version=4.2>; rel="alternate"; filename="Package@swift-4.2.swift"; swift-tools-version="4.2",
                <http://packages.example.com/mona/LinkedList/1.1.1/Package.swift?swift-version=5.3>; rel="alternate"; filename="Package@swift-5.3.swift"; swift-tools-version="5.3"
                """

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(defaultManifestData.count)"),
                        .init(name: "Content-Type", value: "text/x-swift"),
                        .init(name: "Content-Version", value: "1"),
                        .init(name: "Link", value: links),
                    ]),
                    body: defaultManifestData
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.security = .testDefault

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            checksumAlgorithm: checksumAlgorithm
        )
        let availableManifests = try await registryClient.getAvailableManifests(
            package: identity,
            version: version
        )

        XCTAssertEqual(availableManifests["Package.swift"]?.toolsVersion, .v5_5)
        XCTAssertEqual(availableManifests["Package.swift"]?.content, defaultManifest)
        XCTAssertEqual(availableManifests["Package@swift-4.swift"]?.toolsVersion, .v4)
        XCTAssertEqual(availableManifests["Package@swift-4.swift"]?.content, .none)
        XCTAssertEqual(availableManifests["Package@swift-4.2.swift"]?.toolsVersion, .v4_2)
        XCTAssertEqual(availableManifests["Package@swift-4.2.swift"]?.content, .none)
        XCTAssertEqual(availableManifests["Package@swift-5.3.swift"]?.toolsVersion, .v5_3)
        XCTAssertEqual(availableManifests["Package@swift-5.3.swift"]?.content, .none)
    }

    func testAvailableManifests_matchingChecksumInStorage() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let manifestURL =
            URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)/Package.swift")

        let checksumAlgorithm: HashAlgorithm = MockHashAlgorithm()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let defaultManifest = """
        // swift-tools-version:5.5
        import PackageDescription

        let package = Package(
            name: "LinkedList",
            products: [
                .library(name: "LinkedList", targets: ["LinkedList"])
            ],
            targets: [
                .target(name: "LinkedList"),
                .testTarget(name: "LinkedListTests", dependencies: ["LinkedList"]),
            ],
            swiftLanguageVersions: [.v4, .v5]
        )
        """

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "author": {
                            "name": "J. Appleseed"
                        },
                        "licenseURL": "https://github.com/mona/LinkedList/license",
                        "readmeURL": "https://github.com/mona/LinkedList/readme",
                        "repositoryURLs": [
                            "https://github.com/mona/LinkedList",
                            "ssh://git@github.com:mona/LinkedList.git",
                            "git@github.com:mona/LinkedList.git"
                        ]
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
            case (.get, manifestURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+swift")

                let defaultManifestData = Data(defaultManifest.utf8)

                let links = """
                <http://packages.example.com/mona/LinkedList/1.1.1/Package.swift?swift-version=4>; rel="alternate"; filename="Package@swift-4.swift"; swift-tools-version="4.0",
                <http://packages.example.com/mona/LinkedList/1.1.1/Package.swift?swift-version=4.2>; rel="alternate"; filename="Package@swift-4.2.swift"; swift-tools-version="4.2",
                <http://packages.example.com/mona/LinkedList/1.1.1/Package.swift?swift-version=5.3>; rel="alternate"; filename="Package@swift-5.3.swift"; swift-tools-version="5.3"
                """

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(defaultManifestData.count)"),
                        .init(name: "Content-Type", value: "text/x-swift"),
                        .init(name: "Content-Version", value: "1"),
                        .init(name: "Link", value: links),
                    ]),
                    body: defaultManifestData
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.security = .testDefault

        let contentType = Fingerprint.ContentType.manifest(.none)
        let manifestChecksum = checksumAlgorithm.hash(.init(Data(defaultManifest.utf8)))
            .hexadecimalRepresentation
        let fingerprintStorage = MockPackageFingerprintStorage([
            identity: [
                version: [
                    .registry: [
                        contentType: Fingerprint(
                            origin: .registry(registryURL),
                            value: manifestChecksum,
                            contentType: contentType
                        ),
                    ],
                ],
            ],
        ])

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .strict,
            checksumAlgorithm: checksumAlgorithm
        )
        let availableManifests = try await registryClient.getAvailableManifests(
            package: identity,
            version: version
        )

        XCTAssertEqual(availableManifests["Package.swift"]?.toolsVersion, .v5_5)
        XCTAssertEqual(availableManifests["Package.swift"]?.content, defaultManifest)
        XCTAssertEqual(availableManifests["Package@swift-4.swift"]?.toolsVersion, .v4)
        XCTAssertEqual(availableManifests["Package@swift-4.swift"]?.content, .none)
        XCTAssertEqual(availableManifests["Package@swift-4.2.swift"]?.toolsVersion, .v4_2)
        XCTAssertEqual(availableManifests["Package@swift-4.2.swift"]?.content, .none)
        XCTAssertEqual(availableManifests["Package@swift-5.3.swift"]?.toolsVersion, .v5_3)
        XCTAssertEqual(availableManifests["Package@swift-5.3.swift"]?.content, .none)
    }

    func testAvailableManifests_nonMatchingChecksumInStorage_strict() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let manifestURL =
            URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)/Package.swift")

        let checksumAlgorithm: HashAlgorithm = MockHashAlgorithm()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let defaultManifest = """
        // swift-tools-version:5.5
        import PackageDescription

        let package = Package(
            name: "LinkedList",
            products: [
                .library(name: "LinkedList", targets: ["LinkedList"])
            ],
            targets: [
                .target(name: "LinkedList"),
                .testTarget(name: "LinkedListTests", dependencies: ["LinkedList"]),
            ],
            swiftLanguageVersions: [.v4, .v5]
        )
        """

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "author": {
                            "name": "J. Appleseed"
                        },
                        "licenseURL": "https://github.com/mona/LinkedList/license",
                        "readmeURL": "https://github.com/mona/LinkedList/readme",
                        "repositoryURLs": [
                            "https://github.com/mona/LinkedList",
                            "ssh://git@github.com:mona/LinkedList.git",
                            "git@github.com:mona/LinkedList.git"
                        ]
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
            case (.get, manifestURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+swift")

                let defaultManifestData = Data(defaultManifest.utf8)

                let links = """
                <http://packages.example.com/mona/LinkedList/1.1.1/Package.swift?swift-version=4>; rel="alternate"; filename="Package@swift-4.swift"; swift-tools-version="4.0",
                <http://packages.example.com/mona/LinkedList/1.1.1/Package.swift?swift-version=4.2>; rel="alternate"; filename="Package@swift-4.2.swift"; swift-tools-version="4.2",
                <http://packages.example.com/mona/LinkedList/1.1.1/Package.swift?swift-version=5.3>; rel="alternate"; filename="Package@swift-5.3.swift"; swift-tools-version="5.3"
                """

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(defaultManifestData.count)"),
                        .init(name: "Content-Type", value: "text/x-swift"),
                        .init(name: "Content-Version", value: "1"),
                        .init(name: "Link", value: links),
                    ]),
                    body: defaultManifestData
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.security = .testDefault

        let contentType = Fingerprint.ContentType.manifest(.none)
        let fingerprintStorage = MockPackageFingerprintStorage([
            identity: [
                version: [
                    .registry: [
                        contentType: Fingerprint(
                            origin: .registry(registryURL),
                            value: "non-matching checksum",
                            contentType: contentType
                        ),
                    ],
                ],
            ],
        ])

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .strict, // intended for this test; don't change
            checksumAlgorithm: checksumAlgorithm
        )

        await XCTAssertAsyncThrowsError(
            try await registryClient.getAvailableManifests(
                package: identity,
                version: version
            )
        ) { error in
            guard case RegistryError.invalidChecksum = error else {
                return XCTFail("Expected RegistryError.invalidChecksum, got \(error)")
            }
        }
    }

    func testAvailableManifests_nonMatchingChecksumInStorage_warn() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let manifestURL =
            URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)/Package.swift")

        let checksumAlgorithm: HashAlgorithm = MockHashAlgorithm()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let defaultManifest = """
        // swift-tools-version:5.5
        import PackageDescription

        let package = Package(
            name: "LinkedList",
            products: [
                .library(name: "LinkedList", targets: ["LinkedList"])
            ],
            targets: [
                .target(name: "LinkedList"),
                .testTarget(name: "LinkedListTests", dependencies: ["LinkedList"]),
            ],
            swiftLanguageVersions: [.v4, .v5]
        )
        """

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "author": {
                            "name": "J. Appleseed"
                        },
                        "licenseURL": "https://github.com/mona/LinkedList/license",
                        "readmeURL": "https://github.com/mona/LinkedList/readme",
                        "repositoryURLs": [
                            "https://github.com/mona/LinkedList",
                            "ssh://git@github.com:mona/LinkedList.git",
                            "git@github.com:mona/LinkedList.git"
                        ]
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
            case (.get, manifestURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+swift")

                let defaultManifestData = Data(defaultManifest.utf8)

                let links = """
                <http://packages.example.com/mona/LinkedList/1.1.1/Package.swift?swift-version=4>; rel="alternate"; filename="Package@swift-4.swift"; swift-tools-version="4.0",
                <http://packages.example.com/mona/LinkedList/1.1.1/Package.swift?swift-version=4.2>; rel="alternate"; filename="Package@swift-4.2.swift"; swift-tools-version="4.2",
                <http://packages.example.com/mona/LinkedList/1.1.1/Package.swift?swift-version=5.3>; rel="alternate"; filename="Package@swift-5.3.swift"; swift-tools-version="5.3"
                """

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(defaultManifestData.count)"),
                        .init(name: "Content-Type", value: "text/x-swift"),
                        .init(name: "Content-Version", value: "1"),
                        .init(name: "Link", value: links),
                    ]),
                    body: defaultManifestData
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.security = .testDefault

        let contentType = Fingerprint.ContentType.manifest(.none)
        let fingerprintStorage = MockPackageFingerprintStorage([
            identity: [
                version: [
                    .registry: [
                        contentType: Fingerprint(
                            origin: .registry(registryURL),
                            value: "non-matching checksum",
                            contentType: contentType
                        ),
                    ],
                ],
            ],
        ])

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .warn, // intended for this test; don't change
            checksumAlgorithm: checksumAlgorithm
        )

        let observability = ObservabilitySystem.makeForTesting()
        // The checksum differs from that in storage, but error is not thrown
        // because fingerprintCheckingMode=.warn
        let availableManifests = try await registryClient.getAvailableManifests(
            package: identity,
            version: version,
            observabilityScope: observability.topScope
        )

        // But there should be a warning
        testDiagnostics(observability.diagnostics) { result in
            result.check(diagnostic: .contains("does not match previously recorded value"), severity: .warning)
        }

        XCTAssertEqual(availableManifests["Package.swift"]?.toolsVersion, .v5_5)
        XCTAssertEqual(availableManifests["Package.swift"]?.content, defaultManifest)
        XCTAssertEqual(availableManifests["Package@swift-4.swift"]?.toolsVersion, .v4)
        XCTAssertEqual(availableManifests["Package@swift-4.swift"]?.content, .none)
        XCTAssertEqual(availableManifests["Package@swift-4.2.swift"]?.toolsVersion, .v4_2)
        XCTAssertEqual(availableManifests["Package@swift-4.2.swift"]?.content, .none)
        XCTAssertEqual(availableManifests["Package@swift-5.3.swift"]?.toolsVersion, .v5_3)
        XCTAssertEqual(availableManifests["Package@swift-5.3.swift"]?.content, .none)
    }

    func testAvailableManifests_404() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let manifestURL =
            URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)/Package.swift")

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: manifestURL,
            errorCode: 404,
            errorDescription: "not found"
        )

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.generic, .get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [],
                    "metadata": {}
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
                serverErrorHandler.handle(request: request, progress: nil, completion: completion)
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(try await registryClient.getAvailableManifests(package: identity, version: version)) { error in
            guard case RegistryError
                .failedRetrievingManifest(
                    registry: configuration.defaultRegistry!,
                    package: identity,
                    version: version,
                    error: RegistryError.packageVersionNotFound
                ) = error
            else {
                return XCTFail("unexpected error: '\(error)'")
            }
        }
    }

    func testAvailableManifests_ServerError() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let manifestURL =
            URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)/Package.swift")

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: manifestURL,
            errorCode: Int.random(in: 405 ..< 500),
            errorDescription: UUID().uuidString
        )

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.generic, .get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [],
                    "metadata": {}
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
                serverErrorHandler.handle(request: request, progress: nil, completion: completion)
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(try await registryClient.getAvailableManifests(package: identity, version: version)) { error in
            guard case RegistryError
                .failedRetrievingManifest(
                    registry: configuration.defaultRegistry!,
                    package: identity,
                    version: version,
                    error: RegistryError
                        .serverError(code: serverErrorHandler.errorCode, details: serverErrorHandler.errorDescription)
                ) = error
            else {
                return XCTFail("unexpected error: '\(error)'")
            }
        }
    }

    func testAvailableManifests_RegistryNotAvailable() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")

        let serverErrorHandler = UnavailableServerErrorHandler(registryURL: registryURL)

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: true)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(try await registryClient.getAvailableManifests(package: identity, version: version)) { error in
            guard case RegistryError.registryNotAvailable(registry) = error
            else {
                return XCTFail("unexpected error: '\(error)'")
            }
        }
    }

    func testGetManifestContent() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let manifestURL =
            URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)/Package.swift")

        let checksumAlgorithm: HashAlgorithm = MockHashAlgorithm()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
            let toolsVersion = components.queryItems?.first { $0.name == "swift-version" }
                .flatMap { ToolsVersion(string: $0.value!) } ?? ToolsVersion.current
            // remove query
            components.query = nil
            let urlWithoutQuery = components.url
            switch (request.method, urlWithoutQuery) {
            case (.get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "author": {
                            "name": "J. Appleseed"
                        },
                        "licenseURL": "https://github.com/mona/LinkedList/license",
                        "readmeURL": "https://github.com/mona/LinkedList/readme",
                        "repositoryURLs": [
                            "https://github.com/mona/LinkedList",
                            "ssh://git@github.com:mona/LinkedList.git",
                            "git@github.com:mona/LinkedList.git"
                        ]
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
            case (.get, manifestURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+swift")

                let data = """
                // swift-tools-version:\(toolsVersion)

                import PackageDescription

                let package = Package()
                """.data(using: .utf8)!

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "text/x-swift"),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.security = .testDefault

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            checksumAlgorithm: checksumAlgorithm
        )

        do {
            let manifest = try await registryClient.getManifestContent(
                package: identity,
                version: version,
                customToolsVersion: nil
            )
            let parsedToolsVersion = try ToolsVersionParser.parse(utf8String: manifest)
            XCTAssertEqual(parsedToolsVersion, .current)
        }

        do {
            let manifest = try await registryClient.getManifestContent(
                package: identity,
                version: version,
                customToolsVersion: .v5_3
            )
            let parsedToolsVersion = try ToolsVersionParser.parse(utf8String: manifest)
            XCTAssertEqual(parsedToolsVersion, .v5_3)
        }

        do {
            let manifest = try await registryClient.getManifestContent(
                package: identity,
                version: version,
                customToolsVersion: .v4
            )
            let parsedToolsVersion = try ToolsVersionParser.parse(utf8String: manifest)
            XCTAssertEqual(parsedToolsVersion, .v4)
        }
    }

    func testGetManifestContent_optionalContentVersion() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let manifestURL =
            URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)/Package.swift")

        let checksumAlgorithm: HashAlgorithm = MockHashAlgorithm()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
            let toolsVersion = components.queryItems?.first { $0.name == "swift-version" }
                .flatMap { ToolsVersion(string: $0.value!) } ?? ToolsVersion.current
            // remove query
            components.query = nil
            let urlWithoutQuery = components.url
            switch (request.method, urlWithoutQuery) {
            case (.get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "author": {
                            "name": "J. Appleseed"
                        },
                        "licenseURL": "https://github.com/mona/LinkedList/license",
                        "readmeURL": "https://github.com/mona/LinkedList/readme",
                        "repositoryURLs": [
                            "https://github.com/mona/LinkedList",
                            "ssh://git@github.com:mona/LinkedList.git",
                            "git@github.com:mona/LinkedList.git"
                        ]
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
            case (.get, manifestURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+swift")

                let data = """
                // swift-tools-version:\(toolsVersion)

                import PackageDescription

                let package = Package()
                """.data(using: .utf8)!

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "text/x-swift"),
                        // Omit `Content-Version` header
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.security = .testDefault

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            checksumAlgorithm: checksumAlgorithm
        )

        do {
            let manifest = try await registryClient.getManifestContent(
                package: identity,
                version: version,
                customToolsVersion: nil
            )
            let parsedToolsVersion = try ToolsVersionParser.parse(utf8String: manifest)
            XCTAssertEqual(parsedToolsVersion, .current)
        }

        do {
            let manifest = try await registryClient.getManifestContent(
                package: identity,
                version: version,
                customToolsVersion: .v5_3
            )
            let parsedToolsVersion = try ToolsVersionParser.parse(utf8String: manifest)
            XCTAssertEqual(parsedToolsVersion, .v5_3)
        }
    }

    func testGetManifestContent_matchingChecksumInStorage() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let manifestURL =
            URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)/Package.swift")

        let checksumAlgorithm: HashAlgorithm = MockHashAlgorithm()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
            let toolsVersion = components.queryItems?.first { $0.name == "swift-version" }
                .flatMap { ToolsVersion(string: $0.value!) } ?? ToolsVersion.current
            // remove query
            components.query = nil
            let urlWithoutQuery = components.url
            switch (request.method, urlWithoutQuery) {
            case (.get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "author": {
                            "name": "J. Appleseed"
                        },
                        "licenseURL": "https://github.com/mona/LinkedList/license",
                        "readmeURL": "https://github.com/mona/LinkedList/readme",
                        "repositoryURLs": [
                            "https://github.com/mona/LinkedList",
                            "ssh://git@github.com:mona/LinkedList.git",
                            "git@github.com:mona/LinkedList.git"
                        ]
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
            case (.get, manifestURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+swift")

                let data = Data(manifestContent(toolsVersion: toolsVersion).utf8)

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "text/x-swift"),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.security = .testDefault

        let defaultManifestChecksum = checksumAlgorithm
            .hash(.init(Data(manifestContent(toolsVersion: .none).utf8))).hexadecimalRepresentation
        let versionManifestChecksum = checksumAlgorithm
            .hash(.init(Data(manifestContent(toolsVersion: .v5_3).utf8))).hexadecimalRepresentation
        let fingerprintStorage = MockPackageFingerprintStorage([
            identity: [
                version: [
                    .registry: [
                        Fingerprint.ContentType.manifest(.none): Fingerprint(
                            origin: .registry(registryURL),
                            value: defaultManifestChecksum,
                            contentType: Fingerprint.ContentType.manifest(.none)
                        ),
                        Fingerprint.ContentType.manifest(.v5_3): Fingerprint(
                            origin: .registry(registryURL),
                            value: versionManifestChecksum,
                            contentType: Fingerprint.ContentType.manifest(.v5_3)
                        ),
                    ],
                ],
            ],
        ])

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .strict,
            checksumAlgorithm: checksumAlgorithm
        )

        do {
            let manifest = try await registryClient.getManifestContent(
                package: identity,
                version: version,
                customToolsVersion: nil
            )
            let parsedToolsVersion = try ToolsVersionParser.parse(utf8String: manifest)
            XCTAssertEqual(parsedToolsVersion, .current)
        }

        do {
            let manifest = try await registryClient.getManifestContent(
                package: identity,
                version: version,
                customToolsVersion: .v5_3
            )
            let parsedToolsVersion = try ToolsVersionParser.parse(utf8String: manifest)
            XCTAssertEqual(parsedToolsVersion, .v5_3)
        }
    }

    func testGetManifestContent_nonMatchingChecksumInStorage_strict() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let manifestURL =
            URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)/Package.swift")

        let checksumAlgorithm: HashAlgorithm = MockHashAlgorithm()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
            let toolsVersion = components.queryItems?.first { $0.name == "swift-version" }
                .flatMap { ToolsVersion(string: $0.value!) } ?? ToolsVersion.current
            // remove query
            components.query = nil
            let urlWithoutQuery = components.url
            switch (request.method, urlWithoutQuery) {
            case (.get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "author": {
                            "name": "J. Appleseed"
                        },
                        "licenseURL": "https://github.com/mona/LinkedList/license",
                        "readmeURL": "https://github.com/mona/LinkedList/readme",
                        "repositoryURLs": [
                            "https://github.com/mona/LinkedList",
                            "ssh://git@github.com:mona/LinkedList.git",
                            "git@github.com:mona/LinkedList.git"
                        ]
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
            case (.get, manifestURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+swift")

                let data = Data(manifestContent(toolsVersion: toolsVersion).utf8)

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "text/x-swift"),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.security = .testDefault

        let fingerprintStorage = MockPackageFingerprintStorage([
            identity: [
                version: [
                    .registry: [
                        Fingerprint.ContentType.manifest(.none): Fingerprint(
                            origin: .registry(registryURL),
                            value: "non-matching checksum",
                            contentType: Fingerprint.ContentType.manifest(.none)
                        ),
                        Fingerprint.ContentType.manifest(.v5_3): Fingerprint(
                            origin: .registry(registryURL),
                            value: "non-matching checksum",
                            contentType: Fingerprint.ContentType.manifest(.v5_3)
                        ),
                    ],
                ],
            ],
        ])

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .strict, // intended for this test; don't change
            checksumAlgorithm: checksumAlgorithm
        )

        await XCTAssertAsyncThrowsError(
            try await registryClient.getManifestContent(
                package: identity,
                version: version,
                customToolsVersion: nil
            )
        ) { error in
            guard case RegistryError.invalidChecksum = error else {
                return XCTFail("Expected RegistryError.invalidChecksum, got \(error)")
            }
        }

        await XCTAssertAsyncThrowsError(
            try await registryClient.getManifestContent(
                package: identity,
                version: version,
                customToolsVersion: .v5_3
            )
        ) { error in
            guard case RegistryError.invalidChecksum = error else {
                return XCTFail("Expected RegistryError.invalidChecksum, got \(error)")
            }
        }
    }

    func testGetManifestContent_matchingChecksumInStorage_warn() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let manifestURL =
            URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)/Package.swift")

        let checksumAlgorithm: HashAlgorithm = MockHashAlgorithm()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
            let toolsVersion = components.queryItems?.first { $0.name == "swift-version" }
                .flatMap { ToolsVersion(string: $0.value!) } ?? ToolsVersion.current
            // remove query
            components.query = nil
            let urlWithoutQuery = components.url
            switch (request.method, urlWithoutQuery) {
            case (.get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "author": {
                            "name": "J. Appleseed"
                        },
                        "licenseURL": "https://github.com/mona/LinkedList/license",
                        "readmeURL": "https://github.com/mona/LinkedList/readme",
                        "repositoryURLs": [
                            "https://github.com/mona/LinkedList",
                            "ssh://git@github.com:mona/LinkedList.git",
                            "git@github.com:mona/LinkedList.git"
                        ]
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
            case (.get, manifestURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+swift")

                let data = Data(manifestContent(toolsVersion: toolsVersion).utf8)

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "text/x-swift"),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.security = .testDefault

        let fingerprintStorage = MockPackageFingerprintStorage([
            identity: [
                version: [
                    .registry: [
                        Fingerprint.ContentType.manifest(.none): Fingerprint(
                            origin: .registry(registryURL),
                            value: "non-matching checksum",
                            contentType: Fingerprint.ContentType.manifest(.none)
                        ),
                        Fingerprint.ContentType.manifest(.v5_3): Fingerprint(
                            origin: .registry(registryURL),
                            value: "non-matching checksum",
                            contentType: Fingerprint.ContentType.manifest(.v5_3)
                        ),
                    ],
                ],
            ],
        ])

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .warn, // intended for this test; don't change
            checksumAlgorithm: checksumAlgorithm
        )

        do {
            let observability = ObservabilitySystem.makeForTesting()
            // The checksum differs from that in storage, but error is not thrown
            // because fingerprintCheckingMode=.warn
            let manifest = try await registryClient.getManifestContent(
                package: identity,
                version: version,
                customToolsVersion: nil,
                observabilityScope: observability.topScope
            )

            // But there should be a warning
            testDiagnostics(observability.diagnostics) { result in
                result.check(diagnostic: .contains("does not match previously recorded value"), severity: .warning)
            }

            let parsedToolsVersion = try ToolsVersionParser.parse(utf8String: manifest)
            XCTAssertEqual(parsedToolsVersion, .current)
        }

        do {
            let observability = ObservabilitySystem.makeForTesting()
            // The checksum differs from that in storage, but error is not thrown
            // because fingerprintCheckingMode=.warn
            let manifest = try await registryClient.getManifestContent(
                package: identity,
                version: version,
                customToolsVersion: .v5_3,
                observabilityScope: observability.topScope
            )

            // But there should be a warning
            testDiagnostics(observability.diagnostics) { result in
                result.check(diagnostic: .contains("does not match previously recorded value"), severity: .warning)
            }

            let parsedToolsVersion = try ToolsVersionParser.parse(utf8String: manifest)
            XCTAssertEqual(parsedToolsVersion, .v5_3)
        }
    }

    func testGetManifestContent_404() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let manifestURL =
            URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)/Package.swift")

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: manifestURL,
            errorCode: 404,
            errorDescription: "not found"
        )

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.generic, .get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [],
                    "metadata": {}
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
                serverErrorHandler.handle(request: request, progress: nil, completion: completion)
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(
            try await registryClient
                .getManifestContent(package: identity, version: version, customToolsVersion: nil)
        ) { error in
            guard case RegistryError
                .failedRetrievingManifest(
                    registry: configuration.defaultRegistry!,
                    package: identity,
                    version: version,
                    error: RegistryError.packageVersionNotFound
                ) = error
            else {
                return XCTFail("unexpected error: '\(error)'")
            }
        }
    }

    func testGetManifestContent_ServerError() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let manifestURL =
            URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)/Package.swift")

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: manifestURL,
            errorCode: Int.random(in: 405 ..< 500),
            errorDescription: UUID().uuidString
        )

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.generic, .get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [],
                    "metadata": {}
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
                serverErrorHandler.handle(request: request, progress: nil, completion: completion)
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(
            try await registryClient
                .getManifestContent(package: identity, version: version, customToolsVersion: nil)
        ) { error in
            guard case RegistryError
                .failedRetrievingManifest(
                    registry: configuration.defaultRegistry!,
                    package: identity,
                    version: version,
                    error: RegistryError
                        .serverError(code: serverErrorHandler.errorCode, details: serverErrorHandler.errorDescription)
                ) = error
            else {
                return XCTFail("unexpected error: '\(error)'")
            }
        }
    }

    func testGetManifestContent_RegistryNotAvailable() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")

        let serverErrorHandler = UnavailableServerErrorHandler(registryURL: registryURL)

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: true)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(
            try await registryClient
                .getManifestContent(package: identity, version: version, customToolsVersion: nil)
        ) { error in
            guard case RegistryError
                .registryNotAvailable(registry) = error
            else {
                return XCTFail("unexpected error: '\(error)'")
            }
        }
    }

    func testDownloadSourceArchive() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.registry("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.scope)/\(identity.name)/\(version)")
        let downloadURL = URL("\(registryURL)/\(identity.scope)/\(identity.name)/\(version).zip")

        let checksumAlgorithm: HashAlgorithm = MockHashAlgorithm()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let author = UUID().uuidString
        let licenseURL = URL("https://github.com/\(identity.scope)/\(identity.name)/license")
        let readmeURL = URL("https://github.com/\(identity.scope)/\(identity.name)/readme")
        let repositoryURLs = [
            SourceControlURL("https://github.com/\(identity.scope)/\(identity.name)"),
            SourceControlURL("ssh://git@github.com:\(identity.scope)/\(identity.name).git"),
            SourceControlURL("git@github.com:\(identity.scope)/\(identity.name).git"),
        ]

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.generic, .get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "author": {
                            "name": "\(author)"
                        },
                        "licenseURL": "\(licenseURL)",
                        "readmeURL": "\(readmeURL)",
                        "repositoryURLs": [\"\(repositoryURLs.map(\.absoluteString).joined(separator: "\", \""))\"]
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
            case (.download(let fileSystem, let path), .get, downloadURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+zip")

                let data = Data(emptyZipFile.contents)
                try! fileSystem.writeFileContents(path, data: data)

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/zip"),
                        .init(name: "Content-Version", value: "1"),
                        .init(
                            name: "Content-Disposition",
                            value: "attachment; filename=\"\(identity)-\(version).zip\""
                        ),
                        .init(
                            name: "Digest",
                            value: "sha-256=bc6c9a5d2f2226cfa1ef4fad8344b10e1cc2e82960f468f70d9ed696d26b3283"
                        ),
                    ]),
                    body: nil
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.security = .testDefault

        let registryClient = RegistryClient(
            configuration: configuration,
            fingerprintStorage: .none,
            fingerprintCheckingMode: .strict,
            skipSignatureValidation: false,
            signingEntityStorage: .none,
            signingEntityCheckingMode: .strict,
            customHTTPClient: httpClient,
            customArchiverProvider: { fileSystem in
                MockArchiver(handler: { _, from, to, callback in
                    let data = try fileSystem.readFileContents(from)
                    XCTAssertEqual(data, emptyZipFile)

                    let packagePath = to.appending(component: "package")
                    try fileSystem.createDirectory(packagePath, recursive: true)
                    try fileSystem.writeFileContents(packagePath.appending(component: "Package.swift"), string: "")
                    callback(.success(()))
                })
            },
            delegate: .none,
            checksumAlgorithm: checksumAlgorithm
        )

        let fileSystem = InMemoryFileSystem()
        let path = try! AbsolutePath(validating: "/\(identity)-\(version)")

        try await registryClient.downloadSourceArchive(
            package: identity.underlying,
            version: version,
            fileSystem: fileSystem,
            destinationPath: path
        )

        let contents = try fileSystem.getDirectoryContents(path)
        XCTAssertEqual(contents.sorted(), [RegistryReleaseMetadataStorage.fileName, "Package.swift"].sorted())

        let storedMetadata = try RegistryReleaseMetadataStorage.load(
            from: path.appending(component: RegistryReleaseMetadataStorage.fileName),
            fileSystem: fileSystem
        )
        XCTAssertEqual(storedMetadata.source, .registry(registryURL))
        XCTAssertEqual(storedMetadata.metadata.author?.name, author)
        XCTAssertEqual(storedMetadata.metadata.licenseURL, licenseURL)
        XCTAssertEqual(storedMetadata.metadata.readmeURL, readmeURL)
        XCTAssertEqual(storedMetadata.metadata.scmRepositoryURLs, repositoryURLs)
    }

    func testDownloadSourceArchive_matchingChecksumInStorage() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let downloadURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version).zip")

        let checksumAlgorithm: HashAlgorithm = MockHashAlgorithm()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.generic, .get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "author": {
                            "name": "J. Appleseed"
                        },
                        "licenseURL": "https://github.com/mona/LinkedList/license",
                        "readmeURL": "https://github.com/mona/LinkedList/readme",
                        "repositoryURLs": [
                            "https://github.com/mona/LinkedList",
                            "ssh://git@github.com:mona/LinkedList.git",
                            "git@github.com:mona/LinkedList.git"
                        ]
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
            case (.download(let fileSystem, let path), .get, downloadURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+zip")

                let data = Data(emptyZipFile.contents)
                try! fileSystem.writeFileContents(path, data: data)

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/zip"),
                        .init(name: "Content-Version", value: "1"),
                        .init(name: "Content-Disposition", value: #"attachment; filename="LinkedList-1.1.1.zip""#),
                        .init(
                            name: "Digest",
                            value: "sha-256=bc6c9a5d2f2226cfa1ef4fad8344b10e1cc2e82960f468f70d9ed696d26b3283"
                        ),
                    ]),
                    body: nil
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.security = .testDefault

        let fingerprintStorage = MockPackageFingerprintStorage([
            identity: [
                version: [
                    .registry: [
                        .sourceCode: Fingerprint(
                            origin: .registry(registryURL),
                            value: checksum,
                            contentType: .sourceCode
                        ),
                    ],
                ],
            ],
        ])
        let registryClient = RegistryClient(
            configuration: configuration,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .strict,
            skipSignatureValidation: false,
            signingEntityStorage: .none,
            signingEntityCheckingMode: .strict,
            customHTTPClient: httpClient,
            customArchiverProvider: { fileSystem in
                MockArchiver(handler: { _, from, to, callback in
                    let data = try fileSystem.readFileContents(from)
                    XCTAssertEqual(data, emptyZipFile)

                    let packagePath = to.appending("package")
                    try fileSystem.createDirectory(packagePath, recursive: true)
                    try fileSystem.writeFileContents(packagePath.appending("Package.swift"), string: "")
                    callback(.success(()))
                })
            },
            delegate: .none,
            checksumAlgorithm: checksumAlgorithm
        )

        let fileSystem = InMemoryFileSystem()
        let path = AbsolutePath("/LinkedList-1.1.1")

        try await registryClient.downloadSourceArchive(
            package: identity,
            version: version,
            fileSystem: fileSystem,
            destinationPath: path
        )

        let contents = try fileSystem.getDirectoryContents(path)
        XCTAssertEqual(contents.sorted(), [RegistryReleaseMetadataStorage.fileName, "Package.swift"].sorted())
    }

    func testDownloadSourceArchive_nonMatchingChecksumInStorage() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let downloadURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version).zip")

        let checksumAlgorithm: HashAlgorithm = MockHashAlgorithm()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.generic, .get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "author": {
                            "name": "J. Appleseed"
                        },
                        "licenseURL": "https://github.com/mona/LinkedList/license",
                        "readmeURL": "https://github.com/mona/LinkedList/readme",
                        "repositoryURLs": [
                            "https://github.com/mona/LinkedList",
                            "ssh://git@github.com:mona/LinkedList.git",
                            "git@github.com:mona/LinkedList.git"
                        ]
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
            case (.download(let fileSystem, let path), .get, downloadURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+zip")

                let data = Data(emptyZipFile.contents)
                try! fileSystem.writeFileContents(path, data: data)

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/zip"),
                        .init(name: "Content-Version", value: "1"),
                        .init(name: "Content-Disposition", value: #"attachment; filename="LinkedList-1.1.1.zip""#),
                        .init(
                            name: "Digest",
                            value: "sha-256=bc6c9a5d2f2226cfa1ef4fad8344b10e1cc2e82960f468f70d9ed696d26b3283"
                        ),
                    ]),
                    body: nil
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.security = .testDefault

        let fingerprintStorage = MockPackageFingerprintStorage([
            identity: [
                version: [
                    .registry: [
                        .sourceCode: Fingerprint(
                            origin: .registry(registryURL),
                            value: "non-matching checksum",
                            contentType: .sourceCode
                        ),
                    ],
                ],
            ],
        ])
        let registryClient = RegistryClient(
            configuration: configuration,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .strict, // intended for this test; don't change
            skipSignatureValidation: false,
            signingEntityStorage: .none,
            signingEntityCheckingMode: .strict,
            customHTTPClient: httpClient,
            customArchiverProvider: { fileSystem in
                MockArchiver(handler: { _, from, to, callback in
                    let data = try fileSystem.readFileContents(from)
                    XCTAssertEqual(data, emptyZipFile)

                    let packagePath = to.appending("package")
                    try fileSystem.createDirectory(packagePath, recursive: true)
                    try fileSystem.writeFileContents(packagePath.appending("Package.swift"), string: "")
                    callback(.success(()))
                })
            },
            delegate: .none,
            checksumAlgorithm: checksumAlgorithm
        )

        let fileSystem = InMemoryFileSystem()
        let path = AbsolutePath("/LinkedList-1.1.1")

        await XCTAssertAsyncThrowsError(
            try await registryClient.downloadSourceArchive(
                package: identity,
                version: version,
                fileSystem: fileSystem,
                destinationPath: path
            )
        ) { error in
            guard case RegistryError.invalidChecksum = error else {
                return XCTFail("Expected RegistryError.invalidChecksum, got \(error)")
            }
        }

        // download did not succeed so directory does not exist
        XCTAssertFalse(fileSystem.exists(path))
    }

    func testDownloadSourceArchive_nonMatchingChecksumInStorage_fingerprintChecking_warn() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let downloadURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version).zip")

        let checksumAlgorithm: HashAlgorithm = MockHashAlgorithm()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.generic, .get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "author": {
                            "name": "J. Appleseed"
                        },
                        "licenseURL": "https://github.com/mona/LinkedList/license",
                        "readmeURL": "https://github.com/mona/LinkedList/readme",
                        "repositoryURLs": [
                            "https://github.com/mona/LinkedList",
                            "ssh://git@github.com:mona/LinkedList.git",
                            "git@github.com:mona/LinkedList.git"
                        ]
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
            case (.download(let fileSystem, let path), .get, downloadURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+zip")

                let data = Data(emptyZipFile.contents)
                try! fileSystem.writeFileContents(path, data: data)

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/zip"),
                        .init(name: "Content-Version", value: "1"),
                        .init(name: "Content-Disposition", value: #"attachment; filename="LinkedList-1.1.1.zip""#),
                        .init(
                            name: "Digest",
                            value: "sha-256=bc6c9a5d2f2226cfa1ef4fad8344b10e1cc2e82960f468f70d9ed696d26b3283"
                        ),
                    ]),
                    body: nil
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.security = .testDefault

        let fingerprintStorage = MockPackageFingerprintStorage([
            identity: [
                version: [
                    .registry: [
                        .sourceCode: Fingerprint(
                            origin: .registry(registryURL),
                            value: "non-matching checksum",
                            contentType: .sourceCode
                        ),
                    ],
                ],
            ],
        ])
        let registryClient = RegistryClient(
            configuration: configuration,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .warn, // intended for this test; don't change
            skipSignatureValidation: false,
            signingEntityStorage: .none,
            signingEntityCheckingMode: .strict,
            customHTTPClient: httpClient,
            customArchiverProvider: { fileSystem in
                MockArchiver(handler: { _, from, to, callback in
                    let data = try fileSystem.readFileContents(from)
                    XCTAssertEqual(data, emptyZipFile)

                    let packagePath = to.appending("package")
                    try fileSystem.createDirectory(packagePath, recursive: true)
                    try fileSystem.writeFileContents(packagePath.appending("Package.swift"), string: "")
                    callback(.success(()))
                })
            },
            delegate: .none,
            checksumAlgorithm: checksumAlgorithm
        )

        let fileSystem = InMemoryFileSystem()
        let path = AbsolutePath("/LinkedList-1.1.1")
        let observability = ObservabilitySystem.makeForTesting()

        // The checksum differs from that in storage, but error is not thrown
        // because fingerprintCheckingMode=.warn
        try await registryClient.downloadSourceArchive(
            package: identity,
            version: version,
            fileSystem: fileSystem,
            destinationPath: path,
            observabilityScope: observability.topScope
        )

        // But there should be a warning
        testDiagnostics(observability.diagnostics) { result in
            result.check(diagnostic: .contains("does not match previously recorded value"), severity: .warning)
        }

        let contents = try fileSystem.getDirectoryContents(path)
        XCTAssertEqual(contents.sorted(), [RegistryReleaseMetadataStorage.fileName, "Package.swift"].sorted())
    }

    func testDownloadSourceArchive_checksumNotInStorage() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let downloadURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version).zip")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")

        let checksumAlgorithm: HashAlgorithm = MockHashAlgorithm()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.download(let fileSystem, let path), .get, downloadURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+zip")

                let data = Data(emptyZipFile.contents)
                try! fileSystem.writeFileContents(path, data: data)

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/zip"),
                        .init(name: "Content-Version", value: "1"),
                        .init(name: "Content-Disposition", value: #"attachment; filename="LinkedList-1.1.1.zip""#),
                        .init(
                            name: "Digest",
                            value: "sha-256=bc6c9a5d2f2226cfa1ef4fad8344b10e1cc2e82960f468f70d9ed696d26b3283"
                        ),
                    ]),
                    body: nil
                )))
            // `downloadSourceArchive` calls this API to fetch checksum
            case (.generic, .get, metadataURL):
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

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.security = .testDefault

        let fingerprintStorage = MockPackageFingerprintStorage()
        let registryClient = RegistryClient(
            configuration: configuration,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .strict,
            skipSignatureValidation: false,
            signingEntityStorage: .none,
            signingEntityCheckingMode: .strict,
            customHTTPClient: httpClient,
            customArchiverProvider: { fileSystem in
                MockArchiver(handler: { _, from, to, callback in
                    let data = try fileSystem.readFileContents(from)
                    XCTAssertEqual(data, emptyZipFile)

                    let packagePath = to.appending("package")
                    try fileSystem.createDirectory(packagePath, recursive: true)
                    try fileSystem.writeFileContents(packagePath.appending("Package.swift"), string: "")
                    callback(.success(()))
                })
            },
            delegate: .none,
            checksumAlgorithm: checksumAlgorithm
        )

        let fileSystem = InMemoryFileSystem()
        let path = AbsolutePath("/LinkedList-1.1.1")

        try await registryClient.downloadSourceArchive(
            package: identity,
            version: version,
            fileSystem: fileSystem,
            destinationPath: path
        )

        let contents = try fileSystem.getDirectoryContents(path)
        XCTAssertEqual(contents.sorted(), [RegistryReleaseMetadataStorage.fileName, "Package.swift"].sorted())

        // Expected checksum is not found in storage so the metadata API will be called
        let fingerprint = try await safe_async {
            fingerprintStorage.get(
                package: identity,
                version: version,
                kind: .registry,
                contentType: .sourceCode,
                observabilityScope: ObservabilitySystem
                    .NOOP,
                callbackQueue: .sharedConcurrent,
                callback: $0
            )
        }
        XCTAssertEqual(SourceControlURL(registryURL), fingerprint.origin.url)
        XCTAssertEqual(checksum, fingerprint.value)
    }

    func testDownloadSourceArchive_optionalContentVersion() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let downloadURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version).zip")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")

        let checksumAlgorithm: HashAlgorithm = MockHashAlgorithm()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.download(let fileSystem, let path), .get, downloadURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+zip")

                let data = Data(emptyZipFile.contents)
                try! fileSystem.writeFileContents(path, data: data)

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/zip"),
                        // Omit `Content-Version` header
                        .init(name: "Content-Disposition", value: #"attachment; filename="LinkedList-1.1.1.zip""#),
                        .init(
                            name: "Digest",
                            value: "sha-256=bc6c9a5d2f2226cfa1ef4fad8344b10e1cc2e82960f468f70d9ed696d26b3283"
                        ),
                    ]),
                    body: nil
                )))
            // `downloadSourceArchive` calls this API to fetch checksum
            case (.generic, .get, metadataURL):
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

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.security = .testDefault

        let fingerprintStorage = MockPackageFingerprintStorage()
        let registryClient = RegistryClient(
            configuration: configuration,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .strict,
            skipSignatureValidation: false,
            signingEntityStorage: .none,
            signingEntityCheckingMode: .strict,
            customHTTPClient: httpClient,
            customArchiverProvider: { fileSystem in
                MockArchiver(handler: { _, from, to, callback in
                    let data = try fileSystem.readFileContents(from)
                    XCTAssertEqual(data, emptyZipFile)

                    let packagePath = to.appending("package")
                    try fileSystem.createDirectory(packagePath, recursive: true)
                    try fileSystem.writeFileContents(packagePath.appending("Package.swift"), string: "")
                    callback(.success(()))
                })
            },
            delegate: .none,
            checksumAlgorithm: checksumAlgorithm
        )

        let fileSystem = InMemoryFileSystem()
        let path = AbsolutePath("/LinkedList-1.1.1")

        try await registryClient.downloadSourceArchive(
            package: identity,
            version: version,
            fileSystem: fileSystem,
            destinationPath: path
        )

        let contents = try fileSystem.getDirectoryContents(path)
        // TODO: check metadata
        XCTAssertEqual(contents.sorted(), [RegistryReleaseMetadataStorage.fileName, "Package.swift"].sorted())
    }

    func testDownloadSourceArchive_404() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let downloadURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version).zip")

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: downloadURL,
            errorCode: 404,
            errorDescription: "not found"
        )

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.generic, .get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [],
                    "metadata": {}
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
                serverErrorHandler.handle(request: request, progress: nil, completion: completion)
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = RegistryClient(
            configuration: configuration,
            fingerprintStorage: .none,
            fingerprintCheckingMode: .strict,
            skipSignatureValidation: false,
            signingEntityStorage: .none,
            signingEntityCheckingMode: .strict,
            customHTTPClient: httpClient,
            delegate: .none,
            checksumAlgorithm: MockHashAlgorithm()
        )

        let fileSystem = InMemoryFileSystem()
        let path = AbsolutePath("/LinkedList-1.1.1")

        await XCTAssertAsyncThrowsError(try await registryClient.downloadSourceArchive(
            package: identity,
            version: version,
            fileSystem: fileSystem,
            destinationPath: path
        )) { error in
            guard case RegistryError
                .failedDownloadingSourceArchive(
                    registry: configuration.defaultRegistry!,
                    package: identity,
                    version: version,
                    error: RegistryError.packageVersionNotFound
                ) = error
            else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testDownloadSourceArchive_ServerError() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let metadataURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let downloadURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version).zip")

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: downloadURL,
            errorCode: Int.random(in: 405 ..< 500),
            errorDescription: UUID().uuidString
        )

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.generic, .get, metadataURL):
                let data = """
                {
                    "id": "\(identity)",
                    "version": "\(version)",
                    "resources": [],
                    "metadata": {}
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
                serverErrorHandler.handle(request: request, progress: nil, completion: completion)
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = RegistryClient(
            configuration: configuration,
            fingerprintStorage: .none,
            fingerprintCheckingMode: .strict,
            skipSignatureValidation: false,
            signingEntityStorage: .none,
            signingEntityCheckingMode: .strict,
            customHTTPClient: httpClient,
            delegate: .none,
            checksumAlgorithm: MockHashAlgorithm()
        )

        let fileSystem = InMemoryFileSystem()
        let path = AbsolutePath("/LinkedList-1.1.1")

        await XCTAssertAsyncThrowsError(try await registryClient.downloadSourceArchive(
            package: identity,
            version: version,
            fileSystem: fileSystem,
            destinationPath: path
        )) { error in
            guard case RegistryError
                .failedDownloadingSourceArchive(
                    registry: configuration.defaultRegistry!,
                    package: identity,
                    version: version,
                    error: RegistryError
                        .serverError(code: serverErrorHandler.errorCode, details: serverErrorHandler.errorDescription)
                ) = error
            else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testDownloadSourceArchive_RegistryNotAvailable() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")

        let serverErrorHandler = UnavailableServerErrorHandler(registryURL: registryURL)

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: true)
        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = registry

        let registryClient = RegistryClient(
            configuration: configuration,
            fingerprintStorage: .none,
            fingerprintCheckingMode: .strict,
            skipSignatureValidation: false,
            signingEntityStorage: .none,
            signingEntityCheckingMode: .strict,
            customHTTPClient: httpClient,
            delegate: .none,
            checksumAlgorithm: MockHashAlgorithm()
        )

        let fileSystem = InMemoryFileSystem()
        let path = AbsolutePath("/LinkedList-1.1.1")

        await XCTAssertAsyncThrowsError(try await registryClient.downloadSourceArchive(
            package: identity,
            version: version,
            fileSystem: fileSystem,
            destinationPath: path
        )) { error in
            guard case RegistryError
                .registryNotAvailable(registry) = error
            else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testLookupIdentities() async throws {
        let registryURL = URL("https://packages.example.com")
        let packageURL = SourceControlURL("https://example.com/mona/LinkedList")
        let identifiersURL = URL("\(registryURL)/identifiers?url=\(packageURL.absoluteString)")

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, identifiersURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                let data = #"""
                {
                    "identifiers": [
                      "mona.LinkedList"
                    ]
                }
                """#.data(using: .utf8)!

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

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        let identities = try await registryClient.lookupIdentities(scmURL: packageURL)
        XCTAssertEqual([PackageIdentity.plain("mona.LinkedList")], identities)
    }

    func testLookupIdentities404() async throws {
        let registryURL = URL("https://packages.example.com")
        let packageURL = SourceControlURL("https://example.com/mona/LinkedList")
        let identifiersURL = URL("\(registryURL)/identifiers?url=\(packageURL.absoluteString)")

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, identifiersURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")
                completion(.success(.notFound()))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        let identities = try await registryClient.lookupIdentities(scmURL: packageURL)
        XCTAssertEqual([], identities)
    }

    func testLookupIdentities_ServerError() async throws {
        let registryURL = URL("https://packages.example.com")
        let packageURL = SourceControlURL("https://example.com/mona/LinkedList")
        let identifiersURL = URL("\(registryURL)/identifiers?url=\(packageURL.absoluteString)")

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: identifiersURL,
            errorCode: Int.random(in: 405 ..< 500), // avoid 404 since it is not considered an error
            errorDescription: UUID().uuidString
        )

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(try await registryClient.lookupIdentities(scmURL: packageURL)) { error in
            guard case RegistryError
                .failedIdentityLookup(
                    registry: configuration.defaultRegistry!,
                    scmURL: packageURL,
                    error: RegistryError
                        .serverError(code: serverErrorHandler.errorCode, details: serverErrorHandler.errorDescription)
                ) = error
            else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testRequestAuthorization_token() async throws {
        let registryURL = URL("https://packages.example.com")
        let packageURL = SourceControlURL("https://example.com/mona/LinkedList")
        let identifiersURL = URL("\(registryURL)/identifiers?url=\(packageURL.absoluteString)")

        let token = "top-sekret"

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, identifiersURL):
                XCTAssertEqual(request.headers.get("Authorization").first, "Bearer \(token)")
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                let data = #"""
                {
                    "identifiers": [
                      "mona.LinkedList"
                    ]
                }
                """#.data(using: .utf8)!

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

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.registryAuthentication[registryURL.host!] = .init(type: .token)

        let authorizationProvider = TestProvider(map: [registryURL.host!: ("token", token)])

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            authorizationProvider: authorizationProvider
        )
        let identities = try await registryClient.lookupIdentities(scmURL: packageURL)
        XCTAssertEqual([PackageIdentity.plain("mona.LinkedList")], identities)
    }

    func testRequestAuthorization_basic() async throws {
        let registryURL = URL("https://packages.example.com")
        let packageURL = SourceControlURL("https://example.com/mona/LinkedList")
        let identifiersURL = URL("\(registryURL)/identifiers?url=\(packageURL.absoluteString)")

        let user = "jappleseed"
        let password = "top-sekret"

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, identifiersURL):
                XCTAssertEqual(
                    request.headers.get("Authorization").first,
                    "Basic \(Data("\(user):\(password)".utf8).base64EncodedString())"
                )
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                let data = #"""
                {
                    "identifiers": [
                      "mona.LinkedList"
                    ]
                }
                """#.data(using: .utf8)!

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

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.registryAuthentication[registryURL.host!] = .init(type: .basic)

        let authorizationProvider = TestProvider(map: [registryURL.host!: (user, password)])

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            authorizationProvider: authorizationProvider
        )
        let identities = try await registryClient.lookupIdentities(scmURL: packageURL)
        XCTAssertEqual([PackageIdentity.plain("mona.LinkedList")], identities)
    }

    func testLogin() async throws {
        let registryURL = URL("https://packages.example.com")
        let loginURL = URL("\(registryURL)/login")

        let token = "top-sekret"

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.post, loginURL):
                XCTAssertEqual(request.headers.get("Authorization").first, "Bearer \(token)")

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Version", value: "1"),
                    ])
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.registryAuthentication[registryURL.host!] = .init(type: .token)

        let authorizationProvider = TestProvider(map: [registryURL.host!: ("token", token)])

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            authorizationProvider: authorizationProvider
        )
        try await registryClient.login(loginURL: loginURL)
    }

    func testLogin_missingCredentials() async throws {
        let registryURL = URL("https://packages.example.com")
        let loginURL = URL("\(registryURL)/login")

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.post, loginURL):
                XCTAssertNil(request.headers.get("Authorization").first)

                completion(.success(.init(
                    statusCode: 401,
                    headers: .init([
                        .init(name: "Content-Version", value: "1"),
                    ])
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient
        )

        await XCTAssertAsyncThrowsError(try await registryClient.login(loginURL: loginURL)) { error in
            guard case RegistryError.loginFailed(_, _) = error else {
                return XCTFail("Expected RegistryError.unauthorized, got \(error)")
            }
        }
    }

    func testLogin_authenticationMethodNotSupported() async throws {
        let registryURL = URL("https://packages.example.com")
        let loginURL = URL("\(registryURL)/login")

        let token = "top-sekret"

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.post, loginURL):
                XCTAssertNotNil(request.headers.get("Authorization").first)

                completion(.success(.init(
                    statusCode: 501,
                    headers: .init([
                        .init(name: "Content-Version", value: "1"),
                    ])
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)
        configuration.registryAuthentication[registryURL.host!] = .init(type: .token)

        let authorizationProvider = TestProvider(map: [registryURL.host!: ("token", token)])

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            authorizationProvider: authorizationProvider
        )

        await XCTAssertAsyncThrowsError(try await registryClient.login(loginURL: loginURL)) { error in
            guard case RegistryError.loginFailed = error else {
                return XCTFail("Expected RegistryError.authenticationMethodNotSupported, got \(error)")
            }
        }
    }

    func testRegistryPublishSync() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let publishURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let expectedLocation =
            URL("https://\(registryURL)/packages\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")

        let archiveContent = UUID().uuidString
        let metadataContent = UUID().uuidString

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.put, publishURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")
                XCTAssertNil(request.headers.get("X-Swift-Package-Signature-Format").first)

                // TODO: implement multipart form parsing
                let body = String(decoding: request.body!, as: UTF8.self)
                XCTAssertMatch(body, .contains(archiveContent))
                XCTAssertMatch(body, .contains(metadataContent))

                completion(.success(.init(
                    statusCode: 201,
                    headers: .init([
                        .init(name: "Location", value: expectedLocation.absoluteString),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: .none
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        try await withTemporaryDirectory { temporaryDirectory in
            let archivePath = temporaryDirectory.appending("\(identity)-\(version).zip")
            try localFileSystem.writeFileContents(archivePath, string: archiveContent)

            let metadataPath = temporaryDirectory.appending("\(identity)-\(version)-metadata.json")
            try localFileSystem.writeFileContents(metadataPath, string: metadataContent)

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            var configuration = RegistryConfiguration()
            configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

            let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
            let result = try await registryClient.publish(
                registryURL: registryURL,
                packageIdentity: identity,
                packageVersion: version,
                packageArchive: archivePath,
                packageMetadata: metadataPath,
                signature: .none,
                metadataSignature: .none,
                signatureFormat: .none,
                fileSystem: localFileSystem
            )

            XCTAssertEqual(result, .published(expectedLocation))
        }
    }

    func testRegistryPublishAsync() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let publishURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let expectedLocation =
            URL("https://\(registryURL)/status\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let expectedRetry = Int.random(in: 10 ..< 100)

        let archiveContent = UUID().uuidString
        let metadataContent = UUID().uuidString

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.put, publishURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")
                XCTAssertNil(request.headers.get("X-Swift-Package-Signature-Format").first)

                // TODO: implement multipart form parsing
                let body = String(decoding: request.body!, as: UTF8.self)
                XCTAssertMatch(body, .contains(archiveContent))
                XCTAssertMatch(body, .contains(metadataContent))

                completion(.success(.init(
                    statusCode: 202,
                    headers: .init([
                        .init(name: "Location", value: expectedLocation.absoluteString),
                        .init(name: "Retry-After", value: expectedRetry.description),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: .none
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        try await withTemporaryDirectory { temporaryDirectory in
            let archivePath = temporaryDirectory.appending("\(identity)-\(version).zip")
            try localFileSystem.writeFileContents(archivePath, string: archiveContent)

            let metadataPath = temporaryDirectory.appending("\(identity)-\(version)-metadata.json")
            try localFileSystem.writeFileContents(metadataPath, string: metadataContent)

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            var configuration = RegistryConfiguration()
            configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

            let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
            let result = try await registryClient.publish(
                registryURL: registryURL,
                packageIdentity: identity,
                packageVersion: version,
                packageArchive: archivePath,
                packageMetadata: metadataPath,
                signature: .none,
                metadataSignature: .none,
                signatureFormat: .none,
                fileSystem: localFileSystem
            )

            XCTAssertEqual(result, .processing(statusURL: expectedLocation, retryAfter: expectedRetry))
        }
    }

    func testRegistryPublishWithSignature() async throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let publishURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")
        let expectedLocation =
            URL("https://\(registryURL)/packages\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")

        let archiveContent = UUID().uuidString
        let metadataContent = UUID().uuidString
        let signature = UUID().uuidString
        let metadataSignature = UUID().uuidString
        let signatureFormat = SignatureFormat.cms_1_0_0

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.put, publishURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")
                XCTAssertEqual(request.headers.get("X-Swift-Package-Signature-Format").first, signatureFormat.rawValue)

                // TODO: implement multipart form parsing
                let body = String(decoding: request.body!, as: UTF8.self)
                XCTAssertMatch(body, .contains(archiveContent))
                XCTAssertMatch(body, .contains(metadataContent))
                XCTAssertMatch(body, .contains(signature))
                XCTAssertMatch(body, .contains(metadataSignature))

                completion(.success(.init(
                    statusCode: 201,
                    headers: .init([
                        .init(name: "Location", value: expectedLocation.absoluteString),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: .none
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        try await withTemporaryDirectory { temporaryDirectory in
            let archivePath = temporaryDirectory.appending(component: "\(identity)-\(version).zip")
            try localFileSystem.writeFileContents(archivePath, string: archiveContent)

            let metadataPath = temporaryDirectory.appending(component: "\(identity)-\(version)-metadata.json")
            try localFileSystem.writeFileContents(metadataPath, string: metadataContent)

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            var configuration = RegistryConfiguration()
            configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

            let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
            let result = try await registryClient.publish(
                registryURL: registryURL,
                packageIdentity: identity,
                packageVersion: version,
                packageArchive: archivePath,
                packageMetadata: metadataPath,
                signature: Array(signature.utf8),
                metadataSignature: Array(metadataSignature.utf8),
                signatureFormat: signatureFormat,
                fileSystem: localFileSystem
            )

            XCTAssertEqual(result, .published(expectedLocation))
        }
    }

    func testRegistryPublishSignatureFormatIsRequiredIfSigned() throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")

        let archiveContent = UUID().uuidString
        let metadataContent = UUID().uuidString
        let signature = UUID().uuidString
        let metadataSignature = UUID().uuidString

        let handler: LegacyHTTPClient.Handler = { _, _, completion in
            completion(.failure(StringError("should not be called")))
        }

        try withTemporaryDirectory { temporaryDirectory in
            let archivePath = temporaryDirectory.appending(component: "\(identity)-\(version).zip")
            try localFileSystem.writeFileContents(archivePath, string: archiveContent)

            let metadataPath = temporaryDirectory.appending(component: "\(identity)-\(version)-metadata.json")
            try localFileSystem.writeFileContents(metadataPath, string: metadataContent)

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            var configuration = RegistryConfiguration()
            configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

            let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
            await XCTAssertAsyncThrowsError(try await registryClient.publish(
                registryURL: registryURL,
                packageIdentity: identity,
                packageVersion: version,
                packageArchive: archivePath,
                packageMetadata: metadataPath,
                signature: Array(signature.utf8),
                metadataSignature: Array(metadataSignature.utf8),
                signatureFormat: .none,
                fileSystem: localFileSystem
            )) { error in
                guard case RegistryError.missingSignatureFormat = error else {
                    return XCTFail("unexpected error \(error)")
                }
            }
        }
    }

    func testRegistryPublishMetadataSignatureIsRequiredIfArchiveSigned() throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")

        let archiveContent = UUID().uuidString
        let metadataContent = UUID().uuidString
        let signature = UUID().uuidString
        let signatureFormat = SignatureFormat.cms_1_0_0

        let handler: LegacyHTTPClient.Handler = { _, _, completion in
            completion(.failure(StringError("should not be called")))
        }

        try withTemporaryDirectory { temporaryDirectory in
            let archivePath = temporaryDirectory.appending(component: "\(identity)-\(version).zip")
            try localFileSystem.writeFileContents(archivePath, string: archiveContent)

            let metadataPath = temporaryDirectory.appending(component: "\(identity)-\(version)-metadata.json")
            try localFileSystem.writeFileContents(metadataPath, string: metadataContent)

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            var configuration = RegistryConfiguration()
            configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

            let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
            await XCTAssertAsyncThrowsError(try await registryClient.publish(
                registryURL: registryURL,
                packageIdentity: identity,
                packageVersion: version,
                packageArchive: archivePath,
                packageMetadata: metadataPath,
                signature: Array(signature.utf8),
                metadataSignature: .none,
                signatureFormat: signatureFormat,
                fileSystem: localFileSystem
            )) { error in
                guard case RegistryError.invalidSignature = error else {
                    return XCTFail("unexpected error \(error)")
                }
            }
        }
    }

    func testRegistryPublishArchiveSignatureIsRequiredIfMetadataSigned() throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")

        let archiveContent = UUID().uuidString
        let metadataContent = UUID().uuidString
        let metadataSignature = UUID().uuidString
        let signatureFormat = SignatureFormat.cms_1_0_0

        let handler: LegacyHTTPClient.Handler = { _, _, completion in
            completion(.failure(StringError("should not be called")))
        }

        try withTemporaryDirectory { temporaryDirectory in
            let archivePath = temporaryDirectory.appending(component: "\(identity)-\(version).zip")
            try localFileSystem.writeFileContents(archivePath, string: archiveContent)

            let metadataPath = temporaryDirectory.appending(component: "\(identity)-\(version)-metadata.json")
            try localFileSystem.writeFileContents(metadataPath, string: metadataContent)

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            var configuration = RegistryConfiguration()
            configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

            let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
            await XCTAssertAsyncThrowsError(try await registryClient.publish(
                registryURL: registryURL,
                packageIdentity: identity,
                packageVersion: version,
                packageArchive: archivePath,
                packageMetadata: metadataPath,
                signature: .none,
                metadataSignature: Array(metadataSignature.utf8),
                signatureFormat: signatureFormat,
                fileSystem: localFileSystem
            )) { error in
                guard case RegistryError.invalidSignature = error else {
                    return XCTFail("unexpected error \(error)")
                }
            }
        }
    }

    func testRegistryPublish_ServerError() throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")
        let publishURL = URL("\(registryURL)/\(identity.registry!.scope)/\(identity.registry!.name)/\(version)")

        let serverErrorHandler = ServerErrorHandler(
            method: .put,
            url: publishURL,
            errorCode: Int.random(in: 405 ..< 500),
            errorDescription: UUID().uuidString
        )

        try withTemporaryDirectory { temporaryDirectory in
            let archivePath = temporaryDirectory.appending("\(identity)-\(version).zip")
            try localFileSystem.writeFileContents(archivePath, bytes: [])

            let metadataPath = temporaryDirectory.appending("\(identity)-\(version)-metadata.json")
            try localFileSystem.writeFileContents(metadataPath, bytes: [])

            let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            var configuration = RegistryConfiguration()
            configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

            let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
            await XCTAssertAsyncThrowsError(try await registryClient.publish(
                registryURL: registryURL,
                packageIdentity: identity,
                packageVersion: version,
                packageArchive: archivePath,
                packageMetadata: metadataPath,
                signature: .none,
                metadataSignature: .none,
                signatureFormat: .none,
                fileSystem: localFileSystem
            )) { error in
                guard case RegistryError
                    .failedPublishing(
                        RegistryError
                            .serverError(
                                code: serverErrorHandler.errorCode,
                                details: serverErrorHandler.errorDescription
                            )
                    ) = error
                else {
                    return XCTFail("unexpected error \(error)")
                }
            }
        }
    }

    func testRegistryPublish_InvalidArchive() throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")

        let handler: LegacyHTTPClient.Handler = { _, _, completion in
            completion(.failure(StringError("should not be called")))
        }

        try withTemporaryDirectory { temporaryDirectory in
            let archivePath = temporaryDirectory.appending("\(identity)-\(version).zip")
            // try localFileSystem.writeFileContents(archivePath, bytes: [])

            let metadataPath = temporaryDirectory.appending("\(identity)-\(version)-metadata.json")

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            var configuration = RegistryConfiguration()
            configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

            let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
            await XCTAssertAsyncThrowsError(try await registryClient.publish(
                registryURL: registryURL,
                packageIdentity: identity,
                packageVersion: version,
                packageArchive: archivePath,
                packageMetadata: metadataPath,
                signature: .none,
                metadataSignature: .none,
                signatureFormat: .none,
                fileSystem: localFileSystem
            )) { error in
                guard case RegistryError.failedLoadingPackageArchive(archivePath) = error else {
                    return XCTFail("unexpected error \(error)")
                }
            }
        }
    }

    func testRegistryPublish_InvalidMetadata() throws {
        let registryURL = URL("https://packages.example.com")
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")

        let handler: LegacyHTTPClient.Handler = { _, _, completion in
            completion(.failure(StringError("should not be called")))
        }

        try withTemporaryDirectory { temporaryDirectory in
            let archivePath = temporaryDirectory.appending("\(identity)-\(version).zip")
            try localFileSystem.writeFileContents(archivePath, bytes: [])

            let metadataPath = temporaryDirectory.appending("\(identity)-\(version)-metadata.json")

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            var configuration = RegistryConfiguration()
            configuration.defaultRegistry = Registry(url: registryURL, supportsAvailability: false)

            let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
            await XCTAssertAsyncThrowsError(try await registryClient.publish(
                registryURL: registryURL,
                packageIdentity: identity,
                packageVersion: version,
                packageArchive: archivePath,
                packageMetadata: metadataPath,
                signature: .none,
                metadataSignature: .none,
                signatureFormat: .none,
                fileSystem: localFileSystem
            )) { error in
                guard case RegistryError.failedLoadingPackageMetadata(metadataPath) = error else {
                    return XCTFail("unexpected error \(error)")
                }
            }
        }
    }

    func testRegistryAvailability() async throws {
        let registryURL = URL("https://packages.example.com")
        let availabilityURL = URL("\(registryURL)/availability")

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, availabilityURL):
                completion(.success(.okay()))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: true)

        let registryClient = makeRegistryClient(
            configuration: .init(),
            httpClient: httpClient
        )

        let status = try await registryClient.checkAvailability(registry: registry)
        XCTAssertEqual(status, .available)
    }

    func testRegistryAvailability_NotAvailable() async throws {
        let registryURL = URL("https://packages.example.com")
        let availabilityURL = URL("\(registryURL)/availability")

        for unavailableStatus in RegistryClient.AvailabilityStatus.unavailableStatusCodes {
            let handler: LegacyHTTPClient.Handler = { request, _, completion in
                switch (request.method, request.url) {
                case (.get, availabilityURL):
                    completion(.success(.init(statusCode: unavailableStatus)))
                default:
                    completion(.failure(StringError("method and url should match")))
                }
            }

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            let registry = Registry(url: registryURL, supportsAvailability: true)

            let registryClient = makeRegistryClient(
                configuration: .init(),
                httpClient: httpClient
            )

            let status = try await registryClient.checkAvailability(registry: registry)
            XCTAssertEqual(status, .unavailable)
        }
    }

    func testRegistryAvailability_ServerError() async throws {
        let registryURL = URL("https://packages.example.com")
        let availabilityURL = URL("\(registryURL)/availability")

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, availabilityURL):
                completion(.success(.serverError(reason: "boom")))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: true)

        let registryClient = makeRegistryClient(
            configuration: .init(),
            httpClient: httpClient
        )

        let status = try await registryClient.checkAvailability(registry: registry)
        XCTAssertEqual(status, .error("unknown server error (500)"))
    }

    func testRegistryAvailability_NotSupported() async throws {
        let registryURL = URL("https://packages.example.com")
        let availabilityURL = URL("\(registryURL)/availability")

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, availabilityURL):
                completion(.success(.serverError(reason: "boom")))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        let registry = Registry(url: registryURL, supportsAvailability: false)

        let registryClient = makeRegistryClient(
            configuration: .init(),
            httpClient: httpClient
        )

        await XCTAssertAsyncThrowsError(try await registryClient.checkAvailability(registry: registry)) { error in
            XCTAssertEqual(
                error as? StringError,
                StringError("registry \(registry.url) does not support availability checks.")
            )
        }
    }
}

// MARK: - Sugar

extension RegistryClient {
    fileprivate func getPackageMetadata(package: PackageIdentity) async throws -> RegistryClient.PackageMetadata {
        try await self.getPackageMetadata(
            package: package,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
    }

    func getPackageVersionMetadata(
        package: PackageIdentity,
        version: Version
    ) async throws -> PackageVersionMetadata {
        try await self.getPackageVersionMetadata(
            package: package,
            version: version,
            fileSystem: InMemoryFileSystem(),
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
    }

    func getPackageVersionMetadata(
        package: PackageIdentity.RegistryIdentity,
        version: Version
    ) throws -> PackageVersionMetadata {
        // TODO: Finish removing this temp_await
        // It can't currently be removed because it is passed to
        // PackageVersionChecksumTOFU which expects a non async method
        return try temp_await { completion in
            self.getPackageVersionMetadata(
                package: package.underlying,
                version: version,
                fileSystem: InMemoryFileSystem(),
                observabilityScope: ObservabilitySystem.NOOP,
                callbackQueue: .sharedConcurrent,
                completion: completion
            )
        }
    }

    fileprivate func getAvailableManifests(
        package: PackageIdentity,
        version: Version,
        observabilityScope: ObservabilityScope = ObservabilitySystem.NOOP
    ) async throws -> [String: (toolsVersion: ToolsVersion, content: String?)] {
        try await self.getAvailableManifests(
            package: package,
            version: version,
            observabilityScope: observabilityScope,
            callbackQueue: .sharedConcurrent
        )
    }

    fileprivate func getManifestContent(
        package: PackageIdentity,
        version: Version,
        customToolsVersion: ToolsVersion?,
        observabilityScope: ObservabilityScope = ObservabilitySystem.NOOP
    ) async throws -> String {
        try await self.getManifestContent(
            package: package,
            version: version,
            customToolsVersion: customToolsVersion,
            observabilityScope: observabilityScope,
            callbackQueue: .sharedConcurrent
        )
    }

    fileprivate func downloadSourceArchive(
        package: PackageIdentity,
        version: Version,
        fileSystem: FileSystem,
        destinationPath: AbsolutePath,
        observabilityScope: ObservabilityScope = ObservabilitySystem.NOOP
    ) async throws {
        try await self.downloadSourceArchive(
            package: package,
            version: version,
            destinationPath: destinationPath,
            progressHandler: .none,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope,
            callbackQueue: .sharedConcurrent
        )
    }

    fileprivate func lookupIdentities(scmURL: SourceControlURL) async throws -> Set<PackageIdentity> {
        try await self.lookupIdentities(
            scmURL: scmURL,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
    }

    fileprivate func login(loginURL: URL) async throws {
        try await self.login(
            loginURL: loginURL,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
    }

    func publish(
        registryURL: URL,
        packageIdentity: PackageIdentity,
        packageVersion: Version,
        packageArchive: AbsolutePath,
        packageMetadata: AbsolutePath?,
        signature: [UInt8]?,
        metadataSignature: [UInt8]?,
        signatureFormat: SignatureFormat?,
        fileSystem: FileSystem
    ) async throws -> RegistryClient.PublishResult {
        try await self.publish(
            registryURL: registryURL,
            packageIdentity: packageIdentity,
            packageVersion: packageVersion,
            packageArchive: packageArchive,
            packageMetadata: packageMetadata,
            signature: signature,
            metadataSignature: metadataSignature,
            signatureFormat: signatureFormat,
            fileSystem: fileSystem,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
    }

    func checkAvailability(registry: Registry) async throws -> AvailabilityStatus {
        try await self.checkAvailability(
            registry: registry,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
    }
}

func makeRegistryClient(
    configuration: RegistryConfiguration,
    httpClient: LegacyHTTPClient,
    authorizationProvider: AuthorizationProvider? = .none,
    fingerprintStorage: PackageFingerprintStorage = MockPackageFingerprintStorage(),
    fingerprintCheckingMode: FingerprintCheckingMode = .strict,
    skipSignatureValidation: Bool = false,
    signingEntityStorage: PackageSigningEntityStorage = MockPackageSigningEntityStorage(),
    signingEntityCheckingMode: SigningEntityCheckingMode = .strict,
    checksumAlgorithm: HashAlgorithm = MockHashAlgorithm()
) -> RegistryClient {
    RegistryClient(
        configuration: configuration,
        fingerprintStorage: fingerprintStorage,
        fingerprintCheckingMode: fingerprintCheckingMode,
        skipSignatureValidation: skipSignatureValidation,
        signingEntityStorage: signingEntityStorage,
        signingEntityCheckingMode: signingEntityCheckingMode,
        authorizationProvider: authorizationProvider,
        customHTTPClient: httpClient,
        customArchiverProvider: { _ in MockArchiver() },
        delegate: .none,
        checksumAlgorithm: checksumAlgorithm
    )
}

private struct TestProvider: AuthorizationProvider {
    let map: [String: (user: String, password: String)]

    func authentication(for url: URL) -> (user: String, password: String)? {
        self.map[url.host!]
    }
}

struct ServerErrorHandler {
    let method: HTTPMethod
    let url: URL
    let errorCode: Int
    let errorDescription: String

    init(
        method: HTTPMethod,
        url: URL,
        errorCode: Int,
        errorDescription: String
    ) {
        self.method = method
        self.url = url
        self.errorCode = errorCode
        self.errorDescription = errorDescription
    }

    func handle(
        request: LegacyHTTPClient.Request,
        progress: LegacyHTTPClient.ProgressHandler?,
        completion: @escaping ((Result<LegacyHTTPClient.Response, Error>) -> Void)
    ) {
        let data = """
        {
            "detail": "\(self.errorDescription)"
        }
        """.data(using: .utf8)!

        if request.method == self.method &&
            request.url == self.url
        {
            completion(
                .success(.init(
                    statusCode: self.errorCode,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/problem+json"),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: data
                ))
            )
        } else {
            completion(
                .failure(StringError("unexpected request"))
            )
        }
    }
}

struct UnavailableServerErrorHandler {
    let registryURL: URL
    init(registryURL: URL) {
        self.registryURL = registryURL
    }

    func handle(
        request: LegacyHTTPClient.Request,
        progress: LegacyHTTPClient.ProgressHandler?,
        completion: @escaping ((Result<LegacyHTTPClient.Response, Error>) -> Void)
    ) {
        if request.method == .get && request.url == URL("\(self.registryURL)/availability") {
            completion(
                .success(.init(
                    statusCode: RegistryClient.AvailabilityStatus.unavailableStatusCodes.first!
                ))
            )
        } else {
            completion(
                .failure(StringError("unexpected request"))
            )
        }
    }
}

private func manifestContent(toolsVersion: ToolsVersion?) -> String {
    """
    // swift-tools-version:\(toolsVersion ?? ToolsVersion.current)

    import PackageDescription

    let package = Package()
    """
}
