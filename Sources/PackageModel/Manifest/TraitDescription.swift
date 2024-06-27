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

public struct TraitDescription: Sendable, Hashable, Codable, ExpressibleByStringLiteral {
    /// The trait's canonical name.
    ///
    /// This is used when enabling the trait or when referring to it from other modifiers in the manifest.
    public var name: String

    /// The trait's description.
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
}
