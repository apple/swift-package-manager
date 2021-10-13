/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import PackageModel
import XCTest

class PackageDescriptionNextLoadingTests: PackageDescriptionLoadingTests {
    override var toolsVersion: ToolsVersion {
        .vNext
    }
    
    func testRegistryDependencies() throws {
        let manifest = """
            import PackageDescription
            let package = Package(
               name: "MyPackage",
               dependencies: [
                   .package(id: "x.foo", from: "1.1.1"),
                   .package(id: "x.bar", exact: "1.1.1"),
                   .package(id: "x.baz", .upToNextMajor(from: "1.1.1")),
                   .package(id: "x.qux", .upToNextMinor(from: "1.1.1")),
                   .package(id: "x.quux", "1.1.1" ..< "3.0.0"),
               ]
            )
            """
        loadManifest(manifest, toolsVersion: self.toolsVersion) { manifest in
        let deps = Dictionary(uniqueKeysWithValues: manifest.dependencies.map{ ($0.identity.description, $0) })
            XCTAssertEqual(deps["x.foo"], .registry(identity: "x.foo", requirement: .range("1.1.1" ..< "2.0.0")))
            XCTAssertEqual(deps["x.bar"], .registry(identity: "x.bar", requirement: .exact("1.1.1")))
            XCTAssertEqual(deps["x.baz"], .registry(identity: "x.baz", requirement: .range("1.1.1" ..< "2.0.0")))
            XCTAssertEqual(deps["x.qux"], .registry(identity: "x.qux", requirement: .range("1.1.1" ..< "1.2.0")))
            XCTAssertEqual(deps["x.quux"], .registry(identity: "x.quux", requirement: .range("1.1.1" ..< "3.0.0")))
        }
    }
}
