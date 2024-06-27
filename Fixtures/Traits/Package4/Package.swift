// swift-tools-version: 999.0.0

@_spi(ExperimentalTraits) import PackageDescription

let package = Package(
    name: "Package4",
    products: [
        .library(
            name: "Package4Library1",
            targets: ["Package4Library1"]
        ),
    ],
    traits: [
        .default(enabledTraits: ["Package4Trait1"]),
        "Package4Trait1",
    ],
    targets: [
        .target(
            name: "Package4Library1"
        ),
    ]
)
