//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation
import PackageModel
import SPMBuildCore
import PackageLoading

import struct TSCBasic.ByteString
import protocol TSCBasic.HashAlgorithm

import enum TSCUtility.Diagnostics

extension Workspace {
    // marked public for testing
    public struct CustomBinaryArtifactsManager {
        let httpClient: LegacyHTTPClient?
        let archiver: Archiver?

        public init(httpClient: LegacyHTTPClient? = .none, archiver: Archiver? = .none) {
            self.httpClient = httpClient
            self.archiver = archiver
        }
    }

    // marked public since used in tools
    public struct BinaryArtifactsManager: Cancellable {
        public typealias Delegate = BinaryArtifactsManagerDelegate

        private let fileSystem: FileSystem
        private let authorizationProvider: AuthorizationProvider?
        private let hostToolchain: UserToolchain
        private let httpClient: LegacyHTTPClient
        private let archiver: Archiver
        private let checksumAlgorithm: HashAlgorithm
        private let delegate: Delegate?

        public init(
            fileSystem: FileSystem,
            authorizationProvider: AuthorizationProvider?,
            hostToolchain: UserToolchain,
            checksumAlgorithm: HashAlgorithm,
            customHTTPClient: LegacyHTTPClient?,
            customArchiver: Archiver?,
            delegate: Delegate?
        ) {
            self.fileSystem = fileSystem
            self.authorizationProvider = authorizationProvider
            self.hostToolchain = hostToolchain
            self.checksumAlgorithm = checksumAlgorithm
            self.httpClient = customHTTPClient ?? LegacyHTTPClient()
            self.archiver = customArchiver ?? ZipArchiver(fileSystem: fileSystem)
            self.delegate = delegate
        }

        func parseArtifacts(
            from manifests: DependencyManifests,
            observabilityScope: ObservabilityScope
        ) throws -> (local: [ManagedArtifact], remote: [RemoteArtifact]) {
            let packageAndManifests: [(reference: PackageReference, manifest: Manifest)] =
                manifests.root.packages.values + // Root package and manifests.
                manifests.dependencies
                .map { manifest, managed, _, _ in (managed.packageRef, manifest) } // Dependency package and manifests.

            var localArtifacts: [ManagedArtifact] = []
            var remoteArtifacts: [RemoteArtifact] = []

            for (packageReference, manifest) in packageAndManifests {
                for target in manifest.targets where target.type == .binary {
                    if let path = target.path {
                        // TODO: find a better way to get the base path (not via the manifest)
                        let absolutePath = try manifest.path.parentDirectory.appending(RelativePath(validating: path))
                        if absolutePath.extension?.lowercased() == "zip" {
                            localArtifacts.append(
                                .local(
                                    packageRef: packageReference,
                                    targetName: target.name,
                                    path: absolutePath,
                                    kind: .unknown // an archive, we will extract it later
                                )
                            )
                        } else {
                            guard let (artifactPath, artifactKind) = try Self.deriveBinaryArtifact(
                                fileSystem: self.fileSystem,
                                path: absolutePath,
                                observabilityScope: observabilityScope
                            ) else {
                                observabilityScope
                                    .emit(.localArtifactNotFound(artifactPath: absolutePath, targetName: target.name))
                                continue
                            }
                            localArtifacts.append(
                                .local(
                                    packageRef: packageReference,
                                    targetName: target.name,
                                    path: artifactPath,
                                    kind: artifactKind
                                )
                            )
                        }
                    } else if let url = target.url.flatMap(URL.init(string:)), let checksum = target.checksum {
                        remoteArtifacts.append(
                            .init(
                                packageRef: packageReference,
                                targetName: target.name,
                                url: url,
                                checksum: checksum
                            )
                        )
                    } else {
                        throw StringError("a binary target should have either a path or a URL and a checksum")
                    }
                }
            }

            return (local: localArtifacts, remote: remoteArtifacts)
        }

