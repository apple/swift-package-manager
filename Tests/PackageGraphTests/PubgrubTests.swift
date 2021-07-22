/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
@testable import PackageGraph
import PackageLoading
@testable import PackageModel
import SourceControl
import TSCBasic
import XCTest

// There's some useful helper utilities defined below for easier testing:
//
// Terms conform to ExpressibleByStringLiteral in this test module and their
// version requirements can be created with a few options:
//   - "package@1.0.0": equivalent to .exact("1.0.0")
//   - "package^1.0.0": equivalent to .upToNextMajor("1.0.0")
//   - "package-1.0.0-3.0.0": equivalent to .range("1.0.0"..<"3.0.0")
//
// Mocking a dependency graph is easily achieved by using the builder API. It's
// a global object in this module.
//   builder.serve(dependencies: dependencies...)
// or for dependencies
//   builder.serve("packageName", at: someVersion, with: dependencies...)
// Calling builder.create() returns a resolver which can then be used to start
// the resolution by calling .solve() on it and passing a reference to the root
// package.
//
// The functions (AssertBindings,) AssertResult, AssertRootCause & AssertError
// can be used for checking the success or error outcomes of the resolver
// without having to manually pull the bindings or errors out of
// the results. They also offer useful failure messages.

let builder = DependencyGraphBuilder()

private let emptyProvider = MockProvider(containers: [])

private let v1: Version = "1.0.0"
private let v1_1: Version = "1.1.0"
private let v1_5: Version = "1.5.0"
private let v2: Version = "2.0.0"
private let v3: Version = "3.0.0"
private let v1Range: VersionSetSpecifier = .range(v1..<v2)
private let v1_5Range: VersionSetSpecifier = .range(v1_5..<v2)
private let v1to3Range: VersionSetSpecifier = .range(v1..<v3)
private let v2Range: VersionSetSpecifier = .range(v2..<v3)

let aRef = PackageReference.remote(identity: PackageIdentity("a"), location: "")
let bRef = PackageReference.remote(identity: PackageIdentity("b"), location: "")
let cRef = PackageReference.remote(identity: PackageIdentity("c"), location: "")

let rootRef = PackageReference.root(identity: PackageIdentity("root"), path: .root)
let rootNode = DependencyResolutionNode.root(package: rootRef)
let rootCause = try! Incompatibility(Term(rootNode, .exact(v1)), root: rootNode)
let _cause = try! Incompatibility("cause@0.0.0", root: rootNode)

final class PubgrubTests: XCTestCase {
    func testTermInverse() {
        let a = Term("a@1.0.0")
        XCTAssertFalse(a.inverse.isPositive)
        XCTAssertTrue(a.inverse.inverse.isPositive)
    }

    func testTermSatisfies() {
        let a100 = Term("a@1.0.0")

        XCTAssertTrue(a100.satisfies(a100))
        XCTAssertFalse(a100.satisfies("¬a@1.0.0"))
        XCTAssertTrue(a100.satisfies("a^1.0.0"))
        XCTAssertFalse(a100.satisfies("¬a^1.0.0"))
        XCTAssertFalse(a100.satisfies("a^2.0.0"))

        XCTAssertFalse(Term("¬a@1.0.0").satisfies("¬a^1.0.0"))
        XCTAssertFalse(Term("¬a@1.0.0").satisfies("a^2.0.0"))
        XCTAssertTrue(Term("¬a^1.0.0").satisfies("¬a@1.0.0"))
        XCTAssertTrue(Term("a^2.0.0").satisfies("¬a@1.0.0"))

        XCTAssertTrue(Term("a^1.0.0").satisfies("¬a@2.0.0"))
        XCTAssertTrue(Term("a^1.0.0").satisfies("¬a^2.0.0"))

        XCTAssertTrue(Term("a^1.0.0").satisfies(Term("a^1.0.0")))
        XCTAssertTrue(Term("a-1.0.0-1.1.0").satisfies(Term("a^1.0.0")))
        XCTAssertFalse(Term("a-1.0.0-1.1.0").satisfies(Term("a^2.0.0")))
    }

    func _testTermIntersection() {
        // a^1.0.0 ∩ ¬a@1.5.0 → a >=1.0.0 <1.5.0
        XCTAssertEqual(
            Term("a^1.0.0").intersect(with: Term("¬a@1.5.0")),
            Term("a-1.0.0-1.5.0"))

        // a^1.0.0 ∩ a >=1.5.0 <3.0.0 → a^1.5.0
        XCTAssertEqual(
            Term("a^1.0.0").intersect(with: Term("a-1.5.0-3.0.0")),
            Term("a^1.5.0"))

        // ¬a^1.0.0 ∩ ¬a >=1.5.0 <3.0.0 → ¬a >=1.0.0 <3.0.0
        XCTAssertEqual(
            Term("¬a^1.0.0").intersect(with: Term("¬a-1.5.0-3.0.0")),
            Term("¬a-1.0.0-3.0.0"))

        XCTAssertEqual(
            Term("a^1.0.0").intersect(with: Term("a^1.0.0")),
            Term("a^1.0.0"))

        XCTAssertEqual(
            Term("¬a^1.0.0").intersect(with: Term("¬a^1.0.0")),
            Term("¬a^1.0.0"))

        XCTAssertNil(Term("a^1.0.0").intersect(with: Term("¬a^1.0.0")))
        XCTAssertNil(Term("a@1.0.0").difference(with: Term("a@1.0.0")))

        XCTAssertEqual(
            Term("¬a^1.0.0").intersect(with: Term("a^2.0.0")),
            Term("a^2.0.0"))

        XCTAssertEqual(
            Term("a^2.0.0").intersect(with: Term("¬a^1.0.0")),
            Term("a^2.0.0"))

        XCTAssertEqual(
            Term("¬a^1.0.0").intersect(with: Term("¬a^1.0.0")),
            Term("¬a^1.0.0"))

        XCTAssertEqual(
            Term("¬a@1.0.0").intersect(with: Term("¬a@1.0.0")),
            Term("¬a@1.0.0"))

        // Check difference.
        let anyA = Term(.empty(package: "a"), .any)
        XCTAssertNil(Term("a^1.0.0").difference(with: anyA))

        let notEmptyA = Term(not: .empty(package: "a"), .empty)
        XCTAssertNil(Term("a^1.0.0").difference(with: notEmptyA))
    }

    func testTermRelation() {
        // Both positive.
        XCTAssertEqual(Term("a^1.1.0").relation(with: "a^1.0.0"), .subset)
        XCTAssertEqual(Term("a^1.9.0").relation(with: "a^1.8.9"), .subset)
        XCTAssertEqual(Term("a^1.5.0").relation(with: "a^1.0.0"), .subset)
        XCTAssertEqual(Term("a^1.9.0").relation(with: "a@1.9.0"), .overlap)
        XCTAssertEqual(Term("a^1.9.0").relation(with: "a@1.9.1"), .overlap)
        XCTAssertEqual(Term("a^1.9.0").relation(with: "a@1.20.0"), .overlap)
        XCTAssertEqual(Term("a^2.0.0").relation(with: "a^2.9.0"), .overlap)
        XCTAssertEqual(Term("a^2.0.0").relation(with: "a^2.9.0"), .overlap)
        XCTAssertEqual(Term("a-1.5.0-3.0.0").relation(with: "a^1.0.0"), .overlap)
        XCTAssertEqual(Term("a^1.9.0").relation(with: "a@1.8.1"), .disjoint)
        XCTAssertEqual(Term("a^1.9.0").relation(with: "a@2.0.0"), .disjoint)
        XCTAssertEqual(Term("a^2.0.0").relation(with: "a@1.0.0"), .disjoint)

        // First term is negative, second term is positive.
        XCTAssertEqual(Term("¬a^1.0.0").relation(with: "a@1.5.0"), .disjoint)
        XCTAssertEqual(Term("¬a^1.5.0").relation(with: "a^1.0.0"), .overlap)
        XCTAssertEqual(Term("¬a^2.0.0").relation(with: "a^1.5.0"), .overlap)

        // First term is positive, second term is negative.
        XCTAssertEqual(Term("a^2.0.0").relation(with: "¬a^1.0.0"), .subset)
        XCTAssertEqual(Term("a^1.5.0").relation(with: "¬a^1.0.0"), .disjoint)
        XCTAssertEqual(Term("a^1.0.0").relation(with: "¬a^1.5.0"), .overlap)
        XCTAssertEqual(Term("a-1.0.0-2.0.0").relation(with: "¬a-1.0.0-1.2.0"), .overlap)

        // Both terms are negative.
        XCTAssertEqual(Term("¬a^1.0.0").relation(with: "¬a^1.5.0"), .subset)
        XCTAssertEqual(Term("¬a^2.0.0").relation(with: "¬a^1.0.0"), .overlap)
        XCTAssertEqual(Term("¬a^1.5.0").relation(with: "¬a^1.0.0"), .overlap)
    }

    func testTermIsValidDecision() {
        let solution100_150 = PartialSolution(assignments: [
            .derivation("a^1.0.0", cause: _cause, decisionLevel: 1),
            .derivation("a^1.5.0", cause: _cause, decisionLevel: 2)
        ])

        let allSatisfied = Term("a@1.6.0")
        XCTAssertTrue(allSatisfied.isValidDecision(for: solution100_150))
        let partiallySatisfied = Term("a@1.2.0")
        XCTAssertFalse(partiallySatisfied.isValidDecision(for: solution100_150))
    }

    func testIncompatibilityNormalizeTermsOnInit() throws {
        let i1 = try Incompatibility(Term("a^1.0.0"), Term("a^1.5.0"), Term("¬b@1.0.0"),
                                 root: rootNode)
        XCTAssertEqual(i1.terms.count, 2)
        let a1 = i1.terms.first { $0.node.package == "a" }
        let b1 = i1.terms.first { $0.node.package == "b" }
        XCTAssertEqual(a1?.requirement, v1_5Range)
        XCTAssertEqual(b1?.requirement, .exact(v1))

        let i2 = try Incompatibility(Term("¬a^1.0.0"), Term("a^2.0.0"),
                                 root: rootNode)
        XCTAssertEqual(i2.terms.count, 1)
        let a2 = i2.terms.first
        XCTAssertEqual(a2?.requirement, v2Range)
    }

