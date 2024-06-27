//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageGraph
import PackageModel
import SourceControl

extension Workspace {
    /// A downloaded artifact managed by the workspace.
    public struct ManagedArtifact {
        /// The package reference.
        public let packageRef: PackageReference

        /// The name of the binary target the artifact corresponds to.
        public let targetName: String

        /// The source of the artifact (local or remote).
        public let source: Source

        /// The path of the artifact on disk
        public let path: AbsolutePath

        public let kind: BinaryModule.Kind

        public init(
            packageRef: PackageReference,
            targetName: String,
            source: Source,
            path: AbsolutePath,
            kind: BinaryModule.Kind
        ) {
            self.packageRef = packageRef
            self.targetName = targetName
            self.source = source
            self.path = path
            self.kind = kind
        }

        /// Create an artifact downloaded from a remote url.
        public static func remote(
            packageRef: PackageReference,
            targetName: String,
            url: String,
            checksum: String,
            path: AbsolutePath,
            kind: BinaryModule.Kind
        ) -> ManagedArtifact {
            return ManagedArtifact(
                packageRef: packageRef,
                targetName: targetName,
                source: .remote(url: url, checksum: checksum),
                path: path,
                kind: kind
            )
        }

        /// Create an artifact present locally on the filesystem.
        public static func local(
            packageRef: PackageReference,
            targetName: String,
            path: AbsolutePath,
            kind: BinaryModule.Kind,
            checksum: String? = nil
        ) -> ManagedArtifact {
            return ManagedArtifact(
                packageRef: packageRef,
                targetName: targetName,
                source: .local(checksum: checksum),
                path: path,
                kind: kind
            )
        }

        /// Represents the source of the artifact.
        public enum Source: Equatable {

            /// Represents a remote artifact, with the url it was downloaded from, its checksum, and its path relative to
            /// the workspace artifacts path.
            case remote(url: String, checksum: String)

            /// Represents a locally available artifact, with its path relative either to its package or to the workspace artifacts
            /// path, in the latter case, the checksum of the local archive the artifact was extracted from is set.
            case local(checksum: String? = nil)
        }
    }
}

extension Workspace.ManagedArtifact: CustomStringConvertible {
    public var description: String {
        return "<ManagedArtifact: \(self.packageRef.identity).\(self.targetName) \(self.source) \(self.path)>"
    }
}

extension Workspace.ManagedArtifact.Source: CustomStringConvertible {
    public var description: String {
        switch self {
        case .local(let checksum):
            return "local(checksum: \(checksum ?? "nil"))"
        case .remote(let url, let checksum):
            return "remote(url: \(url), checksum: \(checksum))"
        }
    }
}

// MARK: - ManagedArtifacts

extension Workspace {
    /// A collection of managed artifacts which have been downloaded.
    public final class ManagedArtifacts {
        /// A mapping from package identity, to target name, to ManagedArtifact.
        private var artifactMap: [PackageIdentity: [String: ManagedArtifact]]

        internal var artifacts: AnyCollection<ManagedArtifact> {
            AnyCollection(self.artifactMap.values.lazy.flatMap{ $0.values })
        }

        init() {
            self.artifactMap = [:]
        }

        init(_ artifacts: [ManagedArtifact]) throws {
            let artifactsByPackagePath = Dictionary(grouping: artifacts, by: { $0.packageRef.identity })
            self.artifactMap = try artifactsByPackagePath.mapValues{ artifacts in
                // rdar://86857825 do not use Dictionary(uniqueKeysWithValues:) as it can crash the process when input is incorrect such as in older versions of SwiftPM
                var map = [String: ManagedArtifact]()
                for artifact in artifacts {
                    if map[artifact.targetName] != nil {
                        throw StringError("binary artifact for '\(artifact.targetName)' already exists in managed artifacts")
                    }
                    map[artifact.targetName] = artifact
                }
                return map
            }
        }

        public subscript(packageIdentity packageIdentity: PackageIdentity, targetName targetName: String) -> ManagedArtifact? {
            self.artifactMap[packageIdentity]?[targetName]
        }

        public func add(_ artifact: ManagedArtifact) {
            self.artifactMap[artifact.packageRef.identity, default: [:]][artifact.targetName] = artifact
        }

        public func remove(packageIdentity: PackageIdentity, targetName: String) {
            self.artifactMap[packageIdentity]?[targetName] = nil
        }
    }
}

extension Workspace.ManagedArtifacts: Collection {
    public var startIndex: AnyIndex {
        self.artifacts.startIndex
    }

    public var endIndex: AnyIndex {
        self.artifacts.endIndex
    }

    public subscript(index: AnyIndex) -> Workspace.ManagedArtifact {
        self.artifacts[index]
    }

    public func index(after index: AnyIndex) -> AnyIndex {
        self.artifacts.index(after: index)
    }
}

extension Workspace.ManagedArtifacts: CustomStringConvertible {
    public var description: String {
        "<ManagedArtifacts: \(Array(self.artifacts))>"
    }
}
