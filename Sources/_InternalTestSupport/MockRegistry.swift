//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation
import PackageFingerprint
import PackageGraph
import PackageLoading
import PackageModel
import PackageRegistry
import PackageSigning

import protocol TSCBasic.HashAlgorithm

import struct TSCUtility.Version

public class MockRegistry {
    private let baseURL: URL
    private let fileSystem: FileSystem
    private let identityResolver: IdentityResolver
    private let checksumAlgorithm: HashAlgorithm
    public var registryClient: RegistryClient!
    private let jsonEncoder: JSONEncoder

    private var packageVersions = [PackageIdentity: [String: InMemoryRegistryPackageSource]]()
    private var packagesSourceControlURLs = [PackageIdentity: [URL]]()
    private var sourceControlURLs = [URL: PackageIdentity]()
    private let packagesLock = NSLock()

    public init(
        filesystem: FileSystem,
        identityResolver: IdentityResolver,
        checksumAlgorithm: HashAlgorithm,
        fingerprintStorage: PackageFingerprintStorage,
        signingEntityStorage: PackageSigningEntityStorage,
        customBaseURL: URL? = .none
    ) {
        self.fileSystem = filesystem
        self.identityResolver = identityResolver
        self.checksumAlgorithm = checksumAlgorithm
        self.jsonEncoder = JSONEncoder.makeWithDefaults()

        var configuration = RegistryConfiguration()
        if let customBaseURL {
            self.baseURL = customBaseURL

        } else {
            self.baseURL = URL("http://localhost/registry/mock")
        }
        configuration.defaultRegistry = .init(url: self.baseURL, supportsAvailability: false)
        configuration.security = .testDefault

        self.registryClient = RegistryClient(
            configuration: configuration,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .strict,
            skipSignatureValidation: false,
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: .strict,
            authorizationProvider: .none,
            customHTTPClient: LegacyHTTPClient(handler: self.httpHandler),
            customArchiverProvider: { fileSystem in MockRegistryArchiver(fileSystem: fileSystem) },
            delegate: .none,
            checksumAlgorithm: checksumAlgorithm
        )
    }

    public func addPackage(
        identity: PackageIdentity,
        versions: [Version],
        sourceControlURLs: [URL]? = .none,
        source: InMemoryRegistryPackageSource
    ) {
        self.addPackage(
            identity: identity,
            versions: versions.map(\.description),
            sourceControlURLs: sourceControlURLs,
            source: source
        )
    }

    public func addPackage(
        identity: PackageIdentity,
        versions: [String],
        sourceControlURLs: [URL]? = .none,
        source: InMemoryRegistryPackageSource
    ) {
        self.packagesLock.withLock {
            // versions
            var updatedVersions = self.packageVersions[identity] ?? [:]
            for version in versions {
                updatedVersions[version.description] = source
            }
            self.packageVersions[identity] = updatedVersions
            // source control URLs
            if let sourceControlURLs {
                var packageSourceControlURLs = self.packagesSourceControlURLs[identity] ?? []
                packageSourceControlURLs.append(contentsOf: sourceControlURLs)
                self.packagesSourceControlURLs[identity] = packageSourceControlURLs
                // reverse index
                for sourceControlURL in sourceControlURLs {
                    self.sourceControlURLs[sourceControlURL] = identity
                }
            }
        }
    }

    func httpHandler(
        request: LegacyHTTPClient.Request,
        progress: LegacyHTTPClient.ProgressHandler?,
        completion: @escaping (Result<LegacyHTTPClient.Response, Error>) -> Void
    ) {
        do {
            guard request.url.absoluteString.hasPrefix(self.baseURL.absoluteString) else {
                throw StringError("url outside mock registry \(self.baseURL)")
            }

            switch request.kind {
            case .generic:
                let response = try self.handleRequest(request: request)
                completion(.success(response))
            case .download(let fileSystem, let destination):
                let response = try self.handleDownloadRequest(
                    request: request,
                    progress: progress,
                    fileSystem: fileSystem,
                    destination: destination
                )
                completion(.success(response))
            }
        } catch {
            completion(.failure(error))
        }
    }

    private func handleRequest(request: LegacyHTTPClient.Request) throws -> LegacyHTTPClient.Response {
        let routeComponents = request.url.absoluteString.dropFirst(self.baseURL.absoluteString.count + 1)
            .split(separator: "/")
        switch routeComponents.count {
        case _ where routeComponents[0].hasPrefix("identifiers?url="):
            guard let query = request.url.query else {
                throw StringError("invalid url: \(request.url)")
            }
            guard let sourceControlURL = URL(string: String(query.dropFirst(4))) else {
                throw StringError("invalid url query: \(query)")
            }
            return try self.getIdentifiers(url: sourceControlURL)
        case 2:
            let package = PackageIdentity.plain(routeComponents.joined(separator: "."))
            return try self.getPackageMetadata(packageIdentity: package)
        case 3:
            let package = PackageIdentity.plain(routeComponents[0 ... 1].joined(separator: "."))
            let version = String(routeComponents[2])
            return try self.getVersionMetadata(packageIdentity: package, version: version)
        case 4 where routeComponents[3] == "Package.swift":
            let package = PackageIdentity.plain(routeComponents[0 ... 1].joined(separator: "."))
            let version = String(routeComponents[2])
            guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else {
                throw StringError("invalid url: \(request.url)")
            }
            let toolsVersion = components.queryItems?.first(where: { $0.name == "swift-version" })?.value
                .flatMap(ToolsVersion.init(string:))
            return try self.getManifest(packageIdentity: package, version: version, toolsVersion: toolsVersion)
        default:
            throw StringError("unknown request \(request.url)")
        }
    }

