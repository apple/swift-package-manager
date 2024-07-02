//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import Basics
import CoreCommands
import Foundation
import PackageGraph
import PackageLoading
import PackageModel
import SourceControl
import SPMBuildCore
import Workspace
import XCBuildSupport

import enum TSCUtility.Diagnostics

/// swift-package tool namespace
public struct SwiftPackageCommand: AsyncParsableCommand {
    public static var configuration = CommandConfiguration(
        commandName: "package",
        _superCommandName: "swift",
        abstract: "Perform operations on Swift packages",
        discussion: "SEE ALSO: swift build, swift run, swift test",
        version: SwiftVersion.current.completeDisplayString,
        subcommands: [
            AddDependency.self,
            AddProduct.self,
            AddTarget.self,
            AddTargetDependency.self,
            Clean.self,
            PurgeCache.self,
            Reset.self,
            Update.self,
            Describe.self,
            Init.self,
            Format.self,

            Install.self,
            Uninstall.self,
            
            APIDiff.self,
            DeprecatedAPIDiff.self,
            DumpSymbolGraph.self,
            DumpPIF.self,
            DumpPackage.self,

            Edit.self,
            Unedit.self,

            Config.self,
            Resolve.self,
            Fetch.self,

            ShowDependencies.self,
            ToolsVersionCommand.self,
            ComputeChecksum.self,
            ArchiveSource.self,
            CompletionCommand.self,
            PluginCommand.self,

            DefaultCommand.self,
        ]
            + (ProcessInfo.processInfo.environment["SWIFTPM_ENABLE_SNIPPETS"] == "1" ? [Learn.self] : []),
        defaultSubcommand: DefaultCommand.self,
        helpNames: [.short, .long, .customLong("help", withSingleDash: true)]
    )

    @OptionGroup()
    var globalOptions: GlobalOptions

    public static var _errorLabel: String { "error" }

    public init() {}
}

extension SwiftPackageCommand {
    // This command is the default when no other subcommand is passed. It is not shown in the help and is never invoked
    // directly.
    struct DefaultCommand: AsyncSwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: nil,
            shouldDisplay: false
        )

        @OptionGroup(visibility: .hidden)
        var globalOptions: GlobalOptions

        @OptionGroup()
        var pluginOptions: PluginCommand.PluginOptions

        @Argument(parsing: .captureForPassthrough)
        var remaining: [String] = []

        func run(_ swiftCommandState: SwiftCommandState) async throws {
            // See if have a possible plugin command.
            guard let command = remaining.first else {
                print(SwiftPackageCommand.helpMessage())
                return
            }

            // Check for edge cases and unknown options to match the behavior in the absence of plugins.
            if command.isEmpty {
                throw ValidationError("Unknown argument '\(command)'")
            } else if command.starts(with: "-") {
                throw ValidationError("Unknown option '\(command)'")
            }

            // Otherwise see if we can find a plugin.
            try await PluginCommand.run(
                command: command,
                options: self.pluginOptions,
                arguments: self.remaining,
                swiftCommandState: swiftCommandState
            )
        }
    }
}

extension PluginCommand.PluginOptions {
    func merged(with other: Self) -> Self {
        // validate against developer mistake
        assert(
            Mirror(reflecting: self).children.count == 4,
            "Property added to PluginOptions without updating merged(with:)!"
        )
        // actual merge
        var merged = self
        merged.allowWritingToPackageDirectory = merged.allowWritingToPackageDirectory || other
            .allowWritingToPackageDirectory
        merged.additionalAllowedWritableDirectories.append(contentsOf: other.additionalAllowedWritableDirectories)
        if other.allowNetworkConnections != .none {
            merged.allowNetworkConnections = other.allowNetworkConnections
        }
        if other.packageIdentity != nil {
            merged.packageIdentity = other.packageIdentity
        }
        return merged
    }
}
