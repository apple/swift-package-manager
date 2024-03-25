//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import protocol _Concurrency.Actor
import protocol Crypto.HashFunction
import struct SystemPackage.Errno
import struct SystemPackage.FilePath

public protocol AsyncFileSystem: Actor {
    func withOpenReadableFile<T>(_ path: FilePath, _ body: (OpenReadableFile) async throws -> T) async throws -> T
    func withOpenWritableFile<T>(_ path: FilePath, _ body: (OpenWritableFile) async throws -> T) async throws -> T
}

enum FileSystemError: Error {
    case fileDoesNotExist(FilePath)
    case bufferLimitExceeded(FilePath)
    case systemError(FilePath, Errno)
}

extension Error {
    func attach(path: FilePath) -> any Error {
        if let error = self as? Errno {
            FileSystemError.systemError(path, error)
        } else {
            self
        }
    }
}