    private func getPackageMetadata(packageIdentity: PackageIdentity) throws -> HTTPClientResponse {
        guard let registryIdentity = packageIdentity.registry else {
            throw StringError("invalid package identifier '\(packageIdentity)'")
        }

        let versions = self.packageVersions[packageIdentity] ?? [:]
        let metadata = RegistryClient.Serialization.PackageMetadata(
            releases: versions.keys
                .reduce(into: [String: RegistryClient.Serialization.PackageMetadata.Release]()) { partial, item in
                    partial[item] =
                        .init(
                            url: "\(self.baseURL.absoluteString)/\(registryIdentity.scope)/\(registryIdentity.name)/\(item)"
                        )
                }
        )

        /*
         <https://github.com/mona/LinkedList>; rel="canonical",
         <ssh://git@github.com:mona/LinkedList.git>; rel="alternate"
         */
        let sourceControlURLs = self.packagesSourceControlURLs[packageIdentity]
        let links = sourceControlURLs?.map { url in
            "<\(url.absoluteString)>; rel=alternate"
        }.joined(separator: ", ")

        var headers = HTTPClientHeaders()
        headers.add(name: "Content-Version", value: "1")
        headers.add(name: "Content-Type", value: "application/json")
        if let links {
            headers.add(name: "Link", value: links)
        }

        return try HTTPClientResponse(
            statusCode: 200,
            headers: headers,
            body: self.jsonEncoder.encode(metadata)
        )
    }

    private func getVersionMetadata(packageIdentity: PackageIdentity, version: String) throws -> HTTPClientResponse {
        guard let package = self.packageVersions[packageIdentity]?[version] else {
            return .notFound()
        }

        let zipfileContent = try self.zipFileContent(
            packageIdentity: packageIdentity,
            version: version,
            source: package
        )
        let zipfileChecksum = self.checksumAlgorithm.hash(zipfileContent)

        let metadata = RegistryClient.Serialization.VersionMetadata(
            id: packageIdentity.description,
            version: version,
            resources: [
                .init(
                    name: "source-archive",
                    type: "application/zip",
                    checksum: zipfileChecksum.hexadecimalRepresentation,
                    signing: nil
                ),
            ],
            metadata: .init(
                description: "\(packageIdentity) description",
                readmeURL: "http://\(packageIdentity)/readme"
            ),
            publishedAt: Date()
        )

        var headers = HTTPClientHeaders()
        headers.add(name: "Content-Version", value: "1")
        headers.add(name: "Content-Type", value: "application/json")

        return try HTTPClientResponse(
            statusCode: 200,
            headers: headers,
            body: self.jsonEncoder.encode(metadata)
        )
    }

    private func getManifest(
        packageIdentity: PackageIdentity,
        version: String,
        toolsVersion: ToolsVersion? = .none
    ) throws -> HTTPClientResponse {
        guard let package = self.packageVersions[packageIdentity]?[version] else {
            return .notFound()
        }

        let filename: String
        if let toolsVersion {
            filename = Manifest.basename + "@swift-\(toolsVersion).swift"
        } else {
            filename = Manifest.basename + ".swift"
        }

        let content: Data = try package.fileSystem.readFileContents(package.path.appending(component: filename))

        var headers = HTTPClientHeaders()
        headers.add(name: "Content-Version", value: "1")
        headers.add(name: "Content-Type", value: "text/x-swift")

        return HTTPClientResponse(
            statusCode: 200,
            headers: headers,
            body: content
        )
    }

    private func getIdentifiers(url: URL) throws -> HTTPClientResponse {
        let identifiers = self.sourceControlURLs[url].map { [$0.description] } ?? []

        let packageIdentifiers = RegistryClient.Serialization.PackageIdentifiers(
            identifiers: identifiers
        )

        var headers = HTTPClientHeaders()
        headers.add(name: "Content-Version", value: "1")
        headers.add(name: "Content-Type", value: "application/json")

        return HTTPClientResponse(
            statusCode: 200,
            headers: headers,
            body: try self.jsonEncoder.encode(packageIdentifiers)
        )
    }

