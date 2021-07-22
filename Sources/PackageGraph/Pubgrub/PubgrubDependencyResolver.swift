/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2019 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
import Dispatch
import PackageModel
import TSCBasic
import TSCUtility

/// The solver that is able to transitively resolve a set of package constraints
/// specified by a root package.
public struct PubgrubDependencyResolver {
    /// The type of the constraints the resolver operates on.
    public typealias Constraint = PackageContainerConstraint

    /// the mutable state that get computed
    internal final class State {
        /// The root package reference.
        let root: DependencyResolutionNode

        /// The list of packages that are overridden in the graph. A local package reference will
        /// always override any other kind of package reference and branch-based reference will override
        /// version-based reference.
        let overriddenPackages: [PackageReference: (version: BoundVersion, products: ProductFilter)]

        /// A collection of all known incompatibilities matched to the packages they
        /// refer to. This means an incompatibility can occur several times.
        public private(set) var incompatibilities: [DependencyResolutionNode: [Incompatibility]] = [:]

        /// The current best guess for a solution satisfying all requirements.
        public private(set) var solution: PartialSolution

        private let lock = Lock()

        init(root: DependencyResolutionNode,
             overriddenPackages: [PackageReference: (version: BoundVersion, products: ProductFilter)] = [:],
             solution: PartialSolution = PartialSolution()) {
            self.root = root
            self.overriddenPackages = overriddenPackages
            self.solution = solution
        }

        func addIncompatibility(_ incompatibility: Incompatibility, at location: LogLocation) {
            self.lock.withLock {
                // log("incompat: \(incompatibility) \(location)")
                for package in incompatibility.terms.map({ $0.node }) {
                    if let incompats = self.incompatibilities[package] {
                        if !incompats.contains(incompatibility) {
                            self.incompatibilities[package]!.append(incompatibility)
                        }
                    } else {
                        self.incompatibilities[package] = [incompatibility]
                    }
                }
            }
        }

        /// Find all incompatibilities containing a positive term for a given package.
        func positiveIncompatibilities(for node: DependencyResolutionNode) -> [Incompatibility]? {
            self.lock.withLock {
                guard let all = self.incompatibilities[node] else {
                    return nil
                }
                return all.filter {
                    $0.terms.first { $0.node == node }!.isPositive
                }
            }
        }

        func decide(_ node: DependencyResolutionNode, at version: Version) {
            let term = Term(node, .exact(version))
            self.lock.withLock {
                // FIXME: Shouldn't we check this _before_ making a decision?
                assert(term.isValidDecision(for: self.solution))
                self.solution.decide(node, at: version)
            }
        }

        func derive(_ term: Term, cause: Incompatibility) {
            self.lock.withLock {
                self.solution.derive(term, cause: cause)
            }
        }

        func backtrack(toDecisionLevel: Int) {
            self.lock.withLock {
                self.solution.backtrack(toDecisionLevel: toDecisionLevel)
            }
        }
    }

    /// Reference to the pins store, if provided.
    private let pinsMap: PinsStore.PinsMap

    /// The container provider used to load package containers.
    private let provider: ContainerProvider

    /// Skip updating containers while fetching them.
    private let skipUpdate: Bool

    /// Reference to the package container provider.
    private let packageContainerProvider: PackageContainerProvider

    /// Should resolver prefetch the containers.
    private let isPrefetchingEnabled: Bool

    /// Resolver delegate
    private let delegate: DependencyResolverDelegate?

    public init(
        provider: PackageContainerProvider,
        pinsMap: PinsStore.PinsMap = [:],
        isPrefetchingEnabled: Bool = false,
        skipUpdate: Bool = false,
        delegate: DependencyResolverDelegate? = nil
    ) {
        self.packageContainerProvider = provider
        self.pinsMap = pinsMap
        self.isPrefetchingEnabled = isPrefetchingEnabled
        self.skipUpdate = skipUpdate
        self.provider = ContainerProvider(provider: self.packageContainerProvider, skipUpdate: self.skipUpdate, pinsMap: self.pinsMap)
        self.delegate = delegate
    }

    /// Execute the resolution algorithm to find a valid assignment of versions.
    public func solve(constraints: [Constraint]) -> Result<[DependencyResolver.Binding], Error> {
        let root = DependencyResolutionNode.root(package: .root(
            identity: .plain("<synthesized-root>"),
            path: .root
        ))

        do {
            // strips state
            return .success(try self.solve(root: root, constraints: constraints).bindings)
        } catch {
            var error = error

            // If version solving failing, build the user-facing diagnostic.
            if let pubGrubError = error as? PubgrubError, let rootCause = pubGrubError.rootCause, let incompatibilities = pubGrubError.incompatibilities {
                var builder = DiagnosticReportBuilder(
                    root: root,
                    incompatibilities: incompatibilities,
                    provider: self.provider
                )

                do {
                    let diagnostic = try builder.makeErrorReport(for: rootCause)
                    error = PubgrubError.unresolvable(diagnostic)
                } catch {
                    // failed to construct the report, will report the original error
                }
            }

            return .failure(error)
        }
    }

