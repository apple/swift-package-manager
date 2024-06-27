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
import XCTest

import Basics
@testable import PackageCollections
import PackageCollectionsSigning
import PackageModel
import SourceControl
import _InternalTestSupport

class JSONPackageCollectionProviderTests: XCTestCase {
    func testGood() async throws {
        try await fixture(name: "Collections", createGitRepo: false) { fixturePath in
            let path = fixturePath.appending(components: "JSON", "good.json")
            let url = URL("https://www.test.com/collection.json")
            let data: Data = try localFileSystem.readFileContents(path)

            let handler: LegacyHTTPClient.Handler = { request, _, completion in
                XCTAssertEqual(request.url, url, "url should match")
                switch request.method {
                case .head:
                    completion(.success(.init(statusCode: 200,
                                              headers: .init([.init(name: "Content-Length", value: "\(data.count)")]))))
                case .get:
                    completion(.success(.init(statusCode: 200,
                                              headers: .init([.init(name: "Content-Length", value: "\(data.count)")]),
                                              body: data)))
                default:
                    XCTFail("method should match")
                }
            }

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none
            let provider = JSONPackageCollectionProvider(httpClient: httpClient)
            let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)
            let collection = try await provider.get(source)

            XCTAssertEqual(collection.name, "Sample Package Collection")
            XCTAssertEqual(collection.overview, "This is a sample package collection listing made-up packages.")
            XCTAssertEqual(collection.keywords, ["sample package collection"])
            XCTAssertEqual(collection.createdBy?.name, "Jane Doe")
            XCTAssertEqual(collection.packages.count, 2)

            let package = collection.packages.first!
            XCTAssertEqual(package.identity, PackageIdentity.plain("repos.one"))
            XCTAssertEqual(package.location, "https://www.example.com/repos/RepoOne.git")
            XCTAssertEqual(package.summary, "Package One")
            XCTAssertEqual(package.keywords, ["sample package"])
            XCTAssertEqual(package.readmeURL, "https://www.example.com/repos/RepoOne/README")
            XCTAssertEqual(package.license, .init(type: .Apache2_0, url: "https://www.example.com/repos/RepoOne/LICENSE"))
            XCTAssertEqual(package.versions.count, 1)
            let version = package.versions.first!
            XCTAssertEqual(version.summary, "Fixed a few bugs")
            let manifest = version.manifests.values.first!
            XCTAssertEqual(manifest.packageName, "PackageOne")
            XCTAssertEqual(manifest.targets, [.init(name: "Foo", moduleName: "Foo")])
            XCTAssertEqual(manifest.products, [.init(name: "Foo", type: .library(.automatic), targets: [.init(name: "Foo", moduleName: "Foo")])])
            XCTAssertEqual(manifest.toolsVersion, ToolsVersion(string: "5.1")!)
            XCTAssertEqual(manifest.minimumPlatformVersions, [SupportedPlatform(platform: .macOS, version: .init("10.15"))])
            XCTAssertEqual(version.verifiedCompatibility?.count, 3)
            XCTAssertEqual(version.verifiedCompatibility!.first!.platform, .macOS)
            XCTAssertEqual(version.verifiedCompatibility!.first!.swiftVersion, SwiftLanguageVersion(string: "5.1")!)
            XCTAssertEqual(version.license, .init(type: .Apache2_0, url: "https://www.example.com/repos/RepoOne/LICENSE"))
            XCTAssertEqual(version.author?.username, "J. Appleseed")
            XCTAssertEqual(version.signer?.commonName, "J. Appleseed")
            XCTAssertNotNil(version.createdAt)
            XCTAssertFalse(collection.isSigned)
            
            XCTAssertEqual(collection.packages[1].identity, .init(urlString: "https://www.example.com/repos/RepoTwo.git"))

            // "1.8.3" is originally "v1.8.3"
            XCTAssertEqual(["2.1.0", "1.8.3"], collection.packages[1].versions.map { $0.version.description })
        }
    }

    func testLocalFile() async throws {
        try await fixture(name: "Collections", createGitRepo: false) { fixturePath in
            let path = fixturePath.appending(components: "JSON", "good.json")

            let httpClient = LegacyHTTPClient(handler: { (_, _, _) -> Void in fatalError("should not be called") })
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none
            let provider = JSONPackageCollectionProvider(httpClient: httpClient)
            let source = PackageCollectionsModel.CollectionSource(type: .json, url: path.asURL)
            let collection = try await provider.get(source)

            XCTAssertEqual(collection.name, "Sample Package Collection")
            XCTAssertEqual(collection.overview, "This is a sample package collection listing made-up packages.")
            XCTAssertEqual(collection.keywords, ["sample package collection"])
            XCTAssertEqual(collection.createdBy?.name, "Jane Doe")
            XCTAssertEqual(collection.packages.count, 2)

            let package = collection.packages.first!
            XCTAssertEqual(package.identity, PackageIdentity.plain("repos.one"))
            XCTAssertEqual(package.location, "https://www.example.com/repos/RepoOne.git")
            XCTAssertEqual(package.summary, "Package One")
            XCTAssertEqual(package.keywords, ["sample package"])
            XCTAssertEqual(package.readmeURL, "https://www.example.com/repos/RepoOne/README")
            XCTAssertEqual(package.license, .init(type: .Apache2_0, url: "https://www.example.com/repos/RepoOne/LICENSE"))
            XCTAssertEqual(package.versions.count, 1)
            let version = package.versions.first!
            let manifest = version.manifests.values.first!
            XCTAssertEqual(manifest.packageName, "PackageOne")
            XCTAssertEqual(manifest.targets, [.init(name: "Foo", moduleName: "Foo")])
            XCTAssertEqual(manifest.products, [.init(name: "Foo", type: .library(.automatic), targets: [.init(name: "Foo", moduleName: "Foo")])])
            XCTAssertEqual(manifest.toolsVersion, ToolsVersion(string: "5.1")!)
            XCTAssertEqual(manifest.minimumPlatformVersions, [SupportedPlatform(platform: .macOS, version: .init("10.15"))])
            XCTAssertEqual(version.verifiedCompatibility?.count, 3)
            XCTAssertEqual(version.verifiedCompatibility!.first!.platform, .macOS)
            XCTAssertEqual(version.verifiedCompatibility!.first!.swiftVersion, SwiftLanguageVersion(string: "5.1")!)
            XCTAssertEqual(version.license, .init(type: .Apache2_0, url: "https://www.example.com/repos/RepoOne/LICENSE"))
            XCTAssertEqual(version.author?.username, "J. Appleseed")
            XCTAssertEqual(version.signer?.commonName, "J. Appleseed")
            XCTAssertNotNil(version.createdAt)
            XCTAssertFalse(collection.isSigned)
            
            XCTAssertEqual(collection.packages[1].identity, .init(urlString: "https://www.example.com/repos/RepoTwo.git"))

            // "1.8.3" is originally "v1.8.3"
            XCTAssertEqual(["2.1.0", "1.8.3"], collection.packages[1].versions.map { $0.version.description })
        }
    }

    func testInvalidURL() async throws {
        let url = URL("ftp://www.test.com/collection.json")
        let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)
        let httpClient = LegacyHTTPClient(handler: { (_, _, _) -> Void in fatalError("should not be called") })
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none
        let provider = JSONPackageCollectionProvider(httpClient: httpClient)
        await XCTAssertAsyncThrowsError(try await provider.get(source), "expected error", { error in
            guard case .invalidSource(let errorMessage) = error as? JSONPackageCollectionProviderError else {
                return XCTFail("invalid error \(error)")
            }
            XCTAssertTrue(errorMessage.contains("Scheme (\"ftp\") not allowed: \(url.absoluteString)"))
        })
    }

    func testExceedsDownloadSizeLimitHead() async throws {
        let maxSize: Int64 = 50
        let url = URL("https://www.test.com/collection.json")
        let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            XCTAssertEqual(request.url, url, "url should match")
            XCTAssertEqual(request.method, .head, "method should match")
            completion(.success(.init(statusCode: 200,
                                      headers: .init([.init(name: "Content-Length", value: "\(maxSize * 2)")]))))
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none
        let configuration = JSONPackageCollectionProvider.Configuration(maximumSizeInBytes: 10)
        let provider = JSONPackageCollectionProvider(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(try await provider.get(source), "expected error", { error in
            XCTAssertEqual(error as? JSONPackageCollectionProviderError, .responseTooLarge(url, maxSize * 2))
        })
    }

    func testExceedsDownloadSizeLimitGet() async throws {
        let maxSize: Int64 = 50
        let url = URL("https://www.test.com/collection.json")
        let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            XCTAssertEqual(request.url, url, "url should match")
            switch request.method {
            case .head:
                completion(.success(.init(statusCode: 200,
                                          headers: .init([.init(name: "Content-Length", value: "0")]))))
            case .get:
                completion(.success(.init(statusCode: 200,
                                          headers: .init([.init(name: "Content-Length", value: "\(maxSize * 2)")]))))
            default:
                XCTFail("method should match")
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none
        let configuration = JSONPackageCollectionProvider.Configuration(maximumSizeInBytes: 10)
        let provider = JSONPackageCollectionProvider(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(try await provider.get(source), "expected error", { error in
            XCTAssertEqual(error as? JSONPackageCollectionProviderError, .responseTooLarge(url, maxSize * 2))
        })
    }

    func testNoContentLengthOnGet() async throws {
        let url = URL("https://www.test.com/collection.json")
        let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            XCTAssertEqual(request.url, url, "url should match")
            XCTAssertTrue([.head, .get].contains(request.method), "method should match")
            completion(.success(.init(statusCode: 200)))
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none
        let configuration = JSONPackageCollectionProvider.Configuration(maximumSizeInBytes: 10)
        let provider = JSONPackageCollectionProvider(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(try await provider.get(source), "expected error", { error in
            XCTAssertEqual(error as? JSONPackageCollectionProviderError, .invalidResponse(url, "Missing Content-Length header"))
        })
    }

    func testExceedsDownloadSizeLimitProgress() async throws {
        let maxSize: Int64 = 50
        let url = URL("https://www.test.com/collection.json")
        let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)

        let handler: LegacyHTTPClient.Handler = { request, progress, completion in
            XCTAssertEqual(request.url, url, "url should match")
            switch request.method {
            case .head:
                completion(.success(.init(statusCode: 200,
                                          headers: .init([.init(name: "Content-Length", value: "0")]))))
            case .get:
                do {
                    try progress?(Int64(maxSize * 2), 0)
                } catch {
                    completion(.failure(error))
                }
            default:
                XCTFail("method should match")
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none
        let configuration = JSONPackageCollectionProvider.Configuration(maximumSizeInBytes: 10)
        let provider = JSONPackageCollectionProvider(configuration: configuration, httpClient: httpClient)
        await XCTAssertAsyncThrowsError(try await provider.get(source), "expected error", { error in
            XCTAssertEqual(error as? HTTPClientError, .responseTooLarge(maxSize * 2))
        })
    }

    func testUnsuccessfulHead_unavailable() async throws {
        let url = URL("https://www.test.com/collection.json")
        let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)
        let statusCode = Int.random(in: 500 ... 550) // Don't use 404 because it leads to a different error message

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            XCTAssertEqual(request.url, url, "url should match")
            XCTAssertEqual(request.method, .head, "method should match")
            completion(.success(.init(statusCode: statusCode)))
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none
        let provider = JSONPackageCollectionProvider(httpClient: httpClient)
        await XCTAssertAsyncThrowsError(try await provider.get(source), "expected error", { error in
            XCTAssertEqual(error as? JSONPackageCollectionProviderError, .collectionUnavailable(url, statusCode))
        })
    }

    func testUnsuccessfulGet_unavailable() async throws {
        let url = URL("https://www.test.com/collection.json")
        let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)
        let statusCode = Int.random(in: 500 ... 550) // Don't use 404 because it leads to a different error message

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            XCTAssertEqual(request.url, url, "url should match")
            switch request.method {
            case .head:
                completion(.success(.init(statusCode: 200, headers: .init([.init(name: "Content-Length", value: "1")]))))
            case .get:
                completion(.success(.init(statusCode: statusCode)))
            default:
                XCTFail("method should match")
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none
        let provider = JSONPackageCollectionProvider(httpClient: httpClient)
        await XCTAssertAsyncThrowsError(try await provider.get(source), "expected error", { error in
            XCTAssertEqual(error as? JSONPackageCollectionProviderError, .collectionUnavailable(url, statusCode))
        })
    }

    func testUnsuccessfulHead_notFound() async throws {
        let url = URL("https://www.test.com/collection.json")
        let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            XCTAssertEqual(request.url, url, "url should match")
            XCTAssertEqual(request.method, .head, "method should match")
            completion(.success(.init(statusCode: 404)))
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none
        let provider = JSONPackageCollectionProvider(httpClient: httpClient)
        await XCTAssertAsyncThrowsError(try await provider.get(source), "expected error", { error in
            XCTAssertEqual(error as? JSONPackageCollectionProviderError, .collectionNotFound(url))
        })
    }

    func testUnsuccessfulGet_notFound() async throws {
        let url = URL("https://www.test.com/collection.json")
        let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            XCTAssertEqual(request.url, url, "url should match")
            switch request.method {
            case .head:
                completion(.success(.init(statusCode: 200, headers: .init([.init(name: "Content-Length", value: "1")]))))
            case .get:
                completion(.success(.init(statusCode: 404)))
            default:
                XCTFail("method should match")
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none
        let provider = JSONPackageCollectionProvider(httpClient: httpClient)
        await XCTAssertAsyncThrowsError(try await provider.get(source), "expected error", { error in
            XCTAssertEqual(error as? JSONPackageCollectionProviderError, .collectionNotFound(url))
        })
    }

    func testBadJSON() async throws {
        let url = URL("https://www.test.com/collection.json")
        let data = Data("blah".utf8)

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            XCTAssertEqual(request.url, url, "url should match")
            switch request.method {
            case .head:
                completion(.success(.init(statusCode: 200, headers: .init([.init(name: "Content-Length", value: "\(data.count)")]))))
            case .get:
                completion(.success(.init(statusCode: 200,
                                          headers: .init([.init(name: "Content-Length", value: "\(data.count)")]),
                                          body: data)))
            default:
                XCTFail("method should match")
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none
        let provider = JSONPackageCollectionProvider(httpClient: httpClient)
        let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)
        await XCTAssertAsyncThrowsError(try await provider.get(source), "expected error", { error in
            XCTAssertEqual(error as? JSONPackageCollectionProviderError, .invalidJSON(url))
        })
    }

    func testSignedGood() async throws {
        try skipIfSignatureCheckNotSupported()

        try await fixture(name: "Collections", createGitRepo: false) { fixturePath in
            let path = fixturePath.appending(components: "JSON", "good_signed.json")
            let url = URL("https://www.test.com/collection.json")
            let data: Data = try localFileSystem.readFileContents(path)

            let handler: LegacyHTTPClient.Handler = { request, _, completion in
                XCTAssertEqual(request.url, url, "url should match")
                switch request.method {
                case .head:
                    completion(.success(.init(statusCode: 200,
                                              headers: .init([.init(name: "Content-Length", value: "\(data.count)")]))))
                case .get:
                    completion(.success(.init(statusCode: 200,
                                              headers: .init([.init(name: "Content-Length", value: "\(data.count)")]),
                                              body: data)))
                default:
                    XCTFail("method should match")
                }
            }

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            // Mark collection as having valid signature
            let signatureValidator = MockCollectionSignatureValidator(["Sample Package Collection"])
            let provider = JSONPackageCollectionProvider(httpClient: httpClient, signatureValidator: signatureValidator)
            let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)
            let collection = try await provider.get(source)

            XCTAssertEqual(collection.name, "Sample Package Collection")
            XCTAssertEqual(collection.overview, "This is a sample package collection listing made-up packages.")
            XCTAssertEqual(collection.keywords, ["sample package collection"])
            XCTAssertEqual(collection.createdBy?.name, "Jane Doe")
            XCTAssertEqual(collection.packages.count, 2)

            let package = collection.packages.first!
            XCTAssertEqual(package.identity, PackageIdentity.plain("repos.one"))
            XCTAssertEqual(package.location, "https://www.example.com/repos/RepoOne.git")
            XCTAssertEqual(package.summary, "Package One")
            XCTAssertEqual(package.keywords, ["sample package"])
            XCTAssertEqual(package.readmeURL, "https://www.example.com/repos/RepoOne/README")
            XCTAssertEqual(package.license, .init(type: .Apache2_0, url: "https://www.example.com/repos/RepoOne/LICENSE"))
            XCTAssertEqual(package.versions.count, 1)
            let version = package.versions.first!
            XCTAssertEqual(version.summary, "Fixed a few bugs")
            let manifest = version.manifests.values.first!
            XCTAssertEqual(manifest.packageName, "PackageOne")
            XCTAssertEqual(manifest.targets, [.init(name: "Foo", moduleName: "Foo")])
            XCTAssertEqual(manifest.products, [.init(name: "Foo", type: .library(.automatic), targets: [.init(name: "Foo", moduleName: "Foo")])])
            XCTAssertEqual(manifest.toolsVersion, ToolsVersion(string: "5.1")!)
            XCTAssertEqual(manifest.minimumPlatformVersions, [SupportedPlatform(platform: .macOS, version: .init("10.15"))])
            XCTAssertEqual(version.verifiedCompatibility?.count, 3)
            XCTAssertEqual(version.verifiedCompatibility!.first!.platform, .macOS)
            XCTAssertEqual(version.verifiedCompatibility!.first!.swiftVersion, SwiftLanguageVersion(string: "5.1")!)
            XCTAssertEqual(version.license, .init(type: .Apache2_0, url: "https://www.example.com/repos/RepoOne/LICENSE"))
            XCTAssertEqual(version.author?.username, "J. Appleseed")
            XCTAssertEqual(version.signer?.commonName, "J. Appleseed")
            XCTAssertNotNil(version.createdAt)
            XCTAssertTrue(collection.isSigned)
            let signature = collection.signature!
            XCTAssertTrue(signature.isVerified)
            XCTAssertEqual("Sample Subject", signature.certificate.subject.commonName)
            XCTAssertEqual("Sample Issuer", signature.certificate.issuer.commonName)
            
            XCTAssertEqual(collection.packages[1].identity, .init(urlString: "https://www.example.com/repos/RepoTwo.git"))

            // "1.8.3" is originally "v1.8.3"
            XCTAssertEqual(["2.1.0", "1.8.3"], collection.packages[1].versions.map { $0.version.description })
        }
    }

    func testSigned_skipSignatureCheck() async throws {
        try await fixture(name: "Collections", createGitRepo: false) { fixturePath in
            let path = fixturePath.appending(components: "JSON", "good_signed.json")
            let url = URL("https://www.test.com/collection.json")
            let data: Data = try localFileSystem.readFileContents(path)

            let handler: LegacyHTTPClient.Handler = { request, _, completion in
                XCTAssertEqual(request.url, url, "url should match")
                switch request.method {
                case .head:
                    completion(.success(.init(statusCode: 200,
                                              headers: .init([.init(name: "Content-Length", value: "\(data.count)")]))))
                case .get:
                    completion(.success(.init(statusCode: 200,
                                              headers: .init([.init(name: "Content-Length", value: "\(data.count)")]),
                                              body: data)))
                default:
                    XCTFail("method should match")
                }
            }

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            let signatureValidator = MockCollectionSignatureValidator()
            let provider = JSONPackageCollectionProvider(httpClient: httpClient, signatureValidator: signatureValidator)
            // Skip signature check
            let source = PackageCollectionsModel.CollectionSource(type: .json, url: url, skipSignatureCheck: true)
            let collection = try await provider.get(source)

            XCTAssertEqual(collection.name, "Sample Package Collection")
            XCTAssertEqual(collection.overview, "This is a sample package collection listing made-up packages.")
            XCTAssertEqual(collection.keywords, ["sample package collection"])
            XCTAssertEqual(collection.createdBy?.name, "Jane Doe")
            XCTAssertEqual(collection.packages.count, 2)
            let package = collection.packages.first!
            XCTAssertEqual(package.identity, PackageIdentity.plain("repos.one"))
            XCTAssertEqual(package.location, "https://www.example.com/repos/RepoOne.git")
            XCTAssertEqual(package.summary, "Package One")
            XCTAssertEqual(package.keywords, ["sample package"])
            XCTAssertEqual(package.readmeURL, "https://www.example.com/repos/RepoOne/README")
            XCTAssertEqual(package.license, .init(type: .Apache2_0, url: "https://www.example.com/repos/RepoOne/LICENSE"))
            XCTAssertEqual(package.versions.count, 1)
            let version = package.versions.first!
            XCTAssertEqual(version.summary, "Fixed a few bugs")
            let manifest = version.manifests.values.first!
            XCTAssertEqual(manifest.packageName, "PackageOne")
            XCTAssertEqual(manifest.targets, [.init(name: "Foo", moduleName: "Foo")])
            XCTAssertEqual(manifest.products, [.init(name: "Foo", type: .library(.automatic), targets: [.init(name: "Foo", moduleName: "Foo")])])
            XCTAssertEqual(manifest.toolsVersion, ToolsVersion(string: "5.1")!)
            XCTAssertEqual(manifest.minimumPlatformVersions, [SupportedPlatform(platform: .macOS, version: .init("10.15"))])
            XCTAssertEqual(version.verifiedCompatibility?.count, 3)
            XCTAssertEqual(version.verifiedCompatibility!.first!.platform, .macOS)
            XCTAssertEqual(version.verifiedCompatibility!.first!.swiftVersion, SwiftLanguageVersion(string: "5.1")!)
            XCTAssertEqual(version.license, .init(type: .Apache2_0, url: "https://www.example.com/repos/RepoOne/LICENSE"))
            XCTAssertEqual(version.author?.username, "J. Appleseed")
            XCTAssertEqual(version.signer?.commonName, "J. Appleseed")
            XCTAssertNotNil(version.createdAt)
            XCTAssertTrue(collection.isSigned)
            let signature = collection.signature!
            XCTAssertFalse(signature.isVerified)
            XCTAssertEqual("Sample Subject", signature.certificate.subject.commonName)
            XCTAssertEqual("Sample Issuer", signature.certificate.issuer.commonName)
            
            XCTAssertEqual(collection.packages[1].identity, .init(urlString: "https://www.example.com/repos/RepoTwo.git"))
        }
    }

    func testSigned_noTrustedRootCertsConfigured() async throws {
        try skipIfSignatureCheckNotSupported()

        try await fixture(name: "Collections", createGitRepo: false) { fixturePath in
            let path = fixturePath.appending(components: "JSON", "good_signed.json")
            let url = URL("https://www.test.com/collection.json")
            let data: Data = try localFileSystem.readFileContents(path)

            let handler: LegacyHTTPClient.Handler = { request, _, completion in
                XCTAssertEqual(request.url, url, "url should match")
                switch request.method {
                case .head:
                    completion(.success(.init(statusCode: 200,
                                              headers: .init([.init(name: "Content-Length", value: "\(data.count)")]))))
                case .get:
                    completion(.success(.init(statusCode: 200,
                                              headers: .init([.init(name: "Content-Length", value: "\(data.count)")]),
                                              body: data)))
                default:
                    XCTFail("method should match")
                }
            }

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            let signatureValidator = MockCollectionSignatureValidator(hasTrustedRootCerts: false)
            let provider = JSONPackageCollectionProvider(httpClient: httpClient, signatureValidator: signatureValidator)
            let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)

            await XCTAssertAsyncThrowsError(try await provider.get(source), "expected error", { error in
                switch error {
                case PackageCollectionError.cannotVerifySignature:
                    break
                default:
                    XCTFail("unexpected error \(error)")
                }
            })
        }
    }

    func testSignedBad() async throws {
        try skipIfSignatureCheckNotSupported()

        try await fixture(name: "Collections", createGitRepo: false) { fixturePath in
            let path = fixturePath.appending(components: "JSON", "good_signed.json")
            let url = URL("https://www.test.com/collection.json")
            let data: Data = try localFileSystem.readFileContents(path)

            let handler: LegacyHTTPClient.Handler = { request, _, completion in
                XCTAssertEqual(request.url, url, "url should match")
                switch request.method {
                case .head:
                    completion(.success(.init(statusCode: 200,
                                              headers: .init([.init(name: "Content-Length", value: "\(data.count)")]))))
                case .get:
                    completion(.success(.init(statusCode: 200,
                                              headers: .init([.init(name: "Content-Length", value: "\(data.count)")]),
                                              body: data)))
                default:
                    XCTFail("method should match")
                }
            }

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            // The validator doesn't know about the test collection so its signature would be considered invalid
            let signatureValidator = MockCollectionSignatureValidator()
            let provider = JSONPackageCollectionProvider(httpClient: httpClient, signatureValidator: signatureValidator)
            let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)

            await XCTAssertAsyncThrowsError(try await provider.get(source), "expected error", { error in
                switch error {
                case PackageCollectionError.invalidSignature:
                    break
                default:
                    XCTFail("unexpected error \(error)")
                }
            })
        }
    }

    func testSignedLocalFile() async throws {
        try skipIfSignatureCheckNotSupported()

        try await fixture(name: "Collections", createGitRepo: false) { fixturePath in
            let path = fixturePath.appending(components: "JSON", "good_signed.json")

            let httpClient = LegacyHTTPClient(handler: { (_, _, _) -> Void in fatalError("should not be called") })
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            // Mark collection as having valid signature
            let signatureValidator = MockCollectionSignatureValidator(["Sample Package Collection"])

            let provider = JSONPackageCollectionProvider(httpClient: httpClient, signatureValidator: signatureValidator)
            let source = PackageCollectionsModel.CollectionSource(type: .json, url: path.asURL)
            let collection = try await provider.get(source)

            XCTAssertEqual(collection.name, "Sample Package Collection")
            XCTAssertEqual(collection.overview, "This is a sample package collection listing made-up packages.")
            XCTAssertEqual(collection.keywords, ["sample package collection"])
            XCTAssertEqual(collection.createdBy?.name, "Jane Doe")
            XCTAssertEqual(collection.packages.count, 2)
            let package = collection.packages.first!
            XCTAssertEqual(package.identity, PackageIdentity.plain("repos.one"))
            XCTAssertEqual(package.location, "https://www.example.com/repos/RepoOne.git")
            XCTAssertEqual(package.summary, "Package One")
            XCTAssertEqual(package.keywords, ["sample package"])
            XCTAssertEqual(package.readmeURL, "https://www.example.com/repos/RepoOne/README")
            XCTAssertEqual(package.license, .init(type: .Apache2_0, url: "https://www.example.com/repos/RepoOne/LICENSE"))
            XCTAssertEqual(package.versions.count, 1)
            let version = package.versions.first!
            let manifest = version.manifests.values.first!
            XCTAssertEqual(manifest.packageName, "PackageOne")
            XCTAssertEqual(manifest.targets, [.init(name: "Foo", moduleName: "Foo")])
            XCTAssertEqual(manifest.products, [.init(name: "Foo", type: .library(.automatic), targets: [.init(name: "Foo", moduleName: "Foo")])])
            XCTAssertEqual(manifest.toolsVersion, ToolsVersion(string: "5.1")!)
            XCTAssertEqual(manifest.minimumPlatformVersions, [SupportedPlatform(platform: .macOS, version: .init("10.15"))])
            XCTAssertEqual(version.verifiedCompatibility?.count, 3)
            XCTAssertEqual(version.verifiedCompatibility!.first!.platform, .macOS)
            XCTAssertEqual(version.verifiedCompatibility!.first!.swiftVersion, SwiftLanguageVersion(string: "5.1")!)
            XCTAssertEqual(version.license, .init(type: .Apache2_0, url: "https://www.example.com/repos/RepoOne/LICENSE"))
            XCTAssertEqual(version.author?.username, "J. Appleseed")
            XCTAssertEqual(version.signer?.commonName, "J. Appleseed")
            XCTAssertNotNil(version.createdAt)
            XCTAssertTrue(collection.isSigned)
            let signature = collection.signature!
            XCTAssertTrue(signature.isVerified)
            XCTAssertEqual("Sample Subject", signature.certificate.subject.commonName)
            XCTAssertEqual("Sample Issuer", signature.certificate.issuer.commonName)

            XCTAssertEqual(collection.packages[1].identity, .init(urlString: "https://www.example.com/repos/RepoTwo.git"))
        }
    }

    func testRequiredSigningGood() async throws {
        try await fixture(name: "Collections", createGitRepo: false) { fixturePath in
            let path = fixturePath.appending(components: "JSON", "good_signed.json")
            let url = URL("https://www.test.com/collection.json")
            let data: Data = try localFileSystem.readFileContents(path)

            let handler: LegacyHTTPClient.Handler = { request, _, completion in
                XCTAssertEqual(request.url, url, "url should match")
                switch request.method {
                case .head:
                    completion(.success(.init(statusCode: 200,
                                              headers: .init([.init(name: "Content-Length", value: "\(data.count)")]))))
                case .get:
                    completion(.success(.init(statusCode: 200,
                                              headers: .init([.init(name: "Content-Length", value: "\(data.count)")]),
                                              body: data)))
                default:
                    XCTFail("method should match")
                }
            }

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            // Mark collection as having valid signature
            let signatureValidator = MockCollectionSignatureValidator(["Sample Package Collection"])
            // Collections from www.test.com must be signed
            let sourceCertPolicy = PackageCollectionSourceCertificatePolicy(
                sourceCertPolicies: ["www.test.com": [.init(certPolicyKey: CertificatePolicyKey.default, base64EncodedRootCerts: nil)]]
            )
            let provider = JSONPackageCollectionProvider(httpClient: httpClient, signatureValidator: signatureValidator,
                                                         sourceCertPolicy: sourceCertPolicy)
            let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)
            let collection = try await provider.get(source)

            XCTAssertEqual(collection.name, "Sample Package Collection")
            XCTAssertEqual(collection.overview, "This is a sample package collection listing made-up packages.")
            XCTAssertEqual(collection.keywords, ["sample package collection"])
            XCTAssertEqual(collection.createdBy?.name, "Jane Doe")
            XCTAssertEqual(collection.packages.count, 2)
            let package = collection.packages.first!
            XCTAssertEqual(package.identity, PackageIdentity.plain("repos.one"))
            XCTAssertEqual(package.location, "https://www.example.com/repos/RepoOne.git")
            XCTAssertEqual(package.summary, "Package One")
            XCTAssertEqual(package.keywords, ["sample package"])
            XCTAssertEqual(package.readmeURL, "https://www.example.com/repos/RepoOne/README")
            XCTAssertEqual(package.license, .init(type: .Apache2_0, url: "https://www.example.com/repos/RepoOne/LICENSE"))
            XCTAssertEqual(package.versions.count, 1)
            let version = package.versions.first!
            XCTAssertEqual(version.summary, "Fixed a few bugs")
            let manifest = version.manifests.values.first!
            XCTAssertEqual(manifest.packageName, "PackageOne")
            XCTAssertEqual(manifest.targets, [.init(name: "Foo", moduleName: "Foo")])
            XCTAssertEqual(manifest.products, [.init(name: "Foo", type: .library(.automatic), targets: [.init(name: "Foo", moduleName: "Foo")])])
            XCTAssertEqual(manifest.toolsVersion, ToolsVersion(string: "5.1")!)
            XCTAssertEqual(manifest.minimumPlatformVersions, [SupportedPlatform(platform: .macOS, version: .init("10.15"))])
            XCTAssertEqual(version.verifiedCompatibility?.count, 3)
            XCTAssertEqual(version.verifiedCompatibility!.first!.platform, .macOS)
            XCTAssertEqual(version.verifiedCompatibility!.first!.swiftVersion, SwiftLanguageVersion(string: "5.1")!)
            XCTAssertEqual(version.license, .init(type: .Apache2_0, url: "https://www.example.com/repos/RepoOne/LICENSE"))
            XCTAssertEqual(version.author?.username, "J. Appleseed")
            XCTAssertEqual(version.signer?.commonName, "J. Appleseed")
            XCTAssertNotNil(version.createdAt)
            XCTAssertTrue(collection.isSigned)
            let signature = collection.signature!
            XCTAssertTrue(signature.isVerified)
            XCTAssertEqual("Sample Subject", signature.certificate.subject.commonName)
            XCTAssertEqual("Sample Issuer", signature.certificate.issuer.commonName)
            
            XCTAssertEqual(collection.packages[1].identity, .init(urlString: "https://www.example.com/repos/RepoTwo.git"))
        }
    }

    func testRequiredSigningMultiplePoliciesGood() async throws {
        try await fixture(name: "Collections", createGitRepo: false) { fixturePath in
            let path = fixturePath.appending(components: "JSON", "good_signed.json")
            let url = URL("https://www.test.com/collection.json")
            let data: Data = try localFileSystem.readFileContents(path)

            let handler: LegacyHTTPClient.Handler = { request, _, completion in
                XCTAssertEqual(request.url, url, "url should match")
                switch request.method {
                case .head:
                    completion(.success(.init(statusCode: 200,
                                              headers: .init([.init(name: "Content-Length", value: "\(data.count)")]))))
                case .get:
                    completion(.success(.init(statusCode: 200,
                                              headers: .init([.init(name: "Content-Length", value: "\(data.count)")]),
                                              body: data)))
                default:
                    XCTFail("method should match")
                }
            }

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            // Mark collection as having valid signature
            let signatureValidator = MockCollectionSignatureValidator(certPolicyKeys: [CertificatePolicyKey.default(subjectUserID: "test")])
            // Collections from www.test.com must be signed
            let sourceCertPolicy = PackageCollectionSourceCertificatePolicy(
                sourceCertPolicies: [
                    "www.test.com": [
                        .init(certPolicyKey: CertificatePolicyKey.default, base64EncodedRootCerts: nil),
                        .init(certPolicyKey: CertificatePolicyKey.default(subjectUserID: "test"), base64EncodedRootCerts: nil),
                    ],
                ]
            )
            let provider = JSONPackageCollectionProvider(httpClient: httpClient, signatureValidator: signatureValidator,
                                                         sourceCertPolicy: sourceCertPolicy)
            let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)
            let collection = try await provider.get(source)

            XCTAssertEqual(collection.name, "Sample Package Collection")
            XCTAssertEqual(collection.overview, "This is a sample package collection listing made-up packages.")
            XCTAssertEqual(collection.keywords, ["sample package collection"])
            XCTAssertEqual(collection.createdBy?.name, "Jane Doe")
            XCTAssertEqual(collection.packages.count, 2)
            let package = collection.packages.first!
            XCTAssertEqual(package.identity, PackageIdentity.plain("repos.one"))
            XCTAssertEqual(package.location, "https://www.example.com/repos/RepoOne.git")
            XCTAssertEqual(package.summary, "Package One")
            XCTAssertEqual(package.keywords, ["sample package"])
            XCTAssertEqual(package.readmeURL, "https://www.example.com/repos/RepoOne/README")
            XCTAssertEqual(package.license, .init(type: .Apache2_0, url: "https://www.example.com/repos/RepoOne/LICENSE"))
            XCTAssertEqual(package.versions.count, 1)
            let version = package.versions.first!
            XCTAssertEqual(version.summary, "Fixed a few bugs")
            let manifest = version.manifests.values.first!
            XCTAssertEqual(manifest.packageName, "PackageOne")
            XCTAssertEqual(manifest.targets, [.init(name: "Foo", moduleName: "Foo")])
            XCTAssertEqual(manifest.products, [.init(name: "Foo", type: .library(.automatic), targets: [.init(name: "Foo", moduleName: "Foo")])])
            XCTAssertEqual(manifest.toolsVersion, ToolsVersion(string: "5.1")!)
            XCTAssertEqual(manifest.minimumPlatformVersions, [SupportedPlatform(platform: .macOS, version: .init("10.15"))])
            XCTAssertEqual(version.verifiedCompatibility?.count, 3)
            XCTAssertEqual(version.verifiedCompatibility!.first!.platform, .macOS)
            XCTAssertEqual(version.verifiedCompatibility!.first!.swiftVersion, SwiftLanguageVersion(string: "5.1")!)
            XCTAssertEqual(version.license, .init(type: .Apache2_0, url: "https://www.example.com/repos/RepoOne/LICENSE"))
            XCTAssertEqual(version.author?.username, "J. Appleseed")
            XCTAssertEqual(version.signer?.commonName, "J. Appleseed")
            XCTAssertNotNil(version.createdAt)
            XCTAssertTrue(collection.isSigned)
            let signature = collection.signature!
            XCTAssertTrue(signature.isVerified)
            XCTAssertEqual("Sample Subject", signature.certificate.subject.commonName)
            XCTAssertEqual("Sample Issuer", signature.certificate.issuer.commonName)
            
            XCTAssertEqual(collection.packages[1].identity, .init(urlString: "https://www.example.com/repos/RepoTwo.git"))
        }
    }

    func testMissingRequiredSignature() async throws {
        try await fixture(name: "Collections", createGitRepo: false) { fixturePath in
            let path = fixturePath.appending(components: "JSON", "good.json")
            let url = URL("https://www.test.com/collection.json")
            let data: Data = try localFileSystem.readFileContents(path)

            let handler: LegacyHTTPClient.Handler = { request, _, completion in
                XCTAssertEqual(request.url, url, "url should match")
                switch request.method {
                case .head:
                    completion(.success(.init(statusCode: 200,
                                              headers: .init([.init(name: "Content-Length", value: "\(data.count)")]))))
                case .get:
                    completion(.success(.init(statusCode: 200,
                                              headers: .init([.init(name: "Content-Length", value: "\(data.count)")]),
                                              body: data)))
                default:
                    XCTFail("method should match")
                }
            }

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            // The validator doesn't know about the test collection so its signature would be considered invalid
            let signatureValidator = MockCollectionSignatureValidator()
            // Collections from www.test.com must be signed
            let sourceCertPolicy = PackageCollectionSourceCertificatePolicy(
                sourceCertPolicies: ["www.test.com": [.init(certPolicyKey: CertificatePolicyKey.default, base64EncodedRootCerts: nil)]]
            )
            let provider = JSONPackageCollectionProvider(httpClient: httpClient, signatureValidator: signatureValidator,
                                                         sourceCertPolicy: sourceCertPolicy)
            let source = PackageCollectionsModel.CollectionSource(type: .json, url: url)

            await XCTAssertAsyncThrowsError(try await provider.get(source), "expected error", { error in
                switch error {
                case PackageCollectionError.missingSignature:
                    break
                default:
                    XCTFail("unexpected error \(error)")
                }
            })
        }
    }
}

private extension XCTestCase {
    func skipIfSignatureCheckNotSupported() throws {
        if !JSONPackageCollectionProvider.isSignatureCheckSupported {
            throw XCTSkip("Skipping test because signature check is not supported")
        }
    }
}

internal extension JSONPackageCollectionProvider {
    init(
        configuration: Configuration = .init(),
        httpClient: LegacyHTTPClient? = nil,
        signatureValidator: PackageCollectionSignatureValidator? = nil,
        sourceCertPolicy: PackageCollectionSourceCertificatePolicy = PackageCollectionSourceCertificatePolicy(),
        fileSystem: FileSystem = localFileSystem
    ) {
        self.init(
            configuration: configuration,
            fileSystem: fileSystem,
            observabilityScope: ObservabilitySystem.NOOP,
            sourceCertPolicy: sourceCertPolicy,
            customHTTPClient: httpClient ,
            customSignatureValidator: signatureValidator
        )
    }
}
