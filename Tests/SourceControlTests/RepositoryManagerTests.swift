//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@testable import Basics
import PackageModel
import _InternalTestSupport
@testable import SourceControl
import XCTest

import class TSCBasic.InMemoryFileSystem

class RepositoryManagerTests: XCTestCase {
    func testBasics() async throws {
        let fs = localFileSystem
        let observability = ObservabilitySystem.makeForTesting()

        try await testWithTemporaryDirectory { path in
            let provider = DummyRepositoryProvider(fileSystem: fs)
            let delegate = DummyRepositoryManagerDelegate()

            let manager = RepositoryManager(
                fileSystem: fs,
                path: path,
                provider: provider,
                delegate: delegate
            )

            let dummyRepo = RepositorySpecifier(path: "/dummy")
            let badDummyRepo = RepositorySpecifier(path: "/badDummy")
            var prevHandle: RepositoryManager.RepositoryHandle?

            // Check that we can "fetch" a repository.

            do {
                delegate.prepare(fetchExpected: true, updateExpected: false)
                let handle = try await manager.lookup(repository: dummyRepo, observabilityScope: observability.topScope)
                XCTAssertNoDiagnostics(observability.diagnostics)

                prevHandle = handle
                XCTAssertEqual(provider.numFetches, 0)

                // Open the repository.
                let repository = try! handle.open()
                XCTAssertEqual(try! repository.getTags(), ["1.0.0"])

                // Create a checkout of the repository.
                let checkoutPath = path.appending("checkout")
                _ = try! handle.createWorkingCopy(at: checkoutPath, editable: false)

                XCTAssertDirectoryExists(checkoutPath)
                XCTAssertFileExists(checkoutPath.appending("README.txt"))

                try delegate.wait(timeout: .now() + 2)
                XCTAssertEqual(delegate.willFetch.map { $0.repository }, [dummyRepo])
                XCTAssertEqual(delegate.didFetch.map { $0.repository }, [dummyRepo])
            }

            // Get a bad repository.

            do {
                delegate.prepare(fetchExpected: true, updateExpected: false)
                await XCTAssertAsyncThrowsError(try await manager.lookup(repository: badDummyRepo, observabilityScope: observability.topScope)) { error in
                    XCTAssertEqual(error as? DummyError, DummyError.invalidRepository)
                }

                XCTAssertNotNil(prevHandle)

                try delegate.wait(timeout: .now() + 2)
                XCTAssertEqual(delegate.willFetch.map { $0.repository }, [dummyRepo, badDummyRepo])
                XCTAssertEqual(delegate.didFetch.map { $0.repository }, [dummyRepo, badDummyRepo])
                // We shouldn't have made any update call yet.
                XCTAssert(delegate.willUpdate.isEmpty)
                XCTAssert(delegate.didUpdate.isEmpty)
            }

            do {
                delegate.prepare(fetchExpected: false, updateExpected: true)
                let handle = try await manager.lookup(repository: dummyRepo, observabilityScope: observability.topScope)
                XCTAssertNoDiagnostics(observability.diagnostics)
                XCTAssertEqual(handle.repository, dummyRepo)
                XCTAssertEqual(handle.repository, prevHandle?.repository)

                // We should always get back the same handle once fetched.
                // Since we looked up this repo again, we should have made a fetch call.
                try delegate.wait(timeout: .now() + 2)
                XCTAssertEqual(provider.numFetches, 1)
                XCTAssertEqual(delegate.willUpdate, [dummyRepo])
                XCTAssertEqual(delegate.didUpdate, [dummyRepo])
            }

            // Remove the repo.
            do {
                try manager.remove(repository: dummyRepo)

                // Check removing the repo updates the persistent file.
                /*do {
                    let checkoutsStateFile = path.appending("checkouts-state.json")
                    let jsonData = try JSON(bytes: localFileSystem.readFileContents(checkoutsStateFile))
                    XCTAssertEqual(jsonData.dictionary?["object"]?.dictionary?["repositories"]?.dictionary?[dummyRepo.location.description], nil)
                }*/

                // We should get a new handle now because we deleted the existing repository.
                delegate.prepare(fetchExpected: true, updateExpected: false)
                let handle = try await manager.lookup(repository: dummyRepo, observabilityScope: observability.topScope)
                XCTAssertNoDiagnostics(observability.diagnostics)
                XCTAssertEqual(handle.repository, dummyRepo)

                // We should have tried fetching these two.
                try delegate.wait(timeout: .now() + 2)
                XCTAssertEqual(delegate.willFetch.map { $0.repository }, [dummyRepo, badDummyRepo, dummyRepo])
                XCTAssertEqual(delegate.didFetch.map { $0.repository }, [dummyRepo, badDummyRepo, dummyRepo])
                XCTAssertEqual(delegate.willUpdate, [dummyRepo])
                XCTAssertEqual(delegate.didUpdate, [dummyRepo])
            }
        }
    }