    /// Find a set of dependencies that fit the given constraints. If dependency
    /// resolution is unable to provide a result, an error is thrown.
    /// - Warning: It is expected that the root package reference has been set  before this is called.
    internal func solve(root: DependencyResolutionNode, constraints: [Constraint]) throws -> (bindings: [DependencyResolver.Binding], state: State) {
        // first process inputs
        let inputs = try self.processInputs(root: root, with: constraints)

        // Prefetch the containers if prefetching is enabled.
        if self.isPrefetchingEnabled {
            // We avoid prefetching packages that are overridden since
            // otherwise we'll end up creating a repository container
            // for them.
            let pins = self.pinsMap.values
                .map { $0.packageRef }
                .filter { !inputs.overriddenPackages.keys.contains($0) }
            self.provider.prefetch(containers: pins)
        }

        let state = State(root: root, overriddenPackages: inputs.overriddenPackages)

        // Decide root at v1.
        state.decide(state.root, at: "1.0.0")

        // Add the root incompatibility.
        state.addIncompatibility(Incompatibility(terms: [Term(not: root, .exact("1.0.0"))], cause: .root), at: .topLevel)

        // Add inputs root incompatibilities.
        for incompatibility in inputs.rootIncompatibilities {
            state.addIncompatibility(incompatibility, at: .topLevel)
        }

        try self.run(state: state)

        let decisions = state.solution.assignments.filter { $0.isDecision }
        var flattenedAssignments: [PackageReference: (binding: BoundVersion, products: ProductFilter)] = [:]
        for assignment in decisions {
            if assignment.term.node == state.root {
                continue
            }

            let boundVersion: BoundVersion
            switch assignment.term.requirement {
            case .exact(let version):
                boundVersion = .version(version)
            case .range, .any, .empty, .ranges:
                throw InternalError("unexpected requirement value for assignment \(assignment.term)")
            }

            let products = assignment.term.node.productFilter

            // TODO: replace with async/await when available
            let container = try temp_await { provider.getContainer(for: assignment.term.node.package, completion: $0) }
            let identifier = try container.underlying.getUpdatedIdentifier(at: boundVersion)

            if var existing = flattenedAssignments[identifier] {
                assert(existing.binding == boundVersion, "Two products in one package resolved to different versions: \(existing.products)@\(existing.binding) vs \(products)@\(boundVersion)")
                existing.products.formUnion(products)
                flattenedAssignments[identifier] = existing
            } else {
                flattenedAssignments[identifier] = (binding: boundVersion, products: products)
            }
        }
        var finalAssignments: [DependencyResolver.Binding]
            = flattenedAssignments.keys.sorted(by: { $0.name < $1.name }).map { package in
                let details = flattenedAssignments[package]!
                return (package: package, binding: details.binding, products: details.products)
            }

        // Add overriden packages to the result.
        for (package, override) in state.overriddenPackages {
            // TODO: replace with async/await when available
            let container = try temp_await { provider.getContainer(for: package, completion: $0) }
            let identifier = try container.underlying.getUpdatedIdentifier(at: override.version)
            finalAssignments.append((identifier, override.version, override.products))
        }

        self.delegate?.solved(result: finalAssignments)

        return (finalAssignments, state)
    }

    private func processInputs(
        root: DependencyResolutionNode,
        with constraints: [Constraint]
    ) throws -> (
        overriddenPackages: [PackageReference: (version: BoundVersion, products: ProductFilter)],
        rootIncompatibilities: [Incompatibility]
    ) {
        // The list of constraints that we'll be working with. We start with the input constraints
        // and process them in two phases. The first phase finds all unversioned constraints and
        // the second phase discovers all branch-based constraints.
        var constraints = OrderedSet(constraints)

        // The list of packages that are overridden in the graph. A local package reference will
        // always override any other kind of package reference and branch-based reference will override
        // version-based reference.
        var overriddenPackages: [PackageReference: (version: BoundVersion, products: ProductFilter)] = [:]

        // The list of version-based references reachable via local and branch-based references.
        // These are added as top-level incompatibilities since they always need to be statisfied.
        // Some of these might be overridden as we discover local and branch-based references.
        var versionBasedDependencies: [DependencyResolutionNode: [VersionBasedConstraint]] = [:]

        // Process unversioned constraints in first phase. We go through all of the unversioned packages
        // and collect them and their dependencies. This gives us the complete list of unversioned
        // packages in the graph since unversioned packages can only be refered by other
        // unversioned packages.
        while let constraint = constraints.first(where: { $0.requirement == .unversioned }) {
            constraints.remove(constraint)

            // Mark the package as overridden.
            if var existing = overriddenPackages[constraint.package] {
                assert(existing.version == .unversioned, "Overridden package is not unversioned: \(constraint.package)@\(existing.version)")
                existing.products.formUnion(constraint.products)
                overriddenPackages[constraint.package] = existing
            } else {
                overriddenPackages[constraint.package] = (version: .unversioned, products: constraint.products)
            }

            for node in constraint.nodes() {
                // Process dependencies of this package.
                //
                // We collect all version-based dependencies in a separate structure so they can
                // be process at the end. This allows us to override them when there is a non-version
                // based (unversioned/branch-based) constraint present in the graph.
                // TODO: replace with async/await when available
                let container = try temp_await { provider.getContainer(for: node.package, completion: $0) }
                for dependency in try container.underlying.getUnversionedDependencies(productFilter: node.productFilter) {
                    if let versionedBasedConstraints = VersionBasedConstraint.constraints(dependency) {
                        for constraint in versionedBasedConstraints {
                            versionBasedDependencies[node, default: []].append(constraint)
                        }
                    } else if !overriddenPackages.keys.contains(dependency.package) {
                        // Add the constraint if its not already present. This will ensure we don't
                        // end up looping infinitely due to a cycle (which are diagnosed seperately).
                        constraints.append(dependency)
                    }
                }
            }
        }

        // Process revision-based constraints in the second phase. Here we do the similar processing
        // as the first phase but we also ignore the constraints that are overriden due to
        // presence of unversioned constraints.
        while let constraint = constraints.first(where: { $0.requirement.isRevision }) {
            guard case .revision(let revision) = constraint.requirement else {
                throw InternalError("Expected revision requirement")
            }
            constraints.remove(constraint)
            let package = constraint.package

            // Check if there is an existing value for this package in the overridden packages.
            switch overriddenPackages[package]?.version {
            case .excluded?, .version?:
                // These values are not possible.
                throw InternalError("Unexpected value for overriden package \(package) in \(overriddenPackages)")
            case .unversioned?:
                // This package is overridden by an unversioned package so we can ignore this constraint.
                continue
            case .revision(let existingRevision, let branch)?:
                // If this branch-based package was encountered before, ensure the references match.
                if (branch ?? existingRevision) != revision {
                    // FIXME: Improve diagnostics here.
                    let lastPathComponent = String(package.location.split(separator: "/").last!).spm_dropGitSuffix()
                    throw PubgrubError.unresolvable("\(lastPathComponent) is required using two different revision-based requirements (\(existingRevision) and \(revision)), which is not supported")
                } else {
                    // Otherwise, continue since we've already processed this constraint. Any cycles will be diagnosed separately.
                    continue
                }
            case nil:
                break

            }

            // Process dependencies of this package, similar to the first phase but branch-based dependencies
            // are not allowed to contain local/unversioned packages.
            // TODO: replace with async/await when avail
            let container = try temp_await { provider.getContainer(for: package, completion: $0) }

            // If there is a pin for this revision-based dependency, get
            // the dependencies at the pinned revision instead of using
            // latest commit on that branch. Note that if this revision-based dependency is
            // already a commit, then its pin entry doesn't matter in practice.
            let revisionForDependencies: String
            if let pin = pinsMap[package.identity], pin.state.branch == revision {
                revisionForDependencies = pin.state.revision.identifier

                // Mark the package as overridden with the pinned revision and record the branch as well.
                overriddenPackages[package] = (version: .revision(revisionForDependencies, branch: revision), products: constraint.products)
            } else {
                revisionForDependencies = revision
                
                // Mark the package as overridden.
                overriddenPackages[package] = (version: .revision(revision), products: constraint.products)
            }

            for node in constraint.nodes() {
                var unprocessedDependencies = try container.underlying.getDependencies(
                    at: revisionForDependencies,
                    productFilter: constraint.products
                )
                if let sharedRevision = node.revisionLock(revision: revision) {
                    unprocessedDependencies.append(sharedRevision)
                }
                for dependency in unprocessedDependencies {
                    switch dependency.requirement {
                    case .versionSet(let req):
                        for node in dependency.nodes() {
                            let versionedBasedConstraint = VersionBasedConstraint(node: node, req: req)
                            versionBasedDependencies[node, default: []].append(versionedBasedConstraint)
                        }
                    case .revision:
                        constraints.append(dependency)
                    case .unversioned:
                        throw DependencyResolverError.revisionDependencyContainsLocalPackage(
                            dependency: package.name,
                            localPackage: dependency.package.name
                        )
                    }
                }
            }
        }

        // At this point, we should be left with only version-based requirements in our constraints
        // list. Add them to our version-based dependency list.
        for dependency in constraints {
            switch dependency.requirement {
            case .versionSet(let req):
                for node in dependency.nodes() {
                    let versionedBasedConstraint = VersionBasedConstraint(node: node, req: req)
                    // FIXME: It would be better to record where this constraint came from, instead of just
                    // using root.
                    versionBasedDependencies[root, default: []].append(versionedBasedConstraint)
                }
            case .revision, .unversioned:
                throw InternalError("Unexpected revision/unversioned requirement in the constraints list: \(constraints)")
            }
        }

        // Finally, compute the root incompatibilities (which will be all version-based).
        var rootIncompatibilities: [Incompatibility] = []
        for (node, constraints) in versionBasedDependencies {
            for constraint in constraints {
                if overriddenPackages.keys.contains(constraint.node.package) { continue }

                let incompat = try Incompatibility(
                    Term(root, .exact("1.0.0")),
                    Term(not: constraint.node, constraint.requirement),
                    root: root,
                    cause: .dependency(node: node)
                )
                rootIncompatibilities.append(incompat)
            }
        }

        return (overriddenPackages, rootIncompatibilities)
    }

