// swift-tools-version:5.1

/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import PackageDescription
import class Foundation.ProcessInfo


/** SwiftPMDataModel is the subset of SwiftPM product that includes just its data model.
This allowis some clients (such as IDEs) that use SwiftPM's data model but not its build system
to not have to depend on SwiftDriver, SwiftLLBuild, etc. We should probably have better names here,
though that could break some clients.
*/
let swiftPMDataModelProduct = (
    name: "SwiftPMDataModel",
    targets: [
        "SourceControl",
        "PackageCollections",
        "PackageCollectionsModel",
        "PackageModel",
        "PackageLoading",
        "PackageGraph",
        "Xcodeproj",
        "Workspace",
    ]
)

/** The `libSwiftPM` set of interfaces to programatically work with Swift
 packages.  `libSwiftPM` includes all of the SwiftPM code except the
 command line tools, while `libSwiftPMDataModel` includes only the data model.

 NOTE: This API is *unstable* and may change at any time.
*/
let swiftPMProduct = (
    name: "SwiftPM",
    targets: swiftPMDataModelProduct.targets + [
        "SPMLLBuild",
        "LLBuildManifest",
        "Build",
    ]
)

/** An array of products which have two versions listed: one dynamically linked, the other with the
automatic linking type with `-auto` suffix appended to product's name.
*/
let autoProducts = [swiftPMProduct, swiftPMDataModelProduct]

