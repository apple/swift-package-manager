/*
 This source file is part of the Swift.org open source project

 Copyright 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest

import Basic
import POSIX
import Utility

func XCTAssertThrows<T where T: ErrorProtocol, T: Equatable>(_ expectedError: T, file: StaticString = #file, line: UInt = #line, _ body: () throws -> ()) {
    do {
        try body()
        XCTFail("body completed successfully", file: file, line: line)
    } catch let error as T {
        XCTAssertEqual(error, expectedError, file: file, line: line)
    } catch {
        XCTFail("unexpected error thrown", file: file, line: line)
    }
}

class FSProxyTests: XCTestCase {

    // MARK: LocalFS Tests

    func testLocalBasics() {
        let fs = Basic.localFS

        // exists()
        XCTAssert(fs.exists("/"))
        XCTAssert(!fs.exists("/does-not-exist"))

        // isDirectory()
        XCTAssert(fs.isDirectory("/"))
        XCTAssert(!fs.isDirectory("/does-not-exist"))

        // getDirectoryContents()
        XCTAssertThrows(FSProxyError.noEntry) {
            _ = try fs.getDirectoryContents("/does-not-exist")
        }
        let thisDirectoryContents = try! fs.getDirectoryContents(#file.parentDirectory)
        XCTAssertTrue(!thisDirectoryContents.contains({ $0 == "." }))
        XCTAssertTrue(!thisDirectoryContents.contains({ $0 == ".." }))
        XCTAssertTrue(thisDirectoryContents.contains({ $0 == #file.basename }))
    }

    func testLocalCreateDirectory() {
        var fs = Basic.localFS
        
        // FIXME: Migrate to temporary file wrapper, once we have one.
        try! POSIX.mkdtemp(#function) { tmpDir in
            do {
                let testPath = Path.join(tmpDir, "new-dir")
                XCTAssert(!fs.exists(testPath))
                try! fs.createDirectory(testPath)
                XCTAssert(fs.exists(testPath))
                XCTAssert(fs.isDirectory(testPath))
            }

            do {
                let testPath = Path.join(tmpDir, "another-new-dir/with-a-subdir")
                XCTAssert(!fs.exists(testPath))
                try! fs.createDirectory(testPath, recursive: true)
                XCTAssert(fs.exists(testPath))
                XCTAssert(fs.isDirectory(testPath))
            }

            try! Utility.removeFileTree(tmpDir)
        }
    }

    func testLocalReadWriteFile() {
        var fs = Basic.localFS
        
        try! POSIX.mkdtemp(#function) { tmpDir in
            // Check read/write of a simple file.
            let testData = (0..<1000).map { $0.description }.joined(separator: ", ")
            let filePath = Path.join(tmpDir, "test-data.txt")
            try! fs.writeFileContents(filePath, bytes: ByteString(testData))
            let data = try! fs.readFileContents(filePath)
            XCTAssertEqual(data, ByteString(testData))

            // Check overwrite of a file.
            try! fs.writeFileContents(filePath, bytes: "Hello, new world!")
            XCTAssertEqual(try! fs.readFileContents(filePath), "Hello, new world!")
        
            // Check read/write of a directory.
            XCTAssertThrows(FSProxyError.ioError) {
                _ = try fs.readFileContents(filePath.parentDirectory)
            }
            XCTAssertThrows(FSProxyError.isDirectory) {
                try fs.writeFileContents(filePath.parentDirectory, bytes: [])
            }
            XCTAssertEqual(try! fs.readFileContents(filePath), "Hello, new world!")
        
            // Check read/write against root.
            XCTAssertThrows(FSProxyError.ioError) {
                _ = try fs.readFileContents("/")
            }
            XCTAssertThrows(FSProxyError.isDirectory) {
                try fs.writeFileContents("/", bytes: [])
            }
            XCTAssert(fs.exists(filePath))
        
            // Check read/write into a non-directory.
            XCTAssertThrows(FSProxyError.notDirectory) {
                _ = try fs.readFileContents(Path.join(filePath, "not-possible"))
            }
            XCTAssertThrows(FSProxyError.notDirectory) {
                try fs.writeFileContents(Path.join(filePath, "not-possible"), bytes: [])
            }
            XCTAssert(fs.exists(filePath))
        
            // Check read/write into a missing directory.
            let missingDir = Path.join(tmpDir, "does/not/exist")
            XCTAssertThrows(FSProxyError.noEntry) {
                _ = try fs.readFileContents(missingDir)
            }
            XCTAssertThrows(FSProxyError.noEntry) {
                try fs.writeFileContents(missingDir, bytes: [])
            }
            XCTAssert(!fs.exists(missingDir))

            try! Utility.removeFileTree(tmpDir)
        }
    }

    // MARK: PseudoFS Tests

    func testPseudoBasics() {
        let fs = PseudoFS()

        // exists()
        XCTAssert(!fs.exists("/does-not-exist"))

        // isDirectory()
        XCTAssert(!fs.isDirectory("/does-not-exist"))

        // getDirectoryContents()
        XCTAssertThrows(FSProxyError.noEntry) {
            _ = try fs.getDirectoryContents("/does-not-exist")
        }

        // createDirectory()
        XCTAssert(!fs.isDirectory("/new-dir"))
        try! fs.createDirectory("/new-dir/subdir", recursive: true)
        XCTAssert(fs.isDirectory("/new-dir"))
        XCTAssert(fs.isDirectory("/new-dir/subdir"))
    }

    func testPseudoCreateDirectory() {
        let fs = PseudoFS()
        let subdir = AbsolutePath("/new-dir/subdir")
        try! fs.createDirectory(subdir, recursive: true)
        XCTAssert(fs.isDirectory(subdir))

        // Check duplicate creation.
        try! fs.createDirectory(subdir, recursive: true)
        XCTAssert(fs.isDirectory(subdir))
        
        // Check non-recursive subdir creation.
        let subsubdir = subdir.appending("new-subdir")
        XCTAssert(!fs.isDirectory(subsubdir))
        try! fs.createDirectory(subsubdir, recursive: false)
        XCTAssert(fs.isDirectory(subsubdir))
        
        // Check non-recursive failing subdir case.
        let newsubdir = AbsolutePath("/very-new-dir/subdir")
        XCTAssert(!fs.isDirectory(newsubdir))
        XCTAssertThrows(FSProxyError.noEntry) {
            try fs.createDirectory(newsubdir, recursive: false)
        }
        XCTAssert(!fs.isDirectory(newsubdir))
        
        // Check directory creation over a file.
        let filePath = AbsolutePath("/mach_kernel")
        try! fs.writeFileContents(filePath, bytes: [0xCD, 0x0D])
        XCTAssert(fs.exists(filePath) && !fs.isDirectory(filePath))
        XCTAssertThrows(FSProxyError.notDirectory) {
            try fs.createDirectory(filePath, recursive: true)
        }
        XCTAssertThrows(FSProxyError.notDirectory) {
            try fs.createDirectory(filePath.appending("not-possible"), recursive: true)
        }
        XCTAssert(fs.exists(filePath) && !fs.isDirectory(filePath))
    }
    
    func testPseudoReadWriteFile() {
        let fs = PseudoFS()
        try! fs.createDirectory("/new-dir/subdir", recursive: true)

        // Check read/write of a simple file.
        let filePath = AbsolutePath("/new-dir/subdir").appending("new-file.txt")
        XCTAssert(!fs.exists(filePath))
        try! fs.writeFileContents(filePath, bytes: "Hello, world!")
        XCTAssert(fs.exists(filePath))
        XCTAssert(!fs.isDirectory(filePath))
        XCTAssertEqual(try! fs.readFileContents(filePath), "Hello, world!")

        // Check overwrite of a file.
        try! fs.writeFileContents(filePath, bytes: "Hello, new world!")
        XCTAssertEqual(try! fs.readFileContents(filePath), "Hello, new world!")
        
        // Check read/write of a directory.
        XCTAssertThrows(FSProxyError.isDirectory) {
            _ = try fs.readFileContents(filePath.parentDirectory)
        }
        XCTAssertThrows(FSProxyError.isDirectory) {
            try fs.writeFileContents(filePath.parentDirectory, bytes: [])
        }
        XCTAssertEqual(try! fs.readFileContents(filePath), "Hello, new world!")
        
        // Check read/write against root.
        XCTAssertThrows(FSProxyError.isDirectory) {
            _ = try fs.readFileContents("/")
        }
        XCTAssertThrows(FSProxyError.isDirectory) {
            try fs.writeFileContents("/", bytes: [])
        }
        XCTAssert(fs.exists(filePath))
        
        // Check read/write into a non-directory.
        XCTAssertThrows(FSProxyError.notDirectory) {
            _ = try fs.readFileContents(filePath.appending("not-possible"))
        }
        XCTAssertThrows(FSProxyError.notDirectory) {
            try fs.writeFileContents(filePath.appending("not-possible"), bytes: [])
        }
        XCTAssert(fs.exists(filePath))
        
        // Check read/write into a missing directory.
        let missingDir = AbsolutePath("/does/not/exist")
        XCTAssertThrows(FSProxyError.noEntry) {
            _ = try fs.readFileContents(missingDir)
        }
        XCTAssertThrows(FSProxyError.noEntry) {
            try fs.writeFileContents(missingDir, bytes: [])
        }
        XCTAssert(!fs.exists(missingDir))
    }
    
    static var allTests = [
        ("testLocalBasics", testLocalBasics),
        ("testLocalCreateDirectory", testLocalCreateDirectory),
        ("testLocalReadWriteFile", testLocalReadWriteFile),
        ("testPseudoBasics", testPseudoBasics),
        ("testPseudoCreateDirectory", testPseudoCreateDirectory),
        ("testPseudoReadWriteFile", testPseudoReadWriteFile),
    ]
}
