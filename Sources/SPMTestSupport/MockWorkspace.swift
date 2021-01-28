/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import XCTest

import PackageLoading
import PackageModel
import SourceControl
import TSCBasic
import Workspace
import Basics

public final class MockWorkspace {
    let sandbox: AbsolutePath
    let fs: FileSystem
    public let downloader: MockDownloader
    public let archiver: MockArchiver
    public let checksumAlgorithm: MockHashAlgorithm
    let roots: [MockPackage]
    let packages: [MockPackage]
    public let config: Workspace.Configuration
    public var manifestLoader: MockManifestLoader
    public var repoProvider: InMemoryGitRepositoryProvider
    public let delegate = MockWorkspaceDelegate()
    let toolsVersion: ToolsVersion
    let skipUpdate: Bool
    let enablePubGrub: Bool

    public init(
        sandbox: AbsolutePath,
        fs: FileSystem,
        downloader: MockDownloader? = nil,
        archiver: MockArchiver = MockArchiver(),
        checksumAlgorithm: MockHashAlgorithm = MockHashAlgorithm(),
        roots: [MockPackage],
        packages: [MockPackage],
        toolsVersion: ToolsVersion = ToolsVersion.currentToolsVersion,
        skipUpdate: Bool = false,
        enablePubGrub: Bool = true
    ) throws {
        self.sandbox = sandbox
        self.fs = fs
        self.downloader = downloader ?? MockDownloader(fileSystem: fs)
        self.archiver = archiver
        self.checksumAlgorithm = checksumAlgorithm
        self.config = try Workspace.Configuration(path: sandbox.appending(component: "swiftpm"), fs: fs)
        self.roots = roots
        self.packages = packages

        self.manifestLoader = MockManifestLoader(manifests: [:])
        self.repoProvider = InMemoryGitRepositoryProvider()
        self.toolsVersion = toolsVersion
        self.skipUpdate = skipUpdate
        self.enablePubGrub = enablePubGrub

        try self.create()
    }

    private var rootsDir: AbsolutePath {
        return self.sandbox.appending(component: "roots")
    }

    public var packagesDir: AbsolutePath {
        return self.sandbox.appending(component: "pkgs")
    }

    public var artifactsDir: AbsolutePath {
        return self.sandbox.appending(components: ".build", "artifacts")
    }

    public func urlForPackage(withName name: String) -> String {
        return self.packagesDir.appending(RelativePath(name)).pathString
    }

    private func url(for package: MockPackage) -> String {
        return self.packagesDir.appending(RelativePath(package.path ?? package.name)).pathString
    }

    private func create() throws {
        // Remove the sandbox if present.
        try self.fs.removeFileTree(self.sandbox)

        // Create directories.
        try self.fs.createDirectory(self.sandbox, recursive: true)
        try self.fs.createDirectory(self.rootsDir)
        try self.fs.createDirectory(self.packagesDir)

        var manifests: [MockManifestLoader.Key: Manifest] = [:]

        func create(package: MockPackage, basePath: AbsolutePath, packageKind: PackageReference.Kind) throws {
            let packagePath = basePath.appending(RelativePath(package.path ?? package.name))

            let url = (packageKind == .root ? packagePath : self.packagesDir.appending(RelativePath(package.path ?? package.name))).pathString
            let specifier = RepositorySpecifier(url: url)

            // Create targets on disk.
            let repo = self.repoProvider.specifierMap[specifier] ?? InMemoryGitRepository(path: packagePath, fs: self.fs as! InMemoryFileSystem)
            let repoSourcesDir = AbsolutePath("/Sources")
            for target in package.targets {
                let repoTargetDir = repoSourcesDir.appending(component: target.name)
                try repo.createDirectory(repoTargetDir, recursive: true)
                try repo.writeFileContents(repoTargetDir.appending(component: "file.swift"), bytes: "")
            }
            let toolsVersion = package.toolsVersion ?? .currentToolsVersion
            let repoManifestPath = AbsolutePath.root.appending(component: Manifest.filename)
            try repo.writeFileContents(repoManifestPath, bytes: "")
            try writeToolsVersion(at: .root, version: toolsVersion, fs: repo)
            try repo.commit()

            let versions: [String?] = packageKind == .remote ? package.versions : [nil]
            let manifestPath = packagePath.appending(component: Manifest.filename)
            for version in versions {
                let v = version.flatMap(Version.init(string:))
                manifests[.init(url: url, version: v)] = Manifest(
                    name: package.name,
                    platforms: package.platforms,
                    path: manifestPath,
                    url: url,
                    version: v,
                    toolsVersion: toolsVersion,
                    packageKind: packageKind,
                    dependencies: package.dependencies.map { $0.convert(baseURL: packagesDir) },
                    products: package.products.map { ProductDescription(name: $0.name, type: .library(.automatic), targets: $0.targets) },
                    targets: try package.targets.map { try $0.convert() }
                )
                if let version = version {
                    try repo.tag(name: version)
                }
            }

            self.repoProvider.add(specifier: specifier, repository: repo)
        }

        // Create root packages.
        for package in self.roots {
            try create(package: package, basePath: self.rootsDir, packageKind: .root)
        }

        // Create dependency packages.
        for package in self.packages {
            try create(package: package, basePath: self.packagesDir, packageKind: .remote)
        }

        self.manifestLoader = MockManifestLoader(manifests: manifests)
    }

