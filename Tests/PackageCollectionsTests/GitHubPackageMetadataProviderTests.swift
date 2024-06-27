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
import PackageModel
import SourceControl
import _InternalTestSupport

import struct TSCUtility.Version

class GitHubPackageMetadataProviderTests: XCTestCase {
    func testBaseURL() throws {
        let apiURL = URL("https://api.github.com/repos/octocat/Hello-World")

        do {
            let sshURLRetVal = GitHubPackageMetadataProvider.apiURL("git@github.com:octocat/Hello-World.git")
            XCTAssertEqual(apiURL, sshURLRetVal)
        }

        do {
            let httpsURLRetVal = GitHubPackageMetadataProvider.apiURL("https://github.com/octocat/Hello-World.git")
            XCTAssertEqual(apiURL, httpsURLRetVal)
        }

        do {
            let httpsURLRetVal = GitHubPackageMetadataProvider.apiURL("https://github.com/octocat/Hello-World")
            XCTAssertEqual(apiURL, httpsURLRetVal)
        }

        XCTAssertNil(GitHubPackageMetadataProvider.apiURL("bad/Hello-World.git"))
    }

    func testGood() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let repoURL = SourceControlURL("https://github.com/octocat/Hello-World.git")
            let apiURL = URL("https://api.github.com/repos/octocat/Hello-World")
            let releasesURL = URL("https://api.github.com/repos/octocat/Hello-World/releases?per_page=20")

