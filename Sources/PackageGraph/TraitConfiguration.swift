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

/// The trait configuration.
public struct TraitConfiguration: Codable, Hashable {
    /// The traits to enable for the package.
    package var enabledTraits: Set<String>?

    /// Enables all traits of the package.
    package var enableAllTraits: Bool

    package init(
        enabledTraits: Set<String>? = nil,
        enableAllTraits: Bool = false
    ) {
        self.enabledTraits = enabledTraits
        self.enableAllTraits = enableAllTraits
    }
}
