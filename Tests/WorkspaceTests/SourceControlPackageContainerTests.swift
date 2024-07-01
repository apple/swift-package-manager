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
import Foundation
import PackageGraph
import PackageLoading
import PackageModel
import SourceControl
import _InternalTestSupport
@testable import Workspace
import XCTest

import enum TSCUtility.Git
import struct TSCUtility.Version

private class MockRepository: Repository {
    /// The fake location of the repository.
    let location: RepositorySpecifier.Location

    /// The known repository versions, as a map of tags to manifests.
    let versions: [Version: Manifest]

    let fs: FileSystem

    let packageRef: PackageReference

    init(fs: FileSystem, path: AbsolutePath, versions: [Version: Manifest]) {
        self.fs = fs
        self.location = .path(path)
        self.packageRef = .localSourceControl(identity: PackageIdentity(path: path), path: path)
        self.versions = versions
    }

    init(fs: FileSystem, url: SourceControlURL, versions: [Version: Manifest]) {
        self.fs = fs
        self.location = .url(url)
        self.packageRef = .remoteSourceControl(identity: PackageIdentity(url: url), url: url)
        self.versions = versions
    }

    var specifier: RepositorySpecifier {
        return RepositorySpecifier(location: self.location)
    }

    func getTags() throws -> [String] {
        return self.versions.keys.map { String(describing: $0) }
    }

    func resolveRevision(tag: String) throws -> Revision {
        assert(self.versions.index(forKey: Version(tag)!) != nil)
        return Revision(identifier: tag)
    }

    func resolveRevision(identifier: String) throws -> Revision {
        fatalError("Unexpected API call")
    }

    func fetch() throws {
        fatalError("Unexpected API call")
    }

    func exists(revision: Revision) -> Bool {
        fatalError("Unexpected API call")
    }

    func remove() throws {
        fatalError("Unexpected API call")
    }

    func openFileView(revision: Revision) throws -> FileSystem {
        assert(self.versions.index(forKey: Version(revision.identifier)!) != nil)
        // This is used for reading the tools version.
        return self.fs
    }

    public func openFileView(tag: String) throws -> FileSystem {
        let revision = try self.resolveRevision(tag: tag)
        return try self.openFileView(revision: revision)
    }
}

private class MockRepositories: RepositoryProvider {
    /// The known repositories, as a map of URL to repository.
    let repositories: [RepositorySpecifier.Location: MockRepository]
    var fetchRepositories = ThreadSafeKeyValueStore<RepositorySpecifier, AbsolutePath>()

    /// A mock manifest loader for all repositories.
    let manifestLoader: MockManifestLoader

    init(repositories repositoryList: [MockRepository]) {
        var allManifests: [MockManifestLoader.Key: Manifest] = [:]
        var repositories: [RepositorySpecifier.Location: MockRepository] = [:]
        for repository in repositoryList {
            assert(repositories.index(forKey: repository.location) == nil)
            repositories[repository.location] = repository
            for (version, manifest) in repository.versions {
                allManifests[MockManifestLoader.Key(url: repository.location.description, version: version)] = manifest
            }
        }

        self.repositories = repositories
        self.manifestLoader = MockManifestLoader(manifests: allManifests)
    }

    func fetch(repository: RepositorySpecifier, to path: AbsolutePath, progressHandler: FetchProgress.Handler? = nil) throws {
        assert(self.repositories.index(forKey: repository.location) != nil)
        self.fetchRepositories[repository] = path
    }

    func repositoryExists(at path: AbsolutePath) throws -> Bool {
        self.fetchRepositories.get().contains(where: { key, value in value == path })
    }

    func copy(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
        // No-op.
    }

    func workingCopyExists(at path: AbsolutePath) throws -> Bool {
        return false
    }

    func open(repository: RepositorySpecifier, at path: AbsolutePath) throws -> Repository {
        guard let repository = self.repositories[repository.location] else {
            throw InternalError("unknown repository at \(repository.location)")
        }
        return repository
    }

