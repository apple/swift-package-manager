//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct Foundation.URL
import struct TSCBasic.AbsolutePath

// public for transition
public typealias TSCAbsolutePath = TSCBasic.AbsolutePath

/// Represents an absolute file system path, independently of what (or whether
/// anything at all) exists at that path in the file system at any given time.
/// An absolute path always starts with a `/` character, and holds a normalized
/// string representation.  This normalization is strictly syntactic, and does
/// not access the file system in any way.
///
/// The absolute path string is normalized by:
/// - Collapsing `..` path components
/// - Removing `.` path components
/// - Removing any trailing path separator
/// - Removing any redundant path separators
///
/// This string manipulation may change the meaning of a path if any of the
/// path components are symbolic links on disk.  However, the file system is
/// never accessed in any way when initializing an AbsolutePath.
///
/// Note that `~` (home directory resolution) is *not* done as part of path
/// normalization, because it is normally the responsibility of the shell and
/// not the program being invoked (e.g. when invoking `cd ~`, it is the shell
/// that evaluates the tilde; the `cd` command receives an absolute path).
public struct AbsolutePath: Hashable, Sendable {
    /// Root directory (whose string representation is just a path separator).
    public static let root = Self(TSCAbsolutePath.root)

    package let underlying: TSCAbsolutePath

    // public for transition
    public init(_ underlying: TSCAbsolutePath) {
        self.underlying = underlying
    }

    /// Initializes the AbsolutePath from `absStr`, which must be an absolute
    /// path (i.e. it must begin with a path separator; this initializer does
    /// not interpret leading `~` characters as home directory specifiers).
    /// The input string will be normalized if needed, as described in the
    /// documentation for AbsolutePath.
    public init(validating pathString: String) throws {
        self.underlying = try .init(validating: pathString)
    }

    /// Initializes an AbsolutePath from a string that may be either absolute
    /// or relative; if relative, `basePath` is used as the anchor; if absolute,
    /// it is used as is, and in this case `basePath` is ignored.
    public init(validating pathString: String, relativeTo basePath: AbsolutePath) throws {
        self.underlying = try .init(validating: pathString, relativeTo: basePath.underlying)
    }

    /// Initializes the AbsolutePath by concatenating a relative path to an
    /// existing absolute path, and renormalizing if necessary.
    public init(_ absolutePath: AbsolutePath, _ relativeTo: RelativePath) {
        self.underlying = .init(absolutePath.underlying, relativeTo.underlying)
    }

    /// Convenience initializer that appends a string to a relative path.
    public init(_ absolutePath: AbsolutePath, validating relativePathString: String) throws {
        try self.init(absolutePath, RelativePath(validating: relativePathString))
    }

    /// Directory component.  An absolute path always has a non-empty directory
    /// component (the directory component of the root path is the root itself).
    public var dirname: String {
        self.underlying.dirname
    }

    /// Last path component (including the suffix, if any).  it is never empty.
    public var basename: String {
        self.underlying.basename
    }

    /// Returns the basename without the extension.
    public var basenameWithoutExt: String {
        self.underlying.basenameWithoutExt
    }

    /// Suffix (including leading `.` character) if any.  Note that a basename
    /// that starts with a `.` character is not considered a suffix, nor is a
    /// trailing `.` character.
    public var suffix: String? {
        self.underlying.suffix
    }

    /// Extension of the give path's basename. This follow same rules as
    /// suffix except that it doesn't include leading `.` character.
    public var `extension`: String? {
        self.underlying.extension
    }

    /// Absolute path of parent directory.  This always returns a path, because
    /// every directory has a parent (the parent directory of the root directory
    /// is considered to be the root directory itself).
    public var parentDirectory: AbsolutePath {
        Self(self.underlying.parentDirectory)
    }

    /// True if the path is the root directory.
    public var isRoot: Bool {
        self.underlying.isRoot
    }

    /// NOTE: We will most likely want to add other `appending()` methods, such
    ///       as `appending(suffix:)`, and also perhaps `replacing()` methods,
    ///       such as `replacing(suffix:)` or `replacing(basename:)` for some
    ///       of the more common path operations.

    /// NOTE: We may want to consider adding operators such as `+` for appending
    ///       a path component.

    /// NOTE: We will want to add a method to return the lowest common ancestor
    ///       path.

    /// Normalized string representation (the normalization rules are described
    /// in the documentation of the initializer).  This string is never empty.
    public var pathString: String {
        self.underlying.pathString
    }
}

extension AbsolutePath {
    /// Returns an array of strings that make up the path components of the
    /// absolute path.  This is the same sequence of strings as the basenames
    /// of each successive path component, starting from the root.  Therefore
    /// the first path component of an absolute path is always `/`.
    public var components: [String] {
        self.underlying.components
    }

    /// Returns the absolute path with the relative path applied.
    public func appending(_ relativePath: RelativePath) -> AbsolutePath {
        Self(self.underlying.appending(relativePath.underlying))
    }

    /// Returns the absolute path with an additional literal component appended.
    ///
    /// This method accepts pseudo-path like '.' or '..', but should not contain "/".
    public func appending(component: String) -> AbsolutePath {
        Self(self.underlying.appending(component: component))
    }

    /// Returns the absolute path with additional literal components appended.
    ///
    /// This method should only be used in cases where the input is guaranteed
    /// to be a valid path component (i.e., it cannot be empty, contain a path
    /// separator, or be a pseudo-path like '.' or '..').
    public func appending(components: [String]) -> AbsolutePath {
        Self(self.underlying.appending(components: components))
    }

