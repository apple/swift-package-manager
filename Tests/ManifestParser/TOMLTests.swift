/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

@testable import ManifestParser
import XCTest

// Test the basic types.
private func toArray(_ items: [TOMLItem]) -> TOMLItem {
    return .Array(contents: TOMLItemArray(items: items))
}

private func toTable(_ items: [String: TOMLItem]) -> TOMLItem {
    return .Table(contents: TOMLItemTable(items: items))
}

private func parseTOML(_ data: String) -> TOMLItem {
    do {
        return try TOMLItem.parse(data)
    } catch let err {
        fatalError("unexpected error while parsing: \(err)")
    }
}

class TOMLTests: XCTestCase {

    func testLexer() {
        // Test the basics.
        XCTAssertEqual(lexTOML("# Comment\nfoo"), ["Comment", "Identifier(\"foo\")"])
        XCTAssertEqual(lexTOML("# Comment\r\nfoo"), ["Comment", "Identifier(\"foo\")"])
        XCTAssertEqual(lexTOML("=\n[ ]  . \t,"), ["Equals", "Newline", "LSquare", "Whitespace", "RSquare", "Whitespace", "Period", "Whitespace", "Comma"])
        XCTAssertEqual(lexTOML("\"foo\""), ["StringLiteral(\"foo\")"])
        XCTAssertEqual(lexTOML("foo_bar-123"), ["Identifier(\"foo_bar-123\")"])
        XCTAssertEqual(lexTOML("false true"), ["Boolean(false)", "Whitespace", "Boolean(true)"])
        XCTAssertEqual(lexTOML("+12"), ["Number(\"+12\")"])
        XCTAssertEqual(lexTOML("1.2e-10"), ["Number(\"1.2e-10\")"])
        XCTAssertEqual(lexTOML("1.234"), ["Number(\"1.234\")"])
    }

    func testParser() {
        XCTAssertEqual(parseTOML("a = b"), toTable(["a": .String(value: "b")]))
        XCTAssertEqual(parseTOML("a = \"b\""), toTable(["a": .String(value: "b")]))
        XCTAssertEqual(parseTOML("a = 1"), toTable(["a": .Int(value: 1)]))
        XCTAssertEqual(parseTOML("a = 1.234"), toTable(["a": .Float(value: 1.234)]))
        XCTAssertEqual(parseTOML("a = 1.2e-2"), toTable(["a": .Float(value: 1.2e-2)]))
        XCTAssertEqual(parseTOML("a = -12_34_56"), toTable(["a": .Int(value: -123456)]))
        XCTAssertEqual(parseTOML("a = +1.2_34_56"), toTable(["a": .Float(value: 1.23456)]))
        XCTAssertEqual(parseTOML("a = true\n\nb = false"), toTable(["a": .Bool(value: true), "b": .Bool(value: false)]))

        // Test arrays.
        XCTAssertEqual(parseTOML("a = [1, 2]"), toTable(["a": toArray([.Int(value: 1), .Int(value: 2)])]))
        XCTAssertEqual(parseTOML("a = [1,\n[\n2,\n] ]"), toTable(["a": toArray([.Int(value: 1), toArray([.Int(value: 2)])])]))
    }

    func testParsingTables() {
        // Test nested tables.
        XCTAssertEqual(parseTOML(
            (
                "a = 1\n" +
                "[t1]\n" +
                "b = 2\n" +
                "[t2]\n" +
                "b = 3\n" +
                "[t2.t1]\n" +
                "b = 4\n")),
            toTable([
                "a": .Int(value: 1),
                "t1": toTable([
                    "b": .Int(value: 2)]),
                "t2": toTable([
                    "b": .Int(value: 3),
                    "t1": toTable([
                        "b": .Int(value: 4)])])]))

        // Check handling of empty nested tables.
        XCTAssertEqual(parseTOML("[[t1]]"), toTable([
            "t1": toArray([toTable([:])])]))

        // Check basic append handling.
        XCTAssertEqual(parseTOML(
            (
                "[[t1]]\n" +
                "a = 1\n" +
                "[[t1]]\n" +
                "a = 2\n")),
            toTable([
                "t1": toArray([
                    toTable(["a": .Int(value: 1)]),
                    toTable(["a": .Int(value: 2)])])]))

        // Check handling of insert into array of tables.
        XCTAssertEqual(parseTOML(
            (
                "[[t1]]\n" +
                "[t1.t2]\n" +
                "a = 1\n")),
            toTable([
                "t1": toArray([
                    toTable([
                        "t2": toTable(["a": .Int(value: 1)])])])]))
    }
}


extension TOMLTests {
    static var allTests : [(String, TOMLTests -> () throws -> Void)] {
        return [
            ("testLexer", testLexer),
            ("testParser", testParser),
            ("testParsingTables", testParsingTables),
        ]
    }
}

extension ManifestTests {
    static var allTests : [(String, ManifestTests -> () throws -> Void)] {
        return [
            ("testManifestLoading", testManifestLoading),
        ]
    }
}

extension PackageTests {
    static var allTests : [(String, PackageTests -> () throws -> Void)] {
        return [
            ("testBasics", testBasics),
            ("testExclude", testExclude),
            ("testEmptyTestDependencies", testEmptyTestDependencies),
            ("testTestDependencies", testTestDependencies),
            ("testTargetDependencyIsStringConvertible", testTargetDependencyIsStringConvertible)
        ]
    }
}