    func createWorkingCopy(repository: RepositorySpecifier, sourcePath: AbsolutePath, at destinationPath: AbsolutePath, editable: Bool) throws -> WorkingCheckout {
        fatalError("unexpected API call")
    }

    func openWorkingCopy(at path: AbsolutePath) throws -> WorkingCheckout {
        fatalError("unexpected API call")
    }

    func isValidDirectory(_ directory: AbsolutePath) throws -> Bool {
        return true
    }

    public func isValidDirectory(_ directory: AbsolutePath, for repository: RepositorySpecifier) throws -> Bool {
        return true
    }

    func cancel(deadline: DispatchTime) throws {
        // noop
    }
}

private class MockRepositoryManagerDelegate: RepositoryManager.Delegate {
    var fetched = ThreadSafeArrayStore<RepositorySpecifier>()
    var updated = ThreadSafeArrayStore<RepositorySpecifier>()

    func willFetch(package: PackageIdentity, repository: RepositorySpecifier, details: RepositoryManager.FetchDetails) {
        self.fetched.append(repository)
    }

    func fetching(package: PackageIdentity, repository: RepositorySpecifier, objectsFetched: Int, totalObjectsToFetch: Int) {}

    func didFetch(package: PackageIdentity, repository: RepositorySpecifier, result: Result<RepositoryManager.FetchDetails, Error>, duration: DispatchTimeInterval) {}

    func willUpdate(package: PackageIdentity, repository: RepositorySpecifier) {
        self.updated.append(repository)
    }

    func didUpdate(package: PackageIdentity, repository: RepositorySpecifier, duration: DispatchTimeInterval) {}

    func reset() {
        self.fetched.clear()
        self.updated.clear()
    }
}

// Some handy versions & ranges.
//
// The convention is that the name matches how specific the version is, so "v1"
// means "any 1.?.?", and "v1_1" means "any 1.1.?".

private let v1: Version = "1.0.0"
private let v2: Version = "2.0.0"
private let v1Range: VersionSetSpecifier = .range("1.0.0" ..< "2.0.0")

final class SourceControlPackageContainerTests: XCTestCase {
    func testVprefixVersions() async throws {
        let fs = InMemoryFileSystem()
        try fs.createMockToolchain()

        let repoPath = AbsolutePath.root.appending("SourceCache")
        let filePath = repoPath.appending("Package.swift")

        let specifier = RepositorySpecifier(path: repoPath)
        let repo = InMemoryGitRepository(path: repoPath, fs: fs)
        try repo.createDirectory(repoPath, recursive: true)
        try repo.writeFileContents(filePath, string: "// swift-tools-version:\(ToolsVersion.current)\n")
        try repo.commit()
        try repo.tag(name: "v1.0.0")
        try repo.tag(name: "v1.0.1")
        try repo.tag(name: "v1.0.2")
        try repo.tag(name: "v1.0.3")
        try repo.tag(name: "v2.0.3")

        let inMemRepoProvider = InMemoryGitRepositoryProvider()
        inMemRepoProvider.add(specifier: specifier, repository: repo)

        let p = AbsolutePath.root.appending("repoManager")
        try fs.createDirectory(p, recursive: true)
        let repositoryManager = RepositoryManager(
            fileSystem: fs,
            path: p,
            provider: inMemRepoProvider,
            delegate: MockRepositoryManagerDelegate()
        )

        let provider = try Workspace._init(
            fileSystem: fs,
            environment: .mockEnvironment,
            location: .init(forRootPackage: repoPath, fileSystem: fs),
            customHostToolchain: .mockHostToolchain(fs),
            customManifestLoader: MockManifestLoader(manifests: [:]),
            customRepositoryManager: repositoryManager
        )

        let ref = PackageReference.localSourceControl(identity: PackageIdentity(path: repoPath), path: repoPath)
        let container = try await provider.getContainer(for: ref)
        let v = try container.toolsVersionsAppropriateVersionsDescending()
        XCTAssertEqual(v, ["2.0.3", "1.0.3", "1.0.2", "1.0.1", "1.0.0"])
    }

