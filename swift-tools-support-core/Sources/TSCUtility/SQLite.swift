/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Foundation
import TSCBasic

@_implementationOnly import CSQLite3

/// A minimal SQLite wrapper.
public struct SQLite {
    /// The location of the database.
    public let location: Location

    /// The configuration for the database.
    public let configuration: Configuration

    /// Pointer to the database.
    let db: OpaquePointer

    /// Create or open the database at the given path.
    ///
    /// The database is opened in serialized mode.
    public init(location: Location, configuration: Configuration = Configuration()) throws {
        self.location = location
        self.configuration = configuration

        var handle: OpaquePointer?
        try Self.checkError("Unable to open database at \(self.location)") {
            sqlite3_open_v2(
                location.pathString,
                &handle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
        }

        guard let db = handle else {
            throw StringError("Unable to open database at \(self.location)")
        }
        self.db = db
        try Self.checkError("Unable to configure database") { sqlite3_extended_result_codes(db, 1) }
        try Self.checkError("Unable to configure database") { sqlite3_busy_timeout(db, self.configuration.busyTimeoutSeconds) }
    }

    @available(*, deprecated, message: "use init(location:configuration) instead")
    public init(dbPath: AbsolutePath) throws {
        try self.init(location: .path(dbPath))
    }

    /// Prepare the given query.
    public func prepare(query: String) throws -> PreparedStatement {
        try PreparedStatement(db: self.db, query: query)
    }

    /// Directly execute the given query.
    ///
    /// Note: Use withCString for string arguments.
    public func exec(query queryString: String, args: [CVarArg] = [], _ callback: SQLiteExecCallback? = nil) throws {
        let query = withVaList(args) { ptr in
            sqlite3_vmprintf(queryString, ptr)
        }

        let wcb = callback.map { CallbackWrapper($0) }
        let callbackCtx = wcb.map { Unmanaged.passUnretained($0).toOpaque() }

        var err: UnsafeMutablePointer<Int8>?
        try Self.checkError { sqlite3_exec(db, query, sqlite_callback, callbackCtx, &err) }

        sqlite3_free(query)

        if let err = err {
            let errorString = String(cString: err)
            sqlite3_free(err)
            throw StringError(errorString)
        }
    }

    public func close() throws {
        try Self.checkError { sqlite3_close(db) }
    }

    public typealias SQLiteExecCallback = ([Column]) -> Void

    public struct Configuration {
        public var busyTimeoutSeconds: Int32

        public init() {
            self.busyTimeoutSeconds = 5
        }
    }

    public enum Location {
        case path(AbsolutePath)
        case memory
        case temporary

        var pathString: String {
            switch self {
            case .path(let path):
                return path.pathString
            case .memory:
                return ":memory:"
            case .temporary:
                return ""
            }
        }
    }

    /// Represents an sqlite value.
    public enum SQLiteValue {
        case null
        case string(String)
        case int(Int)
        case blob(Data)
    }

    /// Represents a row returned by called step() on a prepared statement.
    public struct Row {
        /// The pointer to the prepared statment.
        let stmt: OpaquePointer

        /// Get integer at the given column index.
        public func int(at index: Int32) -> Int {
            Int(sqlite3_column_int64(self.stmt, index))
        }

        /// Get blob data at the given column index.
        public func blob(at index: Int32) -> Data {
            let bytes = sqlite3_column_blob(stmt, index)!
            let count = sqlite3_column_bytes(stmt, index)
            return Data(bytes: bytes, count: Int(count))
        }

        /// Get string at the given column index.
        public func string(at index: Int32) -> String {
            return String(cString: sqlite3_column_text(self.stmt, index))
        }
    }

    public struct Column {
        public var name: String
        public var value: String
    }

    /// Represents a prepared statement.
    public struct PreparedStatement {
        typealias sqlite3_destructor_type = (@convention(c) (UnsafeMutableRawPointer?) -> Void)
        static let SQLITE_STATIC = unsafeBitCast(0, to: sqlite3_destructor_type.self)
        static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        /// The pointer to the prepared statment.
        let stmt: OpaquePointer

        public init(db: OpaquePointer, query: String) throws {
            var stmt: OpaquePointer?
            try checkError { sqlite3_prepare_v2(db, query, -1, &stmt, nil) }
            self.stmt = stmt!
        }

        /// Evaluate the prepared statement.
        @discardableResult
        public func step() throws -> Row? {
            let result = sqlite3_step(stmt)

            switch result {
            case SQLITE_DONE:
                return nil
            case SQLITE_ROW:
                return Row(stmt: self.stmt)
            default:
                throw StringError(String(cString: sqlite3_errstr(result)))
            }
        }

        /// Bind the given arguments to the statement.
        public func bind(_ arguments: [SQLiteValue]) throws {
            for (idx, argument) in arguments.enumerated() {
                let idx = Int32(idx) + 1
                switch argument {
                case .null:
                    try checkError { sqlite3_bind_null(stmt, idx) }
                case .int(let int):
                    try checkError { sqlite3_bind_int64(stmt, idx, Int64(int)) }
                case .string(let str):
                    try checkError { sqlite3_bind_text(stmt, idx, str, -1, Self.SQLITE_TRANSIENT) }
                case .blob(let blob):
                    try checkError {
                        blob.withUnsafeBytes { ptr in
                            sqlite3_bind_blob(
                                stmt,
                                idx,
                                ptr.baseAddress,
                                Int32(blob.count),
                                Self.SQLITE_TRANSIENT
                            )
                        }
                    }
                }
            }
        }

        /// Reset the prepared statement.
        public func reset() throws {
            try checkError { sqlite3_reset(stmt) }
        }

        /// Clear bindings from the prepared statment.
        public func clearBindings() throws {
            try checkError { sqlite3_clear_bindings(stmt) }
        }

        /// Finalize the statement and free up resources.
        public func finalize() throws {
            try checkError { sqlite3_finalize(stmt) }
        }
    }

    fileprivate class CallbackWrapper {
        var callback: SQLiteExecCallback
        init(_ callback: @escaping SQLiteExecCallback) {
            self.callback = callback
        }
    }

    private static func checkError(_ errorPrefix: String? = nil, _ fn: () -> Int32) throws {
        let result = fn()
        if result != SQLITE_OK {
            var error = ""
            if let errorPrefix = errorPrefix {
                error += errorPrefix + ": "
            }
            error += String(cString: sqlite3_errstr(result))
            throw StringError(error)
        }
    }
}

private func sqlite_callback(
    _ ctx: UnsafeMutableRawPointer?,
    _ numColumns: Int32,
    _ columns: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?,
    _ columnNames: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?
) -> Int32 {
    guard let ctx = ctx else { return 0 }
    guard let columnNames = columnNames, let columns = columns else { return 0 }
    let numColumns = Int(numColumns)
    var result: [SQLite.Column] = []

    for idx in 0 ..< numColumns {
        var name = ""
        if let ptr = columnNames.advanced(by: idx).pointee {
            name = String(cString: ptr)
        }
        var value = ""
        if let ptr = columns.advanced(by: idx).pointee {
            value = String(cString: ptr)
        }
        result.append(SQLite.Column(name: name, value: value))
    }

    let wcb = Unmanaged<SQLite.CallbackWrapper>.fromOpaque(ctx).takeUnretainedValue()
    wcb.callback(result)

    return 0
}
