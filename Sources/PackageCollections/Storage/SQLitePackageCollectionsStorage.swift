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
import Dispatch
import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import class Foundation.NSLock
import struct Foundation.URL
import PackageModel

import protocol TSCBasic.Closable

final class SQLitePackageCollectionsStorage: PackageCollectionsStorage, Closable {
    private static let packageCollectionsTableName = "package_collections"
    private static let packagesFTSName = "fts_packages"
    private static let targetsFTSNameV0 = "fts_targets" // TODO: remove as this has been replaced by v1
    private static let targetsFTSNameV1 = "fts_targets_1"

    let fileSystem: FileSystem
    let location: SQLite.Location
    let configuration: Configuration

    private let observabilityScope: ObservabilityScope

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var state = State.idle
    private let stateLock = NSLock()

    private let cache = ThreadSafeKeyValueStore<Model.CollectionIdentifier, Model.Collection>()

    // NSLock helps prevent concurrency errors with transaction statements during e.g. `refreshCollections`,
    // since only one transaction is allowed per SQLite connection. We need transactions to speed up bulk updates.
    // TODO: we could potentially optimize this with db connection pool
    private let ftsLock = NSLock()
    // FTS not supported on some platforms; the code falls back to "slow path" in that case
    // marked internal for testing
    internal let useSearchIndices = ThreadSafeBox<Bool>()

    // Targets have in-memory trie in addition to SQLite FTS as optimization
    private let targetTrie = Trie<CollectionPackage>()
    private var targetTrieReady: Bool?
    private let populateTargetTrieLock = NSLock()

    init(location: SQLite.Location? = nil, configuration: Configuration = .init(), observabilityScope: ObservabilityScope) {
        self.location = location ?? (try? .path(localFileSystem.swiftPMCacheDirectory.appending(components: "package-collection.db"))) ?? .memory
        switch self.location {
        case .path, .temporary:
            self.fileSystem = localFileSystem
        case .memory:
            self.fileSystem = InMemoryFileSystem()
        }
        self.configuration = configuration
        self.observabilityScope = observabilityScope
        self.encoder = JSONEncoder.makeWithDefaults()
        self.decoder = JSONDecoder.makeWithDefaults()

        if configuration.initializeTargetTrie {
            self.populateTargetTrie()
        }
    }

    convenience init(path: AbsolutePath, observabilityScope: ObservabilityScope) {
        self.init(location: .path(path), observabilityScope: observabilityScope)
    }

    deinit {
        guard case .disconnected = (try? self.withStateLock { self.state }) else {
            return self.observabilityScope.emit(warning: "SQLitePackageCollectionsStorage de-initialized but db is not closed")
        }
    }

    func close() throws {
        func retryClose(db: SQLite, exponentialBackoff: inout ExponentialBackoff) throws {
            let semaphore = DispatchSemaphore(value: 0)
            let callback = { (result: Result<Void, Error>) in
                // If it has failed, the semaphore will timeout in which case we will retry
                if case .success = result {
                    semaphore.signal()
                }
            }

            // This throws error if we have exhausted our attempts
            let delay = try exponentialBackoff.nextDelay()
            DispatchQueue.sharedConcurrent.asyncAfter(deadline: .now() + delay) {
                do {
                    try db.close()
                    callback(.success(()))
                } catch {
                    callback(.failure(error))
                }
            }
            // Add some buffer to allow `asyncAfter` to run
            guard case .success = semaphore.wait(timeout: .now() + delay + .milliseconds(50)) else {
                return try retryClose(db: db, exponentialBackoff: &exponentialBackoff)
            }
        }

        // Signal long-running operation (e.g., populateTargetTrie) to stop
        if case .connected(let db) = try self.withStateLock({ self.state }) {
            try self.withStateLock {
                self.state = .disconnecting(db)
            }

            do {
                try db.close()
            } catch {
                do {
                    var exponentialBackoff = ExponentialBackoff()
                    try retryClose(db: db, exponentialBackoff: &exponentialBackoff)
                } catch {
                    throw StringError("Failed to close database")
                }
            }
        }

        try self.withStateLock {
            self.state = .disconnected
        }
    }

    func put(collection: Model.Collection,
             callback: @escaping (Result<Model.Collection, Error>) -> Void) {
        DispatchQueue.sharedConcurrent.async {
            self.get(identifier: collection.identifier) { getResult in
                do {
                    // write to db
                    let query = "INSERT OR REPLACE INTO \(Self.packageCollectionsTableName) VALUES (?, ?);"
                    try self.executeStatement(query) { statement -> Void in
                        let data = try self.encoder.encode(collection)

                        let bindings: [SQLite.SQLiteValue] = [
                            .string(collection.identifier.databaseKey()),
                            .blob(data),
                        ]
                        try statement.bind(bindings)
                        try statement.step()
                    }

                    // Add to search indices
                    // Optimization: do this only if the collection has not been indexed before or its packages have changed
                    switch getResult {
                    case .failure: // e.g., not found
                        try self.insertToSearchIndices(collection: collection)
                    case .success(let dbCollection) where dbCollection.packages != collection.packages:
                        try self.insertToSearchIndices(collection: collection)
                    default: // dbCollection.packages == collection.packages
                        break
                    }

                    // write to cache
                    self.cache[collection.identifier] = collection
                    callback(.success(collection))
                } catch {
                    callback(.failure(error))
                }
            }
        }
    }

