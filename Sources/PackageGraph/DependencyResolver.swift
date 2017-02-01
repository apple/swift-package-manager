/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basic
import struct Utility.Version

public enum DependencyResolverError: Error {
    /// The resolver was unable to find a solution to the input constraints.
    case unsatisfiable
}

/// An abstract definition for a set of versions.
public enum VersionSetSpecifier: Equatable {
    /// The universal set.
    case any

    /// The empty set.
    case empty

    /// A non-empty range of version.
    case range(Range<Version>)

    /// The exact version that is required.
    case exact(Version)

    /// Compute the intersection of two set specifiers.
    public func intersection(_ rhs: VersionSetSpecifier) -> VersionSetSpecifier {
        switch (self, rhs) {
        case (.any, _):
            return rhs
        case (_, .any):
            return self
        case (.empty, _):
            return .empty
        case (_, .empty):
            return .empty
        case (.range(let lhs), .range(let rhs)):
            let start = Swift.max(lhs.lowerBound, rhs.lowerBound)
            let end = Swift.min(lhs.upperBound, rhs.upperBound)
            if start < end {
                return .range(start..<end)
            } else {
                return .empty
            }
        case (.exact(let v), _):
            if rhs.contains(v) {
                return self
            }
            return .empty
        case (_, .exact(let v)):
            if contains(v) {
                return rhs
            }
            return .empty
        default:
            // FIXME: Compiler should be able to prove this? https://bugs.swift.org/browse/SR-2221
            fatalError("not reachable: \(self), \(rhs)")
        }
    }

    /// Check if the set contains a version.
    public func contains(_ version: Version) -> Bool {
        switch self {
        case .empty:
            return false
        case .range(let range):
            return range.contains(version)
        case .any:
            return true
        case .exact(let v):
            return v == version
        }
    }
}
public func ==(_ lhs: VersionSetSpecifier, _ rhs: VersionSetSpecifier) -> Bool {
    switch (lhs, rhs) {
    case (.any, .any):
        return true
    case (.any, _):
        return false
    case (.empty, .empty):
        return true
    case (.empty, _):
        return false
    case (.range(let lhs), .range(let rhs)):
        return lhs == rhs
    case (.range, _):
        return false
    case (.exact(let lhs), .exact(let rhs)):
        return lhs == rhs
    case (.exact, _):
        return false
    }
}

/// An identifier which unambiguously references a package container.
///
/// This identifier is used to abstractly refer to another container when
/// encoding dependencies across packages.
public protocol PackageContainerIdentifier: Hashable { }

/// A container of packages.
///
/// This is the top-level unit of package resolution, i.e. the unit at which
/// versions are associated.
///
/// It represents a package container (e.g., a source repository) which can be
/// identified unambiguously and which contains a set of available package
/// versions and the ability to retrieve the dependency constraints for each of
/// those versions.
///
/// We use the "container" terminology here to differentiate between two
/// conceptual notions of what the package is: (1) informally, the repository
/// containing the package, but from which a package cannot be loaded by itself
/// and (2) the repository at a particular version, at which point the package
/// can be loaded and dependencies enumerated.
///
/// This is also designed in such a way to extend naturally to multiple packages
/// being contained within a single repository, should we choose to support that
/// later.
public protocol PackageContainer {
    /// The type of packages contained.
    associatedtype Identifier: PackageContainerIdentifier

    /// The identifier for the package.
    var identifier: Identifier { get }

    /// Get the list of versions which are available for the package.
    ///
    /// The list will be returned in sorted order, with the latest version *first*.
    /// All versions will not be requested at once. Resolver will request the next one only 
    /// if the previous one did not satisfy all constraints.
    var versions: AnySequence<Version> { get }

    /// Fetch the declared dependencies for a particular version.
    ///
    /// This property is expected to be efficient to access, and cached by the
    /// client if necessary.
    ///
    /// - Precondition: `versions.contains(version)`
    /// - Throws: If the version could not be resolved; this will abort
    ///   dependency resolution completely.
    //
    // FIXME: We should perhaps define some particularly useful error codes
    // here, so the resolver can handle errors more meaningfully.
    func getDependencies(at version: Version) throws -> [PackageContainerConstraint<Identifier>]
}

/// An interface for resolving package containers.
public protocol PackageContainerProvider {
    associatedtype Container: PackageContainer

