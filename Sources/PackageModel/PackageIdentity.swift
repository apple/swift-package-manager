/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Foundation

import TSCBasic
import TSCUtility

/// A canonical identifier for a package, based on its source location.
///
/// A package may declare external packages as dependencies in its manifest.
/// Each external package is uniquely identified by the location of its source code.
///
/// An external package dependency may itself have one or more external package dependencies,
/// known as _transitive dependencies_.
/// When multiple packages have dependencies in common,
/// Swift Package Manager determines which version of that package should be used
/// (if any exist that satisfy all specified requirements)
/// in a process called package resolution.
///
/// External package dependencies are located by a URL
/// (which may be an implicit `file://` URL in the form of a file path).
/// For the purposes of package resolution,
/// package URLs are case-insensitive (mona ≍ MONA)
/// and normalization-insensitive (n + ◌̃ ≍ ñ).
/// Swift Package Manager takes additional steps to canonicalize URLs
/// to resolve insignificant differences between URLs.
/// For example,
/// the URLs `https://example.com/Mona/LinkedList` and `git@example.com:mona/linkedlist`
/// are equivalent, in that they both resolve to the same source code repository,
/// despite having different scheme, authority, and path components.
///
/// The `PackageIdentity` type canonicalizes package locations by
/// performing the following operations:
///
/// * Removing the scheme component, if present
///   ```
///   https://example.com/mona/LinkedList → example.com/mona/LinkedList
///   ```
/// * Removing the userinfo component (preceded by `@`), if present:
///   ```
///   git@example.com/mona/LinkedList → example.com/mona/LinkedList
///   ```
/// * Removing the port subcomponent, if present:
///   ```
///   example.com:443/mona/LinkedList → example.com/mona/LinkedList
///   ```
/// * Replacing the colon (`:`) preceding the path component in "`scp`-style" URLs:
///   ```
///   git@example.com:mona/LinkedList.git → example.com/mona/LinkedList
///   ```
/// * Expanding the tilde (`~`) to the provided user, if applicable:
///   ```
///   ssh://mona@example.com/~/LinkedList.git → example.com/~mona/LinkedList
///   ```
/// * Removing percent-encoding from the path component, if applicable:
///   ```
///   example.com/mona/%F0%9F%94%97List → example.com/mona/🔗List
///   ```
/// * Removing the `.git` file extension from the path component, if present:
///   ```
///   example.com/mona/LinkedList.git → example.com/mona/LinkedList
///   ```
/// * Removing the trailing slash (`/`) in the path component, if present:
///   ```
///   example.com/mona/LinkedList/ → example.com/mona/LinkedList
///   ```
/// * Removing the fragment component (preceded by `#`), if present:
///   ```
///   example.com/mona/LinkedList#installation → example.com/mona/LinkedList
///   ```
/// * Removing the query component (preceded by `?`), if present:
///   ```
///   example.com/mona/LinkedList?utm_source=forums.swift.org → example.com/mona/LinkedList
///   ```
public struct PackageIdentity: LosslessStringConvertible {
    /// A textual representation of this instance.
    public let description: String

    /// The computed name for the package.
    ///
    /// - Note: In Swift 5.3 and earlier,
    ///         external package dependencies are identified by
    ///         the last path component of their URL (removing any `.git` suffix, if present).
    ///         This is equivalent to the value returned by the `computedName` property.
    public let computedName: String

    /// Instantiates an instance of the conforming type from a string representation.
    public init(_ string: String) {
        var string = string

        let detectedScheme = string.dropSchemeComponentPrefixIfPresent()

        if case (let user, _)? = string.dropUserinfoSubcomponentPrefixIfPresent() {
            string.replaceFirstOccurenceIfPresent(of: "/~/", with: "/~\(user)/")
        }

        switch detectedScheme {
        case "http", "https":
            string.removeFragmentComponentIfPresent()
            string.removeQueryComponentIfPresent()
            string.removePortComponentIfPresent()
        case nil, "git", "ssh":
            string.removePortComponentIfPresent()
            string.replaceFirstOccurenceIfPresent(of: ":", before: string.firstIndex(of: "/"), with: "/")
        default:
            string.removePortComponentIfPresent()
        }

        var components = string.split(omittingEmptySubsequences: true, whereSeparator: isSeparator)
            .compactMap { $0.removingPercentEncoding ?? String($0) }

        var lastPathComponent = components.popLast() ?? ""
        lastPathComponent.removeSuffixIfPresent(".git")
        components.append(lastPathComponent)

        self.description = components.joined(separator: "/")
        self.computedName = String(lastPathComponent)
    }
}

