//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
@testable import PackageCollections
import _InternalTestSupport
import tsan_utils
import XCTest

class PackageCollectionsStorageTests: XCTestCase {
    func testHappyCase() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let path = tmpPath.appending("test.db")
            let storage = SQLitePackageCollectionsStorage(path: path)
            defer { XCTAssertNoThrow(try storage.close()) }

            let mockSources = makeMockSources()
            for source in mockSources {
                await XCTAssertAsyncThrowsError(try await storage.get(identifier: .init(from: source)), "expected error", { error in
                    XCTAssert(error is NotFoundError, "Expected NotFoundError")
                })
            }

            let mockCollections = makeMockCollections(count: 50)
            for collection in mockCollections {
                _ = try await storage.put(collection: collection)
            }

            for collection in mockCollections {
                let retVal = try await storage.get(identifier: collection.identifier)
                XCTAssertEqual(retVal.identifier, collection.identifier)
            }

            do {
                let list = try await storage.list()
                XCTAssertEqual(list.count, mockCollections.count)
            }

            do {
                let count = Int.random(in: 1 ..< mockCollections.count)
                let list = try await storage.list(identifiers: mockCollections.prefix(count).map { $0.identifier })
                XCTAssertEqual(list.count, count)
            }

            do {
                _ = try await storage.remove(identifier: mockCollections.first!.identifier)
                let list = try await storage.list()
                XCTAssertEqual(list.count, mockCollections.count - 1)
            }

            await XCTAssertAsyncThrowsError(try await storage.get(identifier: mockCollections.first!.identifier), "expected error", { error in
                XCTAssert(error is NotFoundError, "Expected NotFoundError")
            })

            guard case .path(let storagePath) = storage.location else {
                return XCTFail("invalid location \(storage.location)")
            }

