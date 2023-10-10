//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2017 Apple Inc. and the Swift project authors
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
import SourceControl

import struct TSCUtility.Version

/// Represents the workspace internal state persisted on disk.
public final class WorkspaceState {
    /// The dependencies managed by the Workspace.
    public private(set) var dependencies: Workspace.ManagedDependencies

    /// The artifacts managed by the Workspace.
    public private(set) var artifacts: Workspace.ManagedArtifacts

    /// Path to the state file.
    public let storagePath: AbsolutePath

    /// storage
    private let storage: WorkspaceStateStorage

    init(
        fileSystem: FileSystem,
        storageDirectory: AbsolutePath,
        initializationWarningHandler: (String) -> Void
    ) {
        self.storagePath = storageDirectory.appending("workspace-state.json")
        self.storage = WorkspaceStateStorage(path: self.storagePath, fileSystem: fileSystem)

        // Load the state from disk, if possible.
        //
        // If the disk operation here fails, we ignore the error here.
        // This means if managed dependencies data is corrupted or out of date,
        // clients will not see the old data and managed dependencies will be
        // reset.  However there could be other errors, like permission issues,
        // these errors will also be ignored but will surface when clients try
        // to save the state.
        do {
            let storedState = try self.storage.load()
            self.dependencies = storedState.dependencies
            self.artifacts = storedState.artifacts
        } catch {
            self.dependencies = Workspace.ManagedDependencies()
            self.artifacts = Workspace.ManagedArtifacts()
            try? self.storage.reset()
            initializationWarningHandler("unable to restore workspace state: \(error.interpolationDescription)")
        }
    }

    func reset() throws {
        self.dependencies = Workspace.ManagedDependencies()
        self.artifacts = Workspace.ManagedArtifacts()
        try self.save()
    }

    // marked public for testing
    public func save() throws {
        try self.storage.save(dependencies: self.dependencies, artifacts: self.artifacts)
    }

    /// Returns true if the state file exists on the filesystem.
    func stateFileExists() -> Bool {
        return self.storage.fileExists()
    }

    /// Returns true if the state file exists on the filesystem.
    func reload() throws  {
        let storedState = try self.storage.load()
        self.dependencies = storedState.dependencies
        self.artifacts = storedState.artifacts
    }
}

// MARK: - Serialization

fileprivate struct WorkspaceStateStorage {
    private let path: AbsolutePath
    private let fileSystem: FileSystem
    private let encoder = JSONEncoder.makeWithDefaults()
    private let decoder = JSONDecoder.makeWithDefaults()

    init(path: AbsolutePath, fileSystem: FileSystem) {
        self.path = path
        self.fileSystem = fileSystem
    }

    func load() throws -> (dependencies: Workspace.ManagedDependencies, artifacts: Workspace.ManagedArtifacts){
        if !self.fileSystem.exists(self.path) {
            return (dependencies: .init(), artifacts: .init())
        }

        return try self.fileSystem.withLock(on: self.path, type: .shared) {
            let version = try decoder.decode(path: self.path, fileSystem: self.fileSystem, as: Version.self)
            switch version.version {
            case 1,2,3,4:
                let v4 = try self.decoder.decode(path: self.path, fileSystem: self.fileSystem, as: V4.self)
                let dependencies = try v4.object.dependencies.map{ try Workspace.ManagedDependency($0) }
                let artifacts = try v4.object.artifacts.map{ try Workspace.ManagedArtifact($0) }
                return try (dependencies: .init(dependencies), artifacts: .init(artifacts))
            case 5:
                let v5 = try self.decoder.decode(path: self.path, fileSystem: self.fileSystem, as: V5.self)
                let dependencies = try v5.object.dependencies.map{ try Workspace.ManagedDependency($0) }
                let artifacts = try v5.object.artifacts.map{ try Workspace.ManagedArtifact($0) }
                return try (dependencies: .init(dependencies), artifacts: .init(artifacts))
            case 6:
                let v6 = try self.decoder.decode(path: self.path, fileSystem: self.fileSystem, as: V6.self)
                let dependencies = try v6.object.dependencies.map{ try Workspace.ManagedDependency($0) }
                let artifacts = try v6.object.artifacts.map{ try Workspace.ManagedArtifact($0) }
                return try (dependencies: .init(dependencies), artifacts: .init(artifacts))
            default:
                throw StringError("unknown 'WorkspaceStateStorage' version '\(version.version)' at '\(self.path)'")
            }
        }
    }

    func save(dependencies: Workspace.ManagedDependencies, artifacts: Workspace.ManagedArtifacts) throws {
        if !self.fileSystem.exists(self.path.parentDirectory) {
            try self.fileSystem.createDirectory(self.path.parentDirectory)
        }

        try self.fileSystem.withLock(on: self.path, type: .exclusive) {
            let storage = V6(dependencies: dependencies, artifacts: artifacts)

            let data = try self.encoder.encode(storage)
            try self.fileSystem.writeIfChanged(path: self.path, data: data)
        }
    }

    func reset() throws {
        if !self.fileSystem.exists(self.path.parentDirectory) {
            return
        }
        try self.fileSystem.withLock(on: self.path, type: .exclusive) {
            try self.fileSystem.removeFileTree(self.path)
        }
    }

    func fileExists() -> Bool {
        return self.fileSystem.exists(self.path)
    }
}

