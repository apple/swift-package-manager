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

import PackageModel
import _InternalTestSupport
import XCTest

import var TSCBasic.localFileSystem

final class BuildSystemDelegateTests: XCTestCase {
    func testDoNotFilterLinkerDiagnostics() async throws {
        try UserToolchain.default.skipUnlessAtLeastSwift6()
        try XCTSkipIf(!UserToolchain.default.supportsSDKDependentTests(), "skipping because test environment doesn't support this test")
        try await fixture(name: "Miscellaneous/DoNotFilterLinkerDiagnostics") { fixturePath in
            #if !os(macOS)
            // These linker diagnostics are only produced on macOS.
            try XCTSkipIf(true, "test is only supported on macOS")
            #endif
            let (fullLog, _) = try await executeSwiftBuild(fixturePath)
            XCTAssertTrue(fullLog.contains("ld: warning: search path 'foobar' not found"), "log didn't contain expected linker diagnostics")
        }
    }

    func testFilterNonFatalCodesignMessages() async throws {
        try XCTSkipIf(!UserToolchain.default.supportsSDKDependentTests(), "skipping because test environment doesn't support this test")
        // Note: we can re-use the `TestableExe` fixture here since we just need an executable.
        try await fixture(name: "Miscellaneous/TestableExe") { fixturePath in
            _ = try await executeSwiftBuild(fixturePath)
            let execPath = fixturePath.appending(components: ".build", "debug", "TestableExe1")
            XCTAssertTrue(localFileSystem.exists(execPath), "executable not found at '\(execPath)'")
            try localFileSystem.removeFileTree(execPath)
            let (fullLog, _) = try await executeSwiftBuild(fixturePath)
            XCTAssertFalse(fullLog.contains("replacing existing signature"), "log contained non-fatal codesigning messages")
        }
    }
}