    func remove(identifier: Model.CollectionIdentifier,
                callback: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.sharedConcurrent.async {
            do {
                // write to db
                let query = "DELETE FROM \(Self.packageCollectionsTableName) WHERE key = ?;"
                try self.executeStatement(query) { statement -> Void in
                    let bindings: [SQLite.SQLiteValue] = [
                        .string(identifier.databaseKey()),
                    ]
                    try statement.bind(bindings)
                    try statement.step()
                }

                // remove from search indices
                try self.removeFromSearchIndices(identifier: identifier)

                // write to cache
                self.cache[identifier] = nil
                callback(.success(()))
            } catch {
                callback(.failure(error))
            }
        }
    }

    func get(identifier: Model.CollectionIdentifier,
             callback: @escaping (Result<Model.Collection, Error>) -> Void) {
        // try read to cache
        if let collection = self.cache[identifier] {
            return callback(.success(collection))
        }

        // go to db if not found
        DispatchQueue.sharedConcurrent.async {
            do {
                let query = "SELECT value FROM \(Self.packageCollectionsTableName) WHERE key = ? LIMIT 1;"
                let collection = try self.executeStatement(query) { statement -> Model.Collection in
                    try statement.bind([.string(identifier.databaseKey())])

                    let row = try statement.step()
                    guard let data = row?.blob(at: 0) else {
                        throw NotFoundError("\(identifier)")
                    }

                    let collection = try self.decoder.decode(Model.Collection.self, from: data)
                    return collection
                }
                callback(.success(collection))
            } catch {
                callback(.failure(error))
            }
        }
    }

    func list(identifiers: [Model.CollectionIdentifier]? = nil,
              callback: @escaping (Result<[Model.Collection], Error>) -> Void) {
        // try read to cache
        let cached = identifiers?.compactMap { self.cache[$0] }
        if let cached, cached.count > 0, cached.count == identifiers?.count {
            return callback(.success(cached))
        }

        // go to db if not found
        DispatchQueue.sharedConcurrent.async {
            do {
                var blobs = [Data]()
                if let identifiers {
                    var index = 0
                    while index < identifiers.count {
                        let slice = identifiers[index ..< min(index + self.configuration.batchSize, identifiers.count)]
                        let query = "SELECT value FROM \(Self.packageCollectionsTableName) WHERE key in (\(slice.map { _ in "?" }.joined(separator: ",")));"
                        try self.executeStatement(query) { statement in
                            try statement.bind(slice.compactMap { .string($0.databaseKey()) })
                            while let row = try statement.step() {
                                blobs.append(row.blob(at: 0))
                            }
                        }
                        index += self.configuration.batchSize
                    }
                } else {
                    let query = "SELECT value FROM \(Self.packageCollectionsTableName);"
                    try self.executeStatement(query) { statement in
                        while let row = try statement.step() {
                            blobs.append(row.blob(at: 0))
                        }
                    }
                }

                // decoding is a performance bottleneck (10+s for 1000 collections)
                // workaround is to decode in parallel if list is large enough to justify it
                let sync = DispatchGroup()
                let collections: ThreadSafeArrayStore<Model.Collection>
                if blobs.count < self.configuration.batchSize {
                    collections = .init(blobs.compactMap { data -> Model.Collection? in
                        try? self.decoder.decode(Model.Collection.self, from: data)
                    })
                } else {
                    collections = .init()
                    blobs.forEach { data in
                        DispatchQueue.sharedConcurrent.async(group: sync) {
                            if let collection = try? self.decoder.decode(Model.Collection.self, from: data) {
                                collections.append(collection)
                            }
                        }
                    }
                }

                sync.notify(queue: .sharedConcurrent) {
                    if collections.count != blobs.count {
                        self.observabilityScope.emit(warning: "Some stored collections could not be deserialized. Please refresh the collections to resolve this issue.")
                    }
                    callback(.success(collections.get()))
                }

            } catch {
                callback(.failure(error))
            }
        }
    }