extension WorkspaceStateStorage {
    // version reader
    struct Version: Codable {
        let version: Int
    }
}

// MARK: - V6 format

extension WorkspaceStateStorage {
    // v6 storage format
    struct V6: Codable {
        let version: Int
        let object: Container

        init (dependencies: Workspace.ManagedDependencies, artifacts: Workspace.ManagedArtifacts) {
            self.version = 6
            self.object = .init(
                dependencies: dependencies.map { .init($0) }.sorted { $0.packageRef.identity < $1.packageRef.identity },
                artifacts: artifacts.map { .init($0) }.sorted { $0.packageRef.identity < $1.packageRef.identity }
            )
        }

        struct Container: Codable {
            var dependencies: [Dependency]
            var artifacts: [Artifact]
        }

        struct Dependency: Codable {
            let packageRef: PackageReference
            let state: State
            let subpath: String

            init(packageRef: PackageReference, state: State, subpath: String) {
                self.packageRef = packageRef
                self.state = state
                self.subpath = subpath
            }

            init(_ dependency: Workspace.ManagedDependency) {
                self.packageRef = .init(dependency.packageRef)
                self.state = .init(underlying: dependency.state)
                self.subpath = dependency.subpath.pathString
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let packageRef = try container.decode(PackageReference.self, forKey: .packageRef)
                let subpath = try container.decode(String.self, forKey: .subpath)
                let basedOn = try container.decode(Dependency?.self, forKey: .basedOn)
                let state = try State.decode(
                    container: container.nestedContainer(keyedBy: State.CodingKeys.self, forKey: .state),
                    basedOn: basedOn
                )

                self.init(
                    packageRef: packageRef,
                    state: state,
                    subpath: subpath
                )
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(self.packageRef, forKey: .packageRef)
                try container.encode(self.state, forKey: .state)
                try container.encode(self.subpath, forKey: .subpath)
                var basedOn: Dependency? = .none
                if case .edited(let _basedOn, _) = self.state.underlying {
                    basedOn = _basedOn.map { .init($0) }
                }
                try container.encode(basedOn, forKey: .basedOn)
            }

            enum CodingKeys: CodingKey {
                case packageRef
                case state
                case subpath
                case basedOn
            }

            struct State: Encodable {
                let underlying: Workspace.ManagedDependency.State

                init(underlying: Workspace.ManagedDependency.State) {
                    self.underlying = underlying
                }

