// swift-tools-version: 999.0
// FIXME(ncooke3): Update above version with the next version of SwiftPM.

// NOTE: This is package is intended to build on all platforms (macOS, Linux, and Windows).

import PackageDescription

let package = Package(
    name: "MixedTargetsWithCXX_InteropDisabled",
    products: [
        .library(
            name: "MixedTarget",
            targets: ["MixedTarget"]
        ),
        .library(
            name: "StaticallyLinkedMixedTarget",
            type: .static,
            targets: ["MixedTarget"]
        ),
        .library(
            name: "DynamicallyLinkedMixedTarget",
            type: .dynamic,
            targets: ["MixedTarget"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
          name: "MixedTarget"
        )
    ]
)
