# Package

`class Package`

The configuration of a Swift package.

Pass configuration options as parameters to your package's initializer
statement to provide the name of the package, its targets, products,
dependencies, and other configuration options.

By convention, the properties of a `Package` are defined in a single nested
initializer statement, and not modified after initialization. The following package
manifest shows the initialization of a simple package object for the MyLibrary
Swift package:

```swift
// swift-tools-version:5.1
import PackageDescription

let package = Package(
    name: "MyLibrary",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "MyLibrary", targets: ["MyLibrary"]),
    ],
    dependencies: [
        .package(url: "https://url/of/another/package/named/Utility", from: "1.0.0"),
    ],
    targets: [
        .target(name: "MyLibrary", dependencies: ["Utility"]),
        .testTarget(name: "MyLibraryTests", dependencies: ["MyLibrary"]),
    ]
)
```

## Methods

<pre>
Package(
    name: String,
    defaultLocalization: [<a href="#languageTag">LanguageTag</a>]? = nil.
    platforms: [<a href="#supportedplatform">SupportedPlatform</a>]? = nil,
    products: [<a href="#product">Product</a>] = [],
    dependencies: [<a href="#package-dependency">Package.Dependency</a>] = [],
    targets: [<a href="#target">Target</a>] = [],
    swiftLanguageVersions: [<a href="#SwiftVersion">SwiftVersion</a>]? = nil,
    cLanguageStandard: <a href="#CLanguageStandard">CLanguageStandard</a>? = nil,
    cxxLanguageStandard: <a href="#CXXLanguageStandard">CXXLanguageStandard</a>? = nil
)
</pre>

### About the Swift Tools Version

A `Package.swift` manifest file must begin with the string
`// swift-tools-version:` followed by a version number specifier.
The following code listing shows a few examples of valid declarations
of the Swift tools version:

    // swift-tools-version:3.0.2
    // swift-tools-version:3.1
    // swift-tools-version:4.0
    // swift-tools-version:5.0
    // swift-tools-version:5.1
    // swift-tools-version:5.2
    // swift-tools-version:5.3

The Swift tools version declares the version of the `PackageDescription`
library, the minimum version of the Swift tools and Swift language
compatibility version to process the manifest, and the minimum version of the
Swift tools that are needed to use the Swift package. Each version of Swift
can introduce updates to the `PackageDescription` framework, but the previous
API version will continue to be available to packages which declare a prior
tools version. This behavior lets you take advantage of new releases of
Swift, the Swift tools, and the `PackageDescription` library, without having
to update your package's manifest or losing access to existing packages.

# SupportedPlatform

`struct SupportedPlatform`

A platform that the Swift package supports.

By default, the Swift Package Manager assigns a predefined minimum deployment
version for each supported platforms unless you configure supported platforms using the `platforms`
API. This predefined deployment version is the oldest deployment target
version that the installed SDK supports for a given platform. One exception
to this rule is macOS, for which the minimum deployment target version
starts from 10.10. Packages can choose to configure the minimum deployment
target version for a platform by using the APIs defined in this struct. The
Swift Package Manager emits appropriate errors when an invalid value is
provided for supported platforms, such as an empty array, multiple declarations
for the same platform, or an invalid version specification.

The Swift Package Manager will emit an error if a dependency is not
compatible with the top-level package's deployment version. The deployment
target of a package's dependencies must be lower than or equal to the top-level package's
deployment target version for a particular platform.

## Methods

