/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import struct PackageDescription.Version
import Utility
import struct PackageDescription.Version

public class Package {
    public let url: String
    public let path: String
    public let name: String
    public let version: Version
    public var dependencies: [Package] = []
    public let manifest: Manifest

    public init(manifest: Manifest, url: String, version: Version) {
        self.manifest = manifest
        self.url = url
        self.path = manifest.path.parentDirectory
        self.name = Package.name(manifest: manifest, url: url)
        self.version = version
    }

    public enum Error: ErrorProtocol {
        case NoManifest(String)
        case NoOrigin(String)
        case NoVersion(String)
    }
}

extension Package: CustomStringConvertible {
    public var description: String {
        return name
    }
}

extension Package: Hashable, Equatable {
    //FIXME technically version should be taken into account
    public var hashValue: Int { return url.hashValue }
}

public func ==(lhs: Package, rhs: Package) -> Bool {
    //FIXME technically version should be taken into account
    return lhs.url == rhs.url
}

extension Package {
    public static func name(manifest: Manifest, url: String) -> String {
        return manifest.package.name ?? name(url: url)
    }

    public static func name(url: String) -> String {
        let base = url.basename

        switch URL.scheme(url) ?? "" {
        case "http", "https", "git", "ssh":
            if url.hasSuffix(".git") {
                let a = base.startIndex
                let b = base.index(base.endIndex, offsetBy: -4)
                return base[a..<b]
            } else {
                fallthrough
            }
        default:
            return base
        }
    }
}
