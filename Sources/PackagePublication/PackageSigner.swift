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
import PackageSigning

public enum PackageSigner {
    public static func signSourceArchive(
        archivePath: AbsolutePath,
        archiveSignaturePath: AbsolutePath,
        signatureProvider: PackagePublication.SignatureProvider,
        signatureFormat: SignatureFormat,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> PackagePublication.Signature {
        let archive = try fileSystem.readFileContents(archivePath).contents
        // Sign the archive
        observabilityScope.emit(info: "signing the archive at '\(archivePath)'")
        let signature = try signatureProvider(archive, signatureFormat)
        // Write the signature file
        try fileSystem.writeFileContents(archiveSignaturePath, bytes: .init(signature))
        return signature
    }

    public static func signPackageVersionMetadata(
        metadataPath: AbsolutePath,
        metadataSignaturePath: AbsolutePath,
        signatureProvider: PackagePublication.SignatureProvider,
        signatureFormat: SignatureFormat,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> PackagePublication.Signature {
        let metadata = try fileSystem.readFileContents(metadataPath).contents
        // Sign the metadata
        observabilityScope.emit(info: "signing metadata at '\(metadataPath)'")
        let signature = try signatureProvider(metadata, signatureFormat)
        // Write the signature file
        try fileSystem.writeFileContents(metadataSignaturePath, bytes: .init(signature))
        return signature
    }
}