    /// Perform unit propagation, resolving conflicts if necessary and making
    /// decisions if nothing else is left to be done.
    /// After this method returns `solution` is either populated with a list of
    /// final version assignments or an error is thrown.
    private func run(state: State) throws {
        var next: DependencyResolutionNode? = state.root

        while let nxt = next {
            try self.propagate(state: state, node: nxt)

            // initiate prefetch of known packages that will be used to make the decision on the next step
            self.provider.prefetch(containers: state.solution.undecided.map { $0.node.package })

            // If decision making determines that no more decisions are to be
            // made, it returns nil to signal that version solving is done.
            // TODO: replace with async/await when available
            next = try temp_await { self.makeDecision(state: state, completion: $0) }
        }
    }

    /// Perform unit propagation to derive new assignments based on the current
    /// partial solution.
    /// If a conflict is found, the conflicting incompatibility is returned to
    /// resolve the conflict on.
    internal func propagate(state: State, node: DependencyResolutionNode) throws {
        var changed: Basics.OrderedSet<DependencyResolutionNode> = [node]

        while !changed.isEmpty {
            let package = changed.removeFirst()
            loop: for incompatibility in state.positiveIncompatibilities(for: package)?.reversed() ?? [] {
                let result = self.propagate(state: state, incompatibility: incompatibility)

                switch result {
                case .conflict:
                    let rootCause = try self.resolve(state: state, conflict: incompatibility)
                    let rootCauseResult = self.propagate(state: state, incompatibility: rootCause)

                    guard case .almostSatisfied(let pkg) = rootCauseResult else {
                        throw InternalError("""
                        Expected root cause \(rootCause) to almost satisfy the \
                        current partial solution:
                        \(state.solution.assignments.map { " * \($0.description)" }.joined(separator: "\n"))\n
                        """)
                    }

                    changed.removeAll(keepingCapacity: false)
                    changed.append(pkg)

                    break loop
                case .almostSatisfied(let package):
                    changed.append(package)
                case .none:
                    break
                }
            }
        }
    }

    private func propagate(state: State, incompatibility: Incompatibility) -> PropagationResult {
        var unsatisfied: Term?

        for term in incompatibility.terms {
            let relation = state.solution.relation(with: term)

            if relation == .disjoint {
                return .none
            } else if relation == .overlap {
                if unsatisfied != nil {
                    return .none
                }
                unsatisfied = term
            }
        }

        // We have a conflict if all the terms of the incompatibility were satisfied.
        guard let unsatisfiedTerm = unsatisfied else {
            return .conflict
        }

        self.delegate?.derived(term: unsatisfiedTerm.inverse)
        state.derive(unsatisfiedTerm.inverse, cause: incompatibility)

        return .almostSatisfied(node: unsatisfiedTerm.node)
    }

