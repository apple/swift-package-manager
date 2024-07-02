//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
@testable import Commands
@testable import CoreCommands
import PackageGraph
import PackageLoading
import PackageModel
import SPMBuildCore
import SPMTestSupport
import Workspace
import XCTest

struct BuildResult {
    let binPath: AbsolutePath
    let stdout: String
    let stderr: String
    let binContents: [String]
    let moduleContents: [String]
}

final class BuildCommandTests: CommandsTestCase {
    @discardableResult
    private func execute(
        _ args: [String] = [],
        environment: Environment? = nil,
        packagePath: AbsolutePath? = nil
    ) async throws -> (stdout: String, stderr: String) {
        try await SwiftPM.Build.execute(args, packagePath: packagePath, env: environment)
    }

    func build(_ args: [String], packagePath: AbsolutePath? = nil, isRelease: Bool = false, cleanAfterward: Bool = true) async throws -> BuildResult {
        do {
            let buildConfigurationArguments = isRelease ? ["-c", "release"] : []
            let (stdout, stderr) = try await execute(args + buildConfigurationArguments, packagePath: packagePath)
            defer {
            }
            let (binPathOutput, _) = try await execute(
                ["--show-bin-path"] + buildConfigurationArguments,
                packagePath: packagePath
            )
            let binPath = try AbsolutePath(validating: binPathOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            let binContents = try localFileSystem.getDirectoryContents(binPath).filter {
                guard let contents = try? localFileSystem.getDirectoryContents(binPath.appending(component: $0)) else {
                    return true
                }
                // Filter directories which only contain an output file map since we didn't build anything for those which
                // is what `binContents` is meant to represent.
                return contents != ["output-file-map.json"]
            }
            let moduleContents = (try? localFileSystem.getDirectoryContents(binPath.appending(component: "Modules"))) ?? []

            if cleanAfterward {
                try! await SwiftPM.Package.execute(["clean"], packagePath: packagePath)
            }
            return BuildResult(
                binPath: binPath,
                stdout: stdout,
                stderr: stderr,
                binContents: binContents,
                moduleContents: moduleContents
            )
        } catch {
            if cleanAfterward {
                try! await SwiftPM.Package.execute(["clean"], packagePath: packagePath)
            }
            throw error
        }
    }

    func testUsage() async throws {
        let stdout = try await execute(["-help"]).stdout
        XCTAssertMatch(stdout, .contains("USAGE: swift build"))
    }

    func testSeeAlso() async throws {
        let stdout = try await execute(["--help"]).stdout
        XCTAssertMatch(stdout, .contains("SEE ALSO: swift run, swift package, swift test"))
    }

    func testVersion() async throws {
        let stdout = try await execute(["--version"]).stdout
        XCTAssertMatch(stdout, .contains("Swift Package Manager"))
    }

    func testCreatingSanitizers() throws {
        for sanitizer in Sanitizer.allCases {
            XCTAssertEqual(sanitizer, Sanitizer(argument: sanitizer.shortName))
        }
    }

    func testInvalidSanitizer() throws {
        XCTAssertNil(Sanitizer(argument: "invalid"))
    }

    func testImportOfMissedDepWarning() async throws {
        // Verify the warning flow
        try await fixture(name: "Miscellaneous/ImportOfMissingDependency") { path in
            let fullPath = try resolveSymlinks(path)
            await XCTAssertAsyncThrowsError(try await self.build(
                ["--explicit-target-dependency-import-check=warn"],
                packagePath: fullPath
            )) { error in
                guard case SwiftPMError.executionFailure(_, let stdout, let stderr) = error else {
                    XCTFail()
                    return
                }

                XCTAssertTrue(
                    stderr.contains(
                        "warning: Target A imports another target (B) in the package without declaring it a dependency."
                    ),
                    "got stdout: \(stdout), stderr: \(stderr)"
                )
            }
        }

        // Verify the error flow
        try await fixture(name: "Miscellaneous/ImportOfMissingDependency") { path in
            let fullPath = try resolveSymlinks(path)
            await XCTAssertAsyncThrowsError(try await self.build(
                ["--explicit-target-dependency-import-check=error"],
                packagePath: fullPath
            )) { error in
                guard case SwiftPMError.executionFailure(_, _, let stderr) = error else {
                    XCTFail()
                    return
                }

                XCTAssertTrue(
                    stderr.contains(
                        "error: Target A imports another target (B) in the package without declaring it a dependency."
                    ),
                    "got stdout: \(stdout), stderr: \(stderr)"
                )
            }
        }

        // Verify that the default does not run the check
        try await fixture(name: "Miscellaneous/ImportOfMissingDependency") { path in
            let fullPath = try resolveSymlinks(path)
            await XCTAssertAsyncThrowsError(try await self.build([], packagePath: fullPath)) { error in
                guard case SwiftPMError.executionFailure(_, _, let stderr) = error else {
                    XCTFail()
                    return
                }
                XCTAssertFalse(
                    stderr.contains(
                        "warning: Target A imports another target (B) in the package without declaring it a dependency."
                    ),
                    "got stdout: \(stdout), stderr: \(stderr)"
                )
            }
        }
    }

    func testBinPathAndSymlink() async throws {
        try await fixture(name: "ValidLayouts/SingleModule/ExecutableNew") { fixturePath in
            let fullPath = try resolveSymlinks(fixturePath)
            let targetPath = try fullPath.appending(
                components: ".build",
                UserToolchain.default.targetTriple.platformBuildPathComponent
            )
            let xcbuildTargetPath = fullPath.appending(components: ".build", "apple")
            try await XCTAssertAsyncEqual(
                try await self.execute(["--show-bin-path"], packagePath: fullPath).stdout,
                "\(targetPath.appending("debug").pathString)\n"
            )
            try await XCTAssertAsyncEqual(
                try await self.execute(["-c", "release", "--show-bin-path"], packagePath: fullPath).stdout,
                "\(targetPath.appending("release").pathString)\n"
            )

            // Print correct path when building with XCBuild.
            #if os(macOS)
            let xcodeDebugOutput = try await execute(["--build-system", "xcode", "--show-bin-path"], packagePath: fullPath)
                .stdout
            let xcodeReleaseOutput = try await execute(
                ["--build-system", "xcode", "-c", "release", "--show-bin-path"],
                packagePath: fullPath
            ).stdout
            XCTAssertEqual(
                xcodeDebugOutput,
                "\(xcbuildTargetPath.appending(components: "Products", "Debug").pathString)\n"
            )
            XCTAssertEqual(
                xcodeReleaseOutput,
                "\(xcbuildTargetPath.appending(components: "Products", "Release").pathString)\n"
            )
            #endif

            // Test symlink.
            try await self.execute(packagePath: fullPath)
            XCTAssertEqual(
                try resolveSymlinks(fullPath.appending(components: ".build", "debug")),
                targetPath.appending("debug")
            )
            try await self.execute(["-c", "release"], packagePath: fullPath)
            XCTAssertEqual(
                try resolveSymlinks(fullPath.appending(components: ".build", "release")),
                targetPath.appending("release")
            )
        }
    }

    func testProductAndTarget() async throws {
        try await fixture(name: "Miscellaneous/MultipleExecutables") { fixturePath in
            let fullPath = try resolveSymlinks(fixturePath)

            do {
                let result = try await build(["--product", "exec1"], packagePath: fullPath)
                XCTAssertMatch(result.binContents, ["exec1"])
                XCTAssertNoMatch(result.binContents, ["exec2.build"])
            }

            do {
                let (_, stderr) = try await execute(["--product", "lib1"], packagePath: fullPath)
                try await SwiftPM.Package.execute(["clean"], packagePath: fullPath)
                XCTAssertMatch(
                    stderr,
                    .contains(
                        "'--product' cannot be used with the automatic product 'lib1'; building the default target instead"
                    )
                )
            }

            do {
                let result = try await build(["--target", "exec2"], packagePath: fullPath)
                XCTAssertMatch(result.binContents, ["exec2.build"])
                XCTAssertNoMatch(result.binContents, ["exec1"])
            }

            await XCTAssertThrowsCommandExecutionError(try await self.execute(
                ["--product", "exec1", "--target", "exec2"],
                packagePath: fixturePath
            )) { error in
                XCTAssertMatch(error.stderr, .contains("error: '--product' and '--target' are mutually exclusive"))
            }

            await XCTAssertThrowsCommandExecutionError(try await self.execute(
                ["--product", "exec1", "--build-tests"],
                packagePath: fixturePath
            )) { error in
                XCTAssertMatch(error.stderr, .contains("error: '--product' and '--build-tests' are mutually exclusive"))
            }

            await XCTAssertThrowsCommandExecutionError(try await self.execute(
                ["--build-tests", "--target", "exec2"],
                packagePath: fixturePath
            )) { error in
                XCTAssertMatch(error.stderr, .contains("error: '--target' and '--build-tests' are mutually exclusive"))
            }

            await XCTAssertThrowsCommandExecutionError(try await self.execute(
                ["--build-tests", "--target", "exec2", "--product", "exec1"],
                packagePath: fixturePath
            )) { error in
                XCTAssertMatch(
                    error.stderr,
                    .contains("error: '--product', '--target', and '--build-tests' are mutually exclusive")
                )
            }

            await XCTAssertThrowsCommandExecutionError(try await self.execute(
                ["--product", "UnkownProduct"],
                packagePath: fixturePath
            )) { error in
                XCTAssertMatch(error.stderr, .contains("error: no product named 'UnkownProduct'"))
            }

            await XCTAssertThrowsCommandExecutionError(try await self.execute(
                ["--target", "UnkownTarget"],
                packagePath: fixturePath
            )) { error in
                XCTAssertMatch(error.stderr, .contains("error: no target named 'UnkownTarget'"))
            }
        }
    }

    func testAtMainSupport() async throws {
        try await fixture(name: "Miscellaneous/AtMainSupport") { fixturePath in
            let fullPath = try resolveSymlinks(fixturePath)

            do {
                let result = try await build(["--product", "ClangExecSingleFile"], packagePath: fullPath)
                XCTAssertMatch(result.binContents, ["ClangExecSingleFile"])
            }

            do {
                let result = try await build(["--product", "SwiftExecSingleFile"], packagePath: fullPath)
                XCTAssertMatch(result.binContents, ["SwiftExecSingleFile"])
            }

            do {
                let result = try await build(["--product", "SwiftExecMultiFile"], packagePath: fullPath)
                XCTAssertMatch(result.binContents, ["SwiftExecMultiFile"])
            }
        }
    }

    func testNonReachableProductsAndTargetsFunctional() async throws {
        try await fixture(name: "Miscellaneous/UnreachableTargets") { fixturePath in
            let aPath = fixturePath.appending("A")

            do {
                let result = try await build([], packagePath: aPath)
                XCTAssertNoMatch(result.binContents, ["bexec"])
                XCTAssertNoMatch(result.binContents, ["BTarget2.build"])
                XCTAssertNoMatch(result.binContents, ["cexec"])
                XCTAssertNoMatch(result.binContents, ["CTarget.build"])
            }

            // Dependency contains a dependent product

            do {
                let result = try await build(["--product", "bexec"], packagePath: aPath)
                XCTAssertMatch(result.binContents, ["BTarget2.build"])
                XCTAssertMatch(result.binContents, ["bexec"])
                XCTAssertNoMatch(result.binContents, ["aexec"])
                XCTAssertNoMatch(result.binContents, ["ATarget.build"])
                XCTAssertNoMatch(result.binContents, ["BLibrary.a"])

                // FIXME: We create the modulemap during build planning, hence this ugliness.
                let bTargetBuildDir =
                    ((try? localFileSystem.getDirectoryContents(result.binPath.appending("BTarget1.build"))) ?? [])
                        .filter { $0 != moduleMapFilename }
                XCTAssertTrue(bTargetBuildDir.isEmpty, "bTargetBuildDir should be empty")

                XCTAssertNoMatch(result.binContents, ["cexec"])
                XCTAssertNoMatch(result.binContents, ["CTarget.build"])

                // Also make sure we didn't emit parseable module interfaces
                // (do this here to avoid doing a second build in
                // testParseableInterfaces().
                XCTAssertNoMatch(result.moduleContents, ["ATarget.swiftinterface"])
                XCTAssertNoMatch(result.moduleContents, ["BTarget.swiftinterface"])
                XCTAssertNoMatch(result.moduleContents, ["CTarget.swiftinterface"])
            }
        }
    }

    func testParseableInterfaces() async throws {
        try await fixture(name: "Miscellaneous/ParseableInterfaces") { fixturePath in
            do {
                let result = try await build(["--enable-parseable-module-interfaces"], packagePath: fixturePath)
                XCTAssertMatch(result.moduleContents, ["A.swiftinterface"])
                XCTAssertMatch(result.moduleContents, ["B.swiftinterface"])
            } catch SwiftPMError.executionFailure(_, _, let stderr) {
                XCTFail(stderr)
            }
        }
    }

    func testAutomaticParseableInterfacesWithLibraryEvolution() async throws {
        try await fixture(name: "Miscellaneous/LibraryEvolution") { fixturePath in
            do {
                let result = try await build([], packagePath: fixturePath)
                XCTAssertMatch(result.moduleContents, ["A.swiftinterface"])
                XCTAssertMatch(result.moduleContents, ["B.swiftinterface"])
            }
        }
    }

    func testBuildCompleteMessage() async throws {
        try XCTSkipIf(true, "This test fails to match the 'Compiling' regex; rdar://101815761")

        try await fixture(name: "DependencyResolution/Internal/Simple") { fixturePath in
            do {
                let result = try await execute(packagePath: fixturePath)
                XCTAssertMatch(result.stdout, .regex("\\[[1-9][0-9]*\\/[1-9][0-9]*\\] Compiling"))
                let lines = result.stdout.split(whereSeparator: { $0.isNewline })
                XCTAssertMatch(String(lines.last!), .regex("Build complete! \\([0-9]*\\.[0-9]*s\\)"))
            }

            do {
                // test second time, to stabilize the cache
                try await self.execute(packagePath: fixturePath)
            }

            do {
                // test third time, to make sure message is presented even when nothing to build (cached)
                let result = try await execute(packagePath: fixturePath)
                XCTAssertNoMatch(result.stdout, .regex("\\[[1-9][0-9]*\\/[1-9][0-9]*\\] Compiling"))
                let lines = result.stdout.split(whereSeparator: { $0.isNewline })
                XCTAssertMatch(String(lines.last!), .regex("Build complete! \\([0-9]*\\.[0-9]*s\\)"))
            }
        }
    }

    func testBuildStartMessage() async throws {
        try await fixture(name: "DependencyResolution/Internal/Simple") { fixturePath in
            do {
                let result = try await execute(["-c", "debug"], packagePath: fixturePath)
                XCTAssertMatch(result.stdout, .prefix("Building for debugging"))
            }

            do {
                let result = try await execute(["-c", "release"], packagePath: fixturePath)
                XCTAssertMatch(result.stdout, .prefix("Building for production"))
            }
        }
    }

    func testXcodeBuildSystemDefaultSettings() async throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test requires `xcbuild` and is therefore only supported on macOS")
        #endif
        try await fixture(name: "ValidLayouts/SingleModule/ExecutableNew") { fixturePath in
            // try await building using XCBuild with default parameters.  This should succeed.  We build verbosely so we get
            // full command lines.
            let defaultOutput = try await execute(["-c", "debug", "-v"], packagePath: fixturePath).stdout

            // Look for certain things in the output from XCBuild.
            XCTAssertMatch(
                defaultOutput,
                try .contains("-target \(UserToolchain.default.targetTriple.tripleString(forPlatformVersion: ""))")
            )
        }
    }

