/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import PackageModel
import SPMTestSupport
import TSCBasic
import XCTest

class TestDiscoveryTests: XCTestCase {
    func testBuild() throws {
        fixture(name: "Miscellaneous/TestDiscovery/Simple") { path in
            let (stdout, _) = try executeSwiftBuild(path)
            #if os(macOS)
            XCTAssertMatch(stdout, .contains("Merging module Simple"))
            #else
            XCTAssertMatch(stdout, .contains("Merging module Simple"))
            #endif
        }
    }

    func testDiscovery() throws {
        fixture(name: "Miscellaneous/TestDiscovery/Simple") { path in
            let (stdout, stderr) = try executeSwiftTest(path)
            #if os(macOS)
            XCTAssertMatch(stdout, .contains("Merging module Simple"))
            XCTAssertMatch(stderr, .contains("Executed 2 tests"))
            #else
            XCTAssertMatch(stdout, .contains("Merging module Simple"))
            XCTAssertMatch(stdout, .contains("Executed 2 tests"))
            #endif
        }
    }

    func testNonStandardName() throws {
        fixture(name: "Miscellaneous/TestDiscovery/hello world") { path in
            let (stdout, stderr) = try executeSwiftTest(path)
            #if os(macOS)
            XCTAssertMatch(stdout, .contains("Merging module hello_world"))
            XCTAssertMatch(stderr, .contains("Executed 1 test"))
            #else
            XCTAssertMatch(stdout, .contains("Merging module hello_world"))
            XCTAssertMatch(stdout, .contains("Executed 1 test"))
            #endif
        }
    }

    func testManifestOverride() throws {
        #if os(macOS)
        try XCTSkipIf(true)
        #else
        SwiftTarget.testManifestNames.forEach { name in
            fixture(name: "Miscellaneous/TestDiscovery/Simple") { path in
                let random = UUID().uuidString
                let manifestPath = path.appending(components: "Tests", name)
                try localFileSystem.writeFileContents(manifestPath, bytes: ByteString("print(\"\(random)\")".utf8))
                let (stdout, _) = try executeSwiftTest(path)
                XCTAssertMatch(stdout, .contains("Merging module Simple"))
                XCTAssertNoMatch(stdout, .contains("Executed 1 test"))
                XCTAssertMatch(stdout, .contains(random))
            }
        }
        #endif
    }

    func testManifestOverrideIgnored() throws {
        #if os(macOS)
        try XCTSkipIf(true)
        #else
        let name = SwiftTarget.testManifestNames.first!
        fixture(name: "Miscellaneous/TestDiscovery/Simple") { path in
            let manifestPath = path.appending(components: "Tests", name)
            try localFileSystem.writeFileContents(manifestPath, bytes: ByteString("fatalError(\"should not be called\")".utf8))
            let (stdout, _) = try executeSwiftTest(path, extraArgs: ["--enable-test-discovery"])
            XCTAssertMatch(stdout, .contains("Merging module Simple"))
            XCTAssertNoMatch(stdout, .contains("Executed 1 test"))
        }
        #endif
    }

    func testTestExtensions() throws {
        #if os(macOS)
        try XCTSkipIf(true)
        #else
        fixture(name: "Miscellaneous/TestDiscovery/Extensions") { path in
            let (stdout, _) = try executeSwiftTest(path, extraArgs: ["--enable-test-discovery"])
            XCTAssertMatch(stdout, .contains("Merging module Simple"))
            XCTAssertMatch(stdout, .contains("SimpleTests1.testExample1"))
            XCTAssertMatch(stdout, .contains("SimpleTests1.testExample1_a"))
            XCTAssertMatch(stdout, .contains("SimpleTests2.testExample2"))
            XCTAssertMatch(stdout, .contains("SimpleTests2.testExample2_a"))
            XCTAssertMatch(stdout, .contains("SimpleTests4.testExample"))
            XCTAssertMatch(stdout, .contains("SimpleTests4.testExample1"))
            XCTAssertMatch(stdout, .contains("SimpleTests4.testExample2"))
            XCTAssertMatch(stdout, .contains("Executed 7 tests"))
        }
        #endif
    }
}
