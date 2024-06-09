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

@_spi(SwiftPMInternal)
import CoreCommands

import Workspace
import SPMBuildCore

extension SwiftPackageCommand {
    struct Init: SwiftCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Initialize a new package")

        @OptionGroup(visibility: .hidden)
        var globalOptions: GlobalOptions
        
        @Option(
            name: .customLong("type"),
            help: ArgumentHelp("Package type:", discussion: """
                library           - A package with a library.
                executable        - A package with an executable.
                tool              - A package with an executable that uses
                                    Swift Argument Parser. Use this template if you
                                    plan to have a rich set of command-line arguments.
                build-tool-plugin - A package that vends a build tool plugin.
                command-plugin    - A package that vends a command plugin.
                macro             - A package that vends a macro.
                empty             - An empty package with a Package.swift manifest.
                """))
        var initMode: InitPackage.PackageType = .library

        /// Which testing libraries to use (and any related options.)
        @OptionGroup()
        var testLibraryOptions: TestLibraryOptions

        @Option(name: .customLong("name"), help: "Provide custom package name")
        var packageName: String?

        func run(_ swiftCommandState: SwiftCommandState) throws {
            guard let cwd = swiftCommandState.fileSystem.currentWorkingDirectory else {
                throw InternalError("Could not find the current working directory")
            }

            // NOTE: Do not use testLibraryOptions.enabledTestingLibraries(swiftCommandState:) here
            // because the package doesn't exist yet, so there are no dependencies for it to query.
            var testingLibraries: Set<BuildParameters.Testing.Library> = []
            if testLibraryOptions.enableXCTestSupport {
                testingLibraries.insert(.xctest)
            }
            if testLibraryOptions.explicitlyEnableSwiftTestingLibrarySupport == true
                || testLibraryOptions.explicitlyEnableExperimentalSwiftTestingLibrarySupport == true {
                testingLibraries.insert(.swiftTesting)
            }
            let packageName = self.packageName ?? cwd.basename
            let initPackage = try InitPackage(
                name: packageName,
                packageType: initMode,
                supportedTestingLibraries: testingLibraries,
                destinationPath: cwd,
                installedSwiftPMConfiguration: swiftCommandState.getHostToolchain().installedSwiftPMConfiguration,
                fileSystem: swiftCommandState.fileSystem
            )
            initPackage.progressReporter = { message in
                print(message)
            }
            try initPackage.writePackageStructure()
        }
    }
}

#if swift(<6.0)
extension InitPackage.PackageType: ExpressibleByArgument {}
#else
extension InitPackage.PackageType: @retroactive ExpressibleByArgument {}
#endif
