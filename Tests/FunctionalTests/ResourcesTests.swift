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

final class ResourcesTests: XCTestCase {
    func testSimpleResources() async throws {
        try await fixture(name: "Resources/Simple") { fixturePath in
            var executables = ["SwiftyResource"]

            // Objective-C module requires macOS
            #if os(macOS)
            executables.append("SeaResource")
            executables.append("CPPResource")
            #endif

            for execName in executables {
                let (output, _) = try await executeSwiftRun(fixturePath, execName)
                XCTAssertTrue(output.contains("foo"), output)
            }
        }
    }

    func testLocalizedResources() async throws {
        try await fixture(name: "Resources/Localized") { fixturePath in
            try await executeSwiftBuild(fixturePath)

            let exec = AbsolutePath(".build/debug/exe", relativeTo: fixturePath)
            // Note: <rdar://problem/59738569> Source from LANG and -AppleLanguages on command line for Linux resources
            let output = try await AsyncProcess.checkNonZeroExit(args: exec.pathString, "-AppleLanguages", "(en_US)")
            XCTAssertEqual(output, """
                ¡Hola Mundo!
                Hallo Welt!
                Bonjour le monde !

                """)
        }
    }

    func testResourcesInMixedClangPackage() async throws {
        #if !os(macOS)
        // Running swift-test fixtures on linux is not yet possible.
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif

        try await fixture(name: "Resources/Simple") { fixturePath in
            await XCTAssertBuilds(fixturePath, extraArgs: ["--target", "MixedClangResource"])
        }
    }

    func testMovedBinaryResources() async throws {
        try await fixture(name: "Resources/Moved") { fixturePath in
            var executables = ["SwiftyResource"]

            // Objective-C module requires macOS
            #if os(macOS)
            executables.append("SeaResource")
            #endif

            let binPath = try AbsolutePath(validating:
                await executeSwiftBuild(fixturePath, configuration: .Release, extraArgs: ["--show-bin-path"]).stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )

            for execName in executables {
                _ = try await executeSwiftBuild(fixturePath, configuration: .Release, extraArgs: ["--product", execName])

                try await withTemporaryDirectory(prefix: execName) { tmpDirPath in
                    defer {
                        // Unblock and remove the tmp dir on deinit.
                        try? localFileSystem.chmod(.userWritable, path: tmpDirPath, options: [.recursive])
                        try? localFileSystem.removeFileTree(tmpDirPath)
                    }

                    let destBinPath = tmpDirPath.appending(component: execName)
                    // Move the binary
                    try localFileSystem.move(from: binPath.appending(component: execName), to: destBinPath)
                    // Move the resources
                    try localFileSystem
                        .getDirectoryContents(binPath)
                        .filter { $0.contains(execName) && $0.hasSuffix(".bundle") || $0.hasSuffix(".resources") }
                        .forEach { try localFileSystem.move(from: binPath.appending(component: $0), to: tmpDirPath.appending(component: $0)) }
                    // Run the binary
                    let output = try await AsyncProcess.checkNonZeroExit(args: destBinPath.pathString)
                    XCTAssertTrue(output.contains("foo"))
                }
            }
        }
    }

    func testSwiftResourceAccessorDoesNotCauseInconsistentImportWarning() async throws {
        try await fixture(name: "Resources/FoundationlessClient/UtilsWithFoundationPkg") { fixturePath in
            await XCTAssertBuilds(
                fixturePath,
                Xswiftc: ["-warnings-as-errors"]
            )
        }
    }

    func testResourceBundleInClangPackageWhenRunningSwiftTest() async throws {
        #if !os(macOS)
        // Running swift-test fixtures on linux is not yet possible.
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif

        try await fixture(name: "Resources/Simple") { fixturePath in
            await XCTAssertSwiftTest(fixturePath, extraArgs: ["--filter", "ClangResourceTests"])
        }
    }

    func testResourcesEmbeddedInCode() async throws {
        try await fixture(name: "Resources/EmbedInCodeSimple") { fixturePath in
            let execPath = fixturePath.appending(components: ".build", "debug", "EmbedInCodeSimple")
            try await executeSwiftBuild(fixturePath)
            let result = try await AsyncProcess.checkNonZeroExit(args: execPath.pathString)
            XCTAssertEqual(result, "hello world\n\n")
            let resourcePath = fixturePath.appending(
                components: "Sources", "EmbedInCodeSimple", "best.txt")

            // Check incremental builds
            for i in 0..<2 {
              let content = "Hi there \(i)!"
              // Update the resource file.
              try localFileSystem.writeFileContents(resourcePath, string: content)
              try await executeSwiftBuild(fixturePath)
              // Run the executable again.
              let result2 = try await AsyncProcess.checkNonZeroExit(args: execPath.pathString)
              XCTAssertEqual(result2, "\(content)\n")
            }
        }
    }

    func testResourcesOutsideOfTargetCanBeIncluded() async throws {
        try UserToolchain.default.skipUnlessAtLeastSwift6()

        try await testWithTemporaryDirectory { tmpPath in
            let packageDir = tmpPath.appending(components: "MyPackage")

            let manifestFile = packageDir.appending("Package.swift")
            try localFileSystem.createDirectory(manifestFile.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(
                manifestFile,
                string: """
                // swift-tools-version: 6.0
                import PackageDescription
                let package = Package(name: "MyPackage",
                    targets: [
                        .executableTarget(
                            name: "exec",
                            resources: [.copy("../resources")]
                        )
                    ])
                """)

            let targetSourceFile = packageDir.appending(components: "Sources", "exec", "main.swift")
            try localFileSystem.createDirectory(targetSourceFile.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(targetSourceFile, string: """
            import Foundation
            print(Bundle.module.resourcePath ?? "<empty>")
            """)

            let resource = packageDir.appending(components: "Sources", "resources", "best.txt")
            try localFileSystem.createDirectory(resource.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(resource, string: "best")

            let (_, stderr) = try await executeSwiftBuild(packageDir, env: ["SWIFT_DRIVER_SWIFTSCAN_LIB" : "/this/is/a/bad/path"])
            // Filter some unrelated output that could show up on stderr.
            let filteredStderr = stderr.components(separatedBy: "\n").filter { !$0.contains("[logging]") }.joined(separator: "\n")
            XCTAssertEqual(filteredStderr, "", "unexpectedly received error output: \(stderr)")

            let builtProductsDir = packageDir.appending(components: [".build", "debug"])
            // On Apple platforms, it's going to be `.bundle` and elsewhere `.resources`.
            let potentialResourceBundleName = try XCTUnwrap(localFileSystem.getDirectoryContents(builtProductsDir).filter { $0.hasPrefix("MyPackage_exec.") }.first)
            let resourcePath = builtProductsDir.appending(components: [potentialResourceBundleName, "resources", "best.txt"])
            XCTAssertTrue(localFileSystem.exists(resourcePath), "resource file wasn't copied by the build")
            let contents = try String(contentsOfFile: resourcePath.pathString)
            XCTAssertEqual(contents, "best", "unexpected resource contents: \(contents)")
        }
    }
}
