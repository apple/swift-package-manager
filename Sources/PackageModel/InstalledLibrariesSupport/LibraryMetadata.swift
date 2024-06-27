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
import struct TSCUtility.Version

public struct ProvidedLibrary: Hashable {
    public let location: AbsolutePath
    public let metadata: LibraryMetadata

    public var version: Version {
        .init(stringLiteral: metadata.version)
    }
}

public struct LibraryMetadata: Hashable, Decodable {
    public enum Identity: Hashable, Decodable {
        case packageIdentity(scope: String, name: String)
        case sourceControl(url: SourceControlURL)
    }

    /// The package from which it was built (e.g., the URL https://github.com/swiftlang/swift-syntax.git)
    public let identities: [Identity]
    /// The version that was built (e.g., 509.0.2)
    public let version: String
    /// The product name, if it differs from the module name (e.g., SwiftParser).
    public let productName: String

    let schemaVersion: Int
}

extension LibraryMetadata.Identity {
    public var identity: PackageIdentity {
        switch self {
        case .packageIdentity(let scope, let name):
            return PackageIdentity.plain("\(scope)/\(name)")
        case .sourceControl(let url):
            return PackageIdentity(url: url)
        }
    }

    public var kind: PackageReference.Kind {
        switch self {
        case .packageIdentity:
            return .registry(self.identity)
        case .sourceControl(let url):
            return .remoteSourceControl(.init(url.absoluteString))
        }
    }

    public var ref: PackageReference {
        return PackageReference(identity: self.identity, kind: self.kind)
    }
}
