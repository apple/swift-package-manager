//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import CRT
import WinSDK
#else
import Darwin.C
#endif

// FIXME: Use Synchronization.Mutex when available
class Mutex<T>: @unchecked Sendable {
    var lock: NSLock
    var value: T

    init(value: T) {
        self.lock = .init()
        self.value = value
    }

    func withLock<U>(_ body: (inout T) -> U) -> U {
        self.lock.lock()
        defer { self.lock.unlock() }
        return body(&self.value)
    }
}

// FIXME: This should come from Foundation
// FIXME: package (public required by users)
public struct Environment {
    var storage: [EnvironmentKey: String]
}

// MARK: - Accessors

extension Environment {
    package init() {
        self.storage = .init()
    }

    package subscript(_ key: EnvironmentKey) -> String? {
        _read { yield self.storage[key] }
        _modify { yield &self.storage[key] }
    }
}

// MARK: - Conversions between Dictionary<String, String>

extension Environment {
    package init(_ dictionary: [String: String]) {
        self.storage = .init()
        let sorted = dictionary.sorted { $0.key < $1.key }
        for (key, value) in sorted {
            self.storage[.init(key)] = value
        }
    }
}

extension [String: String] {
    package init(_ environment: Environment) {
        self.init()
        let sorted = environment.sorted { $0.key < $1.key }
        for (key, value) in sorted {
            self[key.rawValue] = value
        }
    }
}

// MARK: - Path Modification

extension Environment {
    package mutating func prependPath(key: EnvironmentKey, value: String) {
        guard !value.isEmpty else { return }
        if let existing = self[key] {
            self[key] = "\(value)\(Self.pathEntryDelimiter)\(existing)"
        } else {
            self[key] = value
        }
    }

    package mutating func appendPath(key: EnvironmentKey, value: String) {
        guard !value.isEmpty else { return }
        if let existing = self[key] {
            self[key] = "\(existing)\(Self.pathEntryDelimiter)\(value)"
        } else {
            self[key] = value
        }
    }

    package static var pathEntryDelimiter: String {
        #if os(Windows)
        ";"
        #else
        ":"
        #endif
    }
}

// MARK: - Global Environment

extension Environment {
    static let _cachedCurrent = Mutex<Self?>(value: nil)

    /// Vends a copy of the current process's environment variables.
    ///
    /// Mutations to the current process's global environment are not reflected
    /// in the returned value.
    public static var current: Self {
        Self._cachedCurrent.withLock { cachedValue in
            if let cachedValue = cachedValue {
                return cachedValue
            } else {
                let current = Self(ProcessInfo.processInfo.environment)
                cachedValue = current
                return current
            }
        }
    }

    /// Temporary override environment variables
    ///
    /// WARNING! This method is not thread-safe. POSIX environments are shared
    /// between threads. This means that when this method is called simultaneously
    /// from different threads, the environment will neither be setup nor restored
    /// correctly.
    package static func makeCustom<T>(
        _ environment: Self,
        body: () async throws -> T
    ) async throws -> T {
        let current = Self.current
        let state = environment.storage.keys.map { ($0, current[$0]) }
        let restore = {
            for (key, value) in state {
                try Self.set(key: key, value: value)
            }
        }
        let returnValue: T
        do {
            for (key, value) in environment {
                try Self.set(key: key, value: value)
            }
            returnValue = try await body()
        } catch {
            try? restore()
            throw error
        }
        try restore()
        return returnValue
    }

    /// Temporary override environment variables
    ///
    /// WARNING! This method is not thread-safe. POSIX environments are shared
    /// between threads. This means that when this method is called simultaneously
    /// from different threads, the environment will neither be setup nor restored
    /// correctly.
    package static func makeCustom<T>(
        _ environment: Self,
        body: () throws -> T
    ) throws -> T {
        let current = Self.current
        let state = environment.storage.keys.map { ($0, current[$0]) }
        let restore = {
            for (key, value) in state {
                try Self.set(key: key, value: value)
            }
        }
        let returnValue: T
        do {
            for (key, value) in environment {
                try Self.set(key: key, value: value)
            }
            returnValue = try body()
        } catch {
            try? restore()
            throw error
        }
        try restore()
        return returnValue
    }