    func testXcodeBuildSystemWithAdditionalBuildFlags() async throws {
        try XCTSkipIf(
            true,
            "Disabled for now because it is hitting 'IR generation failure: Cannot read legacy layout file' in CI (rdar://88828632)"
        )

        #if !os(macOS)
        try XCTSkipIf(true, "test requires `xcbuild` and is therefore only supported on macOS")
        #endif
        try await fixture(name: "ValidLayouts/SingleModule/ExecutableMixed") { fixturePath in
            // try await building using XCBuild with additional flags.  This should succeed.  We build verbosely so we get
            // full command lines.
            let defaultOutput = try await execute(
                [
                    "--build-system", "xcode",
                    "-c", "debug", "-v",
                    "-Xlinker", "-rpath", "-Xlinker", "/fakerpath",
                    "-Xcc", "-I/cfakepath",
                    "-Xcxx", "-I/cxxfakepath",
                    "-Xswiftc", "-I/swiftfakepath",
                ],
                packagePath: fixturePath
            ).stdout

            // Look for certain things in the output from XCBuild.
            XCTAssertMatch(defaultOutput, .contains("/fakerpath"))
            XCTAssertMatch(defaultOutput, .contains("-I/cfakepath"))
            XCTAssertMatch(defaultOutput, .contains("-I/cxxfakepath"))
            XCTAssertMatch(defaultOutput, .contains("-I/swiftfakepath"))
        }
    }

