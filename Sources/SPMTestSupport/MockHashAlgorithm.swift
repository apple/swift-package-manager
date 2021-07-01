/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics

public class MockHashAlgorithm: HashAlgorithm {
    public typealias Handler = (ByteString) -> ByteString

    public private(set) var hashes = ThreadSafeArrayStore<ByteString>()
    private let handler: Handler?

    public init(handler: Handler? = nil) {
        self.handler = handler
    }

    public func hash(_ hash: ByteString) -> ByteString {
        if let handler = self.handler {
            return handler(hash)
        } else {
            self.hashes.append(hash)
            return ByteString(hash.contents.reversed())
        }
    }
}