    func testVersions() async throws {
        let fs = InMemoryFileSystem()
        try fs.createMockToolchain()

        let repoPath = AbsolutePath.root.appending("SourceCache")
        let filePath = repoPath.appending("Package.swift")

        let specifier = RepositorySpecifier(path: repoPath)
        let repo = InMemoryGitRepository(path: repoPath, fs: fs)

        try repo.createDirectory(repoPath, recursive: true)

        try repo.writeFileContents(filePath, bytes: "// swift-tools-version:3.1")
        try repo.commit()
        try repo.tag(name: "1.0.0")

        try repo.writeFileContents(filePath, bytes: "// swift-tools-version:4.0")
        try repo.commit()
        try repo.tag(name: "1.0.1")

        try repo.writeFileContents(filePath, bytes: "// swift-tools-version:4.2.0;hello\n")
        try repo.commit()
        try repo.tag(name: "1.0.2")

        try repo.writeFileContents(filePath, bytes: "// swift-tools-version:4.2.0\n")
        try repo.commit()
        try repo.tag(name: "1.0.3")

        let inMemRepoProvider = InMemoryGitRepositoryProvider()
        inMemRepoProvider.add(specifier: specifier, repository: repo)

        let p = AbsolutePath.root.appending("repoManager")
        try fs.createDirectory(p, recursive: true)
        let repositoryManager = RepositoryManager(
            fileSystem: fs,
            path: p,
            provider: inMemRepoProvider,
            delegate: MockRepositoryManagerDelegate()
        )

        func createProvider(_ currentToolsVersion: ToolsVersion) throws -> PackageContainerProvider {
            return try Workspace._init(
                fileSystem: fs,
                environment: .mockEnvironment,
                location: .init(forRootPackage: repoPath, fileSystem: fs),
                customToolsVersion: currentToolsVersion,
                customHostToolchain: .mockHostToolchain(fs),
                customManifestLoader: MockManifestLoader(manifests: [:]),
                customRepositoryManager: repositoryManager
            )
        }

        do {
            let provider = try createProvider(ToolsVersion(version: "4.0.0"))
            let ref = PackageReference.localSourceControl(identity: PackageIdentity(path: repoPath), path: repoPath)
            let container = try await provider.getContainer(for: ref)
            let v = try container.toolsVersionsAppropriateVersionsDescending()
            XCTAssertEqual(v, ["1.0.1"])
        }

        do {
            let provider = try createProvider(ToolsVersion(version: "4.2.0"))
            let ref = PackageReference.localSourceControl(identity: PackageIdentity(path: repoPath), path: repoPath)
            let container = try await provider.getContainer(for: ref) as! SourceControlPackageContainer
            XCTAssertTrue(container.validToolsVersionsCache.isEmpty)
            let v = try container.toolsVersionsAppropriateVersionsDescending()
            XCTAssertEqual(container.validToolsVersionsCache["1.0.0"], false)
            XCTAssertEqual(container.validToolsVersionsCache["1.0.1"], true)
            XCTAssertEqual(container.validToolsVersionsCache["1.0.2"], true)
            XCTAssertEqual(container.validToolsVersionsCache["1.0.3"], true)
            XCTAssertEqual(v, ["1.0.3", "1.0.2", "1.0.1"])
        }

        do {
            let provider = try createProvider(ToolsVersion(version: "3.0.0"))
            let ref = PackageReference.localSourceControl(identity: PackageIdentity(path: repoPath), path: repoPath)
            let container = try await provider.getContainer(for: ref)
            let v = try container.toolsVersionsAppropriateVersionsDescending()
            XCTAssertEqual(v, [])
        }

        // Test that getting dependencies on a revision that has unsupported tools version is diagnosed properly.
        do {
            let provider = try createProvider(ToolsVersion(version: "4.0.0"))
            let ref = PackageReference.localSourceControl(identity: PackageIdentity(path: repoPath), path: repoPath)
            let container = try await provider.getContainer(for: ref) as! SourceControlPackageContainer
            let revision = try container.getRevision(forTag: "1.0.0")
            do {
                _ = try container.getDependencies(at: revision.identifier, productFilter: .nothing)
            } catch let error as SourceControlPackageContainer.GetDependenciesError {
                let error = error.underlyingError as! UnsupportedToolsVersion
                XCTAssertMatch(error.description, .and(.prefix("package '\(PackageIdentity(path: repoPath))' @"), .suffix("is using Swift tools version 3.1.0 which is no longer supported; consider using '// swift-tools-version:4.0' to specify the current tools version")))
            }
        }
    }

