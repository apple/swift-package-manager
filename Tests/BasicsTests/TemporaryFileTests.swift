/*
 This source file is part of the Swift.org open source project
 
 Copyright (c) 2022 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception
 
 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import XCTest

import class Foundation.FileManager

import TSCBasic

import Basics

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
class TemporaryAsyncFileTests: XCTestCase {
    func testBasicTemporaryDirectory() async throws {
        // Test can create and remove temp directory.
        let path1: AbsolutePath = try await withTemporaryDirectory(removeTreeOnDeinit: true) { tempDirPath in
            // Do some async task
            let task = Task {
                return
            }
            await task.value
            
            XCTAssertTrue(localFileSystem.isDirectory(tempDirPath))
            return tempDirPath
        }.value
        XCTAssertFalse(localFileSystem.isDirectory(path1))
        
        // Test temp directory is not removed when its not empty.
        let path2: AbsolutePath = try await withTemporaryDirectory { tempDirPath in
            XCTAssertTrue(localFileSystem.isDirectory(tempDirPath))
            // Create a file inside the temp directory.
            let filePath = tempDirPath.appending(component: "somefile")
            // Do some async task
            let task = Task {
                return
            }
            await task.value
            
            try localFileSystem.writeFileContents(filePath, bytes: ByteString())
            return tempDirPath
        }.value
        XCTAssertTrue(localFileSystem.isDirectory(path2))
        // Cleanup.
        try FileManager.default.removeItem(atPath: path2.pathString)
        XCTAssertFalse(localFileSystem.isDirectory(path2))
        
        // Test temp directory is removed when its not empty and removeTreeOnDeinit is enabled.
        let path3: AbsolutePath = try await withTemporaryDirectory(removeTreeOnDeinit: true) { tempDirPath in
            XCTAssertTrue(localFileSystem.isDirectory(tempDirPath))
            let filePath = tempDirPath.appending(component: "somefile")
            // Do some async task
            let task = Task {
                return
            }
            await task.value
            
            try localFileSystem.writeFileContents(filePath, bytes: ByteString())
            return tempDirPath
        }.value
        XCTAssertFalse(localFileSystem.isDirectory(path3))
    }
    
    func testCanCreateUniqueTempDirectories() async throws {
        let (pathOne, pathTwo): (AbsolutePath, AbsolutePath) = try await withTemporaryDirectory(removeTreeOnDeinit: true) { pathOne in
            let pathTwo: AbsolutePath = try await withTemporaryDirectory(removeTreeOnDeinit: true) { pathTwo in
                // Do some async task
                let task = Task {
                    return
                }
                await task.value
                
                XCTAssertTrue(localFileSystem.isDirectory(pathOne))
                XCTAssertTrue(localFileSystem.isDirectory(pathTwo))
                // Their paths should be different.
                XCTAssertTrue(pathOne != pathTwo)
                return pathTwo
            }.value
            return (pathOne, pathTwo)
        }.value
        XCTAssertFalse(localFileSystem.isDirectory(pathOne))
        XCTAssertFalse(localFileSystem.isDirectory(pathTwo))
    }
    
    func testCancelOfTask() async throws {
        let task: Task<AbsolutePath, Error> = try withTemporaryDirectory { path in
            
            try await Task.sleep(nanoseconds: 1_000_000_000)
            XCTAssertTrue(Task.isCancelled)
            XCTAssertFalse(localFileSystem.isDirectory(path))
            return path
        }
        task.cancel()
        do {
            // The correct path is to throw an error here
            let _ = try await task.value
            XCTFail("The correct path here is to throw an error")
        } catch {}
    }
}
