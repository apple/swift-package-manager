//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct Basics.Triple

extension Triple {
    public func platformBuildPathComponent() -> String {
        if isDarwin() {
            return tripleString(forPlatformVersion: "")
        }

        return tripleString
    }
}

extension Triple {
    public func platformBuildPathComponent(buildSystem: BuildSystemProvider.Kind) -> String {
        // Use "apple" as the subdirectory because in theory Xcode build system
        // can be used to build for any Apple platform and it has its own
        // conventions for build subpaths based on platforms.
        buildSystem == .xcode ? "apple" : self.platformBuildPathComponent()
    }
}
