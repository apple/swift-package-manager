/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest
import Foundation

import TSCBasic
import Commands
import Xcodeproj
import PackageModel
import SourceControl
import SPMTestSupport
import TSCUtility
import Workspace

final class PackageToolTests: XCTestCase {
    @discardableResult
    private func execute(
        _ args: [String],
        packagePath: AbsolutePath? = nil,
        env: [String: String]? = nil
    ) throws -> (stdout: String, stderr: String) {
        var environment = env ?? [:]
        // don't ignore local packages when caching
        environment["SWIFTPM_TESTS_PACKAGECACHE"] = "1"
        return try SwiftPMProduct.SwiftPackage.execute(args, packagePath: packagePath, env: environment)
    }

    func testUsage() throws {
        let stdout = try execute(["-help"]).stdout
        XCTAssert(stdout.contains("USAGE: swift package"), "got stdout:\n" + stdout)
    }

    func testSeeAlso() throws {
        let stdout = try execute(["--help"]).stdout
        XCTAssert(stdout.contains("SEE ALSO: swift build, swift run, swift test"), "got stdout:\n" + stdout)
    }

    func testVersion() throws {
        let stdout = try execute(["--version"]).stdout
        XCTAssert(stdout.contains("Swift Package Manager"), "got stdout:\n" + stdout)
    }