        func download(
            _ artifacts: [RemoteArtifact],
            artifactsDirectory: AbsolutePath,
            observabilityScope: ObservabilityScope
        ) throws -> [ManagedArtifact] {
            let group = DispatchGroup()
            let result = ThreadSafeArrayStore<ManagedArtifact>()

            // zip files to download
            // stored in a thread-safe way as we may fetch more from "artifactbundleindex" files
            let zipArtifacts = ThreadSafeArrayStore<RemoteArtifact>(artifacts.filter {
                $0.url.pathExtension.lowercased() == "zip"
            })

            // fetch and parse "artifactbundleindex" files, if any
            let indexFiles = artifacts.filter { $0.url.pathExtension.lowercased() == "artifactbundleindex" }
            if !indexFiles.isEmpty {
                let errors = ThreadSafeArrayStore<Error>()
                let jsonDecoder = JSONDecoder.makeWithDefaults()
                for indexFile in indexFiles {
                    group.enter()
                    var request = LegacyHTTPClient.Request(method: .get, url: indexFile.url)
                    request.options.validResponseCodes = [200]
                    request.options.authorizationProvider = self.authorizationProvider?.httpAuthorizationHeader(for:)
                    self.httpClient.execute(request) { result in
                        defer { group.leave() }

                        do {
                            switch result {
                            case .failure(let error):
                                throw error
                            case .success(let response):
                                guard let body = response.body else {
                                    throw StringError("Body is empty")
                                }
                                // FIXME: would be nice if checksumAlgorithm.hash took Data directly
                                let bodyChecksum = self.checksumAlgorithm.hash(ByteString(body))
                                    .hexadecimalRepresentation
                                guard bodyChecksum == indexFile.checksum else {
                                    throw StringError(
                                        "checksum of downloaded artifact of binary target '\(indexFile.targetName)' (\(bodyChecksum)) does not match checksum specified by the manifest (\(indexFile.checksum))"
                                    )
                                }
                                let metadata = try jsonDecoder.decode(ArchiveIndexFile.self, from: body)
                                // FIXME: this filter needs to become more sophisticated
                                guard let supportedArchive = metadata.archives
                                    .first(where: {
                                        $0.fileName.lowercased().hasSuffix(".zip") && $0.supportedTriples
                                            .contains(self.hostToolchain.targetTriple)
                                    })
                                else {
                                    throw StringError(
                                        "No supported archive was found for '\(self.hostToolchain.targetTriple.tripleString)'"
                                    )
                                }
                                // add relevant archive
                                zipArtifacts.append(
                                    RemoteArtifact(
                                        packageRef: indexFile.packageRef,
                                        targetName: indexFile.targetName,
                                        url: indexFile.url.deletingLastPathComponent()
                                            .appendingPathComponent(supportedArchive.fileName),
                                        checksum: supportedArchive.checksum
                                    )
                                )
                            }
                        } catch {
                            errors.append(error)
                            observabilityScope.emit(
                                error: "failed retrieving '\(indexFile.url)'",
                                underlyingError: error
                            )
                        }
                    }
                }

                // wait for all "artifactbundleindex" files to be processed
                group.wait()

                // no reason to continue if we already ran into issues
                if !errors.isEmpty {
                    throw Diagnostics.fatalError
                }
            }

            // finally download zip files, if any
            for artifact in zipArtifacts.get() {
                let destinationDirectory = artifactsDirectory
                    .appending(components: [artifact.packageRef.identity.description, artifact.targetName])
                guard observabilityScope
                    .trap({ try fileSystem.createDirectory(destinationDirectory, recursive: true) })
                else {
                    continue
                }

                let archivePath = destinationDirectory.appending(component: artifact.url.lastPathComponent)
                if self.fileSystem.exists(archivePath) {
                    guard observabilityScope.trap({ try self.fileSystem.removeFileTree(archivePath) }) else {
                        continue
                    }
                }

                group.enter()
                var headers = HTTPClientHeaders()
                headers.add(name: "Accept", value: "application/octet-stream")
                var request = LegacyHTTPClient.Request.download(
                    url: artifact.url,
                    headers: headers,
                    fileSystem: self.fileSystem,
                    destination: archivePath
                )
                request.options.authorizationProvider = self.authorizationProvider?.httpAuthorizationHeader(for:)
                request.options.retryStrategy = .exponentialBackoff(maxAttempts: 3, baseDelay: .milliseconds(50))
                request.options.validResponseCodes = [200]

                let downloadStart: DispatchTime = .now()
                self.delegate?.willDownloadBinaryArtifact(from: artifact.url.absoluteString)
                observabilityScope.emit(debug: "downloading \(artifact.url) to \(archivePath)")
                self.httpClient.execute(
                    request,
                    progress: { bytesDownloaded, totalBytesToDownload in
                        self.delegate?.downloadingBinaryArtifact(
                            from: artifact.url.absoluteString,
                            bytesDownloaded: bytesDownloaded,
                            totalBytesToDownload: totalBytesToDownload
                        )
                    },
                    completion: { downloadResult in
                        defer { group.leave() }

                        // TODO: Use the same extraction logic for both remote and local archived artifacts.
                        switch downloadResult {
                        case .success:

                            group.enter()
                            observabilityScope.emit(debug: "validating \(archivePath)")
                            self.archiver.validate(path: archivePath, completion: { validationResult in
                                defer { group.leave() }

                                switch validationResult {
                                case .success(let valid):
                                    guard valid else {
                                        observabilityScope
                                            .emit(.artifactInvalidArchive(
                                                artifactURL: artifact.url,
                                                targetName: artifact.targetName
                                            ))
                                        return
                                    }

                                    guard let archiveChecksum = observabilityScope
                                        .trap({ try self.checksum(forBinaryArtifactAt: archivePath) })
                                    else {
                                        return
                                    }
                                    guard archiveChecksum == artifact.checksum else {
                                        observabilityScope.emit(.artifactInvalidChecksum(
                                            targetName: artifact.targetName,
                                            expectedChecksum: artifact.checksum,
                                            actualChecksum: archiveChecksum
                                        ))
                                        observabilityScope.trap { try self.fileSystem.removeFileTree(archivePath) }
                                        return
                                    }

                                    guard let tempExtractionDirectory = observabilityScope.trap({ () -> AbsolutePath in
                                        let path = artifactsDirectory.appending(
                                            components: "extract",
                                            artifact.packageRef.identity.description,
                                            artifact.targetName,
                                            UUID().uuidString
                                        )
                                        try self.fileSystem.forceCreateDirectory(at: path)
                                        return path
                                    }) else {
                                        return
                                    }

                                    group.enter()
                                    observabilityScope
                                        .emit(debug: "extracting \(archivePath) to \(tempExtractionDirectory)")
                                    self.archiver.extract(
                                        from: archivePath,
                                        to: tempExtractionDirectory,
                                        completion: { extractResult in
                                            defer { group.leave() }

                                            switch extractResult {
                                            case .success:
                                                observabilityScope.trap {
                                                    try self.fileSystem.withLock(
                                                        on: destinationDirectory,
                                                        type: .exclusive
                                                    ) {
                                                        // strip first level component if needed
                                                        if try self.fileSystem.shouldStripFirstLevel(
                                                            archiveDirectory: tempExtractionDirectory,
                                                            acceptableExtensions: BinaryTarget.Kind.allCases
                                                                .map(\.fileExtension)
                                                        ) {
                                                            observabilityScope
                                                                .emit(
                                                                    debug: "stripping first level component from  \(tempExtractionDirectory)"
                                                                )
                                                            try self.fileSystem
                                                                .stripFirstLevel(of: tempExtractionDirectory)
                                                        } else {
                                                            observabilityScope
                                                                .emit(
                                                                    debug: "no first level component stripping needed for \(tempExtractionDirectory)"
                                                                )
                                                        }
                                                        let content = try self.fileSystem
                                                            .getDirectoryContents(tempExtractionDirectory)
                                                        // copy from temp location to actual location
                                                        for file in content {
                                                            let source = tempExtractionDirectory
                                                                .appending(component: file)
                                                            let destination = destinationDirectory
                                                                .appending(component: file)
                                                            if self.fileSystem.exists(destination) {
                                                                try self.fileSystem.removeFileTree(destination)
                                                            }
                                                            try self.fileSystem.copy(from: source, to: destination)
                                                        }
                                                    }
                                                    // remove temp location
                                                    try self.fileSystem.removeFileTree(tempExtractionDirectory)
                                                }

                                                // derive concrete artifact path and type
                                                guard let (artifactPath, artifactKind) = try? Self.deriveBinaryArtifact(
                                                    fileSystem: self.fileSystem,
                                                    path: destinationDirectory,
                                                    observabilityScope: observabilityScope
                                                ) else {
                                                    return observabilityScope
                                                        .emit(.remoteArtifactNotFound(
                                                            artifactURL: artifact.url,
                                                            targetName: artifact.targetName
                                                        ))
                                                }

                                                result.append(
                                                    .remote(
                                                        packageRef: artifact.packageRef,
                                                        targetName: artifact.targetName,
                                                        url: artifact.url.absoluteString,
                                                        checksum: artifact.checksum,
                                                        path: artifactPath,
                                                        kind: artifactKind
                                                    )
                                                )
                                                self.delegate?.didDownloadBinaryArtifact(
                                                    from: artifact.url.absoluteString,
                                                    result: .success(artifactPath),
                                                    duration: downloadStart.distance(to: .now())
                                                )
                                            case .failure(let error):
                                                observabilityScope.emit(.remoteArtifactFailedExtraction(
                                                    artifactURL: artifact.url,
                                                    targetName: artifact.targetName,
                                                    reason: error.interpolationDescription
                                                ))
                                                self.delegate?.didDownloadBinaryArtifact(
                                                    from: artifact.url.absoluteString,
                                                    result: .failure(error),
                                                    duration: downloadStart.distance(to: .now())
                                                )
                                            }

                                            observabilityScope.trap { try self.fileSystem.removeFileTree(archivePath) }
                                        }
                                    )
                                case .failure(let error):
                                    observabilityScope.emit(.artifactFailedValidation(
                                        artifactURL: artifact.url,
                                        targetName: artifact.targetName,
                                        reason: error.interpolationDescription
                                    ))
                                    self.delegate?.didDownloadBinaryArtifact(
                                        from: artifact.url.absoluteString,
                                        result: .failure(error),
                                        duration: downloadStart.distance(to: .now())
                                    )
                                }
                            })
                        case .failure(let error):
                            observabilityScope.trap { try self.fileSystem.removeFileTree(archivePath) }
                            observabilityScope.emit(.artifactFailedDownload(
                                artifactURL: artifact.url,
                                targetName: artifact.targetName,
                                reason: error.interpolationDescription
                            ))
                            self.delegate?.didDownloadBinaryArtifact(
                                from: artifact.url.absoluteString,
                                result: .failure(error),
                                duration: downloadStart.distance(to: .now())
                            )
                        }
                    }
                )
            }

            group.wait()

            if zipArtifacts.count > 0 {
                delegate?.didDownloadAllBinaryArtifacts()
            }

            return result.get()
        }

