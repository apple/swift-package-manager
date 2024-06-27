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

import Commands
import PackageModel
import SourceControl
import _InternalTestSupport
import Workspace
import XCTest
 
final class ModuleAliasingFixtureTests: XCTestCase {
    func testModuleDirectDeps1() async throws {
        try await fixture(name: "ModuleAliasing/DirectDeps1") { fixturePath in
            let pkgPath = fixturePath.appending(components: "AppPkg")
            let buildPath = pkgPath.appending(components: ".build", try UserToolchain.default.targetTriple.platformBuildPathComponent, "debug")
            await XCTAssertBuilds(pkgPath, extraArgs: ["--vv"])
            XCTAssertFileExists(buildPath.appending(components: "App"))
            XCTAssertFileExists(buildPath.appending(components: "Modules", "GameUtils.swiftmodule"))
            XCTAssertFileExists(buildPath.appending(components: "Modules", "Utils.swiftmodule"))
            _ = try await SwiftPM.Build.execute(packagePath: pkgPath)
        }
    }

    func testModuleDirectDeps2() async throws {
        try await fixture(name: "ModuleAliasing/DirectDeps2") { fixturePath in
            let pkgPath = fixturePath.appending(components: "AppPkg")
            let buildPath = pkgPath.appending(components: ".build", try UserToolchain.default.targetTriple.platformBuildPathComponent, "debug")
            await XCTAssertBuilds(pkgPath, extraArgs: ["--vv"])
            XCTAssertFileExists(buildPath.appending(components: "App"))
            XCTAssertFileExists(buildPath.appending(components: "Modules", "AUtils.swiftmodule"))
            XCTAssertFileExists(buildPath.appending(components: "Modules", "BUtils.swiftmodule"))
            _ = try await SwiftPM.Build.execute(packagePath: pkgPath)
        }
    }
}
