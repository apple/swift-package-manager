// swift-tools-version: 999.0.0

@_spi(ExperimentalTraits) import PackageDescription

let package = Package(
    name: "TraitsExample",
    traits: [
        .default(
            enabledTraits: [
                "Package1",
                "Package2",
                "Package3",
                "Package4",
                "BuildCondition1",
            ]
        ),
        "Package1",
        "Package2",
        "Package3",
        "Package4",
        "Package5",
        "Package7",
        "Package9",
        "Package10",
        "BuildCondition1",
        "BuildCondition2",
        "BuildCondition3",
    ],
    dependencies: [
        .package(
            path: "../Package1",
            traits: ["Package1Trait1"]
        ),
        .package(
            path: "../Package2",
            traits: ["Package2Trait1"]
        ),
        .package(
            path: "../Package3"
        ),
        .package(
            path: "../Package4",
            traits: []
        ),
        .package(
            path: "../Package5",
            traits: ["Package5Trait1"]
        ),
        .package(
            path: "../Package7"
        ),
        .package(
            path: "../Package9"
        ),
        .package(
            path: "../Package10",
            traits: ["Package10Trait2"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "Example",
            dependencies: [
                .product(
                    name: "Package1Library1",
                    package: "Package1",
                    condition: .when(traits: ["Package1"])
                ),
                .product(
                    name: "Package2Library1",
                    package: "Package2",
                    condition: .when(traits: ["Package2"])
                ),
                .product(
                    name: "Package3Library1",
                    package: "Package3",
                    condition: .when(traits: ["Package3"])
                ),
                .product(
                    name: "Package4Library1",
                    package: "Package4",
                    condition: .when(traits: ["Package4"])
                ),
                .product(
                    name: "Package5Library1",
                    package: "Package5",
                    condition: .when(traits: ["Package5"])
                ),
                .product(
                    name: "Package7Library1",
                    package: "Package7",
                    condition: .when(traits: ["Package7"])
                ),
                .product(
                    name: "Package9Library1",
                    package: "Package9",
                    condition: .when(traits: ["Package9"])
                ),
                .product(
                    name: "Package10Library1",
                    package: "Package10",
                    condition: .when(traits: ["Package10"])
                ),
            ],
            swiftSettings: [
                .define("DEFINE1", .when(traits: ["BuildCondition1"])),
                .define("DEFINE2", .when(traits: ["BuildCondition2"])),
                .define("DEFINE3", .when(traits: ["BuildCondition3"])),
            ]
        ),
        .testTarget(
            name: "ExampleTests",
            dependencies: [
                .product(
                    name: "Package1Library1",
                    package: "Package1",
                    condition: .when(traits: ["Package1"])
                ),
                .product(
                    name: "Package2Library1",
                    package: "Package2",
                    condition: .when(traits: ["Package2"])
                ),
                .product(
                    name: "Package3Library1",
                    package: "Package3",
                    condition: .when(traits: ["Package3"])
                ),
                .product(
                    name: "Package4Library1",
                    package: "Package4",
                    condition: .when(traits: ["Package4"])
                ),
                .product(
                    name: "Package5Library1",
                    package: "Package5",
                    condition: .when(traits: ["Package5"])
                ),
                .product(
                    name: "Package7Library1",
                    package: "Package7",
                    condition: .when(traits: ["Package7"])
                ),
                .product(
                    name: "Package9Library1",
                    package: "Package9",
                    condition: .when(traits: ["Package9"])
                ),
                .product(
                    name: "Package10Library1",
                    package: "Package10",
                    condition: .when(traits: ["Package10"])
                ),
            ],
            swiftSettings: [
                .define("DEFINE1", .when(traits: ["BuildCondition1"])),
                .define("DEFINE2", .when(traits: ["BuildCondition2"])),
                .define("DEFINE3", .when(traits: ["BuildCondition3"])),
            ]
        )
    ]
)
