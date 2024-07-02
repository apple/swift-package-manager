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
@testable import CoreCommands
@testable import Commands
import Foundation

@_spi(DontAdoptOutsideOfSwiftPMExposedForBenchmarksAndTestsOnly)
import PackageGraph

import PackageLoading
import PackageModel
import SourceControl
import _InternalTestSupport
import Workspace
import XCTest

import struct TSCBasic.ByteString
import class TSCBasic.BufferedOutputByteStream
import enum TSCBasic.JSON
import class Basics.AsyncProcess

final class PackageCommandTests: CommandsTestCase {
    @discardableResult
    private func execute(
        _ args: [String] = [],
        packagePath: AbsolutePath? = nil,
        env: Environment? = nil
    ) async throws -> (stdout: String, stderr: String) {
        var environment = env ?? [:]
        // don't ignore local packages when caching
        environment["SWIFTPM_TESTS_PACKAGECACHE"] = "1"
        return try await SwiftPM.Package.execute(args, packagePath: packagePath, env: environment)
    }

    func testNoParameters() async throws {
        let stdout = try await execute().stdout
        XCTAssertMatch(stdout, .contains("USAGE: swift package"))
    }

    func testUsage() async throws {
        do {
            _ = try await execute(["-help"])
            XCTFail("expecting `execute` to fail")
        } catch SwiftPMError.executionFailure(_, _, let stderr) {
            XCTAssertMatch(stderr, .contains("Usage: swift package"))
        } catch {
            throw error
        }
    }

    func testSeeAlso() async throws {
        let stdout = try await execute(["--help"]).stdout
        XCTAssertMatch(stdout, .contains("SEE ALSO: swift build, swift run, swift test"))
    }

    func testVersion() async throws {
        let stdout = try await execute(["--version"]).stdout
        XCTAssertMatch(stdout, .contains("Swift Package Manager"))
    }
	
    func testCompletionTool() async throws {
        let stdout = try await execute(["completion-tool", "--help"]).stdout
        XCTAssertMatch(stdout, .contains("OVERVIEW: Completion command (for shell completions)"))
    }

	func testInitOverview() async throws {
		let stdout = try await execute(["init", "--help"]).stdout
		XCTAssertMatch(stdout, .contains("OVERVIEW: Initialize a new package"))
	}
	
	func testInitUsage() async throws {
		let stdout = try await execute(["init", "--help"]).stdout
		XCTAssertMatch(stdout, .contains("USAGE: swift package init [--type <type>] "))
		XCTAssertMatch(stdout, .contains(" [--name <name>]"))
	}
	
	func testInitOptionsHelp() async throws {
		let stdout = try await execute(["init", "--help"]).stdout
		XCTAssertMatch(stdout, .contains("OPTIONS:"))
	}

    func testPlugin() async throws {
        await XCTAssertThrowsCommandExecutionError(try await execute(["plugin"])) { error in
            XCTAssertMatch(error.stderr, .contains("error: Missing expected plugin command"))
        }
    }

    func testUnknownOption() async throws {
        await XCTAssertThrowsCommandExecutionError(try await execute(["--foo"])) { error in
            XCTAssertMatch(error.stderr, .contains("error: Unknown option '--foo'"))
        }
    }

    func testUnknownSubommand() async throws {
        try await fixture(name: "Miscellaneous/ExeTest") { fixturePath in
            await XCTAssertThrowsCommandExecutionError(try await execute(["foo"], packagePath: fixturePath)) { error in
                XCTAssertMatch(error.stderr, .contains("Unknown subcommand or plugin name ‘foo’"))
            }
        }
    }

    func testNetrc() async throws {
        try await fixture(name: "DependencyResolution/External/XCFramework") { fixturePath in
            // --enable-netrc flag
            try await self.execute(["resolve", "--enable-netrc"], packagePath: fixturePath)

            // --disable-netrc flag
            try await self.execute(["resolve", "--disable-netrc"], packagePath: fixturePath)

            // --enable-netrc and --disable-netrc flags
            await XCTAssertAsyncThrowsError(
                try await self.execute(["resolve", "--enable-netrc", "--disable-netrc"], packagePath: fixturePath)
            ) { error in
                XCTAssertMatch(String(describing: error), .contains("Value to be set with flag '--disable-netrc' had already been set with flag '--enable-netrc'"))
            }
        }
    }

    func testNetrcFile() async throws {
        try await fixture(name: "DependencyResolution/External/XCFramework") { fixturePath in
            let fs = localFileSystem
            let netrcPath = fixturePath.appending(".netrc")
            try fs.writeFileContents(
                netrcPath,
                string: "machine mymachine.labkey.org login user@labkey.org password mypassword"
            )

            // valid .netrc file path
            try await execute(["resolve", "--netrc-file", netrcPath.pathString], packagePath: fixturePath)

            // valid .netrc file path with --disable-netrc option
            await XCTAssertAsyncThrowsError(
                try await execute(["resolve", "--netrc-file", netrcPath.pathString, "--disable-netrc"], packagePath: fixturePath)
            ) { error in
                XCTAssertMatch(String(describing: error), .contains("'--disable-netrc' and '--netrc-file' are mutually exclusive"))
            }

            // invalid .netrc file path
            await XCTAssertAsyncThrowsError(
                try await execute(["resolve", "--netrc-file", "/foo"], packagePath: fixturePath)
            ) { error in
                XCTAssertMatch(String(describing: error), .contains("Did not find netrc file at /foo."))
            }

            // invalid .netrc file path with --disable-netrc option
            await XCTAssertAsyncThrowsError(
                try await execute(["resolve", "--netrc-file", "/foo", "--disable-netrc"], packagePath: fixturePath)
            ) { error in
                XCTAssertMatch(String(describing: error), .contains("'--disable-netrc' and '--netrc-file' are mutually exclusive"))
            }
        }
    }

    func testEnableDisableCache() async throws {
        try await fixture(name: "DependencyResolution/External/Simple") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")
            let repositoriesPath = packageRoot.appending(components: ".build", "repositories")
            let cachePath = fixturePath.appending("cache")
            let repositoriesCachePath = cachePath.appending("repositories")

            do {
                // Remove .build and cache folder
                _ = try await execute(["reset"], packagePath: packageRoot)
                try localFileSystem.removeFileTree(cachePath)

                try await self.execute(["resolve", "--enable-dependency-cache", "--cache-path", cachePath.pathString], packagePath: packageRoot)

                // we have to check for the prefix here since the hash value changes because spm sees the `prefix`
                // directory `/var/...` as `/private/var/...`.
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesCachePath).contains { $0.hasPrefix("Foo-") })

                // Remove .build folder
                _ = try await execute(["reset"], packagePath: packageRoot)

