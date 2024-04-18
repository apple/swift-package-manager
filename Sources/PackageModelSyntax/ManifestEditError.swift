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

import SwiftSyntax

/// An error describing problems that can occur when attempting to edit a
/// package manifest programattically.
package enum ManifestEditError: Error {
    case cannotFindPackage
    case cannotFindArrayLiteralArgument(argumentName: String, node: Syntax)
}

extension ManifestEditError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .cannotFindPackage:
            "invalid manifest: unable to find 'Package' declaration"
        case .cannotFindArrayLiteralArgument(argumentName: let name, node: _):
            "unable to find array literal for '\(name)' argument"
        }
    }
}