    public func createWorkspace() -> Workspace {
        if let workspace = _workspace {
            return workspace
        }

        self._workspace = Workspace(
            dataPath: self.sandbox.appending(component: ".build"),
            editablesPath: self.sandbox.appending(component: "edits"),
            pinsFile: self.sandbox.appending(component: "Package.resolved"),
            manifestLoader: self.manifestLoader,
            currentToolsVersion: self.toolsVersion,
            toolsVersionLoader: ToolsVersionLoader(),
            delegate: self.delegate,
            config: self.config,
            fileSystem: self.fs,
            repositoryProvider: self.repoProvider,
            downloader: self.downloader,
            archiver: self.archiver,
            checksumAlgorithm: self.checksumAlgorithm,
            isResolverPrefetchingEnabled: true,
            enablePubgrubResolver: self.enablePubGrub,
            skipUpdate: self.skipUpdate,
            cachePath: localFileSystem.swiftPMCacheDirectory.appending(component: "repositories"),
            verbosity: TSCUtility.verbosity
        )
        return self._workspace!
    }

    private var _workspace: Workspace?

    public func closeWorkspace() {
        self._workspace = nil
    }

    public func rootPaths(for packages: [String]) -> [AbsolutePath] {
        return packages.map { rootsDir.appending(RelativePath($0)) }
    }

    public func checkEdit(
        packageName: String,
        path: AbsolutePath? = nil,
        revision: Revision? = nil,
        checkoutBranch: String? = nil,
        _ result: (DiagnosticsEngine) -> Void
    ) {
        let ws = self.createWorkspace()
        let diagnostics = DiagnosticsEngine()
        ws.edit(
            packageName: packageName,
            path: path,
            revision: revision,
            checkoutBranch: checkoutBranch,
            diagnostics: diagnostics
        )
        result(diagnostics)
    }

    public func checkUnedit(
        packageName: String,
        roots: [String],
        forceRemove: Bool = false,
        _ result: (DiagnosticsEngine) -> Void
    ) {
        let ws = self.createWorkspace()
        let diagnostics = DiagnosticsEngine()
        let rootInput = PackageGraphRootInput(packages: rootPaths(for: roots))
        diagnostics.wrap {
            try ws.unedit(packageName: packageName, forceRemove: forceRemove, root: rootInput, diagnostics: diagnostics)
        }
        result(diagnostics)
    }

    public func checkResolve(pkg: String, roots: [String], version: TSCUtility.Version, _ result: (DiagnosticsEngine) -> Void) {
        let diagnostics = DiagnosticsEngine()
        let workspace = self.createWorkspace()
        let rootInput = PackageGraphRootInput(packages: rootPaths(for: roots))
        diagnostics.wrap {
            try workspace.resolve(packageName: pkg, root: rootInput, version: version, branch: nil, revision: nil, diagnostics: diagnostics)
            result(diagnostics)
        }
    }

    public func checkClean(_ result: (DiagnosticsEngine) -> Void) {
        let diagnostics = DiagnosticsEngine()
        let workspace = self.createWorkspace()
        workspace.clean(with: diagnostics)
        result(diagnostics)
    }

    public func checkReset(_ result: (DiagnosticsEngine) -> Void) {
        let diagnostics = DiagnosticsEngine()
        let workspace = self.createWorkspace()
        workspace.reset(with: diagnostics)
        result(diagnostics)
    }