    /// Get the container for a particular identifier asynchronously.
    func getContainer(for identifier: Container.Identifier, completion: @escaping (Result<Container, AnyError>) -> Void)
}

/// An individual constraint onto a container.
public struct PackageContainerConstraint<T: PackageContainerIdentifier>: CustomStringConvertible, Equatable {
    public typealias Identifier = T

    /// The requirement of this constraint.
    public enum Requirement: Equatable {

        /// The requirement is specified by the version set.
        case versionSet(VersionSetSpecifier)

        /// Un-versioned requirement i.e. a version should not resolved.
        case unversioned([PackageContainerConstraint<Identifier>])

        public static func ==(lhs: Requirement, rhs: Requirement) -> Bool {
            switch (lhs, rhs) {
            case (.unversioned(let lhs), .unversioned(let rhs)):
                return lhs == rhs
            case (.unversioned, _):
                return false
            case (.versionSet(let lhs), .versionSet(let rhs)):
                return lhs == rhs
            case (.versionSet, _):
                return false
            }
        }
    }

    /// The identifier for the container the constraint is on.
    public let identifier: Identifier

    /// The constraint requirement.
    public let requirement: Requirement

    /// Create a constraint requiring the given `container` satisfying the
    /// `requirement`.
    public init(container identifier: Identifier, requirement: Requirement) {
        self.identifier = identifier
        self.requirement = requirement
    }

    /// Create a constraint requiring the given `container` satisfying the
    /// `versionRequirement`.
    public init(container identifier: Identifier, versionRequirement: VersionSetSpecifier) {
        self.init(container: identifier, requirement: .versionSet(versionRequirement))
    }

    public var description: String {
        return "Constraint(\(identifier), \(requirement))"
    }

    public static func ==(lhs: PackageContainerConstraint, rhs: PackageContainerConstraint) -> Bool {
        return lhs.identifier == rhs.identifier && lhs.requirement == rhs.requirement
    }
}

/// Delegate interface for dependency resoler status.
public protocol DependencyResolverDelegate {
    associatedtype Identifier: PackageContainerIdentifier

    /// Called when a new container is being considered.
    func added(container identifier: Identifier)
}

/// A bound version for a package within an assignment.
//
// FIXME: This should be nested, but cannot be currently.
public enum BoundVersion: Equatable, CustomStringConvertible {
    /// The assignment should not include the package.
    ///
    /// This is different from the absence of an assignment for a particular
    /// package, which only indicates the assignment is agnostic to its
    /// version. This value signifies the package *may not* be present.
    case excluded

    /// The version of the package to include.
    case version(Version)

    /// The package assignment is unversioned.
    case unversioned

    public var description: String {
        switch self {
        case .excluded:
            return "excluded"
        case .version(let version):
            return version.description
        case .unversioned:
            return "unversioned"
        }
    }
}
public func ==(_ lhs: BoundVersion, _ rhs: BoundVersion) -> Bool {
    switch (lhs, rhs) {
    case (.excluded, .excluded):
        return true
    case (.excluded, _):
        return false
    case (.version(let lhs), .version(let rhs)):
        return lhs == rhs
    case (.version, _):
        return false
    case (.unversioned, .unversioned):
        return true
    case (.unversioned, _):
        return false
    }
}

/// A container for constraints for a set of packages.
///
/// This data structure is only designed to represent satisfiable constraint
/// sets, it cannot represent sets including containers which have an empty
/// constraint.
//
// FIXME: Maybe each package should just return this, instead of a list of
// `PackageContainerConstraint`s. That won't work if we decide this should
// eventually map based on the `Container` rather than the `Identifier`, though,
// so they are separate for now.
struct PackageContainerConstraintSet<C: PackageContainer>: Collection {
    typealias Container = C
    typealias Identifier = Container.Identifier
    typealias Requirement = PackageContainerConstraint<Identifier>.Requirement

    typealias Index = Dictionary<Identifier, Requirement>.Index
    typealias Element = Dictionary<Identifier, Requirement>.Element

    /// The set of constraints.
    private var constraints: [Identifier: Requirement]

    /// Create an empty constraint set.
    init() {
        self.constraints = [:]
    }

