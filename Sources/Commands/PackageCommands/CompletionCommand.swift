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
import CoreCommands

import var TSCBasic.stdoutStream

extension SwiftPackageCommand {
    struct CompletionCommand: SwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: "completion-tool",
            abstract: "Completion command (for shell completions)"
        )

        enum Mode: String, CaseIterable, ExpressibleByArgument {
            case generateBashScript = "generate-bash-script"
            case generateZshScript = "generate-zsh-script"
            case generateFishScript = "generate-fish-script"
            case listDependencies = "list-dependencies"
            case listExecutables = "list-executables"
            case listSnippets = "list-snippets"
        }

        /// A dummy version of the root `swift` command, to act as a parent
        /// for all the subcommands.
        fileprivate struct SwiftCommand: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "swift",
                abstract: "The Swift compiler",
                subcommands: [
                    SwiftRunCommand.self,
                    SwiftBuildCommand.self,
                    SwiftTestCommand.self,
                    SwiftPackageCommand.self,
                ]
            )
        }

        @OptionGroup(visibility: .hidden)
        var globalOptions: GlobalOptions

        @Argument(help: "generate-bash-script | generate-zsh-script |\ngenerate-fish-script | list-dependencies | list-executables")
        var mode: Mode

        func run(_ swiftCommandState: SwiftCommandState) throws {
            switch mode {
            case .generateBashScript:
                let script = SwiftCommand.completionScript(for: .bash)
                print(script)
            case .generateZshScript:
                let script = SwiftCommand.completionScript(for: .zsh)
                print(script)
            case .generateFishScript:
                let script = SwiftCommand.completionScript(for: .fish)
                print(script)
            case .listDependencies:
                let graph = try swiftCommandState.loadPackageGraph()
                // command's result output goes on stdout
                // ie "swift package list-dependencies" should output to stdout
                ShowDependencies.dumpDependenciesOf(
                    graph: graph,
                    rootPackage: graph.rootPackages[graph.rootPackages.startIndex],
                    mode: .flatlist,
                    on: TSCBasic.stdoutStream
                )
            case .listExecutables:
                let graph = try swiftCommandState.loadPackageGraph()
                let package = graph.rootPackages[graph.rootPackages.startIndex].underlying
                let executables = package.modules.filter { $0.type == .executable }
                for executable in executables {
                    print(executable.name)
                }
            case .listSnippets:
                let graph = try swiftCommandState.loadPackageGraph()
                let package = graph.rootPackages[graph.rootPackages.startIndex].underlying
                let executables = package.modules.filter { $0.type == .snippet }
                for executable in executables {
                    print(executable.name)
                }
            }
        }
    }
}
