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
import CoreCommands
import PackageModel

package struct RemoveSwiftSDK: SwiftSDKSubcommand {
    package static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: """
        Removes a previously installed Swift SDK bundle from the filesystem.
        """
    )

    @OptionGroup(visibility: .hidden)
    var locations: LocationOptions

    @Argument(help: "Name of the Swift SDK bundle or ID of the Swift SDK to remove from the filesystem.")
    var sdkIDOrBundleName: String

    public init() {}

    func run(
        hostTriple: Triple,
        _ swiftSDKsDirectory: AbsolutePath,
        _ observabilityScope: ObservabilityScope
    ) async throws {
        let artifactBundleDirectory = swiftSDKsDirectory.appending(component: self.sdkIDOrBundleName)

        let removedBundleDirectory: AbsolutePath
        if fileSystem.exists(artifactBundleDirectory) {
            try fileSystem.removeFileTree(artifactBundleDirectory)

            removedBundleDirectory = artifactBundleDirectory
        } else {
            let bundleStore = SwiftSDKBundleStore(
                swiftSDKsDirectory: swiftSDKsDirectory,
                fileSystem: self.fileSystem,
                observabilityScope: observabilityScope,
                outputHandler: { print($0) }
            )

            let bundles = try bundleStore.allValidBundles

            let matchingBundles = bundles.compactMap { bundle in
                bundle.artifacts[sdkIDOrBundleName] != nil ? bundle : nil
            }

            guard !matchingBundles.isEmpty else {
                throw StringError(
                    """
                    Neither a Swift SDK bundle with name `\(self.sdkIDOrBundleName)` nor an \
                    artifact with such ID are currently installed. Use `list` subcommand to see all available \
                    Swift SDKs.
                    """
                )
            }

            guard matchingBundles.count == 1 else {
                let namesOfBundles = matchingBundles.map { "`\($0.name)`" }.joined(separator: ", ")

                throw StringError(
                    """
                    Multiple bundles contain Swift SDKs with ID \(self.sdkIDOrBundleName). Names of these \
                    bundles are: \(namesOfBundles). This will lead to issues when specifying such ID for \
                    building. Delete one of the bundles first by their full name to disambiguate.
                    """
                )
            }

            let matchingBundle = matchingBundles[0]

            // Don't leave an empty bundle and remove the whole thing if it has only a single artifact and that's also
            // matching.
            if matchingBundle.artifacts.count > 1 {
                let otherArtifactIDs = matchingBundle.artifacts.keys
                    .filter { $0 == self.sdkIDOrBundleName }
                    .map { "`\($0)`" }
                    .joined(separator: ", ")

                print(
                    """
                    WARNING: the Swift SDK bundle containing artifact with ID \(self.sdkIDOrBundleName) \
                    also contains other artifacts: \(otherArtifactIDs).
                    """
                )

                print("Would you like to remove the whole bundle with all of its Swift SDKs? (Yes/No): ")
                guard readLine(strippingNewline: true)?.lowercased() == "yes" else {
                    print("Bundle not removed. Exiting...")
                    return
                }
            }

            try fileSystem.removeFileTree(matchingBundle.path)
            removedBundleDirectory = matchingBundle.path
        }

        print("Swift SDK bundle at path `\(removedBundleDirectory)` was successfully removed from the file system.")
    }
}