    /// Create an constraint set from known values.
    ///
    /// The initial constraints should never be unsatisfiable.
    init(_ constraints: [Identifier: Requirement]) {
        assert(constraints.values.filter({ $0 == .versionSet(.empty) }).isEmpty)
        self.constraints = constraints
    }

    /// The list of containers with entries in the set.
    var containerIdentifiers: AnySequence<Identifier> {
        return AnySequence<C.Identifier>(constraints.keys)
    }

    /// Get the version set specifier associated with the given package `identifier`.
    subscript(identifier: Identifier) -> Requirement {
        return constraints[identifier] ?? .versionSet(.any)
    }

    /// Create a constraint set by merging the `requirement` for container `identifier`.
    ///
    /// - Returns: The new set, or nil the resulting set is unsatisfiable.
    private func merging(
        requirement: Requirement, for identifier: Identifier
    ) -> PackageContainerConstraintSet<C>?
    {
        switch (requirement, self[identifier]) {
        case (.versionSet(let newSet), .versionSet(let currentSet)):
            // Try to intersect two version set requirements.
            let intersection = currentSet.intersection(newSet)
            if intersection == .empty {
                return nil
            }
            var result = self
            result.constraints[identifier] = .versionSet(intersection)
            return result
        case (.unversioned(let newConstraints), .unversioned(let currentConstraints)):
            // Two unversioned requirements can only merge if they both impose the same constraints.
            if newConstraints == currentConstraints {
                return self
            }
            return nil
        case (.unversioned, _):
            // Unversioned requirements always *wins*.
            var result = self
            result.constraints[identifier] = requirement
            return result
        case (_, .unversioned):
            // Unversioned requirements always *wins*.
            return self
        default:
            fatalError("Unreachable")
        }
    }

    /// Create a constraint set by merging `constraint`.
    ///
    /// - Returns: The new set, or nil the resulting set is unsatisfiable.
    func merging(_ constraint: PackageContainerConstraint<Identifier>) -> PackageContainerConstraintSet<C>? {
        return merging(requirement: constraint.requirement, for: constraint.identifier)
    }

    /// Create a new constraint set by merging the given constraint set.
    ///
    /// - Returns: False if the merger has made the set unsatisfiable; i.e. true
    /// when the resulting set is satisfiable, if it was already so.
    func merging(
        _ constraints: PackageContainerConstraintSet<Container>
    ) -> PackageContainerConstraintSet<C>?
    {
        var result = self
        for (key, requirement) in constraints {
            guard let merged = result.merging(requirement: requirement, for: key) else {
                return nil
            }
            result = merged
        }
        return result
    }

    // MARK: Collection Conformance

    var startIndex: Index {
        return constraints.startIndex
    }

    var endIndex: Index {
        return constraints.endIndex
    }

    func index(after i: Index) -> Index {
        return constraints.index(after: i)
    }

    subscript(position: Index) -> Element {
        return constraints[position]
    }
}

/// A container for version assignments for a set of packages, exposed as a
/// sequence of `Container` to `BoundVersion` bindings.
///
/// This is intended to be an efficient data structure for accumulating a set of
/// version assignments along with efficient access to the derived information
/// about the assignment (for example, the unified set of constraints it
/// induces).
///
/// The set itself is designed to only ever contain a consistent set of
/// assignments, i.e. each assignment should satisfy the induced
/// `constraints`, but this invariant is not explicitly enforced.
//
// FIXME: Actually make efficient.
struct VersionAssignmentSet<C: PackageContainer>: Equatable, Sequence {
    typealias Container = C
    typealias Identifier = Container.Identifier

    /// The assignment records.
    //
    // FIXME: Does it really make sense to key on the identifier here. Should we
    // require referential equality of containers and use that to simplify?
    fileprivate var assignments: [Identifier: (container: Container, binding: BoundVersion)]

    /// Create an empty assignment.
    init() {
        assignments = [:]
    }

    /// The assignment for the given container `identifier.
    subscript(identifier: Identifier) -> BoundVersion? {
        get {
            return assignments[identifier]?.binding
        }
    }

    /// The assignment for the given `container`.
    subscript(container: Container) -> BoundVersion? {
        get {
            return self[container.identifier]
        }
        set {
            // We disallow deletion.
            let newBinding = newValue!

            // Validate this is a valid assignment.
            assert(isValid(binding: newBinding, for: container))

            assignments[container.identifier] = (container: container, binding: newBinding)
        }
    }

