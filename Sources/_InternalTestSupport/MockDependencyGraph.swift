//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import XCTest

import PackageGraph
import PackageModel

import struct TSCUtility.Version

public struct MockDependencyGraph {
    public let name: String
    public let constraints: [MockPackageContainer.Constraint]
    public let containers: [MockPackageContainer]
    public let result: [PackageReference: Version]

    public init(name: String, constraints: [MockPackageContainer.Constraint], containers: [MockPackageContainer], result: [PackageReference : Version]) {
        self.name = name
        self.constraints = constraints
        self.containers = containers
        self.result = result
    }

    public func checkResult(
        _ output: [(container: PackageReference, version: Version)],
        file: StaticString = #file,
        line: UInt = #line
    ) {
        var result = self.result
        for item in output {
            XCTAssertEqual(result[item.container], item.version, file: file, line: line)
            result[item.container] = nil
        }
        if !result.isEmpty {
            XCTFail("Unchecked containers: \(result)", file: file, line: line)
        }
    }
}
