//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2019-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

struct DiagnosticReportBuilder {
    let rootNode: DependencyResolutionNode
    let incompatibilities: [DependencyResolutionNode: [Incompatibility]]

    private var lines: [(number: Int, message: String)] = []
    private var derivations: [Incompatibility: Int] = [:]
    private var lineNumbers: [Incompatibility: Int] = [:]
    private let provider: ContainerProvider

    init(
        root: DependencyResolutionNode,
        incompatibilities: [DependencyResolutionNode: [Incompatibility]],
        provider: ContainerProvider
    ) {
        self.rootNode = root
        self.incompatibilities = incompatibilities
        self.provider = provider
    }

    mutating func makeErrorReport(for rootCause: Incompatibility) throws -> String {
        /// Populate `derivations`.
        func countDerivations(_ i: Incompatibility) {
            self.derivations[i, default: 0] += 1
            if case .conflict(let cause) = i.cause {
                countDerivations(cause.conflict)
                countDerivations(cause.other)
            }
        }

        countDerivations(rootCause)

        if rootCause.cause.isConflict {
            try self.visit(rootCause)
        } else {
            assertionFailure("Unimplemented")
            try self.record(
                rootCause,
                message: self.description(for: rootCause),
                isNumbered: false
            )
        }

        var content = ""
        let padding = self.lineNumbers.isEmpty ? 0 : "\(Array(self.lineNumbers.values).last!) ".count

        for (idx, line) in self.lines.enumerated() {
            content += String(repeating: " ", count: padding)
            if line.number != -1 {
                content += String(repeating: " ", count: padding)
                content += " (\(line.number)) "
            }
            content += line.message.prefix(1).capitalized
            content += line.message.dropFirst()

            if self.lines.count - 1 != idx {
                content += "\n"
            }
        }

        return content
    }

    private mutating func visit(
        _ incompatibility: Incompatibility,
        isConclusion: Bool = false
    ) throws {
        let isNumbered = isConclusion || self.derivations[incompatibility]! > 1
        let conjunction = isConclusion || incompatibility.cause == .root ? "As a result, " : ""
        let incompatibilityDesc = try description(for: incompatibility)

        guard case .conflict(let cause) = incompatibility.cause else {
            assertionFailure("\(incompatibility)")
            return
        }

        if cause.conflict.cause.isConflict && cause.other.cause.isConflict {
            let conflictLine = self.lineNumbers[cause.conflict]
            let otherLine = self.lineNumbers[cause.other]

            if let conflictLine, let otherLine {
                try self.record(
                    incompatibility,
                    message: "\(incompatibilityDesc) because \(self.description(for: cause.conflict)) (\(conflictLine)) and \(self.description(for: cause.other)) (\(otherLine).",
                    isNumbered: isNumbered
                )
            } else if conflictLine != nil || otherLine != nil {
                let withLine: Incompatibility
                let withoutLine: Incompatibility
                let line: Int
                if let conflictLine {
                    withLine = cause.conflict
                    withoutLine = cause.other
                    line = conflictLine
                } else {
                    withLine = cause.other
                    withoutLine = cause.conflict
                    line = otherLine!
                }

                try self.visit(withoutLine)
                try self.record(
                    incompatibility,
                    message: "\(conjunction)\(incompatibilityDesc) because \(self.description(for: withLine)) \(line).",
                    isNumbered: isNumbered
                )
            } else {
                let singleLineConflict = cause.conflict.cause.isSingleLine
                let singleLineOther = cause.other.cause.isSingleLine
                if singleLineOther || singleLineConflict {
                    let first = singleLineOther ? cause.conflict : cause.other
                    let second = singleLineOther ? cause.other : cause.conflict
                    try self.visit(first)
                    try self.visit(second)
                    self.record(
                        incompatibility,
                        message: "\(incompatibilityDesc).",
                        isNumbered: isNumbered
                    )
                } else {
                    try self.visit(cause.conflict, isConclusion: true)
                    try self.visit(cause.other)
                    try self.record(
                        incompatibility,
                        message: "\(conjunction)\(incompatibilityDesc) because \(self.description(for: cause.conflict)) (\(self.lineNumbers[cause.conflict]!)).",
                        isNumbered: isNumbered
                    )
                }
            }
        } else if cause.conflict.cause.isConflict || cause.other.cause.isConflict {
            let derived = cause.conflict.cause.isConflict ? cause.conflict : cause.other
            let ext = cause.conflict.cause.isConflict ? cause.other : cause.conflict
            let derivedLine = self.lineNumbers[derived]
            if let derivedLine {
                try self.record(
                    incompatibility,
                    message: "\(incompatibilityDesc) because \(self.description(for: ext)) and \(self.description(for: derived)) (\(derivedLine)).",
                    isNumbered: isNumbered
                )
            } else if self.isCollapsible(derived) {
                guard case .conflict(let derivedCause) = derived.cause else {
                    assertionFailure("unreachable")
                    return
                }

                let collapsedDerived = derivedCause.conflict.cause.isConflict ? derivedCause.conflict : derivedCause
                    .other
                let collapsedExt = derivedCause.conflict.cause.isConflict ? derivedCause.other : derivedCause.conflict

                try self.visit(collapsedDerived)
                try self.record(
                    incompatibility,
                    message: "\(conjunction)\(incompatibilityDesc) because \(self.description(for: collapsedExt)) and \(self.description(for: ext)).",
                    isNumbered: isNumbered
                )
            } else {
                try self.visit(derived)
                try self.record(
                    incompatibility,
                    message: "\(conjunction)\(incompatibilityDesc) because \(self.description(for: ext)).",
                    isNumbered: isNumbered
                )
            }
        } else {
            try self.record(
                incompatibility,
                message: "\(incompatibilityDesc) because \(self.description(for: cause.conflict)) and \(self.description(for: cause.other)).",
                isNumbered: isNumbered
            )
        }
    }