    func searchPackages(identifiers: [Model.CollectionIdentifier]? = nil,
                        query: String,
                        callback: @escaping (Result<Model.PackageSearchResult, Error>) -> Void) {
        let useSearchIndices: Bool
        do {
            useSearchIndices = try self.shouldUseSearchIndices()
        } catch {
            return callback(.failure(error))
        }

        if useSearchIndices {
            var matches = [(collection: Model.CollectionIdentifier, package: PackageIdentity)]()
            var matchingCollections = Set<Model.CollectionIdentifier>()

            do {
                // rdar://84218640
                //let packageQuery = "SELECT collection_id_blob_base64, repository_url FROM \(Self.packagesFTSName) WHERE \(Self.packagesFTSName) MATCH ?;"
                let packageQuery = "SELECT collection_id_blob_base64, id FROM \(Self.packagesFTSName) WHERE name LIKE ? OR summary LIKE ? OR keywords LIKE ? OR products LIKE ? OR targets LIKE ? OR repository_url LIKE ? OR id LIKE ?;"
                try self.executeStatement(packageQuery) { statement in
                    try statement.bind((1...7).map { _ in .string("%\(query)%") })

                    while let row = try statement.step() {
                        if let collectionData = Data(base64Encoded: row.string(at: 0)),
                            let collection = try? self.decoder.decode(Model.CollectionIdentifier.self, from: collectionData) {
                            matches.append((collection: collection, package: PackageIdentity.plain(row.string(at: 1))))
                            matchingCollections.insert(collection)
                        }
                    }
                }
            } catch {
                return callback(.failure(error))
            }

            // Optimization: return early if no matches
            guard !matches.isEmpty else {
                return callback(.success(Model.PackageSearchResult(items: [])))
            }

            // Optimization: fetch only those collections that contain matching packages
            self.list(identifiers: Array(identifiers.map { Set($0).intersection(matchingCollections) } ?? matchingCollections)) { result in
                switch result {
                case .failure(let error):
                    callback(.failure(error))
                case .success(let collections):
                    let collectionDict = collections.reduce(into: [Model.CollectionIdentifier: Model.Collection]()) { result, collection in
                        result[collection.identifier] = collection
                    }

                    // For each package, find the containing collections
                    let packageCollections = matches.filter { collectionDict.keys.contains($0.collection) }
                        .reduce(into: [PackageIdentity: (package: Model.Package, collections: Set<Model.CollectionIdentifier>)]()) { result, match in
                            var entry = result.removeValue(forKey: match.package)
                            if entry == nil {
                                guard let package = collectionDict[match.collection].flatMap({ collection in
                                    collection.packages.first(where: { $0.identity == match.package })
                                }) else {
                                    return
                                }
                                entry = (package, .init())
                            }

                            if var entry = entry {
                                entry.collections.insert(match.collection)
                                result[match.package] = entry
                            }
                        }

                    // FTS results are not sorted by relevance at all (FTS5 supports ORDER BY rank but FTS4 requires additional SQL function)
                    // Sort by package name for consistent ordering in results
                    let result = Model.PackageSearchResult(items: packageCollections.sorted { $0.value.package.displayName < $1.value.package.displayName }.map { entry in
                        .init(package: entry.value.package, collections: Array(entry.value.collections))
                    })
                    callback(.success(result))
                }
            }
        } else {
            self.list(identifiers: identifiers) { result in
                switch result {
                case .failure(let error):
                    callback(.failure(error))
                case .success(let collections):
                    let queryString = query.lowercased()
                    let collectionsPackages = collections.reduce([Model.CollectionIdentifier: [Model.Package]]()) { partial, collection in
                        var map = partial
                        map[collection.identifier] = collection.packages.filter { package in
                            if package.identity.description.lowercased().contains(queryString) { return true }
                            if package.location.lowercased().contains(queryString) { return true }
                            if let summary = package.summary, summary.lowercased().contains(queryString) { return true }
                            if let keywords = package.keywords, (keywords.map { $0.lowercased() }).contains(queryString) { return true }
                            return package.versions.contains(where: { version in
                                version.manifests.values.contains { manifest in
                                    if manifest.packageName.lowercased().contains(queryString) { return true }
                                    if manifest.products.contains(where: { $0.name.lowercased().contains(queryString) }) { return true }
                                    return manifest.targets.contains(where: { $0.name.lowercased().contains(queryString) })
                                }
                            })
                        }
                        return map
                    }

                    var packageCollections = [PackageIdentity: (package: Model.Package, collections: Set<Model.CollectionIdentifier>)]()
                    collectionsPackages.forEach { collectionIdentifier, packages in
                        packages.forEach { package in
                            // Avoid copy-on-write: remove entry from dictionary before mutating
                            var entry = packageCollections.removeValue(forKey: package.identity) ?? (package, .init())
                            entry.collections.insert(collectionIdentifier)
                            packageCollections[package.identity] = entry
                        }
                    }

                    // Sort by package name for consistent ordering in results
                    let result = Model.PackageSearchResult(items: packageCollections.sorted { $0.value.package.displayName < $1.value.package.displayName }.map { entry in
                        .init(package: entry.value.package, collections: Array(entry.value.collections))
                    })
                    callback(.success(result))
                }
            }
        }
    }

