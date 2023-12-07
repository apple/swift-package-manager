// swift-tools-version: 999.0
// FIXME(ncooke3): Update above version with the next version of SwiftPM.

import PackageDescription

let package = Package(
    name: "MixedTargets",
    products: [
        .library(
            name: "BasicMixedTarget",
            targets: ["BasicMixedTarget"]
        ),
        .library(
            name: "StaticallyLinkedBasicMixedTarget",
            type: .static,
            targets: ["BasicMixedTarget"]
        ),
        .library(
            name: "DynamicallyLinkedBasicMixedTarget",
            type: .dynamic,
            targets: ["BasicMixedTarget"]
        )
    ],
    dependencies: [],
    targets: [
        // MARK: - BasicMixedTarget
        .target(
            name: "BasicMixedTarget"
        ),
        .testTarget(
            name: "BasicMixedTargetTests",
            dependencies: ["BasicMixedTarget"]
        ),

        // FIXME(ncooke3): Re-enable with Swift compiler change (see proposal).
        // // MARK: - BasicMixedTargetWithUmbrellaHeader
        // .target(
        //     name: "BasicMixedTargetWithUmbrellaHeader"
        // ),
        // .testTarget(
        //     name: "BasicMixedTargetWithUmbrellaHeaderTests",
        //     dependencies: ["BasicMixedTargetWithUmbrellaHeader"]
        // ),

        // MARK: - MixedTargetWithResources
        .target(
            name: "MixedTargetWithResources",
            resources: [
                .process("foo.txt")
            ]
        ),
        .testTarget(
            name: "MixedTargetWithResourcesTests",
            dependencies: ["MixedTargetWithResources"]
        ),

        // MARK: - MixedTargetWithCustomModuleMap
        .target(
            name: "MixedTargetWithCustomModuleMap"
        ),
        .testTarget(
            name: "MixedTargetWithCustomModuleMapTests",
            dependencies: ["MixedTargetWithCustomModuleMap"]
        ),

        // MARK: - MixedTargetWithInvalidCustomModuleMap
        .target(
            name: "MixedTargetWithInvalidCustomModuleMap"
        ),

        // MARK: - MixedTargetWithCustomModuleMapAndResources
        .target(
            name: "MixedTargetWithCustomModuleMapAndResources",
            resources: [
                .process("foo.txt")
            ]
        ),
        .testTarget(
            name: "MixedTargetWithCustomModuleMapAndResourcesTests",
            dependencies: ["MixedTargetWithCustomModuleMapAndResources"]
        ),

        // MARK: - MixedTargetWithCXX
        .target(
            name: "MixedTargetWithCXX"
        ),
        .testTarget(
            name: "MixedTargetWithCXXTests",
            dependencies: ["MixedTargetWithCXX"]
        ),

        // MARK: - MixedTargetWithCXXAndCustomModuleMap
        .target(
            name: "MixedTargetWithCXXAndCustomModuleMap"
        ),

        // MARK: - MixedTargetWithCXXPublicAPI
        .target(
            name: "MixedTargetWithCXXPublicAPI"
        ),
        .testTarget(
            name: "MixedTargetWithCXXPublicAPITests",
            dependencies: ["MixedTargetWithCXXPublicAPI"],
            cSettings: [
                // To import `MixedTargetWithCXXPublicAPI` via a module style
                // import, the following unsafe flags must be passed. See
                // the Objective-C++ file in the test target.
                .unsafeFlags(["-fcxx-modules", "-fmodules"])
            ]
        ),

        // MARK: - MixedTargetWithCXXPublicAPIAndCustomModuleMap
        // In order to import this target into downstream targets, two
        // additional things must be done (depending on whether the target is
        // being imported into a Clang vs. Swift context):
        // - Clang context: If the client wants to import the module, client
        //   must pass `-fcxx-modules` and `-fmodules` as unsafe flags in
        //   the target's `cSettings`. Else, the client can just import
        //   individual public headers without further configuring the target.
        // - Swift context: The mixed target needs to make a custom module
        //   map that only exposes public CXX headers in a non-Swift context.
        //
        //      // module.modulemap
        //      module MixedTargetWithCXXPublicAPIAndCustomModuleMap {
        //          umbrella header "PublicNonCXXHeaders.h"
        //
        //          module CXX {
        //              header "PublicCXXHeaders.h"
        //              export *
        //              requires !swift
        //          }
        //
        //          export *
        //      }
        //
        .target(
            name: "MixedTargetWithCXXPublicAPIAndCustomModuleMap"
        ),
        .testTarget(
            name: "MixedTargetWithCXXPublicAPIAndCustomModuleMapTests",
            dependencies: ["MixedTargetWithCXXPublicAPIAndCustomModuleMap"],
            cSettings: [
                // To import `MixedTargetWithCXXPublicAPIAndCustomModuleMap`
                // via a module style import, the following unsafe flags must
                // be passed. See the Objective-C++ file in the test target.
                .unsafeFlags(["-fcxx-modules", "-fmodules"])
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),

        // MARK: - MixedTargetWithC
        .target(
            name: "MixedTargetWithC"
        ),
        .testTarget(
            name: "MixedTargetWithCTests",
            dependencies: ["MixedTargetWithC"]
        ),

        // MARK: - MixedTargetWithNonPublicHeaders
        .target(
            name: "MixedTargetWithNonPublicHeaders"
        ),

        // MARK: - MixedTargetWithCustomPaths
        .target(
            name: "MixedTargetWithCustomPaths",
            path: "MixedTargetWithCustomPaths/Sources",
            publicHeadersPath: "Public",
            cSettings: [
                .headerSearchPath("../../")
            ]
        ),

        // MARK: - MixedTargetWithNestedPublicHeaders
        .target(
            name: "MixedTargetWithNestedPublicHeaders",
            publicHeadersPath: "Blah/Public"
        ),

        // MARK: - MixedTargetWithNestedPublicHeadersAndCustomModuleMap
        .target(
            name: "MixedTargetWithNestedPublicHeadersAndCustomModuleMap",
            publicHeadersPath: "Blah/Public"
        ),

        // MARK: - MixedTargetWithNoPublicObjectiveCHeaders
        // This target is an edge case. It's purpose may or may not be
        // useful, but it shouldn't fail to build.
       .target(
           name: "MixedTargetWithNoPublicObjectiveCHeaders"
       ),
        .testTarget(
            name: "MixedTargetWithNoPublicObjectiveCHeadersTests",
            dependencies: ["MixedTargetWithNoPublicObjectiveCHeaders"]
        ),

        // MARK: - MixedTargetWithNoObjectiveCCompatibleSwiftAPI
        .target(
           name: "MixedTargetWithNoObjectiveCCompatibleSwiftAPI"
       ),

        // MARK: - MixedTestTargetWithSharedTestUtilities
        .testTarget(
            name: "MixedTestTargetWithSharedUtilitiesTests"
        ),

        // MARK: - PrivateHeadersCanBeTestedViaHeaderSearchPathsTests
        .testTarget(
            name: "PrivateHeadersCanBeTestedViaHeaderSearchPathsTests",
            dependencies: ["MixedTargetWithNonPublicHeaders"],
            cSettings: [
                // Adding a header search path at the root of the package will
                // enable the Objective-C tests to import private headers.
                .headerSearchPath("../../")
            ]
        ),

        // MARK: - MixedTargetsPublicHeadersAreIncludedInHeaderSearchPathsForObjcSource
        .target(
            name: "MixedTargetsPublicHeadersAreIncludedInHeaderSearchPathsForObjcSource"
        ),

        // MARK: - Targets for testing the integration of a mixed target
        .target(
            name: "ClangTargetDependsOnMixedTarget",
            dependencies: ["BasicMixedTarget"]
         ),
         .target(
             name: "SwiftTargetDependsOnMixedTarget",
             dependencies: ["BasicMixedTarget"]
         ),
         .target(
             name: "MixedTargetDependsOnMixedTarget",
             dependencies: ["BasicMixedTarget"]
         ),
         .target(
             name: "MixedTargetDependsOnClangTarget",
             dependencies: ["ClangTarget"]
         ),
         .target(
             name: "MixedTargetDependsOnSwiftTarget",
             dependencies: ["SwiftTarget"]
         ),
         // The below two targets are used for testing the above targets.
         .target(name: "SwiftTarget"),
         .target(name: "ClangTarget")
    ]
)
