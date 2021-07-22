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

class BuildPerfTests: XCTestCasePerf {

    @discardableResult
    func execute(args: [String] = [], packagePath: AbsolutePath) throws -> (stdout: String, stderr: String) {
        // FIXME: We should pass the SWIFT_EXEC at lower level.
        return try SwiftPMProduct.SwiftBuild.execute(args + [], packagePath: packagePath, env: ["SWIFT_EXEC": Resources.default.swiftCompiler.pathString])
    }

    func clean(packagePath: AbsolutePath) throws {
        _ = try SwiftPMProduct.SwiftPackage.execute(["clean"], packagePath: packagePath)
    }

    func testTrivialPackageFullBuild() {
      #if os(macOS)
        runFullBuildTest(for: "DependencyResolution/Internal/Simple", product: "foo")
      #endif
    }

    func testTrivialPackageNullBuild() {
      #if os(macOS)
        runNullBuildTest(for: "DependencyResolution/Internal/Simple", product: "foo")
      #endif
    }

    func testComplexPackageFullBuild() {
      #if os(macOS)
        runFullBuildTest(for: "DependencyResolution/External/Complex", app: "app", product: "Dealer")
      #endif
    }

    func testComplexPackageNullBuild() {
      #if os(macOS)
        runNullBuildTest(for: "DependencyResolution/External/Complex", app: "app", product: "Dealer")
      #endif
    }

    func runFullBuildTest(for name: String, app appString: String? = nil, product productString: String) {
        fixture(name: name) { prefix in
            let app = prefix.appending(components: (appString ?? ""))
            let triple = Resources.default.toolchain.triple
            let product = app.appending(components: ".build", triple.platformBuildPathComponent(), "debug", productString)
            try self.execute(packagePath: app)
            measure {
                try! self.clean(packagePath: app)
                try! self.execute(packagePath: app)
                XCTAssertFileExists(product)
            }
        }
    }

    func runNullBuildTest(for name: String, app appString: String? = nil, product productString: String) {
        fixture(name: name) { prefix in
            let app = prefix.appending(components: (appString ?? ""))
            let triple = Resources.default.toolchain.triple
            let product = app.appending(components: ".build", triple.platformBuildPathComponent(), "debug", productString)
            try self.execute(packagePath: app)
            measure {
                try! self.execute(packagePath: app)
                XCTAssertFileExists(product)
            }
        }
    }
}
