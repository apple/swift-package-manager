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

import struct TSCUtility.Version

/// The partial solution is a constantly updated solution used throughout the
/// dependency resolution process, tracking known assignments.
public struct PartialSolution {
    var root: DependencyResolutionNode?

    /// All known assignments.
    public private(set) var assignments: [Assignment]

    /// All known decisions.
    public private(set) var decisions: [DependencyResolutionNode: Version] = [:]

    /// The intersection of all positive assignments for each package, minus any
    /// negative assignments that refer to that package.
    public private(set) var _positive: OrderedCollections.OrderedDictionary<DependencyResolutionNode, Term> = [:]

    /// Union of all negative assignments for a package.
    ///
    /// Only present if a package has no positive assignment.
    public private(set) var _negative: [DependencyResolutionNode: Term] = [:]

    /// The current decision level.
    public var decisionLevel: Int {
        self.decisions.count - 1
    }

    public init(assignments: [Assignment] = []) {
        self.assignments = assignments
        for assignment in assignments {
            self.register(assignment)
        }
    }

    /// A list of all packages that have been assigned, but are not yet satisfied.
    public var undecided: [Term] {
        self._positive.values.filter { !self.decisions.keys.contains($0.node) }
    }

    /// Create a new derivation assignment and add it to the partial solution's
    /// list of known assignments.
    public mutating func derive(_ term: Term, cause: Incompatibility) {
        let derivation = Assignment.derivation(term, cause: cause, decisionLevel: self.decisionLevel)
        self.assignments.append(derivation)
        self.register(derivation)
    }

    /// Create a new decision assignment and add it to the partial solution's
    /// list of known assignments.
    public mutating func decide(_ node: DependencyResolutionNode, at version: Version) {
        self.decisions[node] = version
        let term = Term(node, .exact(version))
        let decision = Assignment.decision(term, decisionLevel: self.decisionLevel)
        self.assignments.append(decision)
        self.register(decision)
    }

    /// Populates the _positive and _negative properties with the assignment.
    private mutating func register(_ assignment: Assignment) {
        let term = assignment.term
        let pkg = term.node

        if let positive = _positive[pkg] {
            self._positive[term.node] = positive.intersect(with: term)
            return
        }

        let newTerm = self._negative[pkg].flatMap { term.intersect(with: $0) } ?? term

        if newTerm.isPositive {
            self._negative[pkg] = nil
            self._positive[pkg] = newTerm
        } else {
            self._negative[pkg] = newTerm
        }
    }

    /// Returns the first Assignment in this solution such that the list of
    /// assignments up to and including that entry satisfies term.
    public func satisfier(for term: Term) throws -> Assignment {
        var assignedTerm: Term?

        for assignment in self.assignments {
            guard assignment.term.node == term.node else {
                continue
            }
            assignedTerm = assignedTerm.flatMap { $0.intersect(with: assignment.term) } ?? assignment.term

            if assignedTerm!.satisfies(term) {
                return assignment
            }
        }

        throw InternalError("term \(term) not satisfied")
    }

    /// Backtrack to a specific decision level by dropping all assignments with
    /// a decision level which is greater.
    public mutating func backtrack(toDecisionLevel decisionLevel: Int) {
        var toBeRemoved: [(Int, Assignment)] = []

        for (idx, assignment) in zip(0..., self.assignments) {
            if assignment.decisionLevel > decisionLevel {
                toBeRemoved.append((idx, assignment))
            }
        }

        for (idx, remove) in toBeRemoved.reversed() {
            let assignment = self.assignments.remove(at: idx)
            if assignment.isDecision {
                self.decisions.removeValue(forKey: remove.term.node)
            }
        }

        // FIXME: We can optimize this by recomputing only the removed things.
        self._negative.removeAll()
        self._positive.removeAll()
        for assignment in self.assignments {
            self.register(assignment)
        }
    }

    /// Returns true if the given term satisfies the partial solution.
    func satisfies(_ term: Term) -> Bool {
        self.relation(with: term) == .subset
    }

    /// Returns the set relation of the partial solution with the given term.
    func relation(with term: Term) -> Term.SetRelation {
        let pkg = term.node
        if let positive = _positive[pkg] {
            return positive.relation(with: term)
        } else if let negative = _negative[pkg] {
            return negative.relation(with: term)
        }
        return .overlap
    }
}
