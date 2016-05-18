/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import func POSIX.getenv
import PackageModel
import Utility
import func libc.exit

// Builds the default target in the llbuild manifest unless specified.
public func build(YAMLPath: String, target: String? = nil) throws {
    do {
        var args = [llbuild, "-f", YAMLPath]
        if let target = target {
            args += [target]
        }
        if verbosity != .Concise { args.append("-v") }
        try system(args)
    } catch {

        // we only check for these error conditions here
        // as it is better to let swift-build-tool figure
        // out its own error conditions and then try
        // to infer what happened afterwards.

        if YAMLPath.isFile {
            throw error
        } else {
            throw Error.BuildYAMLNotFound(YAMLPath)
        }
    }
}
