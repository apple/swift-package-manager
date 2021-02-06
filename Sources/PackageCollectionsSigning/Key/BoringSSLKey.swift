/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

//===----------------------------------------------------------------------===//
//
// This source file is part of the Vapor open source project
//
// Copyright (c) 2017-2020 Vapor project authors
// Licensed under MIT
//
// See LICENSE for license information
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

#if !(os(macOS) || os(iOS) || os(watchOS) || os(tvOS))
import Foundation

@_implementationOnly import CCryptoBoringSSL

protocol BoringSSLKey {}

extension BoringSSLKey {
    // Source: https://github.com/vapor/jwt-kit/blob/master/Sources/JWTKit/Utilities/OpenSSLSigner.swift
    static func load<Data, T>(pem data: Data,
                              _ closure: (UnsafeMutablePointer<BIO>) -> (T?)) throws -> T where Data: DataProtocol {
        let bytes = data.copyBytes()

        let bio = CCryptoBoringSSL_BIO_new_mem_buf(bytes, -1)
        defer { CCryptoBoringSSL_BIO_free(bio) }

        guard let bioPointer = bio, let result = closure(bioPointer) else {
            throw BoringSSLKeyError.bioConversionFailure
        }

        return result
    }
}

enum BoringSSLKeyError: Error {
    case failedToLoadKeyFromBytes
    case rsaConversionFailure
    case bioConversionFailure
}
#endif
