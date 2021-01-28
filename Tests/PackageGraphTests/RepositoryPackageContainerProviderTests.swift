/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import XCTest

import Basics
@testable import PackageGraph
import PackageLoading
import PackageModel
import SourceControl
import TSCBasic
import TSCUtility

import SPMTestSupport

private class MockRepository: Repository {
    /// The fake URL of the repository.
    let url: String

    /// The known repository versions, as a map of tags to manifests.
    let versions: [Version: Manifest]

    let fs: FileSystem

    init(fs: FileSystem, url: String, versions: [Version: Manifest]) {
        self.fs = fs
        self.url = url
        self.versions = versions
    }

    var specifier: RepositorySpecifier {
        return RepositorySpecifier(url: self.url)
    }

    var packageRef: PackageReference {
        return PackageReference(identity: PackageIdentity(url: self.url), path: self.url)
    }

    func getTags() throws -> [String] {
        return self.versions.keys.map { String(describing: $0) }
    }

    func resolveRevision(tag: String) throws -> Revision {
        assert(self.versions.index(forKey: Version(string: tag)!) != nil)
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
        assert(self.versions.index(forKey: Version(string: revision.identifier)!) != nil)
        // This is used for reading the tools version.
        return self.fs
    }
}

private class MockRepositories: RepositoryProvider {
    /// The known repositories, as a map of URL to repository.
    let repositories: [String: MockRepository]

    /// A mock manifest loader for all repositories.
    let manifestLoader: MockManifestLoader

    init(repositories repositoryList: [MockRepository]) {
        var allManifests: [MockManifestLoader.Key: Manifest] = [:]
        var repositories: [String: MockRepository] = [:]
        for repository in repositoryList {
            assert(repositories.index(forKey: repository.url) == nil)
            repositories[repository.url] = repository
            for (version, manifest) in repository.versions {
                allManifests[MockManifestLoader.Key(url: repository.url, version: version)] = manifest
            }
        }

        self.repositories = repositories
        self.manifestLoader = MockManifestLoader(manifests: allManifests)
    }

    func fetch(repository: RepositorySpecifier, to path: AbsolutePath) throws {
        // No-op.
        assert(self.repositories.index(forKey: repository.url) != nil)
    }

    func copy(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
        // No-op.
    }

    func checkoutExists(at path: AbsolutePath) throws -> Bool {
        return false
    }

    func open(repository: RepositorySpecifier, at path: AbsolutePath) throws -> Repository {
        return self.repositories[repository.url]!
    }

    func cloneCheckout(repository: RepositorySpecifier, at sourcePath: AbsolutePath, to destinationPath: AbsolutePath, editable: Bool) throws {
        fatalError("unexpected API call")
    }

    func openCheckout(at path: AbsolutePath) throws -> WorkingCheckout {
        fatalError("unexpected API call")
    }
}

private class MockResolverDelegate: RepositoryManagerDelegate {
    var fetched = [RepositorySpecifier]()

    func fetchingWillBegin(handle: RepositoryManager.RepositoryHandle, fetchDetails: RepositoryManager.FetchDetails?) {
        self.fetched += [handle.repository]
    }

    func fetchingDidFinish(handle: RepositoryManager.RepositoryHandle, fetchDetails: RepositoryManager.FetchDetails?, error: Swift.Error?) {
    }
}

// Some handy versions & ranges.
//
// The convention is that the name matches how specific the version is, so "v1"
// means "any 1.?.?", and "v1_1" means "any 1.1.?".

private let v1: Version = "1.0.0"
private let v2: Version = "2.0.0"
private let v1Range: VersionSetSpecifier = .range("1.0.0" ..< "2.0.0")

