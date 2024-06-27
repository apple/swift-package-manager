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

import Basics
import PackageModel
import _InternalTestSupport
import XCTest
import class Basics.AsyncProcess
import typealias TSCBasic.ProcessEnvironmentBlock

/// Functional tests of incremental builds.  These are fairly ad hoc at this
/// point, and because of the time they take, they need to be kept minimal.
/// There are at least a couple of ways in which this could be improved to a
/// greater or lesser degree:
///
/// a) we could look at the llbuild manifest to determine that the right fine-
///    grained dependencies exist (however, this feels a bit too much like a
///    "test that we wrote what we wrote" kind of test, i.e. it doesn't really
///    test that the net effect of triggering rebuilds is achieved; it is also
///    hard to write such tests in a black-box manner, i.e. in terms of the
///    desired effect
///
/// b) a much better way would be if llbuild could quickly report on what files
///    it would update if a build were to be triggered;  this would be a lot
///    faster than actually doing the build, but would of course also bake in
///    an assumption that the needs-to-be-rebuilt state of a file system entity
///    could be determined without running any of the commands (i.e. it would
///    assume that there's no feedback during the build)
///
final class IncrementalBuildTests: XCTestCase {

    func testIncrementalSingleModuleCLibraryInSources() async throws {
        try XCTSkipIf(!UserToolchain.default.supportsSDKDependentTests(), "skipping because test environment doesn't support this test")
        try await fixture(name: "CFamilyTargets/CLibrarySources") { fixturePath in
            // Build it once and capture the log (this will be a full build).
            let (fullLog, _) = try await executeSwiftBuild(fixturePath)

            // Check various things that we expect to see in the full build log.
            // FIXME:  This is specific to the format of the log output, which
            // is quite unfortunate but not easily avoidable at the moment.
            XCTAssertMatch(fullLog, .contains("Compiling CLibrarySources Foo.c"))

            let llbuildManifest = fixturePath.appending(components: ".build", "debug.yaml")

            // Modify the source file in a way that changes its size so that the low-level
            // build system can detect the change (the timestamp change might be too small
            // for the granularity of the file system to represent as distinct values).
            let sourceFile = fixturePath.appending(components: "Sources", "Foo.c")
            try localFileSystem.writeFileContents(
                sourceFile,
                string: "\(try localFileSystem.readFileContents(sourceFile))\n"
            )

            // Read the first llbuild manifest.
            let llbuildContents1: String = try localFileSystem.readFileContents(llbuildManifest)

            // Now build again.  This should be an incremental build.
            let (log2, _) = try await executeSwiftBuild(fixturePath)
            XCTAssertMatch(log2, .contains("Compiling CLibrarySources Foo.c"))

            // Read the second llbuild manifest.
            let llbuildContents2: String = try localFileSystem.readFileContents(llbuildManifest)

            // Now build again without changing anything.  This should be a null
            // build.
            let (log3, _) = try await executeSwiftBuild(fixturePath)
            XCTAssertNoMatch(log3, .contains("Compiling CLibrarySources Foo.c"))

            // Read the third llbuild manifest.
            let llbuildContents3: String = try localFileSystem.readFileContents(llbuildManifest)

            XCTAssertEqual(llbuildContents1, llbuildContents2)
            XCTAssertEqual(llbuildContents2, llbuildContents3)

            // Modify the header file in a way that changes its size so that the low-level
            // build system can detect the change (the timestamp change might be too small
            // for the granularity of the file system to represent as distinct values).
            let headerFile = fixturePath.appending(components: "Sources", "include", "Foo.h")
            try localFileSystem.writeFileContents(
                headerFile,
                string: "\(try localFileSystem.readFileContents(headerFile))\n"
            )

            // Now build again.  This should be an incremental build.
            let (log4, _) = try await executeSwiftBuild(fixturePath)
            XCTAssertMatch(log4, .contains("Compiling CLibrarySources Foo.c"))
        }
    }

    func testBuildManifestCaching() async throws {
        try XCTSkipIf(!UserToolchain.default.supportsSDKDependentTests(), "skipping because test environment doesn't support this test")
        try await fixture(name: "ValidLayouts/SingleModule/Library") { fixturePath in
            @discardableResult
            func build() async throws -> String {
                return try await executeSwiftBuild(fixturePath).stdout
            }

            // Perform a full build.
            let log1 = try await build()
            XCTAssertMatch(log1, .contains("Compiling Library"))

            // Ensure manifest caching kicks in.
            let log2 =  try await build()
            XCTAssertMatch(log2, .contains("Planning build"))

            // Check that we're not re-planning when nothing has changed.
            let log3 = try await build()
            XCTAssertNoMatch(log3, .contains("Planning build"))

            // Check that we do run planning when a new source file is added.
            let sourceFile = fixturePath.appending(components: "Sources", "Library", "new.swift")
            try localFileSystem.writeFileContents(sourceFile, bytes: "")
            let log4 = try await build()
            XCTAssertMatch(log4, .contains("Compiling Library"))
            XCTAssertMatch(log4, .contains("Planning build"))

            // Check that we don't run planning when a source file is modified.
            try localFileSystem.writeFileContents(sourceFile, bytes: "\n\n\n\n")
            let log5 = try await build()
            XCTAssertNoMatch(log5, .contains("Planning build"))
        }
    }

    func testDisableBuildManifestCaching() async throws {
        try XCTSkipIf(!UserToolchain.default.supportsSDKDependentTests(), "skipping because test environment doesn't support this test")
        try await fixture(name: "ValidLayouts/SingleModule/Library") { fixturePath in
            @discardableResult
            func build() async throws -> String {
                return try await executeSwiftBuild(fixturePath, extraArgs: ["--disable-build-manifest-caching"]).stdout
            }

            // Perform a full build.
            let log1 = try await build()
            XCTAssertMatch(log1, .contains("Compiling Library"))

            // Ensure manifest caching does not kick in.
            let log2 = try await build()
            XCTAssertNoMatch(log2, .contains("Planning build"))
        }
    }
    // testing the fix for tracking SDK dependencies to avoid triggering rebuilds when the SDK changes (rdar://115777026)
    func testSDKTracking() async throws {
#if os(macOS)
        try XCTSkipIf(!UserToolchain.default.supportsSDKDependentTests(), "skipping because test environment doesn't support this test")

        try await fixture(name: "ValidLayouts/SingleModule/Library") { fixturePath in
            let dummySwiftcPath = SwiftPM.xctestBinaryPath(for: "dummy-swiftc")
            let swiftCompilerPath = try UserToolchain.default.swiftCompilerPath
            let environment: Environment = [
                "SWIFT_EXEC": dummySwiftcPath.pathString,
                "SWIFT_ORIGINAL_PATH": swiftCompilerPath.pathString
            ]
            let sdkPathStr = try await AsyncProcess.checkNonZeroExit(
                arguments: ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
                environment: environment
            ).spm_chomp()

            let newSdkPathStr = "/tmp/../\(sdkPathStr)"
            // Perform a full build again because SDK changed.
            let log1 = try await executeSwiftBuild(fixturePath, env: ["SDKROOT": newSdkPathStr]).stdout
            XCTAssertMatch(log1, .contains("Compiling Library"))
        }
#endif
    }
}