                static func decode(container: KeyedDecodingContainer<Self.CodingKeys>, basedOn: Dependency?) throws -> State {
                    let kind = try container.decode(String.self, forKey: .name)
                    switch kind {
                    case "local", "fileSystem":
                        let path = try container.decode(AbsolutePath.self, forKey: .path)
                        return self.init(underlying: .fileSystem(path))
                    case "checkout", "sourceControlCheckout":
                        let checkout = try container.decode(CheckoutInfo.self, forKey: .checkoutState)
                        return try self.init(underlying: .sourceControlCheckout(.init(checkout)))
                    case "registryDownload":
                        let version = try container.decode(String.self, forKey: .version)
                        return try self.init(underlying: .registryDownload(version: TSCUtility.Version(versionString: version)))
                    case "edited":
                        let path = try container.decode(AbsolutePath?.self, forKey: .path)
                        return try self.init(underlying: .edited(basedOn: basedOn.map { try .init($0) }, unmanagedPath: path))
                    case "custom":
                        let version = try container.decode(String.self, forKey: .version)
                        let path = try container.decode(AbsolutePath.self, forKey: .path)
                        return try self.init(underlying: .custom(version: TSCUtility.Version(versionString: version), path: path))
                    default:
                        throw StringError("unknown dependency state \(kind)")
                    }
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    switch self.underlying {
                    case .fileSystem(let path):
                        try container.encode("fileSystem", forKey: .name)
                        try container.encode(path, forKey: .path)
                    case .sourceControlCheckout(let state):
                        try container.encode("sourceControlCheckout", forKey: .name)
                        try container.encode(CheckoutInfo(state), forKey: .checkoutState)
                    case .registryDownload(let version):
                        try container.encode("registryDownload", forKey: .name)
                        try container.encode(version, forKey: .version)
                    case .edited(_, let path):
                        try container.encode("edited", forKey: .name)
                        try container.encode(path, forKey: .path)
                    case .custom(let version, let path):
                        try container.encode("custom", forKey: .name)
                        try container.encode(version, forKey: .version)
                        try container.encode(path, forKey: .path)
                    }
                }

                enum CodingKeys: CodingKey {
                    case name
                    case path
                    case version
                    case checkoutState
                }

                struct CheckoutInfo: Codable {
                    let revision: String
                    let branch: String?
                    let version: String?

                    init(_ state: CheckoutState) {
                        switch state {
                        case .version(let version, let revision):
                            self.version = version.description
                            self.branch = nil
                            self.revision = revision.identifier
                        case .branch(let branch, let revision):
                            self.version = nil
                            self.branch = branch
                            self.revision = revision.identifier
                        case .revision(let revision):
                            self.version = nil
                            self.branch = nil
                            self.revision = revision.identifier
                        }
                    }
                }
            }
        }

        struct Artifact: Codable {
            let packageRef: PackageReference
            let targetName: String
            let source: Source
            let path: String
            let kind: Kind

            init(_ artifact: Workspace.ManagedArtifact) {
                self.packageRef = .init(artifact.packageRef)
                self.targetName = artifact.targetName
                self.source = .init(underlying: artifact.source)
                self.path = artifact.path.pathString
                self.kind = .init(artifact.kind)
            }

            struct Source: Codable {
                let underlying: Workspace.ManagedArtifact.Source

                init(underlying: Workspace.ManagedArtifact.Source) {
                    self.underlying = underlying
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    let kind = try container.decode(String.self, forKey: .type)
                    switch kind {
                    case "local":
                        let checksum = try container.decodeIfPresent(String.self, forKey: .checksum)
                        self.init(underlying: .local(checksum: checksum))
                    case "remote":
                        let url = try container.decode(String.self, forKey: .url)
                        let checksum = try container.decode(String.self, forKey: .checksum)
                        self.init(underlying: .remote(url: url, checksum: checksum))
                    default:
                        throw StringError("unknown artifact source \(kind)")
                    }
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    switch self.underlying {
                    case .local(let checksum):
                        try container.encode("local", forKey: .type)
                        try container.encodeIfPresent(checksum, forKey: .checksum)
                    case .remote(let url, let checksum):
                        try container.encode("remote", forKey: .type)
                        try container.encode(url, forKey: .url)
                        try container.encode(checksum, forKey: .checksum)
                    }
                }

