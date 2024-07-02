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

// FIXME: can't write `import actor Basics.HTTPClient`, importing the whole module because of that :(
@_spi(SwiftPMInternal)
import Basics
import struct Foundation.URL
import protocol TSCBasic.FileSystem
import struct TSCBasic.RegEx
import protocol TSCUtility.ProgressAnimationProtocol

public final class SwiftSDKBundleStore {
    public enum Output: Equatable, CustomStringConvertible {
        case downloadStarted(URL)
        case downloadFinishedSuccessfully(URL)
        case verifyingChecksum
        case checksumValid
        case unpackingArchive(bundlePathOrURL: String)
        case installationSuccessful(bundlePathOrURL: String, bundleName: String)

        public var description: String {
            switch self {
            case let .downloadStarted(url):
                return "Downloading a Swift SDK bundle archive from `\(url)`..."
            case let .downloadFinishedSuccessfully(url):
                return "Swift SDK bundle archive successfully downloaded from `\(url)`."
            case .verifyingChecksum:
                return "Verifying if checksum of the downloaded archive is valid..."
            case .checksumValid:
                return "Downloaded archive has a valid checksum."
            case let .installationSuccessful(bundlePathOrURL, bundleName):
                return "Swift SDK bundle at `\(bundlePathOrURL)` successfully installed as \(bundleName)."
            case let .unpackingArchive(bundlePathOrURL):
                return "Swift SDK bundle at `\(bundlePathOrURL)` is assumed to be an archive, unpacking..."
            }
        }
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case noMatchingSwiftSDK(selector: String, hostTriple: Triple)

        var description: String {
            switch self {
            case let .noMatchingSwiftSDK(selector, hostTriple):
                return """
                No Swift SDK found matching query `\(selector)` and host triple \
                `\(hostTriple.tripleString)`. Use `swift sdk list` command to see \
                available Swift SDKs.
                """
            }
        }
    }

    /// Directory in which Swift SDKs bundles are stored.
    let swiftSDKsDirectory: AbsolutePath

    /// File system instance used for reading from and writing to SDK bundles stored on it.
    let fileSystem: any FileSystem

    /// Observability scope used for logging.
    private let observabilityScope: ObservabilityScope

    /// Closure invoked for output produced by this store during its operation.
    private let outputHandler: (Output) -> Void

    /// Progress animation used for downloading SDK bundles.
    private let downloadProgressAnimation: ProgressAnimationProtocol?

    public init(
        swiftSDKsDirectory: AbsolutePath,
        fileSystem: any FileSystem,
        observabilityScope: ObservabilityScope,
        outputHandler: @escaping (Output) -> Void,
        downloadProgressAnimation: ProgressAnimationProtocol? = nil
    ) {
        self.swiftSDKsDirectory = swiftSDKsDirectory
        self.fileSystem = fileSystem
        self.observabilityScope = observabilityScope
        self.outputHandler = outputHandler
        self.downloadProgressAnimation = downloadProgressAnimation
    }

    /// An array of valid Swift SDK bundles stored in ``SwiftSDKBundleStore//swiftSDKsDirectory``.
    public var allValidBundles: [SwiftSDKBundle] {
        get throws {
            // Get absolute paths to available Swift SDK bundles.
            try self.fileSystem.getDirectoryContents(swiftSDKsDirectory).filter {
                $0.hasSuffix(BinaryModule.Kind.artifactsArchive.fileExtension)
            }.map {
                self.swiftSDKsDirectory.appending(components: [$0])
            }.compactMap {
                do {
                    // Enumerate available bundles and parse manifests for each of them, then validate supplied
                    // Swift SDKs.
                    return try self.parseAndValidate(bundlePath: $0)
                } catch {
                    observabilityScope.emit(
                        warning: "Couldn't parse `info.json` manifest of a Swift SDK bundle at \($0)",
                        underlyingError: error
                    )
                    return nil
                }
            }
        }
    }

    /// Select a Swift SDK matching a given query and host triple from all Swift SDKs available in
    /// ``SwiftSDKBundleStore//swiftSDKsDirectory``.
    /// - Parameters:
    ///   - query: either an artifact ID or target triple to filter with.
    ///   - hostTriple: triple of the host building with these Swift SDKs.
    /// - Returns: ``SwiftSDK`` value matching `query` either by artifact ID or target triple, `nil` if none found.
    public func selectBundle(
        matching selector: String,
        hostTriple: Triple
    ) throws -> SwiftSDK {
        let validBundles = try self.allValidBundles

        guard !validBundles.isEmpty else {
            throw StringError(
                "No valid Swift SDK bundles found at \(self.swiftSDKsDirectory)."
            )
        }

        guard var selectedSwiftSDKs = validBundles.selectSwiftSDK(
            matching: selector,
            hostTriple: hostTriple,
            observabilityScope: self.observabilityScope
        ) else {
            throw Error.noMatchingSwiftSDK(selector: selector, hostTriple: hostTriple)
        }

        selectedSwiftSDKs.applyPathCLIOptions()

        return selectedSwiftSDKs
    }

