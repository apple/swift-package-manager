//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@testable import PackageModel
import XCTest

import struct Basics.AsyncProcessResult

final class MinimumDeploymentTargetTests: XCTestCase {
    func testDoesNotAssertWithNoOutput() throws {
        #if !os(macOS)
        // these tests eventually call `xcrun`.
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        let result = AsyncProcessResult(
            arguments: [],
            environment: [:],
            exitStatus: .terminated(code: 0),
            output: "".asResult,
            stderrOutput: "xcodebuild: error: SDK \"macosx\" cannot be located.".asResult
        )

        XCTAssertNil(try MinimumDeploymentTarget.computeXCTestMinimumDeploymentTarget(with: result, platform: .macOS))
    }

    func testThrowsWithNonPathOutput() throws {
        #if !os(macOS)
        // these tests eventually call `xcrun`.
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        let result = AsyncProcessResult(
            arguments: [],
            environment: [:],
            exitStatus: .terminated(code: 0),
            output: "some string".asResult,
            stderrOutput: "".asResult
        )

        XCTAssertThrowsError(try MinimumDeploymentTarget.computeXCTestMinimumDeploymentTarget(
            with: result,
            platform: .macOS
        ))
    }

    func testThrowsWithErrorForOutput() throws {
        #if !os(macOS)
        // these tests eventually call `xcrun`.
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        let result = AsyncProcessResult(
            arguments: [],
            environment: [:],
            exitStatus: .terminated(code: 0),
            output: .failure(DummyError()),
            stderrOutput: "".asResult
        )

        XCTAssertThrowsError(try MinimumDeploymentTarget.computeXCTestMinimumDeploymentTarget(
            with: result,
            platform: .macOS
        ))
    }
}

private struct DummyError: Error {}

extension String {
    fileprivate var asResult: Result<[UInt8], Error> {
        .success(Array(utf8))
    }
}
