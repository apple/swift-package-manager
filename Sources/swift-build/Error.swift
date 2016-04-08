/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

enum Error: ErrorProtocol {
    case ManifestAlreadyExists
    case FetchRequired
}

extension Error: CustomStringConvertible {
    var description: String {
        switch self {
        case .ManifestAlreadyExists:
            return "a manifest file already exists in this directory"
        case .FetchRequired:
            return "no packages are checked-out, try: `swift build --fetch'"
        }
    }
}
