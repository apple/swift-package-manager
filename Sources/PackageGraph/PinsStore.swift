/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Configurations
import PackageModel
import TSCBasic
import TSCUtility
import SourceControl

public final class PinsStore {
    public typealias PinsMap = [PackageIdentity: PinsStore.Pin]

    public struct Pin: Equatable {
        /// The package reference of the pinned dependency.
        public let packageRef: PackageReference

        /// The pinned state.
        public let state: CheckoutState

        public init(
            packageRef: PackageReference,
            state: CheckoutState
        ) {
            self.packageRef = packageRef
            self.state = state
        }
    }

    /// The schema version of the resolved file.
    ///
    /// * 1: Initial version.
    static let schemaVersion: Int = 1

    /// The path to the pins file.
    private let pinsFile: AbsolutePath

    /// The filesystem to manage the pin file on.
    private var fileSystem: FileSystem

    private let mirrors: Configuration.Mirrors

    /// The pins map.
    public fileprivate(set) var pinsMap: PinsMap

    /// The current pins.
    public var pins: AnySequence<Pin> {
        return AnySequence<Pin>(pinsMap.values)
    }

    fileprivate let persistence: SimplePersistence

    /// Create a new pins store.
    ///
    /// - Parameters:
    ///   - pinsFile: Path to the pins file.
    ///   - fileSystem: The filesystem to manage the pin file on.
    public init(pinsFile: AbsolutePath, fileSystem: FileSystem, mirrors: Configuration.Mirrors) throws {
        self.pinsFile = pinsFile
        self.fileSystem = fileSystem
        self.persistence = SimplePersistence(
            fileSystem: fileSystem,
            schemaVersion: PinsStore.schemaVersion,
            statePath: pinsFile,
            prettyPrint: true)
        self.pinsMap = [:]
        self.mirrors = mirrors
        do {
            _ = try self.persistence.restoreState(self)
        } catch SimplePersistence.Error.restoreFailure(_, let error) {
            throw StringError("Package.resolved file is corrupted or malformed; fix or delete the file to continue: \(error)")
        }
    }

    /// Pin a repository at a version.
    ///
    /// This method does not automatically write to state file.
    ///
    /// - Parameters:
    ///   - packageRef: The package reference to pin.
    ///   - state: The state to pin at.
    public func pin(
        packageRef: PackageReference,
        state: CheckoutState
    ) {
        self.pinsMap[packageRef.identity] = Pin(
            packageRef: packageRef,
            state: state
        )
    }

    /// Add a pin.
    ///
    /// This will replace any previous pin with same package name.
    public func add(_ pin: Pin) {
        self.pinsMap[pin.packageRef.identity] = pin
    }

    /// Unpin all of the currently pinned dependencies.
    ///
    /// This method does not automatically write to state file.
    public func unpinAll() {
        // Reset the pins map.
        self.pinsMap = [:]
    }

    public func saveState() throws {
        if self.pinsMap.isEmpty {
            // Remove the pins file if there are zero pins to save.
            //
            // This can happen if all dependencies are path-based or edited
            // dependencies.
            return try self.fileSystem.removeFileTree(pinsFile)
        }

        try self.persistence.saveState(self)
    }
}

// MARK: - JSON

extension PinsStore: JSONSerializable {
    /// Saves the current state of pins.
    public func toJSON() -> JSON {
        // rdar://52529014, rdar://52529011: pin file should store the original location but remap when loading
        let pinsWithOriginalLocations = self.pins.map { pin -> Pin in
            let url = self.mirrors.originalURL(for: pin.packageRef.location) ?? pin.packageRef.location
            let identity = PackageIdentity(url: url) // FIXME: pin store should also encode identity
            return Pin(packageRef: .init(identity: identity, kind: pin.packageRef.kind, location: url, name: pin.packageRef.name), state: pin.state)
        }
        return JSON([
            "pins": pinsWithOriginalLocations.sorted(by: { $0.packageRef.identity < $1.packageRef.identity }).toJSON(),
        ])
    }
}

extension PinsStore.Pin: JSONMappable, JSONSerializable {
    /// Create an instance from JSON data.
    public init(json: JSON) throws {
        let name: String? = json.get("package")
        let url: String = try json.get("repositoryURL")
        let identity = PackageIdentity(url: url) // FIXME: pin store should also encode identity
        let ref = PackageReference.remote(identity: identity, location: url)
        self.packageRef = name.flatMap(ref.with(newName:)) ?? ref
        self.state = try json.get("state")
    }

    /// Convert the pin to JSON.
    public func toJSON() -> JSON {
        return .init([
            "package": self.packageRef.name.toJSON(),
            "repositoryURL": self.packageRef.location,
            "state": self.state
        ])
    }
}

// MARK: - SimplePersistanceProtocol

extension PinsStore: SimplePersistanceProtocol {
    public func restore(from json: JSON) throws {
        let pins: [Pin] = try json.get("pins")
        // rdar://52529014, rdar://52529011: pin file should store the original location but remap when loading
        let pinsWithMirroredLocations = pins.map { pin -> Pin in
            let url = self.mirrors.effectiveURL(for: pin.packageRef.location)
            let identity = PackageIdentity(url: url) // FIXME: pin store should also encode identity
            return Pin(packageRef: .init(identity: identity, kind: pin.packageRef.kind, location: url, name: pin.packageRef.name), state: pin.state)
        }
        self.pinsMap = try Dictionary(pinsWithMirroredLocations.map({ ($0.packageRef.identity, $0) }), uniquingKeysWith: { first, _ in throw StringError("duplicated entry for package \"\(first.packageRef.name)\"") })
    }
}
