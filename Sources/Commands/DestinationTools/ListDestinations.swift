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
import SPMBuildCore
import PackageModel
import TSCBasic

extension DestinationCommand {
    struct ListDestinations: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract:
                """
                Print a list of IDs of available cross-compilation destinations available on the filesystem.
                """
        )

        @OptionGroup()
        public var locations: LocationOptions

        func run() throws {
            let fileSystem = localFileSystem
            let observabilitySystem = ObservabilitySystem(
                SwiftToolObservabilityHandler(outputStream: stdoutStream, logLevel: .warning)
            )
            let observabilityScope = observabilitySystem.topScope

            guard var destinationsDirectory = try fileSystem.getSharedCrossCompilationDestinationsDirectory(
                explicitDirectory: locations.crossCompilationDestinationsDirectory
            ) else {
                let expectedPath = try fileSystem.swiftPMCrossCompilationDestinationsDirectory
                throw StringError(
                    "Couldn't find or create a directory where cross-compilation destinations are stored: \(expectedPath)"
                )
            }

            if !fileSystem.exists(destinationsDirectory) {
                destinationsDirectory = try fileSystem.getOrCreateSwiftPMCrossCompilationDestinationsDirectory()
            }

            // Get absolute paths to available destination bundles.
            let destinationBundles = try fileSystem.getDirectoryContents(destinationsDirectory).filter {
                $0.hasSuffix(BinaryTarget.Kind.artifactsArchive.fileExtension)
            }.map {
                destinationsDirectory.appending(components: [$0])
            }

            // Enumerate available bundles and parse manifests for each of them, then validate supplied destinations.
            for bundlePath in destinationBundles {
                do {
                    let parsedManifest = try ArtifactsArchiveMetadata.parse(
                        fileSystem: fileSystem,
                        rootPath: bundlePath
                    )

                    for (artifactID, artifactMetadata) in parsedManifest.artifacts
                    where artifactMetadata.type == .crossCompilationDestination {
                        for variant in artifactMetadata.variants {
                            let destinationJSONPath = try bundlePath
                                .appending(RelativePath(validating: variant.path))
                                .appending(component: "destination.json")

                            guard fileSystem.exists(destinationJSONPath) else {
                                observabilityScope.emit(
                                    .warning(
                                        """
                                        Destination metadata file not found at \(
                                            destinationJSONPath
                                        ) for a variant of artifact \(artifactID)
                                        """
                                    )
                                )

                                continue
                            }

                            do {
                                _ = try Destination(
                                    fromFile: destinationJSONPath, fileSystem: fileSystem
                                )
                            } catch {
                                observabilityScope.emit(
                                    .warning(
                                        "Couldn't parse destination metadata at \(destinationJSONPath): \(error)"
                                    )
                                )
                            }
                        }

                        print(artifactID)
                    }
                } catch {
                    observabilityScope.emit(
                        .warning(
                            "Couldn't parse `info.json` manifest of a destination bundle at \(bundlePath): \(error)"
                        )
                    )
                }
            }
        }
    }
}