            try await fixture(name: "Collections", createGitRepo: false) { fixturePath in
                let handler: LegacyHTTPClient.Handler = { request, _, completion in
                    switch (request.method, request.url) {
                    case (.get, apiURL):
                        let path = fixturePath.appending(components: "GitHub", "metadata.json")
                        let data: Data = try! localFileSystem.readFileContents(path)
                        completion(.success(.init(statusCode: 200,
                                                  headers: .init([.init(name: "Content-Length", value: "\(data.count)")]),
                                                  body: data)))
                    case (.get, releasesURL):
                        let path = fixturePath.appending(components: "GitHub", "releases.json")
                        let data: Data = try! localFileSystem.readFileContents(path)
                        completion(.success(.init(statusCode: 200,
                                                  headers: .init([.init(name: "Content-Length", value: "\(data.count)")]),
                                                  body: data)))
                    case (.get, apiURL.appendingPathComponent("contributors")):
                        let path = fixturePath.appending(components: "GitHub", "contributors.json")
                        let data: Data = try! localFileSystem.readFileContents(path)
                        completion(.success(.init(statusCode: 200,
                                                  headers: .init([.init(name: "Content-Length", value: "\(data.count)")]),
                                                  body: data)))
                    case (.get, apiURL.appendingPathComponent("readme")):
                        let path = fixturePath.appending(components: "GitHub", "readme.json")
                        let data: Data = try! localFileSystem.readFileContents(path)
                        completion(.success(.init(statusCode: 200,
                                                  headers: .init([.init(name: "Content-Length", value: "\(data.count)")]),
                                                  body: data)))
                    case (.get, apiURL.appendingPathComponent("license")):
                        let path = fixturePath.appending(components: "GitHub", "license.json")
                        let data: Data = try! localFileSystem.readFileContents(path)
                        completion(.success(.init(statusCode: 200,
                                                  headers: .init([.init(name: "Content-Length", value: "\(data.count)")]),
                                                  body: data)))
                    case (.get, apiURL.appendingPathComponent("languages")):
                        let path = fixturePath.appending(components: "GitHub", "languages.json")
                        let data: Data = try! localFileSystem.readFileContents(path)
                        completion(.success(.init(statusCode: 200,
                                                  headers: .init([.init(name: "Content-Length", value: "\(data.count)")]),
                                                  body: data)))
                    default:
                        XCTFail("method and url should match")
                    }
                }

                let httpClient = LegacyHTTPClient(handler: handler)
                httpClient.configuration.circuitBreakerStrategy = .none
                httpClient.configuration.retryStrategy = .none
                var configuration = GitHubPackageMetadataProvider.Configuration()
                configuration.cacheDir = tmpPath
                let provider = GitHubPackageMetadataProvider(configuration: configuration, httpClient: httpClient)
                defer { XCTAssertNoThrow(try provider.close()) }

                let metadata = try await provider.syncGet(identity: .init(url: repoURL), location: repoURL.absoluteString)

                XCTAssertEqual(metadata.summary, "This your first repo!")
                XCTAssertEqual(metadata.versions.count, 2)
                XCTAssertEqual(metadata.versions[0].version, TSCUtility.Version(tag: "v2.0.0"))
                XCTAssertEqual(metadata.versions[0].title, "2.0.0")
                XCTAssertEqual(metadata.versions[0].summary, "Description of the release")
                XCTAssertEqual(metadata.versions[0].author?.username, "octocat")
                XCTAssertEqual(metadata.versions[1].version, TSCUtility.Version("1.0.0"))
                XCTAssertEqual(metadata.versions[1].title, "1.0.0")
                XCTAssertEqual(metadata.versions[1].summary, "Description of the release")
                XCTAssertEqual(metadata.versions[1].author?.username, "octocat")
                XCTAssertEqual(metadata.authors, [PackageCollectionsModel.Package.Author(username: "octocat",
                                                                                         url: "https://api.github.com/users/octocat",
                                                                                         service: .init(name: "GitHub"))])
                XCTAssertEqual(metadata.readmeURL, "https://raw.githubusercontent.com/octokit/octokit.rb/master/README.md")
                XCTAssertEqual(metadata.license?.type, PackageCollectionsModel.LicenseType.MIT)
                XCTAssertEqual(metadata.license?.url, "https://raw.githubusercontent.com/benbalter/gman/master/LICENSE?lab=true")
                XCTAssertEqual(metadata.watchersCount, 80)
                XCTAssertEqual(metadata.languages, ["Swift", "Shell", "C"])
            }
        }
    }

    func testRepoNotFound() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let repoURL = SourceControlURL("https://github.com/octocat/Hello-World.git")

            let handler: LegacyHTTPClient.Handler = { _, _, completion in
                completion(.success(.init(statusCode: 404)))
            }

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none
            var configuration = GitHubPackageMetadataProvider.Configuration()
            configuration.cacheDir = tmpPath
            let provider = GitHubPackageMetadataProvider(configuration: configuration, httpClient: httpClient)
            defer { XCTAssertNoThrow(try provider.close()) }

            await XCTAssertAsyncThrowsError(try await provider.syncGet(identity: .init(url: repoURL), location: repoURL.absoluteString), "should throw error") { error in
                XCTAssert(error is NotFoundError, "\(error)")
            }
        }
    }

    func testOthersNotFound() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let repoURL = SourceControlURL("https://github.com/octocat/Hello-World.git")
            let apiURL = URL("https://api.github.com/repos/octocat/Hello-World")

            try await fixture(name: "Collections", createGitRepo: false) { fixturePath in
                let path = fixturePath.appending(components: "GitHub", "metadata.json")
                let data = try Data(localFileSystem.readFileContents(path).contents)
                let handler: LegacyHTTPClient.Handler = { request, _, completion in
                    switch (request.method, request.url) {
                    case (.get, apiURL):
                        completion(.success(.init(statusCode: 200,
                                                  headers: .init([.init(name: "Content-Length", value: "\(data.count)")]),
                                                  body: data)))
                    default:
                        completion(.success(.init(statusCode: 500)))
                    }
                }

                let httpClient = LegacyHTTPClient(handler: handler)
                httpClient.configuration.circuitBreakerStrategy = .none
                httpClient.configuration.retryStrategy = .none
                var configuration = GitHubPackageMetadataProvider.Configuration()
                configuration.cacheDir = tmpPath
                let provider = GitHubPackageMetadataProvider(configuration: configuration, httpClient: httpClient)
                defer { XCTAssertNoThrow(try provider.close()) }

                let metadata = try await provider.syncGet(identity: .init(url: repoURL), location: repoURL.absoluteString)

                XCTAssertEqual(metadata.summary, "This your first repo!")
                XCTAssertEqual(metadata.versions, [])
                XCTAssertNil(metadata.authors)
                XCTAssertNil(metadata.readmeURL)
                XCTAssertEqual(metadata.watchersCount, 80)
            }
        }
    }

    func testPermissionDenied() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let repoURL = SourceControlURL("https://github.com/octocat/Hello-World.git")
            let apiURL = URL("https://api.github.com/repos/octocat/Hello-World")

            let handler: LegacyHTTPClient.Handler = { _, _, completion in
                completion(.success(.init(statusCode: 401)))
            }

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none
            var configuration = GitHubPackageMetadataProvider.Configuration()
            configuration.cacheDir = tmpPath
            let provider = GitHubPackageMetadataProvider(configuration: configuration, httpClient: httpClient)
            defer { XCTAssertNoThrow(try provider.close()) }

            await XCTAssertAsyncThrowsError(try await provider.syncGet(identity: .init(url: repoURL), location: repoURL.absoluteString), "should throw error") { error in
                XCTAssertEqual(error as? GitHubPackageMetadataProviderError, .permissionDenied(apiURL))
            }
        }
    }

    func testInvalidAuthToken() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let repoURL = SourceControlURL("https://github.com/octocat/Hello-World.git")
            let apiURL = URL("https://api.github.com/repos/octocat/Hello-World")
            let authTokens = [AuthTokenType.github("github.com"): "foo"]

            let handler: LegacyHTTPClient.Handler = { request, _, completion in
                if request.headers.get("Authorization").first == "token \(authTokens.first!.value)" {
                    completion(.success(.init(statusCode: 401)))
                } else {
                    XCTFail("expected correct authorization header")
                    completion(.success(.init(statusCode: 500)))
                }
            }

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none
            var configuration = GitHubPackageMetadataProvider.Configuration()
            configuration.cacheDir = tmpPath
            configuration.authTokens = { authTokens }
            let provider = GitHubPackageMetadataProvider(configuration: configuration, httpClient: httpClient)
            defer { XCTAssertNoThrow(try provider.close()) }

            await XCTAssertAsyncThrowsError(try await provider.syncGet(identity: .init(url: repoURL), location: repoURL.absoluteString), "should throw error") { error in
                XCTAssertEqual(error as? GitHubPackageMetadataProviderError, .invalidAuthToken(apiURL))
            }
        }
    }

    func testAPILimit() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let repoURL = SourceControlURL("https://github.com/octocat/Hello-World.git")
            let apiURL = URL("https://api.github.com/repos/octocat/Hello-World")

            let total = 5
            var remaining = total

            try await fixture(name: "Collections", createGitRepo: false) { fixturePath in
                let path = fixturePath.appending(components: "GitHub", "metadata.json")
                let data = try Data(localFileSystem.readFileContents(path).contents)
                let handler: LegacyHTTPClient.Handler = { request, _, completion in
                    var headers = HTTPClientHeaders()
                    headers.add(name: "X-RateLimit-Limit", value: "\(total)")
                    headers.add(name: "X-RateLimit-Remaining", value: "\(remaining)")
                    if remaining == 0 {
                        completion(.success(.init(statusCode: 403, headers: headers)))
                    } else if request.url == apiURL {
                        remaining = remaining - 1
                        headers.add(name: "Content-Length", value: "\(data.count)")
                        completion(.success(.init(statusCode: 200,
                                                  headers: headers,
                                                  body: data)))
                    } else {
                        completion(.success(.init(statusCode: 500)))
                    }
                }

                // Disable cache so we hit the API
                let configuration = GitHubPackageMetadataProvider.Configuration(disableCache: true)

                let httpClient = LegacyHTTPClient(handler: handler)
                httpClient.configuration.circuitBreakerStrategy = .none
                httpClient.configuration.retryStrategy = .none

                let provider = GitHubPackageMetadataProvider(configuration: configuration, httpClient: httpClient)
                defer { XCTAssertNoThrow(try provider.close()) }

                for index in 0 ... total * 2 {
                    if index >= total {
                        await XCTAssertAsyncThrowsError(try await provider.syncGet(identity: .init(url: repoURL), location: repoURL.absoluteString), "should throw error") { error in
                            XCTAssertEqual(error as? GitHubPackageMetadataProviderError, .apiLimitsExceeded(apiURL, total))
                        }
                    } else {
                        _ = try await provider.syncGet(identity: .init(url: repoURL), location: repoURL.absoluteString)
                    }
                }
            }
        }
    }

    func testInvalidURL() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            try await fixture(name: "Collections", createGitRepo: false) { _ in
                var configuration = GitHubPackageMetadataProvider.Configuration()
                configuration.cacheDir = tmpPath
                let provider = GitHubPackageMetadataProvider(configuration: configuration)
                defer { XCTAssertNoThrow(try provider.close()) }

                let url = UUID().uuidString
                let identity = PackageIdentity(urlString: url)
                await XCTAssertAsyncThrowsError(try await provider.syncGet(identity: identity, location: url), "should throw error") { error in
                    XCTAssertEqual(error as? GitHubPackageMetadataProviderError, .invalidSourceControlURL(url))
                }
            }
        }
    }

    func testInvalidURL2() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            try await fixture(name: "Collections", createGitRepo: false) { _ in
                var configuration = GitHubPackageMetadataProvider.Configuration()
                configuration.cacheDir = tmpPath
                let provider = GitHubPackageMetadataProvider(configuration: configuration)
                defer { XCTAssertNoThrow(try provider.close()) }

                let path = AbsolutePath.root
                let identity = PackageIdentity(path: path)
                await XCTAssertAsyncThrowsError(try await provider.syncGet(identity: identity, location: path.pathString), "should throw error") { error in
                    XCTAssertEqual(error as? GitHubPackageMetadataProviderError, .invalidSourceControlURL(path.pathString))
                }
            }
        }
    }

    func testForRealz() async throws {
        #if ENABLE_GITHUB_NETWORK_TEST
        #else
        try XCTSkipIf(true)
        #endif

        let repoURL = SourceControlURL("https://github.com/apple/swift-numerics.git")

        let httpClient = LegacyHTTPClient()
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none
        httpClient.configuration.requestHeaders = .init()
        httpClient.configuration.requestHeaders!.add(name: "Cache-Control", value: "no-cache")
        var configuration = GitHubPackageMetadataProvider.Configuration(disableCache: true) // Disable cache so we hit the API
        if let token = Environment.current["GITHUB_API_TOKEN"] {
            configuration.authTokens = { [.github("github.com"): token] }
        }
        configuration.apiLimitWarningThreshold = 50
        let provider = GitHubPackageMetadataProvider(configuration: configuration, httpClient: httpClient)
        defer { XCTAssertNoThrow(try provider.close()) }

        for _ in 0 ... 60 {
            let metadata = try await provider.syncGet(identity: .init(url: repoURL), location: repoURL.absoluteString)
            XCTAssertNotNil(metadata)
            XCTAssert(metadata.versions.count > 0)
            XCTAssert(metadata.keywords!.count > 0)
            XCTAssertNotNil(metadata.license)
            XCTAssert(metadata.authors!.count > 0)
        }
    }
}

internal extension GitHubPackageMetadataProvider {
    init(configuration: Configuration = .init(), httpClient: LegacyHTTPClient? = nil) {
        self.init(
            configuration: configuration,
            observabilityScope: ObservabilitySystem.NOOP,
            httpClient: httpClient
        )
    }
}

private extension GitHubPackageMetadataProvider {
    func syncGet(identity: PackageIdentity, location: String) async throws -> Model.PackageBasicMetadata {
        try await safe_async { callback in
            self.get(identity: identity, location: location) { result, _ in callback(result) }
        }
    }
}
