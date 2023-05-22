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

import Basics
import Dispatch
import struct Foundation.Date
import class Foundation.JSONDecoder
import struct Foundation.NSRange
import class Foundation.NSRegularExpression
import struct Foundation.URL
import PackageModel

import protocol TSCBasic.Closable

import struct TSCUtility.Version

struct GitHubPackageMetadataProvider: PackageMetadataProvider, Closable {
    private static let apiHostPrefix = "api."
    private static let service = Model.Package.Author.Service(name: "GitHub")

    let configuration: Configuration
    private let observabilityScope: ObservabilityScope
    private let httpClient: LegacyHTTPClient
    private let decoder: JSONDecoder

    private let cache: SQLiteBackedCache<CacheValue>?

    init(configuration: Configuration = .init(), observabilityScope: ObservabilityScope, httpClient: LegacyHTTPClient? = nil) {
        self.configuration = configuration
        self.observabilityScope = observabilityScope
        self.httpClient = httpClient ?? Self.makeDefaultHTTPClient()
        self.decoder = JSONDecoder.makeWithDefaults()
        if configuration.cacheTTLInSeconds > 0 {
            var cacheConfig = SQLiteBackedCacheConfiguration()
            cacheConfig.maxSizeInMegabytes = configuration.cacheSizeInMegabytes
            self.cache = SQLiteBackedCache<CacheValue>(
                tableName: "github_cache",
                path: configuration.cacheDir.appending("package-metadata.db"),
                configuration: cacheConfig
            )
        } else {
            self.cache = nil
        }
    }

    func close() throws {
        try self.cache?.close()
    }