                enum CodingKeys: CodingKey {
                    case type
                    case url
                    case checksum
                }
            }

            enum Kind: String, Codable {
                case xcframework
                case artifactsArchive
                case libraryArchive
                case unknown

                init(_ underlying: BinaryTarget.Kind) {
                    switch underlying {
                    case .xcframework:
                        self = .xcframework
                    case .artifactsArchive:
                        self = .artifactsArchive
                    case .libraryArchive:
                        self = .libraryArchive
                    case .unknown:
                        self = .unknown
                    }
                }

                var underlying: BinaryTarget.Kind {
                    switch self {
                    case .xcframework:
                        return .xcframework
                    case .artifactsArchive:
                        return .artifactsArchive
                    case .libraryArchive:
                        return .libraryArchive
                    case .unknown:
                        return .unknown
                    }
                }
            }
        }

        struct PackageReference: Codable {
            let identity: String
            let kind: Kind
            let location: String
            let name: String

            init (_ reference: PackageModel.PackageReference) {
                self.identity = reference.identity.description
                switch reference.kind {
                case .root(let path):
                    self.kind = .root
                    self.location = path.pathString
                case .fileSystem(let path):
                    self.kind = .fileSystem
                    self.location = path.pathString
                case .localSourceControl(let path):
                    self.kind = .localSourceControl
                    self.location = path.pathString
                case .remoteSourceControl(let url):
                    self.kind = .remoteSourceControl
                    self.location = url.absoluteString
                case .registry:
                    self.kind = .registry
                    // FIXME: placeholder
                    self.location = self.identity.description
                }
                self.name = reference.deprecatedName
            }

            enum Kind: String, Codable {
                case root
                case fileSystem
                case localSourceControl
                case remoteSourceControl
                case registry
            }
        }
    }
}

extension Workspace.ManagedDependency {
    fileprivate init(_ dependency: WorkspaceStateStorage.V6.Dependency) throws {
        try self.init(
            packageRef: .init(dependency.packageRef),
            state: dependency.state.underlying,
            subpath: try RelativePath(validating: dependency.subpath)
        )
    }
}

extension Workspace.ManagedArtifact {
    fileprivate init(_ artifact: WorkspaceStateStorage.V6.Artifact) throws {
        try self.init(
            packageRef: .init(artifact.packageRef),
            targetName: artifact.targetName,
            source: artifact.source.underlying,
            path: try AbsolutePath(validating: artifact.path),
            kind: artifact.kind.underlying
        )
    }
}

extension PackageModel.PackageReference {
    fileprivate init(_ reference: WorkspaceStateStorage.V6.PackageReference) throws {
        let identity = PackageIdentity.plain(reference.identity)
        let kind: PackageModel.PackageReference.Kind
        switch reference.kind {
        case .root:
            kind = try .root(.init(validating: reference.location))
        case .fileSystem:
            kind = try .fileSystem(.init(validating: reference.location))
        case .localSourceControl:
            kind = try .localSourceControl(.init(validating: reference.location))
        case .remoteSourceControl:
            kind = .remoteSourceControl(SourceControlURL(reference.location))
        case .registry:
            kind = .registry(identity)
        }

        self.init(
            identity: identity,
            kind: kind,
            name: reference.name
        )
    }
}

extension CheckoutState {
    fileprivate init(_ state: WorkspaceStateStorage.V6.Dependency.State.CheckoutInfo) throws {
        let revision: Revision = .init(identifier: state.revision)
        if let branch = state.branch {
            self = .branch(name: branch, revision: revision)
        } else if let version = state.version {
            self = try .version(Version(versionString: version), revision: revision)
        } else {
            self = .revision(revision)
        }
    }
}

// MARK: - V5 format (deprecated)

extension WorkspaceStateStorage {
    // v5 storage format
    struct V5: Codable {
        let version: Int
        let object: Container