        func extract(
            _ artifacts: [ManagedArtifact],
            artifactsDirectory: AbsolutePath,
            observabilityScope: ObservabilityScope
        ) throws -> [ManagedArtifact] {
            let result = ThreadSafeArrayStore<ManagedArtifact>()
            let group = DispatchGroup()

            for artifact in artifacts {
                let destinationDirectory = artifactsDirectory
                    .appending(components: [artifact.packageRef.identity.description, artifact.targetName])
                try fileSystem.createDirectory(destinationDirectory, recursive: true)

                let tempExtractionDirectory = artifactsDirectory.appending(
                    components: "extract",
                    artifact.packageRef.identity.description,
                    artifact.targetName,
                    UUID().uuidString
                )
                try self.fileSystem.forceCreateDirectory(at: tempExtractionDirectory)

                group.enter()
                self.archiver.extract(from: artifact.path, to: tempExtractionDirectory, completion: { extractResult in
                    defer { group.leave() }

                    switch extractResult {
                    case .success:
                        observabilityScope.trap { () in
                            try self.fileSystem.withLock(on: destinationDirectory, type: .exclusive) {
                                // strip first level component if needed
                                if try self.fileSystem.shouldStripFirstLevel(
                                    archiveDirectory: tempExtractionDirectory,
                                    acceptableExtensions: BinaryTarget.Kind.allCases.map(\.fileExtension)
                                ) {
                                    observabilityScope
                                        .emit(debug: "stripping first level component from  \(tempExtractionDirectory)")
                                    try self.fileSystem.stripFirstLevel(of: tempExtractionDirectory)
                                } else {
                                    observabilityScope
                                        .emit(
                                            debug: "no first level component stripping needed for \(tempExtractionDirectory)"
                                        )
                                }
                                let content = try self.fileSystem.getDirectoryContents(tempExtractionDirectory)
                                // copy from temp location to actual location
                                for file in content {
                                    let source = tempExtractionDirectory.appending(component: file)
                                    let destination = destinationDirectory.appending(component: file)
                                    if self.fileSystem.exists(destination) {
                                        try self.fileSystem.removeFileTree(destination)
                                    }
                                    try self.fileSystem.copy(from: source, to: destination)
                                }
                            }

                            // remove temp location
                            try self.fileSystem.removeFileTree(tempExtractionDirectory)

                            // derive concrete artifact path and type
                            guard let (artifactPath, artifactKind) = try Self.deriveBinaryArtifact(
                                fileSystem: self.fileSystem,
                                path: destinationDirectory,
                                observabilityScope: observabilityScope
                            ) else {
                                return observabilityScope
                                    .emit(.localArchivedArtifactNotFound(
                                        archivePath: artifact.path,
                                        targetName: artifact.targetName
                                    ))
                            }

                            // compute the checksum
                            let artifactChecksum = try self.checksum(forBinaryArtifactAt: artifact.path)

                            result.append(
                                .local(
                                    packageRef: artifact.packageRef,
                                    targetName: artifact.targetName,
                                    path: artifactPath,
                                    kind: artifactKind,
                                    checksum: artifactChecksum
                                )
                            )
                        }
                    case .failure(let error):
                        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

                        observabilityScope
                            .emit(.localArtifactFailedExtraction(
                                artifactPath: artifact.path,
                                targetName: artifact.targetName,
                                reason: reason
                            ))
                    }
                })
            }

            group.wait()

            return result.get()
        }

