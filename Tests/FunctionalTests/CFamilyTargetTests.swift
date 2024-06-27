//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Commands
import PackageGraph
import PackageLoading
import PackageModel
import SourceControl
import _InternalTestSupport
import Workspace
import XCTest

import class Basics.AsyncProcess

/// Asserts if a directory (recursively) contains a file.
private func XCTAssertDirectoryContainsFile(dir: AbsolutePath, filename: String, file: StaticString = #file, line: UInt = #line) {
    do {
        for entry in try walk(dir) {
            if entry.basename == filename { return }
        }
    } catch {
        XCTFail("Failed with error \(error)", file: file, line: line)
    }
    XCTFail("Directory \(dir) does not contain \(file)", file: file, line: line)
}

final class CFamilyTargetTestCase: XCTestCase {
    func testCLibraryWithSpaces() async throws {
        try await fixture(name: "CFamilyTargets/CLibraryWithSpaces") { fixturePath in
            await XCTAssertBuilds(fixturePath)
            let debugPath = fixturePath.appending(components: ".build", try UserToolchain.default.targetTriple.platformBuildPathComponent, "debug")
            XCTAssertDirectoryContainsFile(dir: debugPath, filename: "Bar.c.o")
            XCTAssertDirectoryContainsFile(dir: debugPath, filename: "Foo.c.o")
        }
    }

    func testCUsingCAndSwiftDep() async throws {
        try await fixture(name: "DependencyResolution/External/CUsingCDep") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")
            await XCTAssertBuilds(packageRoot)
            let debugPath = fixturePath.appending(components: "Bar", ".build", try UserToolchain.default.targetTriple.platformBuildPathComponent, "debug")
            XCTAssertDirectoryContainsFile(dir: debugPath, filename: "Sea.c.o")
            XCTAssertDirectoryContainsFile(dir: debugPath, filename: "Foo.c.o")
            let path = try SwiftPM.packagePath(for: "Foo", packageRoot: packageRoot)
            XCTAssertEqual(try GitRepository(path: path).getTags(), ["1.2.3"])
        }
    }

    func testModuleMapGenerationCases() async throws {
        try await fixture(name: "CFamilyTargets/ModuleMapGenerationCases") { fixturePath in
            await XCTAssertBuilds(fixturePath)
            let debugPath = fixturePath.appending(components: ".build", try UserToolchain.default.targetTriple.platformBuildPathComponent, "debug")
            XCTAssertDirectoryContainsFile(dir: debugPath, filename: "Jaz.c.o")
            XCTAssertDirectoryContainsFile(dir: debugPath, filename: "main.swift.o")
            XCTAssertDirectoryContainsFile(dir: debugPath, filename: "FlatInclude.c.o")
            XCTAssertDirectoryContainsFile(dir: debugPath, filename: "UmbrellaHeader.c.o")
        }
    }
    
    func testNoIncludeDirCheck() async throws {
        try await fixture(name: "CFamilyTargets/CLibraryNoIncludeDir") { fixturePath in
            await XCTAssertAsyncThrowsError(try await executeSwiftBuild(fixturePath), "This build should throw an error") { err in
                // The err.localizedDescription doesn't capture the detailed error string so interpolate
                let errStr = "\(err)"
                let missingIncludeDirStr = "\(ModuleError.invalidPublicHeadersDirectory("Cfactorial"))"
                XCTAssert(errStr.contains(missingIncludeDirStr))
            }
        }
    }

    func testCanForwardExtraFlagsToClang() async throws {
        // Try building a fixture which needs extra flags to be able to build.
        try await fixture(name: "CFamilyTargets/CDynamicLookup") { fixturePath in
            await XCTAssertBuilds(fixturePath, Xld: ["-undefined", "dynamic_lookup"])
            let debugPath = fixturePath.appending(components: ".build", try UserToolchain.default.targetTriple.platformBuildPathComponent, "debug")
            XCTAssertDirectoryContainsFile(dir: debugPath, filename: "Foo.c.o")
        }
    }

    func testObjectiveCPackageWithTestTarget() async throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        try await fixture(name: "CFamilyTargets/ObjCmacOSPackage") { fixturePath in
            // Build the package.
            await XCTAssertBuilds(fixturePath)
            XCTAssertDirectoryContainsFile(dir: fixturePath.appending(components: ".build", try UserToolchain.default.targetTriple.platformBuildPathComponent, "debug"), filename: "HelloWorldExample.m.o")
            // Run swift-test on package.
            await XCTAssertSwiftTest(fixturePath)
        }
    }
    
    func testCanBuildRelativeHeaderSearchPaths() async throws {
        try await fixture(name: "CFamilyTargets/CLibraryParentSearchPath") { fixturePath in
            await XCTAssertBuilds(fixturePath)
            XCTAssertDirectoryContainsFile(dir: fixturePath.appending(components: ".build", try UserToolchain.default.targetTriple.platformBuildPathComponent, "debug"), filename: "HeaderInclude.swiftmodule")
        }
    }
}
