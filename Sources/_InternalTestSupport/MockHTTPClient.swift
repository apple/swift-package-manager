//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics

extension LegacyHTTPClient {
    public static func mock(fileSystem: FileSystem) -> LegacyHTTPClient {
        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch request.kind {
            case.generic:
                completion(.success(.okay(body: request.url.absoluteString)))
            case .download(let fileSystem, let destination):
                do {
                    try fileSystem.writeFileContents(
                        destination,
                        string: request.url.absoluteString
                    )
                    completion(.success(.okay(body: request.url.absoluteString)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        return LegacyHTTPClient(handler: handler)
    }
}