    func testNetrcFile() throws {
        fixture(name: "DependencyResolution/External/XCFramework") { packageRoot in
            let fs = localFileSystem
            let netrcPath = packageRoot.appending(component: ".netrc")
            try fs.writeFileContents(netrcPath) { stream in
                stream <<< "machine mymachine.labkey.org login user@labkey.org password mypassword"
            }

            do {
                // file at correct location
                try execute(["--netrc-file", netrcPath.pathString, "resolve"], packagePath: packageRoot)
                // file does not exist, but is optional
                let textOutput = try execute(["--netrc-file", "/foo", "--netrc-optional", "resolve"], packagePath: packageRoot).stderr
                XCTAssert(textOutput.contains("warning: Did not find optional .netrc file at /foo."))

                // required file does not exist, will throw
                try execute(["--netrc-file", "/foo", "resolve"], packagePath: packageRoot)
            } catch {
                XCTAssert(String(describing: error).contains("Cannot find mandatory .netrc file at /foo"), "\(error)")
            }
        }

        fixture(name: "DependencyResolution/External/XCFramework") { packageRoot in
            do {
                // Developer machine may have .netrc file at NSHomeDirectory; modify test accordingly
                if localFileSystem.exists(localFileSystem.homeDirectory.appending(RelativePath(".netrc"))) {
                    try execute(["--netrc", "resolve"], packagePath: packageRoot)
                } else {
                    // file does not exist, but is optional
                    let textOutput = try execute(["--netrc", "--netrc-optional", "resolve"], packagePath: packageRoot)
                    XCTAssert(textOutput.stderr.contains("Did not find optional .netrc file at \(localFileSystem.homeDirectory)/.netrc."))

                    // file does not exist, but is optional
                    let textOutput2 = try execute(["--netrc-optional", "resolve"], packagePath: packageRoot)
                    XCTAssert(textOutput2.stderr.contains("Did not find optional .netrc file at \(localFileSystem.homeDirectory)/.netrc."))

                    // required file does not exist, will throw
                    try execute(["--netrc", "resolve"], packagePath: packageRoot)
                }
            } catch {
                XCTAssert(String(describing: error).contains("Cannot find mandatory .netrc file at \(localFileSystem.homeDirectory)/.netrc"))
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
            XCTAssertEqual(json["path"]?.string?.hasPrefix("/"), true)
            XCTAssertEqual(json["path"]?.string?.hasSuffix("/" + prefix.basename), true)
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
            XCTAssert(textChunk0.contains("Name: SwiftCMixed"), textChunk0)
            XCTAssert(textChunk0.contains("Path: /"), textChunk0)
            XCTAssert(textChunk0.contains("/" + prefix.basename + "\n"), textChunk0)
            XCTAssert(textChunk0.contains("Tools version: 4.2"), textChunk0)
            XCTAssert(textChunk0.contains("Products:"), textChunk0)
            let textChunk1 = try XCTUnwrap(textChunks[1])
            XCTAssert(textChunk1.contains("Name: SeaExec"), textChunk1)
            XCTAssert(textChunk1.contains("Type:\n        Executable"), textChunk1)
            XCTAssert(textChunk1.contains("Targets:\n        SeaExec"), textChunk1)
            let textChunk2 = try XCTUnwrap(textChunks[2])
            XCTAssert(textChunk2.contains("Name: CExec"), textChunk2)
            XCTAssert(textChunk2.contains("Type:\n        Executable"), textChunk2)
            XCTAssert(textChunk2.contains("Targets:\n        CExec"), textChunk2)
            let textChunk3 = try XCTUnwrap(textChunks[3])
            XCTAssert(textChunk3.contains("Targets:"), textChunk3)
            let textChunk4 = try XCTUnwrap(textChunks[4])
            XCTAssert(textChunk4.contains("Name: SeaLib"), textChunk4)
            XCTAssert(textChunk4.contains("C99name: SeaLib"), textChunk4)
            XCTAssert(textChunk4.contains("Type: library"), textChunk4)
            XCTAssert(textChunk4.contains("Module type: ClangTarget"), textChunk4)
            XCTAssert(textChunk4.contains("Path: Sources/SeaLib"), textChunk4)
            XCTAssert(textChunk4.contains("Sources:\n        Foo.c"), textChunk4)
            let textChunk5 = try XCTUnwrap(textChunks[5])
            XCTAssert(textChunk5.contains("Name: SeaExec"), textChunk5)
            XCTAssert(textChunk5.contains("C99name: SeaExec"), textChunk5)
            XCTAssert(textChunk5.contains("Type: executable"), textChunk5)
            XCTAssert(textChunk5.contains("Module type: SwiftTarget"), textChunk5)
            XCTAssert(textChunk5.contains("Path: Sources/SeaExec"), textChunk5)
            XCTAssert(textChunk5.contains("Sources:\n        main.swift"), textChunk5)
            let textChunk6 = try XCTUnwrap(textChunks[6])
            XCTAssert(textChunk6.contains("Name: CExec"), textChunk6)
            XCTAssert(textChunk6.contains("C99name: CExec"), textChunk6)
            XCTAssert(textChunk6.contains("Type: executable"), textChunk6)
            XCTAssert(textChunk6.contains("Module type: ClangTarget"), textChunk6)
            XCTAssert(textChunk6.contains("Path: Sources/CExec"), textChunk6)
            XCTAssert(textChunk6.contains("Sources:\n        main.c"), textChunk6)
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
            let result = try SwiftPMProduct.SwiftPackage.executeProcess(["describe", "--type=json"], packagePath: prefix, env: ["SWIFTPM_ENABLE_PLUGINS": "1"])
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
        
        let manifestA = Manifest.createManifest(
            name: "PackageA",
            path: "/PackageA",
            packageKind: .root,
            packageLocation: "/PackageA",
            v: .v5_3,
            dependencies: [
                .local(name: "PackageB", path: "/PackageB"),
                .local(name: "PackageC", path: "/PackageC"),
            ],
            products: [
                .init(name: "exe", type: .executable, targets: ["TargetA"])
            ],
            targets: [
                try .init(name: "TargetA", dependencies: ["PackageB", "PackageC"])
            ]
        )
        
        let manifestB = Manifest.createManifest(
            name: "PackageB",
            path: "/PackageB",
            packageKind: .local,
            packageLocation: "/PackageB",
            v: .v5_3,
            dependencies: [
                .local(name: "PackageC", path: "/PackageC"),
                .local(name: "PackageD", path: "/PackageD"),
            ],
            products: [
                .init(name: "PackageB", type: .library(.dynamic), targets: ["TargetB"])
            ],
            targets: [
                try .init(name: "TargetB", dependencies: ["PackageC", "PackageD"])
            ]
        )
        
        let manifestC = Manifest.createManifest(
            name: "PackageC",
            path: "/PackageC",
            packageKind: .local,
            packageLocation: "/PackageC",
            v: .v5_3,
            dependencies: [
                .local(name: "PackageD", path: "/PackageD"),
            ],
            products: [
                .init(name: "PackageC", type: .library(.dynamic), targets: ["TargetC"])
            ],
            targets: [
                try .init(name: "TargetC", dependencies: ["PackageD"])
            ]
        )
        
        let manifestD = Manifest.createManifest(
            name: "PackageD",
            path: "/PackageD",
            packageKind: .local,
            packageLocation: "/PackageD",
            v: .v5_3,
            products: [
                .init(name: "PackageD", type: .library(.dynamic), targets: ["TargetD"])
            ],
            targets: [
                try .init(name: "TargetD")
            ]
        )
        
        let diagnostics = DiagnosticsEngine()
        let graph = try loadPackageGraph(fs: fileSystem,
                                         diagnostics: diagnostics,
                                         manifests: [manifestA, manifestB, manifestC, manifestD])
        XCTAssertNoDiagnostics(diagnostics)
        
        let output = BufferedOutputByteStream()
        dumpDependenciesOf(rootPackage: graph.rootPackages[0], mode: .dot, on: output)
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
            
            XCTAssert(fs.exists(resultPath))
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

            XCTAssert(fs.exists(path.appending(component: "Package.swift")))
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
            XCTAssertTrue(contents.hasPrefix("// swift-tools-version:\(version < .v5_4 ? "" : " ")\(versionSpecifier)\n"))

            XCTAssertTrue(fs.exists(manifest))
            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Sources").appending(component: "Foo")), ["main.swift"])
            XCTAssertEqual(
                try fs.getDirectoryContents(path.appending(component: "Tests")).sorted(),
                ["FooTests"])
        }
    }

    func testInitLibrary() throws {
        try testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending(component: "Foo")
            try fs.createDirectory(path)
            _ = try execute(["init"], packagePath: path)

            XCTAssert(fs.exists(path.appending(component: "Package.swift")))
            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Sources").appending(component: "Foo")), ["Foo.swift"])
            XCTAssertEqual(
                try fs.getDirectoryContents(path.appending(component: "Tests")).sorted(),
                ["FooTests"])
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
			XCTAssertTrue(contents.hasPrefix("// swift-tools-version:\(version < .v5_4 ? "" : " ")\(versionSpecifier)\n"))

            XCTAssertTrue(fs.exists(manifest))
            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Sources").appending(component: "CustomName")), ["main.swift"])
            XCTAssertEqual(
                try fs.getDirectoryContents(path.appending(component: "Tests")).sorted(),
                ["CustomNameTests"])
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
            let exec = [fooPath.appending(components: ".build", Resources.default.toolchain.triple.tripleString, "debug", "foo").pathString]

            // We should see it now in packages directory.
            let editsPath = fooPath.appending(components: "Packages", "bar")
            XCTAssert(localFileSystem.isDirectory(editsPath))

            let bazEditsPath = fooPath.appending(components: "Packages", "baz")
            XCTAssert(localFileSystem.isDirectory(bazEditsPath))
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
            let binFile = buildPath.appending(components: Resources.default.toolchain.triple.tripleString, "debug", "Bar")
            XCTAssertFileExists(binFile)
            XCTAssert(localFileSystem.isDirectory(buildPath))

            // Clean, and check for removal of the build directory but not Packages.
            _ = try execute(["clean"], packagePath: packageRoot)
            XCTAssert(!localFileSystem.exists(binFile))
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
            let binFile = buildPath.appending(components: Resources.default.toolchain.triple.tripleString, "debug", "Bar")
            XCTAssertFileExists(binFile)
            XCTAssert(localFileSystem.isDirectory(buildPath))
            // Clean, and check for removal of the build directory but not Packages.

            _ = try execute(["clean"], packagePath: packageRoot)
            XCTAssert(!localFileSystem.exists(binFile))
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
            XCTAssert(localFileSystem.exists(pinsFile))

            // Update bar repo.
            let barPath = prefix.appending(component: "bar")
            let barRepo = GitRepository(path: barPath)
            try barRepo.checkout(newBranch: "YOLO")
            let yoloRevision = try barRepo.getCurrentRevision()

            // Try to pin bar at a branch.
            do {
                try execute("resolve", "bar", "--branch", "YOLO")
                let pinsStore = try PinsStore(pinsFile: pinsFile, fileSystem: localFileSystem, mirrors: .init())
                let state = CheckoutState(revision: yoloRevision, branch: "YOLO")
                let identity = PackageIdentity(path: barPath)
                XCTAssertEqual(pinsStore.pinsMap[identity]?.state, state)
            }

            // Try to pin bar at a revision.
            do {
                try execute("resolve", "bar", "--revision", yoloRevision.identifier)
                let pinsStore = try PinsStore(pinsFile: pinsFile, fileSystem: localFileSystem, mirrors: .init())
                let state = CheckoutState(revision: yoloRevision)
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
            let exec = [fooPath.appending(components: ".build", Resources.default.toolchain.triple.tripleString, "debug", "foo").pathString]

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
            XCTAssert(localFileSystem.exists(pinsFile))

            // Test pins file.
            do {
                let pinsStore = try PinsStore(pinsFile: pinsFile, fileSystem: localFileSystem, mirrors: .init())
                XCTAssertEqual(pinsStore.pins.map{$0}.count, 2)
                for pkg in ["bar", "baz"] {
                    let path = try SwiftPMProduct.packagePath(for: pkg, packageRoot: fooPath)
                    let pin = pinsStore.pinsMap[PackageIdentity(path: path)]!
                    XCTAssertEqual(pin.packageRef.identity, PackageIdentity(path: path))
                    XCTAssert(pin.packageRef.repository.url.hasSuffix(pkg))
                    XCTAssertEqual(pin.state.version, "1.2.3")
                }
            }

            @discardableResult
            func execute(_ args: String...) throws -> String {
                return try SwiftPMProduct.SwiftPackage.execute([] + args, packagePath: fooPath).stdout
            }

            // Try to pin bar.
            do {
                try execute("resolve", "bar")
                let pinsStore = try PinsStore(pinsFile: pinsFile, fileSystem: localFileSystem, mirrors: .init())
                let identity = PackageIdentity(path: barPath)
                XCTAssertEqual(pinsStore.pinsMap[identity]?.state.version, "1.2.3")
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
                let pinsStore = try PinsStore(pinsFile: pinsFile, fileSystem: localFileSystem, mirrors: .init())
                let identity = PackageIdentity(path: barPath)
                XCTAssertEqual(pinsStore.pinsMap[identity]?.state.version, "1.2.3")
                try checkBar(5)
            }

            // Try pinning a dependency which is in edit mode.
            do {
                try execute("edit", "bar", "--branch", "bugfix")
                do {
                    try execute("resolve", "bar")
                    XCTFail("This should have been an error")
                } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                    XCTAssertEqual(stderr, "error: dependency 'bar' already in edit mode\n")
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
            let diagnostics = DiagnosticsEngine()

            let scriptsDir = path.appending(component: "scripts")
            let packageRoot = path.appending(component: "root")

            let helper = WatchmanHelper(
                diagnostics: diagnostics,
                watchmanScriptsDir: scriptsDir,
                packageRoot: packageRoot)

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

    fileprivate func check(stderr: String, _ block: () throws -> ()) {
        do {
            try block()
            XCTFail()
        } catch SwiftPMProductError.executionFailure(_, _, let stderrOutput) {
            XCTAssertEqual(stderrOutput, stderr)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testMirrorConfig() throws {
        try testWithTemporaryDirectory { prefix in
            let fs = localFileSystem
            let packageRoot = prefix.appending(component: "Foo")
            let configOverride = prefix.appending(component: "configoverride")
            let configFile = packageRoot.appending(components: ".swiftpm", "config")

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

            check(stderr: "error: mirror not found\n") {
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
                XCTAssert(stderrOutput.contains("error: root manifest not found"), #"actual: "\#(stderrOutput)""#)
            }

            // Runnning with output as absolute path to existing directory
            do {
                let destination = AbsolutePath.root
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["archive-source", "--output", destination.pathString], packagePath: packageRoot)
                XCTAssertEqual(result.exitStatus, .terminated(code: 1))

                let stderrOutput = try result.utf8stderrOutput()
                XCTAssert(
                    stderrOutput.contains("error: Couldn’t create an archive:") &&
                        stderrOutput.contains("fatal: could not create archive file '/': Is a directory"),
                    #"actual: "\#(stderrOutput)""#
                )
            }
        }
    }

    #if BUILD_PACKAGE_SYNTAX
    func testAddDependency() throws {
        fixture(name: "PackageEditor/Empty") { packageRoot in
            fixture(name: "PackageEditor/OneProduct") { dependencyRoot in
                _ = try execute(["add-dependency", dependencyRoot.pathString], packagePath: packageRoot)
                let (dumpOutput, _) = try execute(["dump-package"], packagePath: packageRoot)
                let json = try JSON(bytes: ByteString(encodingAsUTF8: dumpOutput))
                guard case .dictionary(let dict) = json else { XCTFail(); return }
                guard case .array(let deps) = dict["dependencies"] else { XCTFail(); return }
                guard case .dictionary(let depsMap) = deps[0] else { XCTFail(); return }
                guard case .array(let localDeps) = depsMap["local"] else { XCTFail(); return }
                XCTAssertEqual(localDeps.count, 1)
                let dependency = localDeps[0]
                XCTAssertEqual(dependency["name"], .string("MyPackage2"))
                XCTAssertEqual(dependency["identity"], .string("packageeditor_oneproduct"))

                check(stderr: "error: 'MyPackage' already has a dependency on '\(dependencyRoot.pathString)'\n") {
                    try execute(["add-dependency", dependencyRoot.pathString], packagePath: packageRoot)
                }

                check(stderr: "error: only one requirement is allowed when specifiying a dependency\n") {
                    try execute(["add-dependency", "http://www.githost.com/repo.git",
                                 "--exact", "1.0.0", "--from", "1.0.0"],
                                packagePath: packageRoot)
                }

                check(stderr: "error: '--to' and '--through' may only be used with '--from' to specify a range requirement\n") {
                    _ = try execute(["add-dependency", "http://www.githost.com/repo.git",
                                     "--exact", "1.0.0", "--to", "2.0.0"],
                                    packagePath: packageRoot)
                }

                check(stderr: "error: '--to' and '--through' may not be used in the same requirement\n") {
                    _ = try execute(["add-dependency", "http://www.githost.com/repo.git",
                                     "--from", "1.0.0", "--to", "2.0.0", "--through", "3.0.0"],
                                    packagePath: packageRoot)
                }

            }
        }
    }

    func testAddTarget() throws {
        fixture(name: "PackageEditor/Empty") { packageRoot in
            fixture(name: "PackageEditor/OneProduct") { dependencyRoot in
                _ = try execute(["add-dependency", dependencyRoot.pathString], packagePath: packageRoot)
                _ = try execute(["add-target", "MyLibrary", "--dependencies", "Library"], packagePath: packageRoot)
                _ = try execute(["add-target", "MyExecutable", "--type", "executable",
                                 "--dependencies", "MyLibrary"], packagePath: packageRoot)
                _ = try execute(["add-target", "--type", "test", "IntegrationTests",
                                 "--dependencies", "MyLibrary"], packagePath: packageRoot)
                let contents = try localFileSystem.readFileContents(packageRoot.appending(component: Manifest.filename)).description
                XCTAssertEqual(contents, """
                // swift-tools-version:5.3
                import PackageDescription

                let package = Package(
                    name: "MyPackage",
                    dependencies: [
                        .package(name: "MyPackage2", path: "\(dependencyRoot.pathString)"),
                    ],
                    targets: [
                        .target(
                            name: "MyLibrary",
                            dependencies: [
                                .product(name: "Library", package: "MyPackage2"),
                            ]
                        ),
                        .testTarget(
                            name: "MyLibraryTests",
                            dependencies: [
                                "MyLibrary",
                            ]
                        ),
                        .target(
                            name: "MyExecutable",
                            dependencies: [
                                "MyLibrary",
                            ]
                        ),
                        .testTarget(
                            name: "IntegrationTests",
                            dependencies: [
                                "MyLibrary",
                            ]
                        ),
                    ]
                )
                """)

                XCTAssertTrue(localFileSystem.exists(packageRoot.appending(components: "Sources", "MyLibrary", "MyLibrary.swift")))
                XCTAssertTrue(localFileSystem.exists(packageRoot.appending(components: "Tests", "MyLibraryTests", "MyLibraryTests.swift")))
                XCTAssertTrue(localFileSystem.exists(packageRoot.appending(components: "Sources", "MyExecutable", "main.swift")))
                XCTAssertTrue(localFileSystem.exists(packageRoot.appending(components: "Tests", "IntegrationTests", "IntegrationTests.swift")))

                _ = try execute(["add-target", "MyLocalBinary", "--type", "binary",
                                 "--path", "LocalBinary.xcframework"],
                                packagePath: packageRoot)
                check(stderr: "error: a target named 'MyLibrary' already exists in 'MyPackage'\n") {
                    _ = try execute(["add-target", "MyLibrary"], packagePath: packageRoot)
                }
                check(stderr: "error: binary targets must specify either a path or both a URL and a checksum\n") {
                    _ = try execute(["add-target", "MyLibrary", "--type", "binary"], packagePath: packageRoot)
                }
                check(stderr: "error: option '--checksum' is only supported for binary targets\n") {
                    _ = try execute(["add-target", "MyLibrary", "--checksum", "checksum"], packagePath: packageRoot)
                }
                check(stderr: "error: option '--dependencies' is not supported for binary targets\n") {
                    _ = try execute(["add-target", "MyLibrary", "--type", "binary", "--dependencies", "MyLibrary"],
                                    packagePath: packageRoot)
                }
                check(stderr: "error: unsupported target type 'unsupported'; supported types are library, executable, test, and binary\n") {
                    _ = try execute(["add-target", "MyLibrary", "--type", "unsupported"],
                                    packagePath: packageRoot)
                }

            }
        }
    }

    func testAddProduct() throws {
        fixture(name: "PackageEditor/Empty") { packageRoot in
            _ = try execute(["add-target", "MyLibrary", "--no-test-target"],
                            packagePath: packageRoot)
            _ = try execute(["add-target", "MyLibrary2", "--no-test-target"],
                            packagePath: packageRoot)

            _ = try execute(["add-product", "LibraryProduct",
                             "--targets", "MyLibrary", "MyLibrary2"],
                            packagePath: packageRoot)
            _ = try execute(["add-product", "DynamicLibraryProduct",
                             "--type", "dynamic-library",
                             "--targets", "MyLibrary"],
                            packagePath: packageRoot)
            _ = try execute(["add-product", "StaticLibraryProduct",
                             "--type", "static-library",
                             "--targets", "MyLibrary"],
                            packagePath: packageRoot)
            _ = try execute(["add-product", "ExecutableProduct",
                             "--type", "executable",
                             "--targets", "MyLibrary2"],
                            packagePath: packageRoot)
            let contents = try localFileSystem.readFileContents(
                packageRoot.appending(component: Manifest.filename)).description
            XCTAssertEqual(contents, """
            // swift-tools-version:5.3
            import PackageDescription

            let package = Package(
                name: "MyPackage",
                products: [
                    .library(
                        name: "LibraryProduct",
                        targets: [
                            "MyLibrary",
                            "MyLibrary2",
                        ]
                    ),
                    .library(
                        name: "DynamicLibraryProduct",
                        type: .dynamic,
                        targets: [
                            "MyLibrary",
                        ]
                    ),
                    .library(
                        name: "StaticLibraryProduct",
                        type: .static,
                        targets: [
                            "MyLibrary",
                        ]
                    ),
                    .executable(
                        name: "ExecutableProduct",
                        targets: [
                            "MyLibrary2",
                        ]
                    ),
                ],
                targets: [
                    .target(
                        name: "MyLibrary",
                        dependencies: []
                    ),
                    .target(
                        name: "MyLibrary2",
                        dependencies: []
                    ),
                ]
            )
            """)

            check(stderr: "error: a product named 'LibraryProduct' already exists in 'MyPackage'\n") {
                _ = try execute(["add-product", "LibraryProduct",
                                 "--targets", "MyLibrary,MyLibrary2"],
                                packagePath: packageRoot)
            }
        }
    }
    #endif
}
