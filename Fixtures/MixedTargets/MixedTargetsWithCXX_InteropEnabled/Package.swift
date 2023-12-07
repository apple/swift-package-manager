// swift-tools-version: 999.0
// FIXME(ncooke3): Update above version with the next version of SwiftPM.

// NOTE: This is package is intended to build on all platforms (macOS, Linux, and Windows).

import PackageDescription

let package = Package(
    name: "MixedTargetsWithCXX_InteropEnabled",
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
          name: "MixedTarget",
          swiftSettings: [.interoperabilityMode(.Cxx)]
        )
    ],
    // TODO(ncooke3): Is the below note behavior that we want to be intended?
    // This is needed for targets with that have
    // `swiftSettings: [.interoperabilityMode(.Cxx)]` set.
    cxxLanguageStandard: .cxx11
)
