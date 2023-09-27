//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics

import struct Foundation.URL
import protocol TSCBasic.FileSystem
import struct TSCBasic.RegEx

/// Represents an `.artifactbundle` on the filesystem that contains a Swift SDK.
public struct SwiftSDKBundle {
    public struct Variant: Equatable {
        let metadata: ArtifactsArchiveMetadata.Variant
        let swiftSDKs: [SwiftSDK]
    }

    // Path to the bundle root directory.
    public let path: AbsolutePath

    /// Mapping of artifact IDs to variants available for a corresponding artifact.
    public fileprivate(set) var artifacts = [String: [Variant]]()

    /// Name of the Swift SDK bundle that can be used to distinguish it from other bundles.
    public var name: String { path.basename }

    /// Lists all valid Swift SDK bundles in a given directory.
    /// - Parameters:
    ///   - swiftSDKsDirectory: the directory to scan for Swift SDK bundles.
    ///   - fileSystem: the filesystem the directory is located on.
    ///   - observabilityScope: observability scope to report bundle validation errors.
    /// - Returns: an array of valid Swift SDK bundles.
    public static func getAllValidBundles(
        swiftSDKsDirectory: AbsolutePath,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> [Self] {
        // Get absolute paths to available Swift SDK bundles.
        try fileSystem.getDirectoryContents(swiftSDKsDirectory).filter {
            $0.hasSuffix(BinaryTarget.Kind.artifactsArchive.fileExtension)
        }.map {
            swiftSDKsDirectory.appending(components: [$0])
        }.compactMap {
            do {
                // Enumerate available bundles and parse manifests for each of them, then validate supplied
                // Swift SDKs.
                return try Self.parseAndValidate(
                    bundlePath: $0,
                    fileSystem: fileSystem,
                    observabilityScope: observabilityScope
                )
            } catch {
                observabilityScope.emit(
                    warning: "Couldn't parse `info.json` manifest of a Swift SDK bundle at \($0)",
                    underlyingError: error
                )
                return nil
            }
        }
    }

    /// Select a Swift SDK matching a given query and host triple from all Swift SDKs available in a directory.
    /// - Parameters:
    ///   - swiftSDKsDirectory: the directory to scan for Swift SDK bundles.
    ///   - fileSystem: the filesystem the directory is located on.
    ///   - query: either an artifact ID or target triple to filter with.
    ///   - hostTriple: triple of the host building with these Swift SDKs.
    ///   - observabilityScope: observability scope to log warnings about multiple matches.
    /// - Returns: ``SwiftSDK`` value matching `query` either by artifact ID or target triple, `nil` if none found.
    public static func selectBundle(
        fromBundlesAt swiftSDKsDirectory: AbsolutePath?,
        fileSystem: FileSystem,
        matching selector: String,
        hostTriple: Triple,
        observabilityScope: ObservabilityScope
    ) throws -> SwiftSDK {
        guard let swiftSDKsDirectory else {
            throw StringError(
                """
                No directory found for installed Swift SDKs, specify one \
                with `--experimental-swift-sdks-path` option.
                """
            )
        }

        let validBundles = try SwiftSDKBundle.getAllValidBundles(
            swiftSDKsDirectory: swiftSDKsDirectory,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )

        guard !validBundles.isEmpty else {
            throw StringError(
                "No valid Swift SDK bundles found at \(swiftSDKsDirectory)."
            )
        }

        guard var selectedSwiftSDKs = validBundles.selectSwiftSDK(
            matching: selector,
            hostTriple: hostTriple,
            observabilityScope: observabilityScope
        ) else {
            throw StringError(
                """
                No Swift SDK found matching query `\(selector)` and host triple \
                `\(hostTriple.tripleString)`. Use `swift experimental-sdk list` command to see \
                available Swift SDKs.
                """
            )
        }

        selectedSwiftSDKs.applyPathCLIOptions()

        return selectedSwiftSDKs
    }

    /// Installs a Swift SDK bundle from a given path or URL to a Swift SDK installation directory.
    /// - Parameters:
    ///   - bundlePathOrURL: A string passed on the command line, which is either an absolute or relative to a current
    ///   working directory path, or a URL to a Swift SDK artifact bundle.
    ///   - swiftSDKsDirectory: A directory where the Swift SDK artifact bundle should be installed.
    ///   - fileSystem: File system on which all of the file operations should run.
    ///   - observabilityScope: Observability scope for reporting warnings and errors.
    public static func install(
        bundlePathOrURL: String,
        swiftSDKsDirectory: AbsolutePath,
        _ fileSystem: some FileSystem,
        _ archiver: some Archiver,
        _ observabilityScope: ObservabilityScope
    ) async throws {
        let bundleName = try await withTemporaryDirectory(removeTreeOnDeinit: true) { temporaryDirectory in
            let bundlePath: AbsolutePath

            if
                let bundleURL = URL(string: bundlePathOrURL),
                let scheme = bundleURL.scheme,
                scheme == "http" || scheme == "https"
            {
                let bundleName: String
                let fileNameComponent = bundleURL.lastPathComponent
                if fileNameComponent.hasSuffix(".tar.gz") {
                    bundleName = fileNameComponent
                } else {
                    bundleName = "bundle.tar.gz"
                }
                let downloadedBundlePath = temporaryDirectory.appending(component: bundleName)

                let client = HTTPClient()

                var request = HTTPClientRequest.init(method: .head, url: bundleURL)
                request = HTTPClientRequest.download(
                    url: bundleURL,
                    fileSystem: fileSystem,
                    destination: downloadedBundlePath
                )
                request.options.validResponseCodes = [200]

                print("Downloading a Swift SDK bundle archive from `\(bundleURL)`...")

                _ = try await client.execute(
                    request,
                    observabilityScope: observabilityScope,
                    progress: nil
                )

                bundlePath = downloadedBundlePath

                print("Swift SDK bundle successfully downloaded from `\(bundleURL)`.")
            } else if
                let cwd: AbsolutePath = fileSystem.currentWorkingDirectory,
                let originalBundlePath = try? AbsolutePath(validating: bundlePathOrURL, relativeTo: cwd)
            {
                bundlePath = originalBundlePath
            } else {
                throw SwiftSDKError.invalidPathOrURL(bundlePathOrURL)
            }

            return try await installIfValid(
                bundlePath: bundlePath,
                swiftSDKsDirectory: swiftSDKsDirectory,
                temporaryDirectory: temporaryDirectory,
                fileSystem,
                archiver,
                observabilityScope
            )
        }

        print("Swift SDK bundle at `\(bundlePathOrURL)` successfully installed as \(bundleName).")
    }

    /// Unpacks a Swift SDK bundle if it has an archive extension in its filename.
    /// - Parameters:
    ///   - bundlePath: Absolute path to a Swift SDK bundle to unpack if needed.
    ///   - swiftSDKsDirectory: A directory where the Swift SDK artifact bundle should be installed.
    ///   - temporaryDirectory: Absolute path to a temporary directory in which the bundle can be unpacked if needed.
    ///   - fileSystem: A file system to operate on that contains the given paths.
    ///   - archiver: Archiver to use for unpacking.
    /// - Returns: Path to an unpacked Swift SDK bundle if unpacking is needed, value of `bundlePath` is returned
    /// otherwise.
    private static func unpackIfNeeded(
        bundlePath: AbsolutePath,
        swiftSDKsDirectory: AbsolutePath,
        temporaryDirectory: AbsolutePath,
        _ fileSystem: some FileSystem,
        _ archiver: some Archiver
    ) async throws -> AbsolutePath {
        let regex = try RegEx(pattern: "(.+\\.artifactbundle).*")

        guard let bundleName = bundlePath.components.last else {
            throw SwiftSDKError.invalidPathOrURL(bundlePath.pathString)
        }

        guard let unpackedBundleName = regex.matchGroups(in: bundleName).first?.first else {
            throw SwiftSDKError.invalidBundleName(bundleName)
        }

        let installedBundlePath = swiftSDKsDirectory.appending(component: unpackedBundleName)
        guard !fileSystem.exists(installedBundlePath) else {
            throw SwiftSDKError.swiftSDKBundleAlreadyInstalled(bundleName: unpackedBundleName)
        }

        // If there's no archive extension on the bundle name, assuming it's not archived and returning the same path.
        guard !bundlePath.pathString.hasSuffix(".artifactbundle") else {
            return bundlePath
        }

        print("`\(bundlePath)` is assumed to be an archive, unpacking...")
        let extractionResultsDirectory = temporaryDirectory.appending("extraction-results")
        try fileSystem.createDirectory(extractionResultsDirectory)

        try await archiver.extract(from: bundlePath, to: extractionResultsDirectory)

        guard let bundleName = try fileSystem.getDirectoryContents(extractionResultsDirectory).first,
                bundleName.hasSuffix(".artifactbundle")
        else {
            throw SwiftSDKError.invalidBundleArchive(bundlePath)
        }

        let installedBundlePath = destinationsDirectory.appending(component: bundleName)
        guard !fileSystem.exists(installedBundlePath) else {
            throw SwiftSDKError.swiftSDKBundleAlreadyInstalled(bundleName: bundleName)
        }

        return extractionResultsDirectory.appending(component: bundleName)
    }

    /// Installs an unpacked Swift SDK bundle to a Swift SDK installation directory.
    /// - Parameters:
    ///   - bundlePath: absolute path to an unpacked Swift SDK bundle directory.
    ///   - swiftSDKsDirectory: a directory where the Swift SDK bundle should be installed.
    ///   - temporaryDirectory: Temporary directory to use if the bundle is an archive that needs extracting.
    ///   - fileSystem: file system on which all of the file operations should run.
    ///   - archiver: Archiver instance to use for extracting bundle archives.
    ///   - observabilityScope: observability scope for reporting warnings and errors.
    /// - Returns: Name of the bundle installed.
    private static func installIfValid(
        bundlePath: AbsolutePath,
        swiftSDKsDirectory: AbsolutePath,
        temporaryDirectory: AbsolutePath,
        _ fileSystem: some FileSystem,
        _ archiver: some Archiver,
        _ observabilityScope: ObservabilityScope
    ) async throws -> String {
        #if os(macOS)
        // Check the quarantine attribute on bundles downloaded manually in the browser.
        guard !fileSystem.hasAttribute(.quarantine, bundlePath) else {
            throw SwiftSDKError.quarantineAttributePresent(bundlePath: bundlePath)
        }
        #endif

        let unpackedBundlePath = try await unpackIfNeeded(
            bundlePath: bundlePath,
            swiftSDKsDirectory: swiftSDKsDirectory,
            temporaryDirectory: temporaryDirectory,
            fileSystem,
            archiver
        )

        guard
            fileSystem.isDirectory(unpackedBundlePath),
            let bundleName = unpackedBundlePath.components.last
        else {
            throw SwiftSDKError.pathIsNotDirectory(bundlePath)
        }

        let installedBundlePath = swiftSDKsDirectory.appending(component: bundleName)

        let validatedBundle = try Self.parseAndValidate(
            bundlePath: unpackedBundlePath,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )
        let newArtifactIDs = validatedBundle.artifacts.keys

        let installedBundles = try Self.getAllValidBundles(
            swiftSDKsDirectory: swiftSDKsDirectory,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )

        for installedBundle in installedBundles {
            for artifactID in installedBundle.artifacts.keys {
                guard !newArtifactIDs.contains(artifactID) else {
                    throw SwiftSDKError.swiftSDKArtifactAlreadyInstalled(
                        installedBundleName: installedBundle.name,
                        newBundleName: validatedBundle.name,
                        artifactID: artifactID
                    )
                }
            }
        }

        try fileSystem.copy(from: unpackedBundlePath, to: installedBundlePath)

        return bundleName
    }

    /// Parses metadata of an `.artifactbundle` and validates it as a bundle containing
    /// cross-compilation Swift SDKs.
    /// - Parameters:
    ///   - bundlePath: path to the bundle root directory.
    ///   - fileSystem: filesystem containing the bundle.
    ///   - observabilityScope: observability scope to log validation warnings.
    /// - Returns: Validated ``SwiftSDKBundle`` containing validated ``SwiftSDK`` values for
    /// each artifact and its variants.
    private static func parseAndValidate(
        bundlePath: AbsolutePath,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> Self {
        let parsedManifest = try ArtifactsArchiveMetadata.parse(
            fileSystem: fileSystem,
            rootPath: bundlePath
        )

        return try parsedManifest.validateSwiftSDKBundle(
            bundlePath: bundlePath,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )
    }
}

extension ArtifactsArchiveMetadata {
    fileprivate func validateSwiftSDKBundle(
        bundlePath: AbsolutePath,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> SwiftSDKBundle {
        var result = SwiftSDKBundle(path: bundlePath)

        for (artifactID, artifactMetadata) in artifacts {
            if artifactMetadata.type == .crossCompilationDestination {
                observabilityScope.emit(
                    warning: """
                    `crossCompilationDestination` bundle metadata value used for `\(artifactID)` is deprecated, \
                    use `swiftSDK` instead.
                    """
                )
            } else {
                guard artifactMetadata.type == .swiftSDK else { continue }
            }

            var variants = [SwiftSDKBundle.Variant]()

            for variantMetadata in artifactMetadata.variants {
                let variantConfigurationPath = bundlePath
                    .appending(variantMetadata.path)
                    .appending("swift-sdk.json")

                guard fileSystem.exists(variantConfigurationPath) else {
                    observabilityScope.emit(
                        .warning(
                            """
                            Swift SDK metadata file not found at \(
                                variantConfigurationPath
                            ) for a variant of artifact \(artifactID)
                            """
                        )
                    )

                    continue
                }

                do {
                    let swiftSDKs = try SwiftSDK.decode(
                        fromFile: variantConfigurationPath, fileSystem: fileSystem,
                        observabilityScope: observabilityScope
                    )

                    variants.append(.init(metadata: variantMetadata, swiftSDKs: swiftSDKs))
                } catch {
                    observabilityScope.emit(
                        warning: "Couldn't parse Swift SDK artifact metadata at \(variantConfigurationPath)",
                        underlyingError: error
                    )
                }
            }

            result.artifacts[artifactID] = variants
        }

        return result
    }
}

extension [SwiftSDKBundle] {
    /// Select a Swift SDK with a given artifact ID from a `self` array of available Swift SDKs.
    /// - Parameters:
    ///   - id: artifact ID of the Swift SDK to look up.
    ///   - hostTriple: triple of the machine on which the Swift SDK is building.
    ///   - targetTriple: triple of the machine for which the Swift SDK is building.
    /// - Returns: ``SwiftSDK`` value with a given artifact ID, `nil` if none found.
    public func selectSwiftSDK(id: String, hostTriple: Triple, targetTriple: Triple) -> SwiftSDK? {
        for bundle in self {
            for (artifactID, variants) in bundle.artifacts {
                guard artifactID == id else {
                    continue
                }

                for variant in variants {
                    guard variant.metadata.supportedTriples.contains(hostTriple) else {
                        continue
                    }

                    return variant.swiftSDKs.first { $0.targetTriple == targetTriple }
                }
            }
        }

        return nil
    }

    /// Select Swift SDKs matching a given selector and host triple from a `self` array of available Swift SDKs.
    /// - Parameters:
    ///   - selector: either an artifact ID or target triple to filter with.
    ///   - hostTriple: triple of the host building with these Swift SDKs.
    ///   - observabilityScope: observability scope to log warnings about multiple matches.
    /// - Returns: ``SwiftSDK`` value matching `query` either by artifact ID or target triple, `nil` if none found.
    func selectSwiftSDK(
        matching selector: String,
        hostTriple: Triple,
        observabilityScope: ObservabilityScope
    ) -> SwiftSDK? {
        var matchedByID: (path: AbsolutePath, variant: SwiftSDKBundle.Variant, swiftSDK: SwiftSDK)?
        var matchedByTriple: (path: AbsolutePath, variant: SwiftSDKBundle.Variant, swiftSDK: SwiftSDK)?

        for bundle in self {
            for (artifactID, variants) in bundle.artifacts {
                for variant in variants {
                    guard variant.metadata.supportedTriples.contains(where: { variantTriple in
                        hostTriple.isRuntimeCompatible(with: variantTriple)
                    }) else {
                        continue
                    }

                    for swiftSDK in variant.swiftSDKs {
                        if artifactID == selector {
                            if let matchedByID {
                                observabilityScope.emit(
                                    warning:
                                    """
                                    multiple Swift SDKs match ID `\(artifactID)` and host triple \(
                                        hostTriple.tripleString
                                    ), selected one at \(
                                        matchedByID.path.appending(matchedByID.variant.metadata.path)
                                    )
                                    """
                                )
                            } else {
                                matchedByID = (bundle.path, variant, swiftSDK)
                            }
                        }

                        if swiftSDK.targetTriple?.tripleString == selector {
                            if let matchedByTriple {
                                observabilityScope.emit(
                                    warning:
                                    """
                                    multiple Swift SDKs match target triple `\(selector)` and host triple \(
                                        hostTriple.tripleString
                                    ), selected one at \(
                                        matchedByTriple.path.appending(matchedByTriple.variant.metadata.path)
                                    )
                                    """
                                )
                            } else {
                                matchedByTriple = (bundle.path, variant, swiftSDK)
                            }
                        }
                    }
                }
            }
        }

        if let matchedByID, let matchedByTriple, matchedByID != matchedByTriple {
            observabilityScope.emit(
                warning:
                """
                multiple Swift SDKs match the query `\(selector)` and host triple \(
                    hostTriple.tripleString
                ), selected one at \(matchedByID.path.appending(matchedByID.variant.metadata.path))
                """
            )
        }

        return matchedByID?.swiftSDK ?? matchedByTriple?.swiftSDK
    }

    public var sortedArtifactIDs: [String] {
        self.flatMap(\.artifacts.keys).sorted()
    }
}
