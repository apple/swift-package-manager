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
import SourceControl
import struct TSCUtility.Version

public enum PackageArchiver {
    // TODO: filter other unnecessary files, and/or .swiftpmignore file
    private static let ignoredContent: Set<String> = [".build", ".git", ".gitignore", ".swiftpm"]

    public static func archiveSource(
        packageIdentity: PackageIdentity,
        packageVersion: Version,
        packageDirectory: AbsolutePath,
        workingDirectory: AbsolutePath,
        workingFilesToCopy: [String],
        cancellator: Cancellator?,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> AbsolutePath {
        let archivePath = workingDirectory.appending("\(packageIdentity)-\(packageVersion).zip")

        // Create temp location for sources
        let sourceDirectory = workingDirectory.appending(components: "source", "\(packageIdentity)")
        try fileSystem.createDirectory(sourceDirectory, recursive: true)

        let packageContent = try fileSystem.getDirectoryContents(packageDirectory)
        for item in (packageContent.filter { !Self.ignoredContent.contains($0) }) {
            try fileSystem.copy(
                from: packageDirectory.appending(component: item),
                to: sourceDirectory.appending(component: item)
            )
        }

        for item in workingFilesToCopy {
            let replacementPath = workingDirectory.appending(item)
            let replacement = try fileSystem.readFileContents(replacementPath)

            let toBeReplacedPath = sourceDirectory.appending(item)

            observabilityScope.emit(info: "replacing '\(toBeReplacedPath)' with '\(replacementPath)'")
            try fileSystem.writeFileContents(toBeReplacedPath, bytes: replacement)
        }

        try Self.archiveSource(
            at: sourceDirectory,
            to: archivePath,
            fileSystem: fileSystem,
            cancellator: cancellator
        )

        return archivePath
    }

    public static func archiveSource(
        at packageDirectory: AbsolutePath,
        to archivePath: AbsolutePath,
        fileSystem: FileSystem,
        cancellator: Cancellator?
    ) throws {
        let gitRepositoryProvider = GitRepositoryProvider()
        if gitRepositoryProvider.repositoryExists(at: packageDirectory) {
            let repository = GitRepository(path: packageDirectory, cancellator: cancellator)
            try repository.archive(to: archivePath)
        } else {
            let zipArchiver = ZipArchiver(fileSystem: fileSystem, cancellator: cancellator)
            try temp_await {
                zipArchiver.compress(directory: packageDirectory, to: archivePath, completion: $0)
            }
        }
    }
}