    func testSolutionPositive() {
        let s1 = PartialSolution(assignments:[
            .derivation("a^1.5.0", cause: _cause, decisionLevel: 0),
            .derivation("b@2.0.0", cause: _cause, decisionLevel: 0),
            .derivation("a^1.0.0", cause: _cause, decisionLevel: 0)
        ])
        let a1 = s1._positive.first { $0.key.package.identity == PackageIdentity("a") }?.value
        XCTAssertEqual(a1?.requirement, v1_5Range)
        let b1 = s1._positive.first { $0.key.package.identity == PackageIdentity("b") }?.value
        XCTAssertEqual(b1?.requirement, .exact(v2))

        let s2 = PartialSolution(assignments: [
            .derivation("¬a^1.5.0", cause: _cause, decisionLevel: 0),
            .derivation("a^1.0.0", cause: _cause, decisionLevel: 0)
        ])
        let a2 = s2._positive.first { $0.key.package.identity == PackageIdentity("a") }?.value
        XCTAssertEqual(a2?.requirement, .range(v1..<v1_5))
    }

    func testSolutionUndecided() {
        var solution = PartialSolution()
        solution.derive("a^1.0.0", cause: rootCause)
        solution.decide(.empty(package: "b"), at: v2)
        solution.derive("a^1.5.0", cause: rootCause)
        solution.derive("¬c^1.5.0", cause: rootCause)
        solution.derive("d^1.9.0", cause: rootCause)
        solution.derive("d^1.9.9", cause: rootCause)

        let undecided = solution.undecided.sorted{ $0.node.package.identity < $1.node.package.identity }
        XCTAssertEqual(undecided, [Term("a^1.5.0"), Term("d^1.9.9")])
    }

    func testSolutionAddAssignments() {
        let root = Term(rootNode, .exact("1.0.0"))
        let a = Term("a@1.0.0")
        let b = Term("b@2.0.0")

        var solution = PartialSolution(assignments: [])
        solution.decide(rootNode, at: v1)
        solution.decide(.product("a", package: aRef), at: v1)
        solution.derive(b, cause: _cause)
        XCTAssertEqual(solution.decisionLevel, 1)

        XCTAssertEqual(solution.assignments, [
            .decision(root, decisionLevel: 0),
            .decision(a, decisionLevel: 1),
            .derivation(b, cause: _cause, decisionLevel: 1)
        ])
        XCTAssertEqual(solution.decisions, [
            rootNode: v1,
            .product("a", package: aRef): v1,
        ])
    }

    func testSolutionBacktrack() {
        // TODO: This should probably add derivations to cover that logic as well.
        var solution = PartialSolution()
        solution.decide(.empty(package: aRef), at: v1)
        solution.decide(.empty(package: bRef), at: v1)
        solution.decide(.empty(package: cRef), at: v1)

        XCTAssertEqual(solution.decisionLevel, 2)
        solution.backtrack(toDecisionLevel: 1)
        XCTAssertEqual(solution.assignments.count, 2)
        XCTAssertEqual(solution.decisionLevel, 1)
    }

    func testPositiveTerms() {
        let s1 = PartialSolution(assignments: [
            .derivation("a^1.0.0", cause: _cause, decisionLevel: 0),
        ])
        XCTAssertEqual(s1._positive[.product("a", package: "a")]?.requirement,
                       v1Range)

        let s2 = PartialSolution(assignments: [
            .derivation("a^1.0.0", cause: _cause, decisionLevel: 0),
            .derivation("a^1.5.0", cause: _cause, decisionLevel: 0)
        ])
        XCTAssertEqual(s2._positive[.product("a", package: "a")]?.requirement,
                       v1_5Range)
    }

    func testResolverAddIncompatibility() throws {
        let state = PubgrubDependencyResolver.State(root: rootNode)

        let a = try Incompatibility(Term("a@1.0.0"), root: rootNode)
        state.addIncompatibility(a, at: .topLevel)
        let ab = try Incompatibility(Term("a@1.0.0"), Term("b@2.0.0"), root: rootNode)
        state.addIncompatibility(ab, at: .topLevel)

        XCTAssertEqual(state.incompatibilities, [
            .product("a", package: "a"): [a, ab],
            .product("b", package: "b"): [ab],
        ])
    }

    func testUpdatePackageIdentifierAfterResolution() {
        let fooURL = "https://example.com/foo"
        let fooRef = PackageReference.remote(identity: PackageIdentity(url: fooURL), location: fooURL)
        let foo = MockContainer(package: fooRef, dependenciesByVersion: [v1: [:]])
        foo.manifestName = "bar"

        let provider = MockProvider(containers: [foo])

        let resolver = PubgrubDependencyResolver(provider: provider)
        let deps = builder.create(dependencies: [
            "foo": (.versionSet(v1Range), .specific(["foo"]))
        ])
        let result = resolver.solve(constraints: deps)

        switch result {
        case .failure(let error):
            XCTFail("Unexpected error: \(error)")
        case .success(let bindings):
            XCTAssertEqual(bindings.count, 1)
            let foo = bindings.first { $0.package.identity == PackageIdentity("foo") }
            XCTAssertEqual(foo?.package.name, "bar")
        }
    }

    func testResolverConflictResolution() throws  {
        let solver1 = PubgrubDependencyResolver(provider: emptyProvider)
        let state1 = PubgrubDependencyResolver.State(root: rootNode)

        let notRoot = try Incompatibility(Term(not: rootNode, .any),
                                      root: rootNode,
                                      cause: .root)
        state1.addIncompatibility(notRoot, at: .topLevel)
        XCTAssertThrowsError(try solver1.resolve(state: state1, conflict: notRoot))
    }

    func testResolverDecisionMaking() throws {
        let solver1 = PubgrubDependencyResolver(provider: emptyProvider)
        let state1 = PubgrubDependencyResolver.State(root: rootNode)

        // No decision can be made if no unsatisfied terms are available.
        XCTAssertNil(try tsc_await { solver1.makeDecision(state: state1, completion: $0) })

        let a = MockContainer(package: aRef, dependenciesByVersion: [
            "0.0.0": [:],
            v1: ["a": [(package: bRef, requirement: v1Range, productFilter: .specific(["b"]))]]
        ])

        let provider = MockProvider(containers: [a])
        let solver2 = PubgrubDependencyResolver(provider: provider)
        let solution = PartialSolution(assignments: [
            .derivation("a^1.0.0", cause: rootCause, decisionLevel: 0)
        ])
        let state2 = PubgrubDependencyResolver.State(root: rootNode, solution: solution)

        XCTAssertEqual(state2.incompatibilities.count, 0)

        let decision = try tsc_await { solver2.makeDecision(state: state2, completion: $0) }
        XCTAssertEqual(decision, .product("a", package: "a"))

        XCTAssertEqual(state2.incompatibilities.count, 3)
        XCTAssertEqual(state2.incompatibilities[.product("a", package: "a")], [
            try Incompatibility("a^1.0.0", Term(not: .product("b", package: "b"), v1Range),
                                              root: rootNode,
                                              cause: .dependency(node: .product("a", package: "a"))),
            try Incompatibility("a^1.0.0", Term(not: .empty(package: "a"), .exact("1.0.0")),
                                              root: rootNode,
                                              cause: .dependency(node: .product("a", package: "a"))),
        ])
    }

    func testResolverUnitPropagation() throws {
        let solver1 = PubgrubDependencyResolver(provider: emptyProvider)
        let state1 = PubgrubDependencyResolver.State(root: rootNode)
        
        // no known incompatibilities should result in no satisfaction checks
        try solver1.propagate(state: state1, node: .root(package: "root"))

        // even if incompatibilities are present
        state1.addIncompatibility(try Incompatibility(Term("a@1.0.0"), root: rootNode), at: .topLevel)
        try solver1.propagate(state: state1, node: .empty(package: "a"))
        try solver1.propagate(state: state1, node: .empty(package: "a"))
        try solver1.propagate(state: state1, node: .empty(package: "a"))

        // adding a satisfying term should result in a conflict
        state1.decide(.empty(package: aRef), at: v1)
        // FIXME: This leads to fatal error.
        // try solver1.propagate(aRef)

        // Unit propagation should derive a new assignment from almost satisfied incompatibilities.
        let solver2 = PubgrubDependencyResolver(provider: emptyProvider)
        let state2 = PubgrubDependencyResolver.State(root: rootNode)
        state2.addIncompatibility(try Incompatibility(Term(.root(package: "root"), .any),
                                    Term("¬a@1.0.0"),
                                    root: rootNode), at: .topLevel)
        state2.decide(rootNode, at: v1)
        XCTAssertEqual(state2.solution.assignments.count, 1)
        try solver2.propagate(state: state2, node: .root(package: .root(identity: PackageIdentity("root"), path: .root)))
        XCTAssertEqual(state2.solution.assignments.count, 2)
    }

    func testSolutionFindSatisfiers() {
        var solution = PartialSolution()
        solution.decide(rootNode, at: v1) // ← previous, but actually nil because this is the root decision
        solution.derive(Term(.product("a", package: aRef), .any), cause: _cause) // ← satisfier
        solution.decide(.product("a", package: aRef), at: v2)
        solution.derive("b^1.0.0", cause: _cause)

        XCTAssertEqual(try solution.satisfier(for: Term("b^1.0.0")) .term, "b^1.0.0")
        XCTAssertEqual(try solution.satisfier(for: Term("¬a^1.0.0")).term, "a@2.0.0")
        XCTAssertEqual(try solution.satisfier(for: Term("a^2.0.0")).term, "a@2.0.0")
    }

