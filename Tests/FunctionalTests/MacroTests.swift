//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import DriverSupport
import _InternalTestSupport
import PackageModel
import XCTest

class MacroTests: XCTestCase {
    func testMacrosBasic() throws {
        #if BUILD_MACROS_AS_DYLIBS
        // Check for required compiler support.
        try XCTSkipIf(!DriverSupport.checkSupportedFrontendFlags(flags: ["load-plugin-library"], toolchain: UserToolchain.default, fileSystem: localFileSystem), "test needs `-load-plugin-library`")

        // Check for presence of `libSwiftSyntaxMacros`.
        let libSwiftSyntaxMacrosPath = try UserToolchain.default.hostLibDir.appending("libSwiftSyntaxMacros.dylib")
        try XCTSkipIf(!localFileSystem.exists(libSwiftSyntaxMacrosPath), "test need `libSwiftSyntaxMacros` to exist in the host toolchain")

        try fixture(name: "Macros") { fixturePath in
            let (stdout, _) = try executeSwiftBuild(fixturePath.appending("MacroPackage"), configuration: .Debug)
            XCTAssert(stdout.contains("@__swiftmacro_11MacroClient11fontLiteralfMf_.swift as Font"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Build complete!"), "stdout:\n\(stdout)")
        }
        #else
        try XCTSkipIf(true, "test is only supported if `BUILD_MACROS_AS_DYLIBS`")
        #endif
    }
}