    func get(
        identity: PackageIdentity,
        location: String,
        callback: @escaping (Result<Model.PackageBasicMetadata, Error>, PackageMetadataProviderContext?) -> Void
    ) {
        guard let baseURL = Self.apiURL(location) else {
            return self.errorCallback(GitHubPackageMetadataProviderError.invalidSourceControlURL(location), apiHost: nil, callback: callback)
        }

        if let cached = try? self.cache?.get(key: identity.description) {
            if cached.dispatchTime + DispatchTimeInterval.seconds(self.configuration.cacheTTLInSeconds) > DispatchTime.now() {
                return callback(.success(cached.package), self.createContext(apiHost: baseURL.host, error: nil))
            }
        }

        let metadataURL = baseURL
        // TODO: make `per_page` configurable? GitHub API's max/default is 100
        let releasesURL = URL(string: baseURL.appendingPathComponent("releases").absoluteString + "?per_page=20") ?? baseURL.appendingPathComponent("releases")
        let contributorsURL = baseURL.appendingPathComponent("contributors")
        let readmeURL = baseURL.appendingPathComponent("readme")
        let licenseURL = baseURL.appendingPathComponent("license")
        let languagesURL = baseURL.appendingPathComponent("languages")

        let sync = DispatchGroup()
        let results = ThreadSafeKeyValueStore<URL, Result<HTTPClientResponse, Error>>()

        // get the main data
        sync.enter()
        var metadataHeaders = HTTPClientHeaders()
        metadataHeaders.add(name: "Accept", value: "application/vnd.github.mercy-preview+json")
        let metadataOptions = self.makeRequestOptions(validResponseCodes: [200, 401, 403, 404])
        let hasAuthorization = metadataOptions.authorizationProvider?(metadataURL) != nil
        httpClient.get(metadataURL, headers: metadataHeaders, options: metadataOptions) { result in
            defer { sync.leave() }
            results[metadataURL] = result
            if case .success(let response) = result {
                let apiLimit = response.headers.get("X-RateLimit-Limit").first.flatMap(Int.init) ?? -1
                let apiRemaining = response.headers.get("X-RateLimit-Remaining").first.flatMap(Int.init) ?? -1
                switch (response.statusCode, hasAuthorization, apiRemaining) {
                case (_, _, 0):
                    self.observabilityScope.emit(warning: "Exceeded API limits on \(metadataURL.host ?? metadataURL.absoluteString) (\(apiRemaining)/\(apiLimit)), consider configuring an API token for this service.")
                    results[metadataURL] = .failure(GitHubPackageMetadataProviderError.apiLimitsExceeded(metadataURL, apiLimit))
                case (401, true, _):
                    results[metadataURL] = .failure(GitHubPackageMetadataProviderError.invalidAuthToken(metadataURL))
                case (401, false, _):
                    results[metadataURL] = .failure(GitHubPackageMetadataProviderError.permissionDenied(metadataURL))
                case (403, _, _):
                    results[metadataURL] = .failure(GitHubPackageMetadataProviderError.permissionDenied(metadataURL))
                case (404, _, _):
                    results[metadataURL] = .failure(NotFoundError("\(baseURL)"))
                case (200, _, _):
                    if apiRemaining < self.configuration.apiLimitWarningThreshold {
                        self.observabilityScope.emit(warning: "Approaching API limits on \(metadataURL.host ?? metadataURL.absoluteString) (\(apiRemaining)/\(apiLimit)), consider configuring an API token for this service.")
                    }
                    // if successful, fan out multiple API calls
                    [releasesURL, contributorsURL, readmeURL, licenseURL, languagesURL].forEach { url in
                        sync.enter()
                        var headers = HTTPClientHeaders()
                        headers.add(name: "Accept", value: "application/vnd.github.v3+json")
                        let options = self.makeRequestOptions(validResponseCodes: [200])
                        self.httpClient.get(url, headers: headers, options: options) { result in
                            defer { sync.leave() }
                            results[url] = result
                        }
                    }
                default:
                    results[metadataURL] = .failure(GitHubPackageMetadataProviderError.invalidResponse(metadataURL, "Invalid status code: \(response.statusCode)"))
                }
            }
        }

        // process results
        sync.notify(queue: self.httpClient.configuration.callbackQueue) {
            do {
                // check for main request error state
                switch results[metadataURL] {
                case .none:
                    throw GitHubPackageMetadataProviderError.invalidResponse(metadataURL, "Response missing")
                case .some(.failure(let error)):
                    throw error
                case .some(.success(let metadataResponse)):
                    guard let metadata = try metadataResponse.decodeBody(GetRepositoryResponse.self, using: self.decoder) else {
                        throw GitHubPackageMetadataProviderError.invalidResponse(metadataURL, "Empty body")
                    }
                    let releases = try results[releasesURL]?.success?.decodeBody([Release].self, using: self.decoder) ?? []
                    let contributors = try results[contributorsURL]?.success?.decodeBody([Contributor].self, using: self.decoder)
                    let readme = try results[readmeURL]?.success?.decodeBody(Readme.self, using: self.decoder)
                    let license = try results[licenseURL]?.success?.decodeBody(License.self, using: self.decoder)
                    let languages = try results[languagesURL]?.success?.decodeBody([String: Int].self, using: self.decoder)?.keys

                    let model = Model.PackageBasicMetadata(
                        summary: metadata.description,
                        keywords: metadata.topics,
                        // filters out non-semantic versioned tags
                        versions: releases.compactMap {
                            guard let version = $0.tagName.flatMap(TSCUtility.Version.init(tag:)) else {
                                return nil
                            }
                            return Model.PackageBasicVersionMetadata(
                                version: version,
                                title: $0.name,
                                summary: $0.body,
                                author: $0.author.map { .init(username: $0.login, url: $0.url, service: Self.service) },
                                createdAt: $0.createdAt
                            )
                        },
                        watchersCount: metadata.watchersCount,
                        readmeURL: readme?.downloadURL,
                        license: license.flatMap { .init(type: Model.LicenseType(string: $0.license.spdxID), url: $0.downloadURL) },
                        authors: contributors?.map { .init(username: $0.login, url: $0.url, service: Self.service) },
                        languages: languages.flatMap(Set.init) ?? metadata.language.map { [$0] }
                    )

                    do {
                        try self.cache?.put(
                            key: identity.description,
                            value: CacheValue(package: model, timestamp: DispatchTime.now()),
                            replace: true,
                            observabilityScope: self.observabilityScope
                        )
                    } catch {
                        self.observabilityScope.emit(
                            warning: "Failed to save GitHub metadata for package \(identity) to cache",
                            underlyingError: error
                        )
                    }

                    callback(.success(model), self.createContext(apiHost: baseURL.host, error: nil))
                }
            } catch {
                self.errorCallback(error, apiHost: baseURL.host, callback: callback)
            }
        }
    }
    