    /// Installs a Swift SDK bundle from a given path or URL to ``SwiftSDKBundleStore//swiftSDKsDirectory``.
    /// - Parameters:
    ///   - bundlePathOrURL: A string passed on the command line, which is either an absolute or relative to a current
    ///   working directory path, or a URL to a Swift SDK artifact bundle.
    ///   - archiver: Archiver instance to use for extracting bundle archives.
    public func install(
        bundlePathOrURL: String,
        checksum: String? = nil,
        _ archiver: any Archiver,
        _ httpClient: HTTPClient = .init(),
        hasher: ((_ archivePath: AbsolutePath) throws -> String)? = nil
    ) async throws {
        let bundleName = try await withTemporaryDirectory(fileSystem: self.fileSystem, removeTreeOnDeinit: true) { temporaryDirectory in
            let bundlePath: AbsolutePath

            if
                let bundleURL = URL(string: bundlePathOrURL),
                let scheme = bundleURL.scheme,
                scheme == "http" || scheme == "https"
            {
                guard let checksum, let hasher else {
                    throw SwiftSDKError.checksumNotProvided(bundleURL)
                }

                let bundleName: String
                let fileNameComponent = bundleURL.lastPathComponent
                if archiver.isFileSupported(fileNameComponent) {
                    bundleName = fileNameComponent
                } else {
                    // Assume that the bundle is a tarball if it doesn't have a recognized extension.
                    bundleName = "bundle.tar.gz"
                }
                let downloadedBundlePath = temporaryDirectory.appending(component: bundleName)

                var request = HTTPClientRequest.download(
                    url: bundleURL,
                    fileSystem: self.fileSystem,
                    destination: downloadedBundlePath
                )
                request.options.validResponseCodes = [200]

                self.outputHandler(.downloadStarted(bundleURL))

                _ = try await httpClient.execute(
                    request,
                    observabilityScope: self.observabilityScope,
                    progress: { step, total in
                        guard let progressAnimation = self.downloadProgressAnimation else {
                            return
                        }
                        let step = step > Int.max ? Int.max : Int(step)
                        let total = total.map { $0 > Int.max ? Int.max : Int($0) } ?? step
                        progressAnimation.update(
                          step: step,
                          total: total,
                          text: "Downloading \(bundleURL.lastPathComponent)"
                        )
                    }
                )
                self.downloadProgressAnimation?.complete(success: true)

                self.outputHandler(.downloadFinishedSuccessfully(bundleURL))

                self.outputHandler(.verifyingChecksum)
                let computedChecksum = try hasher(downloadedBundlePath)
                guard computedChecksum == checksum else {
                    throw SwiftSDKError.checksumInvalid(computed: computedChecksum, provided: checksum)
                }
                self.outputHandler(.checksumValid)

                bundlePath = downloadedBundlePath
            } else if
                let cwd: AbsolutePath = self.fileSystem.currentWorkingDirectory,
                let originalBundlePath = try? AbsolutePath(validating: bundlePathOrURL, relativeTo: cwd)
            {
                bundlePath = originalBundlePath
            } else {
                throw SwiftSDKError.invalidPathOrURL(bundlePathOrURL)
            }

            return try await self.installIfValid(
                bundlePathOrURL: bundlePathOrURL,
                validatedBundlePath: bundlePath,
                temporaryDirectory: temporaryDirectory,
                archiver: archiver
            )
        }.value

        self.outputHandler(.installationSuccessful(bundlePathOrURL: bundlePathOrURL, bundleName: bundleName))
    }

