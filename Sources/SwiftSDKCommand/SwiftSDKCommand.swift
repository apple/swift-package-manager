//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import Basics
    
package struct SwiftSDKCommand: AsyncParsableCommand {
    package static let configuration = CommandConfiguration(
        commandName: "sdk",
        _superCommandName: "swift",
        abstract: "Perform operations on Swift SDKs.",
        version: SwiftVersion.current.completeDisplayString,
        subcommands: [
            ConfigureSwiftSDK.self,
            DeprecatedSwiftSDKConfigurationCommand.self,
            InstallSwiftSDK.self,
            ListSwiftSDKs.self,
            RemoveSwiftSDK.self,
        ],
        helpNames: [.short, .long, .customLong("help", withSingleDash: true)]
    )

    package init() {}
}