class RepositoryPackageContainerProviderTests: XCTestCase {
    func testVprefixVersions() throws {
        let fs = InMemoryFileSystem()

        let repoPath = AbsolutePath.root
        let filePath = repoPath.appending(component: "Package.swift")

        let specifier = RepositorySpecifier(url: repoPath.pathString)
        let repo = InMemoryGitRepository(path: repoPath, fs: fs)
        try repo.createDirectory(repoPath, recursive: true)
        try repo.writeFileContents(filePath, bytes: ByteString(encodingAsUTF8: "// swift-tools-version:\(ToolsVersion.currentToolsVersion)\n"))
        try repo.commit()
        try repo.tag(name: "v1.0.0")
        try repo.tag(name: "v1.0.1")
        try repo.tag(name: "v1.0.2")
        try repo.tag(name: "v1.0.3")
        try repo.tag(name: "v2.0.3")

        let inMemRepoProvider = InMemoryGitRepositoryProvider()
        inMemRepoProvider.add(specifier: specifier, repository: repo)

        let p = AbsolutePath.root.appending(component: "repoManager")
        try fs.createDirectory(p, recursive: true)
        let repositoryManager = RepositoryManager(
            path: p,
            provider: inMemRepoProvider,
            delegate: MockResolverDelegate(),
            fileSystem: fs
        )

        let provider = RepositoryPackageContainerProvider(
            repositoryManager: repositoryManager,
            manifestLoader: MockManifestLoader(manifests: [:]),
            verbosity: TSCUtility.verbosity
        )

        let ref = PackageReference(identity: PackageIdentity(path: repoPath), path: repoPath.pathString)
        let container = try provider.getContainer(for: ref, skipUpdate: false)
        let v = try container.toolsVersionsAppropriateVersionsDescending().map { $0 }
        XCTAssertEqual(v, ["2.0.3", "1.0.3", "1.0.2", "1.0.1", "1.0.0"])
    }

    func testVersions() throws {
        let fs = InMemoryFileSystem()

        let repoPath = AbsolutePath.root
        let filePath = repoPath.appending(component: "Package.swift")

        let specifier = RepositorySpecifier(url: repoPath.pathString)
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

        let p = AbsolutePath.root.appending(component: "repoManager")
        try fs.createDirectory(p, recursive: true)
        let repositoryManager = RepositoryManager(
            path: p,
            provider: inMemRepoProvider,
            delegate: MockResolverDelegate(),
            fileSystem: fs
        )

        func createProvider(_ currentToolsVersion: ToolsVersion) -> RepositoryPackageContainerProvider {
            return RepositoryPackageContainerProvider(
                repositoryManager: repositoryManager,
                manifestLoader: MockManifestLoader(manifests: [:]),
                currentToolsVersion: currentToolsVersion,
                verbosity: TSCUtility.verbosity
            )
        }

        do {
            let provider = createProvider(ToolsVersion(version: "4.0.0"))
            let ref = PackageReference(identity: PackageIdentity(url: specifier.url), path: specifier.url)
            let container = try provider.getContainer(for: ref, skipUpdate: false)
            let v = try container.toolsVersionsAppropriateVersionsDescending().map { $0 }
            XCTAssertEqual(v, ["1.0.1"])
        }

        do {
            let provider = createProvider(ToolsVersion(version: "4.2.0"))
            let ref = PackageReference(identity: PackageIdentity(url: specifier.url), path: specifier.url)
            let container = try provider.getContainer(for: ref, skipUpdate: false) as! RepositoryPackageContainer
            XCTAssertTrue(container.validToolsVersionsCache.isEmpty)
            let v = try container.toolsVersionsAppropriateVersionsDescending().map { $0 }
            XCTAssertEqual(container.validToolsVersionsCache["1.0.0"], false)
            XCTAssertEqual(container.validToolsVersionsCache["1.0.1"], true)
            XCTAssertEqual(container.validToolsVersionsCache["1.0.2"], true)
            XCTAssertEqual(container.validToolsVersionsCache["1.0.3"], true)
            XCTAssertEqual(v, ["1.0.3", "1.0.2", "1.0.1"])
        }

        do {
            let provider = createProvider(ToolsVersion(version: "3.0.0"))
            let ref = PackageReference(identity: PackageIdentity(url: specifier.url), path: specifier.url)
            let container = try provider.getContainer(for: ref, skipUpdate: false)
            let v = try container.toolsVersionsAppropriateVersionsDescending().map { $0 }
            XCTAssertEqual(v, [])
        }

        // Test that getting dependencies on a revision that has unsupported tools version is diganosed properly.
        do {
            let provider = createProvider(ToolsVersion(version: "4.0.0"))
            let ref = PackageReference(identity: PackageIdentity(url: specifier.url), path: specifier.url)
            let container = try provider.getContainer(for: ref, skipUpdate: false) as! RepositoryPackageContainer
            let revision = try container.getRevision(forTag: "1.0.0")
            do {
                _ = try container.getDependencies(at: revision.identifier, productFilter: .nothing)
            } catch let error as RepositoryPackageContainer.GetDependenciesError {
                let error = error.underlyingError as! UnsupportedToolsVersion
                XCTAssertMatch(error.description, .and(.prefix("package at '/' @"), .suffix("is using Swift tools version 3.1.0 which is no longer supported; consider using '// swift-tools-version:4.0' to specify the current tools version")))
            }
        }
    }

