# ``PackageDescription``

Create reusable code, organize it in a lightweight way, and share it across your projects and with other developers.

Swift packages are reusable components of Swift, Objective-C, Objective-C++, C, or C++ code that developers can use in their projects. They bundle source files, binaries, and resources in a way that’s easy to use in your app’s project. 

Each Swift package requires a `Package.swift` file in the main directory of the package — referred to as the package manifest. When you create a Swift package, you use the PackageDescription library in the package manifest to list dependencies, configure localized resources, and set other configuration options.

For example, the package manifest from the [SlothCreator: Building DocC Documentation in Xcode](https://developer.apple.com/documentation/xcode/slothcreator_building_docc_documentation_in_xcode) sample project below defines the SlothCreator package, with the SlothCreator library in it. It specifies the deployment targets, and that its resources are in the `Resources` folder.

```swift
import PackageDescription

let package = Package(
    name: "SlothCreator",
    platforms: [
        .macOS(.v11),
        .iOS(.v14),
        .watchOS(.v7),
        .tvOS(.v13)
    ],
    products: [
        .library(
            name: "SlothCreator",
            targets: ["SlothCreator"]
        )
    ],
    targets: [
        .target(
            name: "SlothCreator",
            resources: [
                .process("Resources/")
            ]
        )
    ]
)
```

The package manifest also allows you to define executable products, as well as plugins that Swift Package Manager can use to build other products in the manifest.

For more information about adding a package dependency to your app project and creating Swift packages with Xcode, see [Adding Package Dependencies to Your App](https://developer.apple.com/documentation/xcode/adding-package-dependencies-to-your-app), [Creating a Standalone Swift Package with Xcode](https://developer.apple.com/documentation/xcode/creating-a-standalone-swift-package-with-xcode), and [Swift Packages](https://developer.apple.com/documentation/xcode/swift-packages).

Support for Swift packages in Xcode builds on the open-source Swift Package Manager project. To learn more about the Swift Package Manager, visit [Swift.org](https://www.swift.org/package-manager/) and the Swift Package Manager repository on [GitHub](https://github.com/swiftlang/swift-package-manager).

## Topics

### Creating a Package

- ``Package``
- ``Context``
