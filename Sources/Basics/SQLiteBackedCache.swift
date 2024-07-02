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

import Foundation

import protocol TSCBasic.Closable
import var TSCBasic.localFileSystem

/// SQLite backed persistent cache.
package final class SQLiteBackedCache<Value: Codable>: Closable {
    package typealias Key = String

    package let tableName: String
    package let fileSystem: FileSystem
    package let location: SQLite.Location
    package let configuration: SQLiteBackedCacheConfiguration

    private var state = State.idle
    private let stateLock = NSLock()

    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    /// Creates a SQLite-backed cache.
    ///
    /// - Parameters:
    ///   - tableName: The SQLite table name. Must follow SQLite naming rules (e.g., no spaces).
    ///   - location: SQLite.Location
    ///   - configuration: Optional. Configuration for the cache.
    package init(tableName: String, location: SQLite.Location, configuration: SQLiteBackedCacheConfiguration = .init()) {
        self.tableName = tableName
        self.location = location
        switch self.location {
        case .path, .temporary:
            self.fileSystem = localFileSystem
        case .memory:
            self.fileSystem = InMemoryFileSystem()
        }
        self.configuration = configuration
        self.jsonEncoder = JSONEncoder.makeWithDefaults()
        self.jsonDecoder = JSONDecoder.makeWithDefaults()
    }

    /// Creates a SQLite-backed cache.
    ///
    /// - Parameters:
    ///   - tableName: The SQLite table name. Must follow SQLite naming rules (e.g., no spaces).
    ///   - path: The path of the SQLite database.
    ///   - configuration: Optional. Configuration for the cache.
    package convenience init(
        tableName: String,
        path: AbsolutePath,
        configuration: SQLiteBackedCacheConfiguration = .init()
    ) {
        self.init(tableName: tableName, location: .path(path), configuration: configuration)
    }

    deinit {
        try? self.withStateLock {
            if case .connected(let db) = self.state {
                // TODO: we could wrap the failure here with diagnostics if it was available
                assertionFailure("db should be closed")
                try db.close()
            }
        }
    }

    package func close() throws {
        try self.withStateLock {
            if case .connected(let db) = self.state {
                try db.close()
            }
            self.state = .disconnected
        }
    }

    private func put(
        rawKey key: SQLite.SQLiteValue,
        value: Value,
        replace: Bool = false,
        observabilityScope: ObservabilityScope? = nil
    ) throws {
        do {
            let query = "INSERT OR \(replace ? "REPLACE" : "IGNORE") INTO \(self.tableName) VALUES (?, ?);"
            try self.executeStatement(query) { statement in
                let data = try self.jsonEncoder.encode(value)
                let bindings: [SQLite.SQLiteValue] = [
                    key,
                    .blob(data),
                ]
                try statement.bind(bindings)
                try statement.step()
            }
        } catch (let error as SQLite.Errors) where error == .databaseFull {
            if !self.configuration.truncateWhenFull {
                throw error
            }
            observabilityScope?
                .emit(
                    warning: """
                    truncating \(self.tableName) cache database since it reached max size of \(
                        self.configuration.maxSizeInBytes ?? 0
                    ) bytes
                    """
                )
            try self.executeStatement("DELETE FROM \(self.tableName);") { statement in
                try statement.step()
            }
            try self.put(rawKey: key, value: value, replace: replace, observabilityScope: observabilityScope)
        } catch {
            throw error
        }
    }

    package func put(
        blobKey key: some Sequence<UInt8>,
        value: Value,
        replace: Bool = false,
        observabilityScope: ObservabilityScope? = nil
    ) throws {
        try self.put(rawKey: .blob(Data(key)), value: value, observabilityScope: observabilityScope)
    }

    package func put(
        key: Key,
        value: Value,
        replace: Bool = false,
        observabilityScope: ObservabilityScope? = nil
    ) throws {
        try self.put(rawKey: .string(key), value: value, replace: replace, observabilityScope: observabilityScope)
    }

    package func get(key: Key) throws -> Value? {
        let query = "SELECT value FROM \(self.tableName) WHERE key = ? LIMIT 1;"
        return try self.executeStatement(query) { statement -> Value? in
            try statement.bind([.string(key)])
            let data = try statement.step()?.blob(at: 0)
            return try data.flatMap {
                try self.jsonDecoder.decode(Value.self, from: $0)
            }
        }
    }

    package func get(blobKey key: some Sequence<UInt8>) throws -> Value? {
        let query = "SELECT value FROM \(self.tableName) WHERE key = ? LIMIT 1;"
        return try self.executeStatement(query) { statement -> Value? in
            try statement.bind([.blob(Data(key))])
            let data = try statement.step()?.blob(at: 0)
            return try data.flatMap {
                try self.jsonDecoder.decode(Value.self, from: $0)
            }
        }
    }

    package func remove(key: Key) throws {
        let query = "DELETE FROM \(self.tableName) WHERE key = ?;"
        try self.executeStatement(query) { statement in
            try statement.bind([.string(key)])
            try statement.step()
        }
    }

    @discardableResult
    private func executeStatement<T>(_ query: String, _ body: (SQLite.PreparedStatement) throws -> T) throws -> T {
        try self.withDB { db in
            let result: Result<T, Error>
            let statement = try db.prepare(query: query)
            do {
                result = try .success(body(statement))
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

        return try self.withStateLock { () -> T in
            let db: SQLite
            switch (self.location, self.state) {
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
            return try body(db)
        }
    }

    private func createSchemaIfNecessary(db: SQLite) throws {
        let table = """
            CREATE TABLE IF NOT EXISTS \(self.tableName) (
                key STRING PRIMARY KEY NOT NULL,
                value BLOB NOT NULL
            );
        """

        try db.exec(query: table)
        try db.exec(query: "PRAGMA journal_mode=WAL;")
    }

    private func withStateLock<T>(_ body: () throws -> T) throws -> T {
        switch self.location {
        case .path(let path):
            if !self.fileSystem.exists(path.parentDirectory) {
                try self.fileSystem.createDirectory(path.parentDirectory)
            }
            return try self.fileSystem.withLock(on: path, type: .exclusive, body)
        case .memory, .temporary:
            return try self.stateLock.withLock(body)
        }
    }

    private enum State {
        case idle
        case connected(SQLite)
        case disconnected
    }
}

package struct SQLiteBackedCacheConfiguration {
    package var truncateWhenFull: Bool

    fileprivate var underlying: SQLite.Configuration

    package init() {
        self.underlying = .init()
        self.truncateWhenFull = true
        self.maxSizeInMegabytes = 100
        // see https://www.sqlite.org/c3ref/busy_timeout.html
        self.busyTimeoutMilliseconds = 1000
    }

    package var maxSizeInMegabytes: Int? {
        get {
            self.underlying.maxSizeInMegabytes
        }
        set {
            self.underlying.maxSizeInMegabytes = newValue
        }
    }

    package var maxSizeInBytes: Int? {
        get {
            self.underlying.maxSizeInBytes
        }
        set {
            self.underlying.maxSizeInBytes = newValue
        }
    }

    package var busyTimeoutMilliseconds: Int32 {
        get {
            self.underlying.busyTimeoutMilliseconds
        }
        set {
            self.underlying.busyTimeoutMilliseconds = newValue
        }
    }
}
