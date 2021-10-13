/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest
import Basics
import TSCBasic
import PackageModel

class PackageModelTests: XCTestCase {

    func testLegacyIdentities() throws {
        XCTAssertTrue(PackageModel._useLegacyIdentities)
        
        PackageModel._useLegacyIdentities = false
        XCTAssertEqual(
            PackageIdentity(url: URL(string: "git@github.com/foo/bar/baz.git")!).description,
            "github.com/foo/bar/baz"
        )

        PackageModel._useLegacyIdentities = true
        XCTAssertEqual(
            PackageIdentity(url: URL(string: "git@github.com/foo/bar/baz.git")!).description,
            "baz"
        )
    }

    func testProductTypeCodable() throws {
        struct Foo: Codable, Equatable {
            var type: ProductType
        }

        func checkCodable(_ type: ProductType) {
            do {
                let foo = Foo(type: type)
                let data = try JSONEncoder.makeWithDefaults().encode(foo)
                let decodedFoo = try JSONDecoder.makeWithDefaults().decode(Foo.self, from: data)
                XCTAssertEqual(foo, decodedFoo)
            } catch {
                XCTFail("\(error)")
            }
        }

        checkCodable(.library(.automatic))
        checkCodable(.library(.static))
        checkCodable(.library(.dynamic))
        checkCodable(.executable)
        checkCodable(.test)
    }
    
    func testProductFilterCodable() throws {
        // Test ProductFilter.everything
        try {
            let data = try JSONEncoder().encode(ProductFilter.everything)
            let decoded = try JSONDecoder().decode(ProductFilter.self, from: data)
            XCTAssertEqual(decoded, ProductFilter.everything)
        }()
        // Test ProductFilter.specific(), including that the order is normalized
        try {
            let data = try JSONEncoder().encode(ProductFilter.specific(["Bar", "Foo"]))
            let decoded = try JSONDecoder().decode(ProductFilter.self, from: data)
            XCTAssertEqual(decoded, ProductFilter.specific(["Foo", "Bar"]))
        }()
    }
}