    func testPrereleaseVersions() throws {
        let fs = InMemoryFileSystem()

        let repoPath = AbsolutePath.root
        let filePath = repoPath.appending(component: "Package.swift")

        let specifier = RepositorySpecifier(url: repoPath.pathString)
        let repo = InMemoryGitRepository(path: repoPath, fs: fs)
        try repo.createDirectory(repoPath, recursive: true)
        try repo.writeFileContents(filePath, bytes: ByteString(encodingAsUTF8: "// swift-tools-version:\(ToolsVersion.currentToolsVersion)\n"))
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

        let p = AbsolutePath.root.appending(component: "repoManager")
        try fs.createDirectory(p, recursive: true)
        let repositoryManager = RepositoryManager(
            path: p,
            provider: inMemRepoProvider,
            delegate: MockResolverDelegate(),
            fileSystem: fs
        )

        let provider = RepositoryPackageContainerProvider(
            repositoryManager: repositoryManager,
            manifestLoader: MockManifestLoader(manifests: [:]),
            verbosity: TSCUtility.verbosity
        )
        let ref = PackageReference(identity: PackageIdentity(path: repoPath), path: repoPath.pathString)
        let container = try provider.getContainer(for: ref, skipUpdate: false)
        let v = try container.toolsVersionsAppropriateVersionsDescending().map { $0 }
        XCTAssertEqual(v, ["1.0.4-alpha", "1.0.2-dev.2", "1.0.2-dev", "1.0.1", "1.0.0", "1.0.0-beta.1", "1.0.0-alpha.1"])
    }

    func testSimultaneousVersions() throws {
        let fs = InMemoryFileSystem()

        let repoPath = AbsolutePath.root
        let filePath = repoPath.appending(component: "Package.swift")

        let specifier = RepositorySpecifier(url: repoPath.pathString)
        let repo = InMemoryGitRepository(path: repoPath, fs: fs)
        try repo.createDirectory(repoPath, recursive: true)
        try repo.writeFileContents(filePath, bytes: ByteString(encodingAsUTF8: "// swift-tools-version:\(ToolsVersion.currentToolsVersion)\n"))
        try repo.commit()
        try repo.tag(name: "v1.0.0")
        try repo.tag(name: "1.0.0")
        try repo.tag(name: "1.0.1")
        try repo.tag(name: "v1.0.2")
        try repo.tag(name: "1.0.4")
        try repo.tag(name: "v2.0.1")

        let inMemRepoProvider = InMemoryGitRepositoryProvider()
        inMemRepoProvider.add(specifier: specifier, repository: repo)

        let p = AbsolutePath.root.appending(component: "repoManager")
        try fs.createDirectory(p, recursive: true)
        let repositoryManager = RepositoryManager(
            path: p,
            provider: inMemRepoProvider,
            delegate: MockResolverDelegate(),
            fileSystem: fs
        )

        let provider = RepositoryPackageContainerProvider(
            repositoryManager: repositoryManager,
            manifestLoader: MockManifestLoader(manifests: [:]),
            verbosity: TSCUtility.verbosity
        )
        let ref = PackageReference(identity: PackageIdentity(path: repoPath), path: repoPath.pathString)
        let container = try provider.getContainer(for: ref, skipUpdate: false)
        let v = try container.toolsVersionsAppropriateVersionsDescending().map { $0 }
        XCTAssertEqual(v, ["2.0.1", "1.0.4", "1.0.2", "1.0.1", "1.0.0"])
    }

