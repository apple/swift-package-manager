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

// FIXME: re-enable when `measure` supports `async` or replace with lower level benchmarks
//import Basics
//import Commands
//import PackageModel
//import InternalTestSupport
//import Workspace
//import XCTest
//
//import class TSCTestSupport.XCTestCasePerf
//
//final class BuildPerfTests: XCTestCasePerf {
//    @discardableResult
//    func execute(args: [String] = [], packagePath: AbsolutePath) async throws -> (stdout: String, stderr: String) {
//        // FIXME: We should pass the SWIFT_EXEC at lower level.
//        try await SwiftPM.Build.execute(args + [], packagePath: packagePath, env: ["SWIFT_EXEC": UserToolchain.default.swiftCompilerPath.pathString])
//    }
//
//    func clean(packagePath: AbsolutePath) async throws {
//        _ = try await SwiftPM.Package.execute(["clean"], packagePath: packagePath)
//    }
//
//    func testTrivialPackageFullBuild() throws {
//        #if !os(macOS)
//        try XCTSkipIf(true, "test is only supported on macOS")
//        #endif
//        try runFullBuildTest(for: "DependencyResolution/Internal/Simple", product: "foo")
//    }
//
//    func testTrivialPackageNullBuild() throws {
//        #if !os(macOS)
//        try XCTSkipIf(true, "test is only supported on macOS")
//        #endif
//        try runNullBuildTest(for: "DependencyResolution/Internal/Simple", product: "foo")
//    }
//
//    func testComplexPackageFullBuild() throws {
//        #if !os(macOS)
//        try XCTSkipIf(true, "test is only supported on macOS")
//        #endif
//        try runFullBuildTest(for: "DependencyResolution/External/Complex", app: "app", product: "Dealer")
//    }
//
//    func testComplexPackageNullBuild() throws {
//        #if !os(macOS)
//        try XCTSkipIf(true, "test is only supported on macOS")
//        #endif
//        try runNullBuildTest(for: "DependencyResolution/External/Complex", app: "app", product: "Dealer")
//    }
//
//    func runFullBuildTest(for name: String, app appString: String? = nil, product productString: String) throws {
//        try fixture(name: name) { fixturePath in
//            let app = fixturePath.appending(components: (appString ?? ""))
//            let triple = try UserToolchain.default.targetTriple
//            let product = app.appending(components: ".build", triple.platformBuildPathComponent, "debug", productString)
//            try await self.execute(packagePath: app)
//            measure {
//                try! await self.clean(packagePath: app)
//                try! await self.execute(packagePath: app)
//                XCTAssertFileExists(product)
//            }
//        }
//    }
//
//    func runNullBuildTest(for name: String, app appString: String? = nil, product productString: String) throws {
//        try fixture(name: name) { fixturePath in
//            let app = fixturePath.appending(components: (appString ?? ""))
//            let triple = try UserToolchain.default.targetTriple
//            let product = app.appending(components: ".build", triple.platformBuildPathComponent, "debug", productString)
//            try self.execute(packagePath: app)
//            measure {
//                try! self.execute(packagePath: app)
//                XCTAssertFileExists(product)
//            }
//        }
//    }
//}
