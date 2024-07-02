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
import struct Basics.Environment
import CoreCommands
import Foundation
import PackageModel
import TSCBasic

extension SwiftPackageCommand {
    struct Install: SwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: "experimental-install",
            abstract: "Offers the ability to install executable products of the current package."
        )

        @OptionGroup()
        var globalOptions: GlobalOptions

        @Option(help: "The name of the executable product to install")
        var product: String?

        func run(_ commandState: SwiftCommandState) throws {
            let swiftpmBinDir = try commandState.fileSystem.getOrCreateSwiftPMInstalledBinariesDirectory()

            let env = Environment.current

            if let path = env[.path], !path.contains(swiftpmBinDir.pathString), !globalOptions.logging.quiet {
                commandState.observabilityScope.emit(
                    warning: """
                    PATH doesn't include \(swiftpmBinDir.pathString)! This means you won't be able to access \
                    the installed executables by default, and will need to specify the full path.
                    """
                )
            }

            let alreadyExisting = (try? InstalledPackageProduct.installedProducts(commandState.fileSystem)) ?? []

            let workspace = try commandState.getActiveWorkspace()
            let packageRoot = try commandState.getPackageRoot()

            let packageGraph = try workspace.loadPackageGraph(
                rootPath: packageRoot,
                observabilityScope: commandState.observabilityScope
            )

            let possibleCandidates = packageGraph.rootPackages.flatMap(\.products)
                .filter { $0.type == .executable }

            let productToInstall: Product

            switch possibleCandidates.count {
            case 0:
                throw StringError("No Executable Products in Package.swift.")
            case 1:
                productToInstall = possibleCandidates[0].underlying
            default:
                guard let product, let first = possibleCandidates.first(where: { $0.name == product }) else {
                    throw StringError(
                        """
                        Multiple candidates found, however, no product was specified. Specify a product with the \
                        `--product` option
                        """
                    )
                }

                productToInstall = first.underlying
            }

            if let existingPkg = alreadyExisting.first(where: { $0.name == productToInstall.name }) {
                throw StringError("\(productToInstall.name) is already installed at \(existingPkg.path)")
            }

            if commandState.options.build.configuration == nil {
                commandState.preferredBuildConfiguration = .release
            }

            try commandState.createBuildSystem(explicitProduct: productToInstall.name, traitConfiguration: .init())
                .build(subset: .product(productToInstall.name))

            let binPath = try commandState.productsBuildParameters.buildPath.appending(component: productToInstall.name)
            let finalBinPath = swiftpmBinDir.appending(component: binPath.basename)
            try commandState.fileSystem.copy(from: binPath, to: finalBinPath)

            print("Executable product `\(productToInstall.name)` was successfully installed to \(finalBinPath).")
        }
    }

    struct Uninstall: SwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: "experimental-uninstall",
            abstract: "Offers the ability to uninstall executable products previously installed by `swift package experimental-install`."
        )

        @OptionGroup
        var globalOptions: GlobalOptions

        @Argument(help: "Name of the executable to uninstall.")
        var name: String

        func run(_ tool: SwiftCommandState) throws {
            let alreadyInstalled = (try? InstalledPackageProduct.installedProducts(tool.fileSystem)) ?? []

            guard let removedExecutable = alreadyInstalled.first(where: { $0.name == name }) else {
                // The installed executable doesn't exist - let the user know, and stop here.
                throw StringError("No such installed executable as \(name)")
            }

            try tool.fileSystem.removeFileTree(removedExecutable.path)
            print("Executable product `\(self.name)` was successfully uninstalled from \(removedExecutable.path).")
        }
    }
}

private struct InstalledPackageProduct {
    static func installedProducts(_ fileSystem: FileSystem) throws -> [InstalledPackageProduct] {
        let binPath = try fileSystem.getOrCreateSwiftPMInstalledBinariesDirectory()

        let contents = ((try? fileSystem.getDirectoryContents(binPath)) ?? [])
            .map { binPath.appending($0) }

        return contents.map { path in
            InstalledPackageProduct(path: .init(path))
        }
    }

    /// The name of this installed product, being the basename of the path.
    var name: String {
        self.path.basename
    }

    /// Path of the executable.
    let path: AbsolutePath
}