    func testResolutionNoConflicts() {
        builder.serve("a", at: v1, with: ["a": ["b": (.versionSet(v1Range), .specific(["b"]))]])
        builder.serve("b", at: v1)
        builder.serve("b", at: v2)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "a": (.versionSet(v1Range), .specific(["a"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("a", .version(v1)),
            ("b", .version(v1))
        ])
    }

    func testResolutionAvoidingConflictResolutionDuringDecisionMaking() {
        builder.serve("a", at: v1)
        builder.serve("a", at: v1_1, with: ["a": ["b": (.versionSet(v2Range), .specific(["b"]))]])
        builder.serve("b", at: v1)
        builder.serve("b", at: v1_1)
        builder.serve("b", at: v2)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "a": (.versionSet(v1Range), .specific(["a"])),
            "b": (.versionSet(v1Range), .specific(["b"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("a", .version(v1)),
            ("b", .version("1.1.0"))
        ])
    }

    func testResolutionPerformingConflictResolution() {
        // Pubgrub has a listed as >=1.0.0, which we can't really represent here.
        // It's either .any or 1.0.0..<n.0.0 with n>2. Both should have the same
        // effect though.
        builder.serve("a", at: v1)
        builder.serve("a", at: v2, with: ["a": ["b": (.versionSet(v1Range), .specific(["b"]))]])
        builder.serve("b", at: v1, with: ["b": ["a": (.versionSet(v1Range), .specific(["a"]))]])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "a": (.versionSet(v1to3Range), .specific(["a"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("a", .version(v1))
        ])
    }

    func testResolutionConflictResolutionWithAPartialSatisfier() {
        builder.serve("foo", at: v1)
        builder.serve("foo", at: v1_1, with: [
            "foo": ["left": (.versionSet(v1Range), .specific(["left"]))],
            "foo": ["right": (.versionSet(v1Range), .specific(["right"]))]
        ])
        builder.serve("left", at: v1, with: ["left": ["shared": (.versionSet(v1Range), .specific(["shared"]))]])
        builder.serve("right", at: v1, with: ["right": ["shared": (.versionSet(v1Range), .specific(["shared"]))]])
        builder.serve("shared", at: v1, with: ["shared": ["target": (.versionSet(v1Range), .specific(["target"]))]])
        builder.serve("shared", at: v2)
        builder.serve("target", at: v1)
        builder.serve("target", at: v2)

        // foo 1.1.0 transitively depends on a version of target that's not compatible
        // with root's constraint. This dependency only exists because of left
        // *and* right, choosing only one of these would be fine.

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.versionSet(v1Range), .specific(["foo"])),
            "target": (.versionSet(v2Range), .specific(["target"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .version(v1)),
            ("target", .version(v2))
        ])
    }

    func testCycle1() {
        builder.serve("foo", at: v1_1, with: ["foo": ["foo": (.versionSet(v1Range), .specific(["foo"]))]])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.versionSet(v1Range), .specific(["foo"]))
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .version(v1_1)),
        ])
    }

    func testCycle2() {
        builder.serve("foo", at: v1_1, with: ["foo": ["bar": (.versionSet(v1Range), .specific(["bar"]))]])
        builder.serve("bar", at: v1, with: ["bar": ["baz": (.versionSet(v1Range), .specific(["baz"]))]])
        builder.serve("baz", at: v1, with: ["baz": ["bam": (.versionSet(v1Range), .specific(["bam"]))]])
        builder.serve("bam", at: v1, with: ["bam": ["baz": (.versionSet(v1Range), .specific(["baz"]))]])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.versionSet(v1Range), .specific(["foo"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .version(v1_1)),
            ("bar", .version(v1)),
            ("baz", .version(v1)),
            ("bam", .version(v1)),
        ])
    }

    func testLocalPackageCycle() {
        builder.serve("foo", at: .unversioned, with: [
            "foo": ["bar": (.unversioned, .specific(["bar"]))],
        ])
        builder.serve("bar", at: .unversioned, with: [
            "bar": ["baz": (.unversioned, .specific(["baz"]))],
        ])
        builder.serve("baz", at: .unversioned, with: [
            "baz": ["foo": (.unversioned, .specific(["foo"]))],
        ])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.unversioned, .specific(["foo"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .unversioned),
            ("bar", .unversioned),
            ("baz", .unversioned),
        ])
    }

    func testBranchBasedPackageCycle() {
        builder.serve("foo", at: .revision("develop"), with: [
            "foo": ["bar": (.revision("develop"), .specific(["bar"]))],
        ])
        builder.serve("bar", at: .revision("develop"), with: [
            "bar": ["baz": (.revision("develop"), .specific(["baz"]))],
        ])
        builder.serve("baz", at: .revision("develop"), with: [
            "baz": ["foo": (.revision("develop"), .specific(["foo"]))],
        ])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.revision("develop"), .specific(["foo"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .revision("develop")),
            ("bar", .revision("develop")),
            ("baz", .revision("develop")),
        ])
    }

    func testNonExistentPackage() {
        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "package": (.versionSet(.exact(v1)), .specific(["package"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertError(result, _MockLoadingError.unknownModule)
    }

    func testUnversioned1() {
        builder.serve("foo", at: .unversioned)
        builder.serve("bar", at: v1_5)
        builder.serve("bar", at: v2)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.unversioned, .specific(["foo"])),
            "bar": (.versionSet(v1Range), .specific(["bar"]))
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .unversioned),
            ("bar", .version(v1_5))
        ])
    }

    func testUnversioned2() {
        builder.serve("foo", at: .unversioned, with: [
            "foo": ["bar": (.versionSet(.range(v1..<"1.2.0")), .specific(["bar"]))]
        ])
        builder.serve("bar", at: v1)
        builder.serve("bar", at: v1_1)
        builder.serve("bar", at: v1_5)
        builder.serve("bar", at: v2)

        let resolver = builder.create()

        let dependencies = builder.create(dependencies: [
            "foo": (.unversioned, .specific(["foo"])),
            "bar": (.versionSet(v1Range), .specific(["bar"]))
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .unversioned),
            ("bar", .version(v1_1))
        ])
    }

    func testUnversioned3() {
        builder.serve("foo", at: .unversioned)
        builder.serve("bar", at: v1, with: [
            "bar": ["foo": (.versionSet(.exact(v1)), .specific(["foo"]))]
        ])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.unversioned, .specific(["foo"])),
            "bar": (.versionSet(v1Range), .specific(["bar"]))
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .unversioned),
            ("bar", .version(v1))
        ])
    }

    func testUnversioned4() {
        builder.serve("foo", at: .unversioned)
        builder.serve("bar", at: .revision("master"), with: [
            "bar": ["foo": (.versionSet(v1Range), .specific(["foo"]))]
        ])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.unversioned, .specific(["foo"])),
            "bar": (.revision("master"), .specific(["bar"]))
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .unversioned),
            ("bar", .revision("master"))
        ])
    }

    func testUnversioned5() {
        builder.serve("foo", at: .unversioned)
        builder.serve("foo", at: .revision("master"))
        builder.serve("bar", at: .revision("master"), with: [
            "bar": ["foo": (.revision("master"), .specific(["foo"]))]
        ])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.unversioned, .specific(["foo"])),
            "bar": (.revision("master"), .specific(["bar"]))
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .unversioned),
            ("bar", .revision("master"))
        ])
    }

    func testUnversioned7() {
        builder.serve("local", at: .unversioned, with: [
            "local": ["remote": (.unversioned, .specific(["remote"]))]
        ])
        builder.serve("remote", at: .unversioned)
        builder.serve("remote", at: v1)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "local": (.unversioned, .specific(["local"])),
            "remote": (.versionSet(v1Range), .specific(["remote"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("remote", .unversioned),
            ("local", .unversioned)
        ])
    }

    func testUnversioned8() {
        builder.serve("entry", at: .unversioned, with: [
            "entry": [
                "remote": (.versionSet(v1Range), .specific(["remote"])),
                "local": (.unversioned, .specific(["local"])),
            ]
        ])
        builder.serve("local", at: .unversioned, with: [
            "local": ["remote": (.unversioned, .specific(["remote"]))]
        ])
        builder.serve("remote", at: .unversioned)
        builder.serve("remote", at: v1)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "entry": (.unversioned, .specific(["entry"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("entry", .unversioned),
            ("local", .unversioned),
            ("remote", .unversioned),
        ])
    }

    func testUnversioned9() {
        builder.serve("entry", at: .unversioned, with: [
            "entry": [
                "local": (.unversioned, .specific(["local"])),
                "remote": (.versionSet(v1Range), .specific(["remote"])),
            ]
        ])
        builder.serve("local", at: .unversioned, with: [
            "local": ["remote": (.unversioned, .specific(["remote"]))]
        ])
        builder.serve("remote", at: .unversioned)
        builder.serve("remote", at: v1)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "entry": (.unversioned, .specific(["entry"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("entry", .unversioned),
            ("local", .unversioned),
            ("remote", .unversioned),
        ])
    }

    func testResolutionWithSimpleBranchBasedDependency() {
        builder.serve("foo", at: .revision("master"), with: ["foo": ["bar": (.versionSet(v1Range), .specific(["bar"]))]])
        builder.serve("bar", at: v1)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.revision("master"), .specific(["foo"])),
            "bar": (.versionSet(v1Range), .specific(["bar"]))
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .revision("master")),
            ("bar", .version(v1))
        ])
    }

    func testResolutionWithSimpleBranchBasedDependency2() {
        builder.serve("foo", at: .revision("master"), with: ["foo": ["bar": (.versionSet(v1Range), .specific(["bar"]))]])
        builder.serve("bar", at: v1)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.revision("master"), .specific(["foo"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .revision("master")),
            ("bar", .version(v1))
        ])
    }

    func testResolutionWithOverridingBranchBasedDependency() {
        builder.serve("foo", at: .revision("master"))
        builder.serve("bar", at: v1, with: ["bar": ["foo": (.versionSet(v1Range), .specific(["foo"]))]])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.revision("master"), .specific(["foo"])),
            "bar": (.versionSet(.exact(v1)), .specific(["bar"])),

        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .revision("master")),
            ("bar", .version(v1))
        ])
    }

    func testResolutionWithOverridingBranchBasedDependency2() {
        builder.serve("foo", at: .revision("master"))
        builder.serve("bar", at: v1, with: ["bar": ["foo": (.versionSet(v1Range), .specific(["foo"]))]])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "bar": (.versionSet(.exact(v1)), .specific(["bar"])),
            "foo": (.revision("master"), .specific(["foo"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .revision("master")),
            ("bar", .version(v1))
        ])
    }

    func testResolutionWithOverridingBranchBasedDependency3() {
        builder.serve("foo", at: .revision("master"), with: ["foo": ["bar": (.revision("master"), .specific(["bar"]))]])

        builder.serve("bar", at: .revision("master"))
        builder.serve("bar", at: v1)

        builder.serve("baz", at: .revision("master"), with: ["baz": ["bar": (.versionSet(v1Range), .specific(["bar"]))]])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.revision("master"), .specific(["foo"])),
            "baz": (.revision("master"), .specific(["baz"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .revision("master")),
            ("bar", .revision("master")),
            ("baz", .revision("master")),
        ])
    }

    func testResolutionWithUnavailableRevision() {
        builder.serve("foo", at: .version(v1))

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.revision("master"), .specific(["foo"]))
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertError(result, _MockLoadingError.unknownRevision)
    }

    func testResolutionWithRevisionConflict() {
        builder.serve("foo", at: .revision("master"), with: ["foo": ["bar": (.revision("master"), .specific(["bar"]))]])
        builder.serve("bar", at: .version(v1))
        builder.serve("bar", at: .revision("master"))

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "bar": (.versionSet(v1Range), .specific(["bar"])),
            "foo": (.revision("master"), .specific(["foo"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .revision("master")),
            ("bar", .revision("master")),
        ])
    }

    func testBranchOverriding3() {
        builder.serve("swift-nio", at: v1)
        builder.serve("swift-nio", at: .revision("master"))
        builder.serve("swift-nio-ssl", at: .revision("master"), with: [
            "swift-nio-ssl": ["swift-nio": (.versionSet(v2Range), .specific(["swift-nio"]))],
        ])
        builder.serve("foo", at: "1.0.0", with: [
            "foo": ["swift-nio": (.versionSet(v1Range), .specific(["swift-nio"]))],
        ])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.versionSet(v1Range), .specific(["foo"])),
            "swift-nio": (.revision("master"), .specific(["swift-nio"])),
            "swift-nio-ssl": (.revision("master"), .specific(["swift-nio-ssl"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("swift-nio-ssl", .revision("master")),
            ("swift-nio", .revision("master")),
            ("foo", .version(v1))
        ])
    }

    func testBranchOverriding4() {
        builder.serve("swift-nio", at: v1)
        builder.serve("swift-nio", at: .revision("master"))
        builder.serve("swift-nio-ssl", at: .revision("master"), with: [
            "swift-nio-ssl": ["swift-nio": (.versionSet(v2Range), .specific(["swift-nio"]))],
        ])
        builder.serve("nio-postgres", at: .revision("master"), with: [
            "nio-postgres": [
                "swift-nio": (.revision("master"), .specific(["swift-nio"])),
                "swift-nio-ssl": (.revision("master"), .specific(["swift-nio-ssl"])),
            ]
        ])
        builder.serve("http-client", at: v1, with: [
            "http-client": [
                "swift-nio": (.versionSet(v1Range), .specific(["swift-nio"])),
                "boring-ssl": (.versionSet(v1Range), .specific(["boring-ssl"])),
            ]
        ])
        builder.serve("boring-ssl", at: v1, with: [
            "boring-ssl": ["swift-nio": (.versionSet(v1Range), .specific(["swift-nio"]))],
        ])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "nio-postgres": (.revision("master"), .specific(["nio-postgres"])),
            "http-client": (.versionSet(v1Range), .specific(["https-client"])),
            "boring-ssl": (.versionSet(v1Range), .specific(["boring-ssl"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("swift-nio-ssl", .revision("master")),
            ("swift-nio", .revision("master")),
            ("nio-postgres", .revision("master")),
            ("http-client", .version(v1)),
            ("boring-ssl", .version(v1)),
        ])
    }

    func testNonVersionDependencyInVersionDependency2() {
        builder.serve("foo", at: v1_1, with: [
            "foo": ["bar": (.revision("master"), .specific(["bar"]))]
        ])
        builder.serve("foo", at: v1)
        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.versionSet(v1Range), .specific(["foo"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .version(v1)),
        ])
    }

    func testTrivialPinStore() throws {
        builder.serve("a", at: v1, with: ["a": ["b": (.versionSet(v1Range), .specific(["b"]))]])
        builder.serve("a", at: v1_1)
        builder.serve("b", at: v1)
        builder.serve("b", at: v1_1)
        builder.serve("b", at: v2)

        let dependencies = builder.create(dependencies: [
            "a": (.versionSet(v1Range), .specific(["a"])),
        ])

        let pinsStore = builder.create(pinsStore: [
            "a": (.version(v1), .specific(["a"])),
            "b": (.version(v1), .specific(["b"])),
        ])

        let resolver = builder.create(pinsMap: pinsStore.pinsMap)
        let result = try resolver.solve(root: rootNode, constraints: dependencies)

        // Since a was pinned, we shouldn't have computed bounds for its incomaptibilities.
        let aIncompat = result.state.positiveIncompatibilities(for: .product("a", package: builder.reference(for: "a")))![0]
        XCTAssertEqual(aIncompat.terms[0].requirement, .exact("1.0.0"))

        AssertResult(Result.success(result.bindings), [
            ("a", .version(v1)),
            ("b", .version(v1))
        ])
    }

    func testPartialPins() {
        // This checks that we can drop pins that are not valid anymore but still keep the ones
        // which fit the constraints.
        builder.serve("a", at: v1, with: ["a": ["b": (.versionSet(v1Range), .specific(["b"]))]])
        builder.serve("a", at: v1_1)
        builder.serve("b", at: v1)
        builder.serve("b", at: v1_1)
        builder.serve("c", at: v1, with: ["c": ["b": (.versionSet(.range(v1_1..<v2)), .specific(["b"]))]])
        
        let dependencies = builder.create(dependencies: [
            "c": (.versionSet(v1Range), .specific(["c"])),
            "a": (.versionSet(v1Range), .specific(["a"])),
        ])

        // Here b is pinned to v1 but its requirement is now 1.1.0..<2.0.0 in the graph
        // due to addition of a new dependency.
        let pinsStore = builder.create(pinsStore: [
            "a": (.version(v1), .specific(["a"])),
            "b": (.version(v1), .specific(["b"])),
        ])

        let resolver = builder.create(pinsMap: pinsStore.pinsMap)
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("a", .version(v1)),
            ("b", .version(v1_1)),
            ("c", .version(v1))
        ])
    }

    func testBranchedBasedPin() {
        // This test ensures that we get the SHA listed in Package.resolved for branch-based
        // dependencies.
        builder.serve("a", at: .revision("develop-sha-1"))
        builder.serve("b", at: .revision("master-sha-2"))

        let dependencies = builder.create(dependencies: [
            "a": (.revision("develop"), .specific(["a"])),
            "b": (.revision("master"), .specific(["b"])),
        ])

        let pinsStore = builder.create(pinsStore: [
            "a": (.branch("develop", revision: "develop-sha-1"), .specific(["a"])),
            "b": (.branch("master", revision: "master-sha-2"), .specific(["b"])),
        ])

        let resolver = builder.create(pinsMap: pinsStore.pinsMap)
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("a", .revision("develop-sha-1", branch: "develop")),
            ("b", .revision("master-sha-2", branch: "master")),
        ])
    }

    func testIncompatibleToolsVersion2() {
        builder.serve("a", at: v1_1, toolsVersion: ToolsVersion.v5)
        builder.serve("a", at: v1)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "a": (.versionSet(v1Range), .specific(["a"])),
        ])

        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("a", .version(v1)),
        ])
    }

    func testUnreachableProductsSkipped() throws {
        #if ENABLE_TARGET_BASED_DEPENDENCY_RESOLUTION
        #else
        try XCTSkipIf(true)
        #endif

        builder.serve("root", at: .unversioned, with: [
            "root": ["immediate": (.versionSet(v1Range), .specific(["ImmediateUsed"]))]
        ])
        builder.serve("immediate", at: v1, with: [
            "ImmediateUsed": ["transitive": (.versionSet(v1Range), .specific(["TransitiveUsed"]))],
            "ImmediateUnused": [
                "transitive": (.versionSet(v1Range), .specific(["TransitiveUnused"])),
                "nonexistent": (.versionSet(v1Range), .specific(["Nonexistent"]))
            ]
        ])
        builder.serve("transitive", at: v1, with: [
            "TransitiveUsed": [:],
            "TransitiveUnused": [
                "nonexistent": (.versionSet(v1Range), .specific(["Nonexistent"]))
            ]
        ])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "root": (.unversioned, .everything)
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("root", .unversioned),
            ("immediate", .version(v1)),
            ("transitive", .version(v1))
        ])
    }

    func testDelegate() {
        class TestDelegate: DependencyResolverDelegate {
            var events = [String]()
            let lock = Lock()

            func willResolve(term: Term) {
                self.lock.withLock {
                    self.events.append("willResolve '\(term.node.package.identity)'")
                }
            }

            func didResolve(term: Term, version: Version, duration: DispatchTimeInterval) {
                self.lock.withLock {
                    self.events.append("didResolve '\(term.node.package.identity)' at '\(version)'")
                }
            }

            func derived(term: Term) {}

            func conflict(conflict: Incompatibility) {}

            func satisfied(term: Term, by assignment: Assignment, incompatibility: Incompatibility) {}

            func partiallySatisfied(term: Term, by assignment: Assignment, incompatibility: Incompatibility, difference: Term) {}

            func failedToResolve(incompatibility: Incompatibility) {}

            func solved(result: [DependencyResolver.Binding]) {
                let decisions = result.sorted(by: { $0.package.identity < $1.package.identity }).map { "'\($0.package.identity)' at '\($0.binding)'" }
                self.lock.withLock {
                    self.events.append("solved: \(decisions.joined(separator: ", "))")
                }
            }
        }

        builder.serve("foo", at: "1.0.0")
        builder.serve("foo", at: "1.1.0")
        builder.serve("foo", at: "2.0.0")
        builder.serve("foo", at: "2.0.1")

        builder.serve("bar", at: "1.0.0")
        builder.serve("bar", at: "1.1.0")
        builder.serve("bar", at: "2.0.0")
        builder.serve("bar", at: "2.0.1")

        let delegate = TestDelegate()
        let resolver = builder.create(delegate: delegate)
        let dependencies = builder.create(dependencies: [
            "foo": (.versionSet(v1Range), .specific(["foo"])),
            "bar": (.versionSet(v2Range), .specific(["bar"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .version("1.1.0")),
            ("bar", .version("2.0.1")),
        ])

        XCTAssertTrue(delegate.events.contains("willResolve 'foo'"), "\(delegate.events)")
        XCTAssertTrue(delegate.events.contains("didResolve 'foo' at '1.1.0'"), "\(delegate.events)")
        XCTAssertTrue(delegate.events.contains("willResolve 'bar'"), "\(delegate.events)")
        XCTAssertTrue(delegate.events.contains("didResolve 'bar' at '2.0.1'"), "\(delegate.events)")
        XCTAssertTrue(delegate.events.contains("solved: 'bar' at '2.0.1', 'foo' at '1.1.0'"), "\(delegate.events)")
    }
}

final class PubGrubTestsBasicGraphs: XCTestCase {
    func testSimple1() {
        builder.serve("a", at: v1, with: [
            "a": [
                "aa": (.versionSet(.exact("1.0.0")), .specific(["aa"])),
                "ab": (.versionSet(.exact("1.0.0")), .specific(["ab"])),
            ]
        ])
        builder.serve("aa", at: v1)
        builder.serve("ab", at: v1)
        builder.serve("b", at: v1, with: [
            "b": [
                "ba": (.versionSet(.exact("1.0.0")), .specific(["ba"])),
                "bb": (.versionSet(.exact("1.0.0")), .specific(["bb"])),
            ]
        ])
        builder.serve("ba", at: v1)
        builder.serve("bb", at: v1)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "a": (.versionSet(.exact("1.0.0")), .specific(["a"])),
            "b": (.versionSet(.exact("1.0.0")), .specific(["b"])),
        ])

        let result = resolver.solve(constraints: dependencies)
        AssertResult(result, [
            ("a", .version(v1)),
            ("aa", .version(v1)),
            ("ab", .version(v1)),
            ("b", .version(v1)),
            ("ba", .version(v1)),
            ("bb", .version(v1)),
        ])
    }

    func testSharedDependency1() {
        builder.serve("a", at: v1, with: [
            "a": ["shared": (.versionSet(.range("2.0.0"..<"4.0.0")), .specific(["shared"]))],
        ])
        builder.serve("b", at: v1, with: [
            "b": ["shared": (.versionSet(.range("3.0.0"..<"5.0.0")), .specific(["shared"]))],
        ])
        builder.serve("shared", at: "2.0.0")
        builder.serve("shared", at: "3.0.0")
        builder.serve("shared", at: "3.6.9")
        builder.serve("shared", at: "4.0.0")
        builder.serve("shared", at: "5.0.0")

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "a": (.versionSet(.exact("1.0.0")), .specific(["a"])),
            "b": (.versionSet(.exact("1.0.0")), .specific(["b"])),
        ])

        let result = resolver.solve(constraints: dependencies)
        AssertResult(result, [
            ("a", .version(v1)),
            ("b", .version(v1)),
            ("shared", .version("3.6.9")),
        ])
    }

    func testSharedDependency2() {
        builder.serve("foo", at: "1.0.0")
        builder.serve("foo", at: "1.0.1", with: [
            "foo": ["bang": (.versionSet(.exact("1.0.0")), .specific(["bang"]))],
        ])
        builder.serve("foo", at: "1.0.2", with: [
            "foo": ["whoop": (.versionSet(.exact("1.0.0")), .specific(["whoop"]))],
        ])
        builder.serve("foo", at: "1.0.3", with: [
            "foo": ["zoop": (.versionSet(.exact("1.0.0")), .specific(["zoop"]))],
        ])
        builder.serve("bar", at: "1.0.0", with: [
            "bar": ["foo": (.versionSet(.range("0.0.0"..<"1.0.2")), .specific(["foo"]))],
        ])
        builder.serve("bang", at: "1.0.0")
        builder.serve("whoop", at: "1.0.0")
        builder.serve("zoop", at: "1.0.0")

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.versionSet(.range("0.0.0"..<"1.0.3")), .specific(["foo"])),
            "bar": (.versionSet(.exact("1.0.0")), .specific(["bar"])),
        ])

        let result = resolver.solve(constraints: dependencies)
        AssertResult(result, [
            ("foo", .version("1.0.1")),
            ("bar", .version(v1)),
            ("bang", .version(v1)),
        ])
    }

    func testFallbacksToOlderVersion() {
        builder.serve("foo", at: "1.0.0")
        builder.serve("foo", at: "2.0.0")
        builder.serve("bar", at: "1.0.0")
        builder.serve("bar", at: "2.0.0", with: [
            "bar": ["baz": (.versionSet(.exact("1.0.0")), .specific(["baz"]))],
        ])
        builder.serve("baz", at: "1.0.0", with: [
            "baz": ["foo": (.versionSet(.exact("2.0.0")), .specific(["foo"]))],
        ])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "bar": (.versionSet(.range("0.0.0"..<"5.0.0")), .specific(["bar"])),
            "foo": (.versionSet(.exact("1.0.0")), .specific(["foo"])),
        ])

        let result = resolver.solve(constraints: dependencies)
        AssertResult(result, [
            ("foo", .version(v1)),
            ("bar", .version(v1)),
        ])
    }
}

