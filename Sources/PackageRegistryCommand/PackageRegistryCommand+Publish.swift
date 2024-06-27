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
import Commands
import CoreCommands
import Foundation
import PackageModel
import PackageRegistry
import PackageSigning
import Workspace

#if USE_IMPL_ONLY_IMPORTS
@_implementationOnly import X509 // FIXME: need this import or else SwiftSigningIdentity initializer fails
#else
import X509
#endif

import struct TSCBasic.ByteString
import struct TSCBasic.RegEx
import struct TSCBasic.SHA256

import struct TSCUtility.Version

extension PackageRegistryCommand {
    struct Publish: AsyncSwiftCommand {
        static let metadataFilename = "package-metadata.json"

        static let configuration = CommandConfiguration(
            abstract: "Publish to a registry"
        )

        @OptionGroup(visibility: .hidden)
        var globalOptions: GlobalOptions

        @Argument(help: .init("The package identifier.", valueName: "package-id"))
        var packageIdentity: PackageIdentity

        @Argument(help: .init("The package release version being created.", valueName: "package-version"))
        var packageVersion: Version

        @Option(name: [.customLong("url"), .customLong("registry-url")], help: "The registry URL.")
        var registryURL: URL?

        @Option(
            name: .customLong("scratch-directory"),
            help: "The path of the directory where working file(s) will be written."
        )
        var customWorkingDirectory: AbsolutePath?

        @Option(
            name: .customLong("metadata-path"),
            help: "The path to the package metadata JSON file if it is not '\(Self.metadataFilename)' in the package directory."
        )
        var customMetadataPath: AbsolutePath?

        @Option(help: .hidden) // help: "Signature format identifier. Defaults to 'cms-1.0.0'.
        var signatureFormat: SignatureFormat = .cms_1_0_0

        @Option(
            help: "The label of the signing identity to be retrieved from the system's identity store if supported."
        )
        var signingIdentity: String?

        @Option(help: "The path to the certificate's PKCS#8 private key (DER-encoded).")
        var privateKeyPath: AbsolutePath?

        @Option(
            name: .customLong("cert-chain-paths"),
            parsing: .upToNextOption,
            help: "Path(s) to the signing certificate (DER-encoded) and optionally the rest of the certificate chain. Certificates should be ordered with the leaf first and the root last."
        )
        var certificateChainPaths: [AbsolutePath] = []

        @Flag(name: .customLong("allow-insecure-http"), help: "Allow using a non-HTTPS registry URL")
        var allowInsecureHTTP: Bool = false

        @Flag(help: "Dry run only; prepare the archive and sign it but do not publish to the registry.")
        var dryRun: Bool = false

