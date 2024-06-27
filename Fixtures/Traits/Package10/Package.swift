// swift-tools-version: 999.0.0

@_spi(ExperimentalTraits) import PackageDescription

let package = Package(
    name: "Package10",
    products: [
        .library(
            name: "Package10Library1",
            targets: ["Package10Library1"]
        ),
    ],
    traits: [
        "Package10Trait1",
        "Package10Trait2"
    ],
    targets: [
        .target(
            name: "Package10Library1"
        ),
    ]
)
