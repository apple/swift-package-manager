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

import protocol Crypto.HashFunction
import struct SystemPackage.FileDescriptor

public struct OpenReadableFile {
    let readChunkSize: Int

    enum FileHandle {
        case local(FileDescriptor)
        case virtual([UInt8])
    }

    let fileHandle: FileHandle

    func read() async throws -> ReadableFileStream {
        switch self.fileHandle {
        case .local(let fileDescriptor):
            ReadableFileStream.local(.init(fileDescriptor: fileDescriptor, readChunkSize: self.readChunkSize))
        case .virtual(let array):
            ReadableFileStream.virtual(.init(bytes: array))
        }
    }

    func hash(with hashFunction: inout some HashFunction) async throws {
        switch self.fileHandle {
        case .local(let fileDescriptor):
            var buffer = [UInt8](repeating: 0, count: readChunkSize)
            var bytesRead = 0
            repeat {
                bytesRead = try buffer.withUnsafeMutableBytes {
                    try fileDescriptor.read(into: $0)
                }

                if bytesRead > 0 {
                    hashFunction.update(data: buffer[0 ..< bytesRead])
                }

            } while bytesRead > 0
        case .virtual(let array):
            hashFunction.update(data: array)
        }
    }
}