        public func checksum(forBinaryArtifactAt path: AbsolutePath) throws -> String {
            // Validate the path has a supported extension.
            guard let pathExtension = path.extension, self.archiver.supportedExtensions.contains(pathExtension) else {
                let supportedExtensionList = self.archiver.supportedExtensions.joined(separator: ", ")
                throw StringError("unexpected file type; supported extensions are: \(supportedExtensionList)")
            }

            // Ensure that the path with the accepted extension is a file.
            guard self.fileSystem.isFile(path) else {
                throw StringError("file not found at path: \(path.pathString)")
            }

            let contents = try self.fileSystem.readFileContents(path)
            return self.checksumAlgorithm.hash(contents).hexadecimalRepresentation
        }

        public func cancel(deadline: DispatchTime) throws {
            try self.httpClient.cancel(deadline: deadline)
            if let cancellableArchiver = self.archiver as? Cancellable {
                try cancellableArchiver.cancel(deadline: deadline)
            }
        }
    }
}

/// Delegate to notify clients about actions being performed by BinaryArtifactsDownloadsManage.
public protocol BinaryArtifactsManagerDelegate {
    /// The workspace has started downloading a binary artifact.
    func willDownloadBinaryArtifact(from url: String)
    /// The workspace has finished downloading a binary artifact.
    func didDownloadBinaryArtifact(
        from url: String,
        result: Result<AbsolutePath, Error>,
        duration: DispatchTimeInterval
    )
    /// The workspace is downloading a binary artifact.
    func downloadingBinaryArtifact(from url: String, bytesDownloaded: Int64, totalBytesToDownload: Int64?)
    /// The workspace finished downloading all binary artifacts.
    func didDownloadAllBinaryArtifacts()
}

