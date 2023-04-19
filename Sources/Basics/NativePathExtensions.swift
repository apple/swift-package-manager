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

import Foundation
import struct TSCBasic.AbsolutePath

extension AbsolutePath {
    public func _nativePathString(escaped: Bool) -> String {
        return URL(fileURLWithPath: self.pathString).withUnsafeFileSystemRepresentation {
            let repr = String(cString: $0!)
            if escaped {
                return repr.replacingOccurrences(of: "\\", with: "\\\\")
            }
            return repr
        }
    }
}
