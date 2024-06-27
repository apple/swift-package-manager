// swift-tools-version: 999.0.0

@_spi(ExperimentalTraits) import PackageDescription

let package = Package(
    name: "Package5",
    products: [
        .library(
            name: "Package5Library1",
            targets: ["Package5Library1"]
        ),
    ],
    traits: [
        "Package5Trait1"
    ],
    dependencies: [
        .package(
            path: "../Package6",
            traits: [
                Package.Dependency.Trait(name: "Package6Trait1", condition: .when(traits: ["Package5Trait1"]))
            ]
        )
    ],
    targets: [
        .target(
            name: "Package5Library1",
            dependencies: [
                .product(
                    name: "Package6Library1",
                    package: "Package6"
                )
            ]
        ),
    ]
)