    struct UpdateEnvironmentError: CustomStringConvertible, Error {
        var function: StaticString
        var code: Int32
        var description: String { "\(self.function) returned \(self.code)" }
    }

    /// Modifies the process's global environment.
    ///
    /// > Important: This operation is _not_ concurrency safe.
    package static func set(key: EnvironmentKey, value: String?) throws {
        #if os(Windows)
        func _SetEnvironmentVariableW(_ key: String, _ value: String?) -> Bool {
            key.withCString(encodedAs: UTF16.self) { key in
                if let value {
                    value.withCString(encodedAs: UTF16.self) { value in
                        SetEnvironmentVariableW(key, value)
                    }
                } else {
                    SetEnvironmentVariableW(key, nil)
                }
            }
        }
        #endif

        // Invalidate cached value after mutating the global environment.
        // This is potentially overly safe because we may not need to invalidate
        // the cache if the mutation fails. However this approach is easier to
        // read and reason about.
        defer { Self._cachedCurrent.withLock { $0 = nil } }
        if let value = value {
            #if os(Windows)
            guard _SetEnvironmentVariableW(key.rawValue, value) else {
                throw UpdateEnvironmentError(
                    function: "SetEnvironmentVariableW",
                    code: Int32(GetLastError())
                )
            }
            guard _putenv("\(key)=\(value)") == 0 else {
                throw UpdateEnvironmentError(
                    function: "_putenv",
                    code: Int32(GetLastError())
                )
            }
            #else
            guard setenv(key.rawValue, value, 1) == 0 else {
                throw UpdateEnvironmentError(
                    function: "setenv",
                    code: errno
                )
            }
            #endif
        } else {
            #if os(Windows)
            guard _SetEnvironmentVariableW(key.rawValue, nil) else {
                throw UpdateEnvironmentError(
                    function: "SetEnvironmentVariableW",
                    code: Int32(GetLastError())
                )
            }
            guard _putenv("\(key)=") == 0 else {
                throw UpdateEnvironmentError(
                    function: "_putenv",
                    code: Int32(GetLastError())
                )
            }
            #else
            guard unsetenv(key.rawValue) == 0 else {
                throw UpdateEnvironmentError(
                    function: "unsetenv",
                    code: errno
                )
            }
            #endif
        }
    }
}

// MARK: - Cachable Keys

extension Environment {
    /// Returns a copy of `self` with known non-cacheable keys removed.
    ///
    /// - Issue: rdar://107029374
    package var cachable: Environment {
        var cachable = Environment()
        for (key, value) in self {
            if !EnvironmentKey.nonCachable.contains(key) {
                cachable[key] = value
            }
        }
        return cachable
    }
}

// MARK: - Protocol Conformances

extension Environment: Collection {
    public struct Index: Comparable {
        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.underlying < rhs.underlying
        }

        var underlying: Dictionary<EnvironmentKey, String>.Index
    }

    public typealias Element = (key: EnvironmentKey, value: String)

    public var startIndex: Index {
        Index(underlying: self.storage.startIndex)
    }

    public var endIndex: Index {
        Index(underlying: self.storage.endIndex)
    }

    public subscript(index: Index) -> Element {
        self.storage[index.underlying]
    }

    public func index(after index: Self.Index) -> Self.Index {
        Index(underlying: self.storage.index(after: index.underlying))
    }
}

extension Environment: CustomStringConvertible {
    public var description: String {
        let body = self
            .sorted { $0.key < $1.key }
            .map { "\"\($0.rawValue)=\($1)\"" }
            .joined(separator: ", ")
        return "[\(body)]"
    }
}

extension Environment: Encodable {
    public func encode(to encoder: any Encoder) throws {
        try self.storage.encode(to: encoder)
    }
}

extension Environment: Equatable {}

extension Environment: ExpressibleByDictionaryLiteral {
    public typealias Key = EnvironmentKey
    public typealias Value = String

    public init(dictionaryLiteral elements: (Key, Value)...) {
        self.storage = .init()
        for (key, value) in elements {
            self.storage[key] = value
        }
    }
}

extension Environment: Decodable {
    public init(from decoder: any Decoder) throws {
        self.storage = try .init(from: decoder)
    }
}

extension Environment: Sendable {}
