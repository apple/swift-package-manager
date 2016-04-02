/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import func libc.exit
import Multitool
import Utility
import func POSIX.chdir

do {
    let args = Array(Process.arguments.dropFirst())
    let (mode, opts) = try parse(commandLineArguments: args)
    if let dir = opts.chdir {
        try chdir(dir)
    }

    switch mode {
    case .Usage:
        usage()
    case .Run(let xctestArg):
        let dir = try directories()
        let yamlPath = Path.join(dir.build, "debug.yaml")
        guard yamlPath.exists else { throw Error.DebugYAMLNotFound }

        try build(YAMLPath: yamlPath, target: "test")
        let success = try test(dir.build, "debug", xctestArg: xctestArg)
        exit(success ? 0 : 1)
    }
} catch {
    handleError(error, usage: usage)
}
