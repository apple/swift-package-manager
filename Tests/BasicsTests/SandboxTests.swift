//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@testable import Basics
import _InternalTestSupport
import XCTest

#if canImport(Darwin)
import Darwin
#endif

import class TSCBasic.InMemoryFileSystem
import class Basics.AsyncProcess
import struct Basics.AsyncProcessResult

final class SandboxTest: XCTestCase {
    func testSandboxOnAllPlatforms() throws {
        try withTemporaryDirectory { path in
#if os(Windows)
            let command = try Sandbox.apply(command: ["tar.exe", "-h"], strictness: .default, writableDirectories: [])
#else
            let command = try Sandbox.apply(command: ["echo", "0"], strictness: .default, writableDirectories: [])
#endif
            XCTAssertNoThrow(try AsyncProcess.checkNonZeroExit(arguments: command))
        }
    }
    
#if canImport(Darwin)
    // _CS_DARWIN_USER_CACHE_DIR is only on Darwin, will fail to compile on other platforms.
    func testUniformTypeIdentifiers() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif

        let testProgram = """
        import Foundation

        let file = URL(fileURLWithPath:"\(#file)", isDirectory:false)
        guard let resourceValues = try? file.resourceValues(forKeys: [.contentTypeKey]) else {
            fputs("Failed to get content type/type identifier for '\(#file)'", stderr)
            exit(EXIT_FAILURE)
        }
        """
        let cacheDirectory = String(unsafeUninitializedCapacity: Int(PATH_MAX)) { buffer in
            return confstr(_CS_DARWIN_USER_CACHE_DIR, buffer.baseAddress, Int(PATH_MAX))
        }
        let command = try Sandbox.apply(command: ["swift", "-"], strictness: .writableTemporaryDirectory, writableDirectories: [try AbsolutePath(validating: cacheDirectory)])
        let process = AsyncProcess(arguments: command)
        let stdin = try process.launch()
        stdin.write(sequence: testProgram.utf8)
        try stdin.close()
        let processResult = try process.waitUntilExit()
        XCTAssertEqual(processResult.exitStatus, .terminated(code: 0), (try? processResult.utf8stderrOutput()) ?? "")
    }
