/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2022 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
import Dispatch
import Foundation
import PackageModel
import TSCBasic

struct PackageIndex: PackageIndexProtocol {
    private let configuration: PackageIndexConfiguration
    private let httpClient: HTTPClient
    private let callbackQueue: DispatchQueue
    private let observabilityScope: ObservabilityScope
    
    private let decoder: JSONDecoder

    // TODO: cache metadata results
    
    var isEnabled: Bool {
        self.configuration.enabled && self.configuration.url != .none
    }

    init(
        configuration: PackageIndexConfiguration,
        customHTTPClient: HTTPClient? = nil,
        callbackQueue: DispatchQueue,
        observabilityScope: ObservabilityScope
    ) {
        self.configuration = configuration
        self.httpClient = customHTTPClient ?? HTTPClient()
        self.callbackQueue = callbackQueue
        self.observabilityScope = observabilityScope
        self.decoder = JSONDecoder.makeWithDefaults()
    }

    func getPackageMetadata(
        identity: PackageIdentity,
        location: String?,
        callback: @escaping (Result<PackageCollectionsModel.PackageMetadata, Error>) -> Void
    ) {
        self.runIfConfigured(callback: callback) { url, callback in
            // TODO: rdar://87582621 call package index's get metadata API
            let metadataURL = url.appendingPathComponent("packages").appendingPathComponent(identity.description)
            self.httpClient.get(metadataURL) { result in
                callback(result.tryMap { response in
                    switch response.statusCode {
                    case 200:
                        guard let package = try response.decodeBody(PackageCollectionsModel.Package.self, using: self.decoder) else {
                            throw PackageIndexError.invalidResponse(metadataURL, "Empty body")
                        }
                        
                        let name = url.host ?? "package index"
                        let providerContext = PackageMetadataProviderContext(
                            name: name,
                            // Package index doesn't require auth
                            authTokenType: nil,
                            isAuthTokenConfigured: true
                        )
                        
                        return (package: package, collections: [], provider: providerContext)
                    default:
                        throw PackageIndexError.invalidResponse(metadataURL, "Invalid status code: \(response.statusCode)")
                    }
                })
            }
        }
    }
    
    func findPackages(
        _ query: String,
        callback: @escaping (Result<PackageCollectionsModel.PackageSearchResult, Error>) -> Void
    ) {
        self.runIfConfigured(callback: callback) { url, callback in
            // TODO: rdar://87582621 call package index's search API
            guard let searchURL = URL(string: url.appendingPathComponent("search").absoluteString + "?q=\(query)") else {
                return callback(.failure(PackageIndexError.invalidURL(url)))
            }
            self.httpClient.get(searchURL) { result in
                callback(result.tryMap { response in
                    switch response.statusCode {
                    case 200:
                        guard let packages = try response.decodeBody([PackageCollectionsModel.Package].self, using: self.decoder) else {
                            throw PackageIndexError.invalidResponse(searchURL, "Empty body")
                        }
                        // Limit the number of items
                        let items = packages[..<Int(self.configuration.searchResultMaxItemsCount)].map {
                            PackageCollectionsModel.PackageSearchResult.Item(package: $0, indexes: [url])
                        }
                        return PackageCollectionsModel.PackageSearchResult(items: items)
                    default:
                        throw PackageIndexError.invalidResponse(searchURL, "Invalid status code: \(response.statusCode)")
                    }
                })
            }
        }
    }

    func listPackages(
        offset: Int,
        limit: Int,
        callback: @escaping (Result<PackageCollectionsModel.PaginatedPackageList, Error>) -> Void
    ) {
        self.runIfConfigured(callback: callback) { url, callback in
            // TODO: rdar://87582621 call package index's list API
            guard let listURL = URL(string: url.appendingPathComponent("packages").absoluteString + "?offset=\(offset)&limit=\(limit)") else {
                return callback(.failure(PackageIndexError.invalidURL(url)))
            }
            self.httpClient.get(listURL) { result in
                callback(result.tryMap { response in
                    switch response.statusCode {
                    case 200:
                        guard let listResponse = try response.decodeBody(ListResponse.self, using: self.decoder) else {
                            throw PackageIndexError.invalidResponse(listURL, "Empty body")
                        }
                        return PackageCollectionsModel.PaginatedPackageList(
                            items: listResponse.items,
                            offset: offset,
                            limit: limit,
                            total: listResponse.total
                        )
                    default:
                        throw PackageIndexError.invalidResponse(listURL, "Invalid status code: \(response.statusCode)")
                    }
                })
            }
        }
        
        struct ListResponse: Codable {
            let items: [PackageCollectionsModel.Package]
            let total: Int
        }
    }

    private func runIfConfigured<T>(
        callback: @escaping (Result<T, Error>) -> Void,
        handler: @escaping (Foundation.URL, @escaping (Result<T, Error>) -> Void) -> Void
    ) {
        let callback = self.makeAsync(callback)
        
        guard self.configuration.enabled else {
            return callback(.failure(PackageIndexError.featureDisabled))
        }
        guard let url = self.configuration.url else {
            return callback(.failure(PackageIndexError.notConfigured))
        }

        handler(url, callback)
    }

    private func makeAsync<T>(_ closure: @escaping (Result<T, Error>) -> Void) -> (Result<T, Error>) -> Void {
        { result in self.callbackQueue.async { closure(result) } }
    }
}

// MARK: - PackageMetadataProvider conformance

extension PackageIndex: PackageMetadataProvider {
    func get(
        identity: PackageIdentity,
        location: String,
        callback: @escaping (Result<PackageCollectionsModel.PackageBasicMetadata, Error>, PackageMetadataProviderContext?) -> Void
    ) {
        self.getPackageMetadata(identity: identity, location: location) { result in
            switch result {
            case .failure(let error):
                // Package index fails to produce result so it cannot be the provider
                callback(.failure(error), nil)
            case .success(let metadata):
                let package = metadata.package
                let basicMetadata = PackageCollectionsModel.PackageBasicMetadata(
                    summary: package.summary,
                    keywords: package.keywords,
                    versions: package.versions.map { version in
                        PackageCollectionsModel.PackageBasicVersionMetadata(
                            version: version.version,
                            title: version.title,
                            summary: version.summary,
                            createdAt: version.createdAt
                        )
                    },
                    watchersCount: package.watchersCount,
                    readmeURL: package.readmeURL,
                    license: package.license,
                    authors: package.authors,
                    languages: package.languages
                )
                callback(.success(basicMetadata), metadata.provider)
            }
        }
    }
}