        init (dependencies: Workspace.ManagedDependencies, artifacts: Workspace.ManagedArtifacts) {
            self.version = 5
            self.object = .init(
                dependencies: dependencies.map { .init($0) }.sorted { $0.packageRef.identity < $1.packageRef.identity },
                artifacts: artifacts.map { .init($0) }.sorted { $0.packageRef.identity < $1.packageRef.identity }
            )
        }

        struct Container: Codable {
            var dependencies: [Dependency]
            var artifacts: [Artifact]
        }

        struct Dependency: Codable {
            let packageRef: PackageReference
            let state: State
            let subpath: String

            init(packageRef: PackageReference, state: State, subpath: String) {
                self.packageRef = packageRef
                self.state = state
                self.subpath = subpath
            }

            init(_ dependency: Workspace.ManagedDependency) {
                self.packageRef = .init(dependency.packageRef)
                self.state = .init(underlying: dependency.state)
                self.subpath = dependency.subpath.pathString
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let packageRef = try container.decode(PackageReference.self, forKey: .packageRef)
                let subpath = try container.decode(String.self, forKey: .subpath)
                let basedOn = try container.decode(Dependency?.self, forKey: .basedOn)
                let state = try State.decode(
                    container: container.nestedContainer(keyedBy: State.CodingKeys.self, forKey: .state),
                    basedOn: basedOn
                )

                self.init(
                    packageRef: packageRef,
                    state: state,
                    subpath: subpath
                )
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(self.packageRef, forKey: .packageRef)
                try container.encode(self.state, forKey: .state)
                try container.encode(self.subpath, forKey: .subpath)
                var basedOn: Dependency? = .none
                if case .edited(let _basedOn, _) = self.state.underlying {
                    basedOn = _basedOn.map { .init($0) }
                }
                try container.encode(basedOn, forKey: .basedOn)
            }

            enum CodingKeys: CodingKey {
                case packageRef
                case state
                case subpath
                case basedOn
            }

            struct State: Encodable {
                let underlying: Workspace.ManagedDependency.State

                init(underlying: Workspace.ManagedDependency.State) {
                    self.underlying = underlying
                }

                static func decode(container: KeyedDecodingContainer<Self.CodingKeys>, basedOn: Dependency?) throws -> State {
                    let kind = try container.decode(String.self, forKey: .name)
                    switch kind {
                    case "local", "fileSystem":
                        let path = try container.decode(AbsolutePath.self, forKey: .path)
                        return self.init(underlying: .fileSystem(path))
                    case "checkout", "sourceControlCheckout":
                        let checkout = try container.decode(CheckoutInfo.self, forKey: .checkoutState)
                        return try self.init(underlying: .sourceControlCheckout(.init(checkout)))
                    case "registryDownload":
                        let version = try container.decode(String.self, forKey: .version)
                        return try self.init(underlying: .registryDownload(version: TSCUtility.Version(versionString: version)))
                    case "edited":
                        let path = try container.decode(AbsolutePath?.self, forKey: .path)
                        return try self.init(underlying: .edited(basedOn: basedOn.map { try .init($0) }, unmanagedPath: path))
                    case "custom":
                        let version = try container.decode(String.self, forKey: .version)
                        let path = try container.decode(AbsolutePath.self, forKey: .path)
                        return try self.init(underlying: .custom(version: TSCUtility.Version(versionString: version), path: path))
                    default:
                        throw StringError("unknown dependency state \(kind)")
                    }
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    switch self.underlying {
                    case .fileSystem(let path):
                        try container.encode("fileSystem", forKey: .name)
                        try container.encode(path, forKey: .path)
                    case .sourceControlCheckout(let state):
                        try container.encode("sourceControlCheckout", forKey: .name)
                        try container.encode(CheckoutInfo(state), forKey: .checkoutState)
                    case .registryDownload(let version):
                        try container.encode("registryDownload", forKey: .name)
                        try container.encode(version, forKey: .version)
                    case .edited(_, let path):
                        try container.encode("edited", forKey: .name)
                        try container.encode(path, forKey: .path)
                    case .custom(let version, let path):
                        try container.encode("custom", forKey: .name)
                        try container.encode(version, forKey: .version)
                        try container.encode(path, forKey: .path)
                    }
                }