    private func handleDownloadRequest(
        request: LegacyHTTPClient.Request,
        progress: LegacyHTTPClient.ProgressHandler?,
        fileSystem: FileSystem,
        destination: AbsolutePath
    ) throws -> HTTPClientResponse {
        let routeComponents = request.url.absoluteString.dropFirst(self.baseURL.absoluteString.count + 1)
            .split(separator: "/")
        guard routeComponents.count == 3, routeComponents[2].hasSuffix(".zip") else {
            throw StringError("invalid request \(request.url), expecting zip suffix")
        }

        let packageIdentity = PackageIdentity.plain(routeComponents[0 ... 1].joined(separator: "."))
        let version = String(routeComponents[2].dropLast(4))

        guard let package = self.packageVersions[packageIdentity]?[version] else {
            return .notFound()
        }

        if !fileSystem.exists(destination.parentDirectory) {
            try fileSystem.createDirectory(destination.parentDirectory, recursive: true)
        }

        let zipfileContent = try self.zipFileContent(
            packageIdentity: packageIdentity,
            version: version,
            source: package
        )
        try fileSystem.writeFileContents(destination, string: zipfileContent)

        var headers = HTTPClientHeaders()
        headers.add(name: "Content-Version", value: "1")
        headers.add(name: "Content-Type", value: "application/zip")

        return HTTPClientResponse(
            statusCode: 200,
            headers: headers
        )
    }

    private func zipFileContent(
        packageIdentity: PackageIdentity,
        version: String,
        source: InMemoryRegistryPackageSource
    ) throws -> String {
        var content = "\(packageIdentity)_\(version)\n"
        content += source.path.pathString + "\n"
        for file in try source.listFiles() {
            content += file.pathString + "\n"
        }
        return content
    }
}

public struct InMemoryRegistryPackageSource {
    let fileSystem: FileSystem
    public let path: AbsolutePath

    public init(fileSystem: FileSystem, path: AbsolutePath, writeContent: Bool = true) {
        self.fileSystem = fileSystem
        self.path = path
    }

    public func writePackageContent(targets: [String] = [], toolsVersion: ToolsVersion = .current) throws {
        try self.fileSystem.createDirectory(self.path, recursive: true)
        let sourcesDir = self.path.appending("Sources")
        for target in targets {
            let targetDir = sourcesDir.appending(component: target)
            try self.fileSystem.createDirectory(targetDir, recursive: true)
            try self.fileSystem.writeFileContents(targetDir.appending("file.swift"), bytes: "")
        }
        let manifestPath = self.path.appending(component: Manifest.filename)
        try self.fileSystem.writeFileContents(manifestPath, string: "// swift-tools-version:\(toolsVersion)")
    }

    public func listFiles(root: AbsolutePath? = .none) throws -> [AbsolutePath] {
        var files = [AbsolutePath]()
        let root = root ?? self.path
        let entries = try self.fileSystem.getDirectoryContents(root)
        for entry in entries.map({ root.appending(component: $0) }) {
            if self.fileSystem.isDirectory(entry) {
                let directoryFiles = try self.listFiles(root: entry)
                files.append(contentsOf: directoryFiles)
            } else if self.fileSystem.isFile(entry) {
                files.append(entry)
            } else {
                throw StringError("invalid entry type")
            }
        }
        return files
    }
}

private struct MockRegistryArchiver: Archiver {
    let supportedExtensions = Set<String>(["zip"])
    let fileSystem: FileSystem

    init(fileSystem: FileSystem) {
        self.fileSystem = fileSystem
    }

    func extract(
        from archivePath: AbsolutePath,
        to destinationPath: AbsolutePath,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            let lines = try self.readFileContents(archivePath)
            guard lines.count >= 2 else {
                throw StringError("invalid mock zip format, not enough lines")
            }
            let rootPath = lines[1]
            for path in lines[2 ..< lines.count] {
                let relativePath = String(path.dropFirst(rootPath.count + 1))
                let targetPath = try AbsolutePath(
                    validating: relativePath,
                    relativeTo: destinationPath.appending("package")
                )
                if !self.fileSystem.exists(targetPath.parentDirectory) {
                    try self.fileSystem.createDirectory(targetPath.parentDirectory, recursive: true)
                }
                try self.fileSystem.copy(from: try AbsolutePath(validating: path), to: targetPath)
            }
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    func compress(
        directory: AbsolutePath,
        to destinationPath: AbsolutePath,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        fatalError("not implemented")
    }

    func validate(path: AbsolutePath, completion: @escaping (Result<Bool, Error>) -> Void) {
        do {
            let lines = try self.readFileContents(path)
            completion(.success(lines.count >= 2))
        } catch {
            completion(.failure(error))
        }
    }

    private func readFileContents(_ path: AbsolutePath) throws -> [String] {
        let content: String = try self.fileSystem.readFileContents(path)
        return content.split(whereSeparator: { $0.isNewline }).map(String.init)
    }
}

extension RegistryConfiguration.Security {
    public static let testDefault: RegistryConfiguration.Security = {
        var signing = RegistryConfiguration.Security.Signing()
        signing.onUnsigned = .silentAllow
        signing.onUntrustedCertificate = .silentAllow

        var security = RegistryConfiguration.Security()
        security.default.signing = signing
        return security
    }()
}