    func testPreReleaseVersions() async throws {
        let fs = InMemoryFileSystem()
        try fs.createMockToolchain()

        // Insert an arc in the path prior to the repository root to prevent
        // `\Package.swift` being the path that is used.  The
        // intermediate arc allows processing the tools versions.
        let repoPath = AbsolutePath.root.appending("SourceCache")
        let filePath = repoPath.appending("Package.swift")

        let specifier = RepositorySpecifier(path: repoPath)
        let repo = InMemoryGitRepository(path: repoPath, fs: fs)
        try repo.createDirectory(repoPath, recursive: true)
        try repo.writeFileContents(filePath, string: "// swift-tools-version:\(ToolsVersion.current)\n")
        try repo.commit()
        try repo.tag(name: "1.0.0-alpha.1")
        try repo.tag(name: "1.0.0-beta.1")
        try repo.tag(name: "1.0.0")
        try repo.tag(name: "1.0.1")
        try repo.tag(name: "1.0.2-dev")
        try repo.tag(name: "1.0.2-dev.2")
        try repo.tag(name: "1.0.4-alpha")

        let inMemRepoProvider = InMemoryGitRepositoryProvider()
        inMemRepoProvider.add(specifier: specifier, repository: repo)

        let p = AbsolutePath.root.appending("repoManager")
        try fs.createDirectory(p, recursive: true)
        let repositoryManager = RepositoryManager(
            fileSystem: fs,
            path: p,
            provider: inMemRepoProvider,
            delegate: MockRepositoryManagerDelegate()
        )

        let provider = try Workspace._init(
            fileSystem: fs,
            environment: .mockEnvironment,
            location: .init(forRootPackage: repoPath, fileSystem: fs),
            customHostToolchain: .mockHostToolchain(fs),
            customManifestLoader: MockManifestLoader(manifests: [:]),
            customRepositoryManager: repositoryManager
        )

        let ref = PackageReference.localSourceControl(identity: PackageIdentity(path: repoPath), path: repoPath)
        let container = try await provider.getContainer(for: ref)
        let v = try container.toolsVersionsAppropriateVersionsDescending()
        XCTAssertEqual(v, ["1.0.4-alpha", "1.0.2-dev.2", "1.0.2-dev", "1.0.1", "1.0.0", "1.0.0-beta.1", "1.0.0-alpha.1"])
    }