                enum CodingKeys: CodingKey {
                    case name
                    case path
                    case version
                    case checkoutState
                }

                struct CheckoutInfo: Codable {
                    let revision: String
                    let branch: String?
                    let version: String?

                    init(_ state: CheckoutState) {
                        switch state {
                        case .version(let version, let revision):
                            self.version = version.description
                            self.branch = nil
                            self.revision = revision.identifier
                        case .branch(let branch, let revision):
                            self.version = nil
                            self.branch = branch
                            self.revision = revision.identifier
                        case .revision(let revision):
                            self.version = nil
                            self.branch = nil
                            self.revision = revision.identifier
                        }
                    }
                }
            }
        }

        struct Artifact: Codable {
            let packageRef: PackageReference
            let targetName: String
            let source: Source
            let path: String

            init(_ artifact: Workspace.ManagedArtifact) {
                self.packageRef = .init(artifact.packageRef)
                self.targetName = artifact.targetName
                self.source = .init(underlying: artifact.source)
                self.path = artifact.path.pathString
            }

            struct Source: Codable {
                let underlying: Workspace.ManagedArtifact.Source

                init(underlying: Workspace.ManagedArtifact.Source) {
                    self.underlying = underlying
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    let kind = try container.decode(String.self, forKey: .type)
                    switch kind {
                    case "local":
                        let checksum = try container.decodeIfPresent(String.self, forKey: .checksum)
                        self.init(underlying: .local(checksum: checksum))
                    case "remote":
                        let url = try container.decode(String.self, forKey: .url)
                        let checksum = try container.decode(String.self, forKey: .checksum)
                        self.init(underlying: .remote(url: url, checksum: checksum))
                    default:
                        throw StringError("unknown artifact source \(kind)")
                    }
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    switch self.underlying {
                    case .local(let checksum):
                        try container.encode("local", forKey: .type)
                        try container.encodeIfPresent(checksum, forKey: .checksum)
                    case .remote(let url, let checksum):
                        try container.encode("remote", forKey: .type)
                        try container.encode(url, forKey: .url)
                        try container.encode(checksum, forKey: .checksum)
                    }
                }

                enum CodingKeys: CodingKey {
                    case type
                    case url
                    case checksum
                }
            }
        }

        struct PackageReference: Codable {
            let identity: String
            let kind: Kind
            let location: String
            let name: String

            init (_ reference: PackageModel.PackageReference) {
                self.identity = reference.identity.description
                switch reference.kind {
                case .root(let path):
                    self.kind = .root
                    self.location = path.pathString
                case .fileSystem(let path):
                    self.kind = .fileSystem
                    self.location = path.pathString
                case .localSourceControl(let path):
                    self.kind = .localSourceControl
                    self.location = path.pathString
                case .remoteSourceControl(let url):
                    self.kind = .remoteSourceControl
                    self.location = url.absoluteString
                case .registry:
                    self.kind = .registry
                    // FIXME: placeholder
                    self.location = self.identity.description
                }
                self.name = reference.deprecatedName
            }

            enum Kind: String, Codable {
                case root
                case fileSystem
                case localSourceControl
                case remoteSourceControl
                case registry
            }
        }
    }
}

extension Workspace.ManagedDependency {
    fileprivate init(_ dependency: WorkspaceStateStorage.V5.Dependency) throws {
        try self.init(
            packageRef: .init(dependency.packageRef),
            state: dependency.state.underlying,
            subpath: RelativePath(validating: dependency.subpath)
        )
    }
}

extension Workspace.ManagedArtifact {
    fileprivate init(_ artifact: WorkspaceStateStorage.V5.Artifact) throws {
        let path = try AbsolutePath(validating: artifact.path)
        try self.init(
            packageRef: .init(artifact.packageRef),
            targetName: artifact.targetName,
            source: artifact.source.underlying,
            path: path,
            kind: .forPath(path)
        )
    }
}

