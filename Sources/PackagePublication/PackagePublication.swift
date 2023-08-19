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

import Basics
import PackageModel
import PackageSigning
import struct TSCUtility.Version

public enum PackagePublication {
    public typealias Signature = [UInt8]
    public typealias SignatureProvider = (_ content: [UInt8], _ signatureFormat: SignatureFormat) throws -> Signature

    public static func archiveAndSign(
        packageIdentity: PackageIdentity,
        packageVersion: Version,
        packageDirectory: AbsolutePath,
        metadataPath: AbsolutePath?,
        signingIdentity: SigningIdentity,
        intermediateCertificates: [[UInt8]],
        signatureFormat: SignatureFormat,
        workingDirectory: AbsolutePath,
        cancellator: Cancellator?,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> ArchiveAndSignResult {
        let signatureProvider: SignatureProvider = { content, signatureFormat in
            try PackageSigning.SignatureProvider.sign(
                content: content,
                identity: signingIdentity,
                intermediateCertificates: intermediateCertificates,
                format: signatureFormat,
                observabilityScope: observabilityScope
            )
        }

        // Sign the package manifest(s)
        let manifests = try ManifestSigner.findManifests(
            packageDirectory: packageDirectory,
            fileSystem: fileSystem
        )
        try manifests.forEach {
            let manifestPath = packageDirectory.appending($0)
            let signedManifestPath = workingDirectory.appending($0)
            _ = try ManifestSigner.sign(
                manifestPath: manifestPath,
                signedManifestPath: signedManifestPath,
                signatureProvider: signatureProvider,
                signatureFormat: signatureFormat,
                fileSystem: fileSystem,
                observabilityScope: observabilityScope
            )
        }

        // Create the archive (includes signed manifests)
        observabilityScope.emit(info: "archiving the source at '\(packageDirectory)'")
        let archivePath = try PackageArchiver.archiveSource(
            packageIdentity: packageIdentity,
            packageVersion: packageVersion,
            packageDirectory: packageDirectory,
            workingDirectory: workingDirectory,
            workingFilesToCopy: manifests, // copy signed manifests
            cancellator: cancellator,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )
        let archiveSignaturePath = workingDirectory.appending("\(packageIdentity)-\(packageVersion).sig")

        // Sign the archive
        let archiveSignature = try PackageSigner.signSourceArchive(
            archivePath: archivePath,
            archiveSignaturePath: archiveSignaturePath,
            signatureProvider: signatureProvider,
            signatureFormat: signatureFormat,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )

        // Sign the package version metadata if any
        var signedMetadata: SignedItem? = .none
        if let metadataPath {
            let metadataSignaturePath = workingDirectory.appending("\(packageIdentity)-\(packageVersion)-metadata.sig")
            let metadataSignature = try PackageSigner.signPackageVersionMetadata(
                metadataPath: metadataPath,
                metadataSignaturePath: metadataSignaturePath,
                signatureProvider: signatureProvider,
                signatureFormat: signatureFormat,
                fileSystem: fileSystem,
                observabilityScope: observabilityScope
            )
            signedMetadata = .init(path: metadataPath, signature: metadataSignature)
        }

        return ArchiveAndSignResult(
            archive: .init(path: archivePath, signature: archiveSignature),
            signedManifests: manifests,
            metadata: signedMetadata
        )
    }

    public struct ArchiveAndSignResult {
        public let archive: SignedItem
        public let signedManifests: [String]
        public let metadata: SignedItem?
    }

    public struct SignedItem {
        public let path: AbsolutePath
        public let signature: Signature
    }
}
