// swift-tools-version:5.7

import PackageDescription

let package = Package(
    name: "package-info",
    platforms: [
        .macOS(.v13),
        .iOS(.v13)
    ],
    dependencies: [
        // This just points to the SwiftPM at the root of this repository.
        .package(name: "swift-package-manager", path: "../../"),
        // You will want to depend on a stable semantic version instead:
        // .package(url: "https://github.com/swiftlang/swift-package-manager", .exact("0.4.0"))
    ],
    targets: [
        .executableTarget(
            name: "package-info",
            dependencies: [
                .product(name: "SwiftPM", package: "swift-package-manager")
            ]
        ),
    ]
)
