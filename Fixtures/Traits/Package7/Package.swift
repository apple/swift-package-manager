// swift-tools-version: 999.0.0

@_spi(ExperimentalTraits) import PackageDescription

let package = Package(
    name: "Package7",
    products: [
        .library(
            name: "Package7Library1",
            targets: ["Package7Library1"]
        ),
    ],
    traits: [
        "Package7Trait1"
    ],
    dependencies: [
        .package(
            path: "../Package8"
        )
    ],
    targets: [
        .target(
            name: "Package7Library1",
            dependencies: [
                .product(
                    name: "Package8Library1",
                    package: "Package8",
                    condition: .when(traits: ["Package7Trait1"])
                )
            ]
        ),
    ]
)