    /// Create a new assignment set by merging in the bindings from `assignment`.
    ///
    /// - Returns: The new assignment, or nil if the merge cannot be made (the
    /// assignments contain incompatible versions).
    func merging(_ assignment: VersionAssignmentSet<Container>) -> VersionAssignmentSet<Container>? {
        // In order to protect the assignment set, we first have to test whether
        // the merged constraint sets are satisfiable.
        //
        // FIXME: This is very inefficient; we should decide whether it is right
        // to handle it here or force the main resolver loop to handle the
        // discovery of this property.
        guard let _ = constraints.merging(assignment.constraints) else {
            return nil
        }

        // The induced constraints are satisfiable, so we *can* union the
        // assignments without breaking our internal invariant on
        // satisfiability.
        var result = self
        for (container, binding) in assignment {
            if let existing = result[container] {
                if existing != binding {
                    return nil
                }
            } else {
                result[container] = binding
            }
        }

        return result
    }

    /// The combined version constraints induced by the assignment.
    ///
    /// This consists of the merged constraints which need to be satisfied on
    /// each package as a result of the versions selected in the assignment.
    ///
    /// The resulting constraint set is guaranteed to be non-empty for each
    /// mapping, assuming the invariants on the set are followed.
    //
    // FIXME: We need to cache this.
    var constraints: PackageContainerConstraintSet<Container> {
        // Collect all of the constraints.
        var result = PackageContainerConstraintSet<Container>()
        for (_, (container: container, binding: binding)) in assignments {
            switch binding {
            case .unversioned, .excluded:
                // If the package is unversioned or excluded, it doesn't contribute.
                continue

            case .version(let version):
                // If we have a version, add the constraints from that package version.
                //
                // FIXME: We should cache this too, possibly at a layer
                // different than above (like the entry record).
                //
                // FIXME: Error handling, except that we probably shouldn't have
                // needed to refetch the dependencies at this point.
                for constraint in try! container.getDependencies(at: version) {
                    guard let merged = result.merging(constraint) else {
                        preconditionFailure("unsatisfiable constraint set")
                    }
                    result = merged
                }
            }
        }
        return result
    }

    /// Check if the given `binding` for `container` is valid within the assignment.
    //
    // FIXME: This is currently very inefficient.
    func isValid(binding: BoundVersion, for container: Container) -> Bool {
        switch binding {
        case .excluded:
            // A package can be excluded if there are no constraints on the
            // package (it has not been requested by any other package in the
            // assignment).
            return constraints[container.identifier] == .versionSet(.any)

        case .version(let version):
            // A version is valid if it is contained in the constraints.
            if case .versionSet(let versionSet) = constraints[container.identifier] {
                return versionSet.contains(version)
            }
            return false

        case .unversioned:
            // An unversioned binding is always valid.
            return true
        }
    }

    /// Check if the assignment is valid and complete.
    func checkIfValidAndComplete() -> Bool {
        // Validity should hold trivially, because it is an invariant of the collection.
        for assignment in assignments.values {
            if !isValid(binding: assignment.binding, for: assignment.container) {
                return false
            }
        }

        // Check completeness, by simply looking at all the entries in the induced constraints.
        for identifier in constraints.containerIdentifiers {
            // Verify we have a non-excluded entry for this key.
            switch assignments[identifier]?.binding {
            case .unversioned?, .version?:
                continue
            case .excluded?, nil:
                return false
            }
        }

        return true
    }

    // MARK: Sequence Conformance

    // FIXME: This should really be a collection, but that takes significantly
    // more work given our current backing collection.

    typealias Iterator = AnyIterator<(Container, BoundVersion)>

    func makeIterator() -> Iterator {
        var it = assignments.values.makeIterator()
        return AnyIterator{
            if let next = it.next() {
                return (next.container, next.binding)
            } else {
                return nil
            }
        }
    }
}
func ==<C: PackageContainer>(lhs: VersionAssignmentSet<C>, rhs: VersionAssignmentSet<C>) -> Bool {
    if lhs.assignments.count != rhs.assignments.count { return false }
    for (container, lhsBinding) in lhs {
        switch rhs[container] {
        case let rhsBinding? where lhsBinding == rhsBinding:
            continue
        default:
            return false
        }
    }
    return true
}

