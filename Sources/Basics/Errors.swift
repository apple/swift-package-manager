//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import protocol Foundation.LocalizedError
import class Foundation.NSError
import var Foundation.NSLocalizedDescriptionKey
import struct TSCBasic.StringError

public typealias StringError = TSCBasic.StringError

public struct InternalError: Error {
    private let description: String
    public init(_ description: String) {
        assertionFailure(description)
        self.description =
            "Internal error. Please file a bug at https://github.com/swiftlang/swift-package-manager/issues with this info. \(description)"
    }
}

extension Error {
    public var interpolationDescription: String {
        switch self {
        // special case because `LocalizedError` conversion will hide the underlying error
        case let _error as DecodingError:
            return "\(_error)"
        case let _error as LocalizedError:
            var description = _error.errorDescription ?? _error.localizedDescription
            if let recoverySuggestion = _error.recoverySuggestion {
                description += ". \(recoverySuggestion)"
            }
            return description
        case let _error as NSError:
            guard var description = _error.userInfo[NSLocalizedDescriptionKey] as? String else {
                return "\(self)"
            }

            if let localizedRecoverySuggestion = _error.localizedRecoverySuggestion {
                description += ". \(localizedRecoverySuggestion)"
            }
            return description
        default:
            return "\(self)"
        }
    }
}