        func run(_ swiftCommandState: SwiftCommandState) async throws {
            // Require both local and user-level registries config
            let configuration = try getRegistriesConfig(swiftCommandState, global: false).configuration

            // validate package location
            let packageDirectory = try self.globalOptions.locations.packageDirectory ?? swiftCommandState.getPackageRoot()
            guard localFileSystem.isDirectory(packageDirectory) else {
                throw StringError("No package found at '\(packageDirectory)'.")
            }

            // validate package identity
            guard let registryIdentity = self.packageIdentity.registry else {
                throw ValidationError.invalidPackageIdentity(self.packageIdentity)
            }

            // compute and validate registry URL
            let registryURL = self.registryURL ?? configuration.registry(for: registryIdentity.scope)?.url
            guard let registryURL else {
                throw ValidationError.unknownRegistry
            }

            let allowHTTP = try self.allowInsecureHTTP && (configuration.authentication(for: registryURL) == nil)
            try registryURL.validateRegistryURL(allowHTTP: allowHTTP)

            // validate working directory path
            if let customWorkingDirectory {
                guard localFileSystem.isDirectory(customWorkingDirectory) else {
                    throw StringError("Directory not found at '\(customWorkingDirectory)'.")
                }
            }

            let workingDirectory = self.customWorkingDirectory ?? Workspace.DefaultLocations
                .scratchDirectory(forRootPackage: packageDirectory).appending(components: ["registry", "publish"])
            if localFileSystem.exists(workingDirectory) {
                try localFileSystem.removeFileTree(workingDirectory)
            }
            // Make sure the working directory exists
            try localFileSystem.createDirectory(workingDirectory, recursive: true)

            // validate custom metadata path
            let defaultMetadataPath = packageDirectory.appending(component: Self.metadataFilename)
            var metadataLocation: MetadataLocation? = .none
            if let customMetadataPath {
                guard localFileSystem.exists(customMetadataPath) else {
                    throw StringError("Metadata file not found at '\(customMetadataPath)'.")
                }
                metadataLocation = .external(customMetadataPath)
            } else if localFileSystem.exists(defaultMetadataPath) {
                metadataLocation = .sourceTree(defaultMetadataPath)
            }

            guard let authorizationProvider = try swiftCommandState.getRegistryAuthorizationProvider() else {
                throw ValidationError.unknownCredentialStore
            }

            let registryClient = RegistryClient(
                configuration: configuration,
                fingerprintStorage: .none,
                fingerprintCheckingMode: .strict,
                skipSignatureValidation: false,
                signingEntityStorage: .none,
                signingEntityCheckingMode: .strict,
                authorizationProvider: authorizationProvider,
                delegate: .none,
                checksumAlgorithm: SHA256()
            )

            // step 1: publishing configuration
            let signingRequired = self.signingIdentity != nil || self.privateKeyPath != nil || !self
                .certificateChainPaths.isEmpty

            let archivePath: AbsolutePath
            var archiveSignature: [UInt8]? = .none
            var metadataSignature: [UInt8]? = .none
            if signingRequired {
                // step 2: generate source archive (includes signed manifests) for the package release
                // step 3: sign source archive and metadata
                let signingMode = try PackageArchiveSigner.computeSigningMode(
                    signingIdentity: self.signingIdentity,
                    privateKeyPath: self.privateKeyPath,
                    certificateChainPaths: self.certificateChainPaths
                )

                let result = try PackageArchiveSigner.prepareArchiveAndSign(
                    packageIdentity: packageIdentity,
                    packageVersion: packageVersion,
                    packageDirectory: packageDirectory,
                    metadataPath: metadataLocation?.path,
                    workingDirectory: workingDirectory,
                    mode: signingMode,
                    signatureFormat: self.signatureFormat,
                    cancellator: swiftCommandState.cancellator,
                    fileSystem: localFileSystem,
                    observabilityScope: swiftCommandState.observabilityScope
                )
                archivePath = result.archive.path
                archiveSignature = result.archive.signature
                metadataSignature = result.metadata?.signature
            } else {
                // step 2: generate source archive for the package release
                // step 3: signing not required
                swiftCommandState.observabilityScope.emit(info: "archiving the source at '\(packageDirectory)'")
                archivePath = try PackageArchiver.archive(
                    packageIdentity: self.packageIdentity,
                    packageVersion: self.packageVersion,
                    packageDirectory: packageDirectory,
                    workingDirectory: workingDirectory,
                    workingFilesToCopy: [],
                    cancellator: swiftCommandState.cancellator,
                    observabilityScope: swiftCommandState.observabilityScope
                )
            }

            // step 4: publish the package if not dry-run
            guard !self.dryRun else {
                print(
                    "\(packageIdentity)@\(packageVersion) was successfully prepared for publishing but was not published due to dry run flag. Artifacts available at '\(workingDirectory)'."
                )
                return
            }

            swiftCommandState.observabilityScope
                .emit(info: "publishing \(self.packageIdentity) archive at '\(archivePath)' to \(registryURL)")
            let result = try await registryClient.publish(
                registryURL: registryURL,
                packageIdentity: self.packageIdentity,
                packageVersion: self.packageVersion,
                packageArchive: archivePath,
                packageMetadata: metadataLocation?.path,
                signature: archiveSignature,
                metadataSignature: metadataSignature,
                signatureFormat: self.signatureFormat,
                fileSystem: localFileSystem,
                observabilityScope: swiftCommandState.observabilityScope,
                callbackQueue: .sharedConcurrent
            )

            switch result {
            case .published(.none):
                print("\(packageIdentity) version \(packageVersion) was successfully published to \(registryURL)")
            case .published(.some(let location)):
                print(
                    "\(packageIdentity) version \(packageVersion) was successfully published to \(registryURL) and is available at '\(location)'"
                )
            case .processing(let statusURL, _):
                print(
                    "\(packageIdentity) version \(packageVersion) was successfully submitted to \(registryURL) and is being processed. Publishing status is available at '\(statusURL)'."
                )
            }
        }
    }
}

extension SignatureFormat {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

#if compiler(<6.0)
extension SignatureFormat: ExpressibleByArgument {}
#else
extension SignatureFormat: @retroactive ExpressibleByArgument {}
#endif

enum MetadataLocation {
    case sourceTree(AbsolutePath)
    case external(AbsolutePath)

