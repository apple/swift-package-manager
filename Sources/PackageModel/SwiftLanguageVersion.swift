//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

import struct TSCUtility.Version

/// Represents a Swift language version.
public struct SwiftLanguageVersion: Hashable, Sendable {

    /// Swift language version 3.
    public static let v3 = SwiftLanguageVersion(uncheckedString: "3")

    /// Swift language version 4.
    public static let v4 = SwiftLanguageVersion(uncheckedString: "4")

    /// Swift language version 4.2.
    public static let v4_2 = SwiftLanguageVersion(uncheckedString: "4.2")

    /// Swift language version 5.
    public static let v5 = SwiftLanguageVersion(uncheckedString: "5")

    /// The list of known Swift language versions.
    public static let knownSwiftLanguageVersions = [
        v3, v4, v4_2, v5,
    ]

    /// The raw value of the language version.
    //
    // This should be passed as a value to Swift compiler's -swift-version flag.
    public let rawValue: String

    /// The underlying backing store.
    private let _version: Version

    /// The major version number.
    public var major: Int {
        return _version.major
    }

    /// The minor version number.
    public var minor: Int {
        return _version.minor
    }

    /// The patch version number.
    public var patch: Int {
        return _version.patch
    }

    /// Regex for parsing the Swift language version.
    private static let regex = #/^(?<major>\d+)(?:\.(?<minor>\d+))?(?:\.(?<patch>\d+))?$/#

    /// Create an instance of Swift language version from the given string.
    ///
    // The Swift language version is not officially fixed but we require it to
    // be a valid SemVer-like string.
    public init?(string: String) {
        let parsedVersions = string.matches(of: SwiftLanguageVersion.regex)
        guard parsedVersions.count == 1 else {
            return nil
        }
        let parsedVersion = parsedVersions[0]
        let major = Int(parsedVersion.major) ?? 0
        let minor: Int
        if let minorString = parsedVersion.minor {
            minor = Int(minorString) ?? 0
        } else {
            minor = 0
        }
        let patch: Int
        if let patchString = parsedVersion.patch {
            patch = Int(patchString) ?? 0
        } else {
            patch = 0
        }
        self.rawValue = string
        self._version = Version(major, minor, patch)
    }

    /// Create an instance assuming the string is valid.
    private init(uncheckedString string: String) {
        self.init(string: string)!
    }
}

extension SwiftLanguageVersion: CustomStringConvertible {
    public var description: String {
        return rawValue
    }
}

extension SwiftLanguageVersion: Equatable {
    public static func == (lhs: SwiftLanguageVersion, rhs: SwiftLanguageVersion) -> Bool {
        return lhs._version == rhs._version
    }
}

extension SwiftLanguageVersion: Comparable {
    public static func < (lhs: SwiftLanguageVersion, rhs: SwiftLanguageVersion) -> Bool {
        return lhs._version < rhs._version
    }
}

// MARK: - Compare with ToolsVersion

extension SwiftLanguageVersion {
    public static func == (lhs: SwiftLanguageVersion, rhs: ToolsVersion) -> Bool {
        return (lhs.major, lhs.minor, lhs.patch) == (rhs.major, rhs.minor, rhs.patch)
    }

    public static func < (lhs: SwiftLanguageVersion, rhs: ToolsVersion) -> Bool {
        return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public static func <= (lhs: SwiftLanguageVersion, rhs: ToolsVersion) -> Bool {
        return (lhs < rhs) || (lhs == rhs)
    }
}

extension SwiftLanguageVersion: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self.init(uncheckedString: rawValue)
    }
}
