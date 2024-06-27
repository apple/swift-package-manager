//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@testable import Basics
import _InternalTestSupport
import tsan_utils
import XCTest

final class SQLiteBackedCacheTests: XCTestCase {
    func testHappyCase() throws {
        try testWithTemporaryDirectory { tmpPath in
            let path = tmpPath.appending("test.db")
            let cache = SQLiteBackedCache<String>(tableName: "SQLiteBackedCacheTest", path: path)
            defer { XCTAssertNoThrow(try cache.close()) }

            let mockData = try makeMockData(fileSystem: localFileSystem, rootPath: tmpPath)
            try mockData.forEach { key, value in
                _ = try cache.put(key: key, value: value)
            }

            try mockData.forEach { key, _ in
                let result = try cache.get(key: key)
                XCTAssertEqual(mockData[key], result)
            }

            let key = mockData.first!.key

            _ = try cache.put(key: key, value: "foobar", replace: false)
            XCTAssertEqual(mockData[key], try cache.get(key: key))

            _ = try cache.put(key: key, value: "foobar", replace: true)
            XCTAssertEqual("foobar", try cache.get(key: key))

            try cache.remove(key: key)
            XCTAssertNil(try cache.get(key: key))

            guard case .path(let cachePath) = cache.location else {
                return XCTFail("invalid location \(cache.location)")
            }

            XCTAssertTrue(cache.fileSystem.exists(cachePath), "expected file to be written")
        }
    }

    func testFileDeleted() throws {
#if os(Windows)
        try XCTSkipIf(true, "open file cannot be deleted on Windows")
#endif
        try XCTSkipIf(is_tsan_enabled())

        try testWithTemporaryDirectory { tmpPath in
            let path = tmpPath.appending("test.db")
            let cache = SQLiteBackedCache<String>(tableName: "SQLiteBackedCacheTest", path: path)
            defer { XCTAssertNoThrow(try cache.close()) }

            let mockData = try makeMockData(fileSystem: localFileSystem, rootPath: tmpPath)
            try mockData.forEach { key, value in
                _ = try cache.put(key: key, value: value)
            }

            try mockData.forEach { key, _ in
                let result = try cache.get(key: key)
                XCTAssertEqual(mockData[key], result)
            }

            guard case .path(let cachePath) = cache.location else {
                return XCTFail("invalid location \(cache.location)")
            }

            XCTAssertTrue(cache.fileSystem.exists(cachePath), "expected file to exist at \(cachePath)")
            try cache.fileSystem.removeFileTree(cachePath)

            let key = mockData.first!.key

            do {
                let result = try cache.get(key: key)
                XCTAssertNil(result)
            }

            do {
                XCTAssertNoThrow(try cache.put(key: key, value: mockData[key]!))
                let result = try cache.get(key: key)
                XCTAssertEqual(mockData[key], result)
            }

            XCTAssertTrue(cache.fileSystem.exists(cachePath), "expected file to exist at \(cachePath)")
        }
    }

    func testFileCorrupt() throws {
        try XCTSkipIf(is_tsan_enabled())

        try testWithTemporaryDirectory { tmpPath in
            let path = tmpPath.appending("test.db")
            let cache = SQLiteBackedCache<String>(tableName: "SQLiteBackedCacheTest", path: path)
            defer { XCTAssertNoThrow(try cache.close()) }

            let mockData = try makeMockData(fileSystem: localFileSystem, rootPath: tmpPath)
            try mockData.forEach { key, value in
                _ = try cache.put(key: key, value: value)
            }

            try mockData.forEach { key, _ in
                let result = try cache.get(key: key)
                XCTAssertEqual(mockData[key], result)
            }

            guard case .path(let cachePath) = cache.location else {
                return XCTFail("invalid location \(cache.location)")
            }

            try cache.close()

            XCTAssertTrue(cache.fileSystem.exists(cachePath), "expected file to exist at \(path)")
            try cache.fileSystem.writeFileContents(cachePath, string: "blah")

            XCTAssertThrowsError(try cache.get(key: mockData.first!.key), "expected error") { error in
                XCTAssert("\(error)".contains("is not a database"), "Expected file is not a database error")
            }

            XCTAssertThrowsError(try cache.put(key: mockData.first!.key, value: mockData.first!.value), "expected error") { error in
                XCTAssert("\(error)".contains("is not a database"), "Expected file is not a database error")
            }
        }
    }

    func testMaxSizeNotHandled() throws {
        try testWithTemporaryDirectory { tmpPath in
            let path = tmpPath.appending("test.db")
            var configuration = SQLiteBackedCacheConfiguration()
            configuration.maxSizeInBytes = 1024 * 3
            configuration.truncateWhenFull = false
            let cache = SQLiteBackedCache<String>(tableName: "SQLiteBackedCacheTest", path: path, configuration: configuration)
            defer { XCTAssertNoThrow(try cache.close()) }

            func create() throws {
                let mockData = try makeMockData(fileSystem: localFileSystem, rootPath: tmpPath, count: 500)
                try mockData.forEach { key, value in
                    _ = try cache.put(key: key, value: value)
                }
            }

            XCTAssertThrowsError(try create(), "expected error") { error in
                XCTAssertEqual(error as? SQLite.Errors, .databaseFull, "Expected 'databaseFull' error")
            }
        }
    }

    func testMaxSizeHandled() throws {
        try testWithTemporaryDirectory { tmpPath in
            let path = tmpPath.appending("test.db")
            var configuration = SQLiteBackedCacheConfiguration()
            configuration.maxSizeInBytes = 1024 * 3
            configuration.truncateWhenFull = true
            let cache = SQLiteBackedCache<String>(tableName: "SQLiteBackedCacheTest", path: path, configuration: configuration)
            defer { XCTAssertNoThrow(try cache.close()) }

            var keys = [String]()
            let mockData = try makeMockData(fileSystem: localFileSystem, rootPath: tmpPath, count: 500)
            try mockData.forEach { key, value in
                _ = try cache.put(key: key, value: value)
                keys.append(key)
            }

            do {
                let result = try cache.get(key: mockData.first!.key)
                XCTAssertNil(result)
            }

            do {
                let result = try cache.get(key: keys.last!)
                XCTAssertEqual(mockData[keys.last!], result)
            }
        }
    }
}

private func makeMockData(fileSystem: FileSystem, rootPath: AbsolutePath, count: Int = Int.random(in: 50 ..< 100)) throws -> [String: String] {
    var data = [String: String]()
    let value = UUID().uuidString
    for index in 0 ..< count {
        data["\(index)"] = "\(index) \(value)"
    }
    return data
}
