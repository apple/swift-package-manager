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
import PackageGraph
import PackageModel

/// Information about a library from a binary dependency.
public struct LibraryInfo: Equatable {
    /// The path to the binary.
    public let libraryPath: AbsolutePath

    /// The paths to the headers directories.
    public let headersPaths: [AbsolutePath]
}

/// Information about an executable from a binary dependency.
public struct ExecutableInfo: Equatable {
    /// The tool name
    public let name: String

    /// The path to the executable.
    public let executablePath: AbsolutePath

    /// Supported triples, e.g. `x86_64-apple-macosx`
    public let supportedTriples: [Triple]
}

extension BinaryModule {
    public func parseXCFrameworks(for triple: Triple, fileSystem: FileSystem) throws -> [LibraryInfo] {
        // At the moment we return at most a single library.
        let metadata = try XCFrameworkMetadata.parse(fileSystem: fileSystem, rootPath: self.artifactPath)
        // Filter the libraries that are relevant to the triple.
        guard let library = metadata.libraries.first(where: {
            $0.platform == triple.os?.asXCFrameworkPlatformString &&
            $0.variant == triple.environment?.asXCFrameworkPlatformVariantString &&
            $0.architectures.contains(triple.archName)
        }) else {
            return []
        }
        // Construct a LibraryInfo for the library.
        let libraryDir = self.artifactPath.appending(component: library.libraryIdentifier)
        let libraryFile = try AbsolutePath(validating: library.libraryPath, relativeTo: libraryDir)
        let headersDirs = try library.headersPath
            .map { [try AbsolutePath(validating: $0, relativeTo: libraryDir)] } ?? [] + [libraryDir]
        return [LibraryInfo(libraryPath: libraryFile, headersPaths: headersDirs)]
    }

    public func parseArtifactArchives(for triple: Triple, fileSystem: FileSystem) throws -> [ExecutableInfo] {
        // The host triple might contain a version which we don't want to take into account here.
        let versionLessTriple = try triple.withoutVersion()
        // We return at most a single variant of each artifact.
        let metadata = try ArtifactsArchiveMetadata.parse(fileSystem: fileSystem, rootPath: self.artifactPath)
        // Currently we filter out everything except executables.
        // TODO: Add support for libraries
        let executables = metadata.artifacts.filter { $0.value.type == .executable }
        // Construct an ExecutableInfo for each matching variant.
        return try executables.flatMap { entry in
            // Filter supported triples with versionLessTriple and pass into
            // ExecutableInfo; empty if non matching triples found.
            try entry.value.variants.map {
                guard let supportedTriples = $0.supportedTriples else {
                    throw StringError("No \"supportedTriples\" found in the artifact metadata for \(entry.key) in \(self.artifactPath)")
                }
                let filteredSupportedTriples = try supportedTriples
                    .filter { try $0.withoutVersion() == versionLessTriple }
                return ExecutableInfo(
                    name: entry.key,
                    executablePath: self.artifactPath.appending($0.path),
                    supportedTriples: filteredSupportedTriples
                )
            }
        }
    }
}

extension Triple {
    func withoutVersion() throws -> Triple {
        if isDarwin() {
            let stringWithoutVersion = tripleString(forPlatformVersion: "")
            return try Triple(stringWithoutVersion)
        } else {
            return self
        }
    }
}

extension Triple.OS {
    /// Returns a representation of the receiver that can be compared with platform strings declared in an XCFramework.
    fileprivate var asXCFrameworkPlatformString: String? {
        switch self {
        case .darwin, .linux, .wasi, .win32, .openbsd, .noneOS:
            return nil // XCFrameworks do not support any of these platforms today.
        case .macosx:
            return "macos"
        case .ios:
            return "ios"
        case .tvos:
            return "tvos"
        case .watchos:
            return "watchos"
        default:
            return nil // XCFrameworks do not support any of these platforms today.
        }
    }
}

extension Triple.Environment {
    fileprivate var asXCFrameworkPlatformVariantString: String? {
        switch self {
        case .simulator:
            return "simulator"
        case .macabi:
            return "maccatalyst"
        default:
            return nil // XCFrameworks do not support any of these platform variants today.
        }
    }
}
