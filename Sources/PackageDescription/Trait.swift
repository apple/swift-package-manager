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

/// A struct representing a package's trait.
///
/// Traits can be used for expressing conditional compilation and optional dependencies.
///
/// - Important: Traits must be strictly additive and enabling a trait **must not** remove API.
@_spi(ExperimentalTraits)
@available(_PackageDescription, introduced: 999.0)
public struct Trait: Hashable, ExpressibleByStringLiteral {
    /// Declares the default traits for this package.
    public static func `default`(enabledTraits: Set<String>) -> Self {
        .init(
            name: "default",
            description: "The default traits of this package.",
            enabledTraits: enabledTraits
        )
    }

    /// The trait's canonical name.
    ///
    /// This is used when enabling the trait or when referring to it from other modifiers in the manifest.
    ///
    /// The following rules are enforced on trait names:
    /// - The first character must be a [Unicode XID start character](https://unicode.org/reports/tr31/#Figure_Code_Point_Categories_for_Identifier_Parsing)
    /// (most letters), a digit, or `_`.
    /// - Subsequent characters must be a [Unicode XID continue character](https://unicode.org/reports/tr31/#Figure_Code_Point_Categories_for_Identifier_Parsing)
    /// (a digit, `_`, or most letters), `-`, or `+`.
    /// - `default` and `defaults` (in any letter casing combination) are not allowed as trait names to avoid confusion with default traits.
    public var name: String

    /// The trait's description.
    ///
    /// Use this to explain what functionality this trait enables.
    public var description: String?

    /// A set of other traits of this package that this trait enables.
    public var enabledTraits: Set<String>

    /// Initializes a new trait.
    ///
    /// - Parameters:
    ///   - name: The trait's canonical name.
    ///   - description: The trait's description.
    ///   - enabledTraits: A set of other traits of this package that this trait enables.
    public init(
        name: String,
        description: String? = nil,
        enabledTraits: Set<String> = []
    ) {
        self.name = name
        self.description = description
        self.enabledTraits = enabledTraits
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(name: value)
    }

    /// Initializes a new trait.
    ///
    /// - Parameters:
    ///   - name: The trait's canonical name.
    ///   - description: The trait's description.
    ///   - enabledTraits: A set of other traits of this package that this trait enables.
    public static func trait(
        name: String,
        description: String? = nil,
        enabledTraits: Set<String> = []
    ) -> Trait {
        .init(
            name: name,
            description: description,
            enabledTraits: enabledTraits
        )
    }
}
