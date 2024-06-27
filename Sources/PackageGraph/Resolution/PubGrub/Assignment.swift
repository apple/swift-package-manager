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

/// An assignment that is either decided upon during decision making or derived
/// from previously known incompatibilities during unit propagation.
///
/// All assignments store a term (a package identifier and a version
/// requirement) and a decision level, which represents the number of decisions
/// at or before it in the partial solution that caused it to be derived. This
/// is later used during conflict resolution to figure out how far back to jump
/// when a conflict is found.
public struct Assignment: Equatable {
    public let term: Term
    public let decisionLevel: Int
    public let cause: Incompatibility?
    public let isDecision: Bool

    private init(
        term: Term,
        decisionLevel: Int,
        cause: Incompatibility?,
        isDecision: Bool
    ) {
        self.term = term
        self.decisionLevel = decisionLevel
        self.cause = cause
        self.isDecision = isDecision
    }

    /// An assignment made during decision making.
    public static func decision(_ term: Term, decisionLevel: Int) -> Assignment {
        assert(
            term.requirement.isExact,
            "Cannot create a decision assignment with a non-exact version selection: \(term.requirement)"
        )

        return self.init(
            term: term,
            decisionLevel: decisionLevel,
            cause: nil,
            isDecision: true
        )
    }

    /// An assignment derived from previously known incompatibilities during
    /// unit propagation.
    public static func derivation(
        _ term: Term,
        cause: Incompatibility,
        decisionLevel: Int
    ) -> Assignment {
        self.init(
            term: term,
            decisionLevel: decisionLevel,
            cause: cause,
            isDecision: false
        )
    }
}

extension Assignment: CustomStringConvertible {
    public var description: String {
        switch self.isDecision {
        case true:
            "[Decision \(self.decisionLevel): \(self.term)]"
        case false:
            "[Derivation: \(self.term) ← \(self.cause?.description ?? "-")]"
        }
    }
}