```swift
/// Configure the minimum deployment target version for the macOS platform.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameter version: The minimum deployment target that the package supports.
static func macOS(_ version: SupportedPlatform.MacOSVersion) -> SupportedPlatform

/// Configure the minimum deployment target version for the macOS platform
/// using a version string.
///
/// The version string must be a series of two or three dot-separated integers, such as `10.10` or `10.10.1`.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameter versionString: The minimum deployment target as a string representation of two or three dot-separated integers, such as `10.10.1`.
static func macOS(_ versionString: String) -> SupportedPlatform

/// Configure the minimum deployment target version for the iOS platform.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameter version: The minimum deployment target that the package supports.
static func iOS(_ version: SupportedPlatform.IOSVersion) -> SupportedPlatform

/// Configure the minimum deployment target version for the iOS platform
/// using a custom version string.
///
/// The version string must be a series of two or three dot-separated integers, such as `8.0` or `8.0.1`.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameter versionString: The minimum deployment target as a string representation of two or three dot-separated integers, such as `8.0.1`.
static func iOS(_ versionString: String) -> SupportedPlatform

/// Configure the minimum deployment target version for the tvOS platform.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameter version: The minimum deployment target that the package supports.
static func tvOS(_ version: SupportedPlatform.TVOSVersion) -> SupportedPlatform

/// Configure the minimum deployment target version for the tvOS platform
/// using a custom version string.
///
/// The version string must be a series of two or three dot-separated integers,such as `9.0` or `9.0.1`.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameter versionString: The minimum deployment target as a string representation of two or three dot-separated integers, such as `9.0.1`.
static func tvOS(_ versionString: String) -> SupportedPlatform

/// Configure the minimum deployment target version for the watchOS platform.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameter version: The minimum deployment target that the package supports.
static func watchOS(_ version: SupportedPlatform.WatchOSVersion) -> SupportedPlatform

/// Configure the minimum deployment target version for the watchOS platform
/// using a custom version string.
///
/// The version string must be a series of two or three dot-separated integers, such as `2.0` or `2.0.1`.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameter versionString: The minimum deployment target as a string representation of two or three dot-separated integers, such as `2.0.1`.
static func watchOS(_ versionString: String) -> SupportedPlatform
```

# Product

`class Product`

The object that defines a package product.

A package product defines an externally visible build artifact that's
available to clients of a package. The product is assembled from the build
artifacts of one or more of the package's targets.

A package product can be one of two types:

1. **Library**. Use a library product to vend library targets. This makes a target's public APIs
available to clients that integrate the Swift package.
2. **Executable**. Use an executable product to vend an executable target.
Use this only if you want to make the executable available to clients.

The following example shows a package manifest for a library called "Paper"
that defines multiple products:

```swift
let package = Package(
    name: "Paper",
    products: [
        .executable(name: "tool", targets: ["tool"]),
        .library(name: "Paper", targets: ["Paper"]),
        .library(name: "PaperStatic", type: .static, targets: ["Paper"]),
        .library(name: "PaperDynamic", type: .dynamic, targets: ["Paper"]),
    ],
    dependencies: [
        .package(url: "http://example.com/ExamplePackage/ExamplePackage", from: "1.2.3"),
        .package(url: "http://some/other/lib", .exact("1.2.3")),
    ],
    targets: [
        .target(
            name: "tool",
            dependencies: [
                "Paper",
                "ExamplePackage"
            ]),
        .target(
            name: "Paper",
            dependencies: [
                "Basic",
                .target(name: "Utility"),
                .product(name: "AnotherExamplePackage"),
            ])
    ]
)
```

## Methods

```swift
/// Create a library product to allow clients that declare a dependency on this package
/// to use the package's functionality.
///
/// A library's product can either be statically or dynamically linked.
/// If possible, don't declare the type of library explicitly to let 
/// the Swift Package Manager choose between static or dynamic linking based
/// on the preference of the package's consumer.
///
/// - Parameters:
///     - name: The name of the library product.
///     - type: The optional type of the library that is used to determine how to link to the library.
///         Leave this parameter unspecified to let to let the Swift Package Manager choose between static or dynamic linking (recommended).
///         If you do not support both linkage types, use `.static` or `.dynamic` for this parameter. 
///     - targets: The targets that are bundled into a library product.
static func library(name: String, type: Product.Library.LibraryType? = nil, targets: [String]) -> Product

/// Create an executable package product that clients can run.
///
/// - Parameters:
///     - name: The name of the executable product.
///     - targets: The targets to bundle into an executable product.
static func executable(name: String, targets: [String]) -> Product
```

# Package Dependency

`class Package.Dependency`

A package dependency of a Swift package.

A package dependency consists of a Git URL to the source of the package,
and a requirement for the version of the package.

The Swift Package Manager performs a process called *dependency resolution* to
figure out the exact version of the package dependencies that an app or other
Swift package can use. The `Package.resolved` file records the results of the
dependency resolution and lives in the top-level directory of a Swift package.
If you add the Swift package as a package dependency to an app for an Apple platform,
you can find the `Package.resolved` file inside your `.xcodeproj` or `.xcworkspace`.

## Methods