    var path: AbsolutePath {
        switch self {
        case .sourceTree(let path):
            return path
        case .external(let path):
            return path
        }
    }
}

// MARK: - Helpers

enum PackageArchiveSigner {
    static func computeSigningMode(
        signingIdentity: String?,
        privateKeyPath: AbsolutePath?,
        certificateChainPaths: [AbsolutePath]
    ) throws -> SigningMode {
        let signingMode: PackageArchiveSigner.SigningMode
        switch (signingIdentity, certificateChainPaths, privateKeyPath) {
        case (.none, let certChainPaths, .none) where !certChainPaths.isEmpty:
            throw StringError(
                "Both 'private-key-path' and 'cert-chain-paths' are required when one of them is set."
            )
        case (.none, let certChainPaths, .some) where certChainPaths.isEmpty:
            throw StringError(
                "Both 'private-key-path' and 'cert-chain-paths' are required when one of them is set."
            )
        case (.none, let certChainPaths, .some(let privateKeyPath)) where !certChainPaths.isEmpty:
            let certificate = certChainPaths[0]
            let intermediateCertificates = certChainPaths.count > 1 ? Array(certChainPaths[1...]) : []
            signingMode = .certificate(
                certificate: certificate,
                intermediateCertificates: intermediateCertificates,
                privateKey: privateKeyPath
            )
        case (.some(let signingStoreLabel), let certChainPaths, .none) where certChainPaths.isEmpty:
            signingMode = .identityStore(label: signingStoreLabel, intermediateCertificates: certChainPaths)
        default:
            throw StringError(
                "Either 'signing-identity' or 'private-key-path' (together with 'cert-chain-paths') must be provided."
            )
        }
        return signingMode
    }

