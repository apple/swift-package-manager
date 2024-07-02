//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import TSCclibc // for SPM_posix_spawn_file_actions_addchdir_np_supported
import _InternalTestSupport
import XCTest

import struct TSCBasic.FileSystemError

final class UniversalArchiverTests: XCTestCase {
    func testSuccess() async throws {
        try await testWithTemporaryDirectory { tmpdir in
            let archiver = UniversalArchiver(localFileSystem)
            let inputArchivePath = AbsolutePath(#file).parentDirectory
                .appending(components: "Inputs", "archive.tar.gz")
            let tarDestination = tmpdir.appending("tar")
            try localFileSystem.createDirectory(tarDestination)
            try await archiver.extract(from: inputArchivePath, to: tarDestination)
            let tarContent = tarDestination.appending("file")
            XCTAssert(localFileSystem.exists(tarContent))
            XCTAssertEqual((try? localFileSystem.readFileContents(tarContent))?.cString, "Hello World!")

            let zipDestination = tmpdir.appending("zip")
            try localFileSystem.createDirectory(zipDestination)
            try await archiver.extract(from: inputArchivePath, to: zipDestination)
            let zipContent = zipDestination.appending("file")
            XCTAssert(localFileSystem.exists(zipContent))
            XCTAssertEqual((try? localFileSystem.readFileContents(zipContent))?.cString, "Hello World!")
        }
    }

    func testArchiveDoesntExist() async {
        let fileSystem = InMemoryFileSystem()
        let archiver = UniversalArchiver(fileSystem)
        let archive = AbsolutePath("/archive.tar.gz")
        await XCTAssertAsyncThrowsError(try await archiver.extract(from: archive, to: "/")) { error in
            XCTAssertEqual(error as? FileSystemError, FileSystemError(.noEntry, archive))
        }
    }

    func testDestinationDoesntExist() async throws {
        let fileSystem = InMemoryFileSystem(emptyFiles: "/archive.tar.gz")
        let archiver = UniversalArchiver(fileSystem)
        let destination = AbsolutePath("/destination")
        await XCTAssertAsyncThrowsError(try await archiver.extract(from: "/archive.tar.gz", to: destination)) { error in
            XCTAssertEqual(error as? FileSystemError, FileSystemError(.notDirectory, destination))
        }
    }

    func testDestinationIsFile() async throws {
        let fileSystem = InMemoryFileSystem(emptyFiles: "/archive.tar.gz", "/destination")
        let archiver = UniversalArchiver(fileSystem)
        let destination = AbsolutePath("/destination")
        await XCTAssertAsyncThrowsError(try await archiver.extract(from: "/archive.tar.gz", to: destination)) { error in
            XCTAssertEqual(error as? FileSystemError, FileSystemError(.notDirectory, destination))
        }
    }

    func testInvalidArchive() async throws {
        try await testWithTemporaryDirectory { tmpdir in
            let archiver = UniversalArchiver(localFileSystem)
            var inputArchivePath = AbsolutePath(#file).parentDirectory
                .appending(components: "Inputs", "invalid_archive.tar.gz")
            await XCTAssertAsyncThrowsError(try await archiver.extract(from: inputArchivePath, to: tmpdir)) { error in
                #if os(Linux)
                XCTAssertMatch((error as? StringError)?.description, .contains("not in gzip format"))
                #else
                XCTAssertMatch((error as? StringError)?.description, .contains("Unrecognized archive format"))
                #endif
            }

            inputArchivePath = AbsolutePath(#file).parentDirectory
                .appending(components: "Inputs", "invalid_archive.zip")
            await XCTAssertAsyncThrowsError(try await archiver.extract(from: inputArchivePath, to: tmpdir)) { error in
#if os(Windows)
                XCTAssertMatch((error as? StringError)?.description, .contains("Unrecognized archive format"))
#else
                XCTAssertMatch((error as? StringError)?.description, .contains("End-of-central-directory signature not found"))
#endif
            }
        }
    }

    func testValidation() async throws {
        // valid
        try await testWithTemporaryDirectory { _ in
            let archiver = UniversalArchiver(localFileSystem)
            let path = AbsolutePath(#file).parentDirectory
                .appending(components: "Inputs", "archive.tar.gz")
            try await XCTAssertAsyncTrue(try await archiver.validate(path: path))
        }
        // invalid
        try await testWithTemporaryDirectory { _ in
            let archiver = UniversalArchiver(localFileSystem)
            let path = AbsolutePath(#file).parentDirectory
                .appending(components: "Inputs", "invalid_archive.tar.gz")
            try await XCTAssertAsyncFalse(try await archiver.validate(path: path))
        }
        // error
        try await testWithTemporaryDirectory { _ in
            let archiver = UniversalArchiver(localFileSystem)
            let path = AbsolutePath.root.appending("does_not_exist.tar.gz")
            await XCTAssertAsyncThrowsError(try await archiver.validate(path: path)) { error in
                XCTAssertEqual(error as? FileSystemError, FileSystemError(.noEntry, path))
            }
        }
    }

    func testCompress() async throws {
        #if os(Linux)
        guard SPM_posix_spawn_file_actions_addchdir_np_supported() else {
            throw XCTSkip("working directory not supported on this platform")
        }
        #endif

        try await testWithTemporaryDirectory { tmpdir in
            let archiver = UniversalArchiver(localFileSystem)

            let rootDir = tmpdir.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(rootDir)
            try localFileSystem.writeFileContents(rootDir.appending("file1.txt"), string: "Hello World!")

            let dir1 = rootDir.appending("dir1")
            try localFileSystem.createDirectory(dir1)
            try localFileSystem.writeFileContents(dir1.appending("file2.txt"), string: "Hello World 2!")

            let dir2 = dir1.appending("dir2")
            try localFileSystem.createDirectory(dir2)
            try localFileSystem.writeFileContents(dir2.appending("file3.txt"), string: "Hello World 3!")
            try localFileSystem.writeFileContents(dir2.appending("file4.txt"), string: "Hello World 4!")

            var archivePath = tmpdir.appending(component: UUID().uuidString + ".tar.gz")
            try await archiver.compress(directory: rootDir, to: archivePath)
            XCTAssertFileExists(archivePath)

            var extractRootDir = tmpdir.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(extractRootDir)
            try await archiver.extract(from: archivePath, to: extractRootDir)
            try localFileSystem.stripFirstLevel(of: extractRootDir)

            XCTAssertFileExists(extractRootDir.appending("file1.txt"))
            XCTAssertEqual(
                try? localFileSystem.readFileContents(extractRootDir.appending("file1.txt")),
                "Hello World!"
            )

            var extractedDir1 = extractRootDir.appending("dir1")
            XCTAssertDirectoryExists(extractedDir1)
            XCTAssertFileExists(extractedDir1.appending("file2.txt"))
            XCTAssertEqual(
                try? localFileSystem.readFileContents(extractedDir1.appending("file2.txt")),
                "Hello World 2!"
            )

            var extractedDir2 = extractedDir1.appending("dir2")
            XCTAssertDirectoryExists(extractedDir2)
            XCTAssertFileExists(extractedDir2.appending("file3.txt"))
            XCTAssertEqual(
                try? localFileSystem.readFileContents(extractedDir2.appending("file3.txt")),
                "Hello World 3!"
            )
            XCTAssertFileExists(extractedDir2.appending("file4.txt"))
            XCTAssertEqual(
                try? localFileSystem.readFileContents(extractedDir2.appending("file4.txt")),
                "Hello World 4!"
            )

            archivePath = tmpdir.appending(component: UUID().uuidString + ".zip")
            try await archiver.compress(directory: rootDir, to: archivePath)
            XCTAssertFileExists(archivePath)

            extractRootDir = tmpdir.appending(component: UUID().uuidString)
            try localFileSystem.createDirectory(extractRootDir)
            try await archiver.extract(from: archivePath, to: extractRootDir)
            try localFileSystem.stripFirstLevel(of: extractRootDir)

            XCTAssertFileExists(extractRootDir.appending("file1.txt"))
            XCTAssertEqual(
                try? localFileSystem.readFileContents(extractRootDir.appending("file1.txt")),
                "Hello World!"
            )

            extractedDir1 = extractRootDir.appending("dir1")
            XCTAssertDirectoryExists(extractedDir1)
            XCTAssertFileExists(extractedDir1.appending("file2.txt"))
            XCTAssertEqual(
                try? localFileSystem.readFileContents(extractedDir1.appending("file2.txt")),
                "Hello World 2!"
            )

            extractedDir2 = extractedDir1.appending("dir2")
            XCTAssertDirectoryExists(extractedDir2)
            XCTAssertFileExists(extractedDir2.appending("file3.txt"))
            XCTAssertEqual(
                try? localFileSystem.readFileContents(extractedDir2.appending("file3.txt")),
                "Hello World 3!"
            )
            XCTAssertFileExists(extractedDir2.appending("file4.txt"))
            XCTAssertEqual(
                try? localFileSystem.readFileContents(extractedDir2.appending("file4.txt")),
                "Hello World 4!"
            )
        }
    }
}
