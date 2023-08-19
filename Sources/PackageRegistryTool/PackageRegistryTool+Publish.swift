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
import Foundation
import PackageModel
import PackagePublication
import PackageRegistry
import PackageSigning
import Workspace
@_implementationOnly import X509 // FIXME: need this import or else SwiftSigningIdentity initializer fails

import struct TSCBasic.ByteString
import struct TSCBasic.RegEx
import struct TSCBasic.SHA256

import struct TSCUtility.Version

extension SwiftPackageRegistryTool {
    struct Publish: SwiftCommand {
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

        @Flag(help: "Dry run only; prepare the archive and sign it but do not publish to the registry.")
        var dryRun: Bool = false

        func run(_ swiftTool: SwiftTool) throws {
            // Require both local and user-level registries config
            let configuration = try getRegistriesConfig(swiftTool, global: false).configuration

            // validate package location
            let packageDirectory = try self.globalOptions.locations.packageDirectory ?? swiftTool.getPackageRoot()
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

            try registryURL.validateRegistryURL()

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

            guard let authorizationProvider = try swiftTool.getRegistryAuthorizationProvider() else {
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
                    cancellator: swiftTool.cancellator,
                    fileSystem: localFileSystem,
                    observabilityScope: swiftTool.observabilityScope
                )
                archivePath = result.archive.path
                archiveSignature = result.archive.signature
                metadataSignature = result.metadata?.signature
            } else {
                // step 2: generate source archive for the package release
                // step 3: signing not required
                swiftTool.observabilityScope.emit(info: "archiving the source at '\(packageDirectory)'")
                archivePath = try PackageArchiver.archiveSource(
                    packageIdentity: self.packageIdentity,
                    packageVersion: self.packageVersion,
                    packageDirectory: packageDirectory,
                    workingDirectory: workingDirectory,
                    workingFilesToCopy: [],
                    cancellator: swiftTool.cancellator,
                    fileSystem: localFileSystem,
                    observabilityScope: swiftTool.observabilityScope
                )
            }

            // step 4: publish the package if not dry-run
            guard !self.dryRun else {
                print(
                    "\(packageIdentity)@\(packageVersion) was successfully prepared for publishing but was not published due to dry run flag. Artifacts available at '\(workingDirectory)'."
                )
                return
            }

            swiftTool.observabilityScope
                .emit(info: "publishing \(self.packageIdentity) archive at '\(archivePath)' to \(registryURL)")
            let result = try temp_await {
                registryClient.publish(
                    registryURL: registryURL,
                    packageIdentity: self.packageIdentity,
                    packageVersion: self.packageVersion,
                    packageArchive: archivePath,
                    packageMetadata: metadataLocation?.path,
                    signature: archiveSignature,
                    metadataSignature: metadataSignature,
                    signatureFormat: self.signatureFormat,
                    fileSystem: localFileSystem,
                    observabilityScope: swiftTool.observabilityScope,
                    callbackQueue: .sharedConcurrent,
                    completion: $0
                )
            }

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

extension SignatureFormat: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

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
    ) throws -> PackagePublication.ArchiveAndSignResult {
        // signing identity
        let (signingIdentity, intermediateCertificates) = try Self.signingIdentityAndIntermediateCertificates(
            mode: mode,
            signatureFormat: signatureFormat,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )
        
        return try PackagePublication.archiveAndSign(
            packageIdentity: packageIdentity,
            packageVersion: packageVersion,
            packageDirectory: packageDirectory,
            metadataPath: metadataPath,
            signingIdentity: signingIdentity,
            intermediateCertificates: intermediateCertificates,
            signatureFormat: signatureFormat,
            workingDirectory: workingDirectory,
            cancellator: cancellator,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
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

    enum SigningMode {
        case identityStore(label: String, intermediateCertificates: [AbsolutePath])
        case certificate(certificate: AbsolutePath, intermediateCertificates: [AbsolutePath], privateKey: AbsolutePath)
    }
}
