// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DependentPlugins",
    platforms: [ .macOS(.v13) ],
    dependencies: [
    ],
    targets: [
        .executableTarget(name: "MyExecutable"),
        .executableTarget(name: "MyExecutable2"),

        .plugin(
            name: "MyPlugin",
            capability: .buildTool(),
            dependencies: [
                "MyExecutable"
            ]
        ),

        .plugin(
            name: "MyPlugin2",
            capability: .buildTool(),
            dependencies: [
                "MyExecutable2"
            ]
        ),

        .executableTarget(
            name: "MyClient",
            plugins: [
                "MyPlugin",
                "MyPlugin2",
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
