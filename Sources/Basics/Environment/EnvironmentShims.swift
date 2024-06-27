//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct TSCBasic.ProcessEnvironmentBlock

import Dispatch

// FIXME: remove ProcessEnvironmentBlockShims
// only needed outside this module for Git
extension Environment {
    @_spi(ProcessEnvironmentBlockShim)
    public init(_ processEnvironmentBlock: ProcessEnvironmentBlock) {
        self.init()
        for (key, value) in processEnvironmentBlock {
            self[.init(key.value)] = value
        }
    }
}

extension ProcessEnvironmentBlock {
    @_spi(ProcessEnvironmentBlockShim)
    public init(_ environment: Environment) {
        self.init()
        for (key, value) in environment {
            self[.init(key.rawValue)] = value
        }
    }
}