    func testXcodeBuildSystemOverrides() async throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test requires `xcbuild` and is therefore only supported on macOS")
        #endif
        try await fixture(name: "ValidLayouts/SingleModule/ExecutableNew") { fixturePath in
            // try await building using XCBuild without specifying overrides.  This should succeed, and should use the default
            // compiler path.
            let defaultOutput = try await execute(["-c", "debug", "--vv"], packagePath: fixturePath).stdout
            XCTAssertMatch(defaultOutput, try .contains(UserToolchain.default.swiftCompilerPath.pathString))

            // Now try await building using XCBuild while specifying a faulty compiler override.  This should fail.  Note that
            // we need to set the executable to use for the manifest itself to the default one, since it defaults to
            // SWIFT_EXEC if not provided.
            var overriddenOutput = ""
            await XCTAssertThrowsCommandExecutionError(
                try await self.execute(
                    ["-c", "debug", "--vv"],
                    environment: [
                        "SWIFT_EXEC": "/usr/bin/false",
                        "SWIFT_EXEC_MANIFEST": UserToolchain.default.swiftCompilerPath.pathString,
                    ],
                    packagePath: fixturePath
                )
            ) { error in
                overriddenOutput = error.stderr
            }
            XCTAssertMatch(overriddenOutput, .contains("/usr/bin/false"))
        }
    }

    func testPrintLLBuildManifestJobGraph() async throws {
        try await fixture(name: "DependencyResolution/Internal/Simple") { fixturePath in
            let output = try await execute(["--print-manifest-job-graph"], packagePath: fixturePath).stdout
            XCTAssertMatch(output, .prefix("digraph Jobs {"))
        }
    }

    func testSwiftDriverRawOutputGetsNewlines() async throws {
        try await fixture(name: "DependencyResolution/Internal/Simple") { fixturePath in
            // Building with `-wmo` should result in a `remark: Incremental compilation has been disabled: it is not
            // compatible with whole module optimization` message, which should have a trailing newline.  Since that
            // message won't be there at all when the legacy compiler driver is used, we gate this check on whether the
            // remark is there in the first place.
            let result = try await execute(["-c", "release", "-Xswiftc", "-wmo"], packagePath: fixturePath)
            if result.stdout.contains(
                "remark: Incremental compilation has been disabled: it is not compatible with whole module optimization"
            ) {
                XCTAssertMatch(result.stdout, .contains("optimization\n"))
                XCTAssertNoMatch(result.stdout, .contains("optimization["))
                XCTAssertNoMatch(result.stdout, .contains("optimizationremark"))
            }
        }
    }

    func testSwiftGetVersion() async throws {
        try await fixture(name: "Miscellaneous/Simple") { fixturePath in
            func findSwiftGetVersionFile() throws -> AbsolutePath {
                let buildArenaPath = fixturePath.appending(components: ".build", "debug")
                let files = try localFileSystem.getDirectoryContents(buildArenaPath)
                let filename = try XCTUnwrap(files.first { $0.hasPrefix("swift-version") })
                return buildArenaPath.appending(component: filename)
            }

            let dummySwiftcPath = SwiftPM.xctestBinaryPath(for: "dummy-swiftc")
            let swiftCompilerPath = try UserToolchain.default.swiftCompilerPath

            var environment: Environment = [
                "SWIFT_EXEC": dummySwiftcPath.pathString,
                // Environment variables used by `dummy-swiftc.sh`
                "SWIFT_ORIGINAL_PATH": swiftCompilerPath.pathString,
                "CUSTOM_SWIFT_VERSION": "1.0",
            ]

            // Build with a swiftc that returns version 1.0, we expect a successful build which compiles our one source
            // file.
            do {
                let result = try await execute(["--verbose"], environment: environment, packagePath: fixturePath)
                XCTAssertTrue(
                    result.stdout.contains("\(dummySwiftcPath.pathString) -module-name"),
                    "compilation task missing from build result: \(result.stdout)"
                )
                XCTAssertTrue(result.stdout.contains("Build complete!"), "unexpected build result: \(result.stdout)")
                let swiftGetVersionFilePath = try findSwiftGetVersionFile()
                XCTAssertEqual(try String(contentsOfFile: swiftGetVersionFilePath.pathString).spm_chomp(), "1.0")
            }

            // Build again with that same version, we do not expect any compilation tasks.
            do {
                let result = try await execute(["--verbose"], environment: environment, packagePath: fixturePath)
                XCTAssertFalse(
                    result.stdout.contains("\(dummySwiftcPath.pathString) -module-name"),
                    "compilation task present in build result: \(result.stdout)"
                )
                XCTAssertTrue(result.stdout.contains("Build complete!"), "unexpected build result: \(result.stdout)")
                let swiftGetVersionFilePath = try findSwiftGetVersionFile()
                XCTAssertEqual(try String(contentsOfFile: swiftGetVersionFilePath.pathString).spm_chomp(), "1.0")
            }

            // Build again with a swiftc that returns version 2.0, we expect compilation happening once more.
            do {
                environment["CUSTOM_SWIFT_VERSION"] = "2.0"
                let result = try await execute(["--verbose"], environment: environment, packagePath: fixturePath)
                XCTAssertTrue(
                    result.stdout.contains("\(dummySwiftcPath.pathString) -module-name"),
                    "compilation task missing from build result: \(result.stdout)"
                )
                XCTAssertTrue(result.stdout.contains("Build complete!"), "unexpected build result: \(result.stdout)")
                let swiftGetVersionFilePath = try findSwiftGetVersionFile()
                XCTAssertEqual(try String(contentsOfFile: swiftGetVersionFilePath.pathString).spm_chomp(), "2.0")
            }
        }
    }

    func testGetTaskAllowEntitlement() async throws {
        try await fixture(name: "ValidLayouts/SingleModule/ExecutableNew") { fixturePath in
            #if os(macOS)
            // try await building with default parameters.  This should succeed. We build verbosely so we get full command
            // lines.
            var buildResult = try await build(["-v"], packagePath: fixturePath)

            XCTAssertMatch(buildResult.stdout, .contains("codesign --force --sign - --entitlements"))

            buildResult = try await self.build(["-c", "debug", "-v"], packagePath: fixturePath)

            XCTAssertMatch(buildResult.stdout, .contains("codesign --force --sign - --entitlements"))

            // Build with different combinations of the entitlement flag and debug/release build configurations.

            buildResult = try await self.build(
                ["--enable-get-task-allow-entitlement", "-v"],
                packagePath: fixturePath,
                isRelease: true
            )

            XCTAssertMatch(buildResult.stdout, .contains("codesign --force --sign - --entitlements"))

            buildResult = try await self.build(
                ["-c", "debug", "--enable-get-task-allow-entitlement", "-v"],
                packagePath: fixturePath
            )

            XCTAssertMatch(buildResult.stdout, .contains("codesign --force --sign - --entitlements"))

            buildResult = try await self.build(
                ["-c", "debug", "--disable-get-task-allow-entitlement", "-v"],
                packagePath: fixturePath
            )

            XCTAssertNoMatch(buildResult.stdout, .contains("codesign --force --sign - --entitlements"))

            buildResult = try await self.build(
                ["--disable-get-task-allow-entitlement", "-v"],
                packagePath: fixturePath,
                isRelease: true
            )

            XCTAssertNoMatch(buildResult.stdout, .contains("codesign --force --sign - --entitlements"))
            #else
            var buildResult = try await self.build(["-v"], packagePath: fixturePath)

            XCTAssertNoMatch(buildResult.stdout, .contains("codesign --force --sign - --entitlements"))

            buildResult = try await self.build(["-v"], packagePath: fixturePath, isRelease: true)

            XCTAssertNoMatch(buildResult.stdout, .contains("codesign --force --sign - --entitlements"))

            buildResult = try await self.build(
                ["--disable-get-task-allow-entitlement", "-v"],
                packagePath: fixturePath,
                isRelease: true
            )

            XCTAssertNoMatch(buildResult.stdout, .contains("codesign --force --sign - --entitlements"))
            XCTAssertMatch(buildResult.stderr, .contains(SwiftCommandState.entitlementsMacOSWarning))

            buildResult = try await self.build(
                ["--enable-get-task-allow-entitlement", "-v"],
                packagePath: fixturePath,
                isRelease: true
            )

            XCTAssertNoMatch(buildResult.stdout, .contains("codesign --force --sign - --entitlements"))
            XCTAssertMatch(buildResult.stderr, .contains(SwiftCommandState.entitlementsMacOSWarning))
            #endif

            buildResult = try await self.build(["-c", "release", "-v"], packagePath: fixturePath, isRelease: true)

            XCTAssertNoMatch(buildResult.stdout, .contains("codesign --force --sign - --entitlements"))
        }
    }