final class PubGrubDiagnosticsTests: XCTestCase {

    func testMissingVersion() {
        builder.serve("foopkg", at: v1_1)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foopkg": (.versionSet(v2Range), .specific(["foopkg"])),
        ])
        let result = resolver.solve(constraints: dependencies)
        
        XCTAssertEqual(result.errorMsg, """
            Dependencies could not be resolved because no versions of 'foopkg' match the requirement 2.0.0..<3.0.0 and root depends on 'foopkg' 2.0.0..<3.0.0.
            """)
    }

    func testResolutionNonExistentVersion() {
        builder.serve("package", at: v2)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "package": (.versionSet(.exact(v1)), .specific(["package"]))
        ])
        let result = resolver.solve(constraints: dependencies)

        XCTAssertEqual(result.errorMsg, """
            Dependencies could not be resolved because no versions of 'package' match the requirement 1.0.0 and root depends on 'package' 1.0.0.
            """)
    }

    func testResolutionLinearErrorReporting() {
        builder.serve("foo", at: v1, with: ["foo": ["bar": (.versionSet(v2Range), .specific(["bar"]))]])
        builder.serve("bar", at: v2, with: ["bar": ["baz": (.versionSet(.range("3.0.0"..<"4.0.0")), .specific(["baz"]))]])
        builder.serve("baz", at: v1)
        builder.serve("baz", at: "3.0.0")

        // root transitively depends on a version of baz that's not compatible
        // with root's constraint.

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.versionSet(v1Range), .specific(["foo"])),
            "baz": (.versionSet(v1Range), .specific(["baz"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        XCTAssertEqual(result.errorMsg, """
            Dependencies could not be resolved because root depends on 'foo' 1.0.0..<2.0.0 and root depends on 'baz' 1.0.0..<2.0.0.
            'foo' practically depends on 'baz' 3.0.0..<4.0.0 because 'foo' depends on 'bar' 2.0.0..<3.0.0 and 'bar' depends on 'baz' 3.0.0..<4.0.0.
            """)
    }

    func testResolutionBranchingErrorReporting() {
        builder.serve("foo", at: v1, with: [
            "foo": [
                "a": (.versionSet(v1Range), .specific(["a"])),
                "b": (.versionSet(v1Range), .specific(["b"]))
            ]
        ])
        builder.serve("foo", at: v1_1, with: [
            "foo": [
                "x": (.versionSet(v1Range), .specific(["x"])),
                "y": (.versionSet(v1Range), .specific(["y"]))
            ]
        ])
        builder.serve("a", at: v1, with: ["a": ["b": (.versionSet(v2Range), .specific(["b"]))]])
        builder.serve("b", at: v1)
        builder.serve("b", at: v2)
        builder.serve("x", at: v1, with: ["x": ["y": (.versionSet(v2Range), .specific(["y"]))]])
        builder.serve("y", at: v1)
        builder.serve("y", at: v2)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.versionSet(v1Range), .specific(["foo"])),
        ])
        let result = resolver.solve(constraints: dependencies)
        
        XCTAssertEqual(result.errorMsg, """
          Dependencies could not be resolved because root depends on 'foo' 1.0.0..<2.0.0.
          'foo' cannot be used because 'foo' < 1.1.0 cannot be used (1).
          'foo' >= 1.1.0 cannot be used because 'foo' >= 1.1.0 depends on 'y' 1.0.0..<2.0.0.
          'foo' >= 1.1.0 practically depends on 'y' 2.0.0..<3.0.0 because 'x' depends on 'y' 2.0.0..<3.0.0 and 'foo' >= 1.1.0 depends on 'x' 1.0.0..<2.0.0.
          'foo' < 1.1.0 practically depends on 'b' 2.0.0..<3.0.0 because 'a' depends on 'b' 2.0.0..<3.0.0 and 'foo' < 1.1.0 depends on 'a' 1.0.0..<2.0.0.
             (1) As a result, 'foo' < 1.1.0 cannot be used because 'foo' < 1.1.0 depends on 'b' 1.0.0..<2.0.0.
        """)
    }
    
    func testConflict1() {
        builder.serve("foo", at: v1, with: ["foo": ["config": (.versionSet(v1Range), .specific(["config"]))]])
        builder.serve("bar", at: v1, with: ["bar": ["config": (.versionSet(v2Range), .specific(["config"]))]])
        builder.serve("config", at: v1)
        builder.serve("config", at: v2)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.versionSet(v1Range), .specific(["foo"])),
            "bar": (.versionSet(v1Range), .specific(["bar"]))
        ])
        let result = resolver.solve(constraints: dependencies)

        XCTAssertEqual(result.errorMsg, """
            Dependencies could not be resolved because root depends on 'foo' 1.0.0..<2.0.0 and root depends on 'bar' 1.0.0..<2.0.0.
            'bar' is incompatible with 'foo' because 'bar' depends on 'config' 2.0.0..<3.0.0 and 'foo' depends on 'config' 1.0.0..<2.0.0.
            """)
    }

    func testConflict2() {
        func addDeps() {
            builder.serve("foo", at: v1, with: ["foo": ["config": (.versionSet(v1Range), .specific(["config"]))]])
            builder.serve("config", at: v1)
            builder.serve("config", at: v2)
        }

        let dependencies1 = builder.create(dependencies: [
            "config": (.versionSet(v2Range), .specific(["config"])),
            "foo": (.versionSet(v1Range), .specific(["foo"])),
        ])
        addDeps()
        let resolver1 = builder.create()
        let result1 = resolver1.solve(constraints: dependencies1)

        XCTAssertEqual(result1.errorMsg, """
            Dependencies could not be resolved because root depends on 'foo' 1.0.0..<2.0.0.
            'foo' cannot be used because 'foo' depends on 'config' 1.0.0..<2.0.0 and root depends on 'config' 2.0.0..<3.0.0.
            """)

        let dependencies2 = builder.create(dependencies: [
            "foo": (.versionSet(v1Range), .specific(["foo"])),
            "config": (.versionSet(v2Range), .specific(["config"])),
        ])
        addDeps()
        let resolver2 = builder.create()
        let result2 = resolver2.solve(constraints: dependencies2)

        XCTAssertEqual(result2.errorMsg, """
            Dependencies could not be resolved because root depends on 'config' 2.0.0..<3.0.0.
            'config' 1.0.0..<2.0.0 is required because 'foo' depends on 'config' 1.0.0..<2.0.0 and root depends on 'foo' 1.0.0..<2.0.0.
            """)
    }

    func testConflict3() {
        builder.serve("foo", at: v1, with: ["foo": ["config": (.versionSet(v1Range), .specific(["config"]))]])
        builder.serve("config", at: v1)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "config": (.versionSet(v2Range), .specific(["config"])),
            "foo": (.versionSet(v1Range), .specific(["foo"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        XCTAssertEqual(result.errorMsg, """
            Dependencies could not be resolved because no versions of 'config' match the requirement 2.0.0..<3.0.0 and root depends on 'config' 2.0.0..<3.0.0.
            """)
    }

    func testUnversioned6() {
        builder.serve("foo", at: .unversioned)
        builder.serve("bar", at: .revision("master"), with: [
            "bar": ["foo": (.unversioned, .specific(["foo"]))]
        ])

        let resolver = builder.create()

        let dependencies = builder.create(dependencies: [
            "bar": (.revision("master"), .specific(["bar"]))
        ])
        let result = resolver.solve(constraints: dependencies)

        XCTAssertEqual(result.errorMsg, "package 'bar' is required using a revision-based requirement and it depends on local package 'foo', which is not supported")
    }

    func testResolutionWithOverridingBranchBasedDependency4() {
        builder.serve("foo", at: .revision("master"), with: ["foo": ["bar": (.revision("master"), .specific(["bar"]))]])

        builder.serve("bar", at: .revision("master"))
        builder.serve("bar", at: v1)

        builder.serve("baz", at: .revision("master"), with: ["baz": ["bar": (.revision("develop"), .specific(["baz"]))]])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.revision("master"), .specific(["foo"])),
            "baz": (.revision("master"), .specific(["baz"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        XCTAssertEqual(result.errorMsg, "bar is required using two different revision-based requirements (master and develop), which is not supported")
    }

    func testNonVersionDependencyInVersionDependency1() {
        builder.serve("foo", at: v1_1, with: [
            "foo": ["bar": (.revision("master"), .specific(["bar"]))]
        ])
        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.versionSet(v1Range), .specific(["foo"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        XCTAssertEqual(result.errorMsg, """
            Dependencies could not be resolved because root depends on 'foo' 1.0.0..<2.0.0.
            'foo' cannot be used because no versions of 'foo' match the requirement {1.0.0..<1.1.0, 1.1.1..<2.0.0} and package 'foo' is required using a stable-version but 'foo' depends on an unstable-version package 'bar'.
            """)
    }

    func testNonVersionDependencyInVersionDependency3() {
        builder.serve("foo", at: v1, with: [
            "foo": ["bar": (.unversioned, .specific(["bar"]))]
        ])
        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.versionSet(.exact(v1)), .specific(["foo"])),
        ])
        let result = resolver.solve(constraints: dependencies)

        XCTAssertEqual(result.errorMsg, """
            Dependencies could not be resolved because package 'foo' is required using a stable-version but 'foo' depends on an unstable-version package 'bar' and root depends on 'foo' 1.0.0.
            """)
    }

    func testIncompatibleToolsVersion1() {
        builder.serve("a", at: v1, toolsVersion: .v5)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "a": (.versionSet(v1Range), .specific(["a"])),
        ])

        let result = resolver.solve(constraints: dependencies)

        XCTAssertEqual(result.errorMsg, """
            Dependencies could not be resolved because root depends on 'a' 1.0.0..<2.0.0.
            'a' >= 1.0.0 cannot be used because no versions of 'a' match the requirement 1.0.1..<2.0.0 and 'a' 1.0.0 contains incompatible tools version (\(ToolsVersion.v5)).
            """)
    }

    func testIncompatibleToolsVersion3() {
        builder.serve("a", at: v1_1, with: [
            "a": ["b": (.versionSet(v1Range), .specific(["b"]))]
        ])
        builder.serve("a", at: v1, toolsVersion: .v4)

        builder.serve("b", at: v1)
        builder.serve("b", at: v2)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "a": (.versionSet(v1Range), .specific(["a"])),
            "b": (.versionSet(v2Range), .specific(["b"])),
        ])

        let result = resolver.solve(constraints: dependencies)
        
        XCTAssertEqual(result.errorMsg, """
            Dependencies could not be resolved because root depends on 'a' 1.0.0..<2.0.0 and root depends on 'b' 2.0.0..<3.0.0.
            'a' >= 1.0.0 practically depends on 'b' 1.0.0..<2.0.0 because 'a' >= 1.1.0 depends on 'b' 1.0.0..<2.0.0.
            'a' 1.0.0..<1.1.0 cannot be used because no versions of 'a' match the requirement 1.0.1..<1.1.0 and 'a' 1.0.0 contains incompatible tools version (\(ToolsVersion.v4)).
            """)
    }

    func testIncompatibleToolsVersion4() {
        builder.serve("a", at: "3.2.1", toolsVersion: .v3)
        builder.serve("a", at: "3.2.2", toolsVersion: .v4)
        builder.serve("a", at: "3.2.3", toolsVersion: .v3)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "a": (.versionSet(.range("3.2.0"..<"4.0.0")), .specific(["a"])),
        ])

        let result = resolver.solve(constraints: dependencies)

        XCTAssertEqual(result.errorMsg, """
            Dependencies could not be resolved because 'a' contains incompatible tools version (\(ToolsVersion.v3)) and root depends on 'a' 3.2.0..<4.0.0.
            """)
    }

    func testIncompatibleToolsVersion5() {
        builder.serve("a", at: "3.2.0", toolsVersion: .v3)
        builder.serve("a", at: "3.2.1", toolsVersion: .v4)
        builder.serve("a", at: "3.2.2", toolsVersion: .v5)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "a": (.versionSet(.range("3.2.0"..<"4.0.0")), .specific(["a"])),
        ])

        let result = resolver.solve(constraints: dependencies)

        XCTAssertEqual(result.errorMsg, """
            Dependencies could not be resolved because 'a' contains incompatible tools version (\(ToolsVersion.v5)) and root depends on 'a' 3.2.0..<4.0.0.
            """)
    }

    func testIncompatibleToolsVersion6() {
        builder.serve("a", at: "3.2.1", toolsVersion: .v5)
        builder.serve("a", at: "3.2.0", with: [
            "a": ["b": (.versionSet(v1Range), .specific(["b"]))],
        ])
        builder.serve("a", at: "3.2.2", toolsVersion: .v4)
        builder.serve("b", at: "1.0.0", toolsVersion: .v3)

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "a": (.versionSet(.range("3.2.0"..<"4.0.0")), .specific(["a"])),
        ])

        let result = resolver.solve(constraints: dependencies)

        XCTAssertEqual(result.errorMsg, """
            Dependencies could not be resolved because 'a' >= 3.2.1 contains incompatible tools version (\(ToolsVersion.v4)) and root depends on 'a' 3.2.0..<4.0.0.
            'a' < 3.2.1 cannot be used because 'a' < 3.2.1 depends on 'b' 1.0.0..<2.0.0.
            'b' >= 1.0.0 cannot be used because 'b' 1.0.0 contains incompatible tools version (\(ToolsVersion.v3)) and no versions of 'b' match the requirement 1.0.1..<2.0.0.
            """)
    }

    func testConflict4() {
        builder.serve("foo", at: v1, with: [
            "foo": ["shared": (.versionSet(.range("2.0.0"..<"3.0.0")), .specific(["shared"]))],
        ])
        builder.serve("bar", at: v1, with: [
            "bar": ["shared": (.versionSet(.range("2.9.0"..<"4.0.0")), .specific(["shared"]))],
        ])
        builder.serve("shared", at: "2.5.0")
        builder.serve("shared", at: "3.5.0")

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "bar": (.versionSet(.exact(v1)), .specific(["bar"])),
            "foo": (.versionSet(.exact(v1)), .specific(["foo"])),
        ])

        let result = resolver.solve(constraints: dependencies)

        XCTAssertEqual(result.errorMsg, """
            Dependencies could not be resolved because root depends on 'bar' 1.0.0 and root depends on 'foo' 1.0.0.
            'foo' is incompatible with 'bar' because 'foo' depends on 'shared' 2.0.0..<3.0.0.
            'bar' practically depends on 'shared' 3.0.0..<4.0.0 because 'bar' depends on 'shared' 2.9.0..<4.0.0 and no versions of 'shared' match the requirement 2.9.0..<3.0.0.
            """)
    }

    func testConflict5() {
        builder.serve("a", at: v1, with: [
            "a": ["b": (.versionSet(.exact("1.0.0")), .specific(["b"]))],
        ])
        builder.serve("a", at: "2.0.0", with: [
            "a": ["b": (.versionSet(.exact("2.0.0")), .specific(["b"]))],
        ])
        builder.serve("b", at: "1.0.0", with: [
            "b": ["a": (.versionSet(.exact("2.0.0")), .specific(["a"]))],
        ])
        builder.serve("b", at: "2.0.0", with: [
            "b": ["a": (.versionSet(.exact("1.0.0")), .specific(["a"]))],
        ])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "b": (.versionSet(.range("0.0.0"..<"5.0.0")), .specific(["b"])),
            "a": (.versionSet(.range("0.0.0"..<"5.0.0")), .specific(["a"])),
        ])

        let result = resolver.solve(constraints: dependencies)

        XCTAssertEqual(result.errorMsg, """
            Dependencies could not be resolved because root depends on 'a' 0.0.0..<5.0.0.
            'a' cannot be used.
            'a' >= 2.0.0 cannot be used because 'b' >= 2.0.0 depends on 'a' 1.0.0 and 'a' >= 2.0.0 depends on 'b' 2.0.0.
            'a' {0.0.0..<2.0.0, 3.0.0..<5.0.0} cannot be used because 'b' < 2.0.0 depends on 'a' 2.0.0.
            'a' {0.0.0..<2.0.0, 3.0.0..<5.0.0} practically depends on 'b' 1.0.0 because no versions of 'a' match the requirement 3.0.0..<5.0.0 and 'a' < 2.0.0 depends on 'b' 1.0.0.
            """)
    }

    func testProductsCannotResolveToDifferentVersions() {
        builder.serve("root", at: .unversioned, with: [
            "root": [
                "intermediate_a": (.versionSet(v1Range), .specific(["Intermediate A"])),
                "intermediate_b": (.versionSet(v1Range), .specific(["Intermediate B"]))
            ]
        ])
        builder.serve("intermediate_a", at: v1, with: [
            "Intermediate A": [
                "transitive": (.versionSet(.exact(v1)), .specific(["Product A"]))
            ]
        ])
        builder.serve("intermediate_b", at: v1, with: [
            "Intermediate B": [
                "transitive": (.versionSet(.exact(v1_1)), .specific(["Product B"]))
            ]
        ])
        builder.serve("transitive", at: v1, with: [
            "Product A": [:],
            "Product B": [:]
        ])
        builder.serve("transitive", at: v1_1, with: [
            "Product A": [:],
            "Product B": [:]
        ])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "root": (.unversioned, .everything)
        ])
        let result = resolver.solve(constraints: dependencies)
        
        XCTAssertEqual(
            result.errorMsg,
            """
            Dependencies could not be resolved because root depends on 'intermediate_a' 1.0.0..<2.0.0 and root depends on 'intermediate_b' 1.0.0..<2.0.0.
            'intermediate_b' is incompatible with 'intermediate_a' because 'transitive' < 1.1.0 depends on 'transitive' 1.0.0 and 'intermediate_a' depends on 'transitive' 1.0.0.
            'intermediate_b' practically depends on 'transitive' 1.1.0 because 'intermediate_b' depends on 'transitive' 1.1.0 and 'transitive' >= 1.1.0 depends on 'transitive' 1.1.0.
            """
        )
    }
}

