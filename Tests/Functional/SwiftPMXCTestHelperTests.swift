/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

#if os(OSX)

import XCTest
import Utility

class SwiftPMXCTestHelperTests: XCTestCase {
    func testBasicXCTestHelper() {
        fixture(name: "Miscellaneous/SwiftPMXCTestHelper") { prefix in
            // Build the package.
            XCTAssertBuilds(prefix)
            XCTAssertFileExists(prefix, ".build", "debug", "SwiftPMXCTestHelper.swiftmodule")
            // Run swift-test on package.
            XCTAssertSwiftTest(prefix)
            // Expected output dictionary.
            let testCases = ["name": "All Tests", "tests": [["name" : "SwiftPMXCTestHelperTests.xctest",
                "tests": [
                [
                "name": "Objc",
                "tests": [["name": "test_example"], ["name": "testThisThing"]]
                ],
                [
                "name": "SwiftPMXCTestHelperTestSuite.SwiftPMXCTestHelperTests1",
                "tests": [["name": "test_Example2"], ["name": "testExample1"]]
                ]
              ]]]
            ] as NSDictionary
            // Run the XCTest helper tool and check result.
            XCTAssertXCTestHelper(prefix, ".build", "debug", "SwiftPMXCTestHelperTests.xctest", testCases: testCases)
        }
    }
}

func XCTAssertXCTestHelper(_ bundlePath: String..., testCases: NSDictionary) {
    do {
        let bundle = Path.join(bundlePath)
        let env = ["DYLD_FRAMEWORK_PATH": try platformFrameworksPath()]
        let outputFile = Path.join(bundle.parentDirectory, "tests.txt")
        let _ = try SwiftPMProduct.XCTestHelper.execute([bundle, outputFile], env: env, printIfError: true)
        guard let data = NSData(contentsOfFile: outputFile) else {
            XCTFail("No output found in : \(outputFile)"); return;
        }
        let json = try JSONSerialization.jsonObject(with: data as Data, options: [])
        XCTAssertTrue(json.isEqual(testCases), "\(json) is not equal to \(testCases)")
    } catch {
        XCTFail("Failed with error: \(error)")
    }
}

#endif
