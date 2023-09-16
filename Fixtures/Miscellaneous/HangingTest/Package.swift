// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "HangingTest",
    products: [
        .library(
            name: "HangingTest",
            targets: ["HangingTest"]),
    ],
    targets: [
        .target(
            name: "HangingTest"),
        .testTarget(
            name: "HangingTestTests",
            dependencies: ["HangingTest"]),
    ]
)
