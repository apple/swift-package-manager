//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation

import struct TSCUtility.Version

public struct ArtifactsArchiveMetadata: Equatable {
    public let schemaVersion: String
    public let artifacts: [String: Artifact]

    public init(schemaVersion: String, artifacts: [String: Artifact]) {
        self.schemaVersion = schemaVersion
        self.artifacts = artifacts
    }

    public struct Artifact: Equatable {
        public let type: ArtifactType
        public let version: String
        public let variants: [Variant]

        public init(type: ArtifactsArchiveMetadata.ArtifactType, version: String, variants: [Variant]) {
            self.type = type
            self.version = version
            self.variants = variants
        }
    }

    // In the future we are likely to extend the ArtifactsArchive file format to carry other types of artifacts beyond
    // executables, libraries, and Swift SDKs. Additional fields may be required to support these new artifact
    // types e.g. headers path for libraries. This can also support resource-only artifacts as well. For example,
    // 3D models along with associated textures, or fonts, etc.
    public enum ArtifactType: String, RawRepresentable, Decodable {
        case executable
        case library
        case swiftSDK

        // Can't be marked as formally deprecated as we still need to use this value for warning users.
        case crossCompilationDestination
    }

    public struct Variant: Equatable {
        public let path: RelativePath
        public let supportedTriples: [Triple]
        public let libraryMetadata: LibraryMetadata?

        public init(path: RelativePath, supportedTriples: [Triple], libraryMetadata: LibraryMetadata? = nil) {
            self.path = path
            self.supportedTriples = supportedTriples
            self.libraryMetadata = libraryMetadata
        }
    }

    public struct LibraryMetadata: Equatable, Decodable {
        public let headerPaths: [RelativePath]
        public let moduleMapPath: RelativePath?
    }
}

extension ArtifactsArchiveMetadata {
    public static func parse(fileSystem: FileSystem, rootPath: AbsolutePath) throws -> ArtifactsArchiveMetadata {
        let path = rootPath.appending("info.json")
        guard fileSystem.exists(path) else {
            throw StringError("ArtifactsArchive info.json not found at '\(rootPath)'")
        }

        do {
            let data: Data = try fileSystem.readFileContents(path)
            let decoder = JSONDecoder.makeWithDefaults()
            let decodedMetadata = try decoder.decode(ArtifactsArchiveMetadata.self, from: data)
            let version = try Version(
                versionString: decodedMetadata.schemaVersion,
                usesLenientParsing: true
            )

            switch (version.major, version.minor) {
            case (1, 2), (1, 1), (1, 0):
                return decodedMetadata
            default:
                throw StringError(
                    "invalid `schemaVersion` of bundle manifest at `\(path)`: \(decodedMetadata.schemaVersion)"
                )
            }
        } catch {
            throw StringError(
                "failed parsing ArtifactsArchive info.json at '\(path)': \(error.interpolationDescription)"
            )
        }
    }
}

extension ArtifactsArchiveMetadata: Decodable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case artifacts
    }
}

extension ArtifactsArchiveMetadata.Artifact: Decodable {
    enum CodingKeys: String, CodingKey {
        case type
        case version
        case variants
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(ArtifactsArchiveMetadata.ArtifactType.self, forKey: .type)
        self.version = try container.decode(String.self, forKey: .version)
        self.variants = try container.decode([ArtifactsArchiveMetadata.Variant].self, forKey: .variants)
    }
}

extension ArtifactsArchiveMetadata.Variant: Decodable {
    enum CodingKeys: String, CodingKey {
        case path
        case supportedTriples
        case libraryMetadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.supportedTriples = try container.decode([String].self, forKey: .supportedTriples).map { try Triple($0) }
        self.path = try RelativePath(validating: container.decode(String.self, forKey: .path))
        self.libraryMetadata = try container.decode(
            ArtifactsArchiveMetadata.LibraryMetadata.self,
            forKey: .libraryMetadata
        )
    }
}