    func findPackage(identifier: PackageIdentity,
                     collectionIdentifiers: [Model.CollectionIdentifier]?,
                     callback: @escaping (Result<(packages: [PackageCollectionsModel.Package], collections: [PackageCollectionsModel.CollectionIdentifier]), Error>) -> Void) {
        let useSearchIndices: Bool
        do {
            useSearchIndices = try self.shouldUseSearchIndices()
        } catch {
            return callback(.failure(error))
        }

        if useSearchIndices {
            var matchingCollections = Set<Model.CollectionIdentifier>()

            do {
                let packageQuery = "SELECT collection_id_blob_base64, repository_url FROM \(Self.packagesFTSName) WHERE id = ?;"
                try self.executeStatement(packageQuery) { statement in
                    try statement.bind([.string(identifier.description)])

                    while let row = try statement.step() {
                        if let collectionData = Data(base64Encoded: row.string(at: 0)),
                            let collection = try? self.decoder.decode(Model.CollectionIdentifier.self, from: collectionData) {
                            matchingCollections.insert(collection)
                        }
                    }
                }
            } catch {
                return callback(.failure(error))
            }

            // Optimization: return early if no matches
            guard !matchingCollections.isEmpty else {
                return callback(.failure(NotFoundError("\(identifier)")))
            }

            // Optimization: fetch only those collections that contain matching packages
            self.list(identifiers: Array(collectionIdentifiers.map { Set($0).intersection(matchingCollections) } ?? matchingCollections)) { result in
                switch result {
                case .failure(let error):
                    return callback(.failure(error))
                case .success(let collections):
                    let collectionDict = collections.reduce(into: [Model.CollectionIdentifier: Model.Collection]()) { result, collection in
                        result[collection.identifier] = collection
                    }

                    let collections = matchingCollections.filter { collectionDict.keys.contains($0) }
                        .compactMap { collectionDict[$0] }
                        // Sort collections by processing date so the latest metadata is first
                        .sorted(by: { lhs, rhs in lhs.lastProcessedAt > rhs.lastProcessedAt })

                    // rdar://79069839 - Package identities are not unique to repository URLs so there can be more than one result.
                    // It's up to the caller to filter out the best-matched package(s). Results are sorted with the latest ones first.
                    let packages = collections.flatMap { collection in
                        collection.packages.filter { $0.identity == identifier }
                    }

                    guard !packages.isEmpty else {
                        return callback(.failure(NotFoundError("\(identifier)")))
                    }

                    callback(.success((packages: packages, collections: collections.map { $0.identifier })))
                }
            }
        } else {
            self.list(identifiers: collectionIdentifiers) { result in
                switch result {
                case .failure(let error):
                    return callback(.failure(error))
                case .success(let collections):
                    // sorting by collection processing date so the latest metadata is first
                    let collectionPackages = collections.sorted(by: { lhs, rhs in lhs.lastProcessedAt > rhs.lastProcessedAt }).compactMap { collection in
                        collection.packages
                            .first(where: { $0.identity == identifier })
                            .flatMap { (collection: collection.identifier, package: $0) }
                    }

                    // rdar://79069839 - Package identities are not unique to repository URLs so there can be more than one result.
                    // It's up to the caller to filter out the best-matched package(s). Results are sorted with the latest ones first.
                    let packages = collectionPackages.map { $0.package }

                    guard !packages.isEmpty else {
                        return callback(.failure(NotFoundError("\(identifier)")))
                    }

                    callback(.success((packages: packages, collections: collectionPackages.map { $0.collection })))
                }
            }
        }
    }
    func searchTargets(identifiers: [Model.CollectionIdentifier]? = nil,
                       query: String,
                       type: Model.TargetSearchType,
                       callback: @escaping (Result<Model.TargetSearchResult, Error>) -> Void) {
        let query = query.lowercased()

        // For each package, find the containing collections
        var packageCollections = [PackageIdentity: (package: Model.Package, collections: Set<Model.CollectionIdentifier>)]()
        // For each matching target, find the containing package version(s)
        var targetPackageVersions = [Model.Target: [PackageIdentity: Set<Model.TargetListResult.PackageVersion>]]()

        func buildResult() {
            // Sort by target name for consistent ordering in results
            let result = Model.TargetSearchResult(items: targetPackageVersions.sorted { $0.key.name < $1.key.name }.map { target, packageVersions in
                let targetPackages: [Model.TargetListItem.Package] = packageVersions.compactMap { identity, versions in
                    guard let packageEntry = packageCollections[identity] else {
                        return nil
                    }
                    return Model.TargetListItem.Package(
                        identity: packageEntry.package.identity,
                        location: packageEntry.package.location,
                        summary: packageEntry.package.summary,
                        versions: Array(versions).sorted(by: >),
                        collections: Array(packageEntry.collections)
                    )
                }
                return Model.TargetListItem(target: target, packages: targetPackages)
            })

            callback(.success(result))
        }

        let useSearchIndices: Bool
        do {
            useSearchIndices = try self.shouldUseSearchIndices()
        } catch {
            return callback(.failure(error))
        }

        if useSearchIndices {
            var matches = [(collection: Model.CollectionIdentifier, package: PackageIdentity, packageLocation: String, targetName: String)]()
            var matchingCollections = Set<Model.CollectionIdentifier>()

            // Trie is more performant for target search; use it if available
            if self.populateTargetTrieLock.withLock({ self.targetTrieReady }) ?? false {
                do {
                    switch type {
                    case .exactMatch:
                        try self.targetTrie.find(word: query).forEach {
                            matches.append((collection: $0.collection, package: $0.package, packageLocation: $0.packageLocation, targetName: query))
                            matchingCollections.insert($0.collection)
                        }
                    case .prefix:
                        try self.targetTrie.findWithPrefix(query).forEach { targetName, collectionPackages in
                            collectionPackages.forEach {
                                matches.append((collection: $0.collection, package: $0.package, packageLocation: $0.packageLocation, targetName: targetName))
                                matchingCollections.insert($0.collection)
                            }
                        }
                    }
                } catch is NotFoundError {
                    // Do nothing if no matches found
                } catch {
                    return callback(.failure(error))
                }
            } else {
                do {
                    let targetV1Query = "SELECT collection_id_blob_base64, package_id, package_repository_url, name FROM \(Self.targetsFTSNameV1) WHERE name LIKE ?;"
                    try self.executeStatement(targetV1Query) { statement in
                        switch type {
                        case .exactMatch:
                            try statement.bind([.string("\(query)")])
                        case .prefix:
                            try statement.bind([.string("\(query)%")])
                        }

                        while let row = try statement.step() {
                            if let collectionData = Data(base64Encoded: row.string(at: 0)),
                                let collection = try? self.decoder.decode(Model.CollectionIdentifier.self, from: collectionData) {
                                matches.append((
                                    collection: collection,
                                    package: PackageIdentity.plain(row.string(at: 1)),
                                    packageLocation: row.string(at: 2),
                                    targetName: row.string(at: 3)
                                ))
                                matchingCollections.insert(collection)
                            }
                        }
                    }
                    
                    let targetV0Query = "SELECT collection_id_blob_base64, package_repository_url, name FROM \(Self.targetsFTSNameV0) WHERE name LIKE ?;"
                    try self.executeStatement(targetV0Query) { statement in
                        switch type {
                        case .exactMatch:
                            try statement.bind([.string("\(query)")])
                        case .prefix:
                            try statement.bind([.string("\(query)%")])
                        }

                        while let row = try statement.step() {
                            if let collectionData = Data(base64Encoded: row.string(at: 0)),
                                let collection = try? self.decoder.decode(Model.CollectionIdentifier.self, from: collectionData) {
                                matches.append((
                                    collection: collection,
                                    package: PackageIdentity(urlString: row.string(at: 1)),
                                    packageLocation: row.string(at: 1),
                                    targetName: row.string(at: 2)
                                ))
                                matchingCollections.insert(collection)
                            }
                        }
                    }
                } catch {
                    return callback(.failure(error))
                }
            }

            // Optimization: return early if no matches
            guard !matches.isEmpty else {
                return callback(.success(Model.TargetSearchResult(items: [])))
            }

            // Optimization: fetch only those collections that contain matching packages
            self.list(identifiers: Array(identifiers.map { Set($0).intersection(matchingCollections) } ?? matchingCollections)) { result in
                switch result {
                case .failure(let error):
                    return callback(.failure(error))
                case .success(let collections):
                    let collectionDict = collections.reduce(into: [Model.CollectionIdentifier: Model.Collection]()) { result, collection in
                        result[collection.identifier] = collection
                    }

                    matches.filter { collectionDict.keys.contains($0.collection) }.forEach { match in
                        var packageEntry = packageCollections.removeValue(forKey: match.package)
                        if packageEntry == nil {
                            guard let package = collectionDict[match.collection].flatMap({ collection in
                                collection.packages.first(where: { $0.identity == match.package || $0.location == match.packageLocation })
                            }) else {
                                return
                            }
                            packageEntry = (package, .init())
                        }

                        if var packageEntry = packageEntry {
                            packageEntry.collections.insert(match.collection)
                            packageCollections[match.package] = packageEntry

                            packageEntry.package.versions.forEach { version in
                                version.manifests.values.forEach { manifest in
                                    let targets = manifest.targets.filter { $0.name.lowercased() == match.targetName.lowercased() }
                                    targets.forEach { target in
                                        var targetEntry = targetPackageVersions.removeValue(forKey: target) ?? [:]
                                        var targetPackageEntry = targetEntry.removeValue(forKey: packageEntry.package.identity) ?? .init()
                                        targetPackageEntry.insert(.init(version: version.version, toolsVersion: manifest.toolsVersion, packageName: manifest.packageName))
                                        targetEntry[packageEntry.package.identity] = targetPackageEntry
                                        targetPackageVersions[target] = targetEntry
                                    }
                                }
                            }
                        }
                    }

                    buildResult()
                }
            }
        } else {
            self.list(identifiers: identifiers) { result in
                switch result {
                case .failure(let error):
                    callback(.failure(error))
                case .success(let collections):
                    let collectionsPackages = collections.reduce([Model.CollectionIdentifier: [(target: Model.Target, package: Model.Package)]]()) { partial, collection in
                        var map = partial
                        collection.packages.forEach { package in
                            package.versions.forEach { version in
                                version.manifests.values.forEach { manifest in
                                    manifest.targets.forEach { target in
                                        let match: Bool
                                        switch type {
                                        case .exactMatch:
                                            match = target.name.lowercased() == query
                                        case .prefix:
                                            match = target.name.lowercased().hasPrefix(query)
                                        }
                                        if match {
                                            // Avoid copy-on-write: remove entry from dictionary before mutating
                                            var entry = map.removeValue(forKey: collection.identifier) ?? .init()
                                            entry.append((target, package))
                                            map[collection.identifier] = entry
                                        }
                                    }
                                }
                            }
                        }
                        return map
                    }

                    collectionsPackages.forEach { collectionIdentifier, packagesAndTargets in
                        packagesAndTargets.forEach { item in
                            // Avoid copy-on-write: remove entry from dictionary before mutating
                            var packageCollectionsEntry = packageCollections.removeValue(forKey: item.package.identity) ?? (item.package, .init())
                            packageCollectionsEntry.collections.insert(collectionIdentifier)
                            packageCollections[item.package.identity] = packageCollectionsEntry

                            packageCollectionsEntry.package.versions.forEach { version in
                                version.manifests.values.forEach { manifest in
                                    let targets = manifest.targets.filter { $0.name.lowercased() == item.target.name.lowercased() }
                                    targets.forEach { target in
                                        var targetEntry = targetPackageVersions.removeValue(forKey: item.target) ?? [:]
                                        var targetPackageEntry = targetEntry.removeValue(forKey: item.package.identity) ?? .init()
                                        targetPackageEntry.insert(.init(version: version.version, toolsVersion: manifest.toolsVersion, packageName: manifest.packageName))
                                        targetEntry[item.package.identity] = targetPackageEntry
                                        targetPackageVersions[target] = targetEntry
                                    }
                                }
                            }
                        }
                    }

                    buildResult()
                }
            }
        }
    }

