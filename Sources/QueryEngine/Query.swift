//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Crypto
import struct SystemPackage.FilePath

public protocol Query: Encodable {
    func run(engine: QueryEngine) async throws -> FilePath
}

extension Query {
    func hash(with hashFunction: inout some HashFunction) {
        fatalError("\(#function) not implemented")
    }
}
