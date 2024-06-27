//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Commands
import Foundation

import SwiftSDKCommand
import PackageCollectionsCommand
import PackageRegistryCommand

let firstArg = CommandLine.arguments[0]
let baseNameWithoutExtension = (try? AbsolutePath(validating: firstArg).basenameWithoutExt) ??
    (try? RelativePath(validating: firstArg).basenameWithoutExt)

@main
struct SwiftPM {
    static func main() async {
        // Workaround a bug in Swift 5.9, where multiple executables with an `async` main entrypoint can't be linked
        // into the same test bundle. We're then linking single `swift-package-manager` binary instead and passing
        // executable name via `SWIFTPM_EXEC_NAME`.
        if baseNameWithoutExtension == "swift-package-manager" {
            await main(execName: Environment.current["SWIFTPM_EXEC_NAME"])
        } else {
            await main(execName: baseNameWithoutExtension)
        }
    }

    private static func main(execName: String?) async {
        switch execName {
        case "swift-package":
            await SwiftPackageCommand.main()
        case "swift-build":
            await SwiftBuildCommand.main()
        case "swift-experimental-sdk":
            fputs("warning: `swift experimental-sdk` command is deprecated and will be removed in a future version of SwiftPM. Use `swift sdk` instead.\n", stderr)
            fallthrough
        case "swift-sdk":
            await SwiftSDKCommand.main()
        case "swift-test":
            await SwiftTestCommand.main()
        case "swift-run":
            await SwiftRunCommand.main()
        case "swift-package-collection":
            await PackageCollectionsCommand.main()
        case "swift-package-registry":
            await PackageRegistryCommand.main()
        default:
            fatalError("swift-package-manager launched with unexpected name: \(execName ?? "(unknown)")")
        }
    }
}
