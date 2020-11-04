/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest

import TSCBasic
import PackageModel
import PackageLoading
import Workspace
import PackageGraph
import SourceControl

public struct TestPackage {

    public let name: String
    public let platforms: [PlatformDescription]
    public let path: String?
    public let targets: [TestTarget]
    public let products: [TestProduct]
    public let dependencies: [TestDependency]
    public let versions: [String?]
    // FIXME: This should be per-version.
    public let toolsVersion: ToolsVersion?

    public init(
        name: String,
        platforms: [PlatformDescription] = [],
        path: String? = nil,
        targets: [TestTarget],
        products: [TestProduct],
        dependencies: [TestDependency] = [],
        versions: [String?] = [],
        toolsVersion: ToolsVersion? = nil
    ) {
        self.name = name
        self.platforms = platforms
        self.path = path
        self.targets = targets
        self.products = products
        self.dependencies = dependencies
        self.versions = versions
        self.toolsVersion = toolsVersion
    }

    public static func genericPackage1(named name: String) -> TestPackage {
        return TestPackage(
            name: name,
            targets: [
                TestTarget(name: name),
            ],
            products: [
                TestProduct(name: name, targets: [name]),
            ],
            versions: ["1.0.0"]
        )
    }
}