    private func insertToSearchIndices(collection: Model.Collection) throws {
        guard try self.shouldUseSearchIndices() else { return }

        try self.ftsLock.withLock {
            // First delete existing data
            try self.removeFromSearchIndices(identifier: collection.identifier)
            // Update search indices
            try self.withDB { db in
                let packagesStatement = try db.prepare(query: "INSERT INTO \(Self.packagesFTSName) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);")
                let targetsStatement = try db.prepare(query: "INSERT INTO \(Self.targetsFTSNameV1) VALUES (?, ?, ?, ?);")
                
                try db.exec(query: "BEGIN TRANSACTION;")
                do {
                    // Then insert new data
                    try collection.packages.forEach { package in
                        var targets = Set<String>()

                        try package.versions.forEach { version in
                            try version.manifests.values.forEach { manifest in
                                // Packages FTS
                                let packagesBindings: [SQLite.SQLiteValue] = [
                                    .string(try self.encoder.encode(collection.identifier).base64EncodedString()),
                                    .string(package.identity.description),
                                    .string(version.version.description),
                                    .string(manifest.packageName),
                                    .string(package.location),
                                    package.summary.map { .string($0) } ?? .null,
                                    package.keywords.map { .string($0.joined(separator: ",")) } ?? .null,
                                    .string(manifest.products.map { $0.name }.joined(separator: ",")),
                                    .string(manifest.targets.map { $0.name }.joined(separator: ",")),
                                ]
                                try packagesStatement.bind(packagesBindings)
                                try packagesStatement.step()

                                try packagesStatement.clearBindings()
                                try packagesStatement.reset()

                                manifest.targets.forEach { targets.insert($0.name) }
                            }
                        }

                        let collectionPackage = CollectionPackage(
                            collection: collection.identifier,
                            package: package.identity,
                            packageLocation: package.location
                        )
                        try targets.forEach { target in
                            // Targets in-memory trie
                            self.targetTrie.insert(word: target.lowercased(), foundIn: collectionPackage)

                            // Targets FTS
                            let targetsBindings: [SQLite.SQLiteValue] = [
                                .string(try self.encoder.encode(collection.identifier).base64EncodedString()),
                                .string(package.identity.description),
                                .string(package.location),
                                .string(target),
                            ]
                            try targetsStatement.bind(targetsBindings)
                            try targetsStatement.step()

                            try targetsStatement.clearBindings()
                            try targetsStatement.reset()
                        }
                    }
                    
                    try db.exec(query: "COMMIT;")
                } catch {
                    try db.exec(query: "ROLLBACK;")
                    throw error
                }

                try packagesStatement.finalize()
                try targetsStatement.finalize()
            }
        }
    }

