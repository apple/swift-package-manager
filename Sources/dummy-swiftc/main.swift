// This program can be used as `swiftc` in order to influence `-version` output

import Foundation

import class Basics.AsyncProcess

let info = ProcessInfo.processInfo
let env = info.environment

if info.arguments.last == "-version" {
    if let customSwiftVersion = env["CUSTOM_SWIFT_VERSION"] {
        print(customSwiftVersion)
    } else {
        print("999.0")
    }
} else {
    let swiftPath: String
    if let swiftOriginalPath = env["SWIFT_ORIGINAL_PATH"] {
        swiftPath = swiftOriginalPath
    } else {
        fatalError("need `SWIFT_ORIGINAL_PATH` in the environment")
    }

    let result = try AsyncProcess.popen(arguments: [swiftPath] + info.arguments.dropFirst())
    print(try result.utf8Output())
    print(try result.utf8stderrOutput())
}
