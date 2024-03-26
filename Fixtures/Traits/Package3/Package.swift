// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Package3",
    products: [
        .library(
            name: "Package3Library1",
            targets: ["Package3Library1"]
        ),
    ],
    traits: [
        Trait(name: "Package3Trait1", enabledTraits: ["Package3Trait2"]),
        Trait(name: "Package3Trait2", enabledTraits: ["Package3Trait3"]),
        "Package3Trait3"
    ],
    defaultTraits: [
        "Package3Trait1"
    ],
    targets: [
        .target(
            name: "Package3Library1"
        ),
    ]
)
