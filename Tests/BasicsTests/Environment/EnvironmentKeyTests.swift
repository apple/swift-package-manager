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

@testable import Basics
import XCTest

final class EnvironmentKeyTests: XCTestCase {
    func test_comparable() {
        let key0 = EnvironmentKey("Test")
        let key1 = EnvironmentKey("Test1")
        XCTAssertLessThan(key0, key1)

        let key2 = EnvironmentKey("test")
        XCTAssertLessThan(key0, key2)
    }

    func test_customStringConvertible() {
        let key = EnvironmentKey("Test")
        XCTAssertEqual(key.description, "Test")
    }

    func test_encodable() throws {
        let key = EnvironmentKey("Test")
        let data = try JSONEncoder().encode(key)
        let string = String(data: data, encoding: .utf8)
        XCTAssertEqual(string, #""Test""#)
    }

    func test_equatable() {
        let key0 = EnvironmentKey("Test")
        let key1 = EnvironmentKey("Test")
        XCTAssertEqual(key0, key1)

        let key2 = EnvironmentKey("Test2")
        XCTAssertNotEqual(key0, key2)

        #if os(Windows)
        // Test case insensitivity on windows
        let key2 = EnvironmentKey("teSt")
        XCTAssertEqual(key0, key2)
        #endif
    }

    func test_expressibleByStringLiteral() {
        let key0 = EnvironmentKey("Test")
        XCTAssertEqual(key0, "Test")
    }

    func test_decodable() throws {
        let jsonString = #""Test""#
        let data = jsonString.data(using: .utf8)!
        let key = try JSONDecoder().decode(EnvironmentKey.self, from: data)
        XCTAssertEqual(key.rawValue, "Test")
    }

    func test_hashable() {
        var set = Set<EnvironmentKey>()
        let key0 = EnvironmentKey("Test")
        XCTAssertTrue(set.insert(key0).inserted)

        let key1 = EnvironmentKey("Test")
        XCTAssertTrue(set.contains(key1))
        XCTAssertFalse(set.insert(key1).inserted)

        let key2 = EnvironmentKey("Test2")
        XCTAssertFalse(set.contains(key2))
        XCTAssertTrue(set.insert(key2).inserted)

        #if os(Windows)
        // Test case insensitivity on windows
        let key3 = EnvironmentKey("teSt")
        XCTAssertTrue(set.contains(key3))
        XCTAssertFalse(set.insert(key3).inserted)
        #endif

        XCTAssertEqual(set, ["Test", "Test2"])
    }

    func test_rawRepresentable() {
        let key = EnvironmentKey(rawValue: "Test")
        XCTAssertEqual(key?.rawValue, "Test")
    }
}