#if !canImport(Darwin)
    func testIgnoresLinuxMain() async throws {
        try await fixture(name: "Miscellaneous/TestDiscovery/IgnoresLinuxMain") { fixturePath in
            let buildResult = try await self.build(["-v", "--build-tests", "--enable-test-discovery"], packagePath: fixturePath, cleanAfterward: false)
            let testBinaryPath = buildResult.binPath.appending("IgnoresLinuxMainPackageTests.xctest")

            _ = try await AsyncProcess.checkNonZeroExit(arguments: [testBinaryPath.pathString])
        }
    }
#endif

    func testCodeCoverage() async throws {
        // Test that no codecov directory is created if not specified when building.
        try await fixture(name: "Miscellaneous/TestDiscovery/Simple") { path in
            _ = try await self.build(["--build-tests"], packagePath: path, cleanAfterward: false)
            await XCTAssertAsyncThrowsError(try await SwiftPM.Test.execute(["--skip-build", "--enable-code-coverage"], packagePath: path))
        }

        // Test that enabling code coverage during building produces the expected folder.
        try await fixture(name: "Miscellaneous/TestDiscovery/Simple") { path in
            let buildResult = try await self.build(["--build-tests", "--enable-code-coverage"], packagePath: path, cleanAfterward: false)
            try await SwiftPM.Test.execute(["--skip-build", "--enable-code-coverage"], packagePath: path)
            let codeCovPath = buildResult.binPath.appending("codecov")
            let codeCovFiles = try localFileSystem.getDirectoryContents(codeCovPath)
            XCTAssertGreaterThan(codeCovFiles.count, 0)
        }
    }
}
