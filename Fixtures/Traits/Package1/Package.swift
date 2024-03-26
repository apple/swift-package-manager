// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Package1",
    products: [
        .library(
            name: "Package1Library1",
            targets: ["Package1Library1"]
        ),
    ],
    traits: [
        "Package1Trait1"
    ],
    targets: [
        .target(
            name: "Package1Library1"
        ),
    ]
)
