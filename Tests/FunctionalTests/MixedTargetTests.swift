//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import XCTest
import SPMTestSupport

final class MixedTargetTests: XCTestCase {
    // MARK: - All Platforms Tests

    // The below tests build targets with C++ interoperability mode enabled, a
    // feature that requires Swift 5.9 or greater.
    // FIXME(ncooke3): Update with next version of SPM.
    #if swift(>=5.9)
    func testMixedTargetWithCXX_InteropEnabled() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithCXX_InteropEnabled") { fixturePath in
            XCTAssertBuilds(
                fixturePath,
                extraArgs: ["--target", "MixedTarget"]
            )
        }
    }
    #endif  // swift(>=5.9)

    func testMixedTargetWithCXX_InteropDisabled() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithCXX_InteropDisabled") { fixturePath in
            XCTAssertBuilds(
                fixturePath,
                extraArgs: ["--target", "MixedTarget"]
            )
        }
    }
}

#if os(macOS)
extension MixedTargetTests {
    // MARK: - macOS Tests
    // The targets tested contain Objective-C, and thus require macOS to be tested.

    func testMixedTarget() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertBuilds(
                fixturePath,
                extraArgs: ["--target", "BasicMixedTarget"]
            )
        }
    }

// FIXME(ncooke3): Re-enable with Swift compiler change (see proposal).
//    func testMixedTargetWithUmbrellaHeader() throws {
//        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
//            XCTAssertBuilds(
//                fixturePath,
//                extraArgs: ["--target", "BasicMixedTargetWithUmbrellaHeader"]
//            )
//            XCTAssertSwiftTest(
//                fixturePath,
//                extraArgs: ["--filter", "BasicMixedTargetWithUmbrellaHeaderTests"]
//            )
//        }
//    }

    func testMixedTargetWithResources() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertSwiftTest(
                fixturePath,
                extraArgs: ["--filter", "MixedTargetWithResources"]
            )
        }
    }

    func testMixedTargetWithCustomModuleMap() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertBuilds(
                fixturePath,
                extraArgs: ["--target", "MixedTargetWithCustomModuleMap"]
            )
            
            for value in [0, 1] {
                XCTAssertSwiftTest(
                    fixturePath,
                    extraArgs: ["--filter", "MixedTargetWithCustomModuleMapTests"],
                    Xcc: ["-DTEST_MODULE_IMPORTS=\(value)"]
                )
            }
        }
    }

    func testMixedTargetWithInvalidCustomModuleMap() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            // An invalid module map will cause the whole package to fail to
            // build. To work around this, the module map is made invalid
            // during the actual test.
            let moduleMapPath = fixturePath.appending(
                .init("Sources/MixedTargetWithInvalidCustomModuleMap/include/module.modulemap")
            )

            // In this case, an invalid module map is one that include a
            // submodule of the form `$(ModuleName).Swift`. This is invalid
            // because it collides with the submodule that SwiftPM will generate.
            try """
            module MixedTargetWithInvalidCustomModuleMap {
                header "Foo.h"
            }

            module MixedTargetWithInvalidCustomModuleMap.Swift {}
            """.write(to: moduleMapPath.asURL, atomically: true, encoding: .utf8)

            let commandExecutionError = try XCTUnwrap(
                XCTAssertBuildFails(
                    fixturePath,
                    extraArgs: ["--target", "MixedTargetWithInvalidCustomModuleMap"]
                )
            )

            XCTAssert(
                commandExecutionError.stderr.contains(
                    "error: The target's module map may not contain a Swift " +
                    "submodule for the module MixedTargetWithInvalidCustomModuleMap."
                )
            )
        }
    }

    func testMixedTargetWithCustomModuleMapAndResources() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertSwiftTest(
                fixturePath,
                extraArgs: [
                    "--filter", "MixedTargetWithCustomModuleMapAndResourcesTests"
// FIXME(ncooke3): Blocked by fix for #5728. Even though #5728 regression was
// addressed in #6055, #5728 is guarded on Swift Tools Version `.vNext`– which
// is also how the mixed language support is guarded. This comment should be
// resolved once the mixed language test feature is staged for release and the
// mixed language Fixture test targets have a swift-tools-version matching the
// expected tools version that the mixed language test targets will release in.
//                ],
//                // Surface warning where custom umbrella header does not
//                // include `resource_bundle_accessor.h` in `build` directory.
//                Xswiftc: [
//                    "-warnings-as-errors"
                ]
            )
        } 
    }

    func testMixedTargetWithCXX() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertSwiftTest(
                fixturePath,
                extraArgs: ["--filter", "MixedTargetWithCXXTests"]
            )
        }
    }

    func testMixedTargetWithCXXAndCustomModuleMap() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertBuilds(
                fixturePath,
                extraArgs: ["--target", "MixedTargetWithCXXAndCustomModuleMap"]
            )
        }
    }

    func testMixedTargetWithCXXPublicAPI() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertBuilds(
                fixturePath,
                extraArgs: ["--target", "MixedTargetWithCXXPublicAPI"]
            )
            for value in [0, 1] {
                XCTAssertSwiftTest(
                    fixturePath,
                    extraArgs: ["--filter", "MixedTargetWithCXXPublicAPITests"],
                    Xcc: ["-DTEST_MODULE_IMPORTS=\(value)"]
                )
            }
        }
    }
    
    func testMixedTargetWithCXXPublicAPIAndCustomModuleMap() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertBuilds(
                fixturePath,
                extraArgs: ["--target", "MixedTargetWithCXXPublicAPIAndCustomModuleMap"]
            )
            for value in [0, 1] {
                XCTAssertSwiftTest(
                    fixturePath,
                    extraArgs: ["--filter", "MixedTargetWithCXXPublicAPIAndCustomModuleMapTests"],
                    Xcc: ["-DTEST_MODULE_IMPORTS=\(value)"]
                )
            }
        }
    }


    func testMixedTargetWithC() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertSwiftTest(
                fixturePath,
                extraArgs: ["--filter", "MixedTargetWithC"]
            )
        }
    }

    func testMixedTargetWithNoPublicObjectiveCHeaders() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertSwiftTest(
                fixturePath,
                extraArgs: ["--filter", "MixedTargetWithNoPublicObjectiveCHeadersTests"]
            )

            XCTAssertBuildFails(
                fixturePath,
                extraArgs: ["--target", "MixedTargetWithNoPublicObjectiveCHeadersTests"],
                Xcc: ["EXPECT_FAILURE"]
            )
        }
    }

    func testMixedTargetWithNoObjectiveCCompatibleSwiftAPI() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertBuilds(
                fixturePath,
                extraArgs: ["--target", "MixedTargetWithNoObjectiveCCompatibleSwiftAPI"]
            )

            XCTAssertBuildFails(
                fixturePath,
                extraArgs: ["--target", "MixedTargetWithNoObjectiveCCompatibleSwiftAPI"],
                Xcc: ["EXPECT_FAILURE"]
            )
        }
    }

    func testNonPublicHeadersAreVisibleFromSwiftPartOfMixedTarget() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertBuildFails(
                fixturePath,
                extraArgs: ["--target", "MixedTargetWithNonPublicHeaders"],
                // Without selectively enabling the tests with the below macro,
                // the intentional build failure will break other unit tests
                // since all targets in the package are build when running
                // `swift test`.
                Xswiftc: ["EXPECT_FAILURE"]
            )
        }
    }

    func testMixedTargetWithCustomPaths() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertBuilds(
                fixturePath,
                extraArgs: ["--target", "MixedTargetWithCustomPaths"]
            )
        }

    }

    func testMixedTargetBuildsInReleaseMode() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertBuilds(
                fixturePath,
                extraArgs: [
                    "--target", "BasicMixedTarget",
                    "--configuration", "release"
                ]
            )
        }
    }

    func testStaticallyLinkedMixedTarget() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertBuilds(
                fixturePath,
                extraArgs: ["--product", "StaticallyLinkedBasicMixedTarget"]
            )
        }

        // Test that statically linked mixed library is successfully
        // integrated into an Objective-C executable.
        try fixture(name: "MixedTargets") { fixturePath in
            let output = try executeSwiftRun(
                fixturePath.appending(component: "DummyTargets"),
                "ClangExecutableDependsOnStaticallyLinkedMixedTarget"
            )
            // The program should print "Hello, world!"
            XCTAssert(output.stderr.contains("Hello, world!"))
        }

        // Test that statically linked mixed library is successfully
        // integrated into a Swift executable.
        try fixture(name: "MixedTargets") { fixturePath in
            let output = try executeSwiftRun(
                fixturePath.appending(component: "DummyTargets"),
                "SwiftExecutableDependsOnStaticallyLinkedMixedTarget"
            )
            // The program should print "Hello, world!"
            XCTAssert(output.stdout.contains("Hello, world!"))
        }
    }

    func testDynamicallyLinkedMixedTarget() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertBuilds(
                fixturePath,
                extraArgs: ["--product", "DynamicallyLinkedBasicMixedTarget"]
            )
        }

        // Test that dynamically linked mixed library is successfully
        // integrated into an Objective-C executable.
        try fixture(name: "MixedTargets") { fixturePath in
            let output = try executeSwiftRun(
                fixturePath.appending(component: "DummyTargets"),
                "ClangExecutableDependsOnDynamicallyLinkedMixedTarget"
            )
            // The program should print "Hello, world!"
            XCTAssert(output.stderr.contains("Hello, world!"))
        }

        // Test that dynamically linked mixed library is successfully
        // integrated into a Swift executable.
        try fixture(name: "MixedTargets") { fixturePath in
            let output = try executeSwiftRun(
                fixturePath.appending(component: "DummyTargets"),
                "SwiftExecutableDependsOnDynamicallyLinkedMixedTarget"
            )
            // The program should print "Hello, world!"
            XCTAssert(output.stdout.contains("Hello, world!"))
        }
    }

    func testMixedTargetsPublicHeadersAreIncludedInHeaderSearchPathsForObjcSource() throws {
        // Consider a mixed target with the following structure:
        //
        //      MixedTarget
        //      ├── NewCar.swift
        //      ├── OldCar.m
        //      └── include
        //          └── OldCar.h
        // 
        // Within the `OldCar.m` implementation, the `OldCar.h` header should
        // be able to be imported via the following import statements:
        // - #import "OldCar.h"
        // - #import "include/OldCar.h"
        //
        // This aligns with the behavior of a Clang-only target.
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertBuilds(
                fixturePath,
                extraArgs: [
                    "--target", 
                    "MixedTargetsPublicHeadersAreIncludedInHeaderSearchPathsForObjcSource"
                ]
            )
        }
    }

    func testMixedTargetWithNestedPublicHeaders() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertBuilds(
                fixturePath,
                extraArgs: ["--target", "MixedTargetWithNestedPublicHeaders"]
            )
        }
    }

    func testMixedTargetWithNestedPublicHeadersAndCustomModuleMap() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertBuilds(
                fixturePath,
                extraArgs: [
                    "--target",
                    "MixedTargetWithNestedPublicHeadersAndCustomModuleMap"
                ]
            )
        }
    }

    // MARK: - Testing Mixed *Test* Targets

    func testMixedTestTarget() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            for value in [0, 1] {
                XCTAssertSwiftTest(
                    fixturePath,
                    extraArgs: ["--filter", "BasicMixedTargetTests"],
                    Xcc: ["-DTEST_MODULE_IMPORTS=\(value)"]
                )
            }
        }
    }

    func testTestUtilitiesCanBeSharedAcrossSwiftAndObjcTestFiles() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertSwiftTest(
                fixturePath,
                extraArgs: ["--filter", "MixedTestTargetWithSharedUtilitiesTests"]
            )
        }
    }

    func testPrivateHeadersCanBeTestedViaHeaderSearchPaths() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertSwiftTest(
                fixturePath,
                extraArgs: ["--filter", "PrivateHeadersCanBeTestedViaHeaderSearchPathsTests"]
            )
        }
    }

    // MARK: - Integrating Mixed Target with other Targets

    func testClangTargetDependsOnMixedTarget() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            for value in [0, 1] {
                XCTAssertBuilds(
                    fixturePath,
                    extraArgs: ["--target", "ClangTargetDependsOnMixedTarget"],
                    Xcc: ["-DTEST_MODULE_IMPORTS=\(value)"]
                )
            }
        }
    }

     func testSwiftTargetDependsOnMixedTarget() throws {
         try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
             XCTAssertBuilds(
                 fixturePath,
                 extraArgs: ["--target", "SwiftTargetDependsOnMixedTarget"]
             )
         }
     }

     func testMixedTargetDependsOnOtherMixedTarget() throws {
         try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
             for value in [0, 1] {
                 XCTAssertBuilds(
                    fixturePath,
                    extraArgs: ["--target", "MixedTargetDependsOnMixedTarget"],
                    Xcc: ["-DTEST_MODULE_IMPORTS=\(value)"]
                 )
             }
         }
     }

     func testMixedTargetDependsOnClangTarget() throws {
         try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
             XCTAssertBuilds(
                 fixturePath,
                 extraArgs: ["--target", "MixedTargetDependsOnClangTarget"]
             )
         }
     }

    func testMixedTargetDependsOnSwiftTarget() throws {
        try fixture(name: "MixedTargets/MixedTargetsWithObjC") { fixturePath in
            XCTAssertBuilds(
                fixturePath,
                extraArgs: ["--target", "MixedTargetDependsOnSwiftTarget"]
            )
        }
    }
}
#endif  // os(macOS)
