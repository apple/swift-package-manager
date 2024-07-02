//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@testable import Basics
import TSCTestSupport
import XCTest

final class FileSystemTests: XCTestCase {
    func testStripFirstLevelComponent() throws {
        let fileSystem = InMemoryFileSystem()

        let rootPath = AbsolutePath("/root")
        try fileSystem.createDirectory(rootPath)

        let totalDirectories = Int.random(in: 0 ..< 100)
        for index in 0 ..< totalDirectories {
            let path = rootPath.appending("dir\(index)")
            try fileSystem.createDirectory(path, recursive: false)
        }

        let totalFiles = Int.random(in: 0 ..< 100)
        for index in 0 ..< totalFiles {
            let path = rootPath.appending("file\(index)")
            try fileSystem.writeFileContents(path, string: "\(index)")
        }

        do {
            let contents = try fileSystem.getDirectoryContents(.root)
            XCTAssertEqual(contents.count, 1)
        }

        try fileSystem.stripFirstLevel(of: .root)

        do {
            let contents = Set(try fileSystem.getDirectoryContents(.root))
            XCTAssertEqual(contents.count, totalDirectories + totalFiles)

            for index in 0 ..< totalDirectories {
                XCTAssertTrue(contents.contains("dir\(index)"))
            }
            for index in 0 ..< totalFiles {
                XCTAssertTrue(contents.contains("file\(index)"))
            }
        }
    }

    func testStripFirstLevelComponentErrors() throws {
        do {
            let fileSystem = InMemoryFileSystem()
            XCTAssertThrowsError(try fileSystem.stripFirstLevel(of: .root), "expected error") { error in
                XCTAssertMatch((error as? StringError)?.description, .contains("requires single top level directory"))
            }
        }

        do {
            let fileSystem = InMemoryFileSystem()
            for index in 0 ..< 3 {
                let path = AbsolutePath.root.appending("dir\(index)")
                try fileSystem.createDirectory(path, recursive: false)
            }
            XCTAssertThrowsError(try fileSystem.stripFirstLevel(of: .root), "expected error") { error in
                XCTAssertMatch((error as? StringError)?.description, .contains("requires single top level directory"))
            }
        }

        do {
            let fileSystem = InMemoryFileSystem()
            for index in 0 ..< 3 {
                let path = AbsolutePath.root.appending("file\(index)")
                try fileSystem.writeFileContents(path, string: "\(index)")
            }
            XCTAssertThrowsError(try fileSystem.stripFirstLevel(of: .root), "expected error") { error in
                XCTAssertMatch((error as? StringError)?.description, .contains("requires single top level directory"))
            }
        }

        do {
            let fileSystem = InMemoryFileSystem()
            let path = AbsolutePath.root.appending("file")
            try fileSystem.writeFileContents(path, string: "")
            XCTAssertThrowsError(try fileSystem.stripFirstLevel(of: .root), "expected error") { error in
                XCTAssertMatch((error as? StringError)?.description, .contains("requires single top level directory"))
            }
        }
    }
}
