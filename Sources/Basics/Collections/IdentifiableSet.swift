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

/// Replacement for `Set` elements that can't be `Hashable`, but can be `Identifiable`.
public struct IdentifiableSet<Element: Identifiable>: Collection {
    public init() {
        self.storage = [:]
    }

    public init(_ sequence: some Sequence<Element>) {
        self.storage = .init(pickLastWhenDuplicateFound: sequence)
    }

    fileprivate typealias Storage = [Element.ID: Element]

    public struct Index: Comparable {
        public static func < (lhs: IdentifiableSet<Element>.Index, rhs: IdentifiableSet<Element>.Index) -> Bool {
            lhs.storageIndex < rhs.storageIndex
        }

        fileprivate let storageIndex: Storage.Index
    }

    private var storage: Storage

    public var startIndex: Index {
        Index(storageIndex: storage.startIndex)
    }

    public var endIndex: Index {
        Index(storageIndex: storage.endIndex)
    }

    public subscript(position: Index) -> Element {
        self.storage[position.storageIndex].value
    }

    public subscript(id: Element.ID) -> Element? {
        get {
            self.storage[id]
        }
        set {
            self.storage[id] = newValue
        }
    }

    public func index(after i: Index) -> Index {
        Index(storageIndex: self.storage.index(after: i.storageIndex))
    }

    public mutating func insert(_ element: Element) {
        self.storage[element.id] = element
    }

    public func union(_ otherSequence: some Sequence<Element>) -> Self {
        var result = self
        for element in otherSequence {
            result.storage[element.id] = element
        }
        return result
    }

    public mutating func formUnion(_ otherSequence: some Sequence<Element>) {
        for element in otherSequence {
            self.storage[element.id] = element
        }
    }

    public func intersection(_ otherSequence: some Sequence<Element>) -> Self {
        let keysToRemove = Set(self.storage.keys).subtracting(otherSequence.map(\.id))
        var result = Self()
        for key in keysToRemove {
            result.storage.removeValue(forKey: key)
        }
        return result
    }

    public func subtracting(_ otherSequence: some Sequence<Element>) -> Self {
        var result = self
        for element in otherSequence {
            result.storage.removeValue(forKey: element.id)
        }
        return result
    }

    public func contains(id: Element.ID) -> Bool {
        self.storage.keys.contains(id)
    }
}

extension Dictionary where Value: Identifiable, Key == Value.ID {
    fileprivate init(pickLastWhenDuplicateFound sequence: some Sequence<Value>) {
        self.init(sequence.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    }
}

extension IdentifiableSet: Equatable {
    public static func ==(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.storage.keys == rhs.storage.keys
    }
}

extension IdentifiableSet: Hashable {
    public func hash(into hasher: inout Hasher) {
        for key in self.storage.keys {
            hasher.combine(key)
        }
    }
}