    private func errorCallback(
        _ error: Error,
        apiHost: String?,
        callback: @escaping (Result<Model.PackageBasicMetadata, Error>, PackageMetadataProviderContext?) -> Void
    ) {
        callback(.failure(error), self.createContext(apiHost: apiHost, error: error))
    }
    
    private func createContext(apiHost: String?, error: Error?) -> PackageMetadataProviderContext? {
        // We can't do anything if we can't determine API host
        guard let apiHost else {
            return nil
        }
        
        let authTokenType = self.getAuthTokenType(for: apiHost)
        let isAuthTokenConfigured = self.configuration.authTokens()?[authTokenType] != nil
        
        // This provider should only deal with GitHub token type
        guard case .github(let host) = authTokenType else {
            return nil
        }
        
        guard let error else {
            // It's possible for the request to complete successfully without auth token configured, in
            // which case we will hit the API limit much more easily, so we should always communicate
            // auth token state to the caller (e.g., so it can prompt user to configure auth token).
            return PackageMetadataProviderContext(
                name: host,
                authTokenType: authTokenType,
                isAuthTokenConfigured: isAuthTokenConfigured
            )
        }
        
        switch error {
        case let error as GitHubPackageMetadataProviderError:
            guard let providerError = PackageMetadataProviderError.from(error) else {
                // Only auth-related GitHub errors can be translated, so for all others
                // assume this provider cannot be used for the package.
                return nil
            }
            
            return PackageMetadataProviderContext(
                name: host,
                authTokenType: authTokenType,
                isAuthTokenConfigured: isAuthTokenConfigured,
                error: providerError
            )
        default:
            // For all other errors, including NotFoundError, assume this provider is not
            // intended for the package (e.g., the repository might not be hosted on GitHub).
            return nil
        }
    }
    
    private func getAuthTokenType(for host: String) -> AuthTokenType {
        let host = host.hasPrefix(Self.apiHostPrefix) ? String(host.dropFirst(Self.apiHostPrefix.count)) : host
        return .github(host)
    }

    // FIXME: use URL instead of string
    internal static func apiURL(_ url: String) -> URL? {
        let regex = #/(?<host>[^/@]+)[:/](?<owner>[^:/]+)/(?<repo>[^/.]+)(\.git)?$/#.ignoresCase()
        guard let match = url.firstMatch(of: regex) else {
            return nil
        }
        return URL(string: "https://\(Self.apiHostPrefix)\(match.host)/repos/\(match.owner)/\(match.repo)")
    }

    private func makeRequestOptions(validResponseCodes: [Int]) -> LegacyHTTPClientRequest.Options {
        var options = LegacyHTTPClientRequest.Options()
        options.addUserAgent = true
        options.validResponseCodes = validResponseCodes
        options.authorizationProvider = { url in
            url.host.flatMap { host in
                let tokenType = self.getAuthTokenType(for: host)
                return self.configuration.authTokens()?[tokenType].flatMap { token in
                    "token \(token)"
                }
            }
        }
        return options
    }

    private static func makeDefaultHTTPClient() -> LegacyHTTPClient {
        let client = LegacyHTTPClient()
        // TODO: make these defaults configurable?
        client.configuration.requestTimeout = .seconds(1)
        client.configuration.retryStrategy = .exponentialBackoff(maxAttempts: 3, baseDelay: .milliseconds(50))
        client.configuration.circuitBreakerStrategy = .hostErrors(maxErrors: 50, age: .seconds(30))
        return client
    }

    public struct Configuration {
        public var authTokens: () -> [AuthTokenType: String]?
        public var apiLimitWarningThreshold: Int
        public var cacheDir: AbsolutePath
        public var cacheTTLInSeconds: Int
        public var cacheSizeInMegabytes: Int

        public init(
            authTokens: @escaping () -> [AuthTokenType: String]? = { nil },
            apiLimitWarningThreshold: Int? = nil,
            disableCache: Bool = false,
            cacheDir: AbsolutePath? = nil,
            cacheTTLInSeconds: Int? = nil,
            cacheSizeInMegabytes: Int? = nil            
        ) {
            self.authTokens = authTokens
            self.apiLimitWarningThreshold = apiLimitWarningThreshold ?? 5
            self.cacheDir = (try? cacheDir.map(resolveSymlinks)) ?? (try? localFileSystem.swiftPMCacheDirectory.appending(components: "package-metadata")) ?? .root
            self.cacheTTLInSeconds = disableCache ? -1 : (cacheTTLInSeconds ?? 3600)
            self.cacheSizeInMegabytes = cacheSizeInMegabytes ?? 10
        }
    }

