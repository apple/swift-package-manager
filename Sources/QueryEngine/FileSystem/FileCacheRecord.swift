//===----------------------------------------------------------------------===//
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

// FIXME: need a new swift-system tag to remove `@preconcurrency`
@preconcurrency import struct SystemPackage.FilePath

public struct FileCacheRecord: Sendable {
    public let path: FilePath
    public let hash: String
}

extension FileCacheRecord: Codable {
    enum CodingKeys: CodingKey {
        case path
        case hash
    }

    // FIXME: `Codable` on `FilePath` is broken, thus all `Codable` types with `FilePath` properties need a custom impl.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try FilePath(container.decode(String.self, forKey: .path))
        self.hash = try container.decode(String.self, forKey: .hash)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.path.string, forKey: .path)
        try container.encode(self.hash, forKey: .hash)
    }
}
