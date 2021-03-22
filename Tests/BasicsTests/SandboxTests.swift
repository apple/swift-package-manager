/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

@testable import Basics
import TSCBasic
import TSCUtility
import XCTest

final class SandboxTest: XCTestCase {
    func testNetworkNotAllowed() throws {
        #if !os(macOS)
        XCTSkip()
        #endif

        let command = Sandbox.apply(command: ["curl", "http://localhost"], writableDirectories: [], strictness: .default)

        XCTAssertThrowsError(try Process.checkNonZeroExit(arguments: command)) { error in
            guard case ProcessResult.Error.nonZeroExit(let result) = error else {
                return XCTFail("invalid error \(error)")
            }
            XCTAssertTrue(try! result.utf8stderrOutput().contains("Operation not permitted"))
        }
    }

    func testWritableAllowed() throws {
        #if !os(macOS)
        XCTSkip()
        #endif

        try withTemporaryDirectory { path in
            let command = Sandbox.apply(command: ["touch", path.appending(component: UUID().uuidString).pathString], writableDirectories: [path], strictness: .default)
            XCTAssertNoThrow(try Process.checkNonZeroExit(arguments: command))
        }
    }

    func testWritableNotAllowed() throws {
        #if !os(macOS)
        XCTSkip()
        #endif

        try withTemporaryDirectory { path in
            let command = Sandbox.apply(command: ["touch", path.appending(component: UUID().uuidString).pathString], writableDirectories: [], strictness: .default)
            XCTAssertThrowsError(try Process.checkNonZeroExit(arguments: command)) { error in
                guard case ProcessResult.Error.nonZeroExit(let result) = error else {
                    return XCTFail("invalid error \(error)")
                }
                XCTAssertTrue(try! result.utf8stderrOutput().contains("Operation not permitted"))
            }
        }
    }

    func testRemoveNotAllowed() throws {
        #if !os(macOS)
        XCTSkip()
        #endif

        try withTemporaryDirectory { path in
            let file = path.appending(component: UUID().uuidString)
            XCTAssertNoThrow(try Process.checkNonZeroExit(arguments: ["touch", file.pathString]))

            let command = Sandbox.apply(command: ["rm", file.pathString], writableDirectories: [], strictness: .default)
            XCTAssertThrowsError(try Process.checkNonZeroExit(arguments: command)) { error in
                guard case ProcessResult.Error.nonZeroExit(let result) = error else {
                    return XCTFail("invalid error \(error)")
                }
                XCTAssertTrue(try! result.utf8stderrOutput().contains("Operation not permitted"))
            }
        }
    }

    // FIXME: this should not be allowed outside very specific programs
    func testExecuteAllowed() throws {
        #if !os(macOS)
        XCTSkip()
        #endif

        try withTemporaryDirectory { path in
            let file = path.appending(component: UUID().uuidString)
            XCTAssertNoThrow(try Process.checkNonZeroExit(arguments: ["touch", file.pathString]))
            XCTAssertNoThrow(try Process.checkNonZeroExit(arguments: ["chmod", "+x", file.pathString]))

            let command = Sandbox.apply(command: [file.pathString], writableDirectories: [], strictness: .default)
            XCTAssertNoThrow(try Process.checkNonZeroExit(arguments: command))
        }
    }
}
