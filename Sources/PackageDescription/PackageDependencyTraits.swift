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

extension Package.Dependency {
    /// A struct representing an enabled trait of a dependency.
    @available(_PackageDescription, introduced: 6.0)
    public struct Trait: Hashable, ExpressibleByStringLiteral {
        /// Enables all default traits of a package.
        public static let defaults = Self.init(name: "defaults")

        /// A condition that limits the application of a dependencies trait.
        public struct Condition: Hashable {
            /// The set of traits that enable the dependencies trait.
            let traits: Set<String>?

            /// Creates a package dependency trait condition.
            ///
            /// - Parameter traits: The set of traits that enable the dependencies trait. If any of the traits are enabled on this package
            /// the dependencies trait will be enabled.
            public static func when(
                traits: Set<String>
            ) -> Self? {
                return !traits.isEmpty ? Self(traits: traits) : .none
            }
        }

        /// The name of the enabled trait.
        public var name: String

        /// The condition under which the trait is enabled.
        public var condition: Condition?

        /// Initializes a new enabled trait.
        ///
        /// - Parameters:
        ///   - name: The name of the enabled trait.
        ///   - condition: The condition under which the trait is enabled.
        public init(name: String, condition: Condition? = nil) {
            self.name = name
            self.condition = condition
        }

        public init(stringLiteral value: StringLiteralType) {
            self.init(name: value)
        }
    }
}