    func testSimultaneousVersions() async throws {
        let fs = InMemoryFileSystem()
        try fs.createMockToolchain()

        let repoPath = AbsolutePath.root.appending("SourceCache")
        let filePath = repoPath.appending("Package.swift")

        let specifier = RepositorySpecifier(path: repoPath)
        let repo = InMemoryGitRepository(path: repoPath, fs: fs)
        try repo.createDirectory(repoPath, recursive: true)
        try repo.writeFileContents(filePath, string: "// swift-tools-version:\(ToolsVersion.current)\n")
        try repo.commit()
        try repo.tag(name: "v1.0.0")
        try repo.tag(name: "1.0.0")
        try repo.tag(name: "v1.1.0")
        try repo.tag(name: "1.1.0")
        try repo.tag(name: "1.1")
        try repo.tag(name: "1.2")
        try repo.tag(name: "1.3")
        try repo.tag(name: "1.3.0")
        try repo.tag(name: "1.0.1")
        try repo.tag(name: "v1.0.2")
        try repo.tag(name: "1.0.4")
        try repo.tag(name: "v2.0.1")

        let inMemRepoProvider = InMemoryGitRepositoryProvider()
        inMemRepoProvider.add(specifier: specifier, repository: repo)

        let p = AbsolutePath.root.appending("repoManager")
        try fs.createDirectory(p, recursive: true)
        let repositoryManager = RepositoryManager(
            fileSystem: fs,
            path: p,
            provider: inMemRepoProvider,
            delegate: MockRepositoryManagerDelegate()
        )

        let provider = try Workspace._init(
            fileSystem: fs,
            environment: .mockEnvironment,
            location: .init(forRootPackage: repoPath, fileSystem: fs),
            customHostToolchain: .mockHostToolchain(fs),
            customManifestLoader: MockManifestLoader(manifests: [:]),
            customRepositoryManager: repositoryManager
        )
        let ref = PackageReference.localSourceControl(identity: PackageIdentity(path: repoPath), path: repoPath)
        let container = try await provider.getContainer(for: ref)
        let v = try container.toolsVersionsAppropriateVersionsDescending()
        XCTAssertEqual(v, ["2.0.1", "1.3.0", "1.2.0", "1.1.0", "1.0.4", "1.0.2", "1.0.1", "1.0.0"])
    }

    func testDependencyConstraints() throws {
#if ENABLE_TARGET_BASED_DEPENDENCY_RESOLUTION
#else
        try XCTSkipIf(true)
#endif

        let dependencies: [PackageDependency] = [
            .localSourceControl(path: "/Bar1", requirement: .upToNextMajor(from: "1.0.0")),
            .localSourceControl(path: "/Bar2", requirement: .upToNextMajor(from: "1.0.0")),
            .localSourceControl(path: "/Bar3", requirement: .upToNextMajor(from: "1.0.0")),
        ]

        let products = [
            try ProductDescription(name: "Foo", type: .library(.automatic), targets: ["Foo1"]),
        ]

        let targets = [
            try TargetDescription(name: "Foo1", dependencies: ["Foo2", "Bar1"]),
            try TargetDescription(name: "Foo2", dependencies: [.product(name: "B2", package: "Bar2")]),
            try TargetDescription(name: "Foo3", dependencies: ["Bar3"]),
        ]

        let v5ProductMapping: [String: ProductFilter] = [
            "bar1": .specific(["Bar1", "Bar3"]),
            "bar2": .specific(["B2", "Bar1", "Bar3"]),
            "bar3": .specific(["Bar1", "Bar3"]),
        ]
        let v5Constraints = try dependencies.map {
            PackageContainerConstraint(
                package: $0.packageRef,
                requirement: try $0.toConstraintRequirement(),
                products: v5ProductMapping[$0.identity.description]!
            )
        }
        let v5_2ProductMapping: [String: ProductFilter] = [
            "bar1": .specific(["Bar1"]),
            "bar2": .specific(["B2"]),
            "bar3": .specific(["Bar3"]),
        ]
        let v5_2Constraints = try dependencies.map {
            PackageContainerConstraint(
                package: $0.packageRef,
                requirement: try $0.toConstraintRequirement(),
                products: v5_2ProductMapping[$0.identity.description]!
            )
        }

        do {
            let manifest = Manifest.createRootManifest(
                displayName: "Foo",
                path: "/Foo",
                toolsVersion: .v5,
                dependencies: dependencies,
                products: products,
                targets: targets
            )

            XCTAssertEqual(
                try manifest
                    .dependencyConstraints(productFilter: .everything)
                    .sorted(by: { $0.package.identity < $1.package.identity }),
                [
                    v5Constraints[0],
                    v5Constraints[1],
                    v5Constraints[2],
                ]
            )
        }

        do {
            let manifest = Manifest.createFileSystemManifest(
                displayName: "Foo",
                path: "/Foo",
                toolsVersion: .v5,
                dependencies: dependencies,
                products: products,
                targets: targets
            )

            XCTAssertEqual(
                try manifest
                    .dependencyConstraints(productFilter: .everything)
                    .sorted(by: { $0.package.identity < $1.package.identity }),
                [
                    v5Constraints[0],
                    v5Constraints[1],
                    v5Constraints[2],
                ]
            )
        }

        do {
            let manifest = Manifest.createRootManifest(
                displayName: "Foo",
                path: "/Foo",
                toolsVersion: .v5_2,
                dependencies: dependencies,
                products: products,
                targets: targets
            )

            XCTAssertEqual(
                try manifest
                    .dependencyConstraints(productFilter: .everything)
                    .sorted(by: { $0.package.identity < $1.package.identity }),
                [
                    v5_2Constraints[0],
                    v5_2Constraints[1],
                    v5_2Constraints[2],
                ]
            )
        }

        do {
            let manifest = Manifest.createFileSystemManifest(
                displayName: "Foo",
                path: "/Foo",
                toolsVersion: .v5_2,
                dependencies: dependencies,
                products: products,
                targets: targets
            )

            XCTAssertEqual(
                try manifest
                    .dependencyConstraints(productFilter: .specific(Set(products.map { $0.name })))
                    .sorted(by: { $0.package.identity < $1.package.identity }),
                [
                    v5_2Constraints[0],
                    v5_2Constraints[1],
                ]
            )
        }
    }