final class PubGrubBacktrackTests: XCTestCase {
    func testBacktrack1() {
        builder.serve("a", at: v1)
        builder.serve("a", at: "2.0.0", with: [
            "a": ["b": (.versionSet(.exact("1.0.0")), .specific(["b"]))],
        ])
        builder.serve("b", at: "1.0.0", with: [
            "b": ["a": (.versionSet(.exact("1.0.0")), .specific(["a"]))],
        ])

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "a": (.versionSet(.range("1.0.0"..<"3.0.0")), .specific(["a"])),
        ])

        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("a", .version(v1)),
        ])
    }

    func testBacktrack2() {
        builder.serve("a", at: v1)
        builder.serve("a", at: "2.0.0", with: [
            "a": ["c": (.versionSet(.range("1.0.0"..<"2.0.0")), .specific(["c"]))],
        ])

        builder.serve("b", at: "1.0.0", with: [
            "b": ["c": (.versionSet(.range("2.0.0"..<"3.0.0")), .specific(["c"]))],
        ])
        builder.serve("b", at: "2.0.0", with: [
            "b": ["c": (.versionSet(.range("3.0.0"..<"4.0.0")), .specific(["c"]))],
        ])

        builder.serve("c", at: "1.0.0")
        builder.serve("c", at: "2.0.0")
        builder.serve("c", at: "3.0.0")

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "a": (.versionSet(.range("1.0.0"..<"3.0.0")), .specific(["a"])),
            "b": (.versionSet(.range("1.0.0"..<"3.0.0")), .specific(["b"])),
        ])

        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("a", .version(v1)),
            ("b", .version("2.0.0")),
            ("c", .version("3.0.0")),
        ])
    }

    func testBacktrack3() {
        builder.serve("a", at: "1.0.0", with: [
            "a": ["x": (.versionSet(.range("1.0.0"..<"5.0.0")), .specific(["x"]))],
        ])
        builder.serve("b", at: "1.0.0", with: [
            "b": ["x": (.versionSet(.range("0.0.0"..<"2.0.0")), .specific(["x"]))],
        ])

        builder.serve("c", at: "1.0.0")
        builder.serve("c", at: "2.0.0", with: [
            "c": [
                "a": (.versionSet(.range("0.0.0"..<"5.0.0")), .specific(["a"])),
                "b": (.versionSet(.range("0.0.0"..<"5.0.0")), .specific(["b"])),
            ]
        ])

        builder.serve("x", at: "0.0.0")
        builder.serve("x", at: "2.0.0")
        builder.serve("x", at: "1.0.0", with: [
            "x": ["y": (.versionSet(.exact(v1)), .specific(["y"]))],
        ])

        builder.serve("y", at: "1.0.0")
        builder.serve("y", at: "2.0.0")

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "c": (.versionSet(.range("1.0.0"..<"3.0.0")), .specific(["c"])),
            "y": (.versionSet(.range("2.0.0"..<"3.0.0")), .specific(["y"])),
        ])

        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("c", .version(v1)),
            ("y", .version("2.0.0")),
        ])
    }

    func testBacktrack4() {
        builder.serve("a", at: "1.0.0", with: [
            "a": ["x": (.versionSet(.range("1.0.0"..<"5.0.0")), .specific(["x"]))],
        ])
        builder.serve("b", at: "1.0.0", with: [
            "b": ["x": (.versionSet(.range("0.0.0"..<"2.0.0")), .specific(["x"]))],
        ])

        builder.serve("c", at: "1.0.0")
        builder.serve("c", at: "2.0.0", with: [
            "c": [
                "a": (.versionSet(.range("0.0.0"..<"5.0.0")), .specific(["a"])),
                "b": (.versionSet(.range("0.0.0"..<"5.0.0")), .specific(["b"])),
            ]
        ])

        builder.serve("x", at: "0.0.0")
        builder.serve("x", at: "2.0.0")
        builder.serve("x", at: "1.0.0", with: [
            "x": ["y": (.versionSet(.exact(v1)), .specific(["y"]))],
        ])

        builder.serve("y", at: "1.0.0")
        builder.serve("y", at: "2.0.0")

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "c": (.versionSet(.range("1.0.0"..<"3.0.0")), .specific(["c"])),
            "y": (.versionSet(.range("2.0.0"..<"3.0.0")), .specific(["y"])),
        ])

        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("c", .version(v1)),
            ("y", .version("2.0.0")),
        ])
    }

    func testBacktrack5() {
        builder.serve("foo", at: "1.0.0", with: [
            "foo": ["bar": (.versionSet(.exact("1.0.0")), .specific(["bar"]))],
        ])
        builder.serve("foo", at: "2.0.0", with: [
            "foo": ["bar": (.versionSet(.exact("2.0.0")), .specific(["bar"]))],
        ])
        builder.serve("foo", at: "3.0.0", with: [
            "foo": ["bar": (.versionSet(.exact("3.0.0")), .specific(["bar"]))],
        ])

        builder.serve("bar", at: "1.0.0", with: [
            "bar": ["baz": (.versionSet(.range("0.0.0"..<"3.0.0")), .specific(["baz"]))],
        ])
        builder.serve("bar", at: "2.0.0", with: [
            "bar": ["baz": (.versionSet(.exact("3.0.0")), .specific(["baz"]))],
        ])
        builder.serve("bar", at: "3.0.0", with: [
            "bar": ["baz": (.versionSet(.exact("3.0.0")), .specific(["baz"]))],
        ])

        builder.serve("baz", at: "1.0.0")

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "foo": (.versionSet(.range("1.0.0"..<"4.0.0")), .specific(["foo"])),
        ])

        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("foo", .version(v1)),
            ("bar", .version("1.0.0")),
            ("baz", .version("1.0.0")),
        ])
    }

    func testBacktrack6() {
        builder.serve("a", at: "1.0.0")
        builder.serve("a", at: "2.0.0")
        builder.serve("b", at: "1.0.0", with: [
            "b": ["a": (.versionSet(.exact("1.0.0")), .specific(["a"]))],
        ])
        builder.serve("c", at: "1.0.0", with: [
            "c": ["b": (.versionSet(.range("0.0.0"..<"3.0.0")), .specific(["b"]))],
        ])
        builder.serve("d", at: "1.0.0")
        builder.serve("d", at: "2.0.0")

        let resolver = builder.create()
        let dependencies = builder.create(dependencies: [
            "a": (.versionSet(.range("1.0.0"..<"4.0.0")), .specific(["a"])),
            "c": (.versionSet(.range("1.0.0"..<"4.0.0")), .specific(["c"])),
            "d": (.versionSet(.range("1.0.0"..<"4.0.0")), .specific(["d"])),
        ])

        let result = resolver.solve(constraints: dependencies)

        AssertResult(result, [
            ("a", .version(v1)),
            ("b", .version(v1)),
            ("c", .version(v1)),
            ("d", .version("2.0.0")),
        ])
    }
}