    static func prepareArchiveAndSign(
        packageIdentity: PackageIdentity,
        packageVersion: Version,
        packageDirectory: AbsolutePath,
        metadataPath: AbsolutePath?,
        workingDirectory: AbsolutePath,
        mode: SigningMode,
        signatureFormat: SignatureFormat,
        cancellator: Cancellator?,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> ArchiveAndSignResult {
        // signing identity
        let (signingIdentity, intermediateCertificates) = try Self.signingIdentityAndIntermediateCertificates(
            mode: mode,
            signatureFormat: signatureFormat,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )

        // sign package manifest(s)
        let manifests = try Self.findManifests(packageDirectory: packageDirectory)
        try manifests.forEach {
            observabilityScope.emit(info: "signing \($0)")
            let signedManifestPath = workingDirectory.appending($0)

            var manifest = try fileSystem.readFileContents(packageDirectory.appending($0)).contents
            let signature = try SignatureProvider.sign(
                content: manifest,
                identity: signingIdentity,
                intermediateCertificates: intermediateCertificates,
                format: signatureFormat,
                observabilityScope: observabilityScope
            )
            manifest
                .append(
                    contentsOf: Array(
                        "\n// signature: \(signatureFormat.rawValue);\(Data(signature).base64EncodedString())"
                            .utf8
                    )
                )
            try fileSystem.writeFileContents(signedManifestPath, bytes: .init(manifest))
        }

        // create the archive
        observabilityScope.emit(info: "archiving the source at '\(packageDirectory)'")
        let archivePath = try PackageArchiver.archive(
            packageIdentity: packageIdentity,
            packageVersion: packageVersion,
            packageDirectory: packageDirectory,
            workingDirectory: workingDirectory,
            workingFilesToCopy: manifests,
            cancellator: cancellator,
            observabilityScope: observabilityScope
        )
        let archive = try localFileSystem.readFileContents(archivePath).contents

        // sign the archive
        observabilityScope.emit(info: "signing the archive at '\(archivePath)'")
        let archiveSignature = try SignatureProvider.sign(
            content: archive,
            identity: signingIdentity,
            intermediateCertificates: intermediateCertificates,
            format: signatureFormat,
            observabilityScope: observabilityScope
        )
        let archiveSignaturePath = workingDirectory.appending("\(packageIdentity)-\(packageVersion).sig")
        try fileSystem.writeFileContents(archiveSignaturePath, bytes: .init(archiveSignature))

        var signedMetadata: SignedItem? = .none
        if let metadataPath {
            observabilityScope.emit(info: "signing metadata at '\(metadataPath)'")
            let metadata = try localFileSystem.readFileContents(metadataPath).contents
            let metadataSignature = try SignatureProvider.sign(
                content: metadata,
                identity: signingIdentity,
                intermediateCertificates: intermediateCertificates,
                format: signatureFormat,
                observabilityScope: observabilityScope
            )
            let metadataSignaturePath = workingDirectory.appending("\(packageIdentity)-\(packageVersion)-metadata.sig")
            try fileSystem.writeFileContents(metadataSignaturePath, bytes: .init(metadataSignature))
            signedMetadata = .init(path: metadataPath, signature: metadataSignature)
        }

        return ArchiveAndSignResult(
            archive: .init(path: archivePath, signature: archiveSignature),
            signedManifests: manifests,
            metadata: signedMetadata
        )
    }

    private static func signingIdentityAndIntermediateCertificates(
        mode: SigningMode,
        signatureFormat: SignatureFormat,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> (SigningIdentity, [[UInt8]]) {
        let signingIdentity: SigningIdentity
        let intermediateCertificates: [[UInt8]]
        switch mode {
        case .identityStore(let label, let intermediateCertPaths):
            let signingIdentityStore = SigningIdentityStore(observabilityScope: observabilityScope)
            let matches = signingIdentityStore.find(by: label)
            guard let identity = matches.first else {
                throw StringError("'\(label)' not found in the system identity store.")
            }
            // TODO: let user choose if there is more than one match?
            signingIdentity = identity
            intermediateCertificates = try intermediateCertPaths.map { try fileSystem.readFileContents($0).contents }
        case .certificate(let certPath, let intermediateCertPaths, let privateKeyPath):
            let certificate = try fileSystem.readFileContents(certPath).contents
            let privateKey = try fileSystem.readFileContents(privateKeyPath).contents
            signingIdentity = try SwiftSigningIdentity(
                derEncodedCertificate: certificate,
                derEncodedPrivateKey: privateKey,
                privateKeyType: signatureFormat.signingKeyType
            )
            intermediateCertificates = try intermediateCertPaths.map { try fileSystem.readFileContents($0).contents }
        }
        return (signingIdentity, intermediateCertificates)
    }

    private static func findManifests(packageDirectory: AbsolutePath) throws -> [String] {
        let packageContents = try localFileSystem.getDirectoryContents(packageDirectory)

        var manifests: [String] = []

        let manifestPath = packageDirectory.appending(Manifest.filename)
        guard localFileSystem.exists(manifestPath) else {
            throw StringError("No \(Manifest.filename) found at \(packageDirectory).")
        }
        manifests.append(Manifest.filename)

        let regex = try RegEx(pattern: #"^Package@swift-(\d+)(?:\.(\d+))?(?:\.(\d+))?.swift$"#)
        let versionSpecificManifests: [String] = packageContents.filter { file in
            let matchGroups = regex.matchGroups(in: file)
            return !matchGroups.isEmpty
        }
        manifests.append(contentsOf: versionSpecificManifests)

        return manifests
    }

    enum SigningMode {
        case identityStore(label: String, intermediateCertificates: [AbsolutePath])
        case certificate(certificate: AbsolutePath, intermediateCertificates: [AbsolutePath], privateKey: AbsolutePath)
    }

    struct ArchiveAndSignResult {
        let archive: SignedItem
        let signedManifests: [String]
        let metadata: SignedItem?
    }

    struct SignedItem {
        let path: AbsolutePath
        let signature: [UInt8]
    }
}

enum PackageArchiver {
    static func archive(
        packageIdentity: PackageIdentity,
        packageVersion: Version,
        packageDirectory: AbsolutePath,
        workingDirectory: AbsolutePath,
        workingFilesToCopy: [String],
        cancellator: Cancellator?,
        observabilityScope: ObservabilityScope
    ) throws -> AbsolutePath {
        let archivePath = workingDirectory.appending("\(packageIdentity)-\(packageVersion).zip")

        // create temp location for sources
        let sourceDirectory = workingDirectory.appending(components: "source", "\(packageIdentity)")
        try localFileSystem.createDirectory(sourceDirectory, recursive: true)

        // TODO: filter other unnecessary files, and/or .swiftpmignore file
        let ignoredContent = [".build", ".git", ".gitignore", ".swiftpm"]
        let packageContent = try localFileSystem.getDirectoryContents(packageDirectory)
        for item in (packageContent.filter { !ignoredContent.contains($0) }) {
            try localFileSystem.copy(
                from: packageDirectory.appending(component: item),
                to: sourceDirectory.appending(component: item)
            )
        }

        for item in workingFilesToCopy {
            let replacementPath = workingDirectory.appending(item)
            let replacement = try localFileSystem.readFileContents(replacementPath)

            let toBeReplacedPath = sourceDirectory.appending(item)

            observabilityScope.emit(info: "replacing '\(toBeReplacedPath)' with '\(replacementPath)'")
            try localFileSystem.writeFileContents(toBeReplacedPath, bytes: replacement)
        }

        try SwiftPackageCommand.archiveSource(
            at: sourceDirectory,
            to: archivePath,
            fileSystem: localFileSystem,
            cancellator: cancellator
        )

        return archivePath
    }
}
