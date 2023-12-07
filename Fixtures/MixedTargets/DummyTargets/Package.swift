// swift-tools-version: 999.0
// FIXME(ncooke3): Update above version with the next version of SwiftPM.

import PackageDescription

// This package vends targets to aid in testing the MixedTargetsWithObjC package.
let package = Package(
    name: "DummyTargets",
    dependencies: [
         .package(path: "../MixedTargetsWithObjC")
    ],
    targets: [
        .executableTarget(
            name: "ClangExecutableDependsOnDynamicallyLinkedMixedTarget", 
            dependencies: [
                .product(
                    name: "DynamicallyLinkedBasicMixedTarget", 
                    package: "MixedTargetsWithObjC"
                )
            ]
         ),
         .executableTarget(
             name: "ClangExecutableDependsOnStaticallyLinkedMixedTarget",
             dependencies: [
                .product(
                    name: "StaticallyLinkedBasicMixedTarget", 
                    package: "MixedTargetsWithObjC"
                )
            ]
         ),
         .executableTarget(
             name: "SwiftExecutableDependsOnDynamicallyLinkedMixedTarget",
             dependencies: [
                .product(
                    name: "DynamicallyLinkedBasicMixedTarget", 
                    package: "MixedTargetsWithObjC"
                )
             ]
         ),
         .executableTarget(
             name: "SwiftExecutableDependsOnStaticallyLinkedMixedTarget",
             dependencies: [
                .product(
                    name: "StaticallyLinkedBasicMixedTarget", 
                    package: "MixedTargetsWithObjC"
                )
             ]
         )

    ]
)
