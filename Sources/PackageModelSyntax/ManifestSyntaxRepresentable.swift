//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import SwiftSyntax

/// Describes an entity in the package model that can be represented as
/// a syntax node.
protocol ManifestSyntaxRepresentable {
    /// The most specific kind of syntax node that best describes this entity
    /// in the manifest.
    ///
    /// There might be other kinds of syntax nodes that can also represent
    /// the syntax, but this is the one that a canonical manifest will use.
    /// As an example, a package dependency is usually expressed as, e.g.,
    ///     .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "510.0.1")
    ///
    /// However, there could be other forms, e.g., this is also valid:
    ///     Package.Dependency.package(url: "https://github.com/swiftlang/swift-syntax.git", from: "510.0.1")
    associatedtype PreferredSyntax: SyntaxProtocol

    /// Provides a suitable syntax node to describe this entity in the package
    /// model.
    ///
    /// The resulting syntax is a fragment that describes just this entity,
    /// and it's enclosing entity will need to understand how to fit it in.
    /// For example, a `PackageDependency` entity would map to syntax for
    /// something like
    ///     .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "510.0.1")
    func asSyntax() -> PreferredSyntax
}

extension String: ManifestSyntaxRepresentable {
    typealias PreferredSyntax = ExprSyntax

    func asSyntax() -> ExprSyntax { "\(literal: self)" }
}
