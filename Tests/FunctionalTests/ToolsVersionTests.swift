/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest

import TSCBasic
import TSCUtility
import SPMTestSupport
import Commands
import PackageModel
import SourceControl
import Workspace

class ToolsVersionTests: XCTestCase {

    func testToolsVersion() throws {
        try testWithTemporaryDirectory{ path in
            let fs = localFileSystem

            // Create a repo for the dependency to test against.
            let depPath = path.appending(component: "Dep")
            try fs.createDirectory(depPath)
            initGitRepo(depPath)
            let repo = GitRepository(path: depPath)

            try fs.writeFileContents(depPath.appending(component: "Package.swift")) {
                $0 <<< """
                    // swift-tools-version:5.0
                    import PackageDescription
                    let package = Package(
                        name: "Dep",
                        products: [
                            .library(name: "Dep", targets: ["Dep"]),
                        ],
                        targets: [
                            .target(name: "Dep", path: "./")
                        ]
                    )
                    """
            }
            try fs.writeFileContents(depPath.appending(component: "foo.swift")) {
                $0 <<< """
                    public func foo() { print("foo@1.0") }
                    """
            }
            // v1.
            try repo.stageEverything()
            try repo.commit(message: "Initial")
            try repo.tag(name: "1.0.0")

            // v1.0.1
            _ = try SwiftPMProduct.SwiftPackage.execute(
                ["tools-version", "--set", "10000.1"], packagePath: depPath)
            try fs.writeFileContents(depPath.appending(component: "foo.swift")) {
                $0 <<< """
                    public func foo() { print("foo@1.0.1") }
                    """
            }
            try repo.stageEverything()
            try repo.commit(message: "1.0.1")
            try repo.tag(name: "1.0.1")

            // Create the primary repository.
            let primaryPath = path.appending(component: "Primary")
            try fs.writeFileContents(primaryPath.appending(component: "Package.swift")) {
                $0 <<< """
                    import PackageDescription
                    let package = Package(
                        name: "Primary",
                        dependencies: [.package(url: "../Dep", from: "1.0.0")],
                        targets: [.target(name: "Primary", dependencies: ["Dep"], path: ".")]
                    )
                    """
            }
            // Create a file.
            try fs.writeFileContents(primaryPath.appending(component: "main.swift")) {
                $0 <<< """
                    import Dep
                    Dep.foo()
                    """
            }
            _ = try SwiftPMProduct.SwiftPackage.execute(
                ["tools-version", "--set", "4.2"], packagePath: primaryPath).stdout.spm_chomp()

            // Build the primary package.
            _ = try SwiftPMProduct.SwiftBuild.execute([], packagePath: primaryPath)
            let exe = primaryPath.appending(components: ".build", Resources.default.toolchain.triple.platformBuildPathComponent(), "debug", "Primary").pathString
            // v1 should get selected because v1.0.1 depends on a (way) higher set of tools.
            XCTAssertEqual(try Process.checkNonZeroExit(args: exe).spm_chomp(), "foo@1.0")

            // Set the tools version to something high.
            _ = try SwiftPMProduct.SwiftPackage.execute(
                ["tools-version", "--set", "10000.1"], packagePath: primaryPath)

            do {
                _ = try SwiftPMProduct.SwiftBuild.execute([], packagePath: primaryPath)
                XCTFail()
            } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                XCTAssert(stderr.contains("is using Swift tools version 10000.1.0 but the installed version is \(ToolsVersion.currentToolsVersion)"), stderr)
            }

            // Write the manifest with incompatible sources.
            try fs.writeFileContents(primaryPath.appending(component: "Package.swift")) {
                $0 <<< """
                    import PackageDescription
                    let package = Package(
                        name: "Primary",
                        dependencies: [.package(url: "../Dep", from: "1.0.0")],
                        targets: [.target(name: "Primary", dependencies: ["Dep"], path: ".")],
                        swiftLanguageVersions: [.version("1000")])
                    """
            }
            _ = try SwiftPMProduct.SwiftPackage.execute(
                ["tools-version", "--set", "4.2"], packagePath: primaryPath).stdout.spm_chomp()

            do {
                _ = try SwiftPMProduct.SwiftBuild.execute([], packagePath: primaryPath)
                XCTFail()
            } catch SwiftPMProductError.executionFailure(_, _, let stderr) {
                XCTAssertTrue(stderr.contains("package 'Primary' requires minimum Swift language version 1000 which is not supported by the current tools version (\(ToolsVersion.currentToolsVersion))"), stderr)
            }

             try fs.writeFileContents(primaryPath.appending(component: "Package.swift")) {
                $0 <<< """
                    import PackageDescription
                    let package = Package(
                        name: "Primary",
                        dependencies: [.package(url: "../Dep", from: "1.0.0")],
                        targets: [.target(name: "Primary", dependencies: ["Dep"], path: ".")],
                        swiftLanguageVersions: [.version("\(ToolsVersion.currentToolsVersion.major)"), .version("1000")])
                    """
             }
             _ = try SwiftPMProduct.SwiftPackage.execute(
                 ["tools-version", "--set", "4.2"], packagePath: primaryPath).stdout.spm_chomp()
             _ = try SwiftPMProduct.SwiftBuild.execute([], packagePath: primaryPath)
        }
    }
}