    private struct CacheValue: Codable {
        let package: Model.PackageBasicMetadata
        let timestamp: UInt64

        var dispatchTime: DispatchTime {
            DispatchTime(uptimeNanoseconds: self.timestamp)
        }

        init(package: Model.PackageBasicMetadata, timestamp: DispatchTime) {
            self.package = package
            self.timestamp = timestamp.uptimeNanoseconds
        }
    }
}

enum GitHubPackageMetadataProviderError: Error, Equatable {
    case invalidSourceControlURL(String)
    case invalidResponse(URL, String)
    case permissionDenied(URL)
    case invalidAuthToken(URL)
    case apiLimitsExceeded(URL, Int)
}

private extension PackageMetadataProviderError {
    static func from(_ error: GitHubPackageMetadataProviderError) -> PackageMetadataProviderError? {
        switch error {
        case .invalidResponse(_, let errorMessage):
            return .invalidResponse(errorMessage: errorMessage)
        case .permissionDenied:
            return .permissionDenied
        case .invalidAuthToken:
            return .invalidAuthToken
        case .apiLimitsExceeded:
            return .apiLimitsExceeded
        default:
            // This metadata provider is not intended for the given package reference
            return nil
        }
    }
}

extension GitHubPackageMetadataProvider {
    fileprivate struct GetRepositoryResponse: Codable {
        let name: String
        let fullName: String
        let description: String?
        let topics: [String]?
        let isPrivate: Bool
        let isFork: Bool
        let defaultBranch: String
        let updatedAt: Date
        let sshURL: URL
        let cloneURL: URL
        let tagsURL: URL
        let contributorsURL: URL
        let language: String?
        let watchersCount: Int
        let forksCount: Int

        private enum CodingKeys: String, CodingKey {
            case name
            case fullName = "full_name"
            case description
            case topics
            case isPrivate = "private"
            case isFork = "fork"
            case defaultBranch = "default_branch"
            case updatedAt = "updated_at"
            case sshURL = "ssh_url"
            case cloneURL = "clone_url"
            case tagsURL = "tags_url"
            case contributorsURL = "contributors_url"
            case language
            case watchersCount = "watchers_count"
            case forksCount = "forks_count"
        }
    }
}

extension GitHubPackageMetadataProvider {
    fileprivate struct Release: Codable {
        let name: String
        let tagName: String?
        // This might contain rich-text
        let body: String?
        let createdAt: Date
        let publishedAt: Date?
        let author: Author?

        private enum CodingKeys: String, CodingKey {
            case name
            case tagName = "tag_name"
            case body
            case createdAt = "created_at"
            case publishedAt = "published_at"
            case author
        }
        
        fileprivate struct Author: Codable {
            let login: String
            let url: URL?
        }
    }

    fileprivate struct Tag: Codable {
        let name: String
        let tarballURL: URL
        let commit: Commit

        private enum CodingKeys: String, CodingKey {
            case name
            case tarballURL = "tarball_url"
            case commit
        }
    }

    fileprivate struct Commit: Codable {
        let sha: String
        let url: URL
    }

    fileprivate struct Contributor: Codable {
        let login: String
        let url: URL
        let contributions: Int
    }

    fileprivate struct Readme: Codable {
        let url: URL
        let htmlURL: URL
        let downloadURL: URL

        private enum CodingKeys: String, CodingKey {
            case url
            case htmlURL = "html_url"
            case downloadURL = "download_url"
        }
    }

    fileprivate struct License: Codable {
        let url: URL
        let htmlURL: URL
        let downloadURL: URL
        let license: License

        private enum CodingKeys: String, CodingKey {
            case url
            case htmlURL = "html_url"
            case downloadURL = "download_url"
            case license
        }

        fileprivate struct License: Codable {
            let name: String
            let spdxID: String

            private enum CodingKeys: String, CodingKey {
                case name
                case spdxID = "spdx_id"
            }
        }
    }
}