    // Based on:
    // https://github.com/dart-lang/pub/tree/master/doc/solver.md#conflict-resolution
    // https://github.com/dart-lang/pub/blob/master/lib/src/solver/version_solver.dart#L201
    internal func resolve(state: State, conflict: Incompatibility) throws -> Incompatibility {
        self.delegate?.conflict(conflict: conflict)

        var incompatibility = conflict
        var createdIncompatibility = false

        while !isCompleteFailure(incompatibility, root: state.root) {
            var mostRecentTerm: Term?
            var mostRecentSatisfier: Assignment?
            var difference: Term?
            var previousSatisfierLevel = 0

            for term in incompatibility.terms {
                let satisfier = try state.solution.satisfier(for: term)

                if let _mostRecentSatisfier = mostRecentSatisfier {
                    let mostRecentSatisfierIdx = state.solution.assignments.firstIndex(of: _mostRecentSatisfier)!
                    let satisfierIdx = state.solution.assignments.firstIndex(of: satisfier)!

                    if mostRecentSatisfierIdx < satisfierIdx {
                        previousSatisfierLevel = max(previousSatisfierLevel, _mostRecentSatisfier.decisionLevel)
                        mostRecentTerm = term
                        mostRecentSatisfier = satisfier
                        difference = nil
                    } else {
                        previousSatisfierLevel = max(previousSatisfierLevel, satisfier.decisionLevel)
                    }
                } else {
                    mostRecentTerm = term
                    mostRecentSatisfier = satisfier
                }

                if mostRecentTerm == term {
                    difference = mostRecentSatisfier?.term.difference(with: term)
                    if let difference = difference {
                        previousSatisfierLevel = max(previousSatisfierLevel, try state.solution.satisfier(for: difference.inverse).decisionLevel)
                    }
                }
            }

            guard let _mostRecentSatisfier = mostRecentSatisfier else {
                throw InternalError("mostRecentSatisfier not set")
            }

            if previousSatisfierLevel < _mostRecentSatisfier.decisionLevel || _mostRecentSatisfier.cause == nil {
                state.backtrack(toDecisionLevel: previousSatisfierLevel)
                if createdIncompatibility {
                    state.addIncompatibility(incompatibility, at: .conflictResolution)
                }
                return incompatibility
            }

            let priorCause = _mostRecentSatisfier.cause!

            var newTerms = incompatibility.terms.filter { $0 != mostRecentTerm }
            newTerms += priorCause.terms.filter { $0.node != _mostRecentSatisfier.term.node }

            if let _difference = difference {
                newTerms.append(_difference.inverse)
            }

            incompatibility = try Incompatibility(
                OrderedSet(newTerms),
                root: state.root,
                cause: .conflict(cause: .init(conflict: incompatibility, other: priorCause))
            )
            createdIncompatibility = true

            if let term = mostRecentTerm {
                if let diff = difference {
                    self.delegate?.partiallySatisfied(term: term, by: _mostRecentSatisfier, incompatibility: incompatibility, difference: diff)
                } else {
                    self.delegate?.satisfied(term: term, by: _mostRecentSatisfier, incompatibility: incompatibility)
                }
            }
        }

        self.delegate?.failedToResolve(incompatibility: incompatibility)
        throw PubgrubError._unresolvable(incompatibility, state.incompatibilities)
    }

    /// Does a given incompatibility specify that version solving has entirely
    /// failed, meaning this incompatibility is either empty or only for the root
    /// package.
    private func isCompleteFailure(_ incompatibility: Incompatibility, root: DependencyResolutionNode) -> Bool {
        return incompatibility.terms.isEmpty || (incompatibility.terms.count == 1 && incompatibility.terms.first?.node == root)
    }

    private func computeCounts(for terms: [Term], completion: @escaping (Result<[Term: Int], Error>) -> Void) {
        if terms.isEmpty {
            return completion(.success([:]))
        }

        let sync = DispatchGroup()
        let results = ThreadSafeKeyValueStore<Term, Result<Int, Error>>()

        terms.forEach { term in
            sync.enter()
            provider.getContainer(for: term.node.package) { result in
                defer { sync.leave() }
                results[term] = result.flatMap { container in Result(catching: { try container.versionCount(term.requirement) }) }
            }
        }

        sync.notify(queue: .sharedConcurrent) {
            do {
                completion(.success(try results.mapValues { try $0.get() }))
            } catch {
                completion(.failure(error))
            }
        }
    }

    internal func makeDecision(state: State, completion: @escaping (Result<DependencyResolutionNode?, Error>) -> Void) {
        // If there are no more undecided terms, version solving is complete.
        let undecided = state.solution.undecided
        guard !undecided.isEmpty else {
            return completion(.success(nil))
        }

        // Prefer packages with least number of versions that fit the current requirements so we
        // get conflicts (if any) sooner.
        self.computeCounts(for: undecided) { result in
            do {
                let start = DispatchTime.now()
                let counts = try result.get()
                // forced unwraps safe since we are testing for count and errors above
                let pkgTerm = undecided.min { counts[$0]! < counts[$1]! }!
                self.delegate?.willResolve(term: pkgTerm)
                // at this point the container is cached 
                let container = try self.provider.getCachedContainer(for: pkgTerm.node.package)

                // Get the best available version for this package.
                guard let version = try container.getBestAvailableVersion(for: pkgTerm) else {
                    state.addIncompatibility(try Incompatibility(pkgTerm, root: state.root, cause: .noAvailableVersion), at: .decisionMaking)
                    return completion(.success(pkgTerm.node))
                }

                // Add all of this version's dependencies as incompatibilities.
                let depIncompatibilities = try container.incompatibilites(
                    at: version,
                    node: pkgTerm.node,
                    overriddenPackages: state.overriddenPackages,
                    root: state.root
                )

                var haveConflict = false
                for incompatibility in depIncompatibilities {
                    // Add the incompatibility to our partial solution.
                    state.addIncompatibility(incompatibility, at: .decisionMaking)

                    // Check if this incompatibility will satisfy the solution.
                    haveConflict = haveConflict || incompatibility.terms.allSatisfy {
                        // We only need to check if the terms other than this package
                        // are satisfied because we _know_ that the terms matching
                        // this package will be satisfied if we make this version
                        // as a decision.
                        $0.node == pkgTerm.node || state.solution.satisfies($0)
                    }
                }

                // Decide this version if there was no conflict with its dependencies.
                if !haveConflict {
                    self.delegate?.didResolve(term: pkgTerm, version: version, duration: start.distance(to: .now()))
                    state.decide(pkgTerm.node, at: version)
                }

                completion(.success(pkgTerm.node))                
            } catch {
                completion(.failure(error))
            }
        }
    }
}

