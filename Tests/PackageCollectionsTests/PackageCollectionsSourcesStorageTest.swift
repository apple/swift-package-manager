//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
@testable import PackageCollections
import _InternalTestSupport
import XCTest

import class TSCBasic.InMemoryFileSystem

final class PackageCollectionsSourcesStorageTest: XCTestCase {
    func testHappyCase() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let storage = FilePackageCollectionsSourcesStorage(fileSystem: mockFileSystem)

        try await assertHappyCase(storage: storage)

        let buffer = try mockFileSystem.readFileContents(storage.path)
        XCTAssertNotEqual(buffer.count, 0, "expected file to be written")
        print(buffer)
    }

    func testRealFile() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let fileSystem = localFileSystem
            let path = tmpPath.appending("test.json")
            let storage = FilePackageCollectionsSourcesStorage(fileSystem: fileSystem, path: path)

            try await assertHappyCase(storage: storage)

            let buffer = try fileSystem.readFileContents(storage.path)
            XCTAssertNotEqual(buffer.count, 0, "expected file to be written")
            print(buffer)
        }
    }

    func assertHappyCase(storage: PackageCollectionsSourcesStorage) async throws {
        let sources = makeMockSources()

        for source in sources {
            _ = try await storage.add(source: source, order: nil)
        }

        do {
            let list = try await storage.list()
            XCTAssertEqual(list.count, sources.count, "sources should match")
        }

        let remove = sources.enumerated().filter { index, _ in index % 2 == 0 }.map { $1 }
        for source in remove {
            _ = try await storage.remove(source: source)
        }

        do {
            let list = try await storage.list()
            XCTAssertEqual(list.count, sources.count - remove.count, "sources should match")
        }

        let remaining = sources.filter { !remove.contains($0) }
        for source in sources {
            try await XCTAssertAsyncTrue(try await storage.exists(source: source) == remaining.contains(source))
        }

        do {
            _ = try await storage.move(source: remaining.last!, to: 0)
            let list = try await storage.list()
            XCTAssertEqual(list.count, remaining.count, "sources should match")
            XCTAssertEqual(list.first, remaining.last, "item should match")
        }

        do {
            _ = try await storage.move(source: remaining.last!, to: remaining.count - 1)
            let list = try await storage.list()
            XCTAssertEqual(list.count, remaining.count, "sources should match")
            XCTAssertEqual(list.last, remaining.last, "item should match")
        }

        do {
            let list = try await storage.list()
            var source = list.first!
            source.isTrusted = !(source.isTrusted ?? false)
            _ = try await storage.update(source: source)
            let listAfter = try await storage.list()
            XCTAssertEqual(source.isTrusted, listAfter.first!.isTrusted, "isTrusted should match")
        }

        do {
            let list = try await storage.list()
            var source = list.first!
            source.skipSignatureCheck = !source.skipSignatureCheck
            _ = try await storage.update(source: source)
            let listAfter = try await storage.list()
            XCTAssertEqual(source.skipSignatureCheck, listAfter.first!.skipSignatureCheck, "skipSignatureCheck should match")
        }
    }

    func testFileDeleted() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let storage = FilePackageCollectionsSourcesStorage(fileSystem: mockFileSystem)

        let sources = makeMockSources()

        for source in sources {
            _ = try await storage.add(source: source, order: nil)
        }

        do {
            let list = try await storage.list()
            XCTAssertEqual(list.count, sources.count, "collections should match")
        }

        try mockFileSystem.removeFileTree(storage.path)
        XCTAssertFalse(mockFileSystem.exists(storage.path), "expected file to be deleted")

        do {
            let list = try await storage.list()
            XCTAssertEqual(list.count, 0, "collections should match")
        }
    }

    func testFileEmpty() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let storage = FilePackageCollectionsSourcesStorage(fileSystem: mockFileSystem)

        let sources = makeMockSources()

        for source in sources {
            _ = try await storage.add(source: source, order: nil)
        }

        do {
            let list = try await storage.list()
            XCTAssertEqual(list.count, sources.count, "collections should match")
        }

        try mockFileSystem.writeFileContents(storage.path, bytes: [])
        let buffer = try mockFileSystem.readFileContents(storage.path)
        XCTAssertEqual(buffer.count, 0, "expected file to be empty")

        do {
            let list = try await storage.list()
            XCTAssertEqual(list.count, 0, "collections should match")
        }
    }

    func testFileCorrupt() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let storage = FilePackageCollectionsSourcesStorage(fileSystem: mockFileSystem)

        let sources = makeMockSources()

        for source in sources {
            _ = try await storage.add(source: source, order: nil)
        }

        let list = try await storage.list()
        XCTAssertEqual(list.count, sources.count, "collections should match")

        try mockFileSystem.writeFileContents(storage.path, string: "{")

        let buffer = try mockFileSystem.readFileContents(storage.path)
        XCTAssertNotEqual(buffer.count, 0, "expected file to be written")
        print(buffer)

        await XCTAssertAsyncThrowsError(try await storage.list(), "expected an error", { error in
            XCTAssert(error is DecodingError, "expected error to match")
        })
    }
}
