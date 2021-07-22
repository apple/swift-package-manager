/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest
import Commands
import SPMTestSupport
import TSCBasic
import TSCUtility
import Workspace

class ModuleMapsTestCase: XCTestCase {

    private func fixture(name: String, cModuleName: String, rootpkg: String, body: @escaping (AbsolutePath, [String]) throws -> Void) {
        SPMTestSupport.fixture(name: name) { prefix in
            let input = prefix.appending(components: cModuleName, "C", "foo.c")
            let triple = Resources.default.toolchain.triple
            let outdir = prefix.appending(components: rootpkg, ".build", triple.platformBuildPathComponent(), "debug")
            try makeDirectories(outdir)
            let output = outdir.appending(component: "libfoo\(triple.dynamicLibraryExtension)")
            try systemQuietly(["clang", "-shared", input.pathString, "-o", output.pathString])

            var Xld = ["-L", outdir.pathString]
        #if os(Linux) || os(Android)
            Xld += ["-rpath", outdir.pathString]
        #endif

            try body(prefix, Xld)
        }
    }

    func testDirectDependency() {
        fixture(name: "ModuleMaps/Direct", cModuleName: "CFoo", rootpkg: "App") { prefix, Xld in

            XCTAssertBuilds(prefix.appending(component: "App"), Xld: Xld)

            let triple = Resources.default.toolchain.triple
            let targetPath = prefix.appending(components: "App", ".build", triple.platformBuildPathComponent())
            let debugout = try Process.checkNonZeroExit(args: targetPath.appending(components: "debug", "App").pathString)
            XCTAssertEqual(debugout, "123\n")
            let releaseout = try Process.checkNonZeroExit(args: targetPath.appending(components: "release", "App").pathString)
            XCTAssertEqual(releaseout, "123\n")
        }
    }

    func testTransitiveDependency() {
        fixture(name: "ModuleMaps/Transitive", cModuleName: "packageD", rootpkg: "packageA") { prefix, Xld in

            XCTAssertBuilds(prefix.appending(component: "packageA"), Xld: Xld)

            func verify(_ conf: String, file: StaticString = #file, line: UInt = #line) throws {
                let triple = Resources.default.toolchain.triple
                let out = try Process.checkNonZeroExit(args: prefix.appending(components: "packageA", ".build", triple.platformBuildPathComponent(), conf, "packageA").pathString)
                XCTAssertEqual(out, """
                    calling Y.bar()
                    Y.bar() called
                    X.foo() called
                    123

                    """)
            }

            try verify("debug")
            try verify("release")
        }
    }
}