    private func removeFromSearchIndices(identifier: Model.CollectionIdentifier) throws {
        guard try self.shouldUseSearchIndices() else { return }

        let identifierBase64 = try self.encoder.encode(identifier).base64EncodedString()

        let packagesQuery = "DELETE FROM \(Self.packagesFTSName) WHERE collection_id_blob_base64 = ?;"
        try self.executeStatement(packagesQuery) { statement -> Void in
            let bindings: [SQLite.SQLiteValue] = [.string(identifierBase64)]
            try statement.bind(bindings)
            try statement.step()
        }

        let targetsV0Query = "DELETE FROM \(Self.targetsFTSNameV0) WHERE collection_id_blob_base64 = ?;"
        try self.executeStatement(targetsV0Query) { statement -> Void in
            let bindings: [SQLite.SQLiteValue] = [.string(identifierBase64)]
            try statement.bind(bindings)
            try statement.step()
        }

        let targetsV1Query = "DELETE FROM \(Self.targetsFTSNameV1) WHERE collection_id_blob_base64 = ?;"
        try self.executeStatement(targetsV1Query) { statement -> Void in
            let bindings: [SQLite.SQLiteValue] = [.string(identifierBase64)]
            try statement.bind(bindings)
            try statement.step()
        }

        self.targetTrie.remove { $0.collection == identifier }
    }

    private func shouldUseSearchIndices() throws -> Bool {
        // Make sure createSchemaIfNecessary is called and useSearchIndices is set before reading it
        try self.withDB { _ in
            self.useSearchIndices.get() ?? false
        }
    }
    internal func populateTargetTrie() async throws {
        try await safe_async { self.populateTargetTrie(callback: $0) }
    }

