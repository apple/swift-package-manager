/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basics
@testable import Commands
import Foundation
import PackageGraph
import PackageLoading
import PackageModel
import SourceControl
import SPMTestSupport
import TSCBasic
import TSCUtility
import Workspace
import Xcodeproj
import XCTest

final class PackageToolTests: CommandsTestCase {
    @discardableResult
    private func execute(
        _ args: [String],
        packagePath: AbsolutePath? = nil,
        env: EnvironmentVariables? = nil
    ) throws -> (stdout: String, stderr: String) {
        var environment = env ?? [:]
        // don't ignore local packages when caching
        environment["SWIFTPM_TESTS_PACKAGECACHE"] = "1"
        return try SwiftPMProduct.SwiftPackage.execute(args, packagePath: packagePath, env: environment)
    }

    func testNoParameters() throws {
        let stdout = try execute([]).stdout
        XCTAssertMatch(stdout, .contains("USAGE: swift package"))
    }

    func testUsage() throws {
        let stdout = try execute(["-help"]).stdout
        XCTAssertMatch(stdout, .contains("USAGE: swift package"))
    }

    func testSeeAlso() throws {
        let stdout = try execute(["--help"]).stdout
        XCTAssertMatch(stdout, .contains("SEE ALSO: swift build, swift run, swift test"))
    }

    func testVersion() throws {
        let stdout = try execute(["--version"]).stdout
        XCTAssertMatch(stdout, .contains("Swift Package Manager"))
    }

