//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct SystemPackage.FileDescriptor
import struct SystemPackage.FilePath

public struct OpenWritableFile {
    enum FileHandle {
        case local(FileDescriptor)
        case virtual(VirtualFileSystem.Storage, FilePath)
    }

    let fileHandle: FileHandle

    func write(_ bytes: some Sequence<UInt8>) async throws {
        switch self.fileHandle {
        case .local(let fileDescriptor):
            _ = try fileDescriptor.writeAll(bytes)
        case .virtual(let storage, let path):
            storage.content[path, default: []].append(contentsOf: bytes)
        }
    }
}
