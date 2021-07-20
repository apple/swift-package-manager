// swift-tools-version:5.1
import PackageDescription

let package = Package(
    name: "VerificationTestPackage",
    products: [
      .executable(name: "BExec", targets: ["B"]),
    ],
    dependencies: [

    ],
    targets: [
        .target(
            name: "A",
            dependencies: []),
        .target(
            name: "B",
            dependencies: []),
    ]
)
