/*
 This source file is part of the Swift.org open source project

 Copyright 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest

#if !os(OSX)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(CollectionTests.allTests),
        testCase(FileTests.allTests),
        testCase(GitUtilityTests.allTests),
        testCase(PathTests.allTests),
        testCase(PkgConfigParserTests.allTests),
        testCase(RelativePathTests.allTests),
        testCase(RmtreeTests.allTests),
        testCase(ShellTests.allTests),
        testCase(StatTests.allTests),
        testCase(StringTests.allTests),
        testCase(URLTests.allTests),
        testCase(WalkTests.allTests)
    ]
}
#endif