    public func checkUpdate(
        roots: [String] = [],
        deps: [MockDependency] = [],
        packages: [String] = [],
        _ result: (DiagnosticsEngine) -> Void
    ) {
        let dependencies = deps.map { $0.convert(baseURL: packagesDir) }
        let diagnostics = DiagnosticsEngine()
        let workspace = self.createWorkspace()
        let rootInput = PackageGraphRootInput(
            packages: rootPaths(for: roots), dependencies: dependencies
        )
        diagnostics.wrap {
            try workspace.updateDependencies(root: rootInput, packages: packages, diagnostics: diagnostics)
            result(diagnostics)
        }
    }

    public func checkUpdateDryRun(
        roots: [String] = [],
        deps: [MockDependency] = [],
        _ result: ([(PackageReference, Workspace.PackageStateChange)]?, DiagnosticsEngine) -> Void
    ) {
        let dependencies = deps.map { $0.convert(baseURL: packagesDir) }
        let diagnostics = DiagnosticsEngine()
        let workspace = self.createWorkspace()
        let rootInput = PackageGraphRootInput(
            packages: rootPaths(for: roots), dependencies: dependencies
        )
        diagnostics.wrap {
            let changes = try workspace.updateDependencies(root: rootInput, diagnostics: diagnostics, dryRun: true)
            result(changes, diagnostics)
        }
    }

    public func checkPackageGraph(
        roots: [String] = [],
        deps: [MockDependency],
        _ result: (PackageGraph, DiagnosticsEngine) -> Void
    ) {
        let dependencies = deps.map { $0.convert(baseURL: packagesDir) }
        self.checkPackageGraph(roots: roots, dependencies: dependencies, result)
    }

    public func checkPackageGraph(
        roots: [String] = [],
        dependencies: [PackageDependencyDescription] = [],
        forceResolvedVersions: Bool = false,
        _ result: (PackageGraph, DiagnosticsEngine) -> Void
    ) {
        let diagnostics = DiagnosticsEngine()
        let workspace = self.createWorkspace()
        let rootInput = PackageGraphRootInput(
            packages: rootPaths(for: roots), dependencies: dependencies
        )
        diagnostics.wrap {
            let graph = try workspace.loadPackageGraph(
                rootInput: rootInput, forceResolvedVersions: forceResolvedVersions, diagnostics: diagnostics
            )
            result(graph, diagnostics)
        }
    }

    public struct ResolutionPrecomputationResult {
        public let result: Workspace.ResolutionPrecomputationResult
        public let diagnostics: DiagnosticsEngine
    }

    public func checkPrecomputeResolution(_ check: (ResolutionPrecomputationResult) -> Void) throws {
        let diagnostics = DiagnosticsEngine()
        let workspace = self.createWorkspace()
        let pinsStore = try workspace.pinsStore.load()

        let rootInput = PackageGraphRootInput(packages: rootPaths(for: roots.map { $0.name }), dependencies: [])
        let rootManifests = try temp_await { workspace.loadRootManifests(packages: rootInput.packages, diagnostics: diagnostics, completion: $0) }
        let root = PackageGraphRoot(input: rootInput, manifests: rootManifests)

        let dependencyManifests = try workspace.loadDependencyManifests(root: root, diagnostics: diagnostics)

        let result = workspace.precomputeResolution(
            root: root,
            dependencyManifests: dependencyManifests,
            pinsStore: pinsStore,
            extraConstraints: []
        )

        check(ResolutionPrecomputationResult(result: result, diagnostics: diagnostics))
    }

    public func set(
        pins: [PackageReference: CheckoutState] = [:],
        managedDependencies: [ManagedDependency] = [],
        managedArtifacts: [ManagedArtifact] = []
    ) throws {
        let workspace = self.createWorkspace()
        let pinsStore = try workspace.pinsStore.load()

        for (ref, state) in pins {
            pinsStore.pin(packageRef: ref, state: state)
        }

        for dependency in managedDependencies {
            try self.fs.createDirectory(workspace.path(for: dependency), recursive: true)
            workspace.state.dependencies.add(dependency)
        }

        for artifact in managedArtifacts {
            if let path = workspace.path(for: artifact) {
                try self.fs.createDirectory(path, recursive: true)
            }

            workspace.state.artifacts.add(artifact)
        }

        try workspace.state.saveState()
    }

    public enum State {
        public enum CheckoutState {
            case version(TSCUtility.Version)
            case revision(String)
            case branch(String)
        }

