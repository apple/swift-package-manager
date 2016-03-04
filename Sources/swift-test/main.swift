/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import func libc.setenv
import func libc.exit
import Multitool
import Utility

do {
    let dir = try directories()

    let yamlPath = Path.join(dir.build, "debug.yaml")
    guard yamlPath.exists else { throw Error.DebugYAMLNotFound }
    
    try build(YAMLPath: yamlPath, target: "test")
    let success = test(dir.build, "debug")
    exit(success ? 0 : 1)

} catch {
    handleError(error, usage: { _ in })
}