fileprivate extension CheckoutState {
    /// Creates a checkout state with the given version and a mocked revision.
    static func version(_ version: Version) -> CheckoutState {
        CheckoutState(revision: Revision(identifier: "<fake-ident>"), version: version)
    }

    static func branch(_ branch: String, revision: String) -> CheckoutState {
        CheckoutState(revision: Revision(identifier: revision), branch: branch)
    }
}

/// Asserts that the listed packages are present in the bindings with their
/// specified versions.
private func AssertBindings(
    _ bindings: [DependencyResolver.Binding],
    _ packages: [(identity: PackageIdentity, version: BoundVersion)],
    file: StaticString = #file,
    line: UInt = #line
) {
    if bindings.count > packages.count {
        let unexpectedBindings = bindings
            .filter { binding in
                packages.contains(where: { pkg in
                    pkg.identity != binding.package.identity
                })
            }
            .map { $0.package.identity }

        XCTFail("Unexpected binding(s) found for \(unexpectedBindings.map { $0.description }.joined(separator: ", ")).", file: file, line: line)
    }
    for package in packages {
        guard let binding = bindings.first(where: { $0.package.identity == package.identity }) else {
            XCTFail("No binding found for \(package.identity).", file: file, line: line)
            continue
        }

        if binding.binding != package.version {
            XCTFail("Expected \(package.version) for \(package.identity), found \(binding.binding) instead.", file: file, line: line)
        }
    }
}

