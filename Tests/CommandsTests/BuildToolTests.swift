/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest

import SPMTestSupport
import TSCBasic
import SPMBuildCore
import Commands
import Workspace

struct BuildResult {
    let binPath: AbsolutePath
    let output: String
    let binContents: [String]
}

final class BuildToolTests: XCTestCase {
    @discardableResult
    private func execute(
        _ args: [String],
        packagePath: AbsolutePath? = nil
    ) throws -> (stdout: String, stderr: String) {
        return try SwiftPMProduct.SwiftBuild.execute(args, packagePath: packagePath)
    }

    func build(_ args: [String], packagePath: AbsolutePath? = nil) throws -> BuildResult {
        let (output, _) = try execute(args, packagePath: packagePath)
        defer { try! SwiftPMProduct.SwiftPackage.execute(["clean"], packagePath: packagePath) }
        let (binPathOutput, _) = try execute(["--show-bin-path"], packagePath: packagePath)
        let binPath = AbsolutePath(binPathOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        let binContents = try localFileSystem.getDirectoryContents(binPath)
        return BuildResult(binPath: binPath, output: output, binContents: binContents)
    }
    
    func testUsage() throws {
        let stdout = try execute(["-help"]).stdout
        XCTAssert(stdout.contains("USAGE: swift build"), "got stdout:\n" + stdout)
    }

    func testSeeAlso() throws {
        let stdout = try execute(["--help"]).stdout
        XCTAssert(stdout.contains("SEE ALSO: swift run, swift package, swift test"), "got stdout:\n" + stdout)
    }

    func testVersion() throws {
        let stdout = try execute(["--version"]).stdout
        XCTAssert(stdout.contains("Swift Package Manager"), "got stdout:\n" + stdout)
    }

    func testCreatingSanitizers() throws {
        for sanitizer in Sanitizer.allCases {
            XCTAssertEqual(sanitizer, try Sanitizer(argument: sanitizer.shortName))
        }
    }

    func testInvalidSanitizer() throws {
        do {
            _ = try Sanitizer(argument: "invalid")
            XCTFail("Should have failed to create Sanitizer")
        } catch let error as StringError {
            XCTAssertEqual(
                error.description, "valid sanitizers: address, thread, undefined, scudo")
        }
    }

    func testBinPathAndSymlink() throws {
        fixture(name: "ValidLayouts/SingleModule/ExecutableNew") { path in
            let fullPath = resolveSymlinks(path)
            let targetPath = fullPath.appending(components: ".build", Resources.default.toolchain.triple.platformBuildPathComponent())
            let xcbuildTargetPath = fullPath.appending(components: ".build", "apple")
            XCTAssertEqual(try execute(["--show-bin-path"], packagePath: fullPath).stdout,
                           "\(targetPath.appending(component: "debug").pathString)\n")
            XCTAssertEqual(try execute(["-c", "release", "--show-bin-path"], packagePath: fullPath).stdout,
                           "\(targetPath.appending(component: "release").pathString)\n")

            // Print correct path when building with XCBuild.
            let xcodeDebugOutput = try execute(["--build-system", "xcode", "--show-bin-path"], packagePath: fullPath).stdout
            let xcodeReleaseOutput = try execute(["--build-system", "xcode", "-c", "release", "--show-bin-path"], packagePath: fullPath).stdout
          #if os(macOS)
            XCTAssertEqual(xcodeDebugOutput, "\(xcbuildTargetPath.appending(components: "Products", "Debug").pathString)\n")
            XCTAssertEqual(xcodeReleaseOutput, "\(xcbuildTargetPath.appending(components: "Products", "Release").pathString)\n")
          #else
            XCTAssertEqual(xcodeDebugOutput, "\(targetPath.appending(component: "debug").pathString)\n")
            XCTAssertEqual(xcodeReleaseOutput, "\(targetPath.appending(component: "release").pathString)\n")
          #endif

            // Test symlink.
            _ = try execute([], packagePath: fullPath)
            XCTAssertEqual(resolveSymlinks(fullPath.appending(components: ".build", "debug")),
                           targetPath.appending(component: "debug"))
            _ = try execute(["-c", "release"], packagePath: fullPath)
            XCTAssertEqual(resolveSymlinks(fullPath.appending(components: ".build", "release")),
                           targetPath.appending(component: "release"))
        }
    }

    func testProductAndTarget() throws {
        fixture(name: "Miscellaneous/MultipleExecutables") { path in
            let fullPath = resolveSymlinks(path)

            do {
                let result = try build(["--product", "exec1"], packagePath: fullPath)
                XCTAssert(result.binContents.contains("exec1"))
                XCTAssert(!result.binContents.contains("exec2.build"))
            } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                XCTFail(stderr)
            }

            do {
                let (_, stderr) = try execute(["--product", "lib1"], packagePath: fullPath)
                try SwiftPMProduct.SwiftPackage.execute(["clean"], packagePath: fullPath)
                XCTAssertMatch(stderr, .contains("'--product' cannot be used with the automatic product 'lib1'; building the default target instead"))
            }

            do {
                let result = try build(["--target", "exec2"], packagePath: fullPath)
                XCTAssert(result.binContents.contains("exec2.build"))
                XCTAssert(!result.binContents.contains("exec1"))
            } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                XCTFail(stderr)
            }

            do {
                _ = try execute(["--product", "exec1", "--target", "exec2"], packagePath: path)
                XCTFail("Expected to fail")
            } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                XCTAssertEqual(stderr, "error: '--product' and '--target' are mutually exclusive\n")
            }

