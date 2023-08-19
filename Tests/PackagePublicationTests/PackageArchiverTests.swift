//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageModel
import PackagePublication
import SPMTestSupport
import TSCclibc // for SPM_posix_spawn_file_actions_addchdir_np_supported
import Workspace
import XCTest

final class PackageArchiveTests: XCTestCase {
    func testArchiving() throws {
        #if os(Linux)
        // needed for archiving
        guard SPM_posix_spawn_file_actions_addchdir_np_supported() else {
            throw XCTSkip("working directory not supported on this platform")
        }
        #endif

        let observability = ObservabilitySystem.makeForTesting()
        let packageIdentity = PackageIdentity.plain("org.package")

        // git repo
        try withTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("MyPackage")
            try localFileSystem.createDirectory(packageDirectory)

            let initPackage = try InitPackage(
                name: "MyPackage",
                packageType: .executable,
                destinationPath: packageDirectory,
                fileSystem: localFileSystem
            )
            try initPackage.writePackageStructure()
            XCTAssertFileExists(packageDirectory.appending("Package.swift"))

            initGitRepo(packageDirectory)

            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)

            let archivePath = try PackageArchiver.archiveSource(
                packageIdentity: packageIdentity,
                packageVersion: "1.3.5",
                packageDirectory: packageDirectory,
                workingDirectory: workingDirectory,
                workingFilesToCopy: [],
                cancellator: .none,
                fileSystem: localFileSystem,
                observabilityScope: observability.topScope
            )

            try validatePackageArchive(at: archivePath)
            XCTAssertTrue(archivePath.isDescendant(of: workingDirectory))
        }

        // not a git repo
        try withTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("MyPackage")
            try localFileSystem.createDirectory(packageDirectory)

            let initPackage = try InitPackage(
                name: "MyPackage",
                packageType: .executable,
                destinationPath: packageDirectory,
                fileSystem: localFileSystem
            )
            try initPackage.writePackageStructure()
            XCTAssertFileExists(packageDirectory.appending("Package.swift"))

            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)

            let archivePath = try PackageArchiver.archiveSource(
                packageIdentity: packageIdentity,
                packageVersion: "1.5.4",
                packageDirectory: packageDirectory,
                workingDirectory: workingDirectory,
                workingFilesToCopy: [],
                cancellator: .none,
                fileSystem: localFileSystem,
                observabilityScope: observability.topScope
            )

            try validatePackageArchive(at: archivePath)
        }

        let metadataFilename = "package-metadata.json"

        // canonical metadata filename is not on the ignored list
        // and thus should be in the archive
        try withTemporaryDirectory { temporaryDirectory in
            let packageDirectory = temporaryDirectory.appending("MyPackage")
            try localFileSystem.createDirectory(packageDirectory)

            let initPackage = try InitPackage(
                name: "MyPackage",
                packageType: .executable,
                destinationPath: packageDirectory,
                fileSystem: localFileSystem
            )
            try initPackage.writePackageStructure()
            XCTAssertFileExists(packageDirectory.appending("Package.swift"))

            // metadata file
            try localFileSystem.writeFileContents(
                packageDirectory.appending(component: metadataFilename),
                bytes: ""
            )

            let workingDirectory = temporaryDirectory.appending(component: UUID().uuidString)

            let archivePath = try PackageArchiver.archiveSource(
                packageIdentity: packageIdentity,
                packageVersion: "0.3.1",
                packageDirectory: packageDirectory,
                workingDirectory: workingDirectory,
                workingFilesToCopy: [],
                cancellator: .none,
                fileSystem: localFileSystem,
                observabilityScope: observability.topScope
            )

            let extractedPath = try validatePackageArchive(at: archivePath)
            XCTAssertFileExists(extractedPath.appending(component: metadataFilename))
        }
    }

    @discardableResult
    private func validatePackageArchive(at archivePath: AbsolutePath) throws -> AbsolutePath {
        XCTAssertFileExists(archivePath)
        let archiver = ZipArchiver(fileSystem: localFileSystem)
        let extractPath = archivePath.parentDirectory.appending(component: UUID().uuidString)
        try localFileSystem.createDirectory(extractPath)
        try temp_await { archiver.extract(from: archivePath, to: extractPath, completion: $0) }
        try localFileSystem.stripFirstLevel(of: extractPath)
        XCTAssertFileExists(extractPath.appending("Package.swift"))
        return extractPath
    }
}
