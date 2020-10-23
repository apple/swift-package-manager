/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2018 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Foundation

import TSCBasic
import TSCUtility

/// Manages a package's configuration.
public final class DependencyMirrors {

    enum Error: Swift.Error, CustomStringConvertible {
        case mirrorNotFound

        var description: String {
            return "mirror not found"
        }
    }

    /// Persistence support.
    let persistence: SimplePersistence?

    /// The schema version of the mirrors file.
    ///
    /// * 1: Initial version.
    static let schemaVersion: Int = 1

    /// The mirrors.
    private var mirrors: [String: Mirror]

    public init(path: AbsolutePath, fs: FileSystem = localFileSystem) {
        self.mirrors = [:]
        self.persistence = SimplePersistence(
            fileSystem: fs, schemaVersion: DependencyMirrors.schemaVersion,
            statePath: path, prettyPrint: true
        )
    }

    public init() {
        self.mirrors = [:]
        self.persistence = nil
    }

    /// Set a mirror URL for the given URL.
    public func set(mirrorURL: String, forURL url: String) throws {
        mirrors[url] = Mirror(original: url, mirror: mirrorURL)
        try saveState()
    }

    /// Unset a mirror for the given URL.
    ///
    /// This method will throw if there is no mirror for the given input.
    public func unset(originalOrMirrorURL: String) throws {
        if mirrors.keys.contains(originalOrMirrorURL) {
            mirrors[originalOrMirrorURL] = nil
        } else if let mirror = mirrors.first(where: { $0.value.mirror == originalOrMirrorURL }) {
            mirrors[mirror.key] = nil
        } else {
            throw Error.mirrorNotFound
        }
        try saveState()
    }

    /// Returns the mirror for the given specificer.
    public func getMirror(forURL url: String) -> String? {
        return mirrors[url]?.mirror
    }

    /// Returns the mirrored url if it exists, otherwise the original url.
    public func mirroredURL(forURL url: String) -> String {
        return getMirror(forURL: url) ?? url
    }

    /// Load the configuration from disk.
    public func load() throws {
        _ = try self.persistence?.restoreState(self)
    }
}


extension DependencyMirrors: JSONSerializable {
    public func toJSON() -> JSON {
        // FIXME: Find a way to avoid encode-decode dance here.
        let jsonData = try! JSONEncoder().encode(mirrors.values.sorted(by: { $0.original < $1.mirror }))
        return try! JSON(data: jsonData)
    }
}

extension DependencyMirrors: SimplePersistanceProtocol {

    public func saveState() throws {
        try self.persistence?.saveState(self)
    }

    public func restore(from json: JSON) throws {
        // FIXME: Find a way to avoid encode-decode dance here.
        let data = Data(json.toBytes().contents)
        let mirrorsData = try JSONDecoder().decode([Mirror].self, from: data)
        self.mirrors = Dictionary(mirrorsData.map({ ($0.original, $0) }), uniquingKeysWith: { first, _ in first })
    }
}

/// An individual repository mirror.
fileprivate struct Mirror: Codable {
    /// The original repository path.
    let original: String

    /// The mirrored repository path.
    let mirror: String

    init(original: String, mirror: String) {
        self.original = original
        self.mirror = mirror
    }
}
