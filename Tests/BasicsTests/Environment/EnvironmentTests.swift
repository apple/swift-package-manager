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

final class EnvironmentTests: XCTestCase {
    func test_init() {
        let environment = Environment()
        XCTAssertTrue(environment.isEmpty)
    }

    func test_subscript() {
        var environment = Environment()
        let key = EnvironmentKey("TestKey")
        environment[key] = "TestValue"
        XCTAssertEqual(environment[key], "TestValue")
    }

    func test_initDictionaryFromSelf() {
        let dictionary = [
            "TestKey": "TestValue",
            "testKey": "TestValue2",
        ]
        let environment = Environment(dictionary)
        XCTAssertEqual(environment["TestKey"], "TestValue")
        #if os(Windows)
        XCTAssertEqual(environment.count, 1)
        #else
        XCTAssertEqual(environment.count, 2)
        #endif
    }

    func test_initSelfFromDictionary() {
        let dictionary = ["TestKey": "TestValue"]
        let environment = Environment(dictionary)
        XCTAssertEqual(environment["TestKey"], "TestValue")
    }

    func path(_ components: String...) -> String {
        components.joined(separator: Environment.pathEntryDelimiter)
    }

    func test_prependPath() {
        var environment = Environment()
        let key = EnvironmentKey(UUID().uuidString)
        XCTAssertNil(environment[key])

        environment.prependPath(key: key, value: "/bin")
        XCTAssertEqual(environment[key], path("/bin"))

        environment.prependPath(key: key, value: "/usr/bin")
        XCTAssertEqual(environment[key], path("/usr/bin", "/bin"))

        environment.prependPath(key: key, value: "/usr/local/bin")
        XCTAssertEqual(environment[key], path("/usr/local/bin", "/usr/bin", "/bin"))

        environment.prependPath(key: key, value: "")
        XCTAssertEqual(environment[key], path("/usr/local/bin", "/usr/bin", "/bin"))
    }

    func test_appendPath() {
        var environment = Environment()
        let key = EnvironmentKey(UUID().uuidString)
        XCTAssertNil(environment[key])

        environment.appendPath(key: key, value: "/bin")
        XCTAssertEqual(environment[key], path("/bin"))

        environment.appendPath(key: key, value: "/usr/bin")
        XCTAssertEqual(environment[key], path("/bin", "/usr/bin"))

        environment.appendPath(key: key, value: "/usr/local/bin")
        XCTAssertEqual(environment[key], path("/bin", "/usr/bin", "/usr/local/bin"))

        environment.appendPath(key: key, value: "")
        XCTAssertEqual(environment[key], path("/bin", "/usr/bin", "/usr/local/bin"))
    }

    func test_pathEntryDelimiter() {
        #if os(Windows)
        XCTAssertEqual(Environment.pathEntryDelimiter, ";")
        #else
        XCTAssertEqual(Environment.pathEntryDelimiter, ":")
        #endif
    }

    /// Important: This test is inherently race-prone, if it is proven to be
    /// flaky, it should run in a singled threaded environment/removed entirely.
    func test_current() {
        XCTAssertEqual(
            Environment.current["PATH"],
            ProcessInfo.processInfo.environment["PATH"])
    }

    /// Important: This test is inherently race-prone, if it is proven to be
    /// flaky, it should run in a singled threaded environment/removed entirely.
    func test_makeCustom() async throws {
        let key = EnvironmentKey(UUID().uuidString)
        let value = "TestValue"

        var customEnvironment = Environment()
        customEnvironment[key] = value

        XCTAssertNil(Environment.current[key])
        try Environment.makeCustom(customEnvironment) {
            XCTAssertEqual(Environment.current[key], value)
        }
        XCTAssertNil(Environment.current[key])
    }

    /// Important: This test is inherently race-prone, if it is proven to be
    /// flaky, it should run in a singled threaded environment/removed entirely.
    func testProcess() throws {
        let key = EnvironmentKey(UUID().uuidString)
        let value = "TestValue"

        var environment = Environment.current
        XCTAssertNil(environment[key])

        try Environment.set(key: key, value: value)
        environment = Environment.current // reload
        XCTAssertEqual(environment[key], value)

        try Environment.set(key: key, value: nil)
        XCTAssertEqual(environment[key], value) // this is a copy!

        environment = Environment.current // reload
        XCTAssertNil(environment[key])
    }

    func test_cachable() {
        let term = EnvironmentKey("TERM")
        var environment = Environment()
        environment[.path] = "/usr/bin"
        environment[term] = "xterm-256color"

        let cachableEnvironment = environment.cachable
        XCTAssertNotNil(cachableEnvironment[.path])
        XCTAssertNil(cachableEnvironment[term])
    }

    func test_collection() {
        let environment: Environment = ["TestKey": "TestValue"]
        XCTAssertEqual(environment.count, 1)
        XCTAssertEqual(environment.first?.key, EnvironmentKey("TestKey"))
        XCTAssertEqual(environment.first?.value, "TestValue")
    }

    func test_description() {
        var environment = Environment()
        environment[EnvironmentKey("TestKey")] = "TestValue"
        XCTAssertEqual(environment.description, #"["TestKey=TestValue"]"#)
    }

    func test_encodable() throws {
        var environment = Environment()
        environment["TestKey"] = "TestValue"
        let data = try JSONEncoder().encode(environment)
        let jsonString = String(data: data, encoding: .utf8)
        XCTAssertEqual(jsonString, #"{"TestKey":"TestValue"}"#)
    }

    func test_equatable() {
        let environment0: Environment = ["TestKey": "TestValue"]
        let environment1: Environment = ["TestKey": "TestValue"]
        XCTAssertEqual(environment0, environment1)

#if os(Windows)
        // Test case insensitivity on windows
        let environment2: Environment = ["testKey": "TestValue"]
        XCTAssertEqual(environment0, environment2)
#endif
    }

    func test_expressibleByDictionaryLiteral() {
        let environment: Environment = ["TestKey": "TestValue"]
        XCTAssertEqual(environment["TestKey"], "TestValue")
    }


    func test_decodable() throws {
        let jsonString = #"{"TestKey":"TestValue"}"#
        let data = jsonString.data(using: .utf8)!
        let environment = try JSONDecoder().decode(Environment.self, from: data)
        XCTAssertEqual(environment[EnvironmentKey("TestKey")], "TestValue")
    }
}
