//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2024 Apple Inc. and the Swift project authors
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
import PackageModelSyntax
import SwiftParser
import SwiftSyntax
import TSCBasic
import TSCUtility
import Workspace

extension AddTarget.TestHarness: ExpressibleByArgument { }

extension SwiftPackageCommand {
    struct AddTarget: SwiftCommand {
        /// The type of target that can be specified on the command line.
        enum TargetType: String, Codable, ExpressibleByArgument {
            case library
            case executable
            case test
            case macro
        }

        package static let configuration = CommandConfiguration(
            abstract: "Add a new target to the manifest")

        @OptionGroup(visibility: .hidden)
        var globalOptions: GlobalOptions

        @Argument(help: "The name of the new target")
        var name: String

        @Option(help: "The type of target to add, which can be one of 'library', 'executable', 'test', or 'macro'")
        var type: TargetType = .library

        @Option(
            parsing: .upToNextOption,
            help: "A list of target dependency names"
        )
        var dependencies: [String] = []

        @Option(help: "The URL for a remote binary target")
        var url: String?

        @Option(help: "The path to a local binary target")
        var path: String?

        @Option(help: "The checksum for a remote binary target")
        var checksum: String?

        @Option(help: "The testing library to use when generating test targets, which can be one of 'xctest', 'swift-testing', or 'none'")
        var testingLibrary: PackageModelSyntax.AddTarget.TestHarness = .default

        func run(_ swiftCommandState: SwiftCommandState) throws {
            let workspace = try swiftCommandState.getActiveWorkspace()

            guard let packagePath = try swiftCommandState.getWorkspaceRoot().packages.first else {
                throw StringError("unknown package")
            }

            // Load the manifest file
            let fileSystem = workspace.fileSystem
            let manifestPath = packagePath.appending("Package.swift")
            let manifestContents: ByteString
            do {
                manifestContents = try fileSystem.readFileContents(manifestPath)
            } catch {
                throw StringError("cannot find package manifest in \(manifestPath)")
            }

            // Parse the manifest.
            let manifestSyntax = manifestContents.withData { data in
                data.withUnsafeBytes { buffer in
                    buffer.withMemoryRebound(to: UInt8.self) { buffer in
                        Parser.parse(source: buffer)
                    }
                }
            }

            // Map the target type.
            let type: TargetDescription.TargetKind = switch self.type {
                case .library: .regular
                case .executable: .executable
                case .test: .test
                case .macro: .macro
            }

            // Map dependencies
            let dependencies: [TargetDescription.Dependency] =
                self.dependencies.map {
                    .byName(name: $0, condition: nil)
                }

            let target = try TargetDescription(
                name: name,
                dependencies: dependencies,
                path: path,
                url: url,
                type: type,
                checksum: checksum
            )

            let editResult = try PackageModelSyntax.AddTarget.addTarget(
                target,
                to: manifestSyntax,
                configuration: .init(testHarness: testingLibrary),
                installedSwiftPMConfiguration: swiftCommandState
                  .getHostToolchain()
                  .installedSwiftPMConfiguration
            )

            try editResult.applyEdits(
                to: fileSystem,
                manifest: manifestSyntax,
                manifestPath: manifestPath,
                verbose: !globalOptions.logging.quiet
            )
        }
    }
}