/// A general purpose package dependency resolver.
///
/// This is a general purpose solver for the problem of:
///
/// Given an input list of constraints, where each constraint identifies a
/// container and version requirements, and, where each container supplies a
/// list of additional constraints ("dependencies") for an individual version,
/// then, choose an assignment of containers to versions such that:
///
/// 1. The assignment is complete: there exists an assignment for each container
/// listed in the union of the input constraint list and the dependency list for
/// every container in the assignment at the assigned version.
///
/// 2. The assignment is correct: the assigned version satisfies each constraint
/// referencing its matching container.
///
/// 3. The assignment is maximal: there is no other assignment satisfying #1 and
/// #2 such that all assigned version are greater than or equal to the versions
/// assigned in the result.
///
/// NOTE: It does not follow from #3 that this solver attempts to give an
/// "optimal" result. There may be many possible solutions satisfying #1, #2,
/// and #3, and optimality requires additional information (e.g. a
/// prioritization among packages).
///
/// As described, this problem is NP-complete (*). This solver currently
/// implements a basic depth-first greedy backtracking algorithm, and honoring
/// the order of dependencies as specified in the manifest file. The solver uses
/// persistent data structures to manage the accumulation of state along the
/// traversal, so the backtracking is not explicit, rather it is an implicit
/// side effect of the underlying copy-on-write data structures.
///
/// The resolver will always merge the complete set of immediate constraints for
/// a package (i.e., the version ranges of its immediate dependencies) into the
/// constraint set *before* traversing into any dependency. This property allows
/// packages to manually work around performance issues in the resolution
/// algorithm by _lifting_ problematic dependency constraints up to be immediate
/// dependencies.
///
/// There is currently no external control offered by the solver over _which_
/// solution satisfying the properties above is selected, if more than one are
/// possible. In practice, the algorithm is designed such that it will
/// effectively prefer (i.e., optimize for the newest version of) dependencies
/// which are earliest in the depth-first, pre-order, traversal.
///
/// (*) Via reduction from 3-SAT: Introduce a package for each variable, with
/// two versions representing true and false. For each clause `C_n`, introduce a
/// package `P(C_n)` representing the clause, with three versions; one for each
/// satisfying assignment of values to a literal with the corresponding precise
/// constraint on the input packages. Finally, construct an input constraint
/// list including a dependency on each clause package `P(C_n)` and an
/// open-ended version constraint. The given input is satisfiable iff the input
/// 3-SAT instance is.
public class DependencyResolver<
    P: PackageContainerProvider,
    D: DependencyResolverDelegate
