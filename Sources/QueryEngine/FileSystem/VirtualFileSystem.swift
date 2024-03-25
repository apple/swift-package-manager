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

import struct SystemPackage.FilePath

actor VirtualFileSystem: AsyncFileSystem {
    public static let defaultChunkSize = 512 * 1024

    let readChunkSize: Int

    final class Storage {
        init(_ content: [FilePath: [UInt8]]) {
            self.content = content
        }

        var content: [FilePath: [UInt8]]
    }

    private let storage: Storage

    init(content: [FilePath: [UInt8]] = [:], readChunkSize: Int = defaultChunkSize) {
        self.storage = .init(content)
        self.readChunkSize = readChunkSize
    }

    func withOpenReadableFile<T>(_ path: FilePath, _ body: (OpenReadableFile) async throws -> T) async throws -> T {
        guard let bytes = storage.content[path] else {
            throw FileSystemError.fileDoesNotExist(path)
        }
        return try await body(.init(readChunkSize: self.readChunkSize, fileHandle: .virtual(bytes)))
    }

    func withOpenWritableFile<T>(_ path: FilePath, _ body: (OpenWritableFile) async throws -> T) async throws -> T {
        try await body(.init(fileHandle: .virtual(self.storage, path)))
    }
}