extension PackageModel.PackageReference {
    fileprivate init(_ reference: WorkspaceStateStorage.V5.PackageReference) throws {
        let identity = PackageIdentity.plain(reference.identity)
        let kind: PackageModel.PackageReference.Kind
        switch reference.kind {
        case .root:
            kind = try .root(.init(validating: reference.location))
        case .fileSystem:
            kind = try .fileSystem(.init(validating: reference.location))
        case .localSourceControl:
            kind = try .localSourceControl(.init(validating: reference.location))
        case .remoteSourceControl:
            kind = .remoteSourceControl(SourceControlURL(reference.location))
        case .registry:
            kind = .registry(identity)
        }

        self.init(
            identity: identity,
            kind: kind,
            name: reference.name
        )
    }
}

extension CheckoutState {
    fileprivate init(_ state: WorkspaceStateStorage.V5.Dependency.State.CheckoutInfo) throws {
        let revision: Revision = .init(identifier: state.revision)
        if let branch = state.branch {
            self = .branch(name: branch, revision: revision)
        } else if let version = state.version {
            self = try .version(Version(versionString: version), revision: revision)
        } else {
            self = .revision(revision)
        }
    }
}


// MARK: - V1...4 format (deprecated)

extension WorkspaceStateStorage {
    /// * 4: Artifacts.
    /// * 3: Package kind.
    /// * 2: Package identity.
    /// * 1: Initial version.
    // v4 storage format
    struct V4: Decodable {
        let version: Int
        let object: Container

        struct Container: Decodable {
            var dependencies: [Dependency]
            var artifacts: [Artifact]
        }

        struct Dependency: Decodable {
            let packageRef: PackageReference
            let state: State
            let subpath: String

            init(packageRef: PackageReference, state: State, subpath: String) {
                self.packageRef = packageRef
                self.state = state
                self.subpath = subpath
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let packageRef = try container.decode(PackageReference.self, forKey: .packageRef)
                let subpath = try container.decode(String.self, forKey: .subpath)
                let basedOn = try container.decode(Dependency?.self, forKey: .basedOn)
                let state = try State.decode(
                    container: container.nestedContainer(keyedBy: State.CodingKeys.self, forKey: .state),
                    packageRef: packageRef,
                    basedOn: basedOn
                )

                self.init(
                    packageRef: packageRef,
                    state: state,
                    subpath: subpath
                )
            }

            enum CodingKeys: CodingKey {
                case packageRef
                case state
                case subpath
                case basedOn
            }

            struct State {
                let underlying: Workspace.ManagedDependency.State

                init(underlying: Workspace.ManagedDependency.State) {
                    self.underlying = underlying
                }

                static func decode(container: KeyedDecodingContainer<Self.CodingKeys>, packageRef: PackageReference, basedOn: Dependency?) throws -> State {
                    let kind = try container.decode(String.self, forKey: .name)
                    switch kind {
                    case "local":
                        return try self.init(underlying: .fileSystem(.init(validating: packageRef.location)))
                    case "checkout":
                        let checkout = try container.decode(CheckoutInfo.self, forKey: .checkoutState)
                        return try self.init(underlying: .sourceControlCheckout(.init(checkout)))
                    case "edited":
                        let path = try container.decode(AbsolutePath?.self, forKey: .path)
                        return try self.init(underlying: .edited(basedOn: basedOn.map { try .init($0) }, unmanagedPath: path))
                    default:
                        throw StringError("unknown dependency state \(kind)")
                    }
                }

                enum CodingKeys: CodingKey {
                    case name
                    case path
                    case checkoutState
                }

                struct CheckoutInfo: Codable {
                    let revision: String
                    let branch: String?
                    let version: String?

                    init(_ state: CheckoutState) {
                        switch state {
                        case .version(let version, let revision):
                            self.version = version.description
                            self.branch = nil
                            self.revision = revision.identifier
                        case .branch(let branch, let revision):
                            self.version = nil
                            self.branch = branch
                            self.revision = revision.identifier
                        case .revision(let revision):
                            self.version = nil
                            self.branch = nil
                            self.revision = revision.identifier
                        }
                    }
                }
            }
        }

