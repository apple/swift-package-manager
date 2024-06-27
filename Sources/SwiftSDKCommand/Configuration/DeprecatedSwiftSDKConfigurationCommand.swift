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

import ArgumentParser
import Basics
import PackageModel

package struct DeprecatedSwiftSDKConfigurationCommand: ParsableCommand {
    package static let configuration = CommandConfiguration(
        commandName: "configuration",
        abstract: """
        Deprecated: use `swift sdk configure` instead.

        Manages configuration options for installed Swift SDKs.
        """,
        subcommands: [
            ResetConfiguration.self,
            SetConfiguration.self,
            ShowConfiguration.self,
        ]
    )

    package init() {}
}