/// Asserts that a result succeeded and contains the specified bindings.
private func AssertResult(
    _ result: Result<[DependencyResolver.Binding], Error>,
    _ packages: [(identifier: String, version: BoundVersion)],
    file: StaticString = #file,
    line: UInt = #line
) {
    switch result {
    case .success(let bindings):
        AssertBindings(bindings, packages.map { (PackageIdentity($0.identifier), $0.version) }, file: file, line: line)
    case .failure(let error):
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

/// Asserts that a result failed with specified error.
private func AssertError(
    _ result: Result<[DependencyResolver.Binding], Error>,
    _ expectedError: Error,
    file: StaticString = #file,
    line: UInt = #line
) {
    switch result {
    case .success(let bindings):
        let bindingsDesc = bindings.map { "\($0.package)@\($0.binding)" }.joined(separator: ", ")
        XCTFail("Expected unresolvable graph, found bindings instead: \(bindingsDesc)", file: file, line: line)
    case .failure(let foundError):
        XCTAssertEqual(String(describing: foundError), String(describing: expectedError), file: file, line: line)
    }
}

// FIXME: this is not thread-safe
public class MockContainer: PackageContainer {
    public typealias Dependency = (container: PackageReference, requirement: PackageRequirement, productFilter: ProductFilter)

    public var package: PackageReference
    var manifestName: PackageReference?

    var dependencies: [String: [String: [Dependency]]]

    public var unversionedDeps: [PackageContainerConstraint] = []

    /// The list of versions that have incompatible tools version.
    var toolsVersion: ToolsVersion = ToolsVersion.currentToolsVersion
    var versionsToolsVersions = [Version: ToolsVersion]()

    private var _versions: [BoundVersion]

    // TODO: this does not actually do anything with the tools-version
    public func toolsVersionsAppropriateVersionsDescending() throws -> [Version] {
        var versions: [Version] = []
        for version in self._versions.reversed() {
            guard case .version(let v) = version else { continue }
            versions.append(v)
        }
        return versions
    }

    public func versionsAscending() throws ->  [Version] {
        var versions: [Version] = []
        for version in self._versions {
            guard case .version(let v) = version else { continue }
            versions.append(v)
        }
        return versions
    }

    public func isToolsVersionCompatible(at version: Version) -> Bool {
        // this checks for *exact* version match which is good enough for our current tests
        if let toolsVersion = try? self.toolsVersion(for: version) {
            return self.toolsVersion == toolsVersion
        }
        
        return (try? self.toolsVersionsAppropriateVersionsDescending().contains(version)) ?? false
    }
    
    public func toolsVersion(for version: Version) throws -> ToolsVersion {
        struct NotFound: Error {}
        
        guard let version = versionsToolsVersions[version] else {
            throw NotFound()
        }
        return version
    }

    public func getDependencies(at version: Version, productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        return try getDependencies(at: version.description, productFilter: productFilter)
    }

    public func getDependencies(at revision: String, productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        guard let revisionDependencies = dependencies[revision] else {
            throw _MockLoadingError.unknownRevision
        }
        var filteredDependencies: [MockContainer.Dependency] = []
        for (product, productDependencies) in revisionDependencies where productFilter.contains(product) {
            filteredDependencies.append(contentsOf: productDependencies)
        }
        return filteredDependencies.map({ value in
            let (package, requirement, filter) = value
            return PackageContainerConstraint(package: package, requirement: requirement, products: filter)
        })
    }

    public func getUnversionedDependencies(productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        // FIXME: This is messy, remove unversionedDeps property.
        if !unversionedDeps.isEmpty {
            return unversionedDeps
        }
        return try getDependencies(at: PackageRequirement.unversioned.description, productFilter: productFilter)
    }

    public func getUpdatedIdentifier(at boundVersion: BoundVersion) throws -> PackageReference {
        if let manifestName = manifestName {
            self.package = self.package.with(newName: manifestName.identity.description)
        }
        return self.package
    }

    func appendVersion(_ version: BoundVersion) {
        self._versions.append(version)
        self._versions = self._versions
            .sorted(by: { lhs, rhs -> Bool in
                guard case .version(let lv) = lhs, case .version(let rv) = rhs else {
                    return true
                }
                return lv < rv
            })
    }

    public convenience init(
        package: PackageReference,
        unversionedDependencies: [(package: PackageReference, requirement: PackageRequirement, productFilter: ProductFilter)]
    ) {
        self.init(package: package)
        self.unversionedDeps = unversionedDependencies
            .map { PackageContainerConstraint(package: $0.package, requirement: $0.requirement, products: $0.productFilter) }
    }

    public convenience init(
        package: PackageReference,
        dependenciesByVersion: [Version: [String: [(
            package: PackageReference,
            requirement: VersionSetSpecifier,
            productFilter: ProductFilter
        )]]]) {
        var dependencies: [String: [String: [Dependency]]] = [:]
        for (version, productDependencies) in dependenciesByVersion {
            if dependencies[version.description] == nil {
                dependencies[version.description] = [:]
            }
            for (product, deps) in productDependencies {
                dependencies[version.description, default: [:]][product] = deps.map({
                    ($0.package, .versionSet($0.requirement), $0.productFilter)
                })
            }
        }
        self.init(package: package, dependencies: dependencies)
    }

    public init(
        package: PackageReference,
        dependencies: [String: [String: [Dependency]]] = [:]
    ) {
        self.package = package
        self.dependencies = dependencies
        let versions = dependencies.keys.compactMap(Version.init(string:))
        self._versions = versions
            .sorted()
            .map(BoundVersion.version)
    }
}

public enum _MockLoadingError: Error {
    case unknownModule
    case unknownRevision
}

public struct MockProvider: PackageContainerProvider {

    public let containers: [MockContainer]
    public let containersByIdentifier: [PackageReference: MockContainer]

    public init(containers: [MockContainer]) {
        self.containers = containers
        self.containersByIdentifier = Dictionary(uniqueKeysWithValues: containers.map({ ($0.package, $0) }))
    }

    public func getContainer(
        for package: PackageReference,
        skipUpdate: Bool,
        on queue: DispatchQueue,
        completion: @escaping (Result<PackageContainer, Error>
    ) -> Void) {
        queue.async {
            completion(self.containersByIdentifier[package].map{ .success($0) } ??
                .failure(_MockLoadingError.unknownModule))
        }
    }
}

class DependencyGraphBuilder {
    private var containers: [String: MockContainer] = [:]
    private var references: [String: PackageReference] = [:]

    func reference(for packageName: String) -> PackageReference {
        if let reference = self.references[packageName] {
            return reference
        }
        let newReference = PackageReference.remote(identity: PackageIdentity(packageName), location: "/\(packageName)")
        self.references[packageName] = newReference
        return newReference
    }

    func create(
        dependencies: Basics.OrderedDictionary<String, (PackageRequirement, ProductFilter)>
    ) -> [PackageContainerConstraint] {
        return dependencies.map {
            PackageContainerConstraint(package: reference(for: $0), requirement: $1.0, products: $1.1)
        }
    }

    func serve(
        _ package: String,
        at version: Version,
        toolsVersion: ToolsVersion? = nil,
        with dependencies: KeyValuePairs<String, Basics.OrderedDictionary<String, (PackageRequirement, ProductFilter)>> = [:]
    ) {
        serve(package, at: .version(version), toolsVersion: toolsVersion, with: dependencies)
    }

    func serve(
        _ package: String,
        at version: BoundVersion,
        toolsVersion: ToolsVersion? = nil,
        with dependencies: KeyValuePairs<String, Basics.OrderedDictionary<String, (PackageRequirement, ProductFilter)>> = [:]
    ) {
        let packageReference = reference(for: package)
        let container = self.containers[package] ?? MockContainer(package: packageReference)

        if case .version(let v) = version {
            container.versionsToolsVersions[v] = toolsVersion ?? container.toolsVersion
        }

        container.appendVersion(version)

        if container.dependencies[version.description] == nil {
            container.dependencies[version.description] = [:]
        }
        for (product, filteredDependencies) in dependencies {
            let packageDependencies: [MockContainer.Dependency] = filteredDependencies.map {
                (container: reference(for: $0), requirement: $1.0, products: $1.1)
            }
            container.dependencies[version.description, default: [:]][product, default: []] += packageDependencies
        }
        self.containers[package] = container
    }

    /// Creates a pins store with the given pins.
    func create(pinsStore pins: [String: (CheckoutState, ProductFilter)]) -> PinsStore {
        let fs = InMemoryFileSystem()
        let store = try! PinsStore(pinsFile: AbsolutePath("/tmp/Package.resolved"), fileSystem: fs, mirrors: .init())

        for (package, pin) in pins {
            store.pin(packageRef: reference(for: package), state: pin.0)
        }

        try! store.saveState()
        return store
    }

    func create(pinsMap: PinsStore.PinsMap = [:], log: Bool = false) -> PubgrubDependencyResolver {
        let delegate = log ? TracingDependencyResolverDelegate(stream: stdoutStream) : nil
        return self.create(pinsMap: pinsMap, delegate: delegate)
    }

    func create(pinsMap: PinsStore.PinsMap = [:], delegate: DependencyResolverDelegate?) -> PubgrubDependencyResolver {
        defer {
            self.containers = [:]
            self.references = [:]
        }
        let provider = MockProvider(containers: self.containers.values.map { $0 })
        return PubgrubDependencyResolver(provider :provider, pinsMap: pinsMap, delegate: delegate)
    }
}

extension Term: ExpressibleByStringLiteral {
    init(_ value: String) {
        self.init(stringLiteral: value)
    }

    public init(stringLiteral value: String) {
        var value = value

        var isPositive = true
        if value.hasPrefix("¬") {
            value.removeFirst()
            isPositive = false
        }

        var components: [String] = []
        var requirement: PackageRequirement?

        if value.contains("@") {
            components = value.split(separator: "@").map(String.init)
            if components[1].contains(".") {
                requirement = .versionSet(.exact(Version(stringLiteral: components[1])))
            }
        } else if value.contains("^") {
            components = value.split(separator: "^").map(String.init)
            let upperMajor = Int(String(components[1].split(separator: ".").first!))! + 1
            requirement = .versionSet(.range(Version(stringLiteral: components[1])..<Version(stringLiteral: "\(upperMajor).0.0")))
        } else if value.contains("-") {
            components = value.split(separator: "-").map(String.init)
            assert(components.count == 3, "expected `name-lowerBound-upperBound`")
            let (lowerBound, upperBound) = (components[1], components[2])
            requirement = .versionSet(.range(Version(stringLiteral: lowerBound)..<Version(stringLiteral: upperBound)))
        }

        let packageReference = PackageReference(identity: PackageIdentity(components[0]), kind: .remote, location: "", name: components[0])

        guard case let .versionSet(vs) = requirement! else {
            fatalError()
        }
        self.init(node: .product(packageReference.name, package: packageReference),
                  requirement: vs,
                  isPositive: isPositive)
    }
}

extension PackageReference: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        let ref = PackageReference.remote(identity: PackageIdentity(value), location: "")
        self = ref
    }

    init(_ name: String) {
        self.init(identity: PackageIdentity(name), kind: .remote, location: "")
    }
}
extension Result where Success == [DependencyResolver.Binding] {
    var errorMsg: String? {
        switch self {
        case .failure(let error):
            switch error {
            case let err as PubgrubDependencyResolver.PubgrubError:
                guard case .unresolvable(let msg) = err else {
                    XCTFail("Unexpected result \(self)")
                    return nil
                }
                return msg
            case let error as DependencyResolverError:
                return error.description
            default:
                XCTFail("Unexpected result \(self)")
        }
        default:
            XCTFail("Unexpected result \(self)")
        }
        return nil
    }
}
