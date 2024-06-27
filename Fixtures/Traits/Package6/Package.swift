// swift-tools-version: 999.0.0

@_spi(ExperimentalTraits) import PackageDescription

let package = Package(
    name: "Package6",
    products: [
        .library(
            name: "Package6Library1",
            targets: ["Package6Library1"]
        ),
    ],
    traits: [
        "Package6Trait1"
    ],
    targets: [
        .target(
            name: "Package6Library1"
        ),
    ]
)