    private func description(for incompatibility: Incompatibility) throws -> String {
        switch incompatibility.cause {
        case .dependency(let causeNode):
            assert(incompatibility.terms.count == 2)
            let depender = incompatibility.terms.first!
            let dependee = incompatibility.terms.last!
            assert(depender.isPositive)
            assert(!dependee.isPositive)

            let dependerDesc: String
            // when depender is the root node, the causeNode may be different as it may represent root's indirect dependencies (e.g. dependencies of root's unversioned dependencies)
            if depender.node == self.rootNode, causeNode != self.rootNode {
                dependerDesc = causeNode.nameForDiagnostics
            } else {
                dependerDesc = try self.description(for: depender, normalizeRange: true)
            }
            let dependeeDesc = try description(for: dependee)
            return "\(dependerDesc) depends on \(dependeeDesc)"
        case .noAvailableVersion:
            assert(incompatibility.terms.count == 1)
            let term = incompatibility.terms.first!
            assert(term.isPositive)
            return "no versions of \(term.node.nameForDiagnostics) match the requirement \(term.requirement)"
        case .root:
            // FIXME: This will never happen I think.
            assert(incompatibility.terms.count == 1)
            let term = incompatibility.terms.first!
            assert(term.isPositive)
            return "\(term.node.nameForDiagnostics) is \(term.requirement)"
        case .conflict where incompatibility.terms.count == 1 && incompatibility.terms.first?.node == self.rootNode:
            return "dependencies could not be resolved"
        case .conflict:
            break
        case .versionBasedDependencyContainsUnversionedDependency(let versionedDependency, let unversionedDependency):
            return "package '\(versionedDependency.identity)' is required using a stable-version but '\(versionedDependency.identity)' depends on an unstable-version package '\(unversionedDependency.identity)'"
        case .incompatibleToolsVersion(let version):
            let term = incompatibility.terms.first!
            return try "\(self.description(for: term, normalizeRange: true)) contains incompatible tools version (\(version))"
        }

        let terms = incompatibility.terms
        if terms.count == 1 {
            let term = terms.first!
            let prefix = try hasEffectivelyAnyRequirement(term) ? term.node.nameForDiagnostics : self.description(
                for: term,
                normalizeRange: true
            )
            return "\(prefix) " + (term.isPositive ? "cannot be used" : "is required")
        } else if terms.count == 2 {
            let term1 = terms.first!
            let term2 = terms.last!
            if term1.isPositive == term2.isPositive {
                if term1.isPositive {
                    return "\(term1.node.nameForDiagnostics) is incompatible with \(term2.node.nameForDiagnostics)"
                } else {
                    return "either \(term1.node.nameForDiagnostics) or \(term2)"
                }
            }
        }

        let positive = try terms.filter(\.isPositive).map { try self.description(for: $0) }
        let negative = try terms.filter { !$0.isPositive }.map { try self.description(for: $0) }
        if !positive.isEmpty, !negative.isEmpty {
            if positive.count == 1 {
                let positiveTerm = terms.first { $0.isPositive }!
                return try "\(self.description(for: positiveTerm, normalizeRange: true)) practically depends on \(negative.joined(separator: " or "))"
            } else {
                return "if \(positive.joined(separator: " and ")) then \(negative.joined(separator: " or "))"
            }
        } else if !positive.isEmpty {
            return "one of \(positive.joined(separator: " or ")) must be true"
        } else {
            return "one of \(negative.joined(separator: " or ")) must be true"
        }
    }

