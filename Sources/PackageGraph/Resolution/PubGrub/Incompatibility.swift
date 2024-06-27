//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import OrderedCollections
import PackageModel

/// A set of terms that are incompatible with each other and can therefore not
/// all be true at the same time. In dependency resolution, these are derived
/// from version requirements and when running into unresolvable situations.
public struct Incompatibility: Equatable, Hashable {
    public let terms: OrderedCollections.OrderedSet<Term>
    public let cause: Cause

    public init(terms: OrderedCollections.OrderedSet<Term>, cause: Cause) {
        self.terms = terms
        self.cause = cause
    }

    public init(_ terms: Term..., root: DependencyResolutionNode, cause: Cause = .root) throws {
        let termSet = OrderedCollections.OrderedSet(terms)
        try self.init(termSet, root: root, cause: cause)
    }

    public init(_ terms: OrderedCollections.OrderedSet<Term>, root: DependencyResolutionNode, cause: Cause) throws {
        if terms.isEmpty {
            self.init(terms: terms, cause: cause)
            return
        }

        // Remove the root package from generated incompatibilities, since it will
        // always be selected.
        var terms = terms
        if terms.count > 1, cause.isConflict,
           terms.contains(where: { $0.isPositive && $0.node == root })
        {
            terms = OrderedSet(terms.filter { !$0.isPositive || $0.node != root })
        }

        let normalizedTerms = try normalize(terms: terms.elements)
        guard normalizedTerms.count > 0 else {
            throw InternalError("An incompatibility must contain at least one term after normalization.")
        }
        self.init(terms: OrderedSet(normalizedTerms), cause: cause)
    }
}

extension Incompatibility: CustomStringConvertible {
    public var description: String {
        let terms = self.terms
            .map(String.init)
            .joined(separator: ", ")
        return "{\(terms)}"
    }
}

extension Incompatibility {
    /// Every incompatibility has a cause to explain its presence in the
    /// derivation graph. Only the root incompatibility uses `.root`. All other
    /// incompatibilities are either obtained from dependency constraints,
    /// decided upon in decision making or derived during unit propagation or
    /// conflict resolution.
    /// Using this information we can build up a derivation graph by following
    /// the tree of causes. All leaf nodes are external dependencies and all
    /// internal nodes are derived incompatibilities.
    ///
    /// An example graph could look like this:
    /// ```
    /// ┌────────────────────────────┐ ┌────────────────────────────┐
    /// │{foo ^1.0.0, not bar ^2.0.0}│ │{bar ^2.0.0, not baz ^3.0.0}│
    /// └─────────────┬──────────────┘ └──────────────┬─────────────┘
    ///               │      ┌────────────────────────┘
    ///               ▼      ▼
    /// ┌─────────────┴──────┴───────┐ ┌────────────────────────────┐
    /// │{foo ^1.0.0, not baz ^3.0.0}│ │{root 1.0.0, not foo ^1.0.0}│
    /// └─────────────┬──────────────┘ └──────────────┬─────────────┘
    ///               │   ┌───────────────────────────┘
    ///               ▼   ▼
    ///         ┌─────┴───┴──┐
    ///         │{root 1.0.0}│
    ///         └────────────┘
    /// ```
    public indirect enum Cause: Equatable, Hashable {
        public struct ConflictCause: Hashable {
            public let conflict: Incompatibility
            public let other: Incompatibility
        }

        /// The root incompatibility.
        case root

        /// The incompatibility represents a package's dependency on another
        /// package.
        case dependency(node: DependencyResolutionNode)

        /// The incompatibility was derived from two others during conflict
        /// resolution.
        case conflict(cause: ConflictCause)

        /// There exists no version to fulfill the specified requirement.
        case noAvailableVersion

        /// A version-based dependency contains unversioned-based dependency.
        case versionBasedDependencyContainsUnversionedDependency(
            versionedDependency: PackageReference,
            unversionedDependency: PackageReference
        )

        /// The package's tools version is incompatible.
        case incompatibleToolsVersion(ToolsVersion)

        public var isConflict: Bool {
            if case .conflict = self { return true }
            return false
        }

        /// Returns whether this cause can be represented in a single line of the
        /// error output.
        public var isSingleLine: Bool {
            guard case .conflict(let cause) = self else {
                assertionFailure("unreachable")
                return false
            }
            return !cause.conflict.cause.isConflict && !cause.other.cause.isConflict
        }
    }
}

/// Normalize terms so that at most one term refers to one package/polarity
/// combination. E.g. we don't want both a^1.0.0 and a^1.5.0 to be terms in the
/// same incompatibility, but have these combined by intersecting their version
/// requirements to a^1.5.0.
private func normalize(terms: [Term]) throws -> [Term] {
    let dict = try terms.reduce(into: OrderedCollections.OrderedDictionary<DependencyResolutionNode, (req: VersionSetSpecifier, polarity: Bool)>()) {
        res, term in
        // Don't try to intersect if this is the first time we're seeing this package.
        guard let previous = res[term.node] else {
            res[term.node] = (term.requirement, term.isPositive)
            return
        }

        guard let intersection = term.intersect(withRequirement: previous.req, andPolarity: previous.polarity) else {
            throw InternalError("""
            Attempting to create an incompatibility with terms for \(term.node) \
            intersecting versions \(previous) and \(term.requirement). These are \
            mutually exclusive and can't be intersected, making this incompatibility \
            irrelevant.
            """)
        }
        res[term.node] = (intersection.requirement, intersection.isPositive)
    }
    return dict.map { Term(node: $0, requirement: $1.req, isPositive: $1.polarity) }
}