```swift
/// Create a package dependency that uses the version requirement, starting with the given minimum version,
/// going up to the next major version.
///
/// This is the recommended way to specify a remote package dependency.
/// It allows you to specify the minimum version you require, allows updates that include bug fixes
/// and backward-compatible feature updates, but requires you to explicitly update to a new major version of the dependency.
/// This approach provides the maximum flexibility on which version to use,
/// while making sure you don't update to a version with breaking changes,
/// and helps to prevent conflicts in your dependency graph.
///
/// The following example allows the Swift Package Manager to select a version
/// like a  `1.2.3`, `1.2.4`, or `1.3.0`, but not `2.0.0`.
///
///    .package(url: "https://example.com/example-package.git", from: "1.2.3"),
///
/// - Parameters:
///     - name: The name of the package, or nil to deduce it from the URL.
///     - url: The valid Git URL of the package.
///     - version: The minimum version requirement.
static func package(url: String, from version: Version) -> Package.Dependency

/// Add a remote package dependency given a version requirement.
///
/// - Parameters:
///     - name: The name of the package, or nil to deduce it from the URL.
///     - url: The valid Git URL of the package.
///     - requirement: A dependency requirement. See static methods on `Package.Dependency.Requirement` for available options.
static func package(url: String, _ requirement: Package.Dependency.Requirement) -> Package.Dependency

/// Adds a remote package dependency given a branch requirement.
///
///    .package(url: "https://example.com/example-package.git", branch: "main"),
///
/// - Parameters:
///     - name: The name of the package, or nil to deduce it from the URL.
///     - url: The valid Git URL of the package.
///     - branch: A dependency requirement. See static methods on `Package.Dependency.Requirement` for available options.
static func package(name: String? = nil, url: String, branch: String) -> Package.Dependency

/// Adds a remote package dependency given a revision requirement.
///
///    .package(url: "https://example.com/example-package.git", revision: "aa681bd6c61e22df0fd808044a886fc4a7ed3a65"),
///
/// - Parameters:
///     - name: The name of the package, or nil to deduce it from the URL.
///     - url: The valid Git URL of the package.
///     - revision: A dependency requirement. See static methods on `Package.Dependency.Requirement` for available options.
static func package(name: String? = nil, url: String, revision: String) -> Package.Dependency

/// Add a package dependency starting with a specific minimum version, up to
/// but not including a specified maximum version.
///
/// The following example allows the Swift Package Manager to pick
/// versions `1.2.3`, `1.2.4`, `1.2.5`, but not `1.2.6`.
///
///     .package(url: "https://example.com/example-package.git", "1.2.3"..<"1.2.6"),
///
/// - Parameters:
///     - name: The name of the package, or nil to deduce it from the URL.
///     - url: The valid Git URL of the package.
///     - range: The custom version range requirement.
static func package(url: String, _ range: Range<Version>) -> Package.Dependency

/// Add a package dependency starting with a specific minimum version, going
/// up to and including a specific maximum version.
///
/// The following example allows the Swift Package Manager to pick
/// versions 1.2.3, 1.2.4, 1.2.5, as well as 1.2.6.
///
///     .package(url: "https://example.com/example-package.git", "1.2.3"..."1.2.6"),
///
/// - Parameters:
///     - name: The name of the package, or nil to deduce it from the URL.
///     - url: The valid Git URL of the package.
///     - range: The closed version range requirement.
static func package(url: String, _ range: ClosedRange<Version>) -> Package.Dependency

/// Add a dependency to a local package on the filesystem.
///
/// The Swift Package Manager uses the package dependency as-is
/// and does not perform any source control access. Local package dependencies
/// are especially useful during development of a new package or when working
/// on multiple tightly coupled packages.
///
/// - Parameter path: The path of the package.
static func package(path: String) -> Package.Dependency
```

# Package Dependency Requirement

`enum Package.Dependency.Requirement`

An enum that represents the requirement for a package dependency.

The dependency requirement can be defined as one of three different version requirements:

**A version-based requirement.**

