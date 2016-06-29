/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest
import Utility
import Basic
import class Foundation.FileManager

class TemporaryFileTests: XCTestCase {
    func testBasicReadWrite() throws {
        let filePath: AbsolutePath
        do {
            let file = try TemporaryFile(prefix: "myprefix", suffix: "mysuffix")
            // Make sure the filename contains our prefix and suffix.
            XCTAssertTrue(file.path.basename.hasPrefix("myprefix"))
            XCTAssertTrue(file.path.basename.hasSuffix("mysuffix"))

            // Check if file is created.
            XCTAssertTrue(String(file.path).isFile)

            // Try writing some data to the file.
            let stream = OutputByteStream()
            stream <<< "foo"
            stream <<< "bar"
            stream <<< "baz"
            try fputs(stream.bytes.contents, file.fileHandle)

            // Go to the begining of the file.
            file.fileHandle.seek(toFileOffset: 0)
            // Read the contents.
            let contents = try? file.fileHandle.readFileContents()
            XCTAssertEqual(contents, "foobarbaz")

            filePath = file.path
        }
        // File should be deleted now.
        XCTAssertFalse(String(filePath).isFile)
    }

    func testCanCreateUniqueTempFiles() throws {
        let filePathOne: AbsolutePath
        let filePathTwo: AbsolutePath
        do {
            let fileOne = try TemporaryFile()
            let fileTwo = try TemporaryFile()
            // Check files exists.
            XCTAssertTrue(String(fileOne.path).isFile)
            XCTAssertTrue(String(fileTwo.path).isFile)
            // Their paths should be different.
            XCTAssertTrue(fileOne.path != fileTwo.path)

            filePathOne = fileOne.path
            filePathTwo = fileTwo.path
        }
        XCTAssertFalse(String(filePathOne).isFile)
        XCTAssertFalse(String(filePathTwo).isFile)
    }

    func testBasicTemporaryDirectory() throws {
        // Test can create and remove temp directory.
        var path: AbsolutePath
        do {
            let tempDir = try TemporaryDirectory()
            XCTAssertTrue(localFS.isDirectory(tempDir.path))
            path = tempDir.path
        }
        XCTAssertFalse(localFS.isDirectory(path))

        // Test temp directory is not removed when its not empty. 
        do {
            let tempDir = try TemporaryDirectory()
            XCTAssertTrue(localFS.isDirectory(tempDir.path))
            // Create a file inside the temp directory.
            let filePath = String(tempDir.path.appending("somefile"))
            try localFS.writeFileContents(filePath, bytes: ByteString())
            path = tempDir.path
        }
        XCTAssertTrue(localFS.isDirectory(path))
        // Cleanup.
        try FileManager.default().removeItem(atPath: String(path))
        XCTAssertFalse(localFS.isDirectory(path))

        // Test temp directory is removed when its not empty and removeTreeOnDeinit is enabled.
        do {
            let tempDir = try TemporaryDirectory(removeTreeOnDeinit: true)
            XCTAssertTrue(localFS.isDirectory(tempDir.path))
            let filePath = String(tempDir.path.appending("somefile"))
            try localFS.writeFileContents(filePath, bytes: ByteString())
            path = tempDir.path
        }
        XCTAssertFalse(localFS.isDirectory(path))
    }

    func testCanCreateUniqueTempDirectories() throws {
        let pathOne: AbsolutePath
        let pathTwo: AbsolutePath
        do {
            let one = try TemporaryDirectory()
            let two = try TemporaryDirectory()
            XCTAssertTrue(localFS.isDirectory(one.path))
            XCTAssertTrue(localFS.isDirectory(two.path))
            // Their paths should be different.
            XCTAssertTrue(one.path != two.path)
            pathOne = one.path
            pathTwo = two.path
        }
        XCTAssertFalse(localFS.isDirectory(pathOne))
        XCTAssertFalse(localFS.isDirectory(pathTwo))
    }

    static var allTests = [
        ("testBasicReadWrite", testBasicReadWrite),
        ("testCanCreateUniqueTempFiles", testCanCreateUniqueTempFiles),
        ("testBasicTemporaryDirectory", testBasicTemporaryDirectory),
        ("testCanCreateUniqueTempDirectories", testCanCreateUniqueTempDirectories),
    ]
}
