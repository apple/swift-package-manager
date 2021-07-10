// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "MyPackage2",
    products: [
        .library(name: "Library", targets: ["Library"])
    ],
    targets: [
        .target(name: "Library")
    ]
)
