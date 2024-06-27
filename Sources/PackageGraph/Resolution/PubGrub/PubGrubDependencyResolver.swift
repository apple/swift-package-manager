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

import Basics
import Dispatch
import class Foundation.NSLock
import OrderedCollections
import PackageModel

import struct TSCUtility.Version

/// The solver that is able to transitively resolve a set of package constraints
/// specified by a root package.
public struct PubGrubDependencyResolver {
    /// The type of the constraints the resolver operates on.
    public typealias Constraint = PackageContainerConstraint

    /// the mutable state that get computed
    final class State {
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

        private let lock = NSLock()

        init(
            root: DependencyResolutionNode,
            overriddenPackages: [PackageReference: (version: BoundVersion, products: ProductFilter)] = [:],
            solution: PartialSolution = PartialSolution()
        ) {
            self.root = root
            self.overriddenPackages = overriddenPackages
            self.solution = solution
        }

        func addIncompatibility(_ incompatibility: Incompatibility, at location: LogLocation) {
            self.lock.withLock {
                // log("incompat: \(incompatibility) \(location)")
                for package in incompatibility.terms.map(\.node) {
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
    private let pins: PinsStore.Pins

    /// The packages that are available in a prebuilt form in SDK or a toolchain
    private let availableLibraries: [ProvidedLibrary]

    /// The container provider used to load package containers.
    private let provider: ContainerProvider

    /// Reference to the package container provider.
    private let packageContainerProvider: PackageContainerProvider

    /// Should resolver prefetch the containers.
    private let prefetchBasedOnResolvedFile: Bool

    /// Update containers while fetching them.
    private let skipDependenciesUpdates: Bool

    /// Resolver delegate
    private let delegate: DependencyResolverDelegate?

    public init(
        provider: PackageContainerProvider,
        pins: PinsStore.Pins = [:],
        availableLibraries: [ProvidedLibrary] = [],
        skipDependenciesUpdates: Bool = false,
        prefetchBasedOnResolvedFile: Bool = false,
        observabilityScope: ObservabilityScope,
        delegate: DependencyResolverDelegate? = nil
    ) {
        self.packageContainerProvider = provider
        self.pins = pins
        self.availableLibraries = availableLibraries
        self.skipDependenciesUpdates = skipDependenciesUpdates
        self.prefetchBasedOnResolvedFile = prefetchBasedOnResolvedFile
        self.provider = ContainerProvider(
            provider: self.packageContainerProvider,
            skipUpdate: self.skipDependenciesUpdates,
            pins: self.pins,
            observabilityScope: observabilityScope
        )
        self.delegate = delegate
    }

    /// Execute the resolution algorithm to find a valid assignment of versions.
    public func solve(constraints: [Constraint]) -> Result<[DependencyResolverBinding], Error> {
        // the graph resolution root
        let root: DependencyResolutionNode
        if constraints.count == 1, let constraint = constraints.first, constraint.package.kind.isRoot {
            // root level package, use it as our resolution root
            root = .root(package: constraint.package)
        } else {
            // more complex setup requires a synthesized root
            root = .root(package: .root(
                identity: .plain("<synthesized-root>"),
                path: .root
            ))
        }

        do {
            let bindings = try self.solve(root: root, constraints: constraints).bindings
            return .success(bindings)
        } catch {
            // If version solving failing, build the user-facing diagnostic.
            if let pubGrubError = error as? PubgrubError, let rootCause = pubGrubError.rootCause,
               let incompatibilities = pubGrubError.incompatibilities
            {
                do {
                    var builder = DiagnosticReportBuilder(
                        root: root,
                        incompatibilities: incompatibilities,
                        provider: self.provider
                    )
                    let diagnostic = try builder.makeErrorReport(for: rootCause)
                    return .failure(PubgrubError.unresolvable(diagnostic))
                } catch {
                    // failed to construct the report, will report the original error
                    return .failure(error)
                }
            }
            return .failure(error)
        }
    }

    /// Find a set of dependencies that fit the given constraints. If dependency
    /// resolution is unable to provide a result, an error is thrown.
    /// - Warning: It is expected that the root package reference has been set  before this is called.
    func solve(root: DependencyResolutionNode, constraints: [Constraint]) throws -> (
        bindings: [DependencyResolverBinding],
        state: State
    ) {
        // first process inputs
        let inputs = try self.processInputs(root: root, with: constraints)

        // Prefetch the containers if prefetching is enabled.
        if self.prefetchBasedOnResolvedFile {
            // We avoid prefetching packages that are overridden since
            // otherwise we'll end up creating a repository container
            // for them.
            let pins = self.pins.values
                .map(\.packageRef)
                .filter { !inputs.overriddenPackages.keys.contains($0) }
            self.provider.prefetch(containers: pins)
        }

        let state = State(root: root, overriddenPackages: inputs.overriddenPackages)

        // Decide root at v1.
        state.decide(state.root, at: "1.0.0")

        // Add the root incompatibility.
        state.addIncompatibility(
            Incompatibility(terms: [Term(not: root, .exact("1.0.0"))], cause: .root),
            at: .topLevel
        )

        // Add inputs root incompatibilities.
        for incompatibility in inputs.rootIncompatibilities {
            state.addIncompatibility(incompatibility, at: .topLevel)
        }

        try self.run(state: state)

        let decisions = state.solution.assignments.filter(\.isDecision)
        var flattenedAssignments: [PackageReference: (binding: BoundVersion, products: ProductFilter)] = [:]
        for assignment in decisions {
            if assignment.term.node == state.root {
                continue
            }

            let package = assignment.term.node.package

            let boundVersion: BoundVersion
            switch assignment.term.requirement {
            case .exact(let version):
                if let library = package.matchingPrebuiltLibrary(in: availableLibraries),
                   version == library.version
                {
                    boundVersion = .version(version, library: library)
                } else {
                    boundVersion = .version(version)
                }
            case .range, .any, .empty, .ranges:
                throw InternalError("unexpected requirement value for assignment \(assignment.term)")
            }

            let products = assignment.term.node.productFilter

            let updatePackage: PackageReference
            if case .version(_, let library) = boundVersion, library != nil {
                updatePackage = package
            } else {
                // TODO: replace with async/await when available
                let container = try temp_await { self.provider.getContainer(for: package, completion: $0) }
                updatePackage = try container.underlying.loadPackageReference(at: boundVersion)
            }

            if var existing = flattenedAssignments[updatePackage] {
                guard existing.binding == boundVersion else {
                    throw InternalError(
                        "Two products in one package resolved to different versions: \(existing.products)@\(existing.binding) vs \(products)@\(boundVersion)"
                    )
                }
                existing.products.formUnion(products)
                flattenedAssignments[updatePackage] = existing
            } else {
                flattenedAssignments[updatePackage] = (binding: boundVersion, products: products)
            }
        }
        var finalAssignments: [DependencyResolverBinding]
            = flattenedAssignments.keys.sorted(by: { $0.deprecatedName < $1.deprecatedName }).map { package in
                let details = flattenedAssignments[package]!
                return .init(package: package, boundVersion: details.binding, products: details.products)
            }

        // Add overridden packages to the result.
        for (package, override) in state.overriddenPackages {
            // TODO: replace with async/await when available
            let container = try temp_await { self.provider.getContainer(for: package, completion: $0) }
            let updatePackage = try container.underlying.loadPackageReference(at: override.version)
            finalAssignments.append(.init(
                package: updatePackage,
                boundVersion: override.version,
                products: override.products
            ))
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
        var constraints = OrderedCollections.OrderedSet(constraints)

        // The list of packages that are overridden in the graph. A local package reference will
        // always override any other kind of package reference and branch-based reference will override
        // version-based reference.
        var overriddenPackages: [PackageReference: (version: BoundVersion, products: ProductFilter)] = [:]

        // The list of version-based references reachable via local and branch-based references.
        // These are added as top-level incompatibilities since they always need to be satisfied.
        // Some of these might be overridden as we discover local and branch-based references.
        var versionBasedDependencies = OrderedCollections.OrderedDictionary<
            DependencyResolutionNode,
            [VersionBasedConstraint]
        >()

        // Process unversioned constraints in first phase. We go through all of the unversioned packages
        // and collect them and their dependencies. This gives us the complete list of unversioned
        // packages in the graph since unversioned packages can only be referred by other
        // unversioned packages.
        while let constraint = constraints.first(where: { $0.requirement == .unversioned }) {
            constraints.remove(constraint)

            // Mark the package as overridden.
            if var existing = overriddenPackages[constraint.package] {
                guard existing.version == .unversioned else {
                    throw InternalError(
                        "Overridden package is not unversioned: \(constraint.package)@\(existing.version)"
                    )
                }
                existing.products.formUnion(constraint.products)
                overriddenPackages[constraint.package] = existing
            } else {
                overriddenPackages[constraint.package] = (version: .unversioned, products: constraint.products)
            }

            for node in constraint.nodes() {
                // Process dependencies of this package.
                //
                // We collect all version-based dependencies in a separate structure so they can
                // be processed at the end. This allows us to override them when there is a non-version
                // based (unversioned/branch-based) constraint present in the graph.
                // TODO: replace with async/await when available
                let container = try temp_await { self.provider.getContainer(for: node.package, completion: $0) }
                for dependency in try container.underlying
                    .getUnversionedDependencies(productFilter: node.productFilter)
                {
                    if let versionedBasedConstraints = VersionBasedConstraint.constraints(dependency) {
                        for constraint in versionedBasedConstraints {
                            versionBasedDependencies[node, default: []].append(constraint)
                        }
                    } else if !overriddenPackages.keys.contains(dependency.package) {
                        // Add the constraint if its not already present. This will ensure we don't
                        // end up looping infinitely due to a cycle (which are diagnosed separately).
                        constraints.append(dependency)
                    }
                }
            }
        }

        // Process revision-based constraints in the second phase. Here we do the similar processing
        // as the first phase but we also ignore the constraints that are overridden due to
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
                throw InternalError("Unexpected value for overridden package \(package) in \(overriddenPackages)")
            case .unversioned?:
                // This package is overridden by an unversioned package so we can ignore this constraint.
                continue
            case .revision(let existingRevision, let branch)?:
                // If this branch-based package was encountered before, ensure the references match.
                if (branch ?? existingRevision) != revision {
                    throw PubgrubError
                        .unresolvable(
                            "\(package.identity) is required using two different revision-based requirements (\(existingRevision) and \(revision)), which is not supported"
                        )
                } else {
                    // Otherwise, continue since we've already processed this constraint. Any cycles will be diagnosed
                    // separately.
                    continue
                }
            case nil:
                break
            }

            // Process dependencies of this package, similar to the first phase but branch-based dependencies
            // are not allowed to contain local/unversioned packages.
            // TODO: replace with async/await when avail
            let container = try temp_await { self.provider.getContainer(for: package, completion: $0) }

            // If there is a pin for this revision-based dependency, get
            // the dependencies at the pinned revision instead of using
            // latest commit on that branch. Note that if this revision-based dependency is
            // already a commit, then its pin entry doesn't matter in practice.
            let revisionForDependencies: String
            if case .branch(revision, let pinRevision) = self.pins[package.identity]?.state {
                revisionForDependencies = pinRevision

                // Mark the package as overridden with the pinned revision and record the branch as well.
                overriddenPackages[package] = (
                    version: .revision(revisionForDependencies, branch: revision),
                    products: constraint.products
                )
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
                            versionBasedDependencies[.root(package: constraint.package), default: []]
                                .append(versionedBasedConstraint)
                        }
                    case .revision:
                        constraints.append(dependency)
                    case .unversioned:
                        throw DependencyResolverError.revisionDependencyContainsLocalPackage(
                            dependency: package.identity.description,
                            localPackage: dependency.package.identity.description
                        )
                    }
                }
            }
        }