    /// Unpacks a Swift SDK bundle if it has an archive extension in its filename.
    /// - Parameters:
    ///   - bundlePath: Absolute path to a Swift SDK bundle to unpack if needed.
    ///   - temporaryDirectory: Absolute path to a temporary directory in which the bundle can be unpacked if needed.
    ///   - archiver: Archiver instance to use for extracting bundle archives.
    /// - Returns: Path to an unpacked Swift SDK bundle if unpacking is needed, value of `bundlePath` is returned
    /// otherwise.
    private func unpackIfNeeded(
        bundlePathOrURL: String,
        validatedBundlePath bundlePath: AbsolutePath,
        temporaryDirectory: AbsolutePath,
        _ archiver: any Archiver
    ) async throws -> AbsolutePath {
        // If there's no archive extension on the bundle name, assuming it's not archived and returning the same path.
        guard !bundlePath.pathString.hasSuffix(".\(artifactBundleExtension)") else {
            return bundlePath
        }

        self.outputHandler(.unpackingArchive(bundlePathOrURL: bundlePathOrURL))
        let extractionResultsDirectory = temporaryDirectory.appending("extraction-results")
        try self.fileSystem.createDirectory(extractionResultsDirectory)

        try await archiver.extract(from: bundlePath, to: extractionResultsDirectory)

        guard let bundleName = try fileSystem.getDirectoryContents(extractionResultsDirectory).first(where: {
            $0.hasSuffix(".\(artifactBundleExtension)") &&
                fileSystem.isDirectory(extractionResultsDirectory.appending($0))
        }) else {
            throw SwiftSDKError.invalidBundleArchive(bundlePath)
        }

        let installedBundlePath = swiftSDKsDirectory.appending(component: bundleName)
        guard !self.fileSystem.exists(installedBundlePath) else {
            throw SwiftSDKError.swiftSDKBundleAlreadyInstalled(bundleName: bundleName)
        }

        return extractionResultsDirectory.appending(component: bundleName)
    }

    /// Installs an unpacked Swift SDK bundle to a Swift SDK installation directory.
    /// - Parameters:
    ///   - bundlePath: absolute path to an unpacked Swift SDK bundle directory.
    ///   - temporaryDirectory: Temporary directory to use if the bundle is an archive that needs extracting.
    ///   - archiver: Archiver instance to use for extracting bundle archives.
    /// - Returns: Name of the bundle installed.
    private func installIfValid(
        bundlePathOrURL: String,
        validatedBundlePath: AbsolutePath,
        temporaryDirectory: AbsolutePath,
        archiver: any Archiver
    ) async throws -> String {
        #if os(macOS)
        // Check the quarantine attribute on bundles downloaded manually in the browser.
        guard !self.fileSystem.hasAttribute(.quarantine, validatedBundlePath) else {
            throw SwiftSDKError.quarantineAttributePresent(bundlePath: validatedBundlePath)
        }
        #endif

        let unpackedBundlePath = try await self.unpackIfNeeded(
            bundlePathOrURL: bundlePathOrURL,
            validatedBundlePath: validatedBundlePath,
            temporaryDirectory: temporaryDirectory,
            archiver
        )

        guard
            self.fileSystem.isDirectory(unpackedBundlePath),
            let bundleName = unpackedBundlePath.components.last
        else {
            throw SwiftSDKError.pathIsNotDirectory(validatedBundlePath)
        }

        let installedBundlePath = self.swiftSDKsDirectory.appending(component: bundleName)

        let validatedBundle = try self.parseAndValidate(bundlePath: unpackedBundlePath)
        let newArtifactIDs = validatedBundle.artifacts.keys

        let installedBundles = try self.allValidBundles

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

        try self.fileSystem.copy(from: unpackedBundlePath, to: installedBundlePath)

        return bundleName
    }

    /// Parses metadata of an `.artifactbundle` and validates it as a bundle containing
    /// cross-compilation Swift SDKs.
    /// - Parameters:
    ///   - bundlePath: path to the bundle root directory.
    /// - Returns: Validated ``SwiftSDKBundle`` containing validated ``SwiftSDK`` values for
    /// each artifact and its variants.
    private func parseAndValidate(bundlePath: AbsolutePath) throws -> SwiftSDKBundle {
        let parsedManifest = try ArtifactsArchiveMetadata.parse(
            fileSystem: self.fileSystem,
            rootPath: bundlePath
        )

        return try self.validateSwiftSDKBundle(
            bundlePath: bundlePath,
            bundleManifest: parsedManifest
        )
    }

    private func validateSwiftSDKBundle(
        bundlePath: AbsolutePath,
        bundleManifest: ArtifactsArchiveMetadata
    ) throws -> SwiftSDKBundle {
        var result = SwiftSDKBundle(path: bundlePath)

        for (artifactID, artifactMetadata) in bundleManifest.artifacts {
            if artifactMetadata.type == .crossCompilationDestination {
                self.observabilityScope.emit(
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

                guard self.fileSystem.exists(variantConfigurationPath) else {
                    self.observabilityScope.emit(
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
