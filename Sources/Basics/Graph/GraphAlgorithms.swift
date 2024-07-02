//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2015-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct OrderedCollections.OrderedSet

/// Implements a pre-order depth-first search.
///
/// The cycles are handled by skipping cycle points but it should be possible to
/// to extend this in the future to provide a callback for every cycle.
///
/// - Parameters:
///   - nodes: The list of input nodes to sort.
///   - successors: A closure for fetching the successors of a particular node.
///   - onUnique: A callback to indicate the the given node is being processed for the first time.
///   - onDuplicate: A callback to indicate that the node was already processed at least once.
///
/// - Complexity: O(v + e) where (v, e) are the number of vertices and edges
/// reachable from the input nodes via the relation.
public func depthFirstSearch<T: Hashable>(
    _ nodes: [T],
    successors: (T) throws -> [T],
    onUnique: (T) -> Void,
    onDuplicate: (T, T) -> Void
) rethrows {
    var stack = OrderedSet<T>()
    var visited = Set<T>()

    for node in nodes {
        precondition(stack.isEmpty)
        stack.append(node)

        while !stack.isEmpty {
            let curr = stack.removeLast()

            let visitResult = visited.insert(curr)
            if visitResult.inserted {
                onUnique(curr)
            } else {
                onDuplicate(visitResult.memberAfterInsert, curr)
                continue
            }

            for succ in try successors(curr) {
                stack.append(succ)
            }
        }
    }
}

package func asyncDepthFirstSearch<T: Hashable>(
    _ nodes: [T],
    successors: (T) async throws -> [T],
    onUnique: (T) -> Void,
    onDuplicate: (T, T) -> Void
) async rethrows {
    var stack = OrderedSet<T>()
    var visited = Set<T>()

    for node in nodes {
        precondition(stack.isEmpty)
        stack.append(node)

        while !stack.isEmpty {
            let curr = stack.removeLast()

            let visitResult = visited.insert(curr)
            if visitResult.inserted {
                onUnique(curr)
            } else {
                onDuplicate(visitResult.memberAfterInsert, curr)
                continue
            }

            for succ in try await successors(curr) {
                stack.append(succ)
            }
        }
    }
}
