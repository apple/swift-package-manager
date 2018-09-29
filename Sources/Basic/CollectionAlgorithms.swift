/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

extension BidirectionalCollection where Iterator.Element : Comparable {
    /// Returns the index of the last occurrence of `element` or nil if none.
    ///
    /// - Parameters:
    ///   - start: If provided, the `start` index limits the search to a suffix of the collection.
    //
    // FIXME: This probably shouldn't take the `from` parameter, the pattern in
    // the standard library is to use slices for that.
    public func rindex(of element: Iterator.Element, from start: Index? = nil) -> Index? {
        let firstIdx = start ?? startIndex
        var i = endIndex
        while i > firstIdx {
            self.formIndex(before: &i)
            if self[i] == element {
                return i
            }
        }
        return nil
    }
}

extension Sequence where Iterator.Element: Hashable {

    /// Finds duplicates in given sequence of Hashables.
    /// - Returns: duplicated elements in the invoking sequence.
    public func findDuplicates() -> [Iterator.Element] {
        var unique: Set<Iterator.Element> = []
        return filter {
            !unique.insert($0).inserted
        }
    }
}

extension Collection where Element: Hashable {

    /// Finds duplicates in given collection of Hashables.
    public func findDuplicateElements() -> [[Element]] {
        var table: [Element: [Element]] = [:]
        for element in self {
            table[element, default: []].append(element)
        }
        return table.values.filter({ $0.count > 1 })
    }
}

extension Sequence {
    public func findDuplicateElements<Key: Hashable>(
        by keyPath: KeyPath<Self.Element, Key>
    ) -> [[Element]] {
        return Dictionary(grouping: self, by: { $0[keyPath: keyPath] })
            .values
            .filter({ $0.count > 1 })
    }
}