    func testDependencyConstraints() throws {
        #if ENABLE_TARGET_BASED_DEPENDENCY_RESOLUTION
        #else
        try XCTSkipIf(true)
        #endif

        let dependencies = [
            PackageDependencyDescription(name: "Bar1", url: "/Bar1", requirement: .upToNextMajor(from: "1.0.0")),
            PackageDependencyDescription(name: "Bar2", url: "/Bar2", requirement: .upToNextMajor(from: "1.0.0")),
            PackageDependencyDescription(name: "Bar3", url: "/Bar3", requirement: .upToNextMajor(from: "1.0.0")),
        ]

        let products = [
            ProductDescription(name: "Foo", type: .library(.automatic), targets: ["Foo1"]),
        ]

        let targets = [
            try TargetDescription(name: "Foo1", dependencies: ["Foo2", "Bar1"]),
            try TargetDescription(name: "Foo2", dependencies: [.product(name: "B2", package: "Bar2")]),
            try TargetDescription(name: "Foo3", dependencies: ["Bar3"]),
        ]

        let mirrors: DependencyMirrors = [:]

        let v5ProductMapping: [String: ProductFilter] = [
            "Bar1": .specific(["Bar1", "Bar3"]),
            "Bar2": .specific(["B2", "Bar1", "Bar3"]),
            "Bar3": .specific(["Bar1", "Bar3"]),
        ]
        let v5Constraints = dependencies.map {
            PackageContainerConstraint(
                container: $0.createPackageRef(mirrors: mirrors),
                requirement: $0.requirement.toConstraintRequirement(),
                products: v5ProductMapping[$0.name]!
            )
        }
        let v5_2ProductMapping: [String: ProductFilter] = [
            "Bar1": .specific(["Bar1"]),
            "Bar2": .specific(["B2"]),
            "Bar3": .specific(["Bar3"]),
        ]
        let v5_2Constraints = dependencies.map {
            PackageContainerConstraint(
                container: $0.createPackageRef(mirrors: mirrors),
                requirement: $0.requirement.toConstraintRequirement(),
                products: v5_2ProductMapping[$0.name]!
            )
        }

        do {
            let manifest = Manifest.createManifest(
                name: "Foo",
                path: "/Foo",
                url: "/Foo",
                v: .v5,
                packageKind: .root,
                dependencies: dependencies,
                products: products,
                targets: targets
            )

            XCTAssertEqual(
                manifest
                    .dependencyConstraints(productFilter: .everything, mirrors: mirrors)
                    .sorted(by: { $0.identifier.identity < $1.identifier.identity }),
                [
                    v5Constraints[0],
                    v5Constraints[1],
                    v5Constraints[2],
                ]
            )
        }

        do {
            let manifest = Manifest.createManifest(
                name: "Foo",
                path: "/Foo",
                url: "/Foo",
                v: .v5,
                packageKind: .local,
                dependencies: dependencies,
                products: products,
                targets: targets
            )

            XCTAssertEqual(
                manifest
                    .dependencyConstraints(productFilter: .everything, mirrors: mirrors)
                    .sorted(by: { $0.identifier.identity < $1.identifier.identity }),
                [
                    v5Constraints[0],
                    v5Constraints[1],
                    v5Constraints[2],
                ]
            )
        }

        do {
            let manifest = Manifest.createManifest(
                name: "Foo",
                path: "/Foo",
                url: "/Foo",
                v: .v5_2,
                packageKind: .root,
                dependencies: dependencies,
                products: products,
                targets: targets
            )

            XCTAssertEqual(
                manifest
                    .dependencyConstraints(productFilter: .everything, mirrors: mirrors)
                    .sorted(by: { $0.identifier.identity < $1.identifier.identity }),
                [
                    v5_2Constraints[0],
                    v5_2Constraints[1],
                    v5_2Constraints[2],
                ]
            )
        }

        do {
            let manifest = Manifest.createManifest(
                name: "Foo",
                path: "/Foo",
                url: "/Foo",
                v: .v5_2,
                packageKind: .local,
                dependencies: dependencies,
                products: products,
                targets: targets
            )

            XCTAssertEqual(
                manifest
                    .dependencyConstraints(productFilter: .specific(Set(products.map { $0.name })), mirrors: mirrors)
                    .sorted(by: { $0.identifier.identity < $1.identifier.identity }),
                [
                    v5_2Constraints[0],
                    v5_2Constraints[1],
                ]
            )
        }
    }