#endif

    func testNetworkNotAllowed() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif

        let command = try Sandbox.apply(command: ["ping", "-t", "1", "localhost"], strictness: .default, writableDirectories: [])

        XCTAssertThrowsError(try AsyncProcess.checkNonZeroExit(arguments: command)) { error in
            guard case AsyncProcessResult.Error.nonZeroExit(let result) = error else {
                return XCTFail("invalid error \(error)")
            }
            XCTAssertMatch(try! result.utf8stderrOutput(), .contains("Operation not permitted"))
        }
    }

    func testWritableAllowed() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif

        try withTemporaryDirectory { path in
            let command = try Sandbox.apply(command: ["touch", path.appending(component: UUID().uuidString).pathString], strictness: .default, writableDirectories: [path])
            XCTAssertNoThrow(try AsyncProcess.checkNonZeroExit(arguments: command))
        }
    }

    func testWritableNotAllowed() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif

        try withTemporaryDirectory { path in
            let command = try Sandbox.apply(command: ["touch", path.appending(component: UUID().uuidString).pathString], strictness: .default, writableDirectories: [])
            XCTAssertThrowsError(try AsyncProcess.checkNonZeroExit(arguments: command)) { error in
                guard case AsyncProcessResult.Error.nonZeroExit(let result) = error else {
                    return XCTFail("invalid error \(error)")
                }
                XCTAssertMatch(try! result.utf8stderrOutput(), .contains("Operation not permitted"))
            }
        }
    }

    func testRemoveNotAllowed() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif

        try withTemporaryDirectory { path in
            let file = path.appending(component: UUID().uuidString)
            XCTAssertNoThrow(try AsyncProcess.checkNonZeroExit(arguments: ["touch", file.pathString]))

            let command = try Sandbox.apply(command: ["rm", file.pathString], strictness: .default, writableDirectories: [])
            XCTAssertThrowsError(try AsyncProcess.checkNonZeroExit(arguments: command)) { error in
                guard case AsyncProcessResult.Error.nonZeroExit(let result) = error else {
                    return XCTFail("invalid error \(error)")
                }
                XCTAssertMatch(try! result.utf8stderrOutput(), .contains("Operation not permitted"))
            }
        }
    }

    // FIXME: rdar://75707545 this should not be allowed outside very specific read locations
    func testReadAllowed() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif

        try withTemporaryDirectory { path in
            let file = path.appending(component: UUID().uuidString)
            XCTAssertNoThrow(try AsyncProcess.checkNonZeroExit(arguments: ["touch", file.pathString]))

            let command = try Sandbox.apply(command: ["cat", file.pathString], strictness: .default, writableDirectories: [])
            XCTAssertNoThrow(try AsyncProcess.checkNonZeroExit(arguments: command))
        }
    }

    // FIXME: rdar://75707545 this should not be allowed outside very specific programs
    func testExecuteAllowed() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif

        try withTemporaryDirectory { path in
            let file = path.appending(component: UUID().uuidString)
            XCTAssertNoThrow(try AsyncProcess.checkNonZeroExit(arguments: ["touch", file.pathString]))
            XCTAssertNoThrow(try AsyncProcess.checkNonZeroExit(arguments: ["chmod", "+x", file.pathString]))

            let command = try Sandbox.apply(command: [file.pathString], strictness: .default, writableDirectories: [])
            XCTAssertNoThrow(try AsyncProcess.checkNonZeroExit(arguments: command))
        }
    }

    func testWritingToTemporaryDirectoryAllowed() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif

        // Try writing to the per-user temporary directory, which is under /var/folders/.../TemporaryItems.
        let tmpFile1 = NSTemporaryDirectory() + "/" + UUID().uuidString
        let command1 = try Sandbox.apply(command: ["touch", tmpFile1], strictness: .writableTemporaryDirectory)
        XCTAssertNoThrow(try AsyncProcess.checkNonZeroExit(arguments: command1))
        try? FileManager.default.removeItem(atPath: tmpFile1)

        let tmpFile2 = "/tmp" + "/" + UUID().uuidString
        let command2 = try Sandbox.apply(command: ["touch", tmpFile2], strictness: .writableTemporaryDirectory)
        XCTAssertNoThrow(try AsyncProcess.checkNonZeroExit(arguments: command2))
        try? FileManager.default.removeItem(atPath: tmpFile2)
    }

    func testWritingToReadOnlyInsideWritableNotAllowed() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "sandboxing is only supported on macOS")
        #endif

        try withTemporaryDirectory { tmpDir in
            // Check that we can write into the temporary directory, but not into a read-only directory underneath it.
            let writableDir = tmpDir.appending("ShouldBeWritable")
            try localFileSystem.createDirectory(writableDir)
            let allowedCommand = try Sandbox.apply(command: ["touch", writableDir.pathString], strictness: .default, writableDirectories: [writableDir])
            XCTAssertNoThrow(try AsyncProcess.checkNonZeroExit(arguments: allowedCommand))

            // Check that we cannot write into a read-only directory inside a writable temporary directory.
            let readOnlyDir = writableDir.appending("ShouldBeReadOnly")
            try localFileSystem.createDirectory(readOnlyDir)
            let deniedCommand = try Sandbox.apply(command: ["touch", readOnlyDir.pathString], strictness: .writableTemporaryDirectory, readOnlyDirectories: [readOnlyDir])
            XCTAssertThrowsError(try AsyncProcess.checkNonZeroExit(arguments: deniedCommand)) { error in
                guard case AsyncProcessResult.Error.nonZeroExit(let result) = error else {
                    return XCTFail("invalid error \(error)")
                }
                XCTAssertMatch(try! result.utf8stderrOutput(), .contains("Operation not permitted"))
            }
        }
    }

    func testWritingToWritableInsideReadOnlyAllowed() throws {
         #if !os(macOS)
         try XCTSkipIf(true, "sandboxing is only supported on macOS")
         #endif

         try withTemporaryDirectory { tmpDir in
             // Check that we cannot write into a read-only directory, but into a writable directory underneath it.
             let readOnlyDir = tmpDir.appending("ShouldBeReadOnly")
             try localFileSystem.createDirectory(readOnlyDir)
             let deniedCommand = try Sandbox.apply(command: ["touch", readOnlyDir.pathString], strictness: .writableTemporaryDirectory, readOnlyDirectories: [readOnlyDir])
             XCTAssertThrowsError(try AsyncProcess.checkNonZeroExit(arguments: deniedCommand)) { error in
                 guard case AsyncProcessResult.Error.nonZeroExit(let result) = error else {
                     return XCTFail("invalid error \(error)")
                 }
                 XCTAssertMatch(try! result.utf8stderrOutput(), .contains("Operation not permitted"))
             }

             // Check that we can write into a writable directory underneath it.
             let writableDir = readOnlyDir.appending("ShouldBeWritable")
             try localFileSystem.createDirectory(writableDir)
             let allowedCommand = try Sandbox.apply(command: ["touch", writableDir.pathString], strictness: .default, writableDirectories:[writableDir], readOnlyDirectories: [readOnlyDir])
             XCTAssertNoThrow(try AsyncProcess.checkNonZeroExit(arguments: allowedCommand))
         }
     }
}

extension Sandbox {
    public static func apply(
        command: [String],
        strictness: Strictness = .default,
        writableDirectories: [AbsolutePath] = [],
        readOnlyDirectories: [AbsolutePath] = [],
        allowNetworkConnections: [SandboxNetworkPermission] = []
    ) throws -> [String] {
        return try self.apply(
            command: command,
            fileSystem: InMemoryFileSystem(),
            strictness: strictness,
            writableDirectories: writableDirectories,
            readOnlyDirectories: readOnlyDirectories,
            allowNetworkConnections: allowNetworkConnections
        )
    }
}