    internal func populateTargetTrie(callback: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        // Check to see if there is any data before submitting task to queue because otherwise it's no-op anyway
        do {
            let numberOfCollections: Int = try self.executeStatement("SELECT COUNT(*) FROM \(Self.packageCollectionsTableName);") { statement in
                let row = try statement.step()
                guard let count = row?.int(at: 0) else {
                    throw StringError("Failed to get count of \(Self.packageCollectionsTableName) table")
                }
                return count
            }
            // No collections means no data, so no need to populate target trie
            guard numberOfCollections > 0 else {
                self.populateTargetTrieLock.withLock {
                    self.targetTrieReady = true
                }
                return callback(.success(()))
            }
        } catch {
            self.observabilityScope.emit(
                warning: "Failed to determine if database is empty or not",
                underlyingError: error
            )
            // Try again in background
        }

        DispatchQueue.sharedConcurrent.async(group: nil, qos: .background, flags: .assignCurrentContext) {
            do {
                try self.populateTargetTrieLock.withLock { // Prevent race to populate targetTrie
                    // Exit early if we've already done the computation before
                    guard self.targetTrieReady == nil else {
                        return
                    }

                    // since running on low priority thread make sure the database has not already gone away
                    switch (try self.withStateLock { self.state }) {
                    case .disconnected, .disconnecting:
                        self.targetTrieReady = false
                        return
                    default:
                        break
                    }

                    // Use collectionsProcessed to make sure we don't end up with duplicates
                    // in the trie. If a collection is in targetsFTSNameV1, then the data
                    // in targetsFTSNameV0 (if any) must be stale.
                    var collectionsProcessed = Set<Model.CollectionIdentifier>()

                    // Use FTS to build the trie
                    let queryV1 = "SELECT collection_id_blob_base64, package_id, package_repository_url, name FROM \(Self.targetsFTSNameV1);"
                    try self.executeStatement(queryV1) { statement in
                        while let row = try statement.step() {
                            #if os(Linux)
                            // lock not required since executeStatement locks
                            guard case .connected = self.state else {
                                return
                            }
                            #else
                            guard case .connected = (try self.withStateLock { self.state }) else {
                                return
                            }
                            #endif

                            let targetName = row.string(at: 3)

                            if let collectionData = Data(base64Encoded: row.string(at: 0)),
                               let collection = try? self.decoder.decode(Model.CollectionIdentifier.self, from: collectionData) {
                                let collectionPackage = CollectionPackage(
                                    collection: collection,
                                    package: PackageIdentity.plain(row.string(at: 1)),
                                    packageLocation: row.string(at: 2)
                                )
                                self.targetTrie.insert(word: targetName.lowercased(), foundIn: collectionPackage)
                                collectionsProcessed.insert(collection)
                            }
                        }
                    }

                    let queryV0 = "SELECT collection_id_blob_base64, package_repository_url, name FROM \(Self.targetsFTSNameV0);"
                    try self.executeStatement(queryV0) { statement in
                        while let row = try statement.step() {
                            #if os(Linux)
                            // lock not required since executeStatement locks
                            guard case .connected = self.state else {
                                return
                            }
                            #else
                            guard case .connected = (try self.withStateLock { self.state }) else {
                                return
                            }
                            #endif

                            let targetName = row.string(at: 2)

                            if let collectionData = Data(base64Encoded: row.string(at: 0)),
                               let collection = try? self.decoder.decode(Model.CollectionIdentifier.self, from: collectionData),
                               !collectionsProcessed.contains(collection) {
                                let collectionPackage = CollectionPackage(
                                    collection: collection,
                                    package: PackageIdentity(urlString: row.string(at: 1)),
                                    packageLocation: row.string(at: 1)
                                )
                                self.targetTrie.insert(word: targetName.lowercased(), foundIn: collectionPackage)
                            }
                        }
                    }
                    self.targetTrieReady = true
                }
                callback(.success(()))
            } catch {
                callback(.failure(error))
            }
        }
    }

    // for testing
    internal func resetCache() {
        self.cache.clear()
    }

    // MARK: -  Private

    private func executeStatement<T>(_ query: String, _ body: (SQLite.PreparedStatement) throws -> T) throws -> T {
        try self.withDB { db in
            let result: Result<T, Error>
            let statement = try db.prepare(query: query)
            do {
                result = .success(try body(statement))
            } catch {
                result = .failure(error)
            }
            try statement.finalize()
            switch result {
            case .failure(let error):
                throw error
            case .success(let value):
                return value
            }
        }
    }

    private func withDB<T>(_ body: (SQLite) throws -> T) throws -> T {
        let createDB = { () throws -> SQLite in
            let db = try SQLite(location: self.location, configuration: self.configuration.underlying)
            try self.createSchemaIfNecessary(db: db)
            return db
        }

        let db = try self.withStateLock { () -> SQLite in
            let db: SQLite
            switch (self.location, self.state) {
            case (_, .disconnecting), (_, .disconnected):
                throw StringError("DB is disconnecting or disconnected")
            case (.path(let path), .connected(let database)):
                if self.fileSystem.exists(path) {
                    db = database
                } else {
                    try database.close()
                    try self.fileSystem.createDirectory(path.parentDirectory, recursive: true)
                    db = try createDB()
                }
            case (.path(let path), _):
                if !self.fileSystem.exists(path) {
                    try self.fileSystem.createDirectory(path.parentDirectory, recursive: true)
                }
                db = try createDB()
            case (_, .connected(let database)):
                db = database
            case (_, _):
                db = try createDB()
            }
            self.state = .connected(db)
            return db
        }

        // FIXME: workaround linux sqlite concurrency issues causing CI failures
        #if os(Linux)
        return try self.withStateLock {
            try body(db)
        }
        #else
        return try body(db)
        #endif
    }

