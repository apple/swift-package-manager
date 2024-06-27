//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import class Dispatch.DispatchQueue
import struct Dispatch.DispatchTime
import struct TSCBasic.FileSystemError

/// An `Archiver` that handles Tar archives using the command-line `tar` tool.
public struct TarArchiver: Archiver {
    public let supportedExtensions: Set<String> = ["tar", "tar.gz"]

    /// The file-system implementation used for various file-system operations and checks.
    private let fileSystem: FileSystem

    /// Helper for cancelling in-flight requests
    private let cancellator: Cancellator

    /// The underlying command
    private let tarCommand: String

    /// Creates a `TarArchiver`.
    ///
    /// - Parameters:
    ///   - fileSystem: The file system to used by the `TarArchiver`.
    ///   - cancellator: Cancellation handler
    public init(fileSystem: FileSystem, cancellator: Cancellator? = .none) {
        self.fileSystem = fileSystem
        self.cancellator = cancellator ?? Cancellator(observabilityScope: .none)

        #if os(Windows)
        self.tarCommand = "tar.exe"
        #else
        self.tarCommand = "tar"
        #endif
    }

    public func extract(
        from archivePath: AbsolutePath,
        to destinationPath: AbsolutePath,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        do {
            guard self.fileSystem.exists(archivePath) else {
                throw FileSystemError(.noEntry, archivePath.underlying)
            }

            guard self.fileSystem.isDirectory(destinationPath) else {
                throw FileSystemError(.notDirectory, destinationPath.underlying)
            }

            let process = AsyncProcess(
                arguments: [self.tarCommand, "zxf", archivePath.pathString, "-C", destinationPath.pathString]
            )

            guard let registrationKey = self.cancellator.register(process) else {
                throw CancellationError.failedToRegisterProcess(process)
            }

            DispatchQueue.sharedConcurrent.async {
                defer { self.cancellator.deregister(registrationKey) }
                completion(.init(catching: {
                    try process.launch()
                    let processResult = try process.waitUntilExit()
                    guard processResult.exitStatus == .terminated(code: 0) else {
                        throw try StringError(processResult.utf8stderrOutput())
                    }
                }))
            }
        } catch {
            return completion(.failure(error))
        }
    }

    public func compress(
        directory: AbsolutePath,
        to destinationPath: AbsolutePath,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        do {
            guard self.fileSystem.isDirectory(directory) else {
                throw FileSystemError(.notDirectory, directory.underlying)
            }

            let process = AsyncProcess(
                arguments: [self.tarCommand, "acf", destinationPath.pathString, directory.basename],
                environment: .current,
                workingDirectory: directory.parentDirectory
            )

            guard let registrationKey = self.cancellator.register(process) else {
                throw CancellationError.failedToRegisterProcess(process)
            }

            DispatchQueue.sharedConcurrent.async {
                defer { self.cancellator.deregister(registrationKey) }
                completion(.init(catching: {
                    try process.launch()
                    let processResult = try process.waitUntilExit()
                    guard processResult.exitStatus == .terminated(code: 0) else {
                        throw try StringError(processResult.utf8stderrOutput())
                    }
                }))
            }
        } catch {
            return completion(.failure(error))
        }
    }

    public func validate(path: AbsolutePath, completion: @escaping @Sendable (Result<Bool, Error>) -> Void) {
        do {
            guard self.fileSystem.exists(path) else {
                throw FileSystemError(.noEntry, path.underlying)
            }

            let process = AsyncProcess(arguments: [self.tarCommand, "tf", path.pathString])
            guard let registrationKey = self.cancellator.register(process) else {
                throw CancellationError.failedToRegisterProcess(process)
            }

            DispatchQueue.sharedConcurrent.async {
                defer { self.cancellator.deregister(registrationKey) }
                completion(.init(catching: {
                    try process.launch()
                    let processResult = try process.waitUntilExit()
                    return processResult.exitStatus == .terminated(code: 0)
                }))
            }
        } catch {
            return completion(.failure(error))
        }
    }

    public func cancel(deadline: DispatchTime) throws {
        try self.cancellator.cancel(deadline: deadline)
    }
}
