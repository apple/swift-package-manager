//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageModel
import XCTest

import class Basics.AsyncProcess
import struct TSCBasic.StringError

extension Toolchain {
    package func skipUnlessAtLeastSwift6(
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        #if compiler(<6.0)
        try XCTSkipIf(true, "Skipping because test requires at least Swift 6.0")
        #endif
    }
}
