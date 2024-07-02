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
import PackageModel
import _InternalTestSupport
import Workspace
import XCTest

final class ModuleMapsTestCase: XCTestCase {
    private func fixture(
        name: String,
        cModuleName: String,
        rootpkg: String,
        body: @escaping (AbsolutePath, [String]) async throws -> Void
    ) async throws {
        try await _InternalTestSupport.fixture(name: name) { fixturePath in
            let input = fixturePath.appending(components: cModuleName, "C", "foo.c")
            let triple = try UserToolchain.default.targetTriple
            let outdir = fixturePath.appending(components: rootpkg, ".build", triple.platformBuildPathComponent, "debug")
            try makeDirectories(outdir)
            let output = outdir.appending("libfoo\(triple.dynamicLibraryExtension)")
            try systemQuietly(["clang", "-shared", input.pathString, "-o", output.pathString])

            var Xld = ["-L", outdir.pathString]
        #if os(Linux) || os(Android)
            Xld += ["-rpath", outdir.pathString]
        #endif

            try await body(fixturePath, Xld)
        }
    }

    func testDirectDependency() async throws {
        try await fixture(name: "ModuleMaps/Direct", cModuleName: "CFoo", rootpkg: "App") { fixturePath, Xld in
            await XCTAssertBuilds(fixturePath.appending("App"), Xld: Xld)

            let triple = try UserToolchain.default.targetTriple
            let targetPath = fixturePath.appending(components: "App", ".build", triple.platformBuildPathComponent)
            let debugout = try await AsyncProcess.checkNonZeroExit(
                args: targetPath.appending(components: "debug", "App").pathString
            )
            XCTAssertEqual(debugout, "123\n")
            let releaseout = try await AsyncProcess.checkNonZeroExit(
                args: targetPath.appending(components: "release", "App").pathString
            )
            XCTAssertEqual(releaseout, "123\n")
        }
    }

    func testTransitiveDependency() async throws {
        try await fixture(name: "ModuleMaps/Transitive", cModuleName: "packageD", rootpkg: "packageA") { fixturePath, Xld in
            await XCTAssertBuilds(fixturePath.appending("packageA"), Xld: Xld)
            
            func verify(_ conf: String) async throws {
                let triple = try UserToolchain.default.targetTriple
                let out = try await AsyncProcess.checkNonZeroExit(
                    args: fixturePath.appending(components: "packageA", ".build", triple.platformBuildPathComponent, conf, "packageA").pathString
                )
                XCTAssertEqual(out, """
                    calling Y.bar()
                    Y.bar() called
                    X.foo() called
                    123

                    """)
            }

            try await verify("debug")
            try await verify("release")
        }
    }
}
