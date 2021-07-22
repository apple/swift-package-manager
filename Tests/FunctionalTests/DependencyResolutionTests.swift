/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest

import TSCBasic
import Commands
import SPMTestSupport
import SourceControl
import Workspace

class DependencyResolutionTests: XCTestCase {
    func testInternalSimple() {
        fixture(name: "DependencyResolution/Internal/Simple") { prefix in
            XCTAssertBuilds(prefix)

            let output = try Process.checkNonZeroExit(args: prefix.appending(components: ".build", Resources.default.toolchain.triple.platformBuildPathComponent(), "debug", "Foo").pathString)
            XCTAssertEqual(output, "Foo\nBar\n")
        }
    }

    func testInternalExecAsDep() {
        fixture(name: "DependencyResolution/Internal/InternalExecutableAsDependency") { prefix in
            XCTAssertBuildFails(prefix)
        }
    }

    func testInternalComplex() {
        fixture(name: "DependencyResolution/Internal/Complex") { prefix in
            XCTAssertBuilds(prefix)

            let output = try Process.checkNonZeroExit(args: prefix.appending(components: ".build", Resources.default.toolchain.triple.platformBuildPathComponent(), "debug", "Foo").pathString)
            XCTAssertEqual(output, "meiow Baz\n")
        }
    }

    /// Check resolution of a trivial package with one dependency.
    func testExternalSimple() {
        fixture(name: "DependencyResolution/External/Simple") { prefix in
            // Add several other tags to check version selection.
            let repo = GitRepository(path: prefix.appending(components: "Foo"))
            for tag in ["1.1.0", "1.2.0"] {
                try repo.tag(name: tag)
            }

            let packageRoot = prefix.appending(component: "Bar")
            XCTAssertBuilds(packageRoot)
            XCTAssertFileExists(prefix.appending(components: "Bar", ".build", Resources.default.toolchain.triple.platformBuildPathComponent(), "debug", "Bar"))
            let path = try SwiftPMProduct.packagePath(for: "Foo", packageRoot: packageRoot)
            XCTAssert(try GitRepository(path: path).getTags().contains("1.2.3"))
        }
    }

    func testExternalComplex() {
        fixture(name: "DependencyResolution/External/Complex") { prefix in
            XCTAssertBuilds(prefix.appending(component: "app"))
            let output = try Process.checkNonZeroExit(args: prefix.appending(components: "app", ".build", Resources.default.toolchain.triple.platformBuildPathComponent(), "debug", "Dealer").pathString)
            XCTAssertEqual(output, "♣︎K\n♣︎Q\n♣︎J\n♣︎10\n♣︎9\n♣︎8\n♣︎7\n♣︎6\n♣︎5\n♣︎4\n")
        }
    }
    
    func testConvenienceBranchInit() throws {
        fixture(name: "DependencyResolution/External/Branch") { prefix in
            // Tests the convenience init .package(url: , branch: )
            let app = prefix.appending(component: "Bar")
            let result = try SwiftPMProduct.SwiftBuild.executeProcess([], packagePath: app)
            XCTAssert(result.exitStatus == .terminated(code: 0))
        }
    }

    func testMirrors() {
        fixture(name: "DependencyResolution/External/Mirror") { prefix in
            let prefix = resolveSymlinks(prefix)
            let appPath = prefix.appending(component: "App")
            let appPinsPath = appPath.appending(component: "Package.resolved")

            // prepare the dependencies as git repos
            try ["Foo", "Bar", "BarMirror"].forEach { directory in
                let path = prefix.appending(component: directory)
                _ = try Process.checkNonZeroExit(args: "git", "-C", path.pathString, "init")
                _ = try Process.checkNonZeroExit(args: "git", "-C", path.pathString, "checkout", "-b", "newMain")
            }

            // run with no mirror
            do {
                let output = try executeSwiftPackage(appPath, extraArgs: ["show-dependencies"])
                XCTAssertTrue(output.stdout.contains("Fetching \(prefix.pathString)/Foo\n"), output.stdout)
                XCTAssertTrue(output.stdout.contains("Fetching \(prefix.pathString)/Bar\n"), output.stdout)
                XCTAssertTrue(output.stdout.contains("foo<\(prefix.pathString)/Foo@unspecified"), output.stdout)
                XCTAssertTrue(output.stdout.contains("bar<\(prefix.pathString)/Bar@unspecified"), output.stdout)

                let pins = try String(bytes: localFileSystem.readFileContents(appPinsPath).contents, encoding: .utf8)!
                XCTAssertTrue(pins.contains("\"\(prefix.pathString)/Foo\""), pins)
                XCTAssertTrue(pins.contains("\"\(prefix.pathString)/Bar\""), pins)

                XCTAssertBuilds(appPath)
            }

            // clean
            try localFileSystem.removeFileTree(appPath.appending(component: ".build"))
            try localFileSystem.removeFileTree(appPinsPath)

            // set mirror
            _ = try executeSwiftPackage(appPath, extraArgs: ["config", "set-mirror",
                                                              "--original-url", prefix.appending(component: "Bar").pathString,
                                                              "--mirror-url", prefix.appending(component: "BarMirror").pathString])

            // run with mirror
            do {
                let output = try executeSwiftPackage(appPath, extraArgs: ["show-dependencies"])
                XCTAssertTrue(output.stdout.contains("Fetching \(prefix.pathString)/Foo\n"), output.stdout)
                XCTAssertTrue(output.stdout.contains("Fetching \(prefix.pathString)/BarMirror\n"), output.stdout)
                XCTAssertFalse(output.stdout.contains("Fetching \(prefix.pathString)/Bar\n"), output.stdout)

                XCTAssertTrue(output.stdout.contains("foo<\(prefix.pathString)/Foo@unspecified"), output.stdout)
                XCTAssertTrue(output.stdout.contains("barmirror<\(prefix.pathString)/BarMirror@unspecified"), output.stdout)
                XCTAssertFalse(output.stdout.contains("bar<\(prefix.pathString)/Bar@unspecified"), output.stdout)

                // rdar://52529014 mirrors should not be reflected in pins file
                let pins = try String(bytes: localFileSystem.readFileContents(appPinsPath).contents, encoding: .utf8)!
                XCTAssertTrue(pins.contains("\"\(prefix.pathString)/Foo\""), pins)
                XCTAssertTrue(pins.contains("\"\(prefix.pathString)/Bar\""), pins)
                XCTAssertFalse(pins.contains("\"\(prefix.pathString)/BarMirror\""), pins)

                XCTAssertBuilds(appPath)
            }
        }
    }

    func testPackageLookupCaseInsensitive() throws {
        fixture(name: "DependencyResolution/External/PackageLookupCaseInsensitive") { path in
            let result = try SwiftPMProduct.SwiftPackage.executeProcess(["update"], packagePath: path.appending(component: "pkg"))
            XCTAssert(result.exitStatus == .terminated(code: 0), try! result.utf8Output() + result.utf8stderrOutput())
        }
    }
}