    func testMissingBranchDiagnostics() async throws {
        try await testWithTemporaryDirectory { tmpDir in
            // Create a repository.
            let packageDir = tmpDir.appending("SomePackage")
            try localFileSystem.createDirectory(packageDir)
            initGitRepo(packageDir)
            let packageRepo = GitRepository(path: packageDir)

            // Create a package manifest in it (it only needs the `swift-tools-version` part, because we'll supply the manifest later).
            let manifestFile = packageDir.appending("Package.swift")
            try localFileSystem.writeFileContents(manifestFile, string: "// swift-tools-version:4.2")

            // Commit it and tag it.
            try packageRepo.stage(file: "Package.swift")
            try packageRepo.commit(message: "Initial")
            try packageRepo.tag(name: "1.0.0")

            // Rename the `master` branch to `main`.
            try systemQuietly([Git.tool, "-C", packageDir.pathString, "branch", "-m", "main"])

            // Create a repository manager for it.
            let repoProvider = GitRepositoryProvider()
            let repositoryManager = RepositoryManager(
                fileSystem: localFileSystem,
                path: packageDir,
                provider: repoProvider,
                delegate: .none
            )

            // Create a container provider, configured with a mock manifest loader that will return the package manifest.
            let manifest = Manifest.createRootManifest(
                displayName: packageDir.basename,
                path: packageDir,
                targets: [
                    try TargetDescription(name: packageDir.basename, path: packageDir.pathString),
                ]
            )
            let containerProvider = try Workspace._init(
                fileSystem: localFileSystem,
                environment: .current,
                location: .init(forRootPackage: packageDir, fileSystem: localFileSystem),
                customManifestLoader: MockManifestLoader(manifests: [.init(url: packageDir.pathString, version: nil): manifest]),
                customRepositoryManager: repositoryManager
            )

            // Get a hold of the container for the test package.
            let packageRef = PackageReference.localSourceControl(identity: PackageIdentity(path: packageDir), path: packageDir)
            let container = try await containerProvider.getContainer(for: packageRef) as! SourceControlPackageContainer

            // Simulate accessing a fictitious dependency on the `master` branch, and check that we get back the expected error.
            do { _ = try container.getDependencies(at: "master", productFilter: .everything) }
            catch let error as SourceControlPackageContainer.GetDependenciesError {
                // We expect to get an error message that mentions main.
                XCTAssertMatch(error.description, .and(.prefix("could not find a branch named ‘master’"), .suffix("(did you mean ‘main’?)")))
                XCTAssertMatch(error.repository.description, .suffix("SomePackage"))
                XCTAssertMatch(error.reference, "master")
            }

            // Simulate accessing a fictitious dependency on some random commit that doesn't exist, and check that we get back the expected error.
            do { _ = try container.getDependencies(at: "535f4cb5b4a0872fa691473e82d7b27b9894df00", productFilter: .everything) }
            catch let error as SourceControlPackageContainer.GetDependenciesError {
                // We expect to get an error message about the specific commit.
                XCTAssertMatch(error.description, .prefix("could not find the commit 535f4cb5b4a0872fa691473e82d7b27b9894df00"))
                XCTAssertMatch(error.repository.description, .suffix("SomePackage"))
                XCTAssertMatch(error.reference, "535f4cb5b4a0872fa691473e82d7b27b9894df00")
            }
        }
    }