            do {
                _ = try execute(["--product", "exec1", "--build-tests"], packagePath: path)
                XCTFail("Expected to fail")
            } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                XCTAssertEqual(stderr, "error: '--product' and '--build-tests' are mutually exclusive\n")
            }

            do {
                _ = try execute(["--build-tests", "--target", "exec2"], packagePath: path)
                XCTFail("Expected to fail")
            } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                XCTAssertEqual(stderr, "error: '--target' and '--build-tests' are mutually exclusive\n")
            }

            do {
                _ = try execute(["--build-tests", "--target", "exec2", "--product", "exec1"], packagePath: path)
                XCTFail("Expected to fail")
            } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                XCTAssertEqual(stderr, "error: '--product', '--target', and '--build-tests' are mutually exclusive\n")
            }

            do {
                _ = try execute(["--product", "UnkownProduct"], packagePath: path)
                XCTFail("Expected to fail")
            } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                XCTAssertEqual(stderr, "error: no product named 'UnkownProduct'\n")
            }

            do {
                _ = try execute(["--target", "UnkownTarget"], packagePath: path)
                XCTFail("Expected to fail")
            } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                XCTAssertEqual(stderr, "error: no target named 'UnkownTarget'\n")
            }
        }
    }
    
    func testAtMainSupport() {
        fixture(name: "Miscellaneous/AtMainSupport") { path in
            let fullPath = resolveSymlinks(path)
            do {
                let result = try build(["--product", "ClangExecSingleFile"], packagePath: fullPath)
                XCTAssert(result.binContents.contains("ClangExecSingleFile"))
            } catch SwiftPMProductError.executionFailure(_, let stdout, let stderr) {
                XCTFail(stdout + "\n" + stderr)
            }

            do {
                let result = try build(["--product", "SwiftExecSingleFile"], packagePath: fullPath)
                XCTAssert(result.binContents.contains("SwiftExecSingleFile"))
            } catch SwiftPMProductError.executionFailure(_, let stdout, let stderr) {
                XCTFail(stdout + "\n" + stderr)
            }

            do {
                let result = try build(["--product", "SwiftExecMultiFile"], packagePath: fullPath)
                XCTAssert(result.binContents.contains("SwiftExecMultiFile"))
            } catch SwiftPMProductError.executionFailure(_, let stdout, let stderr) {
                XCTFail(stdout + "\n" + stderr)
            }
        }
    }

    func testNonReachableProductsAndTargetsFunctional() {
        fixture(name: "Miscellaneous/UnreachableTargets") { path in
            let aPath = path.appending(component: "A")

            do {
                let result = try build([], packagePath: aPath)
                XCTAssert(!result.binContents.contains("bexec"))
                XCTAssert(!result.binContents.contains("BTarget2.build"))
                XCTAssert(!result.binContents.contains("cexec"))
                XCTAssert(!result.binContents.contains("CTarget.build"))
            } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                XCTFail(stderr)
            }

            // Dependency contains a dependent product

            do {
                let result = try build(["--product", "bexec"], packagePath: aPath)
                XCTAssert(result.binContents.contains("BTarget2.build"))
                XCTAssert(result.binContents.contains("bexec"))
                XCTAssert(!result.binContents.contains("aexec"))
                XCTAssert(!result.binContents.contains("ATarget.build"))
                XCTAssert(!result.binContents.contains("BLibrary.a"))

                // FIXME: We create the modulemap during build planning, hence this uglyness.
                let bTargetBuildDir = ((try? localFileSystem.getDirectoryContents(result.binPath.appending(component: "BTarget1.build"))) ?? []).filter{ $0 != moduleMapFilename }
                XCTAssertEqual(bTargetBuildDir, [])

                XCTAssert(!result.binContents.contains("cexec"))
                XCTAssert(!result.binContents.contains("CTarget.build"))

                // Also make sure we didn't emit parseable module interfaces
                // (do this here to avoid doing a second build in
                // testParseableInterfaces().
                XCTAssert(!result.binContents.contains("ATarget.swiftinterface"))
                XCTAssert(!result.binContents.contains("BTarget.swiftinterface"))
                XCTAssert(!result.binContents.contains("CTarget.swiftinterface"))
            } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                XCTFail(stderr)
            }
        }
    }

    func testParseableInterfaces() {
        fixture(name: "Miscellaneous/ParseableInterfaces") { path in
            do {
                let result = try build(["--enable-parseable-module-interfaces"], packagePath: path)
                XCTAssert(result.binContents.contains("A.swiftinterface"))
                XCTAssert(result.binContents.contains("B.swiftinterface"))
            } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                XCTFail(stderr)
            }
        }
    }

    func testAutomaticParseableInterfacesWithLibraryEvolution() {
        fixture(name: "Miscellaneous/LibraryEvolution") { path in
            do {
                let result = try build([], packagePath: path)
                XCTAssert(result.binContents.contains("A.swiftinterface"))
                XCTAssert(result.binContents.contains("B.swiftinterface"))
            } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                XCTFail(stderr)
            }
        }
    }

    func testBuildCompleteMessage() {
        fixture(name: "DependencyResolution/Internal/Simple") { path in
            do {
                let result = try execute([], packagePath: path)
                // Number of steps must be greater than 0. e.g., [8/8] Build complete!
                XCTAssertMatch(result.stdout, .regex("\\[[1-9][0-9]*\\/[1-9][0-9]*\\] Build complete!"))
            }

            do {
                let result = try execute([], packagePath: path)
                // test second time, to make sure message is presented even when nothing to build (cached)
                XCTAssertTrue(result.stdout.contains("[0/0] Build complete!"), result.stdout)
            }
        }
    }
}
