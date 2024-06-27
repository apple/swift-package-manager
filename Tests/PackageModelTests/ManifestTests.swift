//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import XCTest
import PackageModel
import _InternalTestSupport

class ManifestTests: XCTestCase {
    func testRequiredTargets() throws {
        let products = [
            try ProductDescription(name: "Foo", type: .library(.automatic), targets: ["Foo"]),
            try ProductDescription(name: "Bar", type: .library(.automatic), targets: ["Bar"])
        ]

        let targets = [
            try TargetDescription(name: "Foo", dependencies: ["Bar"]),
            try TargetDescription(name: "Bar", dependencies: ["Baz"]),
            try TargetDescription(name: "Baz", dependencies: ["MyPlugin"]),
            try TargetDescription(name: "FooBar", dependencies: []),
            try TargetDescription(name: "MyPlugin", type: .plugin, pluginCapability: .buildTool)
        ]

        do {
            let manifest = Manifest.createRootManifest(
                displayName: "Foo",
                path: "/Foo",
                toolsVersion: .v5_2,
                products: products,
                targets: targets
            )

            XCTAssertEqual(manifest.targetsRequired(for: .everything).map({ $0.name }).sorted(), [
                "Bar",
                "Baz",
                "Foo",
                "FooBar",
                "MyPlugin"
            ])
        }

        do {
            let manifest = Manifest.createLocalSourceControlManifest(
                displayName: "Foo",
                path: "/Foo",
                toolsVersion: .v5_2,
                products: products,
                targets: targets
            )

            XCTAssertEqual(manifest.targetsRequired(for: .specific(["Foo", "Bar"])).map({ $0.name }).sorted(), [
                "Bar",
                "Baz",
                "Foo",
                "MyPlugin",
            ])
        }
    }

    func testRequiredDependencies() throws {
        let dependencies: [PackageDependency] = [
            .localSourceControl(path: "/Bar1", requirement: .upToNextMajor(from: "1.0.0")),
            .localSourceControl(path: "/Bar2", requirement: .upToNextMajor(from: "1.0.0")),
            .localSourceControl(path: "/Bar3", requirement: .upToNextMajor(from: "1.0.0")),
        ]

        let products = [
            try ProductDescription(name: "Foo", type: .library(.automatic), targets: ["Foo1"])
        ]

        let targets = [
            try TargetDescription(name: "Foo1", dependencies: ["Foo2", "Bar1"]),
            try TargetDescription(name: "Foo2", dependencies: [.product(name: "B2", package: "Bar2")]),
            try TargetDescription(name: "Foo3", dependencies: ["Bar3"]),
        ]

        do {
            let manifest = Manifest.createRootManifest(
                displayName: "Foo",
                path: "/Foo",
                toolsVersion: .v5,
                dependencies: dependencies,
                products: products,
                targets: targets
            )

            XCTAssertEqual(manifest.dependenciesRequired(for: .everything).map({ $0.identity.description }).sorted(), [
                "bar1",
                "bar2",
                "bar3",
            ])
        }

        do {
            let manifest = Manifest.createLocalSourceControlManifest(
                displayName: "Foo",
                path: "/Foo",
                toolsVersion: .v5,
                dependencies: dependencies,
                products: products,
                targets: targets
            )

            XCTAssertEqual(manifest.dependenciesRequired(for: .specific(["Foo"])).map({ $0.identity.description }).sorted(), [
                "bar1", // Foo → Foo1 → Bar1
                "bar2", // Foo → Foo1 → Foo2 → Bar2
                "bar3", // Foo → Foo1 → Bar1 → could be from any package due to pre‐5.2 tools version.
            ])
        }

        do {
            let manifest = Manifest.createRootManifest(
                displayName: "Foo",
                path: "/Foo",
                toolsVersion: .v5_2,
                dependencies: dependencies,
                products: products,
                targets: targets
            )

            XCTAssertEqual(manifest.dependenciesRequired(for: .everything).map({ $0.identity.description }).sorted(), [
                "bar1",
                "bar2",
                "bar3",
            ])
        }

        do {
            let manifest = Manifest.createLocalSourceControlManifest(
                displayName: "Foo",
                path: "/Foo",
                toolsVersion: .v5_2,
                dependencies: dependencies,
                products: products,
                targets: targets
            )

            #if ENABLE_TARGET_BASED_DEPENDENCY_RESOLUTION
            XCTAssertEqual(manifest.dependenciesRequired(for: .specific(["Foo"])).map({ $0.identity.description }).sorted(), [
                "bar1", // Foo → Foo1 → Bar1
                "bar2", // Foo → Foo1 → Foo2 → Bar2
                // (Bar3 is unreachable.)
            ])
            #endif
        }
    }
}
