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

import struct Foundation.Data

import Basics
import PackageModel
import PackageSigning
import struct TSCBasic.RegEx

public enum ManifestSigner {
    public static func sign(
        manifestPath: AbsolutePath,
        signedManifestPath: AbsolutePath,
        signatureProvider: PackagePublication.SignatureProvider,
        signatureFormat: SignatureFormat,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> PackagePublication.Signature {
        var manifest = try fileSystem.readFileContents(manifestPath).contents

        // Sign the manifest
        observabilityScope.emit(info: "signing \(manifestPath)")
        let signature = try signatureProvider(manifest, signatureFormat)

        // Append signature to end of manifest
        manifest
            .append(
                contentsOf: Array(
                    "\n// signature: \(signatureFormat.rawValue);\(Data(signature).base64EncodedString())".utf8
                )
            )

        // Save the signed manifest
        observabilityScope.emit(info: "writing \(signedManifestPath)")
        try fileSystem.writeFileContents(signedManifestPath, bytes: .init(manifest))

        return signature
    }

    /// Returns an array of manifest filenames within the package directory.
    public static func findManifests(
        packageDirectory: AbsolutePath,
        fileSystem: FileSystem
    ) throws -> [String] {
        let packageContents = try fileSystem.getDirectoryContents(packageDirectory)

        var manifests: [String] = []

        let manifestPath = packageDirectory.appending(Manifest.filename)
        guard fileSystem.exists(manifestPath) else {
            throw StringError("No \(Manifest.filename) found in \(packageDirectory).")
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
}