        // At this point, we should be left with only version-based requirements in our constraints
        // list. Add them to our version-based dependency list.
        for constraint in constraints {
            switch constraint.requirement {
            case .versionSet(let req):
                for node in constraint.nodes() {
                    let versionedBasedConstraint = VersionBasedConstraint(node: node, req: req)
                    versionBasedDependencies[root, default: []].append(versionedBasedConstraint)
                }
            case .revision, .unversioned:
                throw InternalError(
                    "Unexpected revision/unversioned requirement in the constraints list: \(constraints)"
                )
            }
        }

        // Finally, compute the root incompatibilities (which will be all version-based).
        // note versionBasedDependencies may point to the root package dependencies, or the dependencies of root's
        // non-versioned dependencies
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
            self.provider.prefetch(
                containers: state.solution.undecided.map(\.node.package).filter {
                    $0.matchingPrebuiltLibrary(in: self.availableLibraries) == nil
                }
            )

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
    func propagate(state: State, node: DependencyResolutionNode) throws {
        var changed: OrderedCollections.OrderedSet<DependencyResolutionNode> = [node]

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

        state.derive(unsatisfiedTerm.inverse, cause: incompatibility)
        self.delegate?.derived(term: unsatisfiedTerm.inverse)
        return .almostSatisfied(node: unsatisfiedTerm.node)
    }