    func testPlugin() throws {
        do {
            try execute(["plugin"])
            XCTFail("This should have been an error")
        } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
            XCTAssertMatch(stderr, .contains("error: Missing expected plugin command"))
        }
    }

    func testUnknownOption() throws {
        do {
            try execute(["--foo"])
            XCTFail("This should have been an error")
        } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
            XCTAssertMatch(stderr, .contains("error: Unknown option '--foo'"))
        }
    }

    func testUnknownSubommand() throws {
        fixture(name: "Miscellaneous/ExeTest") { pkgDir in
            do {
                try execute(["foo"], packagePath: pkgDir)
                XCTFail("This should have been an error")
            } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                XCTAssertMatch(stderr, .contains("error: Unknown subcommand or plugin name 'foo'"))
            }
        }
    }

    func testNetrc() throws {
        fixture(name: "DependencyResolution/External/XCFramework") { packageRoot in
            // --enable-netrc flag
            try self.execute(["resolve", "--enable-netrc"], packagePath: packageRoot)

            // --disable-netrc flag
            try self.execute(["resolve", "--disable-netrc"], packagePath: packageRoot)

            // --enable-netrc and --disable-netrc flags
            XCTAssertThrowsError(
                try self.execute(["resolve", "--enable-netrc", "--disable-netrc"], packagePath: packageRoot)
            ) { error in
                XCTAssertMatch(String(describing: error), .contains("Value to be set with flag '--disable-netrc' had already been set with flag '--enable-netrc'"))
            }

            // deprecated --netrc flag
            let stderr = try self.execute(["resolve", "--netrc"], packagePath: packageRoot).stderr
            XCTAssertMatch(stderr, .contains("'--netrc' option is deprecated"))
        }
    }

    func testNetrcOptional() throws {
        fixture(name: "DependencyResolution/External/XCFramework") { packageRoot in
            let stderr = try self.execute(["resolve", "--netrc-optional"], packagePath: packageRoot).stderr
            XCTAssertMatch(stderr, .contains("'--netrc-optional' option is deprecated"))
        }
    }

    func testNetrcFile() throws {
        fixture(name: "DependencyResolution/External/XCFramework") { packageRoot in
            let fs = localFileSystem
            let netrcPath = packageRoot.appending(component: ".netrc")
            try fs.writeFileContents(netrcPath) { stream in
                stream <<< "machine mymachine.labkey.org login user@labkey.org password mypassword"
            }

            // valid .netrc file path
            try execute(["resolve", "--netrc-file", netrcPath.pathString], packagePath: packageRoot)

            // valid .netrc file path with --disable-netrc option
            XCTAssertThrowsError(
                try execute(["resolve", "--netrc-file", netrcPath.pathString, "--disable-netrc"], packagePath: packageRoot)
            ) { error in
                XCTAssertMatch(String(describing: error), .contains("'--disable-netrc' and '--netrc-file' are mutually exclusive"))
            }

            // invalid .netrc file path
            XCTAssertThrowsError(
                try execute(["resolve", "--netrc-file", "/foo"], packagePath: packageRoot)
            ) { error in
                XCTAssertMatch(String(describing: error), .contains("Did not find .netrc file at /foo."))
            }

            // invalid .netrc file path with --disable-netrc option
            XCTAssertThrowsError(
                try execute(["resolve", "--netrc-file", "/foo", "--disable-netrc"], packagePath: packageRoot)
            ) { error in
                XCTAssertMatch(String(describing: error), .contains("'--disable-netrc' and '--netrc-file' are mutually exclusive"))
            }
        }
    }

    func testEnableDisableCache() throws {
        fixture(name: "DependencyResolution/External/Simple") { sandbox in
            let packageRoot = sandbox.appending(component: "Bar")
            let repositoriesPath = packageRoot.appending(components: ".build", "repositories")
            let cachePath = sandbox.appending(component: "cache")
            let repositoriesCachePath = cachePath.appending(component: "repositories")

            do {
                // Remove .build and cache folder
                _ = try execute(["reset"], packagePath: packageRoot)
                try localFileSystem.removeFileTree(cachePath)

                try self.execute(["resolve", "--enable-dependency-cache", "--cache-path", cachePath.pathString], packagePath: packageRoot)

                // we have to check for the prefix here since the hash value changes because spm sees the `prefix`
                // directory `/var/...` as `/private/var/...`.
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesCachePath).contains { $0.hasPrefix("Foo-") })

                // Remove .build folder
                _ = try execute(["reset"], packagePath: packageRoot)

                // Perform another cache this time from the cache
                _ = try execute(["resolve", "--enable-dependency-cache", "--cache-path", cachePath.pathString], packagePath: packageRoot)
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })

                // Remove .build and cache folder
                _ = try execute(["reset"], packagePath: packageRoot)
                try localFileSystem.removeFileTree(cachePath)

                // Perfom another fetch
                _ = try execute(["resolve", "--enable-dependency-cache", "--cache-path", cachePath.pathString], packagePath: packageRoot)
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesCachePath).contains { $0.hasPrefix("Foo-") })
            }

            do {
                // Remove .build and cache folder
                _ = try execute(["reset"], packagePath: packageRoot)
                try localFileSystem.removeFileTree(cachePath)

                try self.execute(["resolve", "--disable-dependency-cache", "--cache-path", cachePath.pathString], packagePath: packageRoot)

                // we have to check for the prefix here since the hash value changes because spm sees the `prefix`
                // directory `/var/...` as `/private/var/...`.
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })
                XCTAssertFalse(localFileSystem.exists(repositoriesCachePath))
            }

            do {
                // Remove .build and cache folder
                _ = try execute(["reset"], packagePath: packageRoot)
                try localFileSystem.removeFileTree(cachePath)

                let (_, stderr) = try self.execute(["resolve", "--enable-repository-cache", "--cache-path", cachePath.pathString], packagePath: packageRoot)
                XCTAssertMatch(stderr, .contains("'--disable-repository-cache'/'--enable-repository-cache' flags are deprecated; use '--disable-dependency-cache'/'--enable-dependency-cache' instead"))

                // we have to check for the prefix here since the hash value changes because spm sees the `prefix`
                // directory `/var/...` as `/private/var/...`.
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesCachePath).contains { $0.hasPrefix("Foo-") })

                // Remove .build folder
                _ = try execute(["reset"], packagePath: packageRoot)

                // Perform another cache this time from the cache
                _ = try execute(["resolve", "--enable-repository-cache", "--cache-path", cachePath.pathString], packagePath: packageRoot)
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })

                // Remove .build and cache folder
                _ = try execute(["reset"], packagePath: packageRoot)
                try localFileSystem.removeFileTree(cachePath)

                // Perfom another fetch
                _ = try execute(["resolve", "--enable-repository-cache", "--cache-path", cachePath.pathString], packagePath: packageRoot)
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesCachePath).contains { $0.hasPrefix("Foo-") })
            }

            do {
                // Remove .build and cache folder
                _ = try execute(["reset"], packagePath: packageRoot)
                try localFileSystem.removeFileTree(cachePath)

                let (_, stderr) = try self.execute(["resolve", "--disable-repository-cache", "--cache-path", cachePath.pathString], packagePath: packageRoot)
                XCTAssertMatch(stderr, .contains("'--disable-repository-cache'/'--enable-repository-cache' flags are deprecated; use '--disable-dependency-cache'/'--enable-dependency-cache' instead"))

                // we have to check for the prefix here since the hash value changes because spm sees the `prefix`
                // directory `/var/...` as `/private/var/...`.
                XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })
                XCTAssertFalse(localFileSystem.exists(repositoriesCachePath))
            }
        }
    }

    func testResolve() throws {
        fixture(name: "DependencyResolution/External/Simple") { prefix in
            let packageRoot = prefix.appending(component: "Bar")

            // Check that `resolve` works.
            _ = try execute(["resolve"], packagePath: packageRoot)
            let path = try SwiftPMProduct.packagePath(for: "Foo", packageRoot: packageRoot)
            XCTAssertEqual(try GitRepository(path: path).getTags(), ["1.2.3"])
        }
    }

    func testUpdate() throws {
        fixture(name: "DependencyResolution/External/Simple") { prefix in
            let packageRoot = prefix.appending(component: "Bar")

            // Perform an initial fetch.
            _ = try execute(["resolve"], packagePath: packageRoot)
            var path = try SwiftPMProduct.packagePath(for: "Foo", packageRoot: packageRoot)
            XCTAssertEqual(try GitRepository(path: path).getTags(), ["1.2.3"])

            // Retag the dependency, and update.
            let repo = GitRepository(path: prefix.appending(component: "Foo"))
            try repo.tag(name: "1.2.4")
            _ = try execute(["update"], packagePath: packageRoot)

            // We shouldn't assume package path will be same after an update so ask again for it.
            path = try SwiftPMProduct.packagePath(for: "Foo", packageRoot: packageRoot)
            XCTAssertEqual(try GitRepository(path: path).getTags(), ["1.2.3", "1.2.4"])
        }
    }

    func testCache() throws {
        fixture(name: "DependencyResolution/External/Simple") { prefix in
            let packageRoot = prefix.appending(component: "Bar")
            let repositoriesPath = packageRoot.appending(components: ".build", "repositories")
            let cachePath = prefix.appending(component: "cache")
            let repositoriesCachePath = cachePath.appending(component: "repositories")

            // Perform an initial fetch and populate the cache
            _ = try execute(["resolve", "--cache-path", cachePath.pathString], packagePath: packageRoot)
            // we have to check for the prefix here since the hash value changes because spm sees the `prefix`
            // directory `/var/...` as `/private/var/...`.
            XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })
            XCTAssert(try localFileSystem.getDirectoryContents(repositoriesCachePath).contains { $0.hasPrefix("Foo-") })

            // Remove .build folder
            _ = try execute(["reset"], packagePath: packageRoot)

            // Perform another cache this time from the cache
            _ = try execute(["resolve", "--cache-path", cachePath.pathString], packagePath: packageRoot)
            XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })

            // Remove .build and cache folder
            _ = try execute(["reset"], packagePath: packageRoot)
            try localFileSystem.removeFileTree(cachePath)

            // Perfom another fetch
            _ = try execute(["resolve", "--cache-path", cachePath.pathString], packagePath: packageRoot)
            XCTAssert(try localFileSystem.getDirectoryContents(repositoriesPath).contains { $0.hasPrefix("Foo-") })
            XCTAssert(try localFileSystem.getDirectoryContents(repositoriesCachePath).contains { $0.hasPrefix("Foo-") })
        }
    }

    func testDescribe() throws {
        fixture(name: "Miscellaneous/ExeTest") { prefix in
            // Generate the JSON description.
            let jsonResult = try SwiftPMProduct.SwiftPackage.executeProcess(["describe", "--type=json"], packagePath: prefix)
            let jsonOutput = try jsonResult.utf8Output()
            let json = try JSON(bytes: ByteString(encodingAsUTF8: jsonOutput))

            // Check that tests don't appear in the product memberships.
            XCTAssertEqual(json["name"]?.string, "ExeTest")
            let jsonTarget0 = try XCTUnwrap(json["targets"]?.array?[0])
            XCTAssertNil(jsonTarget0["product_memberships"])
            let jsonTarget1 = try XCTUnwrap(json["targets"]?.array?[1])
            XCTAssertEqual(jsonTarget1["product_memberships"]?.array?[0].stringValue, "Exe")
        }

        fixture(name: "CFamilyTargets/SwiftCMixed") { prefix in
            // Generate the JSON description.
            let jsonResult = try SwiftPMProduct.SwiftPackage.executeProcess(["describe", "--type=json"], packagePath: prefix)
            let jsonOutput = try jsonResult.utf8Output()
            let json = try JSON(bytes: ByteString(encodingAsUTF8: jsonOutput))

            // Check that the JSON description contains what we expect it to.
            XCTAssertEqual(json["name"]?.string, "SwiftCMixed")
            XCTAssertMatch(json["path"]?.string, .prefix("/"))
            XCTAssertMatch(json["path"]?.string, .suffix("/" + prefix.basename))
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
            let textResult = try SwiftPMProduct.SwiftPackage.executeProcess(["describe", "--type=text"], packagePath: prefix)
            let textOutput = try textResult.utf8Output()
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
            XCTAssertMatch(textChunk0, .contains("/" + prefix.basename + "\n"))
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

        fixture(name: "DependencyResolution/External/Simple/Bar") { prefix in
            // Generate the JSON description.
            let jsonResult = try SwiftPMProduct.SwiftPackage.executeProcess(["describe", "--type=json"], packagePath: prefix)
            let jsonOutput = try jsonResult.utf8Output()
            let json = try JSON(bytes: ByteString(encodingAsUTF8: jsonOutput))

            // Check that product dependencies and memberships are as expected.
            XCTAssertEqual(json["name"]?.string, "Bar")
            let jsonTarget = try XCTUnwrap(json["targets"]?.array?[0])
            XCTAssertEqual(jsonTarget["product_memberships"]?.array?[0].stringValue, "Bar")
            XCTAssertEqual(jsonTarget["product_dependencies"]?.array?[0].stringValue, "Foo")
            XCTAssertNil(jsonTarget["target_dependencies"])
        }

    }

    func testDescribePackageUsingPlugins() throws {
        fixture(name: "Miscellaneous/Plugins/MySourceGenPlugin") { prefix in
            // Generate the JSON description.
            let result = try SwiftPMProduct.SwiftPackage.executeProcess(["describe", "--type=json"], packagePath: prefix)
            XCTAssert(result.exitStatus == .terminated(code: 0), "`swift-package describe` failed: \(String(describing: try? result.utf8stderrOutput()))")
            let json = try JSON(bytes: ByteString(encodingAsUTF8: result.utf8Output()))

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

    func testDumpPackage() throws {
        fixture(name: "DependencyResolution/External/Complex") { prefix in
            let packageRoot = prefix.appending(component: "app")
            let (dumpOutput, _) = try execute(["dump-package"], packagePath: packageRoot)
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

    func testShowDependencies() throws {
        fixture(name: "DependencyResolution/External/Complex") { prefix in
            let packageRoot = prefix.appending(component: "app")
            let textOutput = try SwiftPMProduct.SwiftPackage.executeProcess(["show-dependencies", "--format=text"], packagePath: packageRoot).utf8Output()
            XCTAssert(textOutput.contains("FisherYates@1.2.3"))

            let jsonOutput = try SwiftPMProduct.SwiftPackage.executeProcess(["show-dependencies", "--format=json"], packagePath: packageRoot).utf8Output()
            let json = try JSON(bytes: ByteString(encodingAsUTF8: jsonOutput))
            guard case let .dictionary(contents) = json else { XCTFail("unexpected result"); return }
            guard case let .string(name)? = contents["name"] else { XCTFail("unexpected result"); return }
            XCTAssertEqual(name, "Dealer")
            guard case let .string(path)? = contents["path"] else { XCTFail("unexpected result"); return }
            XCTAssertEqual(resolveSymlinks(AbsolutePath(path)), resolveSymlinks(packageRoot))
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
            name: "PackageA",
            path: .init("/PackageA"),
            toolsVersion: .v5_3,
            dependencies: [
                .fileSystem(path: .init("/PackageB")),
                .fileSystem(path: .init("/PackageC")),
            ],
            products: [
                .init(name: "exe", type: .executable, targets: ["TargetA"])
            ],
            targets: [
                try .init(name: "TargetA", dependencies: ["PackageB", "PackageC"])
            ]
        )

        let manifestB = Manifest.createFileSystemManifest(
            name: "PackageB",
            path: .init("/PackageB"),
            toolsVersion: .v5_3,
            dependencies: [
                .fileSystem(path: .init("/PackageC")),
                .fileSystem(path: .init("/PackageD")),
            ],
            products: [
                .init(name: "PackageB", type: .library(.dynamic), targets: ["TargetB"])
            ],
            targets: [
                try .init(name: "TargetB", dependencies: ["PackageC", "PackageD"])
            ]
        )

        let manifestC = Manifest.createFileSystemManifest(
            name: "PackageC",
            path: .init("/PackageC"),
            toolsVersion: .v5_3,
            dependencies: [
                .fileSystem(path: .init("/PackageD")),
            ],
            products: [
                .init(name: "PackageC", type: .library(.dynamic), targets: ["TargetC"])
            ],
            targets: [
                try .init(name: "TargetC", dependencies: ["PackageD"])
            ]
        )

        let manifestD = Manifest.createFileSystemManifest(
            name: "PackageD",
            path: .init("/PackageD"),
            toolsVersion: .v5_3,
            products: [
                .init(name: "PackageD", type: .library(.dynamic), targets: ["TargetD"])
            ],
            targets: [
                try .init(name: "TargetD")
            ]
        )

        let observability = ObservabilitySystem.makeForTesting()
        let graph = try loadPackageGraph(
            fs: fileSystem,
            manifests: [manifestA, manifestB, manifestC, manifestD],
            observabilityScope: observability.topScope
        )
        XCTAssertNoDiagnostics(observability.diagnostics)

        let output = BufferedOutputByteStream()
        SwiftPackageTool.ShowDependencies.dumpDependenciesOf(rootPackage: graph.rootPackages[0], mode: .dot, on: output)
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

    func testShowDependencies_redirectJsonOutput() throws {
        try testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let root = tmpPath.appending(components: "root")
            let dep = tmpPath.appending(components: "dep")

            // Create root package.
            try fs.writeFileContents(root.appending(components: "Sources", "root", "main.swift")) { $0 <<< "" }
            try fs.writeFileContents(root.appending(component: "Package.swift")) {
                $0 <<< """
                // swift-tools-version:4.2
                import PackageDescription
                let package = Package(
                name: "root",
                dependencies: [.package(url: "../dep", from: "1.0.0")],
                targets: [.target(name: "root", dependencies: ["dep"])]
                )
                """
            }

            // Create dependency.
            try fs.writeFileContents(dep.appending(components: "Sources", "dep", "lib.swift")) { $0 <<< "" }
            try fs.writeFileContents(dep.appending(component: "Package.swift")) {
                $0 <<< """
                // swift-tools-version:4.2
                import PackageDescription
                let package = Package(
                name: "dep",
                products: [.library(name: "dep", targets: ["dep"])],
                targets: [.target(name: "dep")]
                )
                """
            }
            do {
                let depGit = GitRepository(path: dep)
                try depGit.create()
                try depGit.stageEverything()
                try depGit.commit()
                try depGit.tag(name: "1.0.0")
            }

            let resultPath = root.appending(component: "result.json")
            _ = try execute(["show-dependencies", "--format", "json", "--output-path", resultPath.pathString ], packagePath: root)

            XCTAssertFileExists(resultPath)
            let jsonOutput = try fs.readFileContents(resultPath)
            let json = try JSON(bytes: jsonOutput)

            XCTAssertEqual(json["name"]?.string, "root")
            XCTAssertEqual(json["dependencies"]?[0]?["name"]?.string, "dep")
        }
    }

    func testInitEmpty() throws {
        try testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending(component: "Foo")
            try fs.createDirectory(path)
            _ = try execute(["init", "--type", "empty"], packagePath: path)

            XCTAssertFileExists(path.appending(component: "Package.swift"))
            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Sources")), [])
            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Tests")), [])
        }
    }

    func testInitExecutable() throws {
        try testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending(component: "Foo")
            try fs.createDirectory(path)
            _ = try execute(["init", "--type", "executable"], packagePath: path)

            let manifest = path.appending(component: "Package.swift")
            let contents = try localFileSystem.readFileContents(manifest).description
            let version = InitPackage.newPackageToolsVersion
            let versionSpecifier = "\(version.major).\(version.minor)"
            XCTAssertMatch(contents, .prefix("// swift-tools-version:\(version < .v5_4 ? "" : " ")\(versionSpecifier)\n"))

            XCTAssertFileExists(manifest)
            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Sources").appending(component: "Foo")), ["main.swift"])
            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Tests")).sorted(), ["FooTests"])
        }
    }

    func testInitLibrary() throws {
        try testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending(component: "Foo")
            try fs.createDirectory(path)
            _ = try execute(["init"], packagePath: path)

            XCTAssertFileExists(path.appending(component: "Package.swift"))
            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Sources").appending(component: "Foo")), ["Foo.swift"])
            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Tests")).sorted(), ["FooTests"])
        }
    }

    func testInitCustomNameExecutable() throws {
        try testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending(component: "Foo")
            try fs.createDirectory(path)
            _ = try execute(["init", "--name", "CustomName", "--type", "executable"], packagePath: path)

            let manifest = path.appending(component: "Package.swift")
            let contents = try localFileSystem.readFileContents(manifest).description
            let version = InitPackage.newPackageToolsVersion
            let versionSpecifier = "\(version.major).\(version.minor)"
            XCTAssertMatch(contents, .prefix("// swift-tools-version:\(version < .v5_4 ? "" : " ")\(versionSpecifier)\n"))

            XCTAssertFileExists(manifest)
            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Sources").appending(component: "CustomName")), ["main.swift"])
            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Tests")).sorted(), ["CustomNameTests"])
        }
    }

    func testPackageEditAndUnedit() {
        fixture(name: "Miscellaneous/PackageEdit") { prefix in
            let fooPath = prefix.appending(component: "foo")
            func build() throws -> (stdout: String, stderr: String) {
                return try SwiftPMProduct.SwiftBuild.execute([], packagePath: fooPath)
            }

            // Put bar and baz in edit mode.
            _ = try SwiftPMProduct.SwiftPackage.execute(["edit", "bar", "--branch", "bugfix"], packagePath: fooPath)
            _ = try SwiftPMProduct.SwiftPackage.execute(["edit", "baz", "--branch", "bugfix"], packagePath: fooPath)

            // Path to the executable.
            let exec = [fooPath.appending(components: ".build", UserToolchain.default.triple.platformBuildPathComponent(), "debug", "foo").pathString]

            // We should see it now in packages directory.
            let editsPath = fooPath.appending(components: "Packages", "bar")
            XCTAssertDirectoryExists(editsPath)

            let bazEditsPath = fooPath.appending(components: "Packages", "baz")
            XCTAssertDirectoryExists(bazEditsPath)
            // Removing baz externally should just emit an warning and not a build failure.
            try localFileSystem.removeFileTree(bazEditsPath)

            // Do a modification in bar and build.
            try localFileSystem.writeFileContents(editsPath.appending(components: "Sources", "bar.swift"), bytes: "public let theValue = 88888\n")
            let (_, stderr) = try build()

            XCTAssertMatch(stderr, .contains("dependency 'baz' was being edited but is missing; falling back to original checkout"))
            // We should be able to see that modification now.
            XCTAssertEqual(try Process.checkNonZeroExit(arguments: exec), "88888\n")
            // The branch of edited package should be the one we provided when putting it in edit mode.
            let editsRepo = GitRepository(path: editsPath)
            XCTAssertEqual(try editsRepo.currentBranch(), "bugfix")

            // It shouldn't be possible to unedit right now because of uncommited changes.
            do {
                _ = try SwiftPMProduct.SwiftPackage.execute(["unedit", "bar"], packagePath: fooPath)
                XCTFail("Unexpected unedit success")
            } catch {}

            try editsRepo.stageEverything()
            try editsRepo.commit()

            // It shouldn't be possible to unedit right now because of unpushed changes.
            do {
                _ = try SwiftPMProduct.SwiftPackage.execute(["unedit", "bar"], packagePath: fooPath)
                XCTFail("Unexpected unedit success")
            } catch {}

            // Push the changes.
            try editsRepo.push(remote: "origin", branch: "bugfix")

            // We should be able to unedit now.
            _ = try SwiftPMProduct.SwiftPackage.execute(["unedit", "bar"], packagePath: fooPath)

            // Test editing with a path i.e. ToT development.
            let bazTot = prefix.appending(component: "tot")
            try SwiftPMProduct.SwiftPackage.execute(["edit", "baz", "--path", bazTot.pathString], packagePath: fooPath)
            XCTAssertTrue(localFileSystem.exists(bazTot))
            XCTAssertTrue(localFileSystem.isSymlink(bazEditsPath))

            // Edit a file in baz ToT checkout.
            let bazTotPackageFile = bazTot.appending(component: "Package.swift")
            let stream = BufferedOutputByteStream()
            stream <<< (try localFileSystem.readFileContents(bazTotPackageFile)) <<< "\n// Edited."
            try localFileSystem.writeFileContents(bazTotPackageFile, bytes: stream.bytes)

            // Unediting baz will remove the symlink but not the checked out package.
            try SwiftPMProduct.SwiftPackage.execute(["unedit", "baz"], packagePath: fooPath)
            XCTAssertTrue(localFileSystem.exists(bazTot))
            XCTAssertFalse(localFileSystem.isSymlink(bazEditsPath))

            // Check that on re-editing with path, we don't make a new clone.
            try SwiftPMProduct.SwiftPackage.execute(["edit", "baz", "--path", bazTot.pathString], packagePath: fooPath)
            XCTAssertTrue(localFileSystem.isSymlink(bazEditsPath))
            XCTAssertEqual(try localFileSystem.readFileContents(bazTotPackageFile), stream.bytes)
        }
    }

    func testPackageClean() throws {
        fixture(name: "DependencyResolution/External/Simple") { prefix in
            let packageRoot = prefix.appending(component: "Bar")

            // Build it.
            XCTAssertBuilds(packageRoot)
            let buildPath = packageRoot.appending(component: ".build")
            let binFile = buildPath.appending(components: UserToolchain.default.triple.platformBuildPathComponent(), "debug", "Bar")
            XCTAssertFileExists(binFile)
            XCTAssert(localFileSystem.isDirectory(buildPath))

            // Clean, and check for removal of the build directory but not Packages.
            _ = try execute(["clean"], packagePath: packageRoot)
            XCTAssertNoSuchPath(binFile)
            // Clean again to ensure we get no error.
            _ = try execute(["clean"], packagePath: packageRoot)
        }
    }

    func testPackageReset() throws {
        fixture(name: "DependencyResolution/External/Simple") { prefix in
            let packageRoot = prefix.appending(component: "Bar")

            // Build it.
            XCTAssertBuilds(packageRoot)
            let buildPath = packageRoot.appending(component: ".build")
            let binFile = buildPath.appending(components: UserToolchain.default.triple.platformBuildPathComponent(), "debug", "Bar")
            XCTAssertFileExists(binFile)
            XCTAssert(localFileSystem.isDirectory(buildPath))
            // Clean, and check for removal of the build directory but not Packages.

            _ = try execute(["clean"], packagePath: packageRoot)
            XCTAssertNoSuchPath(binFile)
            XCTAssertFalse(try localFileSystem.getDirectoryContents(buildPath.appending(component: "repositories")).isEmpty)

            // Fully clean.
            _ = try execute(["reset"], packagePath: packageRoot)
            XCTAssertFalse(localFileSystem.isDirectory(buildPath))

            // Test that we can successfully run reset again.
            _ = try execute(["reset"], packagePath: packageRoot)
        }
    }

    func testPinningBranchAndRevision() throws {
        fixture(name: "Miscellaneous/PackageEdit") { prefix in
            let fooPath = prefix.appending(component: "foo")

            @discardableResult
            func execute(_ args: String..., printError: Bool = true) throws -> String {
                return try SwiftPMProduct.SwiftPackage.execute([] + args, packagePath: fooPath).stdout
            }

            try execute("update")

            let pinsFile = fooPath.appending(component: "Package.resolved")
            XCTAssertFileExists(pinsFile)

            // Update bar repo.
            let barPath = prefix.appending(component: "bar")
            let barRepo = GitRepository(path: barPath)
            try barRepo.checkout(newBranch: "YOLO")
            let yoloRevision = try barRepo.getCurrentRevision()

            // Try to pin bar at a branch.
            do {
                try execute("resolve", "bar", "--branch", "YOLO")
                let pinsStore = try PinsStore(pinsFile: pinsFile, workingDirectory: prefix, fileSystem: localFileSystem, mirrors: .init())
                let state = PinsStore.PinState.branch(name: "YOLO", revision: yoloRevision.identifier)
                let identity = PackageIdentity(path: barPath)
                XCTAssertEqual(pinsStore.pinsMap[identity]?.state, state)
            }

            // Try to pin bar at a revision.
            do {
                try execute("resolve", "bar", "--revision", yoloRevision.identifier)
                let pinsStore = try PinsStore(pinsFile: pinsFile, workingDirectory: prefix, fileSystem: localFileSystem, mirrors: .init())
                let state = PinsStore.PinState.revision(yoloRevision.identifier)
                let identity = PackageIdentity(path: barPath)
                XCTAssertEqual(pinsStore.pinsMap[identity]?.state, state)
            }

            // Try to pin bar at a bad revision.
            do {
                try execute("resolve", "bar", "--revision", "xxxxx")
                XCTFail()
            } catch {}
        }
    }

    func testPinning() throws {
        fixture(name: "Miscellaneous/PackageEdit") { prefix in
            let fooPath = prefix.appending(component: "foo")
            func build() throws -> String {
                return try SwiftPMProduct.SwiftBuild.execute([], packagePath: fooPath).stdout
            }
            let exec = [fooPath.appending(components: ".build", UserToolchain.default.triple.platformBuildPathComponent(), "debug", "foo").pathString]

            // Build and sanity check.
            _ = try build()
            XCTAssertEqual(try Process.checkNonZeroExit(arguments: exec).spm_chomp(), "\(5)")

            // Get path to bar checkout.
            let barPath = try SwiftPMProduct.packagePath(for: "bar", packageRoot: fooPath)

            // Checks the content of checked out bar.swift.
            func checkBar(_ value: Int, file: StaticString = #file, line: UInt = #line) throws {
                let contents = try localFileSystem.readFileContents(barPath.appending(components:"Sources", "bar.swift")).validDescription?.spm_chomp()
                XCTAssert(contents?.hasSuffix("\(value)") ?? false, file: file, line: line)
            }

            // We should see a pin file now.
            let pinsFile = fooPath.appending(component: "Package.resolved")
            XCTAssertFileExists(pinsFile)

            // Test pins file.
            do {
                let pinsStore = try PinsStore(pinsFile: pinsFile, workingDirectory: prefix, fileSystem: localFileSystem, mirrors: .init())
                XCTAssertEqual(pinsStore.pins.map{$0}.count, 2)
                for pkg in ["bar", "baz"] {
                    let path = try SwiftPMProduct.packagePath(for: pkg, packageRoot: fooPath)
                    let pin = pinsStore.pinsMap[PackageIdentity(path: path)]!
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
            func execute(_ args: String...) throws -> String {
                return try SwiftPMProduct.SwiftPackage.execute([] + args, packagePath: fooPath).stdout
            }

            // Try to pin bar.
            do {
                try execute("resolve", "bar")
                let pinsStore = try PinsStore(pinsFile: pinsFile, workingDirectory: prefix, fileSystem: localFileSystem, mirrors: .init())
                let identity = PackageIdentity(path: barPath)
                switch pinsStore.pinsMap[identity]?.state {
                case .version(let version, revision: _):
                    XCTAssertEqual(version, "1.2.3")
                default:
                    XCTFail("invalid pin state")
                }
            }

            // Update bar repo.
            do {
                let barPath = prefix.appending(component: "bar")
                let barRepo = GitRepository(path: barPath)
                try localFileSystem.writeFileContents(barPath.appending(components: "Sources", "bar.swift"), bytes: "public let theValue = 6\n")
                try barRepo.stageEverything()
                try barRepo.commit()
                try barRepo.tag(name: "1.2.4")
            }

            // Running package update with --repin should update the package.
            do {
                try execute("update")
                try checkBar(6)
            }

            // We should be able to revert to a older version.
            do {
                try execute("resolve", "bar", "--version", "1.2.3")
                let pinsStore = try PinsStore(pinsFile: pinsFile, workingDirectory: prefix, fileSystem: localFileSystem, mirrors: .init())
                let identity = PackageIdentity(path: barPath)
                switch pinsStore.pinsMap[identity]?.state {
                case .version(let version, revision: _):
                    XCTAssertEqual(version, "1.2.3")
                default:
                    XCTFail("invalid pin state")
                }
                try checkBar(5)
            }

            // Try pinning a dependency which is in edit mode.
            do {
                try execute("edit", "bar", "--branch", "bugfix")
                do {
                    try execute("resolve", "bar")
                    XCTFail("This should have been an error")
                } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                    XCTAssertMatch(stderr, .contains("error: edited dependency 'bar' can't be resolved"))
                }
                try execute("unedit", "bar")
            }
        }
    }

    func testSymlinkedDependency() throws {
        try testWithTemporaryDirectory { path in
            let fs = localFileSystem
            let root = path.appending(components: "root")
            let dep = path.appending(components: "dep")
            let depSym = path.appending(components: "depSym")

            // Create root package.
            try fs.writeFileContents(root.appending(components: "Sources", "root", "main.swift")) { $0 <<< "" }
            try fs.writeFileContents(root.appending(component: "Package.swift")) {
                $0 <<< """
                // swift-tools-version:4.2
                import PackageDescription
                let package = Package(
                name: "root",
                dependencies: [.package(url: "../depSym", from: "1.0.0")],
                targets: [.target(name: "root", dependencies: ["dep"])]
                )

                """
            }

            // Create dependency.
            try fs.writeFileContents(dep.appending(components: "Sources", "dep", "lib.swift")) { $0 <<< "" }
            try fs.writeFileContents(dep.appending(component: "Package.swift")) {
                $0 <<< """
                // swift-tools-version:4.2
                import PackageDescription
                let package = Package(
                name: "dep",
                products: [.library(name: "dep", targets: ["dep"])],
                targets: [.target(name: "dep")]
                )
                """
            }
            do {
                let depGit = GitRepository(path: dep)
                try depGit.create()
                try depGit.stageEverything()
                try depGit.commit()
                try depGit.tag(name: "1.0.0")
            }

            // Create symlink to the dependency.
            try fs.createSymbolicLink(depSym, pointingAt: dep, relative: false)

            _ = try execute(["resolve"], packagePath: root)
        }
    }

    func testWatchmanXcodeprojgen() throws {
        try testWithTemporaryDirectory { path in
            let fs = localFileSystem
            let observability = ObservabilitySystem.makeForTesting()

            let scriptsDir = path.appending(component: "scripts")
            let packageRoot = path.appending(component: "root")

            let helper = WatchmanHelper(
                watchmanScriptsDir: scriptsDir,
                packageRoot: packageRoot,
                fileSystem: fs,
                observabilityScope: observability.topScope
            )

            let script = try helper.createXcodegenScript(
                XcodeprojOptions(xcconfigOverrides: .init("/tmp/overrides.xcconfig")))

            XCTAssertEqual(try fs.readFileContents(script), """
                #!/usr/bin/env bash


                # Autogenerated by SwiftPM. Do not edit!


                set -eu

                swift package generate-xcodeproj --xcconfig-overrides /tmp/overrides.xcconfig

                """)
        }
    }

    func testMirrorConfig() throws {
        try testWithTemporaryDirectory { prefix in
            let fs = localFileSystem
            let packageRoot = prefix.appending(component: "Foo")
            let configOverride = prefix.appending(component: "configoverride")
            let configFile = Workspace.DefaultLocations.mirrorsConfigurationFile(forRootPackage: packageRoot)

            fs.createEmptyFiles(at: packageRoot, files:
                "/Sources/Foo/Foo.swift",
                "/Tests/FooTests/FooTests.swift",
                "/Package.swift",
                "anchor"
            )

            // Test writing.
            var (stdout, stderr) = try execute(["config", "set-mirror", "--package-url", "https://github.com/foo/bar", "--mirror-url", "https://mygithub.com/foo/bar"], packagePath: packageRoot)
            XCTAssertMatch(stderr, .contains("warning: '--package-url' option is deprecated; use '--original-url' instead"))
            try execute(["config", "set-mirror", "--original-url", "git@github.com:apple/swift-package-manager.git", "--mirror-url", "git@mygithub.com:foo/swift-package-manager.git"], packagePath: packageRoot)
            XCTAssertTrue(fs.isFile(configFile))

            // Test env override.
            try execute(["config", "set-mirror", "--original-url", "https://github.com/foo/bar", "--mirror-url", "https://mygithub.com/foo/bar"], packagePath: packageRoot, env: ["SWIFTPM_MIRROR_CONFIG": configOverride.pathString])
            XCTAssertTrue(fs.isFile(configOverride))
            XCTAssertTrue(try fs.readFileContents(configOverride).description.contains("mygithub"))

            // Test reading.
            (stdout, stderr) = try execute(["config", "get-mirror", "--package-url", "https://github.com/foo/bar"], packagePath: packageRoot)
            XCTAssertEqual(stdout.spm_chomp(), "https://mygithub.com/foo/bar")
            XCTAssertMatch(stderr, .contains("warning: '--package-url' option is deprecated; use '--original-url' instead"))
            (stdout, _) = try execute(["config", "get-mirror", "--original-url", "git@github.com:apple/swift-package-manager.git"], packagePath: packageRoot)
            XCTAssertEqual(stdout.spm_chomp(), "git@mygithub.com:foo/swift-package-manager.git")

            func check(stderr: String, _ block: () throws -> ()) {
                do {
                    try block()
                    XCTFail()
                } catch SwiftPMProductError.executionFailure(_, _, let stderrOutput) {
                    XCTAssertMatch(stderrOutput, .contains(stderr))
                } catch {
                    XCTFail("unexpected error: \(error)")
                }
            }

            check(stderr: "not found\n") {
                try execute(["config", "get-mirror", "--original-url", "foo"], packagePath: packageRoot)
            }

            // Test deletion.
            (_, stderr) = try execute(["config", "unset-mirror", "--package-url", "https://github.com/foo/bar"], packagePath: packageRoot)
            XCTAssertMatch(stderr, .contains("warning: '--package-url' option is deprecated; use '--original-url' instead"))
            try execute(["config", "unset-mirror", "--original-url", "git@mygithub.com:foo/swift-package-manager.git"], packagePath: packageRoot)

            check(stderr: "not found\n") {
                try execute(["config", "get-mirror", "--original-url", "https://github.com/foo/bar"], packagePath: packageRoot)
            }
            check(stderr: "not found\n") {
                try execute(["config", "get-mirror", "--original-url", "git@github.com:apple/swift-package-manager.git"], packagePath: packageRoot)
            }

            check(stderr: "error: Mirror not found for 'foo'\n") {
                try execute(["config", "unset-mirror", "--original-url", "foo"], packagePath: packageRoot)
            }
        }
    }

    func testPackageLoadingCommandPathResilience() throws {
      #if os(macOS)
        fixture(name: "ValidLayouts/SingleModule") { prefix in
            try testWithTemporaryDirectory { tmpdir in
                // Create fake `xcrun` and `sandbox-exec` commands.
                let fakeBinDir = tmpdir
                for fakeCmdName in ["xcrun", "sandbox-exec"] {
                    let fakeCmdPath = fakeBinDir.appending(component: fakeCmdName)
                    try localFileSystem.writeFileContents(fakeCmdPath, body: { stream in
                        stream <<< """
                        #!/bin/sh
                        echo "wrong \(fakeCmdName) invoked"
                        exit 1
                        """
                    })
                    try localFileSystem.chmod(.executable, path: fakeCmdPath)
                }

                // Invoke `swift-package`, passing in the overriding `PATH` environment variable.
                let packageRoot = prefix.appending(component: "Library")
                let patchedPATH = fakeBinDir.pathString + ":" + ProcessInfo.processInfo.environment["PATH"]!
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["dump-package"], packagePath: packageRoot, env: ["PATH": patchedPATH])
                let textOutput = try result.utf8Output() + result.utf8stderrOutput()

                // Check that the wrong tools weren't invoked.  We can't just check the exit code because of fallbacks.
                XCTAssertNoMatch(textOutput, .contains("wrong xcrun invoked"))
                XCTAssertNoMatch(textOutput, .contains("wrong sandbox-exec invoked"))
            }
        }
      #endif
    }

    func testBuildToolPlugin() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        
        try testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.writeFileContents(packageDir.appending(component: "Package.swift")) {
                $0 <<< """
                // swift-tools-version: 5.5
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
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "MyLibrary", "library.swift")) {
                $0 <<< """
                    public func Foo() { }
                """
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "MyLibrary", "library.foo")) {
                $0 <<< """
                    a file with a filename suffix handled by the plugin
                """
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "MyLibrary", "library.bar")) {
                $0 <<< """
                    a file with a filename suffix not handled by the plugin
                """
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "Plugins", "MyPlugin", "plugin.swift")) {
                $0 <<< """
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
                            let fooFiles = (target as? SourceModuleTarget)?.sourceFiles.compactMap{ $0.path.extension == "foo" ? $0.path : nil } ?? []
                            return [ .buildCommand(displayName: "A command", executable: Path("/bin/echo"), arguments: fooFiles, inputFiles: fooFiles) ]
                        }

                    }
                    extension String : Error {}
                """
            }
            
            // Invoke it, and check the results.
            let result = try SwiftPMProduct.SwiftBuild.executeProcess([], packagePath: packageDir)
            let output = try result.utf8Output() + result.utf8stderrOutput()
            XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
            XCTAssert(output.contains("Build complete!"))
            
            // We expect a warning about `library.bar` but not about `library.foo`.
            let stderrOutput = try result.utf8stderrOutput()
            XCTAssertMatch(stderrOutput, .contains("found 1 file(s) which are unhandled"))
            XCTAssertNoMatch(stderrOutput, .contains("Sources/MyLibrary/library.foo"))
            XCTAssertMatch(stderrOutput, .contains("Sources/MyLibrary/library.bar"))
        }
    }

    func testBuildToolPluginFailure() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        
        try testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(packageDir.appending(component: "Package.swift"), string: """
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
            try localFileSystem.writeFileContents(myLibraryTargetDir.appending(component: "library.swift"), string: """
                public func Foo() { }
                """
            )
            let myPluginTargetDir = packageDir.appending(components: "Plugins", "MyPlugin")
            try localFileSystem.createDirectory(myPluginTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myPluginTargetDir.appending(component: "plugin.swift"), string: """
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
            let result = try SwiftPMProduct.SwiftBuild.executeProcess(["-v"], packagePath: packageDir)
            let output = try result.utf8Output() + result.utf8stderrOutput()
            XCTAssertNotEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
            XCTAssertMatch(output, .contains("This is text from the plugin"))
            XCTAssertMatch(output, .contains("error: This is an error from the plugin"))
            XCTAssertMatch(output, .contains("Build complete!"))
        }
    }

    func testArchiveSource() throws {
        fixture(name: "DependencyResolution/External/Simple") { prefix in
            let packageRoot = prefix.appending(component: "Bar")

            // Running without arguments or options
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["archive-source"], packagePath: packageRoot)
                XCTAssertEqual(result.exitStatus, .terminated(code: 0))

                let stdoutOutput = try result.utf8Output()
                XCTAssert(stdoutOutput.contains("Created Bar.zip"), #"actual: "\#(stdoutOutput)""#)

                // Running without arguments or options again, overwriting existing archive
                do {
                    let result = try SwiftPMProduct.SwiftPackage.executeProcess(["archive-source"], packagePath: packageRoot)
                    XCTAssertEqual(result.exitStatus, .terminated(code: 0))

                    let stdoutOutput = try result.utf8Output()
                    XCTAssert(stdoutOutput.contains("Created Bar.zip"), #"actual: "\#(stdoutOutput)""#)
                }
            }

            // Runnning with output as absolute path within package root
            do {
                let destination = packageRoot.appending(component: "Bar-1.2.3.zip")
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["archive-source", "--output", destination.pathString], packagePath: packageRoot)
                XCTAssertEqual(result.exitStatus, .terminated(code: 0))

                let stdoutOutput = try result.utf8Output()
                XCTAssert(stdoutOutput.contains("Created Bar-1.2.3.zip"), #"actual: "\#(stdoutOutput)""#)
            }

            // Running with output is outside the package root
            try withTemporaryDirectory { tempDirectory in
                let destination = tempDirectory.appending(component: "Bar-1.2.3.zip")
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["archive-source", "--output", destination.pathString], packagePath: packageRoot)
                XCTAssertEqual(result.exitStatus, .terminated(code: 0))

                let stdoutOutput = try result.utf8Output()
                XCTAssert(stdoutOutput.hasPrefix("Created /"), #"actual: "\#(stdoutOutput)""#)
                XCTAssert(stdoutOutput.contains("Bar-1.2.3.zip"), #"actual: "\#(stdoutOutput)""#)
            }

            // Running without arguments or options in non-package directory
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["archive-source"], packagePath: prefix)
                XCTAssertEqual(result.exitStatus, .terminated(code: 1))

                let stderrOutput = try result.utf8stderrOutput()
                XCTAssert(stderrOutput.contains("error: Could not find Package.swift in this directory or any of its parent directories."), #"actual: "\#(stderrOutput)""#)
            }

            // Runnning with output as absolute path to existing directory
            do {
                let destination = AbsolutePath.root
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["archive-source", "--output", destination.pathString], packagePath: packageRoot)
                XCTAssertEqual(result.exitStatus, .terminated(code: 1))

                let stderrOutput = try result.utf8stderrOutput()
                XCTAssert(
                    stderrOutput.contains("error: Couldn’t create an archive:"),
                    #"actual: "\#(stderrOutput)""#
                )
            }
        }
    }
    
    func testCommandPlugin() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        
        try testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target, a plugin, and a local tool. It depends on a sample package which also has a tool.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.writeFileContents(packageDir.appending(components: "Package.swift")) {
                $0 <<< """
                // swift-tools-version: 5.6
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
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "MyLibrary", "library.swift")) {
                $0 <<< """
                public func Foo() { }
                """
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "MyLibrary", "test.docc")) {
                $0 <<< """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>CFBundleName</key>
                    <string>sample</string>
                </dict>
                """
            }
            let hostTriple = try UserToolchain(destination: .hostDestination()).triple
            let hostTripleString = hostTriple.isDarwin() ? hostTriple.tripleString(forPlatformVersion: "") : hostTriple.tripleString
            try localFileSystem.writeFileContents(packageDir.appending(components: "Binaries", "LocalBinaryTool.artifactbundle", "info.json")) {
                $0 <<< """
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
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "LocalBuiltTool", "main.swift")) {
                $0 <<< """
                print("Hello")
                """
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "Plugins", "MyPlugin", "plugin.swift")) {
                $0 <<< """
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
                        if let sourceFiles = (targets.first{ $0.name == "MyLibrary" } as? SourceModuleTarget)?.sourceFiles {
                            for file in sourceFiles {
                                print("  \\(file.path): \\(file.type)")
                            }
                        }
                    }
                }
                """
            }

            // Create the sample vendored dependency package.
            try localFileSystem.writeFileContents(packageDir.appending(components: "VendoredDependencies", "HelperPackage", "Package.swift")) {
                $0 <<< """
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
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "VendoredDependencies", "HelperPackage", "Sources", "HelperLibrary", "library.swift")) {
                $0 <<< """
                public func Bar() { }
                """
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "VendoredDependencies", "HelperPackage", "Sources", "RemoteBuiltTool", "main.swift")) {
                $0 <<< """
                print("Hello")
                """
            }

            // Check that we can invoke the plugin with the "plugin" subcommand.
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["plugin", "mycmd"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .contains("This is MyCommandPlugin."))
            }

            // Check that we can also invoke it without the "plugin" subcommand.
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["mycmd"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .contains("This is MyCommandPlugin."))
            }

            // Testing listing the available command plugins.
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["plugin", "--list"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .contains("‘mycmd’ (plugin ‘MyPlugin’ in package ‘MyPackage’)"))
            }

            // Check that we get the expected error if trying to invoke a plugin with the wrong name.
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["my-nonexistent-cmd"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertNotEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .contains("error: Unknown subcommand or plugin name 'my-nonexistent-cmd'"))
            }

            // Check that the .docc file was properly vended to the plugin.
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["mycmd", "--target", "MyLibrary"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .contains("Sources/MyLibrary/library.swift: source"))
                XCTAssertMatch(output, .contains("Sources/MyLibrary/test.docc: unknown"))
            }

            // Check that the initial working directory is what we expected.
            do {
                let workingDirectory = FileManager.default.currentDirectoryPath
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["mycmd"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .contains("Initial working directory: \(workingDirectory)"))
            }
        }
    }

    func testCommandPluginPermissions() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        
        try testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.writeFileContents(packageDir.appending(components: "Package.swift")) {
                $0 <<< """
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
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "MyLibrary", "library.swift")) {
                $0 <<< """
                public func Foo() { }
                """
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "Plugins", "MyPlugin", "plugin.swift")) {
                $0 <<< """
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
            }

            // Check that we get an error if the plugin needs permission but if we don't give it to them. Note that sandboxing is only currently supported on macOS.
          #if os(macOS)
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["plugin", "PackageScribbler"], packagePath: packageDir, env: ["DECLARE_PACKAGE_WRITING_PERMISSION": "1"])
                XCTAssertNotEqual(result.exitStatus, .terminated(code: 0))
                XCTAssertNoMatch(try result.utf8Output(), .contains("successfully created it"))
                XCTAssertMatch(try result.utf8stderrOutput(), .contains("error: Plugin ‘MyPlugin’ needs permission to write to the package directory (stated reason: “For testing purposes”)"))
            }
          #endif

            // Check that we don't get an error (and also are allowed to write to the package directory) if we pass `--allow-writing-to-package-directory`.
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["plugin", "--allow-writing-to-package-directory", "PackageScribbler"], packagePath: packageDir, env: ["DECLARE_PACKAGE_WRITING_PERMISSION": "1"])
                XCTAssertEqual(result.exitStatus, .terminated(code: 0))
                XCTAssertMatch(try result.utf8Output(), .contains("successfully created it"))
                XCTAssertNoMatch(try result.utf8stderrOutput(), .contains("error: Couldn’t create file at path"))
            }

            // Check that we get an error if the plugin doesn't declare permission but tries to write anyway. Note that sandboxing is only currently supported on macOS.
          #if os(macOS)
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["plugin", "PackageScribbler"], packagePath: packageDir, env: ["DECLARE_PACKAGE_WRITING_PERMISSION": "0"])
                XCTAssertNotEqual(result.exitStatus, .terminated(code: 0))
                XCTAssertNoMatch(try result.utf8Output(), .contains("successfully created it"))
                XCTAssertMatch(try result.utf8stderrOutput(), .contains("error: Couldn’t create file at path"))
            }
          #endif
        }
    }

    func testCommandPluginSymbolGraphCallbacks() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        
        // Depending on how the test is running, the `swift-symbolgraph-extract` tool might be unavailable.
        try XCTSkipIf((try? UserToolchain.default.getSymbolGraphExtract()) == nil, "skipping test because the `swift-symbolgraph-extract` tools isn't available")
        
        try testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library, and executable, and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.writeFileContents(packageDir.appending(components: "Package.swift")) {
                $0 <<< """
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
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "MyLibrary", "library.swift")) {
                $0 <<< """
                public func GetGreeting() -> String { return "Hello" }
                """
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "MyCommand", "main.swift")) {
                $0 <<< """
                import MyLibrary
                print("\\(GetGreeting()), World!")
                """
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "Plugins", "MyPlugin", "plugin.swift")) {
                $0 <<< """
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
            }

            // Check that if we don't pass any target, we successfully get symbol graph information for all targets in the package, and at different paths.
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["generate-documentation"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .and(.contains("MyLibrary:"), .contains("mypackage/MyLibrary")))
                XCTAssertMatch(output, .and(.contains("MyCommand:"), .contains("mypackage/MyCommand")))

            }

            // Check that if we pass a target, we successfully get symbol graph information for just the target we asked for.
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["generate-documentation", "--target", "MyLibrary"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .and(.contains("MyLibrary:"), .contains("mypackage/MyLibrary")))
                XCTAssertNoMatch(output, .and(.contains("MyCommand:"), .contains("mypackage/MyCommand")))
            }
        }
    }

    func testCommandPluginBuildingCallbacks() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        
        try testWithTemporaryDirectory { tmpPath in
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
            try localFileSystem.writeFileContents(myPluginTargetDir.appending(component: "plugin.swift"), string: """
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
            try localFileSystem.writeFileContents(myLibraryTargetDir.appending(component: "library.swift"), string: """
                public func GetGreeting() -> String { return "Hello" }
                """
            )
            let myExecutableTargetDir = packageDir.appending(components: "Sources", "MyExecutable")
            try localFileSystem.createDirectory(myExecutableTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myExecutableTargetDir.appending(component: "main.swift"), string: """
                import MyLibrary
                print("\\(GetGreeting()), World!")
                """
            )

            // Invoke the plugin with parameters choosing a verbose build of MyExecutable for debugging.
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["my-build-tester", "--product", "MyExecutable", "--print-commands"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .contains("Building for debugging..."))
                XCTAssertNoMatch(output, .contains("Building for production..."))
                XCTAssertMatch(output, .contains("-module-name MyExecutable"))
                XCTAssertMatch(output, .contains("-DEXTRA_SWIFT_FLAG"))
                XCTAssertMatch(output, .contains("Build complete!"))
                XCTAssertMatch(output, .contains("succeeded: true"))
                XCTAssertMatch(output, .and(.contains("artifact-path:"), .contains("debug/MyExecutable")))
                XCTAssertMatch(output, .and(.contains("artifact-kind:"), .contains("executable")))
            }

            // Invoke the plugin with parameters choosing a concise build of MyExecutable for release.
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["my-build-tester", "--product", "MyExecutable", "--release"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .contains("Building for production..."))
                XCTAssertNoMatch(output, .contains("Building for debug..."))
                XCTAssertNoMatch(output, .contains("-module-name MyExecutable"))
                XCTAssertMatch(output, .contains("Build complete!"))
                XCTAssertMatch(output, .contains("succeeded: true"))
                XCTAssertMatch(output, .and(.contains("artifact-path:"), .contains("release/MyExecutable")))
                XCTAssertMatch(output, .and(.contains("artifact-kind:"), .contains("executable")))
            }

            // Invoke the plugin with parameters choosing a verbose build of MyStaticLibrary for release.
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["my-build-tester", "--product", "MyStaticLibrary", "--print-commands", "--release"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .contains("Building for production..."))
                XCTAssertNoMatch(output, .contains("Building for debug..."))
                XCTAssertNoMatch(output, .contains("-module-name MyLibrary"))
                XCTAssertMatch(output, .contains("Build complete!"))
                XCTAssertMatch(output, .contains("succeeded: true"))
                XCTAssertMatch(output, .and(.contains("artifact-path:"), .contains("release/libMyStaticLibrary.")))
                XCTAssertMatch(output, .and(.contains("artifact-kind:"), .contains("staticLibrary")))
            }

            // Invoke the plugin with parameters choosing a verbose build of MyDynamicLibrary for release.
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["my-build-tester", "--product", "MyDynamicLibrary", "--print-commands", "--release"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .contains("Building for production..."))
                XCTAssertNoMatch(output, .contains("Building for debug..."))
                XCTAssertNoMatch(output, .contains("-module-name MyLibrary"))
                XCTAssertMatch(output, .contains("Build complete!"))
                XCTAssertMatch(output, .contains("succeeded: true"))
                XCTAssertMatch(output, .and(.contains("artifact-path:"), .contains("release/libMyDynamicLibrary.")))
                XCTAssertMatch(output, .and(.contains("artifact-kind:"), .contains("dynamicLibrary")))
            }
        }
    }

    func testCommandPluginTestingCallbacks() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        
        // Depending on how the test is running, the `llvm-profdata` and `llvm-cov` tool might be unavailable.
        try XCTSkipIf((try? UserToolchain.default.getLLVMProf()) == nil, "skipping test because the `llvm-profdata` tool isn't available")
        try XCTSkipIf((try? UserToolchain.default.getLLVMCov()) == nil, "skipping test because the `llvm-cov` tool isn't available")

        try testWithTemporaryDirectory { tmpPath in
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
            try localFileSystem.writeFileContents(myPluginTargetDir.appending(component: "plugin.swift"), string: """
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
            try localFileSystem.writeFileContents(myLibraryTargetDir.appending(component: "library.swift"), string: """
                public func Foo() { }
                """
            )
            let myBasicTestsTargetDir = packageDir.appending(components: "Tests", "MyBasicTests")
            try localFileSystem.createDirectory(myBasicTestsTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myBasicTestsTargetDir.appending(component: "Test1.swift"), string: """
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
            try localFileSystem.writeFileContents(myBasicTestsTargetDir.appending(component: "Test2.swift"), string: """
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
            try localFileSystem.writeFileContents(myExtendedTestsTargetDir.appending(component: "Test3.swift"), string: """
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
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["my-test-tester"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                print(output)
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
            }

            // We'll add checks for various error conditions here in a future commit.
        }
    }
    
    func testPluginAPIs() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        
        try testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a plugin to test various parts of the API.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(packageDir.appending(component: "Package.swift"), string: """
                // swift-tools-version: 5.6
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
            try localFileSystem.writeFileContents(firstTargetDir.appending(component: "library.swift"), string: """
                public func FirstFunc() { }
                """)
            
            let secondTargetDir = packageDir.appending(components: "Sources", "SecondTarget")
            try localFileSystem.createDirectory(secondTargetDir, recursive: true)
            try localFileSystem.writeFileContents(secondTargetDir.appending(component: "library.swift"), string: """
                public func SecondFunc() { }
                """)
            
            let thirdTargetDir = packageDir.appending(components: "Sources", "ThirdTarget")
            try localFileSystem.createDirectory(thirdTargetDir, recursive: true)
            try localFileSystem.writeFileContents(thirdTargetDir.appending(component: "library.swift"), string: """
                public func ThirdFunc() { }
                """)
            
            let fourthTargetDir = packageDir.appending(components: "Sources", "FourthTarget")
            try localFileSystem.createDirectory(fourthTargetDir, recursive: true)
            try localFileSystem.writeFileContents(fourthTargetDir.appending(component: "library.swift"), string: """
                public func FourthFunc() { }
                """)

            let pluginTargetTargetDir = packageDir.appending(components: "Plugins", "PrintTargetDependencies")
            try localFileSystem.createDirectory(pluginTargetTargetDir, recursive: true)
            try localFileSystem.writeFileContents(pluginTargetTargetDir.appending(component: "plugin.swift"), string: """
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
                    }
                }
                extension String: Error {}
                """)
            
            // Create a separate vendored package so that we can test dependencies across products in other packages.
            let helperPackageDir = packageDir.appending(components: "VendoredDependencies", "HelperPackage")
            try localFileSystem.createDirectory(helperPackageDir, recursive: true)
            try localFileSystem.writeFileContents(helperPackageDir.appending(component: "Package.swift"), string: """
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
            try localFileSystem.writeFileContents(helperPackageDir.appending(component: "library.swift"), string: """
                public func Foo() { }
                """)

            // Check that a target doesn't include itself in its recursive dependencies.
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["print-target-dependencies", "--target", "SecondTarget"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .contains("of 'SecondTarget': [\"FirstTarget\"]"))
            }

            // Check that targets are not included twice in recursive dependencies.
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["print-target-dependencies", "--target", "ThirdTarget"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .contains("of 'ThirdTarget': [\"FirstTarget\"]"))
            }

            // Check that product dependencies work in recursive dependencies.
            do {
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["print-target-dependencies", "--target", "FourthTarget"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .contains("of 'FourthTarget': [\"FirstTarget\", \"SecondTarget\", \"ThirdTarget\", \"HelperLibrary\"]"))
            }
        }
    }

    func testPluginCompilationBeforeBuilding() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        
        try testWithTemporaryDirectory { tmpPath in
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
            try localFileSystem.writeFileContents(myLibraryTargetDir.appending(component: "library.swift"), string: """
                public func GetGreeting() -> String { return "Hello" }
                """
            )
            let myExecutableTargetDir = packageDir.appending(components: "Sources", "MyExecutable")
            try localFileSystem.createDirectory(myExecutableTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myExecutableTargetDir.appending(component: "main.swift"), string: """
                import MyLibrary
                print("\\(GetGreeting()), World!")
                """
            )
            let myBuildToolPluginTargetDir = packageDir.appending(components: "Plugins", "MyBuildToolPlugin")
            try localFileSystem.createDirectory(myBuildToolPluginTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myBuildToolPluginTargetDir.appending(component: "plugin.swift"), string: """
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
            try localFileSystem.writeFileContents(myCommandPluginTargetDir.appending(component: "plugin.swift"), string: """
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
                let result = try SwiftPMProduct.SwiftBuild.executeProcess([], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .contains("Compiling plugin MyBuildToolPlugin..."))
                XCTAssertMatch(output, .contains("Compiling plugin MyCommandPlugin..."))
                XCTAssertMatch(output, .contains("Building for debugging..."))
            }
            
            // Check that building just one of them just compiles that plugin and doesn't build anything else.
            do {
                let result = try SwiftPMProduct.SwiftBuild.executeProcess(["--target", "MyCommandPlugin"], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertNoMatch(output, .contains("Compiling plugin MyBuildToolPlugin..."))
                XCTAssertMatch(output, .contains("Compiling plugin MyCommandPlugin..."))
                XCTAssertNoMatch(output, .contains("Building for debugging..."))
            }
            
            // Deliberately break the command plugin.
            try localFileSystem.writeFileContents(myCommandPluginTargetDir.appending(component: "plugin.swift"), string: """
                import PackagePlugin
                @main struct MyBuildToolPlugin: BuildToolPlugin {
                    func performCommand(
                        context: PluginContext,
                        arguments: [String]
                    ) throws -> [Command] {
                        this is an error
                    }
                }
                """
            )

            // Check that building stops after compiling the plugin and doesn't proceed.
            // Run this test a number of times to try to catch any race conditions.
            for _ in 1...5 {
                let result = try SwiftPMProduct.SwiftBuild.executeProcess([], packagePath: packageDir)
                let output = try result.utf8Output() + result.utf8stderrOutput()
                XCTAssertNotEqual(result.exitStatus, .terminated(code: 0), "output: \(output)")
                XCTAssertMatch(output, .contains("Compiling plugin MyCommandPlugin..."))
                XCTAssertMatch(output, .contains("Compiling plugin MyBuildToolPlugin..."))
                XCTAssertMatch(output, .contains("MyCommandPlugin/plugin.swift:7:19: error: consecutive statements on a line must be separated by ';'"))
                XCTAssertNoMatch(output, .contains("Building for debugging..."))
            }
        }
    }
}