let package = Package(
    name: "SwiftPM",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13)
    ],
    products:
        autoProducts.flatMap {
          [
            .library(
                name: $0.name,
                type: .dynamic,
                targets: $0.targets
            ),
            .library(
                name: "\($0.name)-auto",
                targets: $0.targets
            )
          ]
        } + [
        .library(
            name: "XCBuildSupport",
            targets: ["XCBuildSupport"]
        ),
        .library(
            name: "PackageDescription",
            type: .dynamic,
            targets: ["PackageDescription"]
        ),
        .library(
            name: "PackagePlugin",
            type: .dynamic,
            targets: ["PackagePlugin"]
        ),
        .library(
            name: "PackageCollectionsModel",
            targets: ["PackageCollectionsModel"]
        ),
        .library(
            name: "SwiftPMPackageCollections",
            targets: [
                "PackageCollections",
                "PackageCollectionsModel",
                "PackageCollectionsSigning",
                "PackageModel",
            ]
        ),
    ],
    targets: [
        // The `PackageDescription` target provides the API that is available
        // to `Package.swift` manifests. Here we build a debug version of the
        // library; the bootstrap scripts build the deployable version.
        .target(
            name: "PackageDescription",
            swiftSettings: [
                .unsafeFlags(["-package-description-version", "999.0"]),
                .unsafeFlags(["-enable-library-evolution"], .when(platforms: [.macOS]))
            ]),

        // The `PackagePlugin` target provides the API that is available to
        // plugin scripts. Here we build a debug version of the library; the
        // bootstrap scripts build the deployable version.
        .target(
            name: "PackagePlugin",
            swiftSettings: [
                .unsafeFlags(["-package-description-version", "999.0"]),
                .unsafeFlags(["-enable-library-evolution"], .when(platforms: [.macOS]))
            ]),

        // MARK: SwiftPM specific support libraries

        .target(
            name: "Basics",
            dependencies: ["SwiftToolsSupport-auto"]),

        .target(
            /** The llbuild manifest model */
            name: "LLBuildManifest",
            dependencies: ["SwiftToolsSupport-auto", "Basics"]),

        .target(
            /** Source control operations */
            name: "SourceControl",
            dependencies: ["SwiftToolsSupport-auto", "Basics"]),
        .target(
            /** Shim for llbuild library */
            name: "SPMLLBuild",
            dependencies: ["SwiftToolsSupport-auto", "Basics"]),

        // MARK: Project Model

        .target(
            /** Primitive Package model objects */
            name: "PackageModel",
            dependencies: ["SwiftToolsSupport-auto", "Basics"]),
        .target(
            /** Package model conventions and loading support */
            name: "PackageLoading",
            dependencies: ["SwiftToolsSupport-auto", "Basics", "PackageModel", "SourceControl"]),

        // MARK: Package Dependency Resolution

        .target(
            /** Data structures and support for complete package graphs */
            name: "PackageGraph",
            dependencies: ["SwiftToolsSupport-auto", "Basics", "PackageLoading", "PackageModel", "SourceControl"]),

        // MARK: Package Collections

        .target(
            /** Package collections models */
            name: "PackageCollectionsModel",
            dependencies: []),

        .target(
            /** Package collections signing C lib */
            name: "PackageCollectionsSigningLibc",
            dependencies: ["Crypto"],
            cSettings: [
                .define("WIN32_LEAN_AND_MEAN"),
            ]),
        .target(
             /** Package collections signing */
             name: "PackageCollectionsSigning",
             dependencies: ["PackageCollectionsModel", "PackageCollectionsSigningLibc", "Crypto", "Basics"]),

        .target(
            /** Data structures and support for package collections */
            name: "PackageCollections",
            dependencies: ["SwiftToolsSupport-auto", "Basics", "PackageModel", "SourceControl", "PackageCollectionsModel", "PackageCollectionsSigning"]),

        // MARK: Package Manager Functionality

        .target(
            /** Builds Modules and Products */
            name: "SPMBuildCore",
            dependencies: ["SwiftToolsSupport-auto", "Basics", "PackageGraph"]),
        .target(
            /** Builds Modules and Products */
            name: "Build",
            dependencies: ["SwiftToolsSupport-auto", "Basics", "SPMBuildCore", "PackageGraph", "LLBuildManifest", "SwiftDriver", "SPMLLBuild"]),
        .target(
            /** Support for building using Xcode's build system */
            name: "XCBuildSupport",
            dependencies: ["SPMBuildCore", "PackageGraph"]),

        .target(
            /** Generates Xcode projects */
            name: "Xcodeproj",
            dependencies: ["SwiftToolsSupport-auto", "Basics", "PackageGraph"]),
        .target(
            /** High level functionality */
            name: "Workspace",
            dependencies: ["SwiftToolsSupport-auto", "Basics", "SPMBuildCore", "PackageGraph", "PackageModel", "SourceControl", "Xcodeproj"]),

        // MARK: Commands

        .target(
            /** High-level commands */
            name: "Commands",
            dependencies: ["SwiftToolsSupport-auto", "Basics", "Build", "PackageGraph", "SourceControl", "Xcodeproj", "Workspace", "XCBuildSupport", "ArgumentParser", "PackageCollections"]),
        .target(
            /** The main executable provided by SwiftPM */
            name: "swift-package",
            dependencies: ["Commands", "SwiftToolsSupport-auto"]),
        .target(
            /** Builds packages */
            name: "swift-build",
            dependencies: ["Commands"]),
        .target(
            /** Runs package tests */
            name: "swift-test",
            dependencies: ["Commands"]),
        .target(
            /** Runs an executable product */
            name: "swift-run",
            dependencies: ["Commands"]),
        .target(
            /** Interacts with package collections */
            name: "swift-package-collection",
            dependencies: ["Commands"]),
        .target(
            /** Shim tool to find test names on OS X */
            name: "swiftpm-xctest-helper",
            dependencies: [],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../lib/swift/macosx"], .when(platforms: [.macOS])),
            ]),

        // MARK: Additional Test Dependencies

        .target(
            /** SwiftPM test support library */
            name: "SPMTestSupport",
            dependencies: ["SwiftToolsSupport-auto", "Basics", "TSCTestSupport", "PackageGraph", "PackageLoading", "SourceControl", "Workspace", "Xcodeproj", "XCBuildSupport"]),

        // MARK: SwiftPM tests

        .testTarget(
            name: "BasicsTests",
            dependencies: ["Basics", "SPMTestSupport"]),
        .testTarget(
            name: "BuildTests",
            dependencies: ["Build", "SPMTestSupport"]),
        .testTarget(
            name: "CommandsTests",
            dependencies: ["swift-build", "swift-package", "swift-test", "swift-run", "Commands", "Workspace", "SPMTestSupport", "Build", "SourceControl"]),
        .testTarget(
            name: "WorkspaceTests",
            dependencies: ["Workspace", "SPMTestSupport"]),
        .testTarget(
            name: "FunctionalTests",
            dependencies: ["swift-build", "swift-package", "swift-test", "PackageModel", "SPMTestSupport"]),
        .testTarget(
            name: "FunctionalPerformanceTests",
            dependencies: ["swift-build", "swift-package", "swift-test", "SPMTestSupport"]),
        .testTarget(
            name: "PackageDescriptionTests",
            dependencies: ["PackageDescription"]),
        .testTarget(
            name: "SPMBuildCoreTests",
            dependencies: ["SPMBuildCore", "SPMTestSupport"]),
        .testTarget(
            name: "PackageLoadingTests",
            dependencies: ["PackageLoading", "SPMTestSupport"],
            exclude: ["Inputs"]),
        .testTarget(
            name: "PackageLoadingPerformanceTests",
            dependencies: ["PackageLoading", "SPMTestSupport"]),
        .testTarget(
            name: "PackageModelTests",
            dependencies: ["PackageModel", "SPMTestSupport"]),
        .testTarget(
            name: "PackageGraphTests",
            dependencies: ["PackageGraph", "SPMTestSupport"]),
        .testTarget(
            name: "PackageGraphPerformanceTests",
            dependencies: ["PackageGraph", "SPMTestSupport"]),
        .testTarget(
            name: "PackageCollectionsModelTests",
            dependencies: ["PackageCollectionsModel"]),
        .testTarget(
            name: "PackageCollectionsSigningTests",
            dependencies: ["PackageCollectionsSigning", "SPMTestSupport"]),
        .testTarget(
            name: "PackageCollectionsTests",
            dependencies: ["PackageCollections", "SPMTestSupport"]),
        .testTarget(
            name: "SourceControlTests",
            dependencies: ["SourceControl", "SPMTestSupport"]),
        .testTarget(
            name: "XcodeprojTests",
            dependencies: ["Xcodeproj", "SPMTestSupport"]),
        .testTarget(
            name: "XCBuildSupportTests",
            dependencies: ["XCBuildSupport", "SPMTestSupport"]),

        // Examples (These are built to ensure they stay up to date with the API.)
        .target(
            name: "package-info",
            dependencies: ["PackageModel", "PackageLoading", "PackageGraph", "Workspace"],
            path: "Examples/package-info/Sources/package-info"
        )
    ],
    swiftLanguageVersions: [.v5]
)