    // Based on:
    // https://github.com/dart-lang/pub/tree/master/doc/solver.md#conflict-resolution
    // https://github.com/dart-lang/pub/blob/master/lib/src/solver/version_solver.dart#L201
    func resolve(state: State, conflict: Incompatibility) throws -> Incompatibility {
        self.delegate?.conflict(conflict: conflict)

        var incompatibility = conflict
        var createdIncompatibility = false

        // rdar://93335995
        // hard protection from infinite loops
        let maxIterations = 1000
        var iterations = 0

        while !self.isCompleteFailure(incompatibility, root: state.root) {
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
                    if let difference {
                        previousSatisfierLevel = try max(
                            previousSatisfierLevel,
                            state.solution.satisfier(for: difference.inverse).decisionLevel
                        )
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

            var newTerms = Array(incompatibility.terms.filter { $0 != mostRecentTerm })
            newTerms += priorCause.terms.filter { $0.node != _mostRecentSatisfier.term.node }

            if let _difference = difference {
                // rdar://93335995
                // do not add the exact inverse of a requirement as it can lead to endless loops
                if _difference.inverse != mostRecentTerm {
                    newTerms.append(_difference.inverse)
                }
            }

            incompatibility = try Incompatibility(
                OrderedCollections.OrderedSet(newTerms),
                root: state.root,
                cause: .conflict(cause: .init(conflict: incompatibility, other: priorCause))
            )
            createdIncompatibility = true

            if let mostRecentTerm {
                if let difference {
                    self.delegate?.partiallySatisfied(
                        term: mostRecentTerm,
                        by: _mostRecentSatisfier,
                        incompatibility: incompatibility,
                        difference: difference
                    )
                } else {
                    self.delegate?.satisfied(
                        term: mostRecentTerm,
                        by: _mostRecentSatisfier,
                        incompatibility: incompatibility
                    )
                }
            }

            // rdar://93335995
            // hard protection from infinite loops
            iterations = iterations + 1
            if iterations >= maxIterations {
                break
            }
        }

        self.delegate?.failedToResolve(incompatibility: incompatibility)
        throw PubgrubError._unresolvable(incompatibility, state.incompatibilities)
    }

    /// Does a given incompatibility specify that version solving has entirely
    /// failed, meaning this incompatibility is either empty or only for the root
    /// package.
    private func isCompleteFailure(_ incompatibility: Incompatibility, root: DependencyResolutionNode) -> Bool {
        incompatibility.terms.isEmpty || (incompatibility.terms.count == 1 && incompatibility.terms.first?.node == root)
    }

    private func computeCounts(
        for terms: [Term],
        completion: @escaping (Result<[Term: Int], Error>) -> Void
    ) {
        if terms.isEmpty {
            return completion(.success([:]))
        }

        let sync = DispatchGroup()
        let results = ThreadSafeKeyValueStore<Term, Result<Int, Error>>()

        for term in terms {
            sync.enter()
            self.provider.getContainer(for: term.node.package) { result in
                defer { sync.leave() }
                results[term] = result
                    .flatMap { container in Result(catching: { try container.versionCount(term.requirement) }) }
            }
        }

        sync.notify(queue: .sharedConcurrent) {
            do {
                try completion(.success(results.mapValues { try $0.get() }))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func makeDecision(
        state: State,
        completion: @escaping (Result<DependencyResolutionNode?, Error>) -> Void
    ) {
        // If there are no more undecided terms, version solving is complete.
        let undecided = state.solution.undecided
        guard !undecided.isEmpty else {
            return completion(.success(nil))
        }

        // If prebuilt libraries are available, let's attempt their versions first before going for
        // the latest viable version in the package. This way we archive multiple goals - prioritize
        // prebuilt libraries if they satisfy all requirements, avoid counting and building package
        // manifests and avoid (re-)building packages.
        //
        // Since the conflict resolution learns from incorrect terms this wouldn't be re-attempted.
        if !self.availableLibraries.isEmpty {
            let start = DispatchTime.now()
            for pkgTerm in undecided {
                let package = pkgTerm.node.package
                guard let library = package.matchingPrebuiltLibrary(in: self.availableLibraries) else {
                    continue
                }

                if pkgTerm.requirement.contains(library.version) {
                    self.delegate?.didResolve(
                        term: pkgTerm,
                        version: library.version,
                        duration: start.distance(to: .now())
                    )
                    state.decide(pkgTerm.node, at: library.version)
                    return completion(.success(pkgTerm.node))
                }
            }
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
                    try state.addIncompatibility(
                        Incompatibility(pkgTerm, root: state.root, cause: .noAvailableVersion),
                        at: .decisionMaking
                    )
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

enum LogLocation: String {
    case topLevel = "top level"
    case unitPropagation = "unit propagation"
    case decisionMaking = "decision making"
    case conflictResolution = "conflict resolution"
}

extension PubGrubDependencyResolver {
    public enum PubgrubError: Swift.Error, CustomStringConvertible {
        case _unresolvable(Incompatibility, [DependencyResolutionNode: [Incompatibility]])
        case unresolvable(String)

        public var description: String {
            switch self {
            case ._unresolvable(let rootCause, _):
                rootCause.description
            case .unresolvable(let error):
                error
            }
        }

        var rootCause: Incompatibility? {
            switch self {
            case ._unresolvable(let rootCause, _):
                rootCause
            case .unresolvable:
                nil
            }
        }

        var incompatibilities: [DependencyResolutionNode: [Incompatibility]]? {
            switch self {
            case ._unresolvable(_, let incompatibilities):
                incompatibilities
            case .unresolvable:
                nil
            }
        }
    }
}

extension PubGrubDependencyResolver {
    private struct VersionBasedConstraint {
        let node: DependencyResolutionNode
        let requirement: VersionSetSpecifier

        init(node: DependencyResolutionNode, req: VersionSetSpecifier) {
            self.node = node
            self.requirement = req
        }

        static func constraints(_ constraint: Constraint) -> [VersionBasedConstraint]? {
            switch constraint.requirement {
            case .versionSet(let req):
                constraint.nodes().map { VersionBasedConstraint(node: $0, req: req) }
            case .revision:
                nil
            case .unversioned:
                nil
            }
        }
    }
}

private enum PropagationResult {
    case conflict
    case almostSatisfied(node: DependencyResolutionNode)
    case none
}

extension PackageRequirement {
    fileprivate var isRevision: Bool {
        switch self {
        case .versionSet, .unversioned:
            false
        case .revision:
            true
        }
    }
}

extension PackageReference {
    public func matchingPrebuiltLibrary(in availableLibraries: [ProvidedLibrary]) -> ProvidedLibrary? {
        switch self.kind {
        case .fileSystem, .localSourceControl, .root:
            nil // can never match a prebuilt library
        case .registry(let identity):
            if let registryIdentity = identity.registry {
                availableLibraries.first(
                    where: { $0.metadata.identities.contains(
                        where: { $0 == .packageIdentity(
                            scope: registryIdentity.scope.description,
                            name: registryIdentity.name.description
                        )
                        }
                    )
                    }
                )
            } else {
                nil
            }
        case .remoteSourceControl(let url):
            availableLibraries.first(where: {
                $0.metadata.identities.contains(where: { $0 == .sourceControl(url: url) })
            })
        }
    }
}
