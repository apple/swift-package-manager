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

import ArgumentParser
import Basics
import CoreCommands
import PackageModel
import SPMBuildCore

public struct ListSwiftSDKs: SwiftSDKSubcommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract:
        """
        Print a list of IDs of available cross-compilation destinations available on the filesystem.
        """
    )

    @OptionGroup()
    var locations: LocationOptions

    public init() {}

    func run(
        hostTriple: Triple,
        _ swiftSDKsDirectory: AbsolutePath,
        _ observabilityScope: ObservabilityScope
    ) throws {
        let validBundles = try SwiftSDKBundle.getAllValidBundles(
            swiftSDKsDirectory: swiftSDKsDirectory,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )

        guard !validBundles.isEmpty else {
            print("No cross-compilation destinations are currently installed.")
            return
        }

        for bundle in validBundles {
            bundle.artifacts.keys.forEach { print($0) }
        }
    }
}