                // Perform another cache this time from the cache
                _ = try await execute(["resolve", "--enable-dependency-cache", "--cache-path", cachePath.pathString], packagePath: packageRoot)
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })

                // Remove .build and cache folder
                _ = try await execute(["reset"], packagePath: packageRoot)
                try localFileSystem.removeFileTree(cachePath)

                // Perform another fetch
                _ = try await execute(["resolve", "--enable-dependency-cache", "--cache-path", cachePath.pathString], packagePath: packageRoot)
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesCachePath).contains { $0.hasPrefix("Foo-") })
            }

            do {
                // Remove .build and cache folder
                _ = try await execute(["reset"], packagePath: packageRoot)
                try localFileSystem.removeFileTree(cachePath)

                try await self.execute(["resolve", "--disable-dependency-cache", "--cache-path", cachePath.pathString], packagePath: packageRoot)

                // we have to check for the prefix here since the hash value changes because spm sees the `prefix`
                // directory `/var/...` as `/private/var/...`.
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })
                XCTAssertFalse(localFileSystem.exists(repositoriesCachePath))
            }

            do {
                // Remove .build and cache folder
                _ = try await execute(["reset"], packagePath: packageRoot)
                try localFileSystem.removeFileTree(cachePath)

                let (_, _) = try await self.execute(["resolve", "--enable-dependency-cache", "--cache-path", cachePath.pathString], packagePath: packageRoot)

                // we have to check for the prefix here since the hash value changes because spm sees the `prefix`
                // directory `/var/...` as `/private/var/...`.
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesCachePath).contains { $0.hasPrefix("Foo-") })

                // Remove .build folder
                _ = try await execute(["reset"], packagePath: packageRoot)

                // Perform another cache this time from the cache
                _ = try await execute(["resolve", "--enable-dependency-cache", "--cache-path", cachePath.pathString], packagePath: packageRoot)
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })

                // Remove .build and cache folder
                _ = try await execute(["reset"], packagePath: packageRoot)
                try localFileSystem.removeFileTree(cachePath)

                // Perform another fetch
                _ = try await execute(["resolve", "--enable-dependency-cache", "--cache-path", cachePath.pathString], packagePath: packageRoot)
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesCachePath).contains { $0.hasPrefix("Foo-") })
            }

            do {
                // Remove .build and cache folder
                _ = try await execute(["reset"], packagePath: packageRoot)
                try localFileSystem.removeFileTree(cachePath)

                let (_, _) = try await self.execute(["resolve", "--disable-dependency-cache", "--cache-path", cachePath.pathString], packagePath: packageRoot)

                // we have to check for the prefix here since the hash value changes because spm sees the `prefix`
                // directory `/var/...` as `/private/var/...`.
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })
                XCTAssertFalse(localFileSystem.exists(repositoriesCachePath))
            }
        }
    }

    func testResolve() async throws {
        try await fixture(name: "DependencyResolution/External/Simple") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")

            // Check that `resolve` works.
            _ = try await execute(["resolve"], packagePath: packageRoot)
            let path = try SwiftPM.packagePath(for: "Foo", packageRoot: packageRoot)
            XCTAssertEqual(try GitRepository(path: path).getTags(), ["1.2.3"])
        }
    }

    func testUpdate() async throws {
        try await fixture(name: "DependencyResolution/External/Simple") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")

            // Perform an initial fetch.
            _ = try await execute(["resolve"], packagePath: packageRoot)

            do {
                let checkoutPath = try SwiftPM.packagePath(for: "Foo", packageRoot: packageRoot)
                let checkoutRepo = GitRepository(path: checkoutPath)
                XCTAssertEqual(try checkoutRepo.getTags(), ["1.2.3"])
                _ = try checkoutRepo.revision(forTag: "1.2.3")
            }


            // update and retag the dependency, and update.
            let repoPath = fixturePath.appending("Foo")
            let repo = GitRepository(path: repoPath)
            try localFileSystem.writeFileContents(repoPath.appending("test"), string: "test")
            try repo.stageEverything()
            try repo.commit()
            try repo.tag(name: "1.2.4")

            // we will validate it is there
            let revision = try repo.revision(forTag: "1.2.4")

            _ = try await execute(["update"], packagePath: packageRoot)

            do {
                // We shouldn't assume package path will be same after an update so ask again for it.
                let checkoutPath = try SwiftPM.packagePath(for: "Foo", packageRoot: packageRoot)
                let checkoutRepo = GitRepository(path: checkoutPath)
                // tag may not be there, but revision should be after update
                XCTAssertTrue(checkoutRepo.exists(revision: .init(identifier: revision)))
            }
        }
    }

    func testCache() async throws {
        try await fixture(name: "DependencyResolution/External/Simple") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")
            let repositoriesPath = packageRoot.appending(components: ".build", "repositories")
            let cachePath = fixturePath.appending("cache")
            let repositoriesCachePath = cachePath.appending("repositories")

            // Perform an initial fetch and populate the cache
            _ = try await execute(["resolve", "--cache-path", cachePath.pathString], packagePath: packageRoot)
            // we have to check for the prefix here since the hash value changes because spm sees the `prefix`
            // directory `/var/...` as `/private/var/...`.
            XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })
            XCTAssert(try localFileSystem.getDirectoryContents(repositoriesCachePath).contains { $0.hasPrefix("Foo-") })

            // Remove .build folder
            _ = try await execute(["reset"], packagePath: packageRoot)

            // Perform another cache this time from the cache
            _ = try await execute(["resolve", "--cache-path", cachePath.pathString], packagePath: packageRoot)
            XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })

            // Remove .build and cache folder
            _ = try await execute(["reset"], packagePath: packageRoot)
            try localFileSystem.removeFileTree(cachePath)

            // Perform another fetch
            _ = try await execute(["resolve", "--cache-path", cachePath.pathString], packagePath: packageRoot)
            XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })
            XCTAssert(try localFileSystem.getDirectoryContents(repositoriesCachePath).contains { $0.hasPrefix("Foo-") })
        }
    }

    func testDescribe() async throws {
        try await fixture(name: "Miscellaneous/ExeTest") { fixturePath in
            // Generate the JSON description.
            let (jsonOutput, _) = try await SwiftPM.Package.execute(["describe", "--type=json"], packagePath: fixturePath)
            let json = try JSON(bytes: ByteString(encodingAsUTF8: jsonOutput))

            // Check that tests don't appear in the product memberships.
            XCTAssertEqual(json["name"]?.string, "ExeTest")
            let jsonTarget0 = try XCTUnwrap(json["targets"]?.array?[0])
            XCTAssertNil(jsonTarget0["product_memberships"])
            let jsonTarget1 = try XCTUnwrap(json["targets"]?.array?[1])
            XCTAssertEqual(jsonTarget1["product_memberships"]?.array?[0].stringValue, "Exe")
        }

        try await fixture(name: "CFamilyTargets/SwiftCMixed") { fixturePath in
            // Generate the JSON description.
            let (jsonOutput, _) = try await SwiftPM.Package.execute(["describe", "--type=json"], packagePath: fixturePath)
            let json = try JSON(bytes: ByteString(encodingAsUTF8: jsonOutput))

            // Check that the JSON description contains what we expect it to.
            XCTAssertEqual(json["name"]?.string, "SwiftCMixed")
            XCTAssertMatch(json["path"]?.string, .prefix("/"))
            XCTAssertMatch(json["path"]?.string, .suffix("/" + fixturePath.basename))
            XCTAssertEqual(json["targets"]?.array?.count, 3)
            let jsonTarget0 = try XCTUnwrap(json["targets"]?.array?[0])
            XCTAssertEqual(jsonTarget0["name"]?.stringValue, "SeaLib")
            XCTAssertEqual(jsonTarget0["c99name"]?.stringValue, "SeaLib")
            XCTAssertEqual(jsonTarget0["type"]?.stringValue, "library")
            XCTAssertEqual(jsonTarget0["module_type"]?.stringValue, "ClangTarget")
            let jsonTarget1 = try XCTUnwrap(json["targets"]?.array?[1])
            XCTAssertEqual(jsonTarget1["name"]?.stringValue, "SeaExec")
            XCTAssertEqual(jsonTarget1["c99name"]?.stringValue, "SeaExec")
            XCTAssertEqual(jsonTarget1["type"]?.stringValue, "executable")
            XCTAssertEqual(jsonTarget1["module_type"]?.stringValue, "SwiftTarget")
            XCTAssertEqual(jsonTarget1["product_memberships"]?.array?[0].stringValue, "SeaExec")
            let jsonTarget2 = try XCTUnwrap(json["targets"]?.array?[2])
            XCTAssertEqual(jsonTarget2["name"]?.stringValue, "CExec")
            XCTAssertEqual(jsonTarget2["c99name"]?.stringValue, "CExec")
            XCTAssertEqual(jsonTarget2["type"]?.stringValue, "executable")
            XCTAssertEqual(jsonTarget2["module_type"]?.stringValue, "ClangTarget")
            XCTAssertEqual(jsonTarget2["product_memberships"]?.array?[0].stringValue, "CExec")

            // Generate the text description.
            let (textOutput, _) = try await SwiftPM.Package.execute(["describe", "--type=text"], packagePath: fixturePath)
            let textChunks = textOutput.components(separatedBy: "\n").reduce(into: [""]) { chunks, line in
                // Split the text into chunks based on presence or absence of leading whitespace.
                if line.hasPrefix(" ") == chunks[chunks.count-1].hasPrefix(" ") {
                    chunks[chunks.count-1].append(line + "\n")
                }
                else {
                    chunks.append(line + "\n")
                }
            }.filter{ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            // Check that the text description contains what we expect it to.
            // FIXME: This is a bit inelegant, but any errors are easy to reason about.
            let textChunk0 = try XCTUnwrap(textChunks[0])
            XCTAssertMatch(textChunk0, .contains("Name: SwiftCMixed"))
            XCTAssertMatch(textChunk0, .contains("Path: /"))
            XCTAssertMatch(textChunk0, .contains("/" + fixturePath.basename + "\n"))
            XCTAssertMatch(textChunk0, .contains("Tools version: 4.2"))
            XCTAssertMatch(textChunk0, .contains("Products:"))
            let textChunk1 = try XCTUnwrap(textChunks[1])
            XCTAssertMatch(textChunk1, .contains("Name: SeaExec"))
            XCTAssertMatch(textChunk1, .contains("Type:\n        Executable"))
            XCTAssertMatch(textChunk1, .contains("Targets:\n        SeaExec"))
            let textChunk2 = try XCTUnwrap(textChunks[2])
            XCTAssertMatch(textChunk2, .contains("Name: CExec"))
            XCTAssertMatch(textChunk2, .contains("Type:\n        Executable"))
            XCTAssertMatch(textChunk2, .contains("Targets:\n        CExec"))
            let textChunk3 = try XCTUnwrap(textChunks[3])
            XCTAssertMatch(textChunk3, .contains("Targets:"))
            let textChunk4 = try XCTUnwrap(textChunks[4])
            XCTAssertMatch(textChunk4, .contains("Name: SeaLib"))
            XCTAssertMatch(textChunk4, .contains("C99name: SeaLib"))
            XCTAssertMatch(textChunk4, .contains("Type: library"))
            XCTAssertMatch(textChunk4, .contains("Module type: ClangTarget"))
            XCTAssertMatch(textChunk4, .contains("Path: Sources/SeaLib"))
            XCTAssertMatch(textChunk4, .contains("Sources:\n        Foo.c"))
            let textChunk5 = try XCTUnwrap(textChunks[5])
            XCTAssertMatch(textChunk5, .contains("Name: SeaExec"))
            XCTAssertMatch(textChunk5, .contains("C99name: SeaExec"))
            XCTAssertMatch(textChunk5, .contains("Type: executable"))
            XCTAssertMatch(textChunk5, .contains("Module type: SwiftTarget"))
            XCTAssertMatch(textChunk5, .contains("Path: Sources/SeaExec"))
            XCTAssertMatch(textChunk5, .contains("Sources:\n        main.swift"))
            let textChunk6 = try XCTUnwrap(textChunks[6])
            XCTAssertMatch(textChunk6, .contains("Name: CExec"))
            XCTAssertMatch(textChunk6, .contains("C99name: CExec"))
            XCTAssertMatch(textChunk6, .contains("Type: executable"))
            XCTAssertMatch(textChunk6, .contains("Module type: ClangTarget"))
            XCTAssertMatch(textChunk6, .contains("Path: Sources/CExec"))
            XCTAssertMatch(textChunk6, .contains("Sources:\n        main.c"))
        }

        try await fixture(name: "DependencyResolution/External/Simple/Bar") { fixturePath in
            // Generate the JSON description.
            let (jsonOutput, _) = try await SwiftPM.Package.execute(["describe", "--type=json"], packagePath: fixturePath)
            let json = try JSON(bytes: ByteString(encodingAsUTF8: jsonOutput))

            // Check that product dependencies and memberships are as expected.
            XCTAssertEqual(json["name"]?.string, "Bar")
            let jsonTarget = try XCTUnwrap(json["targets"]?.array?[0])
            XCTAssertEqual(jsonTarget["product_memberships"]?.array?[0].stringValue, "Bar")
            XCTAssertEqual(jsonTarget["product_dependencies"]?.array?[0].stringValue, "Foo")
            XCTAssertNil(jsonTarget["target_dependencies"])
        }

    }

    func testDescribePackageUsingPlugins() async throws {
        try await fixture(name: "Miscellaneous/Plugins/MySourceGenPlugin") { fixturePath in
            // Generate the JSON description.
            let (stdout, _) = try await SwiftPM.Package.execute(["describe", "--type=json"], packagePath: fixturePath)
            let json = try JSON(bytes: ByteString(encodingAsUTF8: stdout))

            // Check the contents of the JSON.
            XCTAssertEqual(try XCTUnwrap(json["name"]).string, "MySourceGenPlugin")
            let targetsArray = try XCTUnwrap(json["targets"]?.array)
            let buildToolPluginTarget = try XCTUnwrap(targetsArray.first{ $0["name"]?.string == "MySourceGenBuildToolPlugin" }?.dictionary)
            XCTAssertEqual(buildToolPluginTarget["module_type"]?.string, "PluginTarget")
            XCTAssertEqual(buildToolPluginTarget["plugin_capability"]?.dictionary?["type"]?.string, "buildTool")
            let prebuildPluginTarget = try XCTUnwrap(targetsArray.first{ $0["name"]?.string == "MySourceGenPrebuildPlugin" }?.dictionary)
            XCTAssertEqual(prebuildPluginTarget["module_type"]?.string, "PluginTarget")
            XCTAssertEqual(prebuildPluginTarget["plugin_capability"]?.dictionary?["type"]?.string, "buildTool")
        }
    }

    func testDumpPackage() async throws {
        try await fixture(name: "DependencyResolution/External/Complex") { fixturePath in
            let packageRoot = fixturePath.appending("app")
            let (dumpOutput, _) = try await execute(["dump-package"], packagePath: packageRoot)
            let json = try JSON(bytes: ByteString(encodingAsUTF8: dumpOutput))
            guard case let .dictionary(contents) = json else { XCTFail("unexpected result"); return }
            guard case let .string(name)? = contents["name"] else { XCTFail("unexpected result"); return }
            guard case let .array(platforms)? = contents["platforms"] else { XCTFail("unexpected result"); return }
            XCTAssertEqual(name, "Dealer")
            XCTAssertEqual(platforms, [
                .dictionary([
                    "platformName": .string("macos"),
                    "version": .string("10.12"),
                    "options": .array([])
                ]),
                .dictionary([
                    "platformName": .string("ios"),
                    "version": .string("10.0"),
                    "options": .array([])
                ]),
                .dictionary([
                    "platformName": .string("tvos"),
                    "version": .string("11.0"),
                    "options": .array([])
                ]),
                .dictionary([
                    "platformName": .string("watchos"),
                    "version": .string("5.0"),
                    "options": .array([])
                ]),
            ])
        }
    }

    // Returns symbol graph with or without pretty printing.
    private func symbolGraph(atPath path: AbsolutePath, withPrettyPrinting: Bool, file: StaticString = #file, line: UInt = #line) async throws -> Data? {
        let tool = try SwiftCommandState.makeMockState(options: GlobalOptions.parse(["--package-path", path.pathString]))
        let symbolGraphExtractorPath = try tool.getTargetToolchain().getSymbolGraphExtract()

        let arguments = withPrettyPrinting ? ["dump-symbol-graph", "--pretty-print"] : ["dump-symbol-graph"]

        let result = try await SwiftPM.Package.execute(arguments, packagePath: path, env: ["SWIFT_SYMBOLGRAPH_EXTRACT": symbolGraphExtractorPath.pathString])
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: URL(fileURLWithPath: path.pathString), includingPropertiesForKeys: nil), file: file, line: line)

        var symbolGraphURL: URL?
        for case let url as URL in enumerator where url.lastPathComponent == "Bar.symbols.json" {
            symbolGraphURL = url
            break
        }

        let symbolGraphData: Data
        if let symbolGraphURL {
            symbolGraphData = try Data(contentsOf: symbolGraphURL)
        } else {
            XCTFail("Failed to extract symbol graph: \(result.stdout)\n\(result.stderr)")
            return nil
        }

        // Double check that it's a valid JSON
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: symbolGraphData), file: file, line: line)

        return symbolGraphData
    }

    func testDumpSymbolGraphCompactFormatting() async throws {
        // Depending on how the test is running, the `swift-symbolgraph-extract` tool might be unavailable.
        try XCTSkipIf((try? UserToolchain.default.getSymbolGraphExtract()) == nil, "skipping test because the `swift-symbolgraph-extract` tools isn't available")

        try await fixture(name: "DependencyResolution/Internal/Simple") { fixturePath in
            let compactGraphData = try await XCTAsyncUnwrap(await symbolGraph(atPath: fixturePath, withPrettyPrinting: false))
            let compactJSONText = String(decoding: compactGraphData, as: UTF8.self)
            XCTAssertEqual(compactJSONText.components(separatedBy: .newlines).count, 1)
        }
    }

    func testDumpSymbolGraphPrettyFormatting() async throws {
        // Depending on how the test is running, the `swift-symbolgraph-extract` tool might be unavailable.
        try XCTSkipIf((try? UserToolchain.default.getSymbolGraphExtract()) == nil, "skipping test because the `swift-symbolgraph-extract` tools isn't available")

        try await fixture(name: "DependencyResolution/Internal/Simple") { fixturePath in
            let prettyGraphData = try await XCTAsyncUnwrap(await symbolGraph(atPath: fixturePath, withPrettyPrinting: true))
            let prettyJSONText = String(decoding: prettyGraphData, as: UTF8.self)
            XCTAssertGreaterThan(prettyJSONText.components(separatedBy: .newlines).count, 1)
        }
    }

    func testShowDependencies() async throws {
        try await fixture(name: "DependencyResolution/External/Complex") { fixturePath in
            let packageRoot = fixturePath.appending("app")
            let (textOutput, _) = try await SwiftPM.Package.execute(["show-dependencies", "--format=text"], packagePath: packageRoot)
            XCTAssert(textOutput.contains("FisherYates@1.2.3"))

            let (jsonOutput, _) = try await SwiftPM.Package.execute(["show-dependencies", "--format=json"], packagePath: packageRoot)
            let json = try JSON(bytes: ByteString(encodingAsUTF8: jsonOutput))
            guard case let .dictionary(contents) = json else { XCTFail("unexpected result"); return }
            guard case let .string(name)? = contents["name"] else { XCTFail("unexpected result"); return }
            XCTAssertEqual(name, "Dealer")
            guard case let .string(path)? = contents["path"] else { XCTFail("unexpected result"); return }
            XCTAssertEqual(try resolveSymlinks(try AbsolutePath(validating: path)), try resolveSymlinks(packageRoot))
        }
    }

    func testShowDependencies_dotFormat_sr12016() throws {
        // Confirm that SR-12016 is resolved.
        // See https://bugs.swift.org/browse/SR-12016

        let fileSystem = InMemoryFileSystem(emptyFiles: [
            "/PackageA/Sources/TargetA/main.swift",
            "/PackageB/Sources/TargetB/B.swift",
            "/PackageC/Sources/TargetC/C.swift",
            "/PackageD/Sources/TargetD/D.swift",
        ])

        let manifestA = Manifest.createRootManifest(
            displayName: "PackageA",
            path: "/PackageA",
            toolsVersion: .v5_3,
            dependencies: [
                .fileSystem(path: "/PackageB"),
                .fileSystem(path: "/PackageC"),
            ],
            products: [
                try .init(name: "exe", type: .executable, targets: ["TargetA"])
            ],
            targets: [
                try .init(name: "TargetA", dependencies: ["PackageB", "PackageC"])
            ]
        )

        let manifestB = Manifest.createFileSystemManifest(
            displayName: "PackageB",
            path: "/PackageB",
            toolsVersion: .v5_3,
            dependencies: [
                .fileSystem(path: "/PackageC"),
                .fileSystem(path: "/PackageD"),
            ],
            products: [
                try .init(name: "PackageB", type: .library(.dynamic), targets: ["TargetB"])
            ],
            targets: [
                try .init(name: "TargetB", dependencies: ["PackageC", "PackageD"])
            ]
        )

        let manifestC = Manifest.createFileSystemManifest(
            displayName: "PackageC",
            path: "/PackageC",
            toolsVersion: .v5_3,
            dependencies: [
                .fileSystem(path: "/PackageD"),
            ],
            products: [
                try .init(name: "PackageC", type: .library(.dynamic), targets: ["TargetC"])
            ],
            targets: [
                try .init(name: "TargetC", dependencies: ["PackageD"])
            ]
        )

        let manifestD = Manifest.createFileSystemManifest(
            displayName: "PackageD",
            path: "/PackageD",
            toolsVersion: .v5_3,
            products: [
                try .init(name: "PackageD", type: .library(.dynamic), targets: ["TargetD"])
            ],
            targets: [
                try .init(name: "TargetD")
            ]
        )

        let observability = ObservabilitySystem.makeForTesting()
        let graph = try loadModulesGraph(
            fileSystem: fileSystem,
            manifests: [manifestA, manifestB, manifestC, manifestD],
            observabilityScope: observability.topScope
        )
        XCTAssertNoDiagnostics(observability.diagnostics)

        let output = BufferedOutputByteStream()
        SwiftPackageCommand.ShowDependencies.dumpDependenciesOf(
            graph: graph,
            rootPackage: graph.rootPackages[graph.rootPackages.startIndex],
            mode: .dot,
            on: output
        )
        let dotFormat = output.bytes.description

        var alreadyPutOut: Set<Substring> = []
        for line in dotFormat.split(whereSeparator: { $0.isNewline }) {
            if alreadyPutOut.contains(line) {
                XCTFail("Same line was already put out: \(line)")
            }
            alreadyPutOut.insert(line)
        }

        let expectedLines: [Substring] = [
            #""/PackageA" [label="packagea\n/PackageA\nunspecified"]"#,
            #""/PackageB" [label="packageb\n/PackageB\nunspecified"]"#,
            #""/PackageC" [label="packagec\n/PackageC\nunspecified"]"#,
            #""/PackageD" [label="packaged\n/PackageD\nunspecified"]"#,
            #""/PackageA" -> "/PackageB""#,
            #""/PackageA" -> "/PackageC""#,
            #""/PackageB" -> "/PackageC""#,
            #""/PackageB" -> "/PackageD""#,
            #""/PackageC" -> "/PackageD""#,
        ]
        for expectedLine in expectedLines {
            XCTAssertTrue(alreadyPutOut.contains(expectedLine),
                          "Expected line is not found: \(expectedLine)")
        }
    }

    func testShowDependencies_redirectJsonOutput() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let root = tmpPath.appending(components: "root")
            let dep = tmpPath.appending(components: "dep")

            // Create root package.
            let mainFilePath = root.appending(components: "Sources", "root", "main.swift")
            try fs.writeFileContents(mainFilePath, string: "")
            try fs.writeFileContents(root.appending("Package.swift"), string:
                """
                // swift-tools-version:4.2
                import PackageDescription
                let package = Package(
                    name: "root",
                    dependencies: [.package(url: "../dep", from: "1.0.0")],
                    targets: [.target(name: "root", dependencies: ["dep"])]
                )
                """
            )

            // Create dependency.
            try fs.writeFileContents(dep.appending(components: "Sources", "dep", "lib.swift"), string: "")
            try fs.writeFileContents(dep.appending("Package.swift"), string:
                """
                // swift-tools-version:4.2
                import PackageDescription
                let package = Package(
                    name: "dep",
                    products: [.library(name: "dep", targets: ["dep"])],
                    targets: [.target(name: "dep")]
                )
                """
            )

            do {
                let depGit = GitRepository(path: dep)
                try depGit.create()
                try depGit.stageEverything()
                try depGit.commit()
                try depGit.tag(name: "1.0.0")
            }

            let resultPath = root.appending("result.json")
            _ = try await execute(["show-dependencies", "--format", "json", "--output-path", resultPath.pathString ], packagePath: root)

            XCTAssertFileExists(resultPath)
            let jsonOutput: Data = try fs.readFileContents(resultPath)
            let json = try JSON(data: jsonOutput)

            XCTAssertEqual(json["name"]?.string, "root")
            XCTAssertEqual(json["dependencies"]?[0]?["name"]?.string, "dep")
        }
    }

    func testInitEmpty() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending("Foo")
            try fs.createDirectory(path)
            _ = try await execute(["init", "--type", "empty"], packagePath: path)

            XCTAssertFileExists(path.appending("Package.swift"))
        }
    }

    func testInitExecutable() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending("Foo")
            try fs.createDirectory(path)
            _ = try await execute(["init", "--type", "executable"], packagePath: path)

            let manifest = path.appending("Package.swift")
            let contents: String = try localFileSystem.readFileContents(manifest)
            let version = InitPackage.newPackageToolsVersion
            let versionSpecifier = "\(version.major).\(version.minor)"
            XCTAssertMatch(contents, .prefix("// swift-tools-version:\(version < .v5_4 ? "" : " ")\(versionSpecifier)\n"))

            XCTAssertFileExists(manifest)
            XCTAssertEqual(try fs.getDirectoryContents(path.appending("Sources")), ["main.swift"])
        }
    }

    func testInitLibrary() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending("Foo")
            try fs.createDirectory(path)
            _ = try await execute(["init"], packagePath: path)

            XCTAssertFileExists(path.appending("Package.swift"))
            XCTAssertEqual(try fs.getDirectoryContents(path.appending("Sources").appending("Foo")), ["Foo.swift"])
            XCTAssertEqual(try fs.getDirectoryContents(path.appending("Tests")).sorted(), ["FooTests"])
        }
    }

    func testInitCustomNameExecutable() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending("Foo")
            try fs.createDirectory(path)
            _ = try await execute(["init", "--name", "CustomName", "--type", "executable"], packagePath: path)

            let manifest = path.appending("Package.swift")
            let contents: String = try localFileSystem.readFileContents(manifest)
            let version = InitPackage.newPackageToolsVersion
            let versionSpecifier = "\(version.major).\(version.minor)"
            XCTAssertMatch(contents, .prefix("// swift-tools-version:\(version < .v5_4 ? "" : " ")\(versionSpecifier)\n"))

            XCTAssertFileExists(manifest)
            XCTAssertEqual(try fs.getDirectoryContents(path.appending("Sources")), ["main.swift"])
        }
    }

    func testPackageAddDependency() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending("PackageB")
            try fs.createDirectory(path)

            try fs.writeFileContents(path.appending("Package.swift"), string:
                """
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(
                    name: "client",
                    targets: [ .target(name: "client", dependencies: [ "library" ]) ]
                )
                """
            )

            _ = try await execute(["add-dependency", "--branch", "main", "https://github.com/swiftlang/swift-syntax.git"], packagePath: path)

            let manifest = path.appending("Package.swift")
            XCTAssertFileExists(manifest)
            let contents: String = try fs.readFileContents(manifest)

            XCTAssertMatch(contents, .contains(#".package(url: "https://github.com/swiftlang/swift-syntax.git", branch: "main"),"#))
        }
    }

    func testPackageAddTarget() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending("PackageB")
            try fs.createDirectory(path)

            try fs.writeFileContents(path.appending("Package.swift"), string:
                """
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(
                    name: "client"
                )
                """
            )

            _ = try await execute(["add-target", "client", "--dependencies", "MyLib", "OtherLib", "--type", "executable"], packagePath: path)

            let manifest = path.appending("Package.swift")
            XCTAssertFileExists(manifest)
            let contents: String = try fs.readFileContents(manifest)

            XCTAssertMatch(contents, .contains(#"targets:"#))
            XCTAssertMatch(contents, .contains(#".executableTarget"#))
            XCTAssertMatch(contents, .contains(#"name: "client""#))
            XCTAssertMatch(contents, .contains(#"dependencies:"#))
            XCTAssertMatch(contents, .contains(#""MyLib""#))
            XCTAssertMatch(contents, .contains(#""OtherLib""#))
        }
    }

    func testPackageAddTargetDependency() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending("PackageB")
            try fs.createDirectory(path)

            try fs.writeFileContents(path.appending("Package.swift"), string:
                """
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(
                    name: "client",
                    targets: [ .target(name: "library") ]
                )
                """
            )
            try localFileSystem.writeFileContents(path.appending(components: "Sources", "library", "library.swift"), string:
                """
                public func Foo() { }
                """
            )

            _ = try await execute(["add-target-dependency", "--package", "other-package", "other-product", "library"], packagePath: path)

            let manifest = path.appending("Package.swift")
            XCTAssertFileExists(manifest)
            let contents: String = try fs.readFileContents(manifest)

            XCTAssertMatch(contents, .contains(#".product(name: "other-product", package: "other-package"#))
        }
    }

    func testPackageAddProduct() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending("PackageB")
            try fs.createDirectory(path)

            try fs.writeFileContents(path.appending("Package.swift"), string:
                """
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(
                    name: "client"
                )
                """
            )

            _ = try await execute(["add-product", "MyLib", "--targets", "MyLib", "--type", "static-library"], packagePath: path)

            let manifest = path.appending("Package.swift")
            XCTAssertFileExists(manifest)
            let contents: String = try fs.readFileContents(manifest)

            XCTAssertMatch(contents, .contains(#"products:"#))
            XCTAssertMatch(contents, .contains(#".library"#))
            XCTAssertMatch(contents, .contains(#"name: "MyLib""#))
            XCTAssertMatch(contents, .contains(#"type: .static"#))
            XCTAssertMatch(contents, .contains(#"targets:"#))
            XCTAssertMatch(contents, .contains(#""MyLib""#))
        }
    }
    func testPackageEditAndUnedit() async throws {
        try await fixture(name: "Miscellaneous/PackageEdit") { fixturePath in
            let fooPath = fixturePath.appending("foo")
            func build() async throws -> (stdout: String, stderr: String) {
                return try await SwiftPM.Build.execute(packagePath: fooPath)
            }

            // Put bar and baz in edit mode.
            _ = try await SwiftPM.Package.execute(["edit", "bar", "--branch", "bugfix"], packagePath: fooPath)
            _ = try await SwiftPM.Package.execute(["edit", "baz", "--branch", "bugfix"], packagePath: fooPath)

            // Path to the executable.
            let exec = [fooPath.appending(components: ".build", try UserToolchain.default.targetTriple.platformBuildPathComponent, "debug", "foo").pathString]

            // We should see it now in packages directory.
            let editsPath = fooPath.appending(components: "Packages", "bar")
            XCTAssertDirectoryExists(editsPath)

            let bazEditsPath = fooPath.appending(components: "Packages", "baz")
            XCTAssertDirectoryExists(bazEditsPath)
            // Removing baz externally should just emit an warning and not a build failure.
            try localFileSystem.removeFileTree(bazEditsPath)

            // Do a modification in bar and build.
            try localFileSystem.writeFileContents(editsPath.appending(components: "Sources", "bar.swift"), bytes: "public let theValue = 88888\n")
            let (_, stderr) = try await build()

            XCTAssertMatch(stderr, .contains("dependency 'baz' was being edited but is missing; falling back to original checkout"))
            // We should be able to see that modification now.
            try await XCTAssertAsyncEqual(try await AsyncProcess.checkNonZeroExit(arguments: exec), "88888\n")
            // The branch of edited package should be the one we provided when putting it in edit mode.
            let editsRepo = GitRepository(path: editsPath)
            XCTAssertEqual(try editsRepo.currentBranch(), "bugfix")

            // It shouldn't be possible to unedit right now because of uncommitted changes.
            do {
                _ = try await SwiftPM.Package.execute(["unedit", "bar"], packagePath: fooPath)
                XCTFail("Unexpected unedit success")
            } catch {}

            try editsRepo.stageEverything()
            try editsRepo.commit()

            // It shouldn't be possible to unedit right now because of unpushed changes.
            do {
                _ = try await SwiftPM.Package.execute(["unedit", "bar"], packagePath: fooPath)
                XCTFail("Unexpected unedit success")
            } catch {}

            // Push the changes.
            try editsRepo.push(remote: "origin", branch: "bugfix")

            // We should be able to unedit now.
            _ = try await SwiftPM.Package.execute(["unedit", "bar"], packagePath: fooPath)

            // Test editing with a path i.e. ToT development.
            let bazTot = fixturePath.appending("tot")
            try await SwiftPM.Package.execute(["edit", "baz", "--path", bazTot.pathString], packagePath: fooPath)
            XCTAssertTrue(localFileSystem.exists(bazTot))
            XCTAssertTrue(localFileSystem.isSymlink(bazEditsPath))

            // Edit a file in baz ToT checkout.
            let bazTotPackageFile = bazTot.appending("Package.swift")
            var content: String = try localFileSystem.readFileContents(bazTotPackageFile)
            content += "\n// Edited."
            try localFileSystem.writeFileContents(bazTotPackageFile, string: content)

            // Unediting baz will remove the symlink but not the checked out package.
            try await SwiftPM.Package.execute(["unedit", "baz"], packagePath: fooPath)
            XCTAssertTrue(localFileSystem.exists(bazTot))
            XCTAssertFalse(localFileSystem.isSymlink(bazEditsPath))

            // Check that on re-editing with path, we don't make a new clone.
            try await SwiftPM.Package.execute(["edit", "baz", "--path", bazTot.pathString], packagePath: fooPath)
            XCTAssertTrue(localFileSystem.isSymlink(bazEditsPath))
            XCTAssertEqual(try localFileSystem.readFileContents(bazTotPackageFile), content)
        }
    }

    func testPackageClean() async throws {
        try await fixture(name: "DependencyResolution/External/Simple") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")

            // Build it.
            await XCTAssertBuilds(packageRoot)
            let buildPath = packageRoot.appending(".build")
            let binFile = buildPath.appending(components: try UserToolchain.default.targetTriple.platformBuildPathComponent, "debug", "Bar")
            XCTAssertFileExists(binFile)
            XCTAssert(localFileSystem.isDirectory(buildPath))

            // Clean, and check for removal of the build directory but not Packages.
            _ = try await execute(["clean"], packagePath: packageRoot)
            XCTAssertNoSuchPath(binFile)
            // Clean again to ensure we get no error.
            _ = try await execute(["clean"], packagePath: packageRoot)
        }
    }

    func testPackageReset() async throws {
        try await fixture(name: "DependencyResolution/External/Simple") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")

            // Build it.
            await XCTAssertBuilds(packageRoot)
            let buildPath = packageRoot.appending(".build")
            let binFile = buildPath.appending(components: try UserToolchain.default.targetTriple.platformBuildPathComponent, "debug", "Bar")
            XCTAssertFileExists(binFile)
            XCTAssert(localFileSystem.isDirectory(buildPath))
            // Clean, and check for removal of the build directory but not Packages.

            _ = try await execute(["clean"], packagePath: packageRoot)
            XCTAssertNoSuchPath(binFile)
            XCTAssertFalse(try localFileSystem.getDirectoryContents(buildPath.appending("repositories")).isEmpty)

            // Fully clean.
            _ = try await execute(["reset"], packagePath: packageRoot)
            XCTAssertFalse(localFileSystem.isDirectory(buildPath))

            // Test that we can successfully run reset again.
            _ = try await execute(["reset"], packagePath: packageRoot)
        }
    }

    func testPinningBranchAndRevision() async throws {
        try await fixture(name: "Miscellaneous/PackageEdit") { fixturePath in
            let fooPath = fixturePath.appending("foo")

            @discardableResult
            func execute(_ args: String..., printError: Bool = true) async throws -> String {
                return try await SwiftPM.Package.execute([] + args, packagePath: fooPath).stdout
            }

            try await execute("update")

            let pinsFile = fooPath.appending("Package.resolved")
            XCTAssertFileExists(pinsFile)

            // Update bar repo.
            let barPath = fixturePath.appending("bar")
            let barRepo = GitRepository(path: barPath)
            try barRepo.checkout(newBranch: "YOLO")
            let yoloRevision = try barRepo.getCurrentRevision()

            // Try to pin bar at a branch.
            do {
                try await execute("resolve", "bar", "--branch", "YOLO")
                let pinsStore = try PinsStore(pinsFile: pinsFile, workingDirectory: fixturePath, fileSystem: localFileSystem, mirrors: .init())
                let state = PinsStore.PinState.branch(name: "YOLO", revision: yoloRevision.identifier)
                let identity = PackageIdentity(path: barPath)
                XCTAssertEqual(pinsStore.pins[identity]?.state, state)
            }

            // Try to pin bar at a revision.
            do {
                try await execute("resolve", "bar", "--revision", yoloRevision.identifier)
                let pinsStore = try PinsStore(pinsFile: pinsFile, workingDirectory: fixturePath, fileSystem: localFileSystem, mirrors: .init())
                let state = PinsStore.PinState.revision(yoloRevision.identifier)
                let identity = PackageIdentity(path: barPath)
                XCTAssertEqual(pinsStore.pins[identity]?.state, state)
            }

            // Try to pin bar at a bad revision.
            do {
                try await execute("resolve", "bar", "--revision", "xxxxx")
                XCTFail()
            } catch {}
        }
    }

    func testPinning() async throws {
        try await fixture(name: "Miscellaneous/PackageEdit") { fixturePath in
            let fooPath = fixturePath.appending("foo")
            let exec = [fooPath.appending(components: ".build", try UserToolchain.default.targetTriple.platformBuildPathComponent, "debug", "foo").pathString]

            // Build and check.
            _ = try await SwiftPM.Build.execute(packagePath: fooPath)
            try await XCTAssertAsyncEqual(try await AsyncProcess.checkNonZeroExit(arguments: exec).spm_chomp(), "\(5)")

            // Get path to bar checkout.
            let barPath = try SwiftPM.packagePath(for: "bar", packageRoot: fooPath)

            // Checks the content of checked out bar.swift.
            func checkBar(_ value: Int, file: StaticString = #file, line: UInt = #line) throws {
                let contents: String = try localFileSystem.readFileContents(barPath.appending(components:"Sources", "bar.swift"))
                XCTAssertTrue(contents.spm_chomp().hasSuffix("\(value)"), "got \(contents)", file: file, line: line)
            }

            // We should see a pin file now.
            let pinsFile = fooPath.appending("Package.resolved")
            XCTAssertFileExists(pinsFile)

            // Test pins file.
            do {
                let pinsStore = try PinsStore(pinsFile: pinsFile, workingDirectory: fixturePath, fileSystem: localFileSystem, mirrors: .init())
                XCTAssertEqual(pinsStore.pins.count, 2)
                for pkg in ["bar", "baz"] {
                    let path = try SwiftPM.packagePath(for: pkg, packageRoot: fooPath)
                    let pin = pinsStore.pins[PackageIdentity(path: path)]!
                    XCTAssertEqual(pin.packageRef.identity, PackageIdentity(path: path))
                    guard case .localSourceControl(let path) = pin.packageRef.kind, path.pathString.hasSuffix(pkg) else {
                        return XCTFail("invalid pin location \(path)")
                    }
                    switch pin.state {
                    case .version(let version, revision: _):
                        XCTAssertEqual(version, "1.2.3")
                    default:
                        XCTFail("invalid pin state")
                    }
                }
            }

            @discardableResult
            func execute(_ args: String...) async throws -> String {
                return try await SwiftPM.Package.execute([] + args, packagePath: fooPath).stdout
            }

            // Try to pin bar.
            do {
                try await execute("resolve", "bar")
                let pinsStore = try PinsStore(pinsFile: pinsFile, workingDirectory: fixturePath, fileSystem: localFileSystem, mirrors: .init())
                let identity = PackageIdentity(path: barPath)
                switch pinsStore.pins[identity]?.state {
                case .version(let version, revision: _):
                    XCTAssertEqual(version, "1.2.3")
                default:
                    XCTFail("invalid pin state")
                }
            }

            // Update bar repo.
            do {
                let barPath = fixturePath.appending("bar")
                let barRepo = GitRepository(path: barPath)
                try localFileSystem.writeFileContents(barPath.appending(components: "Sources", "bar.swift"), bytes: "public let theValue = 6\n")
                try barRepo.stageEverything()
                try barRepo.commit()
                try barRepo.tag(name: "1.2.4")
            }

            // Running package update with --repin should update the package.
            do {
                try await execute("update")
                try checkBar(6)
            }

            // We should be able to revert to a older version.
            do {
                try await execute("resolve", "bar", "--version", "1.2.3")
                let pinsStore = try PinsStore(pinsFile: pinsFile, workingDirectory: fixturePath, fileSystem: localFileSystem, mirrors: .init())
                let identity = PackageIdentity(path: barPath)
                switch pinsStore.pins[identity]?.state {
                case .version(let version, revision: _):
                    XCTAssertEqual(version, "1.2.3")
                default:
                    XCTFail("invalid pin state")
                }
                try checkBar(5)
            }

            // Try pinning a dependency which is in edit mode.
            do {
                try await execute("edit", "bar", "--branch", "bugfix")
                await XCTAssertThrowsCommandExecutionError(try await execute("resolve", "bar")) { error in
                    XCTAssertMatch(error.stderr, .contains("error: edited dependency 'bar' can't be resolved"))
                }
                try await execute("unedit", "bar")
            }
        }
    }

    func testOnlyUseVersionsFromResolvedFileFetchesWithExistingState() async throws {
        func writeResolvedFile(packageDir: AbsolutePath, repositoryURL: String, revision: String, version: String) throws {
            try localFileSystem.writeFileContents(packageDir.appending("Package.resolved"), string:
                """
                {
                  "object": {
                    "pins": [
                      {
                        "package": "library",
                        "repositoryURL": "\(repositoryURL)",
                        "state": {
                          "branch": null,
                          "revision": "\(revision)",
                          "version": "\(version)"
                        }
                      }
                    ]
                  },
                  "version": 1
                }
                """
            )
        }

        try await testWithTemporaryDirectory { tmpPath in
            let packageDir = tmpPath.appending(components: "library")
            try localFileSystem.writeFileContents(packageDir.appending("Package.swift"), string:
                """
                // swift-tools-version:5.0
                import PackageDescription
                let package = Package(
                    name: "library",
                    products: [ .library(name: "library", targets: ["library"]) ],
                    targets: [ .target(name: "library") ]
                )
                """
            )
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "library", "library.swift"), string:
                """
                public func Foo() { }
                """
            )

            let depGit = GitRepository(path: packageDir)
            try depGit.create()
            try depGit.stageEverything()
            try depGit.commit()
            try depGit.tag(name: "1.0.0")

            let initialRevision = try depGit.revision(forTag: "1.0.0")
            let repositoryURL = "file://\(packageDir.pathString)"

            let clientDir = tmpPath.appending(components: "client")
            try localFileSystem.writeFileContents(clientDir.appending("Package.swift"), string:
                """
                // swift-tools-version:5.0
                import PackageDescription
                let package = Package(
                    name: "client",
                    dependencies: [ .package(url: "\(repositoryURL)", from: "1.0.0") ],
                    targets: [ .target(name: "client", dependencies: [ "library" ]) ]
                )
                """
            )
            try localFileSystem.writeFileContents(clientDir.appending(components: "Sources", "client", "main.swift"), string:
                """
                print("hello")
                """
            )

            // Initial resolution with clean state.
            do {
                try writeResolvedFile(packageDir: clientDir, repositoryURL: repositoryURL, revision: initialRevision, version: "1.0.0")
                let (_, err)  = try await execute(["resolve", "--only-use-versions-from-resolved-file"], packagePath: clientDir)
                XCTAssertMatch(err, .contains("Fetching \(repositoryURL)"))
            }

            // Make a change to the dependency and tag a new version.
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "library", "library.swift"), string:
                """
                public func Best() { }
                """
            )
            try depGit.stageEverything()
            try depGit.commit()
            try depGit.tag(name: "1.0.1")
            let updatedRevision = try depGit.revision(forTag: "1.0.1")

            // Require new version but re-use existing state that hasn't fetched the latest revision, yet.
            do {
                try writeResolvedFile(packageDir: clientDir, repositoryURL: repositoryURL, revision: updatedRevision, version: "1.0.1")
                let (_, err) = try await execute(["resolve", "--only-use-versions-from-resolved-file"], packagePath: clientDir)
                XCTAssertNoMatch(err, .contains("Fetching \(repositoryURL)"))
                XCTAssertMatch(err, .contains("Updating \(repositoryURL)"))

            }

            // And again
            do {
                let (_, err) = try await execute(["resolve", "--only-use-versions-from-resolved-file"], packagePath: clientDir)
                XCTAssertNoMatch(err, .contains("Updating \(repositoryURL)"))
                XCTAssertNoMatch(err, .contains("Fetching \(repositoryURL)"))
            }
        }
    }

    func testSymlinkedDependency() async throws {
        try await testWithTemporaryDirectory { path in
            let fs = localFileSystem
            let root = path.appending(components: "root")
            let dep = path.appending(components: "dep")
            let depSym = path.appending(components: "depSym")

            // Create root package.
            try fs.writeFileContents(root.appending(components: "Sources", "root", "main.swift"), string: "")
            try fs.writeFileContents(root.appending("Package.swift"), string:
                """
                // swift-tools-version:4.2
                import PackageDescription
                let package = Package(
                    name: "root",
                    dependencies: [.package(url: "../depSym", from: "1.0.0")],
                    targets: [.target(name: "root", dependencies: ["dep"])]
                )

                """
            )

            // Create dependency.
            try fs.writeFileContents(dep.appending(components: "Sources", "dep", "lib.swift"), string: "")
            try fs.writeFileContents(dep.appending("Package.swift"), string:
                """
                // swift-tools-version:4.2
                import PackageDescription
                let package = Package(
                    name: "dep",
                    products: [.library(name: "dep", targets: ["dep"])],
                    targets: [.target(name: "dep")]
                )
                """
            )
            do {
                let depGit = GitRepository(path: dep)
                try depGit.create()
                try depGit.stageEverything()
                try depGit.commit()
                try depGit.tag(name: "1.0.0")
            }

            // Create symlink to the dependency.
            try fs.createSymbolicLink(depSym, pointingAt: dep, relative: false)

            _ = try await execute(["resolve"], packagePath: root)
        }
    }

    func testMirrorConfigDeprecation() async throws {
        try await testWithTemporaryDirectory { fixturePath in
            localFileSystem.createEmptyFiles(at: fixturePath, files:
                "/Sources/Foo/Foo.swift",
                "/Package.swift"
            )

            let (_, stderr) = try await execute(["config", "set-mirror", "--package-url", "https://github.com/foo/bar", "--mirror-url", "https://mygithub.com/foo/bar"], packagePath: fixturePath)
            XCTAssertMatch(stderr, .contains("warning: '--package-url' option is deprecated; use '--original' instead"))
            XCTAssertMatch(stderr, .contains("warning: '--mirror-url' option is deprecated; use '--mirror' instead"))
        }
    }

    func testMirrorConfig() async throws {
        try await testWithTemporaryDirectory { fixturePath in
            let fs = localFileSystem
            let packageRoot = fixturePath.appending("Foo")
            let configOverride = fixturePath.appending("configoverride")
            let configFile = Workspace.DefaultLocations.mirrorsConfigurationFile(forRootPackage: packageRoot)

            fs.createEmptyFiles(at: packageRoot, files:
                "/Sources/Foo/Foo.swift",
                "/Tests/FooTests/FooTests.swift",
                "/Package.swift",
                "anchor"
            )

            // Test writing.
            try await execute(["config", "set-mirror", "--original", "https://github.com/foo/bar", "--mirror", "https://mygithub.com/foo/bar"], packagePath: packageRoot)
            try await execute(["config", "set-mirror", "--original", "git@github.com:swiftlang/swift-package-manager.git", "--mirror", "git@mygithub.com:foo/swift-package-manager.git"], packagePath: packageRoot)
            XCTAssertTrue(fs.isFile(configFile))

            // Test env override.
            try await execute(["config", "set-mirror", "--original", "https://github.com/foo/bar", "--mirror", "https://mygithub.com/foo/bar"], packagePath: packageRoot, env: ["SWIFTPM_MIRROR_CONFIG": configOverride.pathString])
            XCTAssertTrue(fs.isFile(configOverride))
            let content: String = try fs.readFileContents(configOverride)
            XCTAssertMatch(content, .contains("mygithub"))

            // Test reading.
            var (stdout, _) = try await execute(["config", "get-mirror", "--original", "https://github.com/foo/bar"], packagePath: packageRoot)
            XCTAssertEqual(stdout.spm_chomp(), "https://mygithub.com/foo/bar")
            (stdout, _) = try await execute(["config", "get-mirror", "--original", "git@github.com:swiftlang/swift-package-manager.git"], packagePath: packageRoot)
            XCTAssertEqual(stdout.spm_chomp(), "git@mygithub.com:foo/swift-package-manager.git")

            func check(stderr: String, _ block: () async throws -> ()) async {
                await XCTAssertThrowsCommandExecutionError(try await block()) { error in
                    XCTAssertMatch(stderr, .contains(stderr))
                }
            }

            await check(stderr: "not found\n") {
                try await execute(["config", "get-mirror", "--original", "foo"], packagePath: packageRoot)
            }

            // Test deletion.
            try await execute(["config", "unset-mirror", "--original", "https://github.com/foo/bar"], packagePath: packageRoot)
            try await execute(["config", "unset-mirror", "--original", "git@mygithub.com:foo/swift-package-manager.git"], packagePath: packageRoot)

            await check(stderr: "not found\n") {
                try await execute(["config", "get-mirror", "--original", "https://github.com/foo/bar"], packagePath: packageRoot)
            }
            await check(stderr: "not found\n") {
                try await execute(["config", "get-mirror", "--original", "git@github.com:swiftlang/swift-package-manager.git"], packagePath: packageRoot)
            }

            await check(stderr: "error: Mirror not found for 'foo'\n") {
                try await execute(["config", "unset-mirror", "--original", "foo"], packagePath: packageRoot)
            }
        }
    }

    func testMirrorSimple() async throws {
        try await testWithTemporaryDirectory { fixturePath in
            let fs = localFileSystem
            let packageRoot = fixturePath.appending("MyPackage")
            let configFile = Workspace.DefaultLocations.mirrorsConfigurationFile(forRootPackage: packageRoot)

            fs.createEmptyFiles(
                at: packageRoot,
                files:
                "/Sources/Foo/Foo.swift",
                "/Tests/FooTests/FooTests.swift",
                "/Package.swift"
            )

            try fs.writeFileContents(packageRoot.appending("Package.swift"), string:
                """
                // swift-tools-version: 5.7
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    dependencies: [
                        .package(url: "https://scm.com/org/foo", from: "1.0.0")
                    ],
                    targets: [
                        .executableTarget(
                            name: "MyTarget",
                            dependencies: [
                                .product(name: "Foo", package: "foo")
                            ])
                    ]
                )
                """
            )

            try await execute(["config", "set-mirror", "--original", "https://scm.com/org/foo", "--mirror", "https://scm.com/org/bar"], packagePath: packageRoot)
            XCTAssertTrue(fs.isFile(configFile))

            let (stdout, _) = try await SwiftPM.Package.execute(["dump-package"], packagePath: packageRoot)
            XCTAssertMatch(stdout, .contains("https://scm.com/org/bar"))
            XCTAssertNoMatch(stdout, .contains("https://scm.com/org/foo"))
        }
    }

    func testMirrorURLToRegistry() async throws {
        try await testWithTemporaryDirectory { fixturePath in
            let fs = localFileSystem
            let packageRoot = fixturePath.appending("MyPackage")
            let configFile = Workspace.DefaultLocations.mirrorsConfigurationFile(forRootPackage: packageRoot)

            fs.createEmptyFiles(
                at: packageRoot,
                files:
                "/Sources/Foo/Foo.swift",
                "/Tests/FooTests/FooTests.swift",
                "/Package.swift"
            )

            try fs.writeFileContents(packageRoot.appending("Package.swift"), string:
                """
                // swift-tools-version: 5.7
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    dependencies: [
                        .package(url: "https://scm.com/org/foo", from: "1.0.0")
                    ],
                    targets: [
                        .executableTarget(
                            name: "MyTarget",
                            dependencies: [
                                .product(name: "Foo", package: "foo")
                            ])
                    ]
                )
                """
            )

            try await execute(["config", "set-mirror", "--original", "https://scm.com/org/foo", "--mirror", "org.bar"], packagePath: packageRoot)
            XCTAssertTrue(fs.isFile(configFile))

            let (stdout, _) = try await SwiftPM.Package.execute(["dump-package"], packagePath: packageRoot)
            XCTAssertMatch(stdout, .contains("org.bar"))
            XCTAssertNoMatch(stdout, .contains("https://scm.com/org/foo"))
        }
    }

    func testMirrorRegistryToURL() async throws {
        try await testWithTemporaryDirectory { fixturePath in
            let fs = localFileSystem
            let packageRoot = fixturePath.appending("MyPackage")
            let configFile = Workspace.DefaultLocations.mirrorsConfigurationFile(forRootPackage: packageRoot)

            fs.createEmptyFiles(
                at: packageRoot,
                files:
                "/Sources/Foo/Foo.swift",
                "/Tests/FooTests/FooTests.swift",
                "/Package.swift"
            )

            try fs.writeFileContents(packageRoot.appending("Package.swift"), string:
                """
                // swift-tools-version: 5.7
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    dependencies: [
                        .package(id: "org.foo", from: "1.0.0")
                    ],
                    targets: [
                        .executableTarget(
                            name: "MyTarget",
                            dependencies: [
                                .product(name: "Foo", package: "org.foo")
                            ])
                    ]
                )
                """
            )

            try await execute(["config", "set-mirror", "--original", "org.foo", "--mirror", "https://scm.com/org/bar"], packagePath: packageRoot)
            XCTAssertTrue(fs.isFile(configFile))

            let (stdout, _) = try await SwiftPM.Package.execute(["dump-package"], packagePath: packageRoot)
            XCTAssertMatch(stdout, .contains("https://scm.com/org/bar"))
            XCTAssertNoMatch(stdout, .contains("org.foo"))
        }
    }

    func testPackageLoadingCommandPathResilience() async throws {
        #if !os(macOS)
        try XCTSkipIf(true, "skipping on non-macOS")
        #endif

        try await fixture(name: "ValidLayouts/SingleModule") { fixturePath in
            try await testWithTemporaryDirectory { tmpdir in
                // Create fake `xcrun` and `sandbox-exec` commands.
                let fakeBinDir = tmpdir
                for fakeCmdName in ["xcrun", "sandbox-exec"] {
                    let fakeCmdPath = fakeBinDir.appending(component: fakeCmdName)
                    try localFileSystem.writeFileContents(fakeCmdPath, string:
                        """
                        #!/bin/sh
                        echo "wrong \(fakeCmdName) invoked"
                        exit 1
                        """
                    )
                    try localFileSystem.chmod(.executable, path: fakeCmdPath)
                }

                // Invoke `swift-package`, passing in the overriding `PATH` environment variable.
                let packageRoot = fixturePath.appending("Library")
                let patchedPATH = fakeBinDir.pathString + ":" + ProcessInfo.processInfo.environment["PATH"]!
                let (stdout, _) = try await SwiftPM.Package.execute(["dump-package"], packagePath: packageRoot, env: ["PATH": patchedPATH])

                // Check that the wrong tools weren't invoked.  We can't just check the exit code because of fallbacks.
                XCTAssertNoMatch(stdout, .contains("wrong xcrun invoked"))
                XCTAssertNoMatch(stdout, .contains("wrong sandbox-exec invoked"))
            }
        }
    }

    func testBuildToolPlugin() async throws {
        try await testBuildToolPlugin(staticStdlib: false)
    }

    func testBuildToolPluginWithStaticStdlib() async throws {
        // Skip if the toolchain cannot compile a simple program with static stdlib.
        do {
            let args = try [
                UserToolchain.default.swiftCompilerPath.pathString,
                "-static-stdlib", "-emit-executable", "-o", "/dev/null", "-"
            ]
            let process = AsyncProcess(arguments: args)
            let stdin = try process.launch()
            stdin.write(sequence: "".utf8)
            try stdin.close()
            let result = try await process.waitUntilExit()
            try XCTSkipIf(
                result.exitStatus != .terminated(code: 0),
                "skipping because static stdlib is not supported by the toolchain"
            )
        }
        try await testBuildToolPlugin(staticStdlib: true)
    }

    func testBuildToolPlugin(staticStdlib: Bool) async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.writeFileContents(packageDir.appending("Package.swift"), string:
                """
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    targets: [
                        .target(
                            name: "MyLibrary",
                            plugins: [
                                "MyPlugin",
                            ]
                        ),
                        .plugin(
                            name: "MyPlugin",
                            capability: .buildTool()
                        ),
                    ]
                )
                """
            )
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "MyLibrary", "library.swift"), string:
                """
                public func Foo() { }
                """
            )
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "MyLibrary", "library.foo"), string:
                """
                a file with a filename suffix handled by the plugin
                """
            )
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "MyLibrary", "library.bar"), string:
                """
                a file with a filename suffix not handled by the plugin
                """
            )
            try localFileSystem.writeFileContents(packageDir.appending(components: "Plugins", "MyPlugin", "plugin.swift"), string:
                """
                import PackagePlugin
                import Foundation
                @main
                struct MyBuildToolPlugin: BuildToolPlugin {
                    func createBuildCommands(
                        context: PluginContext,
                        target: Target
                    ) throws -> [Command] {
                        // Expect the initial working directory for build tool plugins is the package directory.
                        guard FileManager.default.currentDirectoryPath == context.package.directory.string else {
                            throw "expected initial working directory ‘\\(FileManager.default.currentDirectoryPath)’"
                        }

                        // Check that the package display name is what we expect.
                        guard context.package.displayName == "MyPackage" else {
                            throw "expected display name to be ‘MyPackage’ but found ‘\\(context.package.displayName)’"
                        }

                        // Create and return a build command that uses all the `.foo` files in the target as inputs, so they get counted as having been handled.
                        let fooFiles = target.sourceModule?.sourceFiles.compactMap{ $0.path.extension == "foo" ? $0.path : nil } ?? []
                        return [ .buildCommand(displayName: "A command", executable: Path("/bin/echo"), arguments: fooFiles, inputFiles: fooFiles) ]
                    }

                }
                extension String : Error {}
                """
            )

            // Invoke it, and check the results.
            let args = staticStdlib ? ["--static-swift-stdlib"] : []
            let (stdout, stderr) = try await SwiftPM.Build.execute(args, packagePath: packageDir)
            XCTAssert(stdout.contains("Build complete!"))

            // We expect a warning about `library.bar` but not about `library.foo`.
            XCTAssertMatch(stderr, .contains("found 1 file(s) which are unhandled"))
            XCTAssertNoMatch(stderr, .contains("Sources/MyLibrary/library.foo"))
            XCTAssertMatch(stderr, .contains("Sources/MyLibrary/library.bar"))
        }
    }

    func testBuildToolPluginFailure() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(packageDir.appending("Package.swift"), string: """
                // swift-tools-version: 5.6
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    targets: [
                        .target(
                            name: "MyLibrary",
                            plugins: [
                                "MyPlugin",
                            ]
                        ),
                        .plugin(
                            name: "MyPlugin",
                            capability: .buildTool()
                        ),
                    ]
                )
                """
            )
            let myLibraryTargetDir = packageDir.appending(components: "Sources", "MyLibrary")
            try localFileSystem.createDirectory(myLibraryTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myLibraryTargetDir.appending("library.swift"), string: """
                public func Foo() { }
                """
            )
            let myPluginTargetDir = packageDir.appending(components: "Plugins", "MyPlugin")
            try localFileSystem.createDirectory(myPluginTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myPluginTargetDir.appending("plugin.swift"), string: """
                import PackagePlugin
                import Foundation
                @main
                struct MyBuildToolPlugin: BuildToolPlugin {
                    func createBuildCommands(
                        context: PluginContext,
                        target: Target
                    ) throws -> [Command] {
                        print("This is text from the plugin")
                        throw "This is an error from the plugin"
                        return []
                    }

                }
                extension String : Error {}
                """
            )

            // Invoke it, and check the results.
            await XCTAssertAsyncThrowsError(try await SwiftPM.Build.execute(["-v"], packagePath: packageDir)) { error in
                guard case SwiftPMError.executionFailure(_, _, let stderr) = error else {
                    return XCTFail("invalid error \(error)")
                }
                XCTAssertMatch(stderr, .contains("This is text from the plugin"))
                XCTAssertMatch(stderr, .contains("error: This is an error from the plugin"))
                XCTAssertMatch(stderr, .contains("build stopped due to build-tool plugin failures"))
            }
        }
    }

    func testArchiveSource() async throws {
        try await fixture(name: "DependencyResolution/External/Simple") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")

            // Running without arguments or options
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["archive-source"], packagePath: packageRoot)
                XCTAssert(stdout.contains("Created Bar.zip"), #"actual: "\#(stdout)""#)
            }

            // Running without arguments or options again, overwriting existing archive
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["archive-source"], packagePath: packageRoot)
                XCTAssert(stdout.contains("Created Bar.zip"), #"actual: "\#(stdout)""#)
            }

            // Running with output as absolute path within package root
            do {
                let destination = packageRoot.appending("Bar-1.2.3.zip")
                let (stdout, _) = try await SwiftPM.Package.execute(["archive-source", "--output", destination.pathString], packagePath: packageRoot)
                XCTAssert(stdout.contains("Created Bar-1.2.3.zip"), #"actual: "\#(stdout)""#)
            }

            // Running with output is outside the package root
            try await withTemporaryDirectory { tempDirectory in
                let destination = tempDirectory.appending("Bar-1.2.3.zip")
                let (stdout, _) = try await SwiftPM.Package.execute(["archive-source", "--output", destination.pathString], packagePath: packageRoot)
                XCTAssert(stdout.hasPrefix("Created /"), #"actual: "\#(stdout)""#)
                XCTAssert(stdout.contains("Bar-1.2.3.zip"), #"actual: "\#(stdout)""#)
            }

            // Running without arguments or options in non-package directory
            do {
                await XCTAssertAsyncThrowsError(try await SwiftPM.Package.execute(["archive-source"], packagePath: fixturePath)) { error in
                    guard case SwiftPMError.executionFailure(_, _, let stderr) = error else {
                        return XCTFail("invalid error \(error)")
                    }
                    XCTAssert(stderr.contains("error: Could not find Package.swift in this directory or any of its parent directories."), #"actual: "\#(stderr)""#)
                }
            }

            // Running with output as absolute path to existing directory
            do {
                let destination = AbsolutePath.root
                await XCTAssertAsyncThrowsError(try await SwiftPM.Package.execute(["archive-source", "--output", destination.pathString], packagePath: packageRoot)) { error in
                    guard case SwiftPMError.executionFailure(_, _, let stderr) = error else {
                        return XCTFail("invalid error \(error)")
                    }
                    XCTAssert(
                        stderr.contains("error: Couldn’t create an archive:"),
                        #"actual: "\#(stderr)""#
                    )
                }
            }
        }
    }

    func testCommandPlugin() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target, a plugin, and a local tool. It depends on a sample package which also has a tool.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.writeFileContents(packageDir.appending(components: "Package.swift"), string:
                """
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    dependencies: [
                        .package(name: "HelperPackage", path: "VendoredDependencies/HelperPackage")
                    ],
                    targets: [
                        .target(
                            name: "MyLibrary",
                            dependencies: [
                                .product(name: "HelperLibrary", package: "HelperPackage")
                            ]
                        ),
                        .plugin(
                            name: "MyPlugin",
                            capability: .command(
                                intent: .custom(verb: "mycmd", description: "What is mycmd anyway?")
                            ),
                            dependencies: [
                                .target(name: "LocalBuiltTool"),
                                .target(name: "LocalBinaryTool"),
                                .product(name: "RemoteBuiltTool", package: "HelperPackage")
                            ]
                        ),
                        .binaryTarget(
                            name: "LocalBinaryTool",
                            path: "Binaries/LocalBinaryTool.artifactbundle"
                        ),
                        .executableTarget(
                            name: "LocalBuiltTool"
                        )
                    ]
                )
                """
            )
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "MyLibrary", "library.swift"), string:
                """
                public func Foo() { }
                """
            )
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "MyLibrary", "test.docc"), string:
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>CFBundleName</key>
                    <string>sample</string>
                </dict>
                """
            )
            let environment = Environment.current
            let hostTriple = try UserToolchain(
                swiftSDK: .hostSwiftSDK(environment: environment),
                environment: environment
            ).targetTriple
            let hostTripleString = if hostTriple.isDarwin() {
                hostTriple.tripleString(forPlatformVersion: "")
            } else {
                hostTriple.tripleString
            }

            try localFileSystem.writeFileContents(
                packageDir.appending(components: "Binaries", "LocalBinaryTool.artifactbundle", "info.json"),
                string: """
                {   "schemaVersion": "1.0",
                    "artifacts": {
                        "LocalBinaryTool": {
                            "type": "executable",
                            "version": "1.2.3",
                            "variants": [
                                {   "path": "LocalBinaryTool.sh",
                                    "supportedTriples": ["\(hostTripleString)"]
                                },
                            ]
                        }
                    }
                }
                """
            )
            try localFileSystem.writeFileContents(
                packageDir.appending(components: "Sources", "LocalBuiltTool", "main.swift"),
                string: #"print("Hello")"#
            )
            try localFileSystem.writeFileContents(
                packageDir.appending(components: "Plugins", "MyPlugin", "plugin.swift"),
                string: """
                import PackagePlugin
                import Foundation
                @main
                struct MyCommandPlugin: CommandPlugin {
                    func performCommand(
                        context: PluginContext,
                        arguments: [String]
                    ) throws {
                        print("This is MyCommandPlugin.")

                        // Print out the initial working directory so we can check it in the test.
                        print("Initial working directory: \\(FileManager.default.currentDirectoryPath)")

                        // Check that we can find a binary-provided tool in the same package.
                        print("Looking for LocalBinaryTool...")
                        let localBinaryTool = try context.tool(named: "LocalBinaryTool")
                        print("... found it at \\(localBinaryTool.path)")

                        // Check that we can find a source-built tool in the same package.
                        print("Looking for LocalBuiltTool...")
                        let localBuiltTool = try context.tool(named: "LocalBuiltTool")
                        print("... found it at \\(localBuiltTool.path)")

                        // Check that we can find a source-built tool in another package.
                        print("Looking for RemoteBuiltTool...")
                        let remoteBuiltTool = try context.tool(named: "RemoteBuiltTool")
                        print("... found it at \\(remoteBuiltTool.path)")

                        // Check that we can find a tool in the toolchain.
                        print("Looking for swiftc...")
                        let swiftc = try context.tool(named: "swiftc")
                        print("... found it at \\(swiftc.path)")

                        // Check that we can find a standard tool.
                        print("Looking for sed...")
                        let sed = try context.tool(named: "sed")
                        print("... found it at \\(sed.path)")

                        // Extract the `--target` arguments.
                        var argExtractor = ArgumentExtractor(arguments)
                        let targetNames = argExtractor.extractOption(named: "target")
                        let targets = try context.package.targets(named: targetNames)

                        // Print out the source files so that we can check them.
                        if let sourceFiles = targets.first(where: { $0.name == "MyLibrary" })?.sourceModule?.sourceFiles {
                            for file in sourceFiles {
                                print("  \\(file.path): \\(file.type)")
                            }
                        }

                        // Print out the dependencies so that we can check them.
                        for dependency in context.package.dependencies {
                            print("  dependency \\(dependency.package.displayName): \\(dependency.package.origin)")
                        }
                    }
                }
                """
            )

            // Create the sample vendored dependency package.
            try localFileSystem.writeFileContents(
                packageDir.appending(components: "VendoredDependencies", "HelperPackage", "Package.swift"),
                string: """
                // swift-tools-version: 5.5
                import PackageDescription
                let package = Package(
                    name: "HelperPackage",
                    products: [
                        .library(
                            name: "HelperLibrary",
                            targets: ["HelperLibrary"]
                        ),
                        .executable(
                            name: "RemoteBuiltTool",
                            targets: ["RemoteBuiltTool"]
                        ),
                    ],
                    targets: [
                        .target(
                            name: "HelperLibrary"
                        ),
                        .executableTarget(
                            name: "RemoteBuiltTool"
                        ),
                    ]
                )
                """
            )
            try localFileSystem.writeFileContents(
                packageDir.appending(
                    components: "VendoredDependencies",
                    "HelperPackage",
                    "Sources",
                    "HelperLibrary",
                    "library.swift"
                ),
                string: "public func Bar() { }"
            )
            try localFileSystem.writeFileContents(
                packageDir.appending(
                    components: "VendoredDependencies",
                    "HelperPackage",
                    "Sources",
                    "RemoteBuiltTool",
                    "main.swift"
                ),
                string: #"print("Hello")"#
            )

            // Check that we can invoke the plugin with the "plugin" subcommand.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["plugin", "mycmd"], packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("This is MyCommandPlugin."))
            }

            // Check that we can also invoke it without the "plugin" subcommand.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["mycmd"], packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("This is MyCommandPlugin."))
            }

            // Testing listing the available command plugins.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["plugin", "--list"], packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("‘mycmd’ (plugin ‘MyPlugin’ in package ‘MyPackage’)"))
            }

            // Check that we get the expected error if trying to invoke a plugin with the wrong name.
            do {
                await XCTAssertAsyncThrowsError(try await SwiftPM.Package.execute(["my-nonexistent-cmd"], packagePath: packageDir)) { error in
                    guard case SwiftPMError.executionFailure(_, _, let stderr) = error else {
                        return XCTFail("invalid error \(error)")
                    }
                    XCTAssertMatch(stderr, .contains("Unknown subcommand or plugin name ‘my-nonexistent-cmd’"))
                }
            }

            // Check that the .docc file was properly vended to the plugin.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["mycmd", "--target", "MyLibrary"], packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("Sources/MyLibrary/library.swift: source"))
                XCTAssertMatch(stdout, .contains("Sources/MyLibrary/test.docc: unknown"))
            }

            // Check that the initial working directory is what we expected.
            do {
                let workingDirectory = FileManager.default.currentDirectoryPath
                let (stdout, _) = try await SwiftPM.Package.execute(["mycmd"], packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("Initial working directory: \(workingDirectory)"))
            }

            // Check that information about the dependencies was properly sent to the plugin.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["mycmd", "--target", "MyLibrary"], packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("dependency HelperPackage: local"))
            }
        }
    }

    func testAmbiguousCommandPlugin() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try await fixture(name: "Miscellaneous/Plugins/AmbiguousCommands") { fixturePath in
            let (stdout, _) = try await SwiftPM.Package.execute(["plugin", "--package", "A", "A"], packagePath: fixturePath)
            XCTAssertMatch(stdout, .contains("Hello A!"))
        }
    }

    // Test reporting of plugin diagnostic messages at different verbosity levels
    func testCommandPluginDiagnostics() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        // Match patterns for expected messages
        let isEmpty = StringPattern.equal("")
        let isOnlyPrint = StringPattern.equal("command plugin: print\n")
        let containsProgress = StringPattern.contains("[diagnostics-stub] command plugin: Diagnostics.progress")
        let containsRemark = StringPattern.contains("command plugin: Diagnostics.remark")
        let containsWarning = StringPattern.contains("command plugin: Diagnostics.warning")
        let containsError = StringPattern.contains("command plugin: Diagnostics.error")

        try await fixture(name: "Miscellaneous/Plugins/CommandPluginTestStub") { fixturePath in
            func runPlugin(flags: [String], diagnostics: [String], completion: (String, String) -> Void) async throws {
                let (stdout, stderr) = try await SwiftPM.Package.execute(flags + ["print-diagnostics"] + diagnostics, packagePath: fixturePath, env: ["SWIFT_DRIVER_SWIFTSCAN_LIB" : "/this/is/a/bad/path"])
                completion(stdout, stderr)
            }

            // Diagnostics.error causes SwiftPM to return a non-zero exit code, but we still need to check stdout and stderr
            func runPluginWithError(flags: [String], diagnostics: [String], completion: (String, String) -> Void) async throws {
                await XCTAssertAsyncThrowsError(try await SwiftPM.Package.execute(flags + ["print-diagnostics"] + diagnostics, packagePath: fixturePath, env: ["SWIFT_DRIVER_SWIFTSCAN_LIB" : "/this/is/a/bad/path"])) { error in
                    guard case SwiftPMError.executionFailure(_, let stdout, let stderr) = error else {
                        return XCTFail("invalid error \(error)")
                    }
                    completion(stdout, stderr)
                }
            }

            // Default verbosity
            //   - stdout is always printed
            //   - Diagnostics below 'warning' are suppressed

            try await runPlugin(flags: [], diagnostics: ["print"]) { stdout, stderr in
                XCTAssertMatch(stdout, isOnlyPrint)
                XCTAssertMatch(stderr, isEmpty)
            }

            try await runPlugin(flags: [], diagnostics: ["print", "progress"]) { stdout, stderr in
                XCTAssertMatch(stdout, isOnlyPrint)
                XCTAssertMatch(stderr, containsProgress)
            }

            try await runPlugin(flags: [], diagnostics: ["print", "progress", "remark"]) { stdout, stderr in
            	XCTAssertMatch(stdout, isOnlyPrint)
                XCTAssertMatch(stderr, containsProgress)
            }

            try await runPlugin(flags: [], diagnostics: ["print", "progress", "remark", "warning"]) { stdout, stderr in
            	XCTAssertMatch(stdout, isOnlyPrint)
            	XCTAssertMatch(stderr, containsProgress)
                XCTAssertMatch(stderr, containsWarning)
            }

         	try await runPluginWithError(flags: [], diagnostics: ["print", "progress", "remark", "warning", "error"]) { stdout, stderr in
                XCTAssertMatch(stdout, isOnlyPrint)
                XCTAssertMatch(stderr, containsProgress)
                XCTAssertMatch(stderr, containsWarning)
                XCTAssertMatch(stderr, containsError)
            }

            // Quiet Mode
            //   - stdout is always printed
            //   - Diagnostics below 'error' are suppressed

            try await runPlugin(flags: ["-q"], diagnostics: ["print"]) { stdout, stderr in
                XCTAssertMatch(stdout, isOnlyPrint)
                XCTAssertMatch(stderr, isEmpty)
            }

            try await runPlugin(flags: ["-q"], diagnostics: ["print", "progress"]) { stdout, stderr in
            	XCTAssertMatch(stdout, isOnlyPrint)
                XCTAssertMatch(stderr, containsProgress)
            }

            try await runPlugin(flags: ["-q"], diagnostics: ["print", "progress", "remark"]) { stdout, stderr in
            	XCTAssertMatch(stdout, isOnlyPrint)
                XCTAssertMatch(stderr, containsProgress)
            }

            try await runPlugin(flags: ["-q"], diagnostics: ["print", "progress", "remark", "warning"]) { stdout, stderr in
            	XCTAssertMatch(stdout, isOnlyPrint)
                XCTAssertMatch(stderr, containsProgress)
            }

            try await runPluginWithError(flags: ["-q"], diagnostics: ["print", "progress", "remark", "warning", "error"]) { stdout, stderr in
            	XCTAssertMatch(stdout, isOnlyPrint)
            	XCTAssertMatch(stderr, containsProgress)
            	XCTAssertNoMatch(stderr, containsRemark)
                XCTAssertNoMatch(stderr, containsWarning)
                XCTAssertMatch(stderr, containsError)
            }

            // Verbose Mode
            //   - stdout is always printed
            //   - All diagnostics are printed
            //   - Substantial amounts of additional compiler output are also printed

            try await runPlugin(flags: ["-v"], diagnostics: ["print"]) { stdout, stderr in
                XCTAssertMatch(stdout, isOnlyPrint)
                // At this level stderr contains extra compiler output even if the plugin does not print diagnostics
            }

            try await runPlugin(flags: ["-v"], diagnostics: ["print", "progress"]) { stdout, stderr in
            	XCTAssertMatch(stdout, isOnlyPrint)
            	XCTAssertMatch(stderr, containsProgress)
            }

            try await runPlugin(flags: ["-v"], diagnostics: ["print", "progress", "remark"]) { stdout, stderr in
            	XCTAssertMatch(stdout, isOnlyPrint)
            	XCTAssertMatch(stderr, containsProgress)
                XCTAssertMatch(stderr, containsRemark)
            }

            try await runPlugin(flags: ["-v"], diagnostics: ["print", "progress", "remark", "warning"]) { stdout, stderr in
            	XCTAssertMatch(stdout, isOnlyPrint)
            	XCTAssertMatch(stderr, containsProgress)
                XCTAssertMatch(stderr, containsRemark)
                XCTAssertMatch(stderr, containsWarning)
            }

            try await runPluginWithError(flags: ["-v"], diagnostics: ["print", "progress", "remark", "warning", "error"]) { stdout, stderr in
            	XCTAssertMatch(stdout, isOnlyPrint)
            	XCTAssertMatch(stderr, containsProgress)
            	XCTAssertMatch(stderr, containsRemark)
                XCTAssertMatch(stderr, containsWarning)
                XCTAssertMatch(stderr, containsError)
            }
        }
    }

    // Test target builds requested by a command plugin
    func testCommandPluginTargetBuilds() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        let debugTarget = [".build", "debug", "placeholder"]
        let releaseTarget = [".build", "release", "placeholder"]

        func AssertIsExecutableFile(_ fixturePath: AbsolutePath, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssert(
                localFileSystem.isExecutableFile(fixturePath),
                "\(fixturePath) does not exist",
                file: file,
                line: line
            )
        }

        func AssertNotExists(_ fixturePath: AbsolutePath, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(
                localFileSystem.exists(fixturePath),
                "\(fixturePath) should not exist",
                file: file,
                line: line
            )
        }

        // By default, a plugin-requested build produces a debug binary
        try await fixture(name: "Miscellaneous/Plugins/CommandPluginTestStub") { fixturePath in
            let _ = try await SwiftPM.Package.execute(["-c", "release", "build-target"], packagePath: fixturePath)
            AssertIsExecutableFile(fixturePath.appending(components: debugTarget))
            AssertNotExists(fixturePath.appending(components: releaseTarget))
        }

        // If the plugin specifies a debug binary, that is what will be built, regardless of overall configuration
        try await fixture(name: "Miscellaneous/Plugins/CommandPluginTestStub") { fixturePath in
            let _ = try await SwiftPM.Package.execute(["-c", "release", "build-target", "build-debug"], packagePath: fixturePath)
            AssertIsExecutableFile(fixturePath.appending(components: debugTarget))
            AssertNotExists(fixturePath.appending(components: releaseTarget))
        }

        // If the plugin requests a release binary, that is what will be built, regardless of overall configuration
        try await fixture(name: "Miscellaneous/Plugins/CommandPluginTestStub") { fixturePath in
            let _ = try await SwiftPM.Package.execute(["-c", "debug", "build-target", "build-release"], packagePath: fixturePath)
            AssertNotExists(fixturePath.appending(components: debugTarget))
            AssertIsExecutableFile(fixturePath.appending(components: releaseTarget))
        }

        // If the plugin inherits the overall build configuration, that is what will be built
        try await fixture(name: "Miscellaneous/Plugins/CommandPluginTestStub") { fixturePath in
            let _ = try await SwiftPM.Package.execute(["-c", "debug", "build-target", "build-inherit"], packagePath: fixturePath)
            AssertIsExecutableFile(fixturePath.appending(components: debugTarget))
            AssertNotExists(fixturePath.appending(components: releaseTarget))
        }

        // If the plugin inherits the overall build configuration, that is what will be built
        try await fixture(name: "Miscellaneous/Plugins/CommandPluginTestStub") { fixturePath in
            let _ = try await SwiftPM.Package.execute(["-c", "release", "build-target", "build-inherit"], packagePath: fixturePath)
            AssertNotExists(fixturePath.appending(components: debugTarget))
            AssertIsExecutableFile(fixturePath.appending(components: releaseTarget))
        }
    }

    // Test logging of builds initiated by a command plugin
    func testCommandPluginBuildLogs() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        // Match patterns for expected messages

        let isEmpty = StringPattern.equal("")

        // result.logText printed by the plugin has a prefix
        let containsLogtext = StringPattern.contains("command plugin: packageManager.build logtext: Building for debugging...")

        // Echoed logs have no prefix
        let containsLogecho = StringPattern.regex("^Building for debugging...\n")

        // These tests involve building a target, so each test must run with a fresh copy of the fixture
        // otherwise the logs may be different in subsequent tests.

        // Check than nothing is echoed when echoLogs is false
        try await fixture(name: "Miscellaneous/Plugins/CommandPluginTestStub") { fixturePath in
            let (stdout, stderr) = try await SwiftPM.Package.execute(["print-diagnostics", "build"], packagePath: fixturePath, env: ["SWIFT_DRIVER_SWIFTSCAN_LIB" : "/this/is/a/bad/path"])
            XCTAssertMatch(stdout, isEmpty)
            XCTAssertMatch(stderr, isEmpty)
        }

        // Check that logs are returned to the plugin when echoLogs is false
        try await fixture(name: "Miscellaneous/Plugins/CommandPluginTestStub") { fixturePath in
            let (stdout, stderr) = try await SwiftPM.Package.execute(["print-diagnostics", "build", "printlogs"], packagePath: fixturePath, env: ["SWIFT_DRIVER_SWIFTSCAN_LIB" : "/this/is/a/bad/path"])
            XCTAssertMatch(stdout, containsLogtext)
            XCTAssertMatch(stderr, isEmpty)
        }

        // Check that logs echoed to the console (on stderr) when echoLogs is true
        try await fixture(name: "Miscellaneous/Plugins/CommandPluginTestStub") { fixturePath in
            let (stdout, stderr) = try await SwiftPM.Package.execute(["print-diagnostics", "build", "echologs"], packagePath: fixturePath, env: ["SWIFT_DRIVER_SWIFTSCAN_LIB" : "/this/is/a/bad/path"])
            XCTAssertMatch(stdout, isEmpty)
            XCTAssertMatch(stderr, containsLogecho)
        }

        // Check that logs are returned to the plugin and echoed to the console (on stderr) when echoLogs is true
        try await fixture(name: "Miscellaneous/Plugins/CommandPluginTestStub") { fixturePath in
            let (stdout, stderr) = try await SwiftPM.Package.execute(["print-diagnostics", "build", "printlogs", "echologs"], packagePath: fixturePath, env: ["SWIFT_DRIVER_SWIFTSCAN_LIB" : "/this/is/a/bad/path"])
            XCTAssertMatch(stdout, containsLogtext)
            XCTAssertMatch(stderr, containsLogecho)
        }
    }

    func testCommandPluginNetworkingPermissions(permissionsManifestFragment: String, permissionError: String, reason: String, remedy: [String]) async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.writeFileContents(packageDir.appending(components: "Package.swift"), string:
                """
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    targets: [
                        .target(name: "MyLibrary"),
                        .plugin(name: "MyPlugin", capability: .command(intent: .custom(verb: "Network", description: "Help description"), permissions: \(permissionsManifestFragment))),
                    ]
                )
                """
            )
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "MyLibrary", "library.swift"), string: "public func Foo() { }")
            try localFileSystem.writeFileContents(packageDir.appending(components: "Plugins", "MyPlugin", "plugin.swift"), string:
                """
                import PackagePlugin

                @main
                struct MyCommandPlugin: CommandPlugin {
                    func performCommand(context: PluginContext, arguments: [String]) throws {
                        print("hello world")
                    }
                }
                """
            )

            #if os(macOS)
            do {
                await XCTAssertAsyncThrowsError(try await SwiftPM.Package.execute(["plugin", "Network"], packagePath: packageDir)) { error in
                    guard case SwiftPMError.executionFailure(_, let stdout, let stderr) = error else {
                        return XCTFail("invalid error \(error)")
                    }
                    XCTAssertNoMatch(stdout, .contains("hello world"))
                    XCTAssertMatch(stderr, .contains("error: Plugin ‘MyPlugin’ wants permission to allow \(permissionError)."))
                    XCTAssertMatch(stderr, .contains("Stated reason: “\(reason)”."))
                    XCTAssertMatch(stderr, .contains("Use `\(remedy.joined(separator: " "))` to allow this."))
                }
            }
            #endif

            // Check that we don't get an error (and also are allowed to write to the package directory) if we pass `--allow-writing-to-package-directory`.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["plugin"] + remedy + ["Network"], packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("hello world"))
            }
        }
    }

    func testCommandPluginNetworkingPermissions() async throws {
        try await testCommandPluginNetworkingPermissions(
            permissionsManifestFragment: "[.allowNetworkConnections(scope: .all(), reason: \"internet good\")]",
            permissionError: "all network connections on all ports",
            reason: "internet good",
            remedy: ["--allow-network-connections", "all"])
        try await testCommandPluginNetworkingPermissions(
            permissionsManifestFragment: "[.allowNetworkConnections(scope: .all(ports: [23, 42, 443, 8080]), reason: \"internet good\")]",
            permissionError: "all network connections on ports: 23, 42, 443, 8080",
            reason: "internet good",
            remedy: ["--allow-network-connections", "all:23,42,443,8080"])
        try await testCommandPluginNetworkingPermissions(
            permissionsManifestFragment: "[.allowNetworkConnections(scope: .all(ports: 1..<4), reason: \"internet good\")]",
            permissionError: "all network connections on ports: 1, 2, 3",
            reason: "internet good",
            remedy: ["--allow-network-connections", "all:1,2,3"])

        try await testCommandPluginNetworkingPermissions(
            permissionsManifestFragment: "[.allowNetworkConnections(scope: .local(), reason: \"localhost good\")]",
            permissionError: "local network connections on all ports",
            reason: "localhost good",
            remedy: ["--allow-network-connections", "local"])
        try await testCommandPluginNetworkingPermissions(
            permissionsManifestFragment: "[.allowNetworkConnections(scope: .local(ports: [23, 42, 443, 8080]), reason: \"localhost good\")]",
            permissionError: "local network connections on ports: 23, 42, 443, 8080",
            reason: "localhost good",
            remedy: ["--allow-network-connections", "local:23,42,443,8080"])
        try await testCommandPluginNetworkingPermissions(
            permissionsManifestFragment: "[.allowNetworkConnections(scope: .local(ports: 1..<4), reason: \"localhost good\")]",
            permissionError: "local network connections on ports: 1, 2, 3",
            reason: "localhost good",
            remedy: ["--allow-network-connections", "local:1,2,3"])

        try await testCommandPluginNetworkingPermissions(
            permissionsManifestFragment: "[.allowNetworkConnections(scope: .docker, reason: \"docker good\")]",
            permissionError: "docker unix domain socket connections",
            reason: "docker good",
            remedy: ["--allow-network-connections", "docker"])
        try await testCommandPluginNetworkingPermissions(
            permissionsManifestFragment: "[.allowNetworkConnections(scope: .unixDomainSocket, reason: \"unix sockets good\")]",
            permissionError: "unix domain socket connections",
            reason: "unix sockets good",
            remedy: ["--allow-network-connections", "unixDomainSocket"])
    }

    func testCommandPluginPermissions() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(packageDir.appending(components: "Package.swift"), string:
                """
                // swift-tools-version: 5.6
                import PackageDescription
                import Foundation
                let package = Package(
                    name: "MyPackage",
                    targets: [
                        .target(
                            name: "MyLibrary"
                        ),
                        .plugin(
                            name: "MyPlugin",
                            capability: .command(
                                intent: .custom(verb: "PackageScribbler", description: "Help description"),
                                // We use an environment here so we can control whether we declare the permission.
                                permissions: ProcessInfo.processInfo.environment["DECLARE_PACKAGE_WRITING_PERMISSION"] == "1"
                                    ? [.writeToPackageDirectory(reason: "For testing purposes")]
                                    : []
                            )
                        ),
                    ]
                )
                """
            )
            let libPath = packageDir.appending(components: "Sources", "MyLibrary")
            try localFileSystem.createDirectory(libPath, recursive: true)
            try localFileSystem.writeFileContents(libPath.appending("library.swift"), string:
                "public func Foo() { }"
            )
            let pluginPath = packageDir.appending(components: "Plugins", "MyPlugin")
            try localFileSystem.createDirectory(pluginPath, recursive: true)
            try localFileSystem.writeFileContents(pluginPath.appending("plugin.swift"), string:
                """
                import PackagePlugin
                import Foundation

                @main
                struct MyCommandPlugin: CommandPlugin {
                    func performCommand(
                        context: PluginContext,
                        arguments: [String]
                    ) throws {
                        // Check that we can write to the package directory.
                        print("Trying to write to the package directory...")
                        guard FileManager.default.createFile(atPath: context.package.directory.appending("Foo").string, contents: Data("Hello".utf8)) else {
                            throw "Couldn’t create file at path \\(context.package.directory.appending("Foo"))"
                        }
                        print("... successfully created it")
                    }
                }
                extension String: Error {}
                """
            )

            // Check that we get an error if the plugin needs permission but if we don't give it to them. Note that sandboxing is only currently supported on macOS.
          #if os(macOS)
            do {
                await XCTAssertAsyncThrowsError(try await SwiftPM.Package.execute(["plugin", "PackageScribbler"], packagePath: packageDir, env: ["DECLARE_PACKAGE_WRITING_PERMISSION": "1"])) { error in
                    guard case SwiftPMError.executionFailure(_, let stdout, let stderr) = error else {
                        return XCTFail("invalid error \(error)")
                    }
                    XCTAssertNoMatch(stdout, .contains("successfully created it"))
                    XCTAssertMatch(stderr, .contains("error: Plugin ‘MyPlugin’ wants permission to write to the package directory."))
                    XCTAssertMatch(stderr, .contains("Stated reason: “For testing purposes”."))
                    XCTAssertMatch(stderr, .contains("Use `--allow-writing-to-package-directory` to allow this."))
                }
            }
          #endif

            // Check that we don't get an error (and also are allowed to write to the package directory) if we pass `--allow-writing-to-package-directory`.
            do {
                let (stdout, stderr) = try await SwiftPM.Package.execute(["plugin", "--allow-writing-to-package-directory", "PackageScribbler"], packagePath: packageDir, env: ["DECLARE_PACKAGE_WRITING_PERMISSION": "1"])
                XCTAssertMatch(stdout, .contains("successfully created it"))
                XCTAssertNoMatch(stderr, .contains("error: Couldn’t create file at path"))
            }

            // Check that we get an error if the plugin doesn't declare permission but tries to write anyway. Note that sandboxing is only currently supported on macOS.
          #if os(macOS)
            do {
                await XCTAssertAsyncThrowsError(try await SwiftPM.Package.execute(["plugin", "PackageScribbler"], packagePath: packageDir, env: ["DECLARE_PACKAGE_WRITING_PERMISSION": "0"])) { error in
                    guard case SwiftPMError.executionFailure(_, let stdout, let stderr) = error else {
                        return XCTFail("invalid error \(error)")
                    }
                    XCTAssertNoMatch(stdout, .contains("successfully created it"))
                    XCTAssertMatch(stderr, .contains("error: Couldn’t create file at path"))
                }
            }
          #endif

            // Check default command with arguments
            do {
                let (stdout, stderr) = try await SwiftPM.Package.execute(["--allow-writing-to-package-directory", "PackageScribbler"], packagePath: packageDir, env: ["DECLARE_PACKAGE_WRITING_PERMISSION": "1"])
                XCTAssertMatch(stdout, .contains("successfully created it"))
                XCTAssertNoMatch(stderr, .contains("error: Couldn’t create file at path"))
            }

            // Check plugin arguments after plugin name
            do {
                let (stdout, stderr) = try await SwiftPM.Package.execute(["plugin", "PackageScribbler",  "--allow-writing-to-package-directory"], packagePath: packageDir, env: ["DECLARE_PACKAGE_WRITING_PERMISSION": "1"])
                XCTAssertMatch(stdout, .contains("successfully created it"))
                XCTAssertNoMatch(stderr, .contains("error: Couldn’t create file at path"))
            }

            // Check default command with arguments after plugin name
            do {
                let (stdout, stderr) = try await SwiftPM.Package.execute(["PackageScribbler", "--allow-writing-to-package-directory", ], packagePath: packageDir, env: ["DECLARE_PACKAGE_WRITING_PERMISSION": "1"])
                XCTAssertMatch(stdout, .contains("successfully created it"))
                XCTAssertNoMatch(stderr, .contains("error: Couldn’t create file at path"))
            }
        }
    }

    func testCommandPluginArgumentsNotSwallowed() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")

            try localFileSystem.createDirectory(packageDir)
            try localFileSystem.writeFileContents(
                packageDir.appending(components: "Package.swift"),
                string: """
                // swift-tools-version: 5.6
                import PackageDescription
                import Foundation
                let package = Package(
                    name: "MyPackage",
                    targets: [
                        .plugin(
                            name: "MyPlugin",
                            capability: .command(
                                intent: .custom(verb: "MyPlugin", description: "Help description")
                            )
                        ),
                    ]
                )
                """
            )

            let pluginDir = packageDir.appending(components: "Plugins", "MyPlugin")
            try localFileSystem.createDirectory(pluginDir, recursive: true)
            try localFileSystem.writeFileContents(
                pluginDir.appending("plugin.swift"),
                string: """
                import PackagePlugin
                import Foundation

                @main
                struct MyCommandPlugin: CommandPlugin {
                    func performCommand(
                        context: PluginContext,
                        arguments: [String]
                    ) throws {
                        print (arguments)
                        guard arguments.contains("--foo") else {
                            throw "expecting argument foo"
                        }
                        guard arguments.contains("--help") else {
                            throw "expecting argument help"
                        }
                        guard arguments.contains("--version") else {
                            throw "expecting argument version"
                        }
                        guard arguments.contains("--verbose") else {
                            throw "expecting argument verbose"
                        }
                        print("success")
                    }
                }
                extension String: Error {}
                """
            )

            // Check arguments
            do {
                let (stdout, stderr) = try await SwiftPM.Package.execute(["plugin", "MyPlugin", "--foo", "--help", "--version", "--verbose"], packagePath: packageDir, env: ["SWIFT_DRIVER_SWIFTSCAN_LIB" : "/this/is/a/bad/path"])
                XCTAssertMatch(stdout, .contains("success"))
                XCTAssertEqual(stderr, "")
            }

            // Check default command arguments
            do {
                let (stdout, stderr) = try await SwiftPM.Package.execute(["MyPlugin", "--foo", "--help", "--version", "--verbose"], packagePath: packageDir, env: ["SWIFT_DRIVER_SWIFTSCAN_LIB" : "/this/is/a/bad/path"])
                XCTAssertMatch(stdout, .contains("success"))
                XCTAssertEqual(stderr, "")
            }
        }
    }

    func testCommandPluginSymbolGraphCallbacks() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        // Depending on how the test is running, the `swift-symbolgraph-extract` tool might be unavailable.
        try XCTSkipIf((try? UserToolchain.default.getSymbolGraphExtract()) == nil, "skipping test because the `swift-symbolgraph-extract` tools isn't available")

        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library, and executable, and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir)
            try localFileSystem.writeFileContents(
                packageDir.appending(components: "Package.swift"),
                string: """
                // swift-tools-version: 5.6
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    targets: [
                        .target(
                            name: "MyLibrary"
                        ),
                        .executableTarget(
                            name: "MyCommand",
                            dependencies: ["MyLibrary"]
                        ),
                        .plugin(
                            name: "MyPlugin",
                            capability: .command(
                                intent: .documentationGeneration()
                            )
                        ),
                    ]
                )
                """
            )

            let libraryPath = packageDir.appending(components: "Sources", "MyLibrary", "library.swift")
            try localFileSystem.createDirectory(libraryPath.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(
                libraryPath,
                string: #"public func GetGreeting() -> String { return "Hello" }"#
            )

            let commandPath = packageDir.appending(components: "Sources", "MyCommand", "main.swift")
            try localFileSystem.createDirectory(commandPath.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(
                commandPath,
                string: """
                import MyLibrary
                print("\\(GetGreeting()), World!")
                """
            )

            let pluginPath = packageDir.appending(components: "Plugins", "MyPlugin", "plugin.swift")
            try localFileSystem.createDirectory(pluginPath.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(
                pluginPath,
                string: """
                import PackagePlugin
                import Foundation

                @main
                struct MyCommandPlugin: CommandPlugin {
                    func performCommand(
                        context: PluginContext,
                        arguments: [String]
                    ) throws {
                        // Ask for and print out the symbol graph directory for each target.
                        var argExtractor = ArgumentExtractor(arguments)
                        let targetNames = argExtractor.extractOption(named: "target")
                        let targets = targetNames.isEmpty
                            ? context.package.targets
                            : try context.package.targets(named: targetNames)
                        for target in targets {
                            let symbolGraph = try packageManager.getSymbolGraph(for: target,
                                options: .init(minimumAccessLevel: .public))
                            print("\\(target.name): \\(symbolGraph.directoryPath)")
                        }
                    }
                }
                """
            )

            // Check that if we don't pass any target, we successfully get symbol graph information for all targets in the package, and at different paths.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["generate-documentation"], packagePath: packageDir)
                XCTAssertMatch(stdout, .and(.contains("MyLibrary:"), .contains("mypackage/MyLibrary")))
                XCTAssertMatch(stdout, .and(.contains("MyCommand:"), .contains("mypackage/MyCommand")))

            }

            // Check that if we pass a target, we successfully get symbol graph information for just the target we asked for.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["generate-documentation", "--target", "MyLibrary"], packagePath: packageDir)
                XCTAssertMatch(stdout, .and(.contains("MyLibrary:"), .contains("mypackage/MyLibrary")))
                XCTAssertNoMatch(stdout, .and(.contains("MyCommand:"), .contains("mypackage/MyCommand")))
            }
        }
    }

    func testCommandPluginBuildingCallbacks() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library, an executable, and a command plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(packageDir.appending(components: "Package.swift"), string: """
                // swift-tools-version: 5.6
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    products: [
                        .library(
                            name: "MyAutomaticLibrary",
                            targets: ["MyLibrary"]
                        ),
                        .library(
                            name: "MyStaticLibrary",
                            type: .static,
                            targets: ["MyLibrary"]
                        ),
                        .library(
                            name: "MyDynamicLibrary",
                            type: .dynamic,
                            targets: ["MyLibrary"]
                        ),
                        .executable(
                            name: "MyExecutable",
                            targets: ["MyExecutable"]
                        ),
                    ],
                    targets: [
                        .target(
                            name: "MyLibrary"
                        ),
                        .executableTarget(
                            name: "MyExecutable",
                            dependencies: ["MyLibrary"]
                        ),
                        .plugin(
                            name: "MyPlugin",
                            capability: .command(
                                intent: .custom(verb: "my-build-tester", description: "Help description")
                            )
                        ),
                    ]
                )
                """
            )
            let myPluginTargetDir = packageDir.appending(components: "Plugins", "MyPlugin")
            try localFileSystem.createDirectory(myPluginTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myPluginTargetDir.appending("plugin.swift"), string: """
                import PackagePlugin
                @main
                struct MyCommandPlugin: CommandPlugin {
                    func performCommand(
                        context: PluginContext,
                        arguments: [String]
                    ) throws {
                        // Extract the plugin arguments.
                        var argExtractor = ArgumentExtractor(arguments)
                        let productNames = argExtractor.extractOption(named: "product")
                        if productNames.count != 1 {
                            throw "Expected exactly one product name, but had: \\(productNames.joined(separator: ", "))"
                        }
                        let products = try context.package.products(named: productNames)
                        let printCommands = (argExtractor.extractFlag(named: "print-commands") > 0)
                        let release = (argExtractor.extractFlag(named: "release") > 0)
                        if let unextractedArgs = argExtractor.unextractedOptionsOrFlags.first {
                            throw "Unknown option: \\(unextractedArgs)"
                        }
                        let positionalArgs = argExtractor.remainingArguments
                        if !positionalArgs.isEmpty {
                            throw "Unexpected extra arguments: \\(positionalArgs)"
                        }
                        do {
                            var parameters = PackageManager.BuildParameters()
                            parameters.configuration = release ? .release : .debug
                            parameters.logging = printCommands ? .verbose : .concise
                            parameters.otherSwiftcFlags = ["-DEXTRA_SWIFT_FLAG"]
                            let result = try packageManager.build(.product(products[0].name), parameters: parameters)
                            print("succeeded: \\(result.succeeded)")
                            for artifact in result.builtArtifacts {
                                print("artifact-path: \\(artifact.path.string)")
                                print("artifact-kind: \\(artifact.kind)")
                            }
                            print("log:\\n\\(result.logText)")
                        }
                        catch {
                            print("error from the plugin host: \\(error)")
                        }
                    }
                }
                extension String: Error {}
                """
            )
            let myLibraryTargetDir = packageDir.appending(components: "Sources", "MyLibrary")
            try localFileSystem.createDirectory(myLibraryTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myLibraryTargetDir.appending("library.swift"), string: """
                public func GetGreeting() -> String { return "Hello" }
                """
            )
            let myExecutableTargetDir = packageDir.appending(components: "Sources", "MyExecutable")
            try localFileSystem.createDirectory(myExecutableTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myExecutableTargetDir.appending("main.swift"), string: """
                import MyLibrary
                print("\\(GetGreeting()), World!")
                """
            )

            // Invoke the plugin with parameters choosing a verbose build of MyExecutable for debugging.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["my-build-tester", "--product", "MyExecutable", "--print-commands"], packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("Building for debugging..."))
                XCTAssertNoMatch(stdout, .contains("Building for production..."))
                XCTAssertMatch(stdout, .contains("-module-name MyExecutable"))
                XCTAssertMatch(stdout, .contains("-DEXTRA_SWIFT_FLAG"))
                XCTAssertMatch(stdout, .contains("Build of product 'MyExecutable' complete!"))
                XCTAssertMatch(stdout, .contains("succeeded: true"))
                XCTAssertMatch(stdout, .and(.contains("artifact-path:"), .contains("debug/MyExecutable")))
                XCTAssertMatch(stdout, .and(.contains("artifact-kind:"), .contains("executable")))
            }

            // Invoke the plugin with parameters choosing a concise build of MyExecutable for release.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["my-build-tester", "--product", "MyExecutable", "--release"], packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("Building for production..."))
                XCTAssertNoMatch(stdout, .contains("Building for debug..."))
                XCTAssertNoMatch(stdout, .contains("-module-name MyExecutable"))
                XCTAssertMatch(stdout, .contains("Build of product 'MyExecutable' complete!"))
                XCTAssertMatch(stdout, .contains("succeeded: true"))
                XCTAssertMatch(stdout, .and(.contains("artifact-path:"), .contains("release/MyExecutable")))
                XCTAssertMatch(stdout, .and(.contains("artifact-kind:"), .contains("executable")))
            }

            // Invoke the plugin with parameters choosing a verbose build of MyStaticLibrary for release.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["my-build-tester", "--product", "MyStaticLibrary", "--print-commands", "--release"], packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("Building for production..."))
                XCTAssertNoMatch(stdout, .contains("Building for debug..."))
                XCTAssertNoMatch(stdout, .contains("-module-name MyLibrary"))
                XCTAssertMatch(stdout, .contains("Build of product 'MyStaticLibrary' complete!"))
                XCTAssertMatch(stdout, .contains("succeeded: true"))
                XCTAssertMatch(stdout, .and(.contains("artifact-path:"), .contains("release/libMyStaticLibrary.")))
                XCTAssertMatch(stdout, .and(.contains("artifact-kind:"), .contains("staticLibrary")))
            }

            // Invoke the plugin with parameters choosing a verbose build of MyDynamicLibrary for release.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["my-build-tester", "--product", "MyDynamicLibrary", "--print-commands", "--release"], packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("Building for production..."))
                XCTAssertNoMatch(stdout, .contains("Building for debug..."))
                XCTAssertNoMatch(stdout, .contains("-module-name MyLibrary"))
                XCTAssertMatch(stdout, .contains("Build of product 'MyDynamicLibrary' complete!"))
                XCTAssertMatch(stdout, .contains("succeeded: true"))
                XCTAssertMatch(stdout, .and(.contains("artifact-path:"), .contains("release/libMyDynamicLibrary.")))
                XCTAssertMatch(stdout, .and(.contains("artifact-kind:"), .contains("dynamicLibrary")))
            }
        }
    }

    func testCommandPluginTestingCallbacks() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        // Depending on how the test is running, the `llvm-profdata` and `llvm-cov` tool might be unavailable.
        try XCTSkipIf((try? UserToolchain.default.getLLVMProf()) == nil, "skipping test because the `llvm-profdata` tool isn't available")
        try XCTSkipIf((try? UserToolchain.default.getLLVMCov()) == nil, "skipping test because the `llvm-cov` tool isn't available")

        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library, a command plugin, and a couple of tests.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(packageDir.appending(components: "Package.swift"), string: """
                // swift-tools-version: 5.6
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    targets: [
                        .target(
                            name: "MyLibrary"
                        ),
                        .plugin(
                            name: "MyPlugin",
                            capability: .command(
                                intent: .custom(verb: "my-test-tester", description: "Help description")
                            )
                        ),
                        .testTarget(
                            name: "MyBasicTests"
                        ),
                        .testTarget(
                            name: "MyExtendedTests"
                        ),
                    ]
                )
                """
            )
            let myPluginTargetDir = packageDir.appending(components: "Plugins", "MyPlugin")
            try localFileSystem.createDirectory(myPluginTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myPluginTargetDir.appending("plugin.swift"), string: """
                import PackagePlugin
                @main
                struct MyCommandPlugin: CommandPlugin {
                    func performCommand(
                        context: PluginContext,
                        arguments: [String]
                    ) throws {
                        do {
                            let result = try packageManager.test(.filtered(["MyBasicTests"]), parameters: .init(enableCodeCoverage: true))
                            assert(result.succeeded == true)
                            assert(result.testTargets.count == 1)
                            assert(result.testTargets[0].name == "MyBasicTests")
                            assert(result.testTargets[0].testCases.count == 2)
                            assert(result.testTargets[0].testCases[0].name == "MyBasicTests.TestSuite1")
                            assert(result.testTargets[0].testCases[0].tests.count == 2)
                            assert(result.testTargets[0].testCases[0].tests[0].name == "testBooleanInvariants")
                            assert(result.testTargets[0].testCases[0].tests[1].result == .succeeded)
                            assert(result.testTargets[0].testCases[0].tests[1].name == "testNumericalInvariants")
                            assert(result.testTargets[0].testCases[0].tests[1].result == .succeeded)
                            assert(result.testTargets[0].testCases[1].name == "MyBasicTests.TestSuite2")
                            assert(result.testTargets[0].testCases[1].tests.count == 1)
                            assert(result.testTargets[0].testCases[1].tests[0].name == "testStringInvariants")
                            assert(result.testTargets[0].testCases[1].tests[0].result == .succeeded)
                            assert(result.codeCoverageDataFile?.extension == "json")
                        }
                        catch {
                            print("error from the plugin host: \\(error)")
                        }
                    }
                }
                """
            )
            let myLibraryTargetDir = packageDir.appending(components: "Sources", "MyLibrary")
            try localFileSystem.createDirectory(myLibraryTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myLibraryTargetDir.appending("library.swift"), string: """
                public func Foo() { }
                """
            )
            let myBasicTestsTargetDir = packageDir.appending(components: "Tests", "MyBasicTests")
            try localFileSystem.createDirectory(myBasicTestsTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myBasicTestsTargetDir.appending("Test1.swift"), string: """
                import XCTest
                class TestSuite1: XCTestCase {
                    func testBooleanInvariants() throws {
                        XCTAssertEqual(true || true, true)
                    }
                    func testNumericalInvariants() throws {
                        XCTAssertEqual(1 + 1, 2)
                    }
                }
                """
            )
            try localFileSystem.writeFileContents(myBasicTestsTargetDir.appending("Test2.swift"), string: """
                import XCTest
                class TestSuite2: XCTestCase {
                    func testStringInvariants() throws {
                        XCTAssertEqual("" + "", "")
                    }
                }
                """
            )
            let myExtendedTestsTargetDir = packageDir.appending(components: "Tests", "MyExtendedTests")
            try localFileSystem.createDirectory(myExtendedTestsTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myExtendedTestsTargetDir.appending("Test3.swift"), string: """
                import XCTest
                class TestSuite3: XCTestCase {
                    func testArrayInvariants() throws {
                        XCTAssertEqual([] + [], [])
                    }
                    func testImpossibilities() throws {
                        XCTFail("no can do")
                    }
                }
                """
            )

            // Check basic usage with filtering and code coverage. The plugin itself asserts a bunch of values.
            try await SwiftPM.Package.execute(["my-test-tester"], packagePath: packageDir)

            // We'll add checks for various error conditions here in a future commit.
        }
    }

    func testPluginAPIs() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a plugin to test various parts of the API.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(packageDir.appending("Package.swift"), string: """
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    dependencies: [
                        .package(name: "HelperPackage", path: "VendoredDependencies/HelperPackage")
                    ],
                    targets: [
                        .target(
                            name: "FirstTarget",
                            dependencies: [
                            ]
                        ),
                        .target(
                            name: "SecondTarget",
                            dependencies: [
                                "FirstTarget",
                            ]
                        ),
                        .target(
                            name: "ThirdTarget",
                            dependencies: [
                                "FirstTarget",
                            ]
                        ),
                        .target(
                            name: "FourthTarget",
                            dependencies: [
                                "SecondTarget",
                                "ThirdTarget",
                                .product(name: "HelperLibrary", package: "HelperPackage"),
                            ]
                        ),
                        .executableTarget(
                            name: "FifthTarget",
                            dependencies: [
                                "FirstTarget",
                                "ThirdTarget",
                            ]
                        ),
                        .testTarget(
                            name: "TestTarget",
                            dependencies: [
                                "SecondTarget",
                            ]
                        ),
                        .plugin(
                            name: "PrintTargetDependencies",
                            capability: .command(
                                intent: .custom(verb: "print-target-dependencies", description: "Plugin that prints target dependencies; argument is name of target")
                            )
                        ),
                    ]
                )
            """)

            let firstTargetDir = packageDir.appending(components: "Sources", "FirstTarget")
            try localFileSystem.createDirectory(firstTargetDir, recursive: true)
            try localFileSystem.writeFileContents(firstTargetDir.appending("library.swift"), string: """
                public func FirstFunc() { }
                """)

            let secondTargetDir = packageDir.appending(components: "Sources", "SecondTarget")
            try localFileSystem.createDirectory(secondTargetDir, recursive: true)
            try localFileSystem.writeFileContents(secondTargetDir.appending("library.swift"), string: """
                public func SecondFunc() { }
                """)

            let thirdTargetDir = packageDir.appending(components: "Sources", "ThirdTarget")
            try localFileSystem.createDirectory(thirdTargetDir, recursive: true)
            try localFileSystem.writeFileContents(thirdTargetDir.appending("library.swift"), string: """
                public func ThirdFunc() { }
                """)

            let fourthTargetDir = packageDir.appending(components: "Sources", "FourthTarget")
            try localFileSystem.createDirectory(fourthTargetDir, recursive: true)
            try localFileSystem.writeFileContents(fourthTargetDir.appending("library.swift"), string: """
                public func FourthFunc() { }
                """)

            let fifthTargetDir = packageDir.appending(components: "Sources", "FifthTarget")
            try localFileSystem.createDirectory(fifthTargetDir, recursive: true)
            try localFileSystem.writeFileContents(fifthTargetDir.appending("main.swift"), string: """
                @main struct MyExec {
                    func run() throws {}
                }
                """)

            let testTargetDir = packageDir.appending(components: "Tests", "TestTarget")
            try localFileSystem.createDirectory(testTargetDir, recursive: true)
            try localFileSystem.writeFileContents(testTargetDir.appending("tests.swift"), string: """
                import XCTest
                class MyTestCase: XCTestCase {
                }
                """)

            let pluginTargetTargetDir = packageDir.appending(components: "Plugins", "PrintTargetDependencies")
            try localFileSystem.createDirectory(pluginTargetTargetDir, recursive: true)
            try localFileSystem.writeFileContents(pluginTargetTargetDir.appending("plugin.swift"), string: """
                import PackagePlugin
                @main struct PrintTargetDependencies: CommandPlugin {
                    func performCommand(
                        context: PluginContext,
                        arguments: [String]
                    ) throws {
                        // Print names of the recursive dependencies of the given target.
                        var argExtractor = ArgumentExtractor(arguments)
                        guard let targetName = argExtractor.extractOption(named: "target").first else {
                            throw "No target argument provided"
                        }
                        guard let target = try? context.package.targets(named: [targetName]).first else {
                            throw "No target found with the name '\\(targetName)'"
                        }
                        print("Recursive dependencies of '\\(target.name)': \\(target.recursiveTargetDependencies.map(\\.name))")

                        let execProducts = context.package.products(ofType: ExecutableProduct.self)
                        print("execProducts: \\(execProducts.map{ $0.name })")
                        let swiftTargets = context.package.targets(ofType: SwiftSourceModuleTarget.self)
                        print("swiftTargets: \\(swiftTargets.map{ $0.name }.sorted())")
                        let swiftSources = swiftTargets.flatMap{ $0.sourceFiles(withSuffix: ".swift") }
                        print("swiftSources: \\(swiftSources.map{ $0.path.lastComponent }.sorted())")

                        if let target = target.sourceModule {
                            print("Module kind of '\\(target.name)': \\(target.kind)")
                        }

                        var sourceModules = context.package.sourceModules
                        print("sourceModules in package: \\(sourceModules.map { $0.name })")
                        sourceModules = context.package.products.first?.sourceModules ?? []
                        print("sourceModules in first product: \\(sourceModules.map { $0.name })")
                    }
                }
                extension String: Error {}
                """)

            // Create a separate vendored package so that we can test dependencies across products in other packages.
            let helperPackageDir = packageDir.appending(components: "VendoredDependencies", "HelperPackage")
            try localFileSystem.createDirectory(helperPackageDir, recursive: true)
            try localFileSystem.writeFileContents(helperPackageDir.appending("Package.swift"), string: """
                // swift-tools-version: 5.6
                import PackageDescription
                let package = Package(
                    name: "HelperPackage",
                    products: [
                        .library(
                            name: "HelperLibrary",
                            targets: ["HelperLibrary"])
                    ],
                    targets: [
                        .target(
                            name: "HelperLibrary",
                            path: ".")
                    ]
                )
                """)
            try localFileSystem.writeFileContents(helperPackageDir.appending("library.swift"), string: """
                public func Foo() { }
                """)

            // Check that a target doesn't include itself in its recursive dependencies.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["print-target-dependencies", "--target", "SecondTarget"], packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("Recursive dependencies of 'SecondTarget': [\"FirstTarget\"]"))
                XCTAssertMatch(stdout, .contains("Module kind of 'SecondTarget': generic"))
            }

            // Check that targets are not included twice in recursive dependencies.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["print-target-dependencies", "--target", "ThirdTarget"], packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("Recursive dependencies of 'ThirdTarget': [\"FirstTarget\"]"))
                XCTAssertMatch(stdout, .contains("Module kind of 'ThirdTarget': generic"))
            }

            // Check that product dependencies work in recursive dependencies.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["print-target-dependencies", "--target", "FourthTarget"], packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("Recursive dependencies of 'FourthTarget': [\"FirstTarget\", \"SecondTarget\", \"ThirdTarget\", \"HelperLibrary\"]"))
                XCTAssertMatch(stdout, .contains("Module kind of 'FourthTarget': generic"))
            }

            // Check some of the other utility APIs.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["print-target-dependencies", "--target", "FifthTarget"], packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("execProducts: [\"FifthTarget\"]"))
                XCTAssertMatch(stdout, .contains("swiftTargets: [\"FifthTarget\", \"FirstTarget\", \"FourthTarget\", \"SecondTarget\", \"TestTarget\", \"ThirdTarget\"]"))
                XCTAssertMatch(stdout, .contains("swiftSources: [\"library.swift\", \"library.swift\", \"library.swift\", \"library.swift\", \"main.swift\", \"tests.swift\"]"))
                XCTAssertMatch(stdout, .contains("Module kind of 'FifthTarget': executable"))
            }

            // Check a test target.
            do {
                let (stdout, _) = try await SwiftPM.Package.execute(["print-target-dependencies", "--target", "TestTarget"], packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("Recursive dependencies of 'TestTarget': [\"FirstTarget\", \"SecondTarget\"]"))
                XCTAssertMatch(stdout, .contains("Module kind of 'TestTarget': test"))
            }
        }
    }

    func testPluginCompilationBeforeBuilding() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a couple of plugins a other targets and products.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(packageDir.appending(components: "Package.swift"), string: """
                // swift-tools-version: 5.6
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    products: [
                        .library(
                            name: "MyLibrary",
                            targets: ["MyLibrary"]
                        ),
                        .executable(
                            name: "MyExecutable",
                            targets: ["MyExecutable"]
                        ),
                    ],
                    targets: [
                        .target(
                            name: "MyLibrary"
                        ),
                        .executableTarget(
                            name: "MyExecutable",
                            dependencies: ["MyLibrary"]
                        ),
                        .plugin(
                            name: "MyBuildToolPlugin",
                            capability: .buildTool()
                        ),
                        .plugin(
                            name: "MyCommandPlugin",
                            capability: .command(
                                intent: .custom(verb: "my-build-tester", description: "Help description")
                            )
                        ),
                    ]
                )
                """
            )
            let myLibraryTargetDir = packageDir.appending(components: "Sources", "MyLibrary")
            try localFileSystem.createDirectory(myLibraryTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myLibraryTargetDir.appending("library.swift"), string: """
                public func GetGreeting() -> String { return "Hello" }
                """
            )
            let myExecutableTargetDir = packageDir.appending(components: "Sources", "MyExecutable")
            try localFileSystem.createDirectory(myExecutableTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myExecutableTargetDir.appending("main.swift"), string: """
                import MyLibrary
                print("\\(GetGreeting()), World!")
                """
            )
            let myBuildToolPluginTargetDir = packageDir.appending(components: "Plugins", "MyBuildToolPlugin")
            try localFileSystem.createDirectory(myBuildToolPluginTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myBuildToolPluginTargetDir.appending("plugin.swift"), string: """
                import PackagePlugin
                @main struct MyBuildToolPlugin: BuildToolPlugin {
                    func createBuildCommands(
                        context: PluginContext,
                        target: Target
                    ) throws -> [Command] {
                        return []
                    }
                }
                """
            )
            let myCommandPluginTargetDir = packageDir.appending(components: "Plugins", "MyCommandPlugin")
            try localFileSystem.createDirectory(myCommandPluginTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myCommandPluginTargetDir.appending("plugin.swift"), string: """
                import PackagePlugin
                @main struct MyCommandPlugin: CommandPlugin {
                    func performCommand(
                        context: PluginContext,
                        arguments: [String]
                    ) throws {
                    }
                }
                """
            )

            // Check that building without options compiles both plugins and that the build proceeds.
            do {
                let (stdout, _) = try await SwiftPM.Build.execute(packagePath: packageDir)
                XCTAssertMatch(stdout, .contains("Compiling plugin MyBuildToolPlugin"))
                XCTAssertMatch(stdout, .contains("Compiling plugin MyCommandPlugin"))
                XCTAssertMatch(stdout, .contains("Building for debugging..."))
            }

            // Check that building just one of them just compiles that plugin and doesn't build anything else.
            do {
                let (stdout, _) = try await SwiftPM.Build.execute(["--target", "MyCommandPlugin"], packagePath: packageDir)
                XCTAssertNoMatch(stdout, .contains("Compiling plugin MyBuildToolPlugin"))
                XCTAssertMatch(stdout, .contains("Compiling plugin MyCommandPlugin"))
                XCTAssertNoMatch(stdout, .contains("Building for debugging..."))
            }

            // Deliberately break the command plugin.
            try localFileSystem.writeFileContents(myCommandPluginTargetDir.appending("plugin.swift"), string: """
                import PackagePlugin
                @main struct MyCommandPlugin: CommandPlugin {
                    func performCommand(
                        context: PluginContext,
                        arguments: [String]
                    ) throws {
                        this is an error
                    }
                }
                """
            )

            // Check that building stops after compiling the plugin and doesn't proceed.
            // Run this test a number of times to try to catch any race conditions.
            for _ in 1...5 {
                await XCTAssertAsyncThrowsError(try await SwiftPM.Build.execute(packagePath: packageDir)) { error in
                    guard case SwiftPMError.executionFailure(_, let stdout, _) = error else {
                        return XCTFail("invalid error \(error)")
                    }
                    XCTAssertMatch(stdout, .contains("Compiling plugin MyBuildToolPlugin"))
                    XCTAssertMatch(stdout, .contains("Compiling plugin MyCommandPlugin"))
                    XCTAssertMatch(stdout, .contains("error: consecutive statements on a line must be separated by ';'"))
                    XCTAssertNoMatch(stdout, .contains("Building for debugging..."))
                }
            }
        }
    }

    func testSinglePluginTarget() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(packageDir.appending("Package.swift"), string: """
                   // swift-tools-version: 5.7
                   import PackageDescription
                   let package = Package(
                       name: "MyPackage",
                       products: [
                           .plugin(name: "Foo", targets: ["Foo"])
                       ],
                       dependencies: [
                       ],
                       targets: [
                           .plugin(
                               name: "Foo",
                               capability: .command(
                                   intent: .custom(verb: "Foo", description: "Plugin example"),
                                   permissions: []
                               )
                           )
                       ]
                   )
                   """)

            let myPluginTargetDir = packageDir.appending(components: "Plugins", "Foo")
            try localFileSystem.createDirectory(myPluginTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myPluginTargetDir.appending("plugin.swift"), string: """
                     import PackagePlugin
                     @main struct FooPlugin: BuildToolPlugin {
                         func createBuildCommands(
                             context: PluginContext,
                             target: Target
                         ) throws -> [Command] { }
                     }
                     """)

            // Load a workspace from the package.
            let observability = ObservabilitySystem.makeForTesting()
            let workspace = try Workspace(
                fileSystem: localFileSystem,
                forRootPackage: packageDir,
                customManifestLoader: ManifestLoader(toolchain: UserToolchain.default),
                delegate: MockWorkspaceDelegate()
            )

            // Load the root manifest.
            let rootInput = PackageGraphRootInput(packages: [packageDir], dependencies: [])
            let rootManifests = try await workspace.loadRootManifests(
                packages: rootInput.packages,
                observabilityScope: observability.topScope
            )
            XCTAssert(rootManifests.count == 1, "\(rootManifests)")

            // Load the package graph.
            let _ = try workspace.loadPackageGraph(
                rootInput: rootInput,
                observabilityScope: observability.topScope
            )
            XCTAssertNoDiagnostics(observability.diagnostics)
        }
    }
}