extension Workspace.BinaryArtifactsManager {
    struct RemoteArtifact {
        let packageRef: PackageReference
        let targetName: String
        let url: URL
        let checksum: String
    }
}

extension Workspace.BinaryArtifactsManager {
    struct ArchiveIndexFile: Decodable {
        let schemaVersion: String
        let archives: [Archive]

        struct Archive: Decodable {
            let fileName: String
            let checksum: String
            let supportedTriples: [Triple]

            enum CodingKeys: String, CodingKey {
                case fileName
                case checksum
                case supportedTriples
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.fileName = try container.decode(String.self, forKey: .fileName)
                self.checksum = try container.decode(String.self, forKey: .checksum)
                self.supportedTriples = try container.decode([String].self, forKey: .supportedTriples).map(Triple.init)
            }
        }
    }
}

extension Workspace.BinaryArtifactsManager {
    static func deriveBinaryArtifact(
        fileSystem: FileSystem,
        path: AbsolutePath,
        observabilityScope: ObservabilityScope
    ) throws -> (AbsolutePath, BinaryTarget.Kind)? {
        let binaryArtifacts = try Self.deriveBinaryArtifacts(
            fileSystem: fileSystem,
            path: path,
            observabilityScope: observabilityScope
        )
        if binaryArtifacts.count > 1, let binaryArtifact = binaryArtifacts.last {
            // multiple ones, return the last one to preserve old behavior
            observabilityScope
                .emit(
                    warning: "multiple potential binary artifacts found: '\(binaryArtifacts.map(\.0.description).joined(separator: "', '"))', using the one in '\(binaryArtifact.0)'"
                )
            return binaryArtifact
        } else if let binaryArtifact = binaryArtifacts.first {
            // single one
            observabilityScope.emit(info: "found binary artifact: '\(binaryArtifact)'")
            return binaryArtifact
        } else {
            return .none
        }
    }