    private func createSchemaIfNecessary(db: SQLite) throws {
        let table = """
            CREATE TABLE IF NOT EXISTS \(Self.packageCollectionsTableName) (
                key STRING PRIMARY KEY NOT NULL,
                value BLOB NOT NULL
            );
        """
        try db.exec(query: table)

        #if os(Android)
        // FTS queries for strings containing hyphens isn't working in SQLite on
        // Android, so disable for now.
        self.useSearchIndices.put(false)
        #else
        do {
            let ftsPackages = """
                CREATE VIRTUAL TABLE IF NOT EXISTS \(Self.packagesFTSName) USING fts4(
                    collection_id_blob_base64, id, version, name, repository_url, summary, keywords, products, targets,
                    notindexed=collection_id_blob_base64,
                    tokenize=unicode61
                );
            """
            try db.exec(query: ftsPackages)

            // We don't insert to this anymore but keeping it for queries to work
            let ftsTargetsV0 = """
                CREATE VIRTUAL TABLE IF NOT EXISTS \(Self.targetsFTSNameV0) USING fts4(
                    collection_id_blob_base64, package_repository_url, name,
                    notindexed=collection_id_blob_base64,
                    tokenize=unicode61
                );
            """
            try db.exec(query: ftsTargetsV0)
            
            let ftsTargetsV1 = """
                CREATE VIRTUAL TABLE IF NOT EXISTS \(Self.targetsFTSNameV1) USING fts4(
                    collection_id_blob_base64, package_id, package_repository_url, name,
                    notindexed=collection_id_blob_base64,
                    tokenize=unicode61
                );
            """
            try db.exec(query: ftsTargetsV1)

            self.useSearchIndices.put(true)
        } catch {
            // We can use FTS3 tables but queries yield different results when run on different
            // platforms. This could be because of SQLite version perhaps? But since we can't get
            // consistent results we will not fallback to FTS3 and just give up if FTS4 is not available.
            self.useSearchIndices.put(false)
        }
        #endif

        try db.exec(query: "PRAGMA journal_mode=WAL;")
    }

    private func withStateLock<T>(_ body: () throws -> T) throws -> T {
        try self.stateLock.withLock(body)
        /* switch self.location {
         case .path(let path):
             if !self.fileSystem.exists(path.parentDirectory) {
                 try self.fileSystem.createDirectory(path.parentDirectory)
             }
             return try self.fileSystem.withLock(on: path, type: .exclusive, body)
         case .memory, .temporary:
             return try self.stateLock.withLock(body)
         } */
    }

    private enum State {
        case idle
        case connected(SQLite)
        case disconnecting(SQLite)
        case disconnected
        case error
    }

    // For `Trie`
    private struct CollectionPackage: Hashable, CustomStringConvertible {
        let collection: Model.CollectionIdentifier
        let package: PackageIdentity
        let packageLocation: String

        var description: String {
            "\(collection): \(package)"
        }
    }

    // For shutdown
    private struct ExponentialBackoff {
        let intervalInMilliseconds: Int
        let randomizationFactor: Int
        let maximumAttempts: Int

        var attempts: Int = 0
        var multiplier: Int = 1

        var canRetry: Bool {
            self.attempts < self.maximumAttempts
        }

        init(intervalInMilliseconds: Int = 100, randomizationFactor: Int = 100, maximumAttempts: Int = 3) {
            self.intervalInMilliseconds = intervalInMilliseconds
            self.randomizationFactor = randomizationFactor
            self.maximumAttempts = maximumAttempts
        }

        mutating func nextDelay() throws -> DispatchTimeInterval {
            guard self.canRetry else {
                throw StringError("Maximum attempts reached")
            }
            let delay = self.multiplier * intervalInMilliseconds
            let jitter = Int.random(in: 0 ... self.randomizationFactor)
            self.attempts += 1
            self.multiplier *= 2
            return .milliseconds(delay + jitter)
        }
    }

    struct Configuration {
        var batchSize: Int
        var initializeTargetTrie: Bool

        fileprivate var underlying: SQLite.Configuration

        init(initializeTargetTrie: Bool = true) {
            self.batchSize = 100
            self.initializeTargetTrie = initializeTargetTrie

            self.underlying = .init()
            self.maxSizeInMegabytes = 100
            // see https://www.sqlite.org/c3ref/busy_timeout.html
            self.busyTimeoutMilliseconds = 1000
        }

        var maxSizeInMegabytes: Int? {
            get {
                self.underlying.maxSizeInMegabytes
            }
            set {
                self.underlying.maxSizeInMegabytes = newValue
            }
        }

        var busyTimeoutMilliseconds: Int32 {
            get {
                self.underlying.busyTimeoutMilliseconds
            }
            set {
                self.underlying.busyTimeoutMilliseconds = newValue
            }
        }
    }
}

// MARK: - Utility

private extension Model.Collection.Identifier {
    func databaseKey() -> String {
        switch self {
        case .json(let url):
            return url.absoluteString
        }
    }
}
