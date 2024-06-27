//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2016-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//


@testable import PackageGraph
import XCTest

private func XCTAssertThrows<T: Swift.Error>(
    _ expectedError: T,
    file: StaticString = #file,
    line: UInt = #line,
    _ body: () throws -> Void
) where T: Equatable {
    do {
        try body()
        XCTFail("body completed successfully", file: file, line: line)
    } catch let error as T {
        XCTAssertEqual(error, expectedError, file: file, line: line)
    } catch {
        XCTFail("unexpected error thrown: \(error)", file: file, line: line)
    }
}

extension Int {
    public var id: Self { self }
}

#if compiler(<6.0)
extension Int: Identifiable {}
#else
extension Int: @retroactive Identifiable {}
#endif

private func topologicalSort(_ nodes: [Int], _ successors: [Int: [Int]]) throws -> [Int] {
    return try topologicalSort(nodes, successors: { successors[$0] ?? [] })
}
private func topologicalSort(_ node: Int, _ successors: [Int: [Int]]) throws -> [Int] {
    return try topologicalSort([node], successors)
}

final class TopologicalSortTests: XCTestCase {
    func testTopologicalSort() throws {
        // A trivial graph.
        XCTAssertEqual([1, 2], try topologicalSort(1, [1: [2]]))
        XCTAssertEqual([1, 2], try topologicalSort([2, 1], [1: [2]]))

        // A diamond.
        let diamond: [Int: [Int]] = [
            1: [3, 2],
            2: [4],
            3: [4]
        ]
        XCTAssertEqual([1, 2, 3, 4], try topologicalSort(1, diamond))
        XCTAssertEqual([2, 3, 4], try topologicalSort([3, 2], diamond))
        XCTAssertEqual([1, 2, 3, 4], try topologicalSort([4, 3, 2, 1], diamond))

        // Test cycle detection.
        XCTAssertThrows(GraphError.unexpectedCycle) { _ = try topologicalSort(1, [1: [1]]) }
        XCTAssertThrows(GraphError.unexpectedCycle) { _ = try topologicalSort(1, [1: [2], 2: [1]]) }
    }
}
