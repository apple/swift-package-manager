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
import PackageGraph
import PackageModel

extension SwiftPackageCommand {
    struct Learn: AsyncSwiftCommand {
        @OptionGroup()
        var globalOptions: GlobalOptions

        static let configuration = CommandConfiguration(abstract: "Learn about Swift and this package")

        func files(fileSystem: FileSystem, in directory: AbsolutePath, fileExtension: String? = nil) throws -> [AbsolutePath] {
            guard fileSystem.isDirectory(directory) else {
                return []
            }

            let files = try fileSystem.getDirectoryContents(directory)
                .map { try AbsolutePath(validating: $0, relativeTo: directory) }
                .filter { fileSystem.isFile($0) }

            guard let fileExtension else {
                return files
            }

            return files.filter { $0.extension == fileExtension }
        }

        func subdirectories(fileSystem: FileSystem, in directory: AbsolutePath) throws -> [AbsolutePath] {
            guard fileSystem.isDirectory(directory) else {
                return []
            }
            return try fileSystem.getDirectoryContents(directory)
                .map { try AbsolutePath(validating: $0, relativeTo: directory) }
                .filter { fileSystem.isDirectory($0) }
        }

        func loadSnippetsAndSnippetGroups(fileSystem: FileSystem, from package: ResolvedPackage) throws -> [SnippetGroup] {
            let snippetsDirectory = package.path.appending("Snippets")
            guard fileSystem.isDirectory(snippetsDirectory) else {
                return []
            }

            let topLevelSnippets = try files(fileSystem: fileSystem, in: snippetsDirectory, fileExtension: "swift")
                .map { try Snippet(parsing: $0) }

            let topLevelSnippetGroup = SnippetGroup(name: "Getting Started",
                                                    baseDirectory: snippetsDirectory,
                                                    snippets: topLevelSnippets,
                                                    explanation: "")

            let subdirectoryGroups = try subdirectories(fileSystem: fileSystem, in: snippetsDirectory)
                .map { subdirectory -> SnippetGroup in
                    let snippets = try files(fileSystem: fileSystem, in: subdirectory, fileExtension: "swift")
                        .map { try Snippet(parsing: $0) }

                    let explanationFile = subdirectory.appending("Explanation.md")

                    let snippetGroupExplanation: String
                    if fileSystem.isFile(explanationFile) {
                        snippetGroupExplanation = try String(contentsOf: explanationFile.asURL)
                    } else {
                        snippetGroupExplanation = ""
                    }

                    return SnippetGroup(name: subdirectory.basename,
                                        baseDirectory: subdirectory,
                                        snippets: snippets,
                                        explanation: snippetGroupExplanation)
                }

            let snippetGroups = [topLevelSnippetGroup] + subdirectoryGroups.sorted {
                $0.baseDirectory.basename < $1.baseDirectory.basename
            }

            return snippetGroups.filter { !$0.snippets.isEmpty }
        }

        func run(_ swiftCommandState: SwiftCommandState) async throws {
            let graph = try swiftCommandState.loadPackageGraph()
            let package = graph.rootPackages[graph.rootPackages.startIndex]
            print(package.products.map { $0.description })

            let snippetGroups = try loadSnippetsAndSnippetGroups(fileSystem: swiftCommandState.fileSystem, from: package)

            var cardStack = CardStack(package: package, snippetGroups: snippetGroups, swiftCommandState: swiftCommandState)

            await cardStack.run()
        }
    }
}