        struct Artifact: Decodable {
            let packageRef: PackageReference
            let targetName: String
            let source: Source
            let path: String

            struct Source: Decodable {
                let underlying: Workspace.ManagedArtifact.Source

                init(underlying: Workspace.ManagedArtifact.Source) {
                    self.underlying = underlying
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    let kind = try container.decode(String.self, forKey: .type)
                    switch kind {
                    case "local":
                        let checksum = try container.decodeIfPresent(String.self, forKey: .checksum)
                        self.init(underlying: .local(checksum: checksum))
                    case "remote":
                        let url = try container.decode(String.self, forKey: .url)
                        let checksum = try container.decode(String.self, forKey: .checksum)
                        self.init(underlying: .remote(url: url, checksum: checksum))
                    default:
                        throw StringError("unknown artifact source \(kind)")
                    }
                }

                enum CodingKeys: CodingKey {
                    case type
                    case url
                    case checksum
                }
            }
        }

        struct PackageReference: Decodable {
            let identity: String
            let kind: String
            let location: String
            let name: String

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.identity = try container.decode(String.self, forKey: .identity)
                self.kind = try container.decode(String.self, forKey: .kind)
                self.name = try container.decode(String.self, forKey: .name)
                if let location = try container.decodeIfPresent(String.self, forKey: .location) {
                    self.location = location
                } else if let path = try container.decodeIfPresent(String.self, forKey: .path) {
                    self.location = path
                } else {
                    throw StringError("invalid package ref, missing location and path")
                }
            }

            enum CodingKeys: CodingKey {
                case identity
                case kind
                case location
                case path
                case name
            }
        }
    }
}

extension Workspace.ManagedDependency {
    fileprivate init(_ dependency: WorkspaceStateStorage.V4.Dependency) throws {
        try self.init(
            packageRef: .init(dependency.packageRef),
            state: dependency.state.underlying,
            subpath: RelativePath(validating: dependency.subpath)
        )
    }
}

extension Workspace.ManagedArtifact {
    fileprivate init(_ artifact: WorkspaceStateStorage.V4.Artifact) throws {
        let path = try AbsolutePath(validating: artifact.path)
        try self.init(
            packageRef: .init(artifact.packageRef),
            targetName: artifact.targetName,
            source: artifact.source.underlying,
            path: path,
            kind: .forPath(path)
        )
    }
}

extension PackageModel.PackageReference {
    fileprivate init(_ reference: WorkspaceStateStorage.V4.PackageReference) throws {
        let identity = PackageIdentity.plain(reference.identity)
        let kind: PackageModel.PackageReference.Kind
        switch reference.kind {
        case "root":
            kind = try .root(.init(validating: reference.location))
        case "local":
            kind = try .fileSystem(.init(validating: reference.location))
        case "remote":
            if let path = try? AbsolutePath(validating: reference.location) {
                kind = .localSourceControl(path)
            } else {
                kind = .remoteSourceControl(SourceControlURL(reference.location))
            }
        default:
            throw StringError("invalid package kind \(reference.kind)")
        }

        self.init(
            identity: identity,
            kind: kind,
            name: reference.name
        )
    }
}

extension CheckoutState {
    fileprivate init(_ state: WorkspaceStateStorage.V4.Dependency.State.CheckoutInfo) throws {
        let revision: Revision = .init(identifier: state.revision)
        if let branch = state.branch {
            self = .branch(name: branch, revision: revision)
        } else if let version = state.version {
            self = try .version(Version(versionString: version), revision: revision)
        } else {
            self = .revision(revision)
        }
    }
}

// backwards compatibility for older formats

extension BinaryTarget.Kind {
    fileprivate static func forPath(_ path: AbsolutePath) -> Self {
        if let kind = Self.allCases.first(where: { $0.fileExtension == path.extension }) {
            return kind
        }
        return .unknown
    }
}