    /// Returns the absolute path with additional literal components appended.
    ///
    /// This method should only be used in cases where the input is guaranteed
    /// to be a valid path component (i.e., it cannot be empty, contain a path
    /// separator, or be a pseudo-path like '.' or '..').
    public func appending(components: String...) -> AbsolutePath {
        Self(self.underlying.appending(components: components))
    }

    /// Returns the absolute path with additional literal components appended.
    ///
    /// This method should only be used in cases where the input is guaranteed
    /// to be a valid path component (i.e., it cannot be empty, contain a path
    /// separator, or be a pseudo-path like '.' or '..').
    public func appending(_ component: String) -> AbsolutePath {
        self.appending(component: component)
    }

    /// Returns the absolute path with additional literal components appended.
    ///
    /// This method should only be used in cases where the input is guaranteed
    /// to be a valid path component (i.e., it cannot be empty, contain a path
    /// separator, or be a pseudo-path like '.' or '..').
    public func appending(_ components: String...) -> AbsolutePath {
        self.appending(components: components)
    }

    /// Returns the absolute path with additional extension appended.
    ///
    public func appending(extension: String) -> AbsolutePath {
        guard !self.isRoot else { return self }
        let `extension` = `extension`.spm_dropPrefix(".")
        return self.parentDirectory.appending("\(basename).\(`extension`)")
    }
}

extension AbsolutePath {
    /// Returns a relative path that, when concatenated to `base`, yields the
    /// callee path itself.  If `base` is not an ancestor of the callee, the
    /// returned path will begin with one or more `..` path components.
    ///
    /// Because both paths are absolute, they always have a common ancestor
    /// (the root path, if nothing else).  Therefore, any path can be made
    /// relative to any other path by using a sufficient number of `..` path
    /// components.
    ///
    /// This method is strictly syntactic and does not access the file system
    /// in any way.  Therefore, it does not take symbolic links into account.
    public func relative(to base: AbsolutePath) -> RelativePath {
        RelativePath(self.underlying.relative(to: base.underlying))
    }

    /// Returns true if the path is an ancestor of the given path.
    ///
    /// This method is strictly syntactic and does not access the file system
    /// in any way.
    public func isAncestor(of descendant: AbsolutePath) -> Bool {
        self.underlying.isAncestor(of: descendant.underlying)
    }

    /// Returns true if the path is an ancestor of or equal to the given path.
    ///
    /// This method is strictly syntactic and does not access the file system
    /// in any way.
    public func isAncestorOfOrEqual(to descendant: AbsolutePath) -> Bool {
        self.underlying.isAncestorOfOrEqual(to: descendant.underlying)
    }

    /// Returns true if the path is a descendant of the given path.
    ///
    /// This method is strictly syntactic and does not access the file system
    /// in any way.
    public func isDescendant(of ancestor: AbsolutePath) -> Bool {
        self.underlying.isDescendant(of: ancestor.underlying)
    }

    /// Returns true if the path is a descendant of or equal to the given path.
    ///
    /// This method is strictly syntactic and does not access the file system
    /// in any way.
    public func isDescendantOfOrEqual(to ancestor: AbsolutePath) -> Bool {
        self.underlying.isDescendantOfOrEqual(to: ancestor.underlying)
    }
}

extension AbsolutePath {
    /// Unlike ``AbsolutePath//extension``, this property returns all characters after the first `.` character in a
    /// filename. If no dot character is present in the filename or first dot is the last character, `nil` is returned.
    public var allExtensions: [String]? {
        guard let firstDot = self.basename.firstIndex(of: ".") else {
            return nil
        }

        var extensions = String(self.basename[firstDot ..< self.basename.endIndex])

        guard extensions.count > 1 else {
            return nil
        }

        extensions.removeFirst()

        return extensions.split(separator: ".").map(String.init)
    }

    /// Returns the basename dropping any possible  extension.
    public var basenameWithoutAnyExtension: String {
        var basename = self.basename
        if let index = basename.firstIndex(of: ".") {
            basename.removeSubrange(index ..< basename.endIndex)
        }
        return String(basename)
    }
}

extension AbsolutePath: Codable {
    public func encode(to encoder: Encoder) throws {
        try self.underlying.encode(to: encoder)
    }

    public init(from decoder: Decoder) throws {
        try self = .init(TSCAbsolutePath(from: decoder))
    }
}

// Make absolute paths Comparable.
extension AbsolutePath: Comparable {
    public static func < (lhs: AbsolutePath, rhs: AbsolutePath) -> Bool {
        lhs.underlying < rhs.underlying
    }
}

/// Make absolute paths CustomStringConvertible and CustomDebugStringConvertible.
extension AbsolutePath: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        self.underlying.description
    }

    public var debugDescription: String {
        self.underlying.debugDescription
    }
}

extension AbsolutePath {
    public var asURL: Foundation.URL {
        self.underlying.asURL
    }
}

extension AbsolutePath {
    /// Returns a path suitable for display to the user (if possible, it is made
    /// to be relative to the current working directory).
    public func prettyPath(cwd: AbsolutePath? = localFileSystem.currentWorkingDirectory) -> String {
        self.underlying.prettyPath(cwd: cwd?.underlying)
    }
}

extension AbsolutePath {
    public var escapedPathString: String {
        self.pathString.replacingOccurrences(of: "\\", with: "\\\\")
    }
}

extension TSCAbsolutePath {
    public init(_ path: AbsolutePath) {
        self = path.underlying
    }
}
