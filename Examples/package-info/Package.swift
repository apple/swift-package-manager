// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "package-info",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    dependencies: [
        // This just points to the SwiftPM at the root of this repository.
        .package(name: "swift-package-manager", path: "../../"),
        // You will want to depend on a stable semantic version instead:
        // .package(url: "https://github.com/apple/swift-package-manager", branch: "swift-5.10-RELEASE")
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