    func testCache() async throws {
        let fs = localFileSystem
        let observability = ObservabilitySystem.makeForTesting()

        try await fixture(name: "DependencyResolution/External/Simple") { (fixturePath: AbsolutePath) in
            let cachePath = fixturePath.appending("cache")
            let repositoriesPath = fixturePath.appending("repositories")
            let repo = RepositorySpecifier(path: fixturePath.appending("Foo"))

            let provider = GitRepositoryProvider()
            let delegate = DummyRepositoryManagerDelegate()

            let manager = RepositoryManager(
                fileSystem: fs,
                path: repositoriesPath,
                provider: provider,
                cachePath: cachePath,
                cacheLocalPackages: true,
                delegate: delegate
            )

            // fetch packages and populate cache
            delegate.prepare(fetchExpected: true, updateExpected: false)
            _ = try await manager.lookup(repository: repo, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            try XCTAssertDirectoryExists(cachePath.appending(repo.storagePath()))
            try XCTAssertDirectoryExists(repositoriesPath.appending(repo.storagePath()))
            try delegate.wait(timeout: .now() + 2)
            XCTAssertEqual(delegate.willFetch[0].details,
                           RepositoryManager.FetchDetails(fromCache: false, updatedCache: false))
            XCTAssertEqual(try delegate.didFetch[0].result.get(),
                           RepositoryManager.FetchDetails(fromCache: false, updatedCache: true))

            // removing the repositories path to force re-fetch
            try fs.removeFileTree(repositoriesPath)

            // fetch packages from the cache
            delegate.prepare(fetchExpected: true, updateExpected: false)
            _ = try await manager.lookup(repository: repo, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            try XCTAssertDirectoryExists(repositoriesPath.appending(repo.storagePath()))
            try delegate.wait(timeout: .now() + 2)
            XCTAssertEqual(delegate.willFetch[1].details,
                           RepositoryManager.FetchDetails(fromCache: true, updatedCache: false))
            XCTAssertEqual(try delegate.didFetch[1].result.get(),
                           RepositoryManager.FetchDetails(fromCache: true, updatedCache: true))

            //  reset the state on disk
            try fs.removeFileTree(cachePath)
            try fs.removeFileTree(repositoriesPath)

            // fetch packages and populate cache
            delegate.prepare(fetchExpected: true, updateExpected: false)
            _ = try await manager.lookup(repository: repo, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            try XCTAssertDirectoryExists(cachePath.appending(repo.storagePath()))
            try XCTAssertDirectoryExists(repositoriesPath.appending(repo.storagePath()))
            try delegate.wait(timeout: .now() + 2)
            XCTAssertEqual(delegate.willFetch[2].details,
                           RepositoryManager.FetchDetails(fromCache: false, updatedCache: false))
            XCTAssertEqual(try delegate.didFetch[2].result.get(),
                           RepositoryManager.FetchDetails(fromCache: false, updatedCache: true))

            // update packages from the cache
            delegate.prepare(fetchExpected: false, updateExpected: true)
            _ = try await manager.lookup(repository: repo, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            try delegate.wait(timeout: .now() + 2)
            try XCTAssertEqual(delegate.willUpdate[0].storagePath(), repo.storagePath())
            try XCTAssertEqual(delegate.didUpdate[0].storagePath(), repo.storagePath())
        }
    }

    func testReset() async throws {
        let fs = localFileSystem
        let observability = ObservabilitySystem.makeForTesting()

        try await testWithTemporaryDirectory { path in
            let repos = path.appending("repo")
            let provider = DummyRepositoryProvider(fileSystem: fs)
            let delegate = DummyRepositoryManagerDelegate()

            try fs.createDirectory(repos, recursive: true)

            let manager = RepositoryManager(
                fileSystem: fs,
                path: repos,
                provider: provider,
                delegate: delegate
            )
            let dummyRepo = RepositorySpecifier(path: "/dummy")

            delegate.prepare(fetchExpected: true, updateExpected: false)
            _ = try await manager.lookup(repository: dummyRepo, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            delegate.prepare(fetchExpected: false, updateExpected: true)
            _ = try await manager.lookup(repository: dummyRepo, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            try delegate.wait(timeout: .now() + 2)
            XCTAssertEqual(delegate.willFetch.count, 1)
            XCTAssertEqual(delegate.didFetch.count, 1)

            manager.reset(observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            
            XCTAssertTrue(!fs.isDirectory(repos))
            try fs.createDirectory(repos, recursive: true)

            delegate.prepare(fetchExpected: true, updateExpected: false)
            _ = try await manager.lookup(repository: dummyRepo, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            try delegate.wait(timeout: .now() + 2)
            XCTAssertEqual(delegate.willFetch.count, 2)
            XCTAssertEqual(delegate.didFetch.count, 2)
        }
    }

    /// Check that the manager is persistent.
    func testPersistence() async throws {
        let fs = localFileSystem
        let observability = ObservabilitySystem.makeForTesting()

        try await testWithTemporaryDirectory { path in
            let provider = DummyRepositoryProvider(fileSystem: fs)
            let dummyRepo = RepositorySpecifier(path: "/dummy")

            // Do the initial fetch.
            do {
                let delegate = DummyRepositoryManagerDelegate()
                let manager = RepositoryManager(
                    fileSystem: fs,
                    path: path,
                    provider: provider,
                    delegate: delegate
                )

                delegate.prepare(fetchExpected: true, updateExpected: false)
                _ = try await manager.lookup(repository: dummyRepo, observabilityScope: observability.topScope)
                XCTAssertNoDiagnostics(observability.diagnostics)
                try delegate.wait(timeout: .now() + 2)
                XCTAssertEqual(delegate.willFetch.map { $0.repository }, [dummyRepo])
                XCTAssertEqual(delegate.didFetch.map { $0.repository }, [dummyRepo])
            }
            // We should have performed one fetch.
            XCTAssertEqual(provider.numClones, 1)
            XCTAssertEqual(provider.numFetches, 0)

            // Create a new manager, and fetch.
            do {
                let delegate = DummyRepositoryManagerDelegate()
                let manager = RepositoryManager(
                    fileSystem: fs,
                    path: path,
                    provider: provider,
                    delegate: delegate
                )

                delegate.prepare(fetchExpected: true, updateExpected: false)
                _ = try await manager.lookup(repository: dummyRepo, observabilityScope: observability.topScope)
                XCTAssertNoDiagnostics(observability.diagnostics)
                // This time fetch shouldn't be called.
                try delegate.wait(timeout: .now() + 2)
                XCTAssertEqual(delegate.willFetch.map { $0.repository }, [])
            }
            // We shouldn't have done a new fetch.
            XCTAssertEqual(provider.numClones, 1)
            XCTAssertEqual(provider.numFetches, 1)

            // Manually destroy the manager state, and check it still works.
            do {
                let delegate = DummyRepositoryManagerDelegate()
                var manager = RepositoryManager(
                    fileSystem: fs,
                    path: path,
                    provider: provider,
                    delegate: delegate
                )
                try! fs.removeFileTree(path.appending(dummyRepo.storagePath()))
                manager = RepositoryManager(
                    fileSystem: fs,
                    path: path,
                    provider: provider,
                    delegate: delegate
                )
                let dummyRepo = RepositorySpecifier(path: "/dummy")

                delegate.prepare(fetchExpected: true, updateExpected: false)
                _ = try await manager.lookup(repository: dummyRepo, observabilityScope: observability.topScope)
                XCTAssertNoDiagnostics(observability.diagnostics)
                try delegate.wait(timeout: .now() + 2)
                XCTAssertEqual(delegate.willFetch.map { $0.repository }, [dummyRepo])
                XCTAssertEqual(delegate.didFetch.map { $0.repository }, [dummyRepo])
            }
            // We should have re-fetched.
            XCTAssertEqual(provider.numClones, 2)
            XCTAssertEqual(provider.numFetches, 1)
        }
    }

    func testCanonicalLocation() throws {
        let variants: [RepositorySpecifier] = [
            .init(url: "https://scm.com/org/foo"),
            .init(url: "https://scm.com/org/foo.git"),
        ]

        for variant in variants {
            XCTAssertEqual(try variant.storagePath(), try variants[0].storagePath())
        }
    }

    func testConcurrency() async throws {
        let fs = localFileSystem
        let observability = ObservabilitySystem.makeForTesting()

        try await testWithTemporaryDirectory { path in
            let provider = DummyRepositoryProvider(fileSystem: fs)
            let delegate = DummyRepositoryManagerDelegate()
            let manager = RepositoryManager(
                fileSystem: fs,
                path: path,
                provider: provider,
                delegate: delegate
            )
            let dummyRepo = RepositorySpecifier(path: "/dummy")

            let results = ThreadSafeKeyValueStore<Int, RepositoryManager.RepositoryHandle>()
            let concurrency = 10000
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0 ..< concurrency {
                    group.addTask {
                        delegate.prepare(fetchExpected: index == 0, updateExpected: index > 0)
                        results[index] = try await manager.lookup(
                            package: .init(url: SourceControlURL(dummyRepo.url)),
                            repository: dummyRepo,
                            updateStrategy: .always,
                            observabilityScope: observability.topScope,
                            delegateQueue: .sharedConcurrent,
                            callbackQueue: .sharedConcurrent
                        )
                    }
                }
                try await group.waitForAll()
            }

            XCTAssertNoDiagnostics(observability.diagnostics)

            try delegate.wait(timeout: .now() + 2)
            XCTAssertEqual(delegate.willFetch.count, 1)
            XCTAssertEqual(delegate.didFetch.count, 1)
            XCTAssertEqual(delegate.willUpdate.count, concurrency - 1)
            XCTAssertEqual(delegate.didUpdate.count, concurrency - 1)

            XCTAssertEqual(results.count, concurrency)
            for index in 0 ..< concurrency {
                XCTAssertEqual(results[index]?.repository, dummyRepo)
            }
        }
    }

    func testSkipUpdate() async throws {
        let fs = localFileSystem
        let observability = ObservabilitySystem.makeForTesting()

        try await testWithTemporaryDirectory { path in
            let repos = path.appending("repo")
            let provider = DummyRepositoryProvider(fileSystem: fs)
            let delegate = DummyRepositoryManagerDelegate()

            try fs.createDirectory(repos, recursive: true)

            let manager = RepositoryManager(
                fileSystem: fs,
                path: repos,
                provider: provider,
                delegate: delegate
            )
            let dummyRepo = RepositorySpecifier(path: "/dummy")

            delegate.prepare(fetchExpected: true, updateExpected: false)
            _ = try await manager.lookup(repository: dummyRepo, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            try delegate.wait(timeout: .now() + 2)
            XCTAssertEqual(delegate.willFetch.count, 1)
            XCTAssertEqual(delegate.didFetch.count, 1)
            XCTAssertEqual(delegate.willUpdate.count, 0)
            XCTAssertEqual(delegate.didUpdate.count, 0)

            delegate.prepare(fetchExpected: false, updateExpected: true)
            _ = try await manager.lookup(repository: dummyRepo, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            delegate.prepare(fetchExpected: false, updateExpected: true)
            _ = try await manager.lookup(repository: dummyRepo, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            try delegate.wait(timeout: .now() + 2)
            XCTAssertEqual(delegate.willFetch.count, 1)
            XCTAssertEqual(delegate.didFetch.count, 1)
            XCTAssertEqual(delegate.willUpdate.count, 2)
            XCTAssertEqual(delegate.didUpdate.count, 2)

            delegate.prepare(fetchExpected: false, updateExpected: false)
            _ = try await manager.lookup(repository: dummyRepo, updateStrategy: .never, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            try delegate.wait(timeout: .now() + 2)
            XCTAssertEqual(delegate.willFetch.count, 1)
            XCTAssertEqual(delegate.didFetch.count, 1)
            XCTAssertEqual(delegate.willUpdate.count, 2)
            XCTAssertEqual(delegate.didUpdate.count, 2)
        }
    }

    func testCancel() throws {
        let observability = ObservabilitySystem.makeForTesting()
        let cancellator = Cancellator(observabilityScope: observability.topScope)

        let total = 10
        let provider = MockRepositoryProvider(total: total)
        let manager = RepositoryManager(
            fileSystem: InMemoryFileSystem(),
            path: .root,
            provider: provider,
            maxConcurrentOperations: total
        )

        cancellator.register(name: "repository manager", handler: manager)

        //let startGroup = DispatchGroup()
        let finishGroup = DispatchGroup()
        let results = ThreadSafeKeyValueStore<RepositorySpecifier, Result<RepositoryManager.RepositoryHandle, Error>>()
        for index in 0 ..< total {
            let repository = RepositorySpecifier(path: try .init(validating: "/repo/\(index)"))
            provider.startGroup.enter()
            finishGroup.enter()
            manager.lookup(
                package: .init(urlString: repository.url),
                repository: repository,
                updateStrategy: .never,
                observabilityScope: observability.topScope,
                delegateQueue: .sharedConcurrent,
                callbackQueue: .sharedConcurrent
            ) { result in
                defer { finishGroup.leave() }
                results[repository] = result
            }
        }

        XCTAssertEqual(.success, provider.startGroup.wait(timeout: .now() + 5), "timeout starting tasks")

        let cancelled = cancellator._cancel(deadline: .now() + .seconds(1))
        XCTAssertEqual(cancelled, 1, "expected to be terminated")
        XCTAssertNoDiagnostics(observability.diagnostics)
        // this releases the fetch threads that are waiting to test if the call was cancelled
        provider.terminatedGroup.leave()

        XCTAssertEqual(.success, finishGroup.wait(timeout: .now() + 5), "timeout finishing tasks")

        XCTAssertEqual(results.count, total, "expected \(total) results")
        for (repository, result) in results.get() {
            switch (Int(repository.basename)! < total / 2, result) {
            case (true, .success):
                break // as expected!
            case (true, .failure(let error)):
                XCTFail("expected success, but failed with \(type(of: error)) '\(error)'")
            case (false, .success):
                XCTFail("expected operation to be cancelled")
            case (false, .failure(let error)):
                XCTAssert(error is CancellationError, "expected error to be CancellationError, but was \(type(of: error)) '\(error)'")
            }
        }

        // wait for outstanding threads that would be cancelled and completion handlers thrown away
        XCTAssertEqual(.success, provider.outstandingGroup.wait(timeout: .now() + .seconds(5)), "timeout waiting for outstanding tasks")

        // the provider called in a thread managed by the RepositoryManager
        // the use of blocking semaphore is intentional
        class MockRepositoryProvider: RepositoryProvider {
            let total: Int
            // this DispatchGroup is used to wait for the requests to start before calling cancel
            let startGroup = DispatchGroup()
            // this DispatchGroup is used to park the delayed threads that would be cancelled
            let terminatedGroup = DispatchGroup()
            // this DispatchGroup is used to monitor the outstanding threads that would be cancelled and completion handlers thrown away
            let outstandingGroup = DispatchGroup()

            init(total: Int) {
                self.total = total
                self.terminatedGroup.enter()
            }

            func fetch(repository: RepositorySpecifier, to path: AbsolutePath, progressHandler: ((FetchProgress) -> Void)?) throws {
                print("fetching \(repository)")
                // startGroup may not be 100% accurate given the blocking nature of the provider so giving it a bit of a buffer
                DispatchQueue.sharedConcurrent.asyncAfter(deadline: .now() + .milliseconds(100)) {
                    self.startGroup.leave()
                }
                if Int(repository.basename)! >= total / 2 {
                    self.outstandingGroup.enter()
                    defer { self.outstandingGroup.leave() }
                    print("\(repository) waiting to be cancelled")
                    XCTAssertEqual(.success, self.terminatedGroup.wait(timeout: .now() + 5), "timeout waiting on terminated signal")
                    throw StringError("\(repository) should be cancelled")
                }
                print("\(repository) okay")
            }

            func repositoryExists(at path: AbsolutePath) throws -> Bool {
                return false
            }

            func open(repository: RepositorySpecifier, at path: AbsolutePath) throws -> Repository {
                fatalError("should not be called")
            }

            func createWorkingCopy(repository: RepositorySpecifier, sourcePath: AbsolutePath, at destinationPath: AbsolutePath, editable: Bool) throws -> WorkingCheckout {
                fatalError("should not be called")
            }

            func workingCopyExists(at path: AbsolutePath) throws -> Bool {
                fatalError("should not be called")
            }

            func openWorkingCopy(at path: AbsolutePath) throws -> WorkingCheckout {
                fatalError("should not be called")
            }

            func copy(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
                fatalError("should not be called")
            }

            func isValidDirectory(_ directory: AbsolutePath) throws -> Bool {
                fatalError("should not be called")
            }

            public func isValidDirectory(_ directory: AbsolutePath, for repository: RepositorySpecifier) throws -> Bool {
                fatalError("should not be called")
            }

            func cancel(deadline: DispatchTime) throws {
                print("cancel")
            }
        }
    }

    func testInvalidRepositoryOnDisk() async throws {
        let fileSystem = localFileSystem
        let observability = ObservabilitySystem.makeForTesting()

        try await testWithTemporaryDirectory { path in
            let repositoriesDirectory = path.appending("repositories")
            try fileSystem.createDirectory(repositoriesDirectory, recursive: true)

            let testRepository = RepositorySpecifier(url: .init("test-\(UUID().uuidString)"))
            let provider = MockRepositoryProvider(repository: testRepository)

            let manager = RepositoryManager(
                fileSystem: fileSystem,
                path: repositoriesDirectory,
                provider: provider,
                delegate: nil
            )

            _ = try await manager.lookup(repository: testRepository, observabilityScope: observability.topScope)
            testDiagnostics(observability.diagnostics) { result in
                result.check(
                    diagnostic: .contains("is not valid git repository for '\(testRepository)', will fetch again"),
                    severity: .warning
                )
            }
        }

        class MockRepositoryProvider: RepositoryProvider {
            let repository: RepositorySpecifier
            var fetch: Int = 0

            init(repository: RepositorySpecifier) {
                self.repository = repository
            }

            func fetch(repository: RepositorySpecifier, to path: AbsolutePath, progressHandler: ((FetchProgress) -> Void)?) throws {
                assert(repository == self.repository)
                self.fetch += 1
            }

            func repositoryExists(at path: AbsolutePath) throws -> Bool {
                // the directory exists
                return true
            }

            func open(repository: RepositorySpecifier, at path: AbsolutePath) throws -> Repository {
                return MockRepository()
            }

            func createWorkingCopy(repository: RepositorySpecifier, sourcePath: AbsolutePath, at destinationPath: AbsolutePath, editable: Bool) throws -> WorkingCheckout {
                fatalError("should not be called")
            }

            func workingCopyExists(at path: AbsolutePath) throws -> Bool {
                fatalError("should not be called")
            }

            func openWorkingCopy(at path: AbsolutePath) throws -> WorkingCheckout {
                fatalError("should not be called")
            }

            func copy(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
                fatalError("should not be called")
            }

            func isValidDirectory(_ directory: AbsolutePath) throws -> Bool {
                fatalError("should not be called")
            }

            public func isValidDirectory(_ directory: AbsolutePath, for repository: RepositorySpecifier) throws -> Bool {
                assert(repository == self.repository)
                // the directory is not valid
                return false
            }

            func cancel(deadline: DispatchTime) throws {
                fatalError("should not be called")
            }
        }

        class MockRepository: Repository {
            func getTags() throws -> [String] {
                fatalError("unexpected API call")
            }

            func resolveRevision(tag: String) throws -> Revision {
                fatalError("unexpected API call")
            }

            func resolveRevision(identifier: String) throws -> Revision {
                fatalError("unexpected API call")
            }

            func exists(revision: Revision) -> Bool {
                fatalError("unexpected API call")
            }

            func isValidDirectory(_ directory: AbsolutePath) throws -> Bool {
                fatalError("unexpected API call")
            }

            public func isValidDirectory(_ directory: AbsolutePath, for repository: RepositorySpecifier) throws -> Bool {
                fatalError("unexpected API call")
            }

            func fetch() throws {
                // noop
            }

            func openFileView(revision: Revision) throws -> FileSystem {
                fatalError("unexpected API call")
            }

            public func openFileView(tag: String) throws -> FileSystem {
                fatalError("unexpected API call")
            }
        }
    }
}

extension RepositoryManager {
    public convenience init(
        fileSystem: FileSystem,
        path: AbsolutePath,
        provider: RepositoryProvider,
        cachePath: AbsolutePath? =  .none,
        cacheLocalPackages: Bool = false,
        maxConcurrentOperations: Int? = .none,
        delegate: RepositoryManagerDelegate? = .none
    ) {
        self.init(
            fileSystem: fileSystem,
            path: path,
            provider: provider,
            cachePath: cachePath,
            cacheLocalPackages: cacheLocalPackages,
            maxConcurrentOperations: maxConcurrentOperations,
            initializationWarningHandler: { _ in },
            delegate: delegate
        )
    }

    fileprivate func lookup(
        repository: RepositorySpecifier,
        updateStrategy: RepositoryUpdateStrategy = .always,
        observabilityScope: ObservabilityScope
    ) async throws -> RepositoryHandle {
        return try await safe_async {
            self.lookup(
                package: .init(url: SourceControlURL(repository.url)),
                repository: repository,
                updateStrategy: updateStrategy,
                observabilityScope: observabilityScope,
                delegateQueue: .sharedConcurrent,
                callbackQueue: .sharedConcurrent,
                completion: $0
            )
        }
    }
}

private enum DummyError: Swift.Error {
    case invalidRepository
}

private class DummyRepositoryProvider: RepositoryProvider {
    private let fileSystem: FileSystem

    private let lock = NSLock()
    private var _numClones = 0
    private var _numFetches = 0

    init(fileSystem: FileSystem) {
        self.fileSystem = fileSystem
    }

    func fetch(repository: RepositorySpecifier, to path: AbsolutePath, progressHandler: FetchProgress.Handler? = nil) throws {
        assert(!self.fileSystem.exists(path))
        try self.fileSystem.createDirectory(path, recursive: true)
        try self.fileSystem.writeFileContents(path.appending("readme.md"), string: repository.location.description)

        self.lock.withLock {
            self._numClones += 1
        }

        // We only support one dummy URL.
        let basename = (repository.url as NSString).lastPathComponent
        if basename != "dummy" {
            throw DummyError.invalidRepository
        }
    }

    public func repositoryExists(at path: AbsolutePath) throws -> Bool {
        return self.fileSystem.isDirectory(path)
    }

    func copy(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
        try self.fileSystem.copy(from: sourcePath, to: destinationPath)

        self.lock.withLock {
            self._numClones += 1
        }

        // We only support one dummy URL.
        let basename = sourcePath.basename
        if basename != "dummy" {
            throw DummyError.invalidRepository
        }
    }

    func open(repository: RepositorySpecifier, at path: AbsolutePath) -> Repository {
        return DummyRepository(provider: self)
    }

    func createWorkingCopy(repository: RepositorySpecifier, sourcePath: AbsolutePath, at destinationPath: AbsolutePath, editable: Bool) throws -> WorkingCheckout  {
        try self.fileSystem.createDirectory(destinationPath)
        try self.fileSystem.writeFileContents(destinationPath.appending("README.txt"), bytes: "Hi")
        return try self.openWorkingCopy(at: destinationPath)
    }

    func workingCopyExists(at path: AbsolutePath) throws -> Bool {
        return false
    }

    func openWorkingCopy(at path: AbsolutePath) throws -> WorkingCheckout {
        return DummyWorkingCheckout(at: path)
    }

    func isValidDirectory(_ directory: AbsolutePath) throws -> Bool {
        return true
    }

    func isValidDirectory(_ directory: AbsolutePath, for repository: RepositorySpecifier) throws -> Bool {
        return true
    }

    func cancel(deadline: DispatchTime) throws {
        // noop
    }

    func increaseFetchCount() {
        self.lock.withLock {
            self._numFetches += 1
        }
    }

    var numClones: Int {
        self.lock.withLock {
            self._numClones
        }
    }

    var numFetches: Int {
        self.lock.withLock {
            self._numFetches
        }
    }

    struct DummyWorkingCheckout: WorkingCheckout {
        let path : AbsolutePath

        init(at path: AbsolutePath) {
            self.path = path
        }

        func getTags() throws -> [String] {
            fatalError("not implemented")
        }

        func getCurrentRevision() throws -> Revision {
            fatalError("not implemented")
        }

        func fetch() throws {
            fatalError("not implemented")
        }

        func hasUnpushedCommits() throws -> Bool {
            fatalError("not implemented")
        }

        func hasUncommittedChanges() -> Bool {
            fatalError("not implemented")
        }

        func checkout(tag: String) throws {
            fatalError("not implemented")
        }

        func checkout(revision: Revision) throws {
            fatalError("not implemented")
        }

        func exists(revision: Revision) -> Bool {
            fatalError("not implemented")
        }

        func checkout(newBranch: String) throws {
            fatalError("not implemented")
        }

        func isAlternateObjectStoreValid(expected: AbsolutePath) -> Bool {
            fatalError("not implemented")
        }

        func areIgnored(_ paths: [AbsolutePath]) throws -> [Bool] {
            fatalError("not implemented")
        }
    }
}

fileprivate class DummyRepositoryManagerDelegate: RepositoryManager.Delegate {
    private var _willFetch = ThreadSafeArrayStore<(repository: RepositorySpecifier, details: RepositoryManager.FetchDetails)>()
    private var _didFetch = ThreadSafeArrayStore<(repository: RepositorySpecifier, result: Result<RepositoryManager.FetchDetails, Error>)>()
    private var _willUpdate = ThreadSafeArrayStore<RepositorySpecifier>()
    private var _didUpdate = ThreadSafeArrayStore<RepositorySpecifier>()

    private var group = DispatchGroup()

    public func prepare(fetchExpected: Bool, updateExpected: Bool) {
        if fetchExpected {
            self.group.enter() // will fetch
            self.group.enter() // did fetch
        }
        if updateExpected {
            self.group.enter() // will update
            self.group.enter() // did v
        }
    }

    public func reset() {
        self.group = DispatchGroup()
        self._willFetch = .init()
        self._didFetch = .init()
        self._willUpdate = .init()
        self._didUpdate = .init()
    }

    public func wait(timeout: DispatchTime) throws {
        switch self.group.wait(timeout: timeout) {
        case .success:
            return
        case .timedOut:
            throw StringError("timeout")
        }
    }

    var willFetch: [(repository: RepositorySpecifier, details: RepositoryManager.FetchDetails)] {
        return self._willFetch.get()
    }

    var didFetch: [(repository: RepositorySpecifier, result: Result<RepositoryManager.FetchDetails, Error>)] {
        return self._didFetch.get()
    }

    var willUpdate: [RepositorySpecifier] {
        return self._willUpdate.get()
    }

    var didUpdate: [RepositorySpecifier] {
        return self._didUpdate.get()
    }

    func willFetch(package: PackageIdentity, repository: RepositorySpecifier, details: RepositoryManager.FetchDetails) {
        self._willFetch.append((repository: repository, details: details))
        self.group.leave()
    }

    func fetching(package: PackageIdentity, repository: RepositorySpecifier, objectsFetched: Int, totalObjectsToFetch: Int) {
    }

    func didFetch(package: PackageIdentity, repository: RepositorySpecifier, result: Result<RepositoryManager.FetchDetails, Error>, duration: DispatchTimeInterval) {
        self._didFetch.append((repository: repository, result: result))
        self.group.leave()
    }

    func willUpdate(package: PackageIdentity, repository: RepositorySpecifier) {
        self._willUpdate.append(repository)
        self.group.leave()
    }

    func didUpdate(package: PackageIdentity, repository: RepositorySpecifier, duration: DispatchTimeInterval) {
        self._didUpdate.append(repository)
        self.group.leave()
    }
}

fileprivate class DummyRepository: Repository {
    unowned let provider: DummyRepositoryProvider

    init(provider: DummyRepositoryProvider) {
        self.provider = provider
    }

    func getTags() throws -> [String] {
        ["1.0.0"]
    }

    func resolveRevision(tag: String) throws -> Revision {
        fatalError("unexpected API call")
    }

    func resolveRevision(identifier: String) throws -> Revision {
        fatalError("unexpected API call")
    }

    func exists(revision: Revision) -> Bool {
        fatalError("unexpected API call")
    }

    func isValidDirectory(_ directory: AbsolutePath) throws -> Bool {
        fatalError("unexpected API call")
    }

    public func isValidDirectory(_ directory: AbsolutePath, for repository: RepositorySpecifier) throws -> Bool {
        fatalError("unexpected API call")
    }

    func fetch() throws {
        self.provider.increaseFetchCount()
    }

    func openFileView(revision: Revision) throws -> FileSystem {
        fatalError("unexpected API call")
    }

    public func openFileView(tag: String) throws -> FileSystem {
        fatalError("unexpected API call")
    }
}
