// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Package4",
    products: [
        .library(
            name: "Package4Library1",
            targets: ["Package4Library1"]
        ),
    ],
    traits: [
        "Package4Trait1"
    ],
    defaultTraits: [
        "Package4Trait1"
    ],
    targets: [
        .target(
            name: "Package4Library1"
        ),
    ]
)