    /// Returns true if the requirement on this term is effectively "any" because of either the actual
    /// `any` requirement or because the version range is large enough to fit all current available versions.
    private func hasEffectivelyAnyRequirement(_ term: Term) throws -> Bool {
        switch term.requirement {
        case .any:
            return true
        case .empty, .exact, .ranges:
            return false
        case .range(let range):
            // container expected to be cached at this point
            guard let container = try? provider.getCachedContainer(for: term.node.package) else {
                return false
            }
            let bounds = try container.computeBounds(for: range)
            return !bounds.includesLowerBound && !bounds.includesUpperBound
        }
    }

    private func isCollapsible(_ incompatibility: Incompatibility) -> Bool {
        if self.derivations[incompatibility]! > 1 {
            return false
        }

        guard case .conflict(let cause) = incompatibility.cause else {
            assertionFailure("unreachable")
            return false
        }

        if cause.conflict.cause.isConflict, cause.other.cause.isConflict {
            return false
        }

        if !cause.conflict.cause.isConflict, !cause.other.cause.isConflict {
            return false
        }

        let complex = cause.conflict.cause.isConflict ? cause.conflict : cause.other
        return !self.lineNumbers.keys.contains(complex)
    }

    private func description(for term: Term, normalizeRange: Bool = false) throws -> String {
        let name = term.node.nameForDiagnostics

        switch term.requirement {
        case .any: return name
        case .empty: return "no version of \(name)"
        case .exact(let version):
            // For the root package, don't output the useless version 1.0.0.
            if term.node == self.rootNode {
                return "root"
            }
            return "\(name) \(version)"
        case .range(let range):
            // container expected to be cached at this point
            guard normalizeRange, let container = try? provider.getCachedContainer(for: term.node.package) else {
                return "\(name) \(range.description)"
            }

            switch try container.computeBounds(for: range) {
            case (true, true):
                return "\(name) \(range.description)"
            case (false, false):
                return name
            case (true, false):
                return "\(name) >= \(range.lowerBound)"
            case (false, true):
                return "\(name) < \(range.upperBound)"
            }
        case .ranges(let ranges):
            let ranges = "{" + ranges.map {
                if $0.lowerBound == $0.upperBound {
                    return $0.lowerBound.description
                }
                return $0.lowerBound.description + "..<" + $0.upperBound.description
            }.joined(separator: ", ") + "}"
            return "\(name) \(ranges)"
        }
    }

    /// Write a given output message to a stream. The message should describe
    /// the incompatibility and how it as derived. If `isNumbered` is true, a
    /// line number will be assigned to this incompatibility so that it can be
    /// referred to again.
    private mutating func record(
        _ incompatibility: Incompatibility,
        message: String,
        isNumbered: Bool
    ) {
        var number = -1
        if isNumbered {
            number = self.lineNumbers.count + 1
            self.lineNumbers[incompatibility] = number
        }
        let line = (number: number, message: message)
        if isNumbered {
            self.lines.append(line)
        } else {
            self.lines.insert(line, at: 0)
        }
    }
}

extension DependencyResolutionNode {
    fileprivate var nameForDiagnostics: String {
        "'\(self.package.identity)'"
    }
}