        case checkout(CheckoutState)
        case edited(AbsolutePath?)
        case local
    }

    public struct ManagedDependencyResult {
        public let managedDependencies: ManagedDependencies

        public init(_ managedDependencies: ManagedDependencies) {
            self.managedDependencies = managedDependencies
        }

        public func check(notPresent name: String, file: StaticString = #file, line: UInt = #line) {
            let dependency = self.managedDependencies[forNameOrIdentity: name]
            XCTAssert(dependency == nil, "Unexpectedly found \(name) in managed dependencies", file: file, line: line)
        }

        public func checkEmpty(file: StaticString = #file, line: UInt = #line) {
            XCTAssertEqual(self.managedDependencies.count, 0, file: file, line: line)
        }

        public func check(dependency name: String, at state: State, file: StaticString = #file, line: UInt = #line) {
            guard let dependency = managedDependencies[forNameOrIdentity: name] else {
                XCTFail("\(name) does not exists", file: file, line: line)
                return
            }
            switch state {
            case .checkout(let checkoutState):
                switch checkoutState {
                case .version(let version):
                    XCTAssertEqual(dependency.checkoutState?.version, version, file: file, line: line)
                case .revision(let revision):
                    XCTAssertEqual(dependency.checkoutState?.revision.identifier, revision, file: file, line: line)
                case .branch(let branch):
                    XCTAssertEqual(dependency.checkoutState?.branch, branch, file: file, line: line)
                }
            case .edited(let path):
                if dependency.state != .edited(path) {
                    XCTFail("Expected edited dependency; found '\(dependency.state)' instead", file: file, line: line)
                }
            case .local:
                if dependency.state != .local {
                    XCTFail("Expected local dependency", file: file, line: line)
                }
            }
        }
    }

    public struct ManagedArtifactResult {
        public let managedArtifacts: ManagedArtifacts

        public init(_ managedArtifacts: ManagedArtifacts) {
            self.managedArtifacts = managedArtifacts
        }

        public func checkNotPresent(
            packageName: String,
            targetName: String,
            file: StaticString = #file,
            line: UInt = #line
        ) {
            let artifact = self.managedArtifacts[packageName: packageName, targetName: targetName]
            XCTAssert(artifact == nil, "Unexpectedly found \(packageName).\(targetName) in managed artifacts", file: file, line: line)
        }

        public func checkEmpty(file: StaticString = #file, line: UInt = #line) {
            XCTAssertEqual(self.managedArtifacts.count, 0, file: file, line: line)
        }

        public func check(
            packageName: String,
            targetName: String,
            source: ManagedArtifact.Source,
            file: StaticString = #file,
            line: UInt = #line
        ) {
            guard let artifact = managedArtifacts[packageName: packageName, targetName: targetName] else {
                XCTFail("\(packageName).\(targetName) does not exists", file: file, line: line)
                return
            }
            switch (artifact.source, source) {
            case (.remote(let lhsURL, let lhsChecksum, let lhsSubpath), .remote(let rhsURL, let rhsChecksum, let rhsSubpath)):
                XCTAssertEqual(lhsURL, rhsURL, file: file, line: line)
                XCTAssertEqual(lhsChecksum, rhsChecksum, file: file, line: line)
                XCTAssertEqual(lhsSubpath, rhsSubpath, file: file, line: line)
            case (.local(let lhsPath), .local(let rhsPath)):
                XCTAssertEqual(lhsPath, rhsPath, file: file, line: line)
            default:
                XCTFail("wrong source type", file: file, line: line)
            }
        }
    }

    public func loadDependencyManifests(
        roots: [String] = [],
        deps: [MockDependency] = [],
        _ result: (Workspace.DependencyManifests, DiagnosticsEngine) -> Void
    ) throws {
        let dependencies = deps.map { $0.convert(baseURL: packagesDir) }
        let diagnostics = DiagnosticsEngine()
        let workspace = self.createWorkspace()
        let rootInput = PackageGraphRootInput(
            packages: rootPaths(for: roots), dependencies: dependencies
        )
        let rootManifests = try tsc_await { workspace.loadRootManifests(packages: rootInput.packages, diagnostics: diagnostics, completion: $0) }
        let graphRoot = PackageGraphRoot(input: rootInput, manifests: rootManifests)
        let manifests = try workspace.loadDependencyManifests(root: graphRoot, diagnostics: diagnostics)
        result(manifests, diagnostics)
    }