Decide whether your project accepts updates to a package dependency up
to the next major version or up to the next minor version. To be more
restrictive, select a specific version range or an exact version.
Major versions tend to have more significant changes than minor
versions, and may require you to modify your code when they update.
The version rule requires Swift packages to conform to semantic
versioning. To learn more about the semantic versioning standard,
visit [semver.org](https://semver.org).

Selecting the version requirement is the recommended way to add a package dependency. It allows you to create a balance between restricting changes and obtaining improvements and features.

**A branch-based requirement**

Select the name of the branch for your package dependency to follow.
Use branch-based dependencies when you're developing multiple packages
in tandem or when you don't want to publish versions of your package dependencies.

Note that packages which use branch-based dependency requirements
can't be added as dependencies to packages that use version-based dependency
requirements; you should remove branch-based dependency requirements
before publishing a version of your package.

**A commit-based requirement**

Select the commit hash for your package dependency to follow.
Choosing this option isn't recommended, and should be limited to
exceptional cases. While pinning your package dependency to a specific
commit ensures that the package dependency doesn't change and your
code remains stable, you don't receive any updates at all. If you worry about
the stability of a remote package, consider one of the more
restrictive options of the version-based requirement.

Note that packages which use commit-based dependency requirements
can't be added as dependencies to packages that use version-based
dependency requirements; you should remove commit-based dependency
requirements before publishing a version of your package.

## Methods

```swift
/// Returns a requirement for the given exact version.
///
/// Specifying exact version requirements are not recommended as
/// they can cause conflicts in your dependency graph when multiple other packages depend on a package.
/// As Swift packages follow the semantic versioning convention,
/// think about specifying a version range instead.
///
/// The following example defines a version requirement that requires version 1.2.3 of a package.
///
///   .exact("1.2.3")
///
/// - Parameters:
///      - version: The exact version of the dependency for this requirement.
static func exact(_ version: Version) -> Package.Dependency.Requirement

/// Returns a requirement for a source control revision such as the hash of a commit.
///
/// Note that packages that use commit-based dependency requirements
/// can't be depended upon by packages that use version-based dependency
/// requirements; you should remove commit-based dependency requirements
/// before publishing a version of your package.
///
/// The following example defines a version requirement for a specific commit hash.
///
///   .revision("e74b07278b926c9ec6f9643455ea00d1ce04a021")
///
/// - Parameters:
///     - ref: The Git revision, usually a commit hash.
static func revision(_ ref: String) -> Package.Dependency.Requirement

/// Returns a requirement for a source control branch.
///
/// Note that packages that use branch-based dependency requirements
/// can't be depended upon by packages that use version-based dependency
/// requirements; you should remove branch-based dependency requirements
/// before publishing a version of your package.
///
/// The following example defines a version requirement that accepts any
/// change in the develop branch.
///
///    .branch("develop")
///
/// - Parameters:
///     - name: The name of the branch.
static func branch(_ name: String) -> Package.Dependency.Requirement

/// Returns a requirement for a version range, starting at the given minimum
/// version and going up to the next major version. This is the recommended version requirement.
///
/// - Parameters:
///     - version: The minimum version for the version range.
static func upToNextMajor(from version: Version) -> Package.Dependency.Requirement

/// Returns a requirement for a version range, starting at the given minimum
/// version and going up to the next minor version.
///
/// - Parameters:
///     - version: The minimum version for the version range.
static func upToNextMinor(from version: Version) -> Package.Dependency.Requirement
```

# Version

`struct Version`

A version according to the semantic versioning specification.

A package version is a three period-separated integer, for example `1.0.0`. It must conform to the semantic versioning standard in order to ensure
that your package behaves in a predictable manner once developers update their
package dependency to a newer version. To achieve predictability, the semantic versioning specification proposes a set of rules and
requirements that dictate how version numbers are assigned and incremented. To learn more about the semantic versioning specification, visit
[semver.org](https://semver.org).

**The Major Version**

The first digit of a version, or  *major version*, signifies breaking changes to the API that require
updates to existing clients. For example, the semantic versioning specification
considers renaming an existing type, removing a method, or changing a method's signature
breaking changes. This also includes any backward-incompatible bug fixes or
behavioral changes of the existing API.

**The Minor Version**

Update the second digit of a version, or *minor version*, if you add functionality in a backward-compatible manner.
For example, the semantic versioning specification considers adding a new method
or type without changing any other API to be backward-compatible.

**The Patch Version**

Increase the third digit of a version, or *patch version*, if you are making a backward-compatible bug fix.
This allows clients to benefit from bugfixes to your package without incurring
any maintenance burden.

# Target

`class Target`

A target, the basic building block of a Swift package.

Each target contains a set of source files that are compiled into a module or test suite.
You can vend targets to other packages by defining products that include the targets.

A target may depend on other targets within the same package and on products vended by the package's dependencies.

## Methods

```swift
/// Creates a regular target.
///
/// A target can contain either Swift or C-family source files, but not both. It contains code that is built as
/// a regular module that can be included in a library or executable product, but that cannot itself be used as
/// the main target of an executable product.
///
/// - Parameters:
///   - name: The name of the target.
///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
///       for example, `[PackageRoot]/Sources/[TargetName]`.
///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
///   - exclude: A list of paths to files or directories that the Swift Package Manager shouldn't consider to be source or resource files.
///       A path is relative to the target's directory.
///       This parameter has precedence over the `sources` parameter.
///   - sources: An explicit list of source files. If you provide a path to a directory,
///       the Swift Package Manager searches for valid source files recursively.
///   - resources: An explicit list of resources files.
///   - publicHeadersPath: The directory containing public headers of a C-family library target.
///   - cSettings: The C settings for this target.
///   - cxxSettings: The C++ settings for this target.
///   - swiftSettings: The Swift settings for this target.
///   - linkerSettings: The linker settings for this target.
static func target(
    name: String,
    dependencies: [Target.Dependency] = [],
    path: String? = nil,
    exclude: [String] = [],
    sources: [String]? = nil,
    resources: [Resource]? = nil,
    publicHeadersPath: String? = nil,
    cSettings: [CSetting]? = nil,
    cxxSettings: [CXXSetting]? = nil,
    swiftSettings: [SwiftSetting]? = nil,
    linkerSettings: [LinkerSetting]? = nil
) -> Target

/// Creates an executable target.
///
/// An executable target can contain either Swift or C-family source files, but not both. It contains code that
/// is built as an executable module that can be used as the main target of an executable product. The target
/// is expected to either have a source file named `main.swift`, `main.m`, `main.c`, or `main.cpp`, or a source
/// file that contains the `@main` keyword.
///
/// - Parameters:
///   - name: The name of the target.
///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
///       for example, `[PackageRoot]/Sources/[TargetName]`.
///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
///   - exclude: A list of paths to files or directories that the Swift Package Manager shouldn't consider to be source or resource files.
///       A path is relative to the target's directory.
///       This parameter has precedence over the `sources` parameter.
///   - sources: An explicit list of source files. If you provide a path to a directory,
///       the Swift Package Manager searches for valid source files recursively.
///   - resources: An explicit list of resources files.
///   - publicHeadersPath: The directory containing public headers of a C-family library target.
///   - cSettings: The C settings for this target.
///   - cxxSettings: The C++ settings for this target.
///   - swiftSettings: The Swift settings for this target.
///   - linkerSettings: The linker settings for this target.
static func executableTarget(
    name: String,
    dependencies: [Target.Dependency] = [],
    path: String? = nil,
    exclude: [String] = [],
    sources: [String]? = nil,
    resources: [Resource]? = nil,
    publicHeadersPath: String? = nil,
    cSettings: [CSetting]? = nil,
    cxxSettings: [CXXSetting]? = nil,
    swiftSettings: [SwiftSetting]? = nil,
    linkerSettings: [LinkerSetting]? = nil
) -> Target

/// Creates a test target.
///
/// Write test targets using the XCTest testing framework.
/// Test targets generally declare a dependency on the targets they test.
///
/// - Parameters:
///   - name: The name of the target.
///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
///       for example, `[PackageRoot]/Sources/[TargetName]`.
///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
///   - exclude: A list of paths to files or directories that the Swift Package Manager shouldn't consider to be source or resource files.
///       A path is relative to the target's directory.
///       This parameter has precedence over the `sources` parameter.
///   - sources: An explicit list of source files. If you provide a path to a directory,
///       the Swift Package Manager searches for valid source files recursively.
///   - resources: An explicit list of resources files.
///   - cSettings: The C settings for this target.
///   - cxxSettings: The C++ settings for this target.
///   - swiftSettings: The Swift settings for this target.
///   - linkerSettings: The linker settings for this target.
static func testTarget(
    name: String,
    dependencies: [Target.Dependency] = [],
    path: String? = nil,
    exclude: [String] = [],
    sources: [String]? = nil,
    resources: [Resource]? = nil,
    cSettings: [CSetting]? = nil,
    cxxSettings: [CXXSetting]? = nil,
    swiftSettings: [SwiftSetting]? = nil,
    linkerSettings: [LinkerSetting]? = nil
) -> Target

/// Creates a system library target.
///
/// Use system library targets to adapt a library installed on the system to work with Swift packages.
/// Such libraries are generally installed by system package managers (such as Homebrew, MacPorts and apt-get)
/// and exposed to Swift packages by providing a `modulemap` file along with other metadata such as the library's `pkgConfig` name.
///
/// - Parameters:
///   - name: The name of the target.
///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
///       for example, `[PackageRoot]/Sources/[TargetName]`.
///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
///   - pkgConfig: The name of the `pkg-config` file for this system library.
///   - providers: The providers for this system library.
static func systemLibrary(
    name: String,
    path: String? = nil,
    pkgConfig: String? = nil,
    providers: [SystemPackageProvider]? = nil
) -> Target

/// Creates a binary target that references a remote artifact.
///
/// A binary target provides the url to a pre-built binary artifact for the target. Currently only supports
/// artifacts for Apple platforms.
///
/// - Parameters:
///   - name: The name of the target.
///   - url: The URL to the binary artifact. This URL must point to an archive file
///       that contains a binary artifact in its root directory.
///   - checksum: The checksum of the archive file that contains the binary artifact.
///
/// Binary targets are only available on Apple platforms.
static func binaryTarget(
    name: String,
    url: String,
    checksum: String
) -> Target

/// Creates a binary target that references an artifact on disk.
///
/// A binary target provides the path to a pre-built binary artifact for the target.
/// The Swift Package Manager only supports binary targets for Apple platforms.
///
/// - Parameters:
///   - name: The name of the target.
///   - path: The path to the binary artifact. This path can point directly to a binary artifact
///       or to an archive file that contains the binary artifact at its root.
///
/// Binary targets are only available on Apple platforms.
static func binaryTarget(
    name: String,
    path: String
) -> Target

```

# Target Dependency

`class Target.Dependency`

The different types of a target's dependency on another entity.

## Methods

```swift
/// Creates a dependency on a target in the same package.
///
/// - parameters:
///   - name: The name of the target.
///   - condition: A condition that limits the application of the target dependency. For example, only apply a
///       dependency for a specific platform.
static func target(
    name: String,
    condition: TargetDependencyCondition? = nil
) -> Target.Dependency

/// Creates a target dependency on a product from a package dependency.
///
/// - parameters:
///   - name: The name of the product.
///   - package: The name of the package.
///   - condition: A condition that limits the application of the target dependency. For example, only apply a
///       dependency for a specific platform.
static func product(
    name: String,
    package: String,
    condition: TargetDependencyCondition? = nil
) -> Target.Dependency

/// Creates a by-name dependency that resolves to either a target or a product but after the Swift Package Manager
/// has loaded the package graph.
///
/// - parameters:
///   - name: The name of the dependency, either a target or a product.
///   - condition: A condition that limits the application of the target dependency. For example, only apply a
///       dependency for a specific platform.
static func byName(
    name: String
    condition: TargetDependencyCondition? = nil
) -> Target.Dependency
```

# Target Dependency Condition

`class TargetDependencyCondition`

A condition that limits the application of a target's dependency.

## Methods

```swift
/// Creates a target dependency condition.
///
/// - Parameters:
///   - platforms: The applicable platforms for this target dependency condition.
static func when(platforms: [Platform]? = nil) -> TargetDependencyCondition
```

# Resource

`struct Resource`

A resource to bundle with the Swift package.

If a Swift package declares a Swift tools version of 5.3 or later, it can include resource files.

Similar to source code, the Swift Package Manager scopes resources to a target, so you must put them
into the folder that corresponds to the target they belong to.
For example, any resources for the `MyLibrary` target must reside in `Sources/MyLibrary`.

Use subdirectories to organize your resource files in a way that simplifies file identification and management.
For example, put all resource files into a directory named `Resources`,
so they reside at `Sources/MyLibrary/Resources`.

By default, the Swift Package Manager handles common resources types for Apple platforms automatically.
For example, you don’t need to declare XIB files, storyboards, Core Data file types, and asset catalogs
as resources in your package manifest.

However, you must explicitly declare other file types—for example image files—as resources
using the `process(_:localization:)` or `copy(_:)` rules.

Alternatively, exclude resource files from a target
by passing them to the target initializer’s `exclude` parameter.

## Methods

```swift
/// Applies a platform-specific rule to the resource at the given path.
///
/// Use the `process` rule to process resources at the given path
/// according to the platform it builds the target for. For example, the
/// Swift Package Manager may optimize image files for platforms that
/// support such optimizations. If no optimization is available for a file
/// type, the Swift Package Manager copies the file.
///
/// If the given path represents a directory, the Swift Package Manager
/// applies the process rule recursively to each file in the directory.
///
/// If possible use this rule instead of `copy(_:)`.
///
/// - Parameters:
///     - path: The path for a resource.
///     - localization: The explicit localization type for the resource.
static func process(
    _ path: String,
    localization: Localization? = nil
) -> Resource

/// Applies the copy rule to a resource at the given path.
///
/// If possible, use `process(_:localization:)`` and automatically apply optimizations
/// to resources.
///
/// If your resources must remain untouched or must retain a specific folder structure,
/// use the `copy` rule. It copies resources at the given path, as is, to the top level
/// in the package’s resource bundle. If the given path represents a directory, Xcode preserves its structure.
///
/// - Parameters:
///     - path: The path for a resource.
static func copy(
    _ path: String
) -> Resource
```

# Localization

`struct Resource.Localization`

Defines the explicit type of localization for resources.

## Cases

```swift
/// A constant that represents default internationalization.
case `default`

/// A constant that represents base internationalization.
case base
```

# LanguageTag

`struct LanguageTag`

A wrapper around an IETF language tag.

To learn more about the IETF worldwide standard for language tags,
see [RFC5646](https://tools.ietf.org/html/rfc5646).

## Methods

```swift
/// Creates a language tag from its IETF string representation.
init(_ tag: String)
```

# CSetting

`struct CSetting`

A C-language build setting.

## Methods

```swift
/// Provides a header search path relative to the target's directory.
///
/// Use this setting to add a search path for headers within your target.
/// You can't use absolute paths and you can't use this setting to provide
/// headers that are visible to other targets.
///
/// The path must be a directory inside the package.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameters:
///   - path: The path of the directory that contains the  headers. The path is relative to the target's directory.
///   - condition: A condition that restricts the application of the build setting.
static func headerSearchPath(_ path: String, _ condition: BuildSettingCondition? = nil) -> CSetting

/// Defines a value for a macro.
///
/// If you don't specify a value, the macro's default value is 1.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameters:
///   - name: The name of the macro.
///   - value: The value of the macro.
///   - condition: A condition that restricts the application of the build setting.
static func define(_ name: String, to value: String? = nil, _ condition: BuildSettingCondition? = nil) -> CSetting

/// Sets unsafe flags to pass arbitrary command-line flags to the corresponding build tool.
///
/// As the usage of the word "unsafe" implies, the Swift Package Manager
/// can't safely determine if the build flags have any negative
/// side effect on the build since certain flags can change the behavior of
/// how it performs a build.
///
/// As some build flags can be exploited for unsupported or malicious
/// behavior, the use of unsafe flags make the products containing this
/// target ineligible for use by other packages.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameters:
///   - flags: The unsafe flags to set.
///   - condition: A condition that restricts the application of the build setting.
static func unsafeFlags(_ flags: [String], _ condition: BuildSettingCondition? = nil) -> CSetting
```

# CXXSetting

`struct CXXSetting`

A CXX-language build setting.

## Methods

```swift
/// Provides a header search path relative to the target's directory.
///
/// Use this setting to add a search path for headers within your target.
/// You can't use absolute paths and you can't use this setting to provide
/// headers that are visible to other targets.
///
/// The path must be a directory inside the package.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameters:
///   - path: The path of the directory that contains the  headers. The path is relative to the target's directory.
///   - condition: A condition that restricts the application of the build setting.
static func headerSearchPath(_ path: String, _ condition: BuildSettingCondition? = nil) -> CXXSetting

/// Defines a value for a macro.
///
/// If you don't specify a value, the macro's default value is 1.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameters:
///   - name: The name of the macro.
///   - value: The value of the macro.
///   - condition: A condition that restricts the application of the build setting.
static func define(_ name: String, to value: String? = nil, _ condition: BuildSettingCondition? = nil) -> CXXSetting

/// Sets unsafe flags to pass arbitrary command-line flags to the corresponding build tool.
///
/// As the usage of the word "unsafe" implies, the Swift Package Manager
/// can't safely determine if the build flags have any negative
/// side effect on the build since certain flags can change the behavior of
/// how a build is performed.
///
/// As some build flags can be exploited for unsupported or malicious
/// behavior, a product can't be used as a dependency in another package if one of its targets uses unsafe flags.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameters:
///   - flags: The unsafe flags to set.
///   - condition: A condition that restricts the application of the build setting.
static func unsafeFlags(_ flags: [String], _ condition: BuildSettingCondition? = nil) -> CXXSetting
```

# SwiftSetting

`struct SwiftSetting`

A Swift language build setting.

## Methods

```swift
/// Defines a compilation condition.
///
/// Use compilation conditions to only compile statements if a certain condition is true.
/// For example, the Swift compiler will only compile the
/// statements inside the `#if` block when `ENABLE_SOMETHING` is defined:
///
///     #if ENABLE_SOMETHING
///        ...
///     #endif
///
/// Unlike macros in C/C++, compilation conditions don't have an
/// associated value.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameters:
///   - name: The name of the macro.
///   - condition: A condition that restricts the application of the build setting.
static func define(_ name: String, _ condition: BuildSettingCondition? = nil) -> SwiftSetting

/// Sets unsafe flags to pass arbitrary command-line flags to the corresponding build tool.
///
/// As the usage of the word "unsafe" implies, the Swift Package Manager
/// can't safely determine if the build flags have any negative
/// side effect on the build since certain flags can change the behavior of
/// how a build is performed.
///
/// As some build flags can be exploited for unsupported or malicious
/// behavior, a product can't be used as a dependency in another package if one of its targets uses unsafe flags.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameters:
///   - flags: The unsafe flags to set.
///   - condition: A condition that restricts the application of the build setting..
static func unsafeFlags(_ flags: [String], _ condition: BuildSettingCondition? = nil) -> SwiftSetting
```

# LinkerSetting

`struct LinkerSetting`

A linker build setting.

## Methods

```swift
/// Declares linkage to a system library.
///
/// This setting is most useful when the library can't be linked
/// automatically, such as C++ based libraries and non-modular
/// libraries.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameters:
///   - library: The library name.
///   - condition: A condition that restricts the application of the build setting.
static func linkedLibrary(_ library: String, _ condition: BuildSettingCondition? = nil) -> LinkerSetting

/// Declares linkage to a system framework.
///
/// This setting is most useful when the framework can't be linked
/// automatically, such as C++ based frameworks and non-modular
/// frameworks.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameters:
///   - framework: The framework name.
///   - condition: A condition that restricts the application of the build setting.
static func linkedFramework(_ framework: String, _ condition: BuildSettingCondition? = nil) -> LinkerSetting

/// Sets unsafe flags to pass arbitrary command-line flags to the corresponding build tool.
///
/// As the usage of the word "unsafe" implies, the Swift Package Manager
/// can't safely determine if the build flags have any negative
/// side effect on the build since certain flags can change the behavior of
/// how a build is performed.
///
/// As some build flags can be exploited for unsupported or malicious
/// behavior, a product can't be used as a dependency in another package if one of its targets uses unsafe flags.
///
/// - Since: First available in PackageDescription 5.0
///
/// - Parameters:
///   - flags: The unsafe flags to set.
///   - condition: A condition that restricts the application of the build setting.
static func unsafeFlags(_ flags: [String], _ condition: BuildSettingCondition? = nil) -> LinkerSetting
```

# SwiftVersion

`enum SwiftVersion`

The version of the Swift language to use for compiling Swift sources in the package.

```swift
enum SwiftVersion {
    case v3
    case v4
    case v4_2
    case v5

    /// A user-defined value for the Swift version.
    ///
    /// The value is passed as-is to the Swift compiler's `-swift-version` flag.
    case version(String)
}
```

# CLanguageStandard

`enum CLanguageStandard`

The supported C language standard to use for compiling C sources in the package.

```swift
enum CLanguageStandard {
    case c89
    case c90
    case c99
    case c11
    case c17
    case c18
    case c2x
    case gnu89
    case gnu90
    case gnu99
    case gnu11
    case gnu17
    case gnu18
    case gnu2x
    case iso9899_1990 = "iso9899:1990"
    case iso9899_199409 = "iso9899:199409"
    case iso9899_1999 = "iso9899:1999"
    case iso9899_2011 = "iso9899:2011"
    case iso9899_2017 = "iso9899:2017"
    case iso9899_2018 = "iso9899:2018"
}
```

# CXXLanguageStandard

`enum CXXLanguageStandard`

The supported C++ language standard to use for compiling C++ sources in the package.

```swift
enum CXXLanguageStandard {
    case cxx98 = "c++98"
    case cxx03 = "c++03"
    case cxx11 = "c++11"
    case cxx14 = "c++14"
    case cxx17 = "c++17"
    case cxx1z = "c++1z"
    case cxx20 = "c++20"
    case cxx2b = "c++2b"
    case gnucxx98 = "gnu++98"
    case gnucxx03 = "gnu++03"
    case gnucxx11 = "gnu++11"
    case gnucxx14 = "gnu++14"
    case gnucxx17 = "gnu++17"
    case gnucxx1z = "gnu++1z"
    case gnucxx20 = "gnu++20"
    case gnucxx2b = "gnu++2b"
}
```