    private static func deriveBinaryArtifacts(
        fileSystem: FileSystem,
        path: AbsolutePath,
        observabilityScope: ObservabilityScope
    ) throws -> [(AbsolutePath, BinaryTarget.Kind)] {
        guard fileSystem.exists(path) else {
            return []
        }

        let subdirectories = try fileSystem.getDirectoryContents(path)
            .map { path.appending(component: $0) }
            .filter { fileSystem.isDirectory($0) }

        // is the current path it?
        if let kind = try deriveBinaryArtifactKind(
            fileSystem: fileSystem,
            path: path,
            observabilityScope: observabilityScope
        ) {
            return [(path, kind)]
        }

        // try to find a matching subdirectory
        var results = [(AbsolutePath, BinaryTarget.Kind)]()
        for subdirectory in subdirectories {
            observabilityScope.emit(debug: "searching for binary artifact in '\(path)'")
            let subdirectoryResults = try Self.deriveBinaryArtifacts(
                fileSystem: fileSystem,
                path: subdirectory,
                observabilityScope: observabilityScope
            )
            results.append(contentsOf: subdirectoryResults)
        }

        return results
    }

    private static func deriveBinaryArtifactKind(
        fileSystem: FileSystem,
        path: AbsolutePath,
        observabilityScope: ObservabilityScope
    ) throws -> BinaryTarget.Kind? {
        let files = try fileSystem.getDirectoryContents(path)
            .map { path.appending(component: $0) }
            .filter { fileSystem.isFile($0) }

        if let infoPlist = files.first(where: { $0.basename.lowercased() == "info.plist" }) {
            let decoder = PropertyListDecoder()
            do {
                _ = try decoder.decode(XCFrameworkMetadata.self, from: fileSystem.readFileContents(infoPlist))
                return .xcframework
            } catch {
                observabilityScope.emit(debug: "info.plist found in '\(path)' but failed to parse: \(error.interpolationDescription)")
            }
        }

        if let infoJSON = files.first(where: { $0.basename.lowercased() == "info.json" }) {
            do {
                _ = try ArtifactsArchiveMetadata.parse(fileSystem: fileSystem, rootPath: infoJSON.parentDirectory)
                return .libraryArchive
            } catch {
                observabilityScope.emit(
                    debug: "info.json found in '\(path)' but failed to parse",
                    underlyingError: error
                )
            }
        }

        return .none
    }
}

extension FileSystem {
    // helper to decide if an archive directory would benefit from stripping first level
    fileprivate func shouldStripFirstLevel(
        archiveDirectory: AbsolutePath,
        acceptableExtensions: [String]? = nil
    ) throws -> Bool {
        let subdirectories = try self.getDirectoryContents(archiveDirectory)
            .map { archiveDirectory.appending(component: $0) }
            .filter { self.isDirectory($0) }

        // single top-level directory required
        guard subdirectories.count == 1, let rootDirectory = subdirectories.first else {
            return false
        }

        // no acceptable extensions defined, so the single top-level directory is a good candidate
        guard let acceptableExtensions else {
            return true
        }

        // the single top-level directory is already one of the acceptable extensions, so no need to strip
        if rootDirectory.extension.map({ acceptableExtensions.contains($0) }) ?? false {
            return false
        }

        // see if there is "grand-child" directory with one of the acceptable extensions
        return try self.getDirectoryContents(rootDirectory)
            .map { rootDirectory.appending(component: $0) }
            .first { $0.extension.map { acceptableExtensions.contains($0) } ?? false } != nil
    }
}