    func testMissingBranchDiagnostics() throws {
        try testWithTemporaryDirectory { tmpDir in
            // Create a repository.
            let packageDir = tmpDir.appending(component: "SomePackage")
            try localFileSystem.createDirectory(packageDir)
            initGitRepo(packageDir)
            let packageRepo = GitRepository(path: packageDir)

            // Create a package manifest in it (it only needs the `swift-tools-version` part, because we'll supply the manifest later).
            let manifestFile = packageDir.appending(component: "Package.swift")
            try localFileSystem.writeFileContents(manifestFile, bytes: ByteString("// swift-tools-version:4.2"))

            // Commit it and tag it.
            try packageRepo.stage(file: "Package.swift")
            try packageRepo.commit(message: "Initial")
            try packageRepo.tag(name: "1.0.0")

            // Rename the `master` branch to `main`.
            try systemQuietly([Git.tool, "-C", packageDir.pathString, "branch", "-m", "main"])

            // Create a repository manager for it.
            let repoProvider = GitRepositoryProvider()
            let repositoryManager = RepositoryManager(path: packageDir, provider: repoProvider, delegate: nil, fileSystem: localFileSystem)

            // Create a container provider, configured with a mock manifest loader that will return the package manifest.
            let manifest = Manifest.createV4Manifest(
                name: packageDir.basename,
                path: packageDir.pathString,
                url: packageDir.pathString,
                packageKind: .root,
                targets: [
                    try TargetDescription(name: packageDir.basename, path: packageDir.pathString),
                ]
            )
            let containerProvider = RepositoryPackageContainerProvider(repositoryManager: repositoryManager, manifestLoader: MockManifestLoader(manifests: [.init(url: packageDir.pathString, version: nil): manifest]), verbosity: TSCUtility.verbosity)

            // Get a hold of the container for the test package.
            let packageRef = PackageReference(identity: PackageIdentity(path: packageDir), path: packageDir.pathString)
            let container = try containerProvider.getContainer(for: packageRef, skipUpdate: false) as! RepositoryPackageContainer

            // Simulate accessing a fictitious dependency on the `master` branch, and check that we get back the expected error.
            do { _ = try container.getDependencies(at: "master", productFilter: .everything) }
            catch let error as RepositoryPackageContainer.GetDependenciesError {
                // We expect to get an error message that mentions main.
                XCTAssertMatch(error.description, .and(.prefix("could not find a branch named ‘master’"), .suffix("(did you mean ‘main’?)")))
                XCTAssertMatch(error.diagnosticLocation?.description, .suffix("/SomePackage @ master"))
            }

            // Simulate accessing a fictitious dependency on some random commit that doesn't exist, and check that we get back the expected error.
            do { _ = try container.getDependencies(at: "535f4cb5b4a0872fa691473e82d7b27b9894df00", productFilter: .everything) }
            catch let error as RepositoryPackageContainer.GetDependenciesError {
                // We expect to get an error message about the specific commit.
                XCTAssertMatch(error.description, .prefix("could not find the commit 535f4cb5b4a0872fa691473e82d7b27b9894df00"))
                XCTAssertMatch(error.diagnosticLocation?.description, .suffix("/SomePackage @ 535f4cb5b4a0872fa691473e82d7b27b9894df00"))
            }
        }
    }

    func testRepositoryPackageContainerCache() throws {
        // From rdar://problem/65284674
        // RepositoryPackageContainer used to erroneously cache dependencies based only on version,
        // storing the result of the first product filter and then continually returning it for other filters too.
        // This lead to corrupt graph states.

        try testWithTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending(component: "Package")
            try localFileSystem.createDirectory(packageDirectory)
            initGitRepo(packageDirectory)
            let packageRepository = GitRepository(path: packageDirectory)

            let manifestFile = packageDirectory.appending(component: "Package.swift")
            try localFileSystem.writeFileContents(manifestFile, bytes: ByteString("// swift-tools-version:5.2"))

            try packageRepository.stage(file: "Package.swift")
            try packageRepository.commit(message: "Initialized.")
            try packageRepository.tag(name: "1.0.0")

            let repositoryProvider = GitRepositoryProvider()
            let repositoryManager = RepositoryManager(
                path: packageDirectory,
                provider: repositoryProvider,
                delegate: nil,
                fileSystem: localFileSystem
            )

            let version = Version(1, 0, 0)
            let manifest = Manifest.createManifest(
                name: packageDirectory.basename,
                path: packageDirectory.pathString,
                url: packageDirectory.pathString,
                v: .v5_2,
                packageKind: .root,
                dependencies: [
                    PackageDependencyDescription(
                        url: "Somewhere/Dependency",
                        requirement: .exact(version),
                        productFilter: .specific([])
                    )
                ],
                products: [ProductDescription(name: "Product", type: .library(.automatic), targets: ["Target"])],
                targets: [
                    try TargetDescription(
                        name: "Target",
                        dependencies: [.product(name: "DependencyProduct", package: "Dependency")]
                    ),
                ]
            )
            let containerProvider = RepositoryPackageContainerProvider(
                repositoryManager: repositoryManager,
                manifestLoader: MockManifestLoader(
                    manifests: [.init(url: packageDirectory.pathString, version: Version(1, 0, 0)): manifest]
                ),
                verbosity: TSCUtility.verbosity
            )

            let packageReference = PackageReference(identity: PackageIdentity(path: packageDirectory), path: packageDirectory.pathString)
            let container = try containerProvider.getContainer(for: packageReference, skipUpdate: false)

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
    fileprivate func getContainer(for identifier: PackageReference, skipUpdate: Bool) throws -> PackageContainer {
        try tsc_await { self.getContainer(for: identifier, skipUpdate: skipUpdate, on: .global(), completion: $0)  }
    }
}