    func testRepositoryContainerUpdateStrategy() async throws {
        try await testWithTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("MyPackage")
            let package = PackageReference.localSourceControl(identity: PackageIdentity(path: packageDirectory), path: packageDirectory)

            try localFileSystem.createDirectory(packageDirectory)
            initGitRepo(packageDirectory)

            try localFileSystem.writeFileContents(packageDirectory.appending(Manifest.filename), string: "")
            try ToolsVersionSpecificationWriter.rewriteSpecification(manifestDirectory: packageDirectory, toolsVersion: .current, fileSystem: localFileSystem)


            let repositoryProvider = GitRepositoryProvider()
            let repositoryManagerDelegate = MockRepositoryManagerDelegate()
            let repositoryManager = RepositoryManager(
                fileSystem: localFileSystem,
                path: packageDirectory,
                provider: repositoryProvider,
                delegate: repositoryManagerDelegate
            )

            let containerProvider = try Workspace._init(
                fileSystem: localFileSystem,
                environment: .current,
                location: .init(forRootPackage: packageDirectory, fileSystem: localFileSystem),
                customManifestLoader: MockManifestLoader(
                    manifests: [
                        .init(url: packageDirectory.pathString, version: nil): Manifest.createRootManifest(
                            displayName: packageDirectory.basename,
                            path: packageDirectory,
                            targets: [
                                try TargetDescription(name: packageDirectory.basename, path: packageDirectory.pathString),
                            ]
                        )
                    ]
                ),
                customRepositoryManager: repositoryManager
            )

            do {
                repositoryManagerDelegate.reset()
                XCTAssertEqual(repositoryManagerDelegate.updated.count, 0)
                _ = try await containerProvider.getContainer(
                    for: package,
                    updateStrategy: .never
                )
                XCTAssertEqual(repositoryManagerDelegate.updated.count, 0)
            }

            do {
                repositoryManagerDelegate.reset()
                XCTAssertEqual(repositoryManagerDelegate.updated.count, 0)
                _ = try await containerProvider.getContainer(
                    for: package,
                    updateStrategy: .always
                )
                XCTAssertEqual(repositoryManagerDelegate.updated.count, 1)
            }

            do {
                let repository = GitRepository(path: packageDirectory)
                try repository.tag(name: "1.0.0")
                let revision = try repository.resolveRevision(tag: "1.0.0")

                repositoryManagerDelegate.reset()
                XCTAssertEqual(repositoryManagerDelegate.updated.count, 0)
                _ = try await containerProvider.getContainer(
                    for: package,
                    updateStrategy: .ifNeeded(revision: revision.identifier)
                )
                XCTAssertEqual(repositoryManagerDelegate.updated.count, 0)
            }

            do {
                repositoryManagerDelegate.reset()
                XCTAssertEqual(repositoryManagerDelegate.updated.count, 0)
                _ = try await containerProvider.getContainer(
                    for: package,
                    updateStrategy: .ifNeeded(revision: UUID().uuidString)
                )
                XCTAssertEqual(repositoryManagerDelegate.updated.count, 1)
            }
        }
    }

    // From rdar://problem/65284674
    // RepositoryPackageContainer used to erroneously cache dependencies based only on version,
    // storing the result of the first product filter and then continually returning it for other filters too.
    // This lead to corrupt graph states.
    func testRepositoryPackageContainerCache() async throws {
        try await testWithTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("Package")
            try localFileSystem.createDirectory(packageDirectory)
            initGitRepo(packageDirectory)
            let packageRepository = GitRepository(path: packageDirectory)

            let manifestFile = packageDirectory.appending("Package.swift")
            try localFileSystem.writeFileContents(manifestFile, string: "// swift-tools-version:5.2")

            try packageRepository.stage(file: "Package.swift")
            try packageRepository.commit(message: "Initialized.")
            try packageRepository.tag(name: "1.0.0")

            let repositoryProvider = GitRepositoryProvider()
            let repositoryManager = RepositoryManager(
                fileSystem: localFileSystem,
                path: packageDirectory,
                provider: repositoryProvider,
                delegate: .none
            )

            let version = Version(1, 0, 0)
            let manifest = Manifest.createRootManifest(
                displayName: packageDirectory.basename,
                path: packageDirectory,
                toolsVersion: .v5_2,
                dependencies: [
                    .localSourceControl(
                        path: "/Somewhere/Dependency",
                        requirement: .exact(version),
                        productFilter: .specific([])
                    )
                ],
                products: [
                    try ProductDescription(name: "Product", type: .library(.automatic), targets: ["Target"])
                ],
                targets: [
                    try TargetDescription(
                        name: "Target",
                        dependencies: [.product(name: "DependencyProduct", package: "Dependency")]
                    ),
                ]
            )
            let containerProvider = try Workspace._init(
                fileSystem: localFileSystem,
                environment: .current,
                location: .init(forRootPackage: packageDirectory, fileSystem: localFileSystem),
                customManifestLoader: MockManifestLoader(
                    manifests: [.init(url: packageDirectory.pathString, version: Version(1, 0, 0)): manifest]
                ),
                customRepositoryManager: repositoryManager
            )

            let packageReference = PackageReference.localSourceControl(identity: PackageIdentity(path: packageDirectory), path: packageDirectory)
            let container = try await containerProvider.getContainer(for: packageReference)

            let forNothing = try container.getDependencies(at: version, productFilter: .specific([]))
            let forProduct = try container.getDependencies(at: version, productFilter: .specific(["Product"]))
            #if ENABLE_TARGET_BASED_DEPENDENCY_RESOLUTION
            // If the cache overlaps (incorrectly), these will be the same.
            XCTAssertNotEqual(forNothing, forProduct)
            #endif
        }
    }
}

extension PackageContainerProvider {
    fileprivate func getContainer(
        for package: PackageReference,
        updateStrategy: ContainerUpdateStrategy = .always
    ) async throws -> PackageContainer {
        try await safe_async {
            self.getContainer(
                for: package,
                updateStrategy: updateStrategy,
                observabilityScope: ObservabilitySystem.NOOP,
                on: .global(),
                completion: $0
            )
        }
    }
}

extension RepositoryManager {
    fileprivate convenience init(
        fileSystem: FileSystem,
        path: AbsolutePath,
        provider: RepositoryProvider,
        cachePath: AbsolutePath? =  .none,
        cacheLocalPackages: Bool = false,
        delegate: RepositoryManagerDelegate? = .none
    ) {
        self.init(
            fileSystem: fileSystem,
            path: path,
            provider: provider,
            cachePath: cachePath,
            cacheLocalPackages: cacheLocalPackages,
            initializationWarningHandler: { _ in },
            delegate: delegate
        )
    }
}