> where P.Container.Identifier == D.Identifier
{
    public typealias Provider = P
    public typealias Delegate = D
    public typealias Container = Provider.Container
    public typealias Identifier = Container.Identifier

    /// The type of the constraints the resolver operates on.
    ///
    /// Technically this is a container constraint, but that is currently the
    /// only kind of constraints we operate on.
    public typealias Constraint = PackageContainerConstraint<Identifier>

    /// The type of constraint set  the resolver operates on.
    typealias ConstraintSet = PackageContainerConstraintSet<Container>

    /// The type of assignment the resolver operates on.
    typealias AssignmentSet = VersionAssignmentSet<Container>

    /// The container provider used to load package containers.
    public let provider: Provider

    /// The resolver's delegate.
    public let delegate: Delegate

    /// Should resolver prefetch the containers.
    private let enablePrefetching: Bool

    /// Contains any error encountered during dependency resolution.
    // FIXME: @testable private
    var error: Swift.Error?

    public init(_ provider: Provider, _ delegate: Delegate, enablePrefetching: Bool = false) {
        self.provider = provider
        self.delegate = delegate
        self.enablePrefetching = enablePrefetching
    }

    /// Execute the resolution algorithm to find a valid assignment of versions.
    ///
    /// - Parameters:
    ///   - constraints: The contraints to solve. It is legal to supply multiple
    ///                  constraints for the same container identifier.
    /// - Returns: A satisfying assignment of containers and their version binding.
    /// - Throws: DependencyResolverError, or errors from the underlying package provider.
    public func resolve(constraints: [Constraint]) throws -> [(container: Identifier, binding: BoundVersion)] {
        return try resolveAssignment(constraints: constraints).map{ ($0.identifier, $1) }
    }

    /// Execute the resolution algorithm to find a valid assignment of versions.
    ///
    /// - Parameters:
    ///   - constraints: The contraints to solve. It is legal to supply multiple
    ///                  constraints for the same container identifier.
    /// - Returns: A satisfying assignment of containers and versions.
    /// - Throws: DependencyResolverError, or errors from the underlying package provider.
    func resolveAssignment(constraints: [Constraint]) throws -> AssignmentSet {
        // Create an assignment for the input constraints.
        guard let assignment = merge(
                constraints: constraints, into: AssignmentSet(),
                subjectTo: ConstraintSet(), excluding: [:]).first(where: { _ in true }) else {
            // Throw any error encountered during resolution.
            if let error = error {
                throw error
            }
            throw DependencyResolverError.unsatisfiable
        }
        return assignment
    }

    /// Resolve an individual container dependency tree.
    ///
    /// This is the primary method in our bottom-up algorithm for resolving
    /// dependencies. The inputs define an active set of constraints and set of
    /// versions to exclude (conceptually the latter could be merged with the
    /// former, but it is convenient to separate them in our
    /// implementation). The result is a sequence of all valid assignments for
    /// this container's subtree.
    ///
    /// - Parameters:
    ///   - container: The container to resolve.
    ///   - constraints: The external constraints which must be honored by the solution.
    ///   - exclusions: The list of individually excluded package versions.
    /// - Returns: A sequence of feasible solutions, starting with the most preferable.
    //
    // FIXME: This needs to a way to return information on the failure, or we
    // will need to have it call the delegate directly.
    //
    // FIXME: @testable private
    func resolveSubtree(
        _ container: Container,
        subjectTo allConstraints: ConstraintSet,
        excluding allExclusions: [Identifier: Set<Version>]
    ) -> AnySequence<AssignmentSet> {
        func validVersions(_ container: Container, in versionSet: VersionSetSpecifier) -> AnyIterator<Version> {
            let exclusions = allExclusions[container.identifier] ?? Set()
            let it = container.versions.makeIterator()
            return AnyIterator{ () -> Version? in
                while let version = it.next() {
                    if versionSet.contains(version) && !exclusions.contains(version) {
                        return version
                    }
                }
                return nil
            }
        }

        // Helper method to abstract passing common parameters to merge().
        //
        // FIXME: We must detect recursion here.
        func merge(constraints: [Constraint], binding: BoundVersion) -> AnySequence<AssignmentSet> {
            // Create an assignment for the container.
            var assignment = AssignmentSet()
            assignment[container] = binding

            return AnySequence(self.merge(
                constraints: constraints,
                into: assignment, subjectTo: allConstraints, excluding: allExclusions).lazy.map{ result in
                // We found a complete valid assignment.
                assert(result.checkIfValidAndComplete())
                return result
            })
        }

        switch allConstraints[container.identifier] {
        case .unversioned(let constraints):
            // Merge the dependencies of unversioned constraint into the assignment.
            return merge(constraints: constraints, binding: .unversioned)

        case .versionSet(let versionSet):
            // Attempt to select each valid version in the preferred order.
            return AnySequence(validVersions(container, in: versionSet).lazy.flatMap{ version -> AnySequence<AssignmentSet> in
                // If we had encountered any error, return early.
                guard self.error == nil else { return AnySequence([]) }

                // Get the constraints for this container version and update the assignment to include each one.
                // FIXME: Making these methods throwing will kill the lazy behavior.
                guard let constraints = self.safely({ try container.getDependencies(at: version) }) else {
                    return AnySequence([])
                }
                return merge(constraints: constraints, binding: .version(version))
            })
        }
    }

    /// Find all solutions for `constraints` with the results merged into the `assignment`.
    ///
    /// - Parameters:
    ///   - constraints: The input list of constraints to solve.
    ///   - assignment: The assignment to merge the result into.
    ///   - allConstraints: An additional set of constraints on the viable solutions.
    ///   - allExclusions: A set of package assignments to exclude from consideration.
    /// - Returns: A sequence of all valid satisfying assignment, in order of preference.
    private func merge(
        constraints: [Constraint],
        into assignment: AssignmentSet,
        subjectTo allConstraints: ConstraintSet,
        excluding allExclusions: [Identifier: Set<Version>]
    ) -> AnySequence<AssignmentSet> {
        var allConstraints = allConstraints

        if enablePrefetching {
            // Ask all of these containers upfront to do async cloning.
            for constraint in constraints {
                provider.getContainer(for: constraint.identifier) { _ in }
            }
        }

        // Update the active constraint set to include all active constraints.
        //
        // We want to put all of these constraints in up front so that we are
        // more likely to get back a viable solution.
        //
        // FIXME: We should have a test for this, probably by adding some kind
        // of statistics on the number of backtracks.
        for constraint in constraints {
            guard let merged = allConstraints.merging(constraint) else {
                return AnySequence([])
            }
            allConstraints = merged
        }

        // Perform an (eager) reduction merging each container into the (lazy)
        // sequence of possible assignments.
        //
        // NOTE: What we are *accumulating* here is a lazy sequence (of
        // solutions) satisfying some number of the constraints; the final lazy
        // sequence is effectively one which has all of the constraints
        // merged. Thus, the reduce itself can be eager since the result is
        // lazy.
        return AnySequence(constraints.map{ $0.identifier }.reduce(AnySequence([(assignment, allConstraints)])) { (possibleAssignments, identifier) -> AnySequence<(AssignmentSet, ConstraintSet)> in
                    // If we had encountered any error, return early.
                    guard self.error == nil else { return AnySequence([]) }

                    // Get the container.
                    //
                    // Failures here will immediately abort the solution, although in
                    // theory one could imagine attempting to find a solution not
                    // requiring this container. It isn't clear that is something we
                    // would ever want to handle at this level.
                    //
                    // FIXME: Making these methods throwing will kill the lazy behavior,
                    guard let container = safely({ try getContainer(for: identifier) }) else {
                        return AnySequence([])
                    }

                    // Return a new lazy sequence merging all possible subtree solutions into all possible incoming assignments.
                    return AnySequence(possibleAssignments.lazy.flatMap{ (assignment, allConstraints) -> AnySequence<(AssignmentSet, ConstraintSet)> in
                            return AnySequence(self.resolveSubtree(
                                    container, subjectTo: allConstraints, excluding: allExclusions).lazy.flatMap{ subtreeAssignment -> (AssignmentSet, ConstraintSet)? in
                                    // We found a valid subtree assignment, attempt to merge it with the
                                    // current solution.
                                    guard let newAssignment = assignment.merging(subtreeAssignment) else {
                                        // The assignment couldn't be merged with the current
                                        // assignment, or the constraint sets couldn't be merged.
                                        //
                                        // This happens when (a) the subtree has a package overlapping
                                        // with a previous subtree assignment, and (b) the subtrees
                                        // needed to resolve different versions due to constraints not
                                        // present in the top-down constraint set.
                                        return nil
                                    }

                                    // Update the working assignment and constraint set.
                                    //
                                    // This should always be feasible, because all prior constraints
                                    // were part of the input constraint request (see comment around
                                    // initial `merge` outside the loop).
                                    guard let merged = allConstraints.merging(subtreeAssignment.constraints) else {
                                        preconditionFailure("unsatisfiable constraints while merging subtree")
                                    }

                                    // We found a valid assignment and updated constraint set.
                                    return (newAssignment, merged)
                                })
                        })
            }.lazy.map{ $0.0 })
    }
    
    /// Executes the body and return the value if the body doesn't throw.
    /// Returns nil if the body throws and save the error.
    private func safely<T>(_ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            self.error = error
        }
        return nil
    }

    // MARK: Container Management

    /// The active set of managed containers.
    public private(set) var containers: [Identifier: Container] = [:]

    /// Get the container for the given identifier, loading it if necessary.
    private func getContainer(for identifier: Identifier) throws -> Container {
        // Return the cached container, if available.
        if let container = containers[identifier] {
            return container
        }

        // Otherwise, load it.
        return try addContainer(for: identifier)
    }

    /// Add a managed container.
    //
    // FIXME: In order to support concurrent fetching of dependencies, we need
    // to have some measure of asynchronicity here.
    private func addContainer(for identifier: Identifier) throws -> Container {
        assert(!containers.keys.contains(identifier))
        // Get the container synchronously from provider.
        let container = try await { provider.getContainer(for: identifier, completion: $0) }
        containers[identifier] = container

        // Inform the delegate we are considering a new container.
        delegate.added(container: identifier)

        return container
    }
}