extension PackageIdentity: Equatable, Comparable {
    private func compare(to another: PackageIdentity) -> ComparisonResult {
        return self.description.compare(another.description, options: [.caseInsensitive, .diacriticInsensitive])
    }

    public static func == (lhs: PackageIdentity, rhs: PackageIdentity) -> Bool {
        return lhs.compare(to: rhs) == .orderedSame
    }

    public static func < (lhs: PackageIdentity, rhs: PackageIdentity) -> Bool {
        return lhs.compare(to: rhs) == .orderedAscending
    }

    public static func > (lhs: PackageIdentity, rhs: PackageIdentity) -> Bool {
        return lhs.compare(to: rhs) == .orderedDescending
    }
}

extension PackageIdentity: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.description)
    }
}

extension PackageIdentity: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let description = try container.decode(String.self)
        self.init(description)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.description)
    }
}

extension PackageIdentity: JSONMappable, JSONSerializable {
    public init(json: JSON) throws {
        guard case .string(let string) = json else {
            throw JSON.MapError.typeMismatch(key: "", expected: String.self, json: json)
        }

        self.init(string)
    }

    public func toJSON() -> JSON {
        return .string(self.description)
    }
}

extension PackageIdentity: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

// MARK: -

#if os(Windows)
fileprivate let isSeparator: (Character) -> Bool = { $0 == "/" || $0 == "\\" }
#else
fileprivate let isSeparator: (Character) -> Bool = { $0 == "/" }
#endif

private extension Character {
    var isDigit: Bool {
        switch self {
        case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            return true
        default:
            return false
        }
    }

    var isAllowedInURLScheme: Bool {
        return isLetter || self.isDigit || self == "+" || self == "-" || self == "."
    }
}

private extension String {
    @discardableResult
    mutating func removePrefixIfPresent<T: StringProtocol>(_ prefix: T) -> Bool {
        guard hasPrefix(prefix) else { return false }
        removeFirst(prefix.count)
        return true
    }

    @discardableResult
    mutating func removeSuffixIfPresent<T: StringProtocol>(_ suffix: T) -> Bool {
        guard hasSuffix(suffix) else { return false }
        removeLast(suffix.count)
        return true
    }

    @discardableResult
    mutating func dropSchemeComponentPrefixIfPresent() -> String? {
        if let rangeOfDelimiter = range(of: "://"),
           self[startIndex].isLetter,
           self[..<rangeOfDelimiter.lowerBound].allSatisfy({ $0.isAllowedInURLScheme })
        {
            defer { self.removeSubrange(..<rangeOfDelimiter.upperBound) }

            return String(self[..<rangeOfDelimiter.lowerBound])
        }

        return nil
    }

    @discardableResult
    mutating func dropUserinfoSubcomponentPrefixIfPresent() -> (user: String, password: String?)? {
        if let indexOfAtSign = firstIndex(of: "@"),
           let indexOfFirstPathComponent = firstIndex(where: isSeparator),
           indexOfAtSign < indexOfFirstPathComponent
        {
            defer { self.removeSubrange(...indexOfAtSign) }

            let userinfo = self[..<indexOfAtSign]
            var components = userinfo.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard components.count > 0 else { return nil }
            let user = String(components.removeFirst())
            let password = components.last.map(String.init)

            return (user, password)
        }

        return nil
    }

    @discardableResult
    mutating func removePortComponentIfPresent() -> Bool {
        if let indexOfFirstPathComponent = firstIndex(where: isSeparator),
           let startIndexOfPort = firstIndex(of: ":"),
           startIndexOfPort < endIndex,
           let endIndexOfPort = self[index(after: startIndexOfPort)...].lastIndex(where: { $0.isDigit }),
           endIndexOfPort <= indexOfFirstPathComponent
        {
            self.removeSubrange(startIndexOfPort ... endIndexOfPort)
            return true
        }

        return false
    }

    @discardableResult
    mutating func removeFragmentComponentIfPresent() -> Bool {
        if let index = firstIndex(of: "#") {
            self.removeSubrange(index...)
        }

        return false
    }

    @discardableResult
    mutating func removeQueryComponentIfPresent() -> Bool {
        if let index = firstIndex(of: "?") {
            self.removeSubrange(index...)
        }

        return false
    }

    @discardableResult
    mutating func replaceFirstOccurenceIfPresent<T: StringProtocol, U: StringProtocol>(
        of string: T,
        before index: Index? = nil,
        with replacement: U
    ) -> Bool {
        guard let range = range(of: string) else { return false }

        if let index = index, range.lowerBound >= index {
            return false
        }

        self.replaceSubrange(range, with: replacement)
        return true
    }
}