    public func checkManagedDependencies(file: StaticString = #file, line: UInt = #line, _ result: (ManagedDependencyResult) throws -> Void) {
        do {
            let workspace = self.createWorkspace()
            try result(ManagedDependencyResult(workspace.state.dependencies))
        } catch {
            XCTFail("Failed with error \(error)", file: file, line: line)
        }
    }

    public func checkManagedArtifacts(file: StaticString = #file, line: UInt = #line, _ result: (ManagedArtifactResult) throws -> Void) {
        do {
            let workspace = self.createWorkspace()
            try result(ManagedArtifactResult(workspace.state.artifacts))
        } catch {
            XCTFail("Failed with error \(error)", file: file, line: line)
        }
    }

    public struct ResolvedResult {
        public let store: PinsStore

        public init(_ store: PinsStore) {
            self.store = store
        }

        public func check(notPresent name: String, file: StaticString = #file, line: UInt = #line) {
            XCTAssertFalse(self.store.pinsMap.keys.contains(where: { $0.description == name }), "Unexpectedly found \(name) in Package.resolved", file: file, line: line)
        }

        public func check(dependency package: String, at state: State, file: StaticString = #file, line: UInt = #line) {
            guard let pin = store.pinsMap.first(where: { $0.key.description == package })?.value else {
                XCTFail("Pin for \(package) not found", file: file, line: line)
                return
            }
            switch state {
            case .checkout(let state):
                switch state {
                case .version(let version):
                    XCTAssertEqual(pin.state.version, version, file: file, line: line)
                case .revision(let revision):
                    XCTAssertEqual(pin.state.revision.identifier, revision, file: file, line: line)
                case .branch(let branch):
                    XCTAssertEqual(pin.state.branch, branch, file: file, line: line)
                }
            case .edited, .local:
                XCTFail("Unimplemented", file: file, line: line)
            }
        }

        public func check(dependency package: String, url: String, file: StaticString = #file, line: UInt = #line) {
            guard let pin = store.pinsMap.first(where: { $0.key.description == package })?.value else {
                XCTFail("Pin for \(package) not found", file: file, line: line)
                return
            }

            XCTAssertEqual(pin.packageRef.path, url, file: file, line: line)
        }
    }

    public func checkResolved(file: StaticString = #file, line: UInt = #line, _ result: (ResolvedResult) throws -> Void) {
        do {
            let workspace = self.createWorkspace()
            try result(ResolvedResult(workspace.pinsStore.load()))
        } catch {
            XCTFail("Failed with error \(error)", file: file, line: line)
        }
    }
}

public final class MockWorkspaceDelegate: WorkspaceDelegate {
    private let lock = Lock()
    public var _events = [String]()

    public init() {}

    public func repositoryWillUpdate(_ repository: String) {
        self.append("updating repo: \(repository)")
    }

    public func dependenciesUpToDate() {
        self.append("Everything is already up-to-date")
    }

    public func fetchingWillBegin(repository: String, fetchDetails: RepositoryManager.FetchDetails?) {
        self.append("fetching repo: \(repository)")
    }

    public func fetchingDidFinish(repository: String, fetchDetails: RepositoryManager.FetchDetails?, diagnostic: Diagnostic?) {
        self.append("finished fetching repo: \(repository)")
    }

    public func cloning(repository: String) {
        self.append("cloning repo: \(repository)")
    }

    public func checkingOut(repository: String, atReference reference: String, to path: AbsolutePath) {
        self.append("checking out repo: \(repository)")
    }

    public func removing(repository: String) {
        self.append("removing repo: \(repository)")
    }

    public func willResolveDependencies(reason: WorkspaceResolveReason) {
        self.append("will resolve dependencies")
    }

    public func willLoadManifest(packagePath: AbsolutePath, url: String, version: Version?, packageKind: PackageReference.Kind) {
        self.append("will load manifest for \(packageKind) package: \(url)")
    }

    public func didLoadManifest(packagePath: AbsolutePath, url: String, version: Version?, packageKind: PackageReference.Kind, manifest: Manifest?, diagnostics: [Diagnostic]) {
        self.append("did load manifest for \(packageKind) package: \(url)")
    }

    private func append(_ event: String) {
        self.lock.withLock {
            self._events.append(event)
        }
    }

    public var events: [String] {
        self.lock.withLock {
            self._events
        }
    }

    public func clear() {
        self.lock.withLock {
            self._events = []
        }
    }
}