            XCTAssertTrue(storage.fileSystem.exists(storagePath), "expected file to be written")
        }
    }

    func testFileDeleted() async throws {
#if os(Windows)
        try XCTSkipIf(true, "open files cannot be deleted on Windows")
#endif
        try XCTSkipIf(is_tsan_enabled())

        try await testWithTemporaryDirectory { tmpPath in
            let path = tmpPath.appending("test.db")
            let storage = SQLitePackageCollectionsStorage(path: path)
            defer { XCTAssertNoThrow(try storage.close()) }

            let mockCollections = makeMockCollections(count: 3)
            for collection in mockCollections {
                _ = try await storage.put(collection: collection)
            }

            for collection in mockCollections {
                let retVal = try await storage.get(identifier: collection.identifier)
                XCTAssertEqual(retVal.identifier, collection.identifier)
            }

            guard case .path(let storagePath) = storage.location else {
                return XCTFail("invalid location \(storage.location)")
            }

            XCTAssertTrue(storage.fileSystem.exists(storagePath), "expected file to exist at \(storagePath)")

            try storage.fileSystem.removeFileTree(storagePath)
            storage.resetCache()

            await XCTAssertAsyncThrowsError(try await storage.get(identifier: mockCollections.first!.identifier), "expected error", { error in
                XCTAssert(error is NotFoundError, "Expected NotFoundError")
            })

            _ = try await storage.put(collection: mockCollections.first!)
            let retVal = try await storage.get(identifier: mockCollections.first!.identifier)
            XCTAssertEqual(retVal.identifier, mockCollections.first!.identifier)

            XCTAssertTrue(storage.fileSystem.exists(storagePath), "expected file to exist at \(storagePath)")
        }
    }

    func testFileCorrupt() async throws {
#if os(Windows)
        try XCTSkipIf(true, "open files cannot be deleted on Windows")
#endif
        try XCTSkipIf(is_tsan_enabled())

        try await testWithTemporaryDirectory { tmpPath in
            let path = tmpPath.appending("test.db")
            let storage = SQLitePackageCollectionsStorage(path: path)
            defer { XCTAssertNoThrow(try storage.close()) }

            let mockCollections = makeMockCollections(count: 3)
            for collection in mockCollections {
                _ = try await storage.put(collection: collection)
            }

            for collection in mockCollections {
                let retVal = try await storage.get(identifier: collection.identifier)
                XCTAssertEqual(retVal.identifier, collection.identifier)
            }

            guard case .path(let storagePath) = storage.location else {
                return XCTFail("invalid location \(storage.location)")
            }

            try storage.close()

            XCTAssertTrue(storage.fileSystem.exists(storagePath), "expected file to exist at \(path)")
            try storage.fileSystem.writeFileContents(storagePath, string: "blah")

            let storage2 = SQLitePackageCollectionsStorage(path: path)
            defer { XCTAssertNoThrow(try storage2.close()) }
            await XCTAssertAsyncThrowsError(try await storage2.get(identifier: mockCollections.first!.identifier), "expected error", { error in
                XCTAssert("\(error)".contains("is not a database"), "Expected file is not a database error")
            })

            await XCTAssertAsyncThrowsError(try await storage2.put(collection: mockCollections.first!), "expected error", { error in
                XCTAssert("\(error)".contains("is not a database"), "Expected file is not a database error")
            })
        }
    }

    func testListLessThanBatch() async throws {
        var configuration = SQLitePackageCollectionsStorage.Configuration()
        configuration.batchSize = 10
        let storage = SQLitePackageCollectionsStorage(location: .memory, configuration: configuration)
        defer { XCTAssertNoThrow(try storage.close()) }

        let count = configuration.batchSize / 2
        let mockCollections = makeMockCollections(count: count)
        for collection in mockCollections {
            _ = try await storage.put(collection: collection)
        }

        let list = try await storage.list()
        XCTAssertEqual(list.count, mockCollections.count)
    }

    func testListNonBatching() async throws {
        var configuration = SQLitePackageCollectionsStorage.Configuration()
        configuration.batchSize = 10
        let storage = SQLitePackageCollectionsStorage(location: .memory, configuration: configuration)
        defer { XCTAssertNoThrow(try storage.close()) }

        let count = Int(Double(configuration.batchSize) * 2.5)
        let mockCollections = makeMockCollections(count: count)
        for collection in mockCollections {
            _ = try await storage.put(collection: collection)
        }

        let list = try await storage.list()
        XCTAssertEqual(list.count, mockCollections.count)
    }

    func testListBatching() async throws {
        var configuration = SQLitePackageCollectionsStorage.Configuration()
        configuration.batchSize = 10
        let storage = SQLitePackageCollectionsStorage(location: .memory, configuration: configuration)
        defer { XCTAssertNoThrow(try storage.close()) }

        let count = Int(Double(configuration.batchSize) * 2.5)
        let mockCollections = makeMockCollections(count: count)
        for collection in mockCollections {
            _ = try await storage.put(collection: collection)
        }

        let list = try await storage.list(identifiers: mockCollections.map { $0.identifier })
        XCTAssertEqual(list.count, mockCollections.count)
    }

    func testPutUpdates() async throws {
        let storage = SQLitePackageCollectionsStorage(location: .memory)
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections(count: 3)
        for collection in mockCollections {
            _ = try await storage.put(collection: collection)
        }

        let list = try await storage.list(identifiers: mockCollections.map { $0.identifier })
        XCTAssertEqual(list.count, mockCollections.count)

        _ = try await storage.put(collection: mockCollections.last!)
        XCTAssertEqual(list.count, mockCollections.count)
    }

    func testPopulateTargetTrie() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let path = tmpPath.appending("test.db")
            let storage = SQLitePackageCollectionsStorage(path: path)
            defer { XCTAssertNoThrow(try storage.close()) }

            let mockCollections = makeMockCollections(count: 3)
            for collection in mockCollections {
                _ = try await storage.put(collection: collection)
            }

            let version = mockCollections.last!.packages.last!.versions.last!
            let targetName = version.defaultManifest!.targets.last!.name

            do {
                let searchResult = try await storage.searchTargets(query: targetName, type: .exactMatch)
                XCTAssert(searchResult.items.count > 0, "should get results")
            }

            // Create another instance, which should read existing data and populate target trie with it.
            // Since we are not calling `storage2.put`, there is no other way for target trie to get populated.
            let storage2 = SQLitePackageCollectionsStorage(path: path)
            defer { XCTAssertNoThrow(try storage2.close()) }

            // populateTargetTrie is called in `.init`; call it again explicitly so we know when it's finished
            do {
                try await storage2.populateTargetTrie()

                let searchResult = try await storage2.searchTargets(query: targetName, type: .exactMatch)
                XCTAssert(searchResult.items.count > 0, "should get results")
            } catch {
                // It's possible that some platforms don't have support FTS
                XCTAssertEqual(false, storage2.useSearchIndices.get(), "populateTargetTrie should fail only if FTS is not available")
            }
        }
    }
}

extension SQLitePackageCollectionsStorage {
    convenience init(location: SQLite.Location? = nil, configuration: Configuration = .init()) {
        self.init(location: location, configuration: configuration, observabilityScope: ObservabilitySystem.NOOP)
    }
    convenience init(path: AbsolutePath) {
        self.init(location: .path(path), observabilityScope: ObservabilitySystem.NOOP)
    }
}
