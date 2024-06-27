// swift-tools-version: 999.0.0

@_spi(ExperimentalTraits) import PackageDescription

let package = Package(
    name: "Package9",
    products: [
        .library(
            name: "Package9Library1",
            targets: ["Package9Library1"]
        ),
    ],
    dependencies: [
        .package(
            path: "../Package10",
            traits: ["Package10Trait1"]
        )
    ],
    targets: [
        .target(
            name: "Package9Library1",
            dependencies: [
                .product(
                    name: "Package10Library1",
                    package: "Package10"
                )
            ]
        ),
    ]
)
