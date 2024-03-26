//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import DriverSupport
import SPMTestSupport
import PackageModel
import XCTest

final class TraitTests: XCTestCase {
    func testTraits_whenNoFlagPassed() throws {
        try fixture(name: "Traits") { fixturePath in
            let (stdout, _) = try executeSwiftRun(fixturePath.appending("Example"), "Example")
            XCTAssertEqual(stdout, """
            Package1Library1 trait1 enabled
            Package2Library1 trait2 enabled
            Package3Library1 trait3 enabled
            Package4Library1 trait1 disabled
            DEFINE1 enabled
            DEFINE2 disabled
            DEFINE3 disabled

            """)
        }
    }

    func testTraits_whenTraitUnification() throws {
        try fixture(name: "Traits") { fixturePath in
            let (stdout, _) = try executeSwiftRun(fixturePath.appending("Example"), "Example", extraArgs: ["--traits", "Package9,Package10"])
            XCTAssertEqual(stdout, """
            Package1Library1 trait1 enabled
            Package2Library1 trait2 enabled
            Package3Library1 trait3 enabled
            Package4Library1 trait1 disabled
            Package10Library1 trait1 enabled
            Package10Library1 trait2 enabled
            Package10Library1 trait1 enabled
            Package10Library1 trait2 enabled
            DEFINE1 enabled
            DEFINE2 disabled
            DEFINE3 disabled

            """)
        }
    }

    func testTraits_whenTraitUnification_whenSecondTraitNotEnabled() throws {
        try fixture(name: "Traits") { fixturePath in
            let (stdout, _) = try executeSwiftRun(fixturePath.appending("Example"), "Example", extraArgs: ["--traits", "Package9"])
            XCTAssertEqual(stdout, """
            Package1Library1 trait1 enabled
            Package2Library1 trait2 enabled
            Package3Library1 trait3 enabled
            Package4Library1 trait1 disabled
            Package10Library1 trait1 enabled
            Package10Library1 trait2 enabled
            DEFINE1 enabled
            DEFINE2 disabled
            DEFINE3 disabled

            """)
        }
    }

    func testTraits_whenIndividualTraitsEnabled_andDefaultTraits() throws {
        try fixture(name: "Traits") { fixturePath in
            let (stdout, _) = try executeSwiftRun(fixturePath.appending("Example"), "Example", extraArgs: ["--traits", "Package5,Package7,BuildCondition3"])
            XCTAssertEqual(stdout, """
            Package1Library1 trait1 enabled
            Package2Library1 trait2 enabled
            Package3Library1 trait3 enabled
            Package4Library1 trait1 disabled
            Package5Library1 trait1 enabled
            Package6Library1 trait1 enabled
            Package7Library1 trait1 disabled
            DEFINE1 enabled
            DEFINE2 disabled
            DEFINE3 enabled

            """)
        }
    }

    func testTraits_whenDefaultTraitsDisabled() throws {
        try fixture(name: "Traits") { fixturePath in
            let (stdout, _) = try executeSwiftRun(fixturePath.appending("Example"), "Example", extraArgs: ["--disable-default-traits"])
            XCTAssertEqual(stdout, """
            DEFINE1 disabled
            DEFINE2 disabled
            DEFINE3 disabled

            """)
        }
    }

    func testTraits_whenIndividualTraitsEnabled_andDefaultTraitsDisabled() throws {
        try fixture(name: "Traits") { fixturePath in
            let (stdout, _) = try executeSwiftRun(fixturePath.appending("Example"), "Example", extraArgs: ["--traits", "Package5,Package7", "--disable-default-traits"])
            XCTAssertEqual(stdout, """
            Package5Library1 trait1 enabled
            Package6Library1 trait1 enabled
            Package7Library1 trait1 disabled
            DEFINE1 disabled
            DEFINE2 disabled
            DEFINE3 disabled

            """)
        }
    }

    func testTraits_whenAllTraitsEnabled() throws {
        try fixture(name: "Traits") { fixturePath in
            let (stdout, _) = try executeSwiftRun(fixturePath.appending("Example"), "Example", extraArgs: ["--enable-all-traits"])
            XCTAssertEqual(stdout, """
            Package1Library1 trait1 enabled
            Package2Library1 trait2 enabled
            Package3Library1 trait3 enabled
            Package4Library1 trait1 disabled
            Package5Library1 trait1 enabled
            Package6Library1 trait1 enabled
            Package7Library1 trait1 disabled
            Package10Library1 trait1 enabled
            Package10Library1 trait2 enabled
            Package10Library1 trait1 enabled
            Package10Library1 trait2 enabled
            DEFINE1 enabled
            DEFINE2 enabled
            DEFINE3 enabled

            """)
        }
    }

    func testTraits_whenAllTraitsEnabled_andDefaultTraitsDisabled() throws {
        try fixture(name: "Traits") { fixturePath in
            let (stdout, _) = try executeSwiftRun(fixturePath.appending("Example"), "Example", extraArgs: ["--enable-all-traits", "--disable-default-traits"])
            XCTAssertEqual(stdout, """
            Package1Library1 trait1 enabled
            Package2Library1 trait2 enabled
            Package3Library1 trait3 enabled
            Package4Library1 trait1 disabled
            Package5Library1 trait1 enabled
            Package6Library1 trait1 enabled
            Package7Library1 trait1 disabled
            Package10Library1 trait1 enabled
            Package10Library1 trait2 enabled
            Package10Library1 trait1 enabled
            Package10Library1 trait2 enabled
            DEFINE1 enabled
            DEFINE2 enabled
            DEFINE3 enabled

            """)
        }
    }
}
