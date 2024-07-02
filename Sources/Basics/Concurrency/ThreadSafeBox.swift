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

import class Foundation.NSLock

/// Thread-safe value boxing structure
@dynamicMemberLookup
public final class ThreadSafeBox<Value> {
    private var underlying: Value?
    private let lock = NSLock()

    public init() {}

    public init(_ seed: Value) {
        self.underlying = seed
    }

    public func mutate(body: (Value?) throws -> Value?) rethrows {
        try self.lock.withLock {
            let value = try body(self.underlying)
            self.underlying = value
        }
    }

    @discardableResult
    public func memoize(body: () throws -> Value) rethrows -> Value {
        if let value = self.get() {
            return value
        }
        let value = try body()
        self.lock.withLock {
            self.underlying = value
        }
        return value
    }

    @discardableResult
    public func memoize(body: () async throws -> Value) async rethrows -> Value {
        if let value = self.get() {
            return value
        }
        let value = try await body()
        self.lock.withLock {
            self.underlying = value
        }
        return value
    }

    public func clear() {
        self.lock.withLock {
            self.underlying = nil
        }
    }

    public func get() -> Value? {
        self.lock.withLock {
            self.underlying
        }
    }

    public func get(default: Value) -> Value {
        self.lock.withLock {
            self.underlying ?? `default`
        }
    }

    public func put(_ newValue: Value) {
        self.lock.withLock {
            self.underlying = newValue
        }
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> T? {
        self.lock.withLock {
            self.underlying?[keyPath: keyPath]
        }
    }

    public subscript<T>(dynamicMember keyPath: WritableKeyPath<Value, T?>) -> T? {
        get {
            self.lock.withLock {
                self.underlying?[keyPath: keyPath]
            }
        }
        set {
            self.lock.withLock {
                if var value = self.underlying {
                    value[keyPath: keyPath] = newValue
                }
            }
        }
    }
}

extension ThreadSafeBox where Value == Int {
    public func increment() {
        self.lock.withLock {
            if let value = self.underlying {
                self.underlying = value + 1
            }
        }
    }

    public func decrement() {
        self.lock.withLock {
            if let value = self.underlying {
                self.underlying = value - 1
            }
        }
    }
}

extension ThreadSafeBox where Value == String {
    public func append(_ value: String) {
        self.mutate { existingValue in
            if let existingValue {
                return existingValue + value
            } else {
                return value
            }
        }
    }
}

extension ThreadSafeBox: @unchecked Sendable where Value: Sendable {}
