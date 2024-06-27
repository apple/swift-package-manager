//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

/// A simple representation of a path in the file system.
public struct Path: Hashable {
    private let _string: String

    /// Initializes the path from the contents a string, which should be an
    /// absolute path in platform representation.
    @available(_PackageDescription, deprecated: 6.0, message: "Use `URL` type instead of `Path`.")
    public init(_ string: String) {
        self._string = string
    }

    init(url: URL) {
        self._string = url.path
    }

    /// A string representation of the path.
    @available(_PackageDescription, deprecated: 6.0, message: "Use `URL` type instead of `Path`.")
    public var string: String {
        self._string
    }

    // Note: this avoids duplication warnings for our own code.
    var stringValue: String {
        self._string
    }

    /// The last path component (including any extension).
    @available(_PackageDescription, deprecated: 6.0, message: "Use `URL` type instead of `Path`.")
    public var lastComponent: String {
        // Check for a special case of the root directory.
        if self._string == "/" {
            // Root directory, so the basename is a single path separator (the
            // root directory is special in this regard).
            return "/"
        }
        // Find the last path separator.
        guard let idx = _string.lastIndex(of: "/") else {
            // No path separators, so the basename is the whole string.
            return self._string
        }
        // Otherwise, it's the string from (but not including) the last path
        // separator.
        return String(self._string.suffix(from: self._string.index(after: idx)))
    }

    /// The last path component (without any extension).
    @available(_PackageDescription, deprecated: 6.0, message: "Use `URL` type instead of `Path`.")
    public var stem: String {
        let filename = self.lastComponent
        if let ext = self.extension {
            return String(filename.dropLast(ext.count + 1))
        } else {
            return filename
        }
    }

    /// The filename extension, if any (without any leading dot).
    @available(_PackageDescription, deprecated: 6.0, message: "Use `URL` type instead of `Path`.")
    public var `extension`: String? {
        // Find the last path separator, if any.
        let sIdx = self._string.lastIndex(of: "/")

        // Find the start of the basename.
        let bIdx = (sIdx != nil) ? self._string.index(after: sIdx!) : self._string.startIndex

        // Find the last `.` (if any), starting from the second character of
        // the basename (a leading `.` does not make the whole path component
        // a suffix).
        let fIdx = self._string.index(bIdx, offsetBy: 1, limitedBy: self._string.endIndex) ?? self._string.startIndex
        if let idx = _string[fIdx...].lastIndex(of: ".") {
            // Unless it's just a `.` at the end, we have found a suffix.
            if self._string.distance(from: idx, to: self._string.endIndex) > 1 {
                return String(self._string.suffix(from: self._string.index(idx, offsetBy: 1)))
            }
        }
        // If we get this far, there is no suffix.
        return nil
    }

    /// The path except for the last path component.
    @available(_PackageDescription, deprecated: 6.0, message: "Use `URL` type instead of `Path`.")
    public func removingLastComponent() -> Path {
        // Find the last path separator.
        guard let idx = string.lastIndex(of: "/") else {
            // No path separators, so the directory name is `.`.
            return Path(".")
        }
        // Check if it's the only one in the string.
        if idx == self.string.startIndex {
            // Just one path separator, so the directory name is `/`.
            return Path("/")
        }
        // Otherwise, it's the string up to (but not including) the last path
        // separator.
        return Path(String(self._string.prefix(upTo: idx)))
    }

    /// The result of appending a subpath, which should be a relative path in
    /// platform representation.
    @available(_PackageDescription, deprecated: 6.0, message: "Use `URL` type instead of `Path`.")
    public func appending(subpath: String) -> Path {
        Path(self._string + (self._string.hasSuffix("/") ? "" : "/") + subpath)
    }

    /// The result of appending one or more path components.
    @available(_PackageDescription, deprecated: 6.0, message: "Use `URL` type instead of `Path`.")
    public func appending(_ components: [String]) -> Path {
        self.appending(subpath: components.joined(separator: "/"))
    }

    /// The result of appending one or more path components.
    @available(_PackageDescription, deprecated: 6.0, message: "Use `URL` type instead of `Path`.")
    public func appending(_ components: String...) -> Path {
        self.appending(components)
    }
}

extension Path: CustomStringConvertible {
    @available(_PackageDescription, deprecated: 6.0, message: "Use `URL` type instead of `Path`.")
    public var description: String {
        self.string
    }
}

extension Path: Codable {
    @available(_PackageDescription, deprecated: 6.0, message: "Use `URL` type instead of `Path`.")
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.string)
    }

    @available(_PackageDescription, deprecated: 6.0, message: "Use `URL` type instead of `Path`.")
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        self.init(string)
    }
}

extension String.StringInterpolation {
    @available(_PackageDescription, deprecated: 6.0, message: "Use `URL` type instead of `Path`.")
    public mutating func appendInterpolation(_ path: Path) {
        self.appendInterpolation(path.string)
    }
}
