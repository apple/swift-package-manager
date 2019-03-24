/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import XCTest

import Basic
import TestSupport

class ProcessEnvTests: XCTestCase {

    func testEnvVars() throws {
        let key = "SWIFTPM_TEST_FOO"
        XCTAssertEqual(ProcessEnv.vars[key], nil)
        try ProcessEnv.setVar(key, value: "BAR")
        XCTAssertEqual(ProcessEnv.vars[key], "BAR")
        try ProcessEnv.unsetVar(key)
        XCTAssertEqual(ProcessEnv.vars[key], nil)
    }

    func testChdir() throws {
        mktmpdir { path in
            let path = resolveSymlinks(path)
            try ProcessEnv.chdir(path)
            XCTAssertEqual(ProcessEnv.cwd, path)
        }
    }
}