private struct DiagnosticReportBuilder {
    let rootNode: DependencyResolutionNode
    let incompatibilities: [DependencyResolutionNode: [Incompatibility]]

    private var lines: [(number: Int, message: String)] = []
    private var derivations: [Incompatibility: Int] = [:]
    private var lineNumbers: [Incompatibility: Int] = [:]
    private let provider: ContainerProvider

    init(root: DependencyResolutionNode, incompatibilities: [DependencyResolutionNode: [Incompatibility]], provider: ContainerProvider) {
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
            self.record(
                rootCause,
                message: try description(for: rootCause),
                isNumbered: false
            )
        }

        let stream = BufferedOutputByteStream()
        let padding = lineNumbers.isEmpty ? 0 : "\(lineNumbers.values.map { $0 }.last!) ".count

        for (idx, line) in lines.enumerated() {
            stream <<< Format.asRepeating(string: " ", count: padding)
            if line.number != -1 {
                stream <<< Format.asRepeating(string: " ", count: padding)
                stream <<< " (\(line.number)) "
            }
            stream <<< line.message.prefix(1).capitalized
            stream <<< line.message.dropFirst()

            if lines.count - 1 != idx {
                stream <<< "\n"
            }
        }

        return stream.bytes.description
    }

    private mutating func visit(
        _ incompatibility: Incompatibility,
        isConclusion: Bool = false
    ) throws {
        let isNumbered = isConclusion || derivations[incompatibility]! > 1
        let conjunction = isConclusion || incompatibility.cause == .root ? "As a result, " : ""
        let incompatibilityDesc = try description(for: incompatibility)

        guard case .conflict(let cause) = incompatibility.cause else {
            assertionFailure("\(incompatibility)")
            return
        }

        if cause.conflict.cause.isConflict && cause.other.cause.isConflict {
            let conflictLine = lineNumbers[cause.conflict]
            let otherLine = lineNumbers[cause.other]

            if let conflictLine = conflictLine, let otherLine = otherLine {
                self.record(
                    incompatibility,
                    message: "\(incompatibilityDesc) because \(try description(for: cause.conflict)) (\(conflictLine)) and \(try description(for: cause.other)) (\(otherLine).",
                    isNumbered: isNumbered
                )
            } else if conflictLine != nil || otherLine != nil {
                let withLine: Incompatibility
                let withoutLine: Incompatibility
                let line: Int
                if let conflictLine = conflictLine {
                    withLine = cause.conflict
                    withoutLine = cause.other
                    line = conflictLine
                } else {
                    withLine = cause.other
                    withoutLine = cause.conflict
                    line = otherLine!
                }

                try self.visit(withoutLine)
                self.record(
                    incompatibility,
                    message: "\(conjunction)\(incompatibilityDesc) because \(try description(for: withLine)) \(line).",
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
                    self.record(
                        incompatibility,
                        message: "\(conjunction)\(incompatibilityDesc) because \(try description(for: cause.conflict)) (\(lineNumbers[cause.conflict]!)).",
                        isNumbered: isNumbered
                    )
                }
            }
        } else if cause.conflict.cause.isConflict || cause.other.cause.isConflict {
            let derived = cause.conflict.cause.isConflict ? cause.conflict : cause.other
            let ext = cause.conflict.cause.isConflict ? cause.other : cause.conflict
            let derivedLine = lineNumbers[derived]
            if let derivedLine = derivedLine {
                self.record(
                    incompatibility,
                    message: "\(incompatibilityDesc) because \(try description(for: ext)) and \(try description(for: derived)) (\(derivedLine)).",
                    isNumbered: isNumbered
                )
            } else if isCollapsible(derived) {
                guard case .conflict(let derivedCause) = derived.cause else {
                    assertionFailure("unreachable")
                    return
                }

                let collapsedDerived = derivedCause.conflict.cause.isConflict ? derivedCause.conflict : derivedCause.other
                let collapsedExt = derivedCause.conflict.cause.isConflict ? derivedCause.other : derivedCause.conflict

                try self.visit(collapsedDerived)
                self.record(
                    incompatibility,
                    message: "\(conjunction)\(incompatibilityDesc) because \(try description(for: collapsedExt)) and \(try description(for: ext)).",
                    isNumbered: isNumbered
                )
            } else {
                try self.visit(derived)
                self.record(
                    incompatibility,
                    message: "\(conjunction)\(incompatibilityDesc) because \(try description(for: ext)).",
                    isNumbered: isNumbered
                )
            }
        } else {
            self.record(
                incompatibility,
                message: "\(incompatibilityDesc) because \(try description(for: cause.conflict)) and \(try description(for: cause.other)).",
                isNumbered: isNumbered
            )
        }
    }

    private func description(for incompatibility: Incompatibility) throws -> String {
        switch incompatibility.cause {
        case .dependency(node: _):
            assert(incompatibility.terms.count == 2)
            let depender = incompatibility.terms.first!
            let dependee = incompatibility.terms.last!
            assert(depender.isPositive)
            assert(!dependee.isPositive)

            let dependerDesc = try description(for: depender, normalizeRange: true)
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
        case .conflict:
            break
        case .versionBasedDependencyContainsUnversionedDependency(let versionedDependency, let unversionedDependency):
            return "package '\(versionedDependency.identity)' is required using a stable-version but '\(versionedDependency.identity)' depends on an unstable-version package '\(unversionedDependency.identity)'"
        case .incompatibleToolsVersion(let version):
            let term = incompatibility.terms.first!
            return "\(try description(for: term, normalizeRange: true)) contains incompatible tools version (\(version))"
        }

        if isFailure(incompatibility) {
            return "dependencies could not be resolved"
        }

        let terms = incompatibility.terms
        if terms.count == 1 {
            let term = terms.first!
            let prefix = try hasEffectivelyAnyRequirement(term) ? term.node.nameForDiagnostics : description(for: term, normalizeRange: true)
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

        let positive = try terms.filter { $0.isPositive }.map { try description(for: $0) }
        let negative = try terms.filter { !$0.isPositive }.map { try description(for: $0) }
        if !positive.isEmpty, !negative.isEmpty {
            if positive.count == 1 {
                let positiveTerm = terms.first { $0.isPositive }!
                return "\(try description(for: positiveTerm, normalizeRange: true)) practically depends on \(negative.joined(separator: " or "))"
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
        if derivations[incompatibility]! > 1 {
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
        return !lineNumbers.keys.contains(complex)
    }

    // FIXME: This is duplicated and wrong.
    private func isFailure(_ incompatibility: Incompatibility) -> Bool {
        return incompatibility.terms.count == 1 && incompatibility.terms.first?.node.package.identity == .plain("<synthesized-root>")
    }

    private func description(for term: Term, normalizeRange: Bool = false) throws -> String {
        let name = term.node.nameForDiagnostics

        switch term.requirement {
        case .any: return name
        case .empty: return "no version of \(name)"
        case .exact(let version):
            // For the root package, don't output the useless version 1.0.0.
            if term.node == rootNode {
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
            number = lineNumbers.count + 1
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

// MARK: - Container Management

/// A container for an individual package. This enhances PackageContainer to add PubGrub specific
/// logic which is mostly related to computing incompatibilities at a particular version.
private final class PubGrubPackageContainer {
    /// The underlying package container.
    let underlying: PackageContainer

    /// Reference to the pins map.
    private let pinsMap: PinsStore.PinsMap

    /// The map of dependencies to version set that indicates the versions that have had their
    /// incompatibilities emitted.
    private var emittedIncompatibilities = ThreadSafeKeyValueStore<PackageReference, VersionSetSpecifier>()

    /// Whether we've emitted the incompatibilities for the pinned versions.
    private var emittedPinnedVersionIncompatibilities = ThreadSafeBox(false)

    init(underlying: PackageContainer, pinsMap: PinsStore.PinsMap) {
        self.underlying = underlying
        self.pinsMap = pinsMap
    }

    var package: PackageReference {
        self.underlying.package
    }

    /// Returns the pinned version for this package, if any.
    var pinnedVersion: Version? {
        return self.pinsMap[self.underlying.package.identity]?.state.version
    }

    /// Returns the numbers of versions that are satisfied by the given version requirement.
    func versionCount(_ requirement: VersionSetSpecifier) throws -> Int {
        if let pinnedVersion = self.pinnedVersion, requirement.contains(pinnedVersion) {
            return 1
        }
        return try self.underlying.versionsDescending().filter(requirement.contains).count
    }

    /// Computes the bounds of the given range against the versions available in the package.
    ///
    /// `includesLowerBound` is `false` if range's lower bound is less than or equal to the lowest available version.
    /// Similarly, `includesUpperBound` is `false` if range's upper bound is greater than or equal to the highest available version.
    func computeBounds(for range: Range<Version>) throws -> (includesLowerBound: Bool, includesUpperBound: Bool) {
        var includeLowerBound = true
        var includeUpperBound = true

        let versions = try self.underlying.versionsDescending()

        if let last = versions.last, range.lowerBound < last {
            includeLowerBound = false
        }

        if let first = versions.first, range.upperBound > first {
            includeUpperBound = false
        }

        return (includeLowerBound, includeUpperBound)
    }

    /// Returns the best available version for a given term.
    func getBestAvailableVersion(for term: Term) throws -> Version? {
        assert(term.isPositive, "Expected term to be positive")
        var versionSet = term.requirement

        // Restrict the selection to the pinned version if is allowed by the current requirements.
        if let pinnedVersion = self.pinnedVersion {
            if versionSet.contains(pinnedVersion) {
                versionSet = .exact(pinnedVersion)
            }
        }

        // Return the highest version that is allowed by the input requirement.
        return try self.underlying.versionsDescending().first { versionSet.contains($0) }
    }

    /// Compute the bounds of incompatible tools version starting from the given version.
    private func computeIncompatibleToolsVersionBounds(fromVersion: Version) throws -> VersionSetSpecifier {
        assert(!self.underlying.isToolsVersionCompatible(at: fromVersion))
        let versions: [Version] = try self.underlying.versionsAscending()

        // This is guaranteed to be present.
        let idx = versions.firstIndex(of: fromVersion)!

        var lowerBound = fromVersion
        var upperBound = fromVersion

        for version in versions.dropFirst(idx + 1) {
            let isToolsVersionCompatible = self.underlying.isToolsVersionCompatible(at: version)
            if isToolsVersionCompatible {
                break
            }
            upperBound = version
        }

        for version in versions.dropLast(versions.count - idx).reversed() {
            let isToolsVersionCompatible = self.underlying.isToolsVersionCompatible(at: version)
            if isToolsVersionCompatible {
                break
            }
            lowerBound = version
        }

        // If lower and upper bounds didn't change then this is the sole incompatible version.
        if lowerBound == upperBound {
            return .exact(lowerBound)
        }

        // If lower bound is the first version then we can use 0 as the sentinel. This
        // will end up producing a better diagnostic since we can omit the lower bound.
        if lowerBound == versions.first {
            lowerBound = "0.0.0"
        }

        if upperBound == versions.last {
            // If upper bound is the last version then we can use the next major version as the sentinel.
            // This will end up producing a better diagnostic since we can omit the upper bound.
            upperBound = Version(upperBound.major + 1, 0, 0)
        } else {
            // Use the next patch since the upper bound needs to be inclusive here.
            upperBound = upperBound.nextPatch()
        }
        return .range(lowerBound ..< upperBound.nextPatch())
    }

    /// Returns the incompatibilities of a package at the given version.
    func incompatibilites(
        at version: Version,
        node: DependencyResolutionNode,
        overriddenPackages: [PackageReference: (version: BoundVersion, products: ProductFilter)],
        root: DependencyResolutionNode
    ) throws -> [Incompatibility] {
        // FIXME: It would be nice to compute bounds for this as well.
        if !self.underlying.isToolsVersionCompatible(at: version) {
            let requirement = try self.computeIncompatibleToolsVersionBounds(fromVersion: version)
            let toolsVersion = try self.underlying.toolsVersion(for: version)
            return [try Incompatibility(Term(node, requirement), root: root, cause: .incompatibleToolsVersion(toolsVersion))]
        }

        var unprocessedDependencies = try self.underlying.getDependencies(at: version, productFilter: node.productFilter)
        if let sharedVersion = node.versionLock(version: version) {
            unprocessedDependencies.append(sharedVersion)
        }
        var constraints: [PackageContainerConstraint] = []
        for dep in unprocessedDependencies {
            // Version-based packages are not allowed to contain unversioned dependencies.
            guard case .versionSet = dep.requirement else {
                let cause: Incompatibility.Cause = .versionBasedDependencyContainsUnversionedDependency(
                    versionedDependency: package,
                    unversionedDependency: dep.package
                )
                return [try Incompatibility(Term(node, .exact(version)), root: root, cause: cause)]
            }

            // Skip if this package is overriden.
            if overriddenPackages.keys.contains(dep.package) {
                continue
            }

            // Skip if we already emitted incompatibilities for this dependency such that the selected
            // falls within the previously computed bounds.
            if emittedIncompatibilities[dep.package]?.contains(version) != true {
                constraints.append(dep)
            }
        }

        // Emit the dependencies at the pinned version if we haven't emitted anything else yet.
        if version == pinnedVersion, emittedIncompatibilities.isEmpty {
            // We don't need to emit anything if we already emitted the incompatibilities at the
            // pinned version.
            if self.emittedPinnedVersionIncompatibilities.get() ?? false {
                return []
            }

            self.emittedPinnedVersionIncompatibilities.put(true)

            // Since the pinned version is most likely to succeed, we don't compute bounds for its
            // incompatibilities.
            return try Array(constraints.map { (constraint: PackageContainerConstraint) -> [Incompatibility] in
                guard case .versionSet(let vs) = constraint.requirement else {
                    throw InternalError("Unexpected unversioned requirement: \(constraint)")
                }
                return try constraint.nodes().map { dependencyNode in
                    var terms: Basics.OrderedSet<Term> = []
                    terms.append(Term(node, .exact(version)))
                    terms.append(Term(not: dependencyNode, vs))
                    return try Incompatibility(terms, root: root, cause: .dependency(node: node))
                }
            }.joined())
        }

        let (lowerBounds, upperBounds) = try self.computeBounds(for: node,
                                                                constraints: constraints,
                                                                startingWith: version,
                                                                products: node.productFilter)

        return try constraints.map { constraint in
            var terms: Basics.OrderedSet<Term> = []
            let lowerBound = lowerBounds[constraint.package] ?? "0.0.0"
            let upperBound = upperBounds[constraint.package] ?? Version(version.major + 1, 0, 0)
            assert(lowerBound < upperBound)

            // We only have version-based requirements at this point.
            guard case .versionSet(let vs) = constraint.requirement else {
                throw InternalError("Unexpected unversioned requirement: \(constraint)")                
            }

            for constraintNode in constraint.nodes() {
                let requirement: VersionSetSpecifier = .range(lowerBound ..< upperBound)
                terms.append(Term(node, requirement))
                terms.append(Term(not: constraintNode, vs))

                // Make a record for this dependency so we don't have to recompute the bounds when the selected version falls within the bounds.
                self.emittedIncompatibilities[constraint.package] = requirement.union(emittedIncompatibilities[constraint.package] ?? .empty)
            }

            return try Incompatibility(terms, root: root, cause: .dependency(node: node))
        }
    }

    /// Method for computing bounds of the given dependencies.
    ///
    /// This will return a dictionary which contains mapping of a package dependency to its bound.
    /// If a dependency is absent in the dictionary, it is present in all versions of the package
    /// above or below the given version. As with regular version ranges, the lower bound is
    /// inclusive and the upper bound is exclusive.
    private func computeBounds(
        for node: DependencyResolutionNode,
        constraints: [PackageContainerConstraint],
        startingWith firstVersion: Version,
        products: ProductFilter
    ) throws -> (lowerBounds: [PackageReference: Version], upperBounds: [PackageReference: Version]) {
        let preloadCount = 3

        // nothing to do
        if constraints.isEmpty {
            return ([:], [:])
        }
        
        func preload(_ versions: [Version]) {
            let sync = DispatchGroup()
            for version in versions {
                DispatchQueue.sharedConcurrent.async(group: sync) {
                    if self.underlying.isToolsVersionCompatible(at: version) {
                        _ = try? self.underlying.getDependencies(at: version, productFilter: products)
                    }
                }
            }
            sync.wait()
        }
        
        func compute(_ versions: [Version], upperBound: Bool) -> [PackageReference: Version] {
            var result: [PackageReference: Version] = [:]
            var previousVersion = firstVersion

            for (index, version) in versions.enumerated() {
                // optimization to preload few version in parallel.
                // we cant preload all versions ahead of time since it will be more
                // costly given the early termination condition
                if index.isMultiple(of: preloadCount) {
                    preload(Array(versions[index ..< min(index + preloadCount, versions.count)]))
                }
                
                // Record this version as the bound if we're finding upper bounds since
                // upper bound is exclusive and record the previous version if we're
                // finding the lower bound since that is inclusive.
                let bound = upperBound ? version : previousVersion
                
                let isToolsVersionCompatible = self.underlying.isToolsVersionCompatible(at: version)
                for constraint in constraints where !result.keys.contains(constraint.package) {
                    // If we hit a version which doesn't have a compatible tools version then that's the boundary.
                    // Record the bound if the tools version isn't compatible at the current version.
                    if !isToolsVersionCompatible {
                        result[constraint.package] = bound
                    } else {
                        // Get the dependencies at this version.
                        if let currentDependencies = try? self.underlying.getDependencies(at: version, productFilter: products) {
                            // Record this version as the bound for our list of dependencies, if appropriate.
                            if currentDependencies.first(where: { $0.package == constraint.package }) != constraint {
                                result[constraint.package] = bound
                            }
                        }
                    }
                }

                // We're done if we found bounds for all of our dependencies.
                if result.count == constraints.count {
                    break
                }

                previousVersion = version
            }
            
            return result
        }

        let versions: [Version] = try self.underlying.versionsAscending()

        guard let idx = versions.firstIndex(of: firstVersion) else {
            throw InternalError("from version \(firstVersion) not found in \(node.package.name)")
        }

        let sync = DispatchGroup()

        var upperBounds = [PackageReference: Version]()
        DispatchQueue.sharedConcurrent.async(group: sync) {
            upperBounds = compute(Array(versions.dropFirst(idx + 1)), upperBound: true)
        }

        var lowerBounds = [PackageReference: Version]()
        DispatchQueue.sharedConcurrent.async(group: sync) {
            lowerBounds = compute(Array(versions.dropLast(versions.count - idx).reversed()), upperBound: false)
        }

        // timeout is a function of # of versions since we need to make several git operations per tag/version
        let timeout = DispatchTimeInterval.seconds(60 + versions.count)
        guard case .success = sync.wait(timeout: .now() + timeout) else {
            throw StringError("timeout computing '\(node.package.name)' bounds")
        }

        return (lowerBounds, upperBounds)
    }
}

/// An utility class around PackageContainerProvider that allows "prefetching" the containers
/// in parallel. The basic idea is to kick off container fetching before starting the resolution
/// by using the list of URLs from the Package.resolved file.
private final class ContainerProvider {
    /// The actual package container provider.
    private let underlying: PackageContainerProvider

    /// Wheather to perform update (git fetch) on existing cloned repositories or not.
    private let skipUpdate: Bool

    /// Reference to the pins store.
    private let pinsMap: PinsStore.PinsMap

    //// Store cached containers
    private var containersCache = ThreadSafeKeyValueStore<PackageReference, PubGrubPackageContainer>()

    //// Store prefetches synchronization
    private var prefetches = ThreadSafeKeyValueStore<PackageReference, DispatchGroup>()

    init(provider underlying: PackageContainerProvider, skipUpdate: Bool, pinsMap: PinsStore.PinsMap) {
        self.underlying = underlying
        self.skipUpdate = skipUpdate
        self.pinsMap = pinsMap
    }

    /// Get a cached container for the given identifier, asserting / throwing if not found.
    func getCachedContainer(for package: PackageReference) throws -> PubGrubPackageContainer {
        guard let container = self.containersCache[package] else {
            throw InternalError("container for \(package.name) expected to be cached")
        }
        return container
    }

    /// Get the container for the given identifier, loading it if necessary.
    func getContainer(for package: PackageReference, completion: @escaping (Result<PubGrubPackageContainer, Error>) -> Void) {
        // Return the cached container, if available.
        if let container = self.containersCache[package] {
            return completion(.success(container))
        }

        if let prefetchSync = self.prefetches[package] {
            // If this container is already being prefetched, wait for that to complete
            prefetchSync.notify(queue: .sharedConcurrent) {
                if let container = self.containersCache[package] {
                    // should be in the cache once prefetch completed
                    return completion(.success(container))
                } else {
                    // if prefetch failed, remove from list of prefetches and try again
                    self.prefetches[package] = nil
                    return self.getContainer(for: package, completion: completion)
                }
            }
        } else {
            // Otherwise, fetch the container from the provider
            self.underlying.getContainer(for: package, skipUpdate: skipUpdate, on: .sharedConcurrent) { result in
                let result = result.tryMap { container -> PubGrubPackageContainer in
                    let pubGrubContainer = PubGrubPackageContainer(underlying: container, pinsMap: self.pinsMap)
                    // only cache positive results
                    self.containersCache[package] = pubGrubContainer
                    return pubGrubContainer
                }
                completion(result)
            }
        }
    }

    /// Starts prefetching the given containers.
    func prefetch(containers identifiers: [PackageReference]) {
        // Process each container.
        for identifier in identifiers {
            var needsFetching = false
            self.prefetches.memoize(identifier) {
                let group = DispatchGroup()
                group.enter()
                needsFetching = true
                return group
            }
            if needsFetching {
                self.underlying.getContainer(for: identifier, skipUpdate: skipUpdate, on: .sharedConcurrent) { result in
                    defer { self.prefetches[identifier]?.leave() }
                    // only cache positive results
                    if case .success(let container) = result {
                        self.containersCache[identifier] = PubGrubPackageContainer(underlying: container, pinsMap: self.pinsMap)
                    }
                }
            }
        }
    }
}

internal enum LogLocation: String {
    case topLevel = "top level"
    case unitPropagation = "unit propagation"
    case decisionMaking = "decision making"
    case conflictResolution = "conflict resolution"
}

extension PubgrubDependencyResolver {
    public enum PubgrubError: Swift.Error, CustomStringConvertible {
        case _unresolvable(Incompatibility, [DependencyResolutionNode: [Incompatibility]])
        case unresolvable(String)

        public var description: String {
            switch self {
            case ._unresolvable(let rootCause, _):
                return rootCause.description
            case .unresolvable(let error):
                return error
            }
        }

        var rootCause: Incompatibility? {
            switch self {
            case ._unresolvable(let rootCause, _):
                return rootCause
            case .unresolvable:
                return nil
            }
        }

        var incompatibilities: [DependencyResolutionNode: [Incompatibility]]? {
            switch self {
            case ._unresolvable(_, let incompatibilities):
                return incompatibilities
            case .unresolvable:
                return nil
            }
        }
    }
}

extension PubgrubDependencyResolver {
    private struct VersionBasedConstraint {
        let node: DependencyResolutionNode
        let requirement: VersionSetSpecifier

        init(node: DependencyResolutionNode, req: VersionSetSpecifier) {
            self.node = node
            self.requirement = req
        }

        internal static func constraints(_ constraint: Constraint) -> [VersionBasedConstraint]? {
            switch constraint.requirement {
            case .versionSet(let req):
                return constraint.nodes().map { VersionBasedConstraint(node: $0, req: req) }
            case .revision:
                return nil
            case .unversioned:
                return nil
            }
        }
    }
}

private enum PropagationResult {
    case conflict
    case almostSatisfied(node: DependencyResolutionNode)
    case none
}

private extension PackageRequirement {
    var isRevision: Bool {
        switch self {
        case .versionSet, .unversioned:
            return false
        case .revision:
            return true
        }
    }
}

private extension DependencyResolutionNode {
    var nameForDiagnostics: String {
        return "'\(package.name)'"
    }
}
