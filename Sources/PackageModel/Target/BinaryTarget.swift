//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct Basics.AbsolutePath

public final class BinaryTarget: Target {
    /// The kind of binary artifact.
    public let kind: Kind

    /// The original source of the binary artifact.
    public let origin: Origin

    /// The binary artifact path.
    public var artifactPath: AbsolutePath {
        return self.sources.root
    }

    public init(
        name: String,
        kind: Kind,
        path: AbsolutePath,
        origin: Origin
    ) {
        self.origin = origin
        self.kind = kind
        let sources = Sources(paths: [], root: path)
        super.init(
            name: name,
            type: .binary,
            path: .root,
            sources: sources,
            dependencies: [],
            packageAccess: false,
            buildSettings: .init(),
            pluginUsages: [],
            usesUnsafeFlags: false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case origin
        case artifactSource // backwards compatibility 2/2021
    }

    public override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.origin, forKey: .origin)
        try container.encode(self.kind, forKey: .kind)
    }

    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // backwards compatibility 2/2021
        if !container.contains(.kind) {
            self.kind = .xcframework
        } else {
            self.kind = try container.decode(Kind.self, forKey: .kind)
        }
        // backwards compatibility 2/2021
        if container.contains(.artifactSource)  {
            self.origin = try container.decode(Origin.self, forKey: .artifactSource)
        } else {
            self.origin = try container.decode(Origin.self, forKey: .origin)
        }
        try super.init(from: decoder)
    }

    public enum Kind: String, RawRepresentable, Codable, CaseIterable {
        case xcframework
        case libraryArchive
        case artifactsArchive
        case unknown // for non-downloaded artifacts

        public var fileExtension: String {
            switch self {
            case .xcframework:
                return "xcframework"
            case .artifactsArchive, .libraryArchive:
                return "artifactbundle"
            case .unknown:
                return "unknown"
            }
        }
    }

    public var containsExecutable: Bool {
        // FIXME: needs to be revisited once libraries are supported in artifact bundles
        return self.kind == .artifactsArchive
    }

    public enum Origin: Equatable, Codable {

        /// Represents an artifact that was downloaded from a remote URL.
        case remote(url: String)

        /// Represents an artifact that was available locally.
        case local

        private enum CodingKeys: String, CodingKey {
            case remote, local
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .remote(let a1):
                var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .remote)
                try unkeyedContainer.encode(a1)
            case .local:
                try container.encodeNil(forKey: .local)
            }
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard let key = values.allKeys.first(where: values.contains) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Did not find a matching key"))
            }
            switch key {
            case .remote:
                var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
                let a1 = try unkeyedValues.decode(String.self)
                self = .remote(url: a1)
            case .local:
                self = .local
            }
        }
    }
}
