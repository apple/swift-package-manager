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

extension SwiftPackageCommand {
    struct AddProduct: SwiftCommand {
        /// The package product type used for the command-line. This is a
        /// subset of `ProductType` that expands out the library types.
        enum CommandProductType: String, Codable, ExpressibleByArgument {
            case executable
            case library
            case staticLibrary = "static-library"
            case dynamicLibrary = "dynamic-library"
            case plugin
        }

        package static let configuration = CommandConfiguration(
            abstract: "Add a new product to the manifest")

        @OptionGroup(visibility: .hidden)
        var globalOptions: GlobalOptions

        @Argument(help: "The name of the new product")
        var name: String

        @Option(help: "The type of target to add, which can be one of 'executable', 'library', 'static-library', 'dynamic-library', or 'plugin'")
        var type: CommandProductType = .library

        @Option(
            parsing: .upToNextOption,
            help: "A list of targets that are part of this product"
        )
        var targets: [String] = []

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

            // Map the product type.
            let type: ProductType = switch self.type {
            case .executable: .executable
            case .library: .library(.automatic)
            case .dynamicLibrary: .library(.dynamic)
            case .staticLibrary: .library(.static)
            case .plugin: .plugin
            }

            let product = try ProductDescription(
                name: name,
                type: type,
                targets: targets
            )

            let editResult = try PackageModelSyntax.AddProduct.addProduct(
                product,
                to: manifestSyntax
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