// Add package dependency on llbuild when not bootstrapping.
//
// When bootstrapping SwiftPM, we can't use llbuild as a package dependency it
// will provided by whatever build system (SwiftCI, bootstrap script) is driving
// the build process. So, we only add these dependencies if SwiftPM is being
// built directly using SwiftPM. It is a bit unfortunate that we've add the
// package dependency like this but there is no other good way of expressing
// this right now.

/// When not using local dependencies, the branch to use for llbuild and TSC repositories.
let relatedDependenciesBranch = "main"

if ProcessInfo.processInfo.environment["SWIFTPM_LLBUILD_FWK"] == nil {
    if ProcessInfo.processInfo.environment["SWIFTCI_USE_LOCAL_DEPS"] == nil {
        package.dependencies += [
            .package(url: "https://github.com/apple/swift-llbuild.git", .branch(relatedDependenciesBranch)),
        ]
    } else {
        // In Swift CI, use a local path to llbuild to interoperate with tools
        // like `update-checkout`, which control the sources externally.
        package.dependencies += [
            .package(path: "../llbuild"),
        ]
    }
    package.targets.first(where: { $0.name == "SPMLLBuild" })!.dependencies += ["llbuildSwift"]
}

if ProcessInfo.processInfo.environment["SWIFTCI_USE_LOCAL_DEPS"] == nil {
    package.dependencies += [
        .package(url: "https://github.com/apple/swift-tools-support-core.git", .branch(relatedDependenciesBranch)),
        // The 'swift-argument-parser' version declared here must match that
        // used by 'swift-driver' and 'sourcekit-lsp'. Please coordinate
        // dependency version changes here with those projects.
        .package(url: "https://github.com/apple/swift-argument-parser.git", .upToNextMinor(from: "0.4.3")),
        .package(url: "https://github.com/apple/swift-driver.git", .branch(relatedDependenciesBranch)),
        .package(url: "https://github.com/apple/swift-crypto.git", .upToNextMinor(from: "1.1.4")),
    ]
} else {
    package.dependencies += [
        .package(path: "../swift-tools-support-core"),
        .package(path: "../swift-argument-parser"),
        .package(path: "../swift-driver"),
        .package(path: "../swift-crypto"),
    ]
}
