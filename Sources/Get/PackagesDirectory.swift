/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basic
import PackageLoading
import PackageModel
import Utility

import struct PackageDescription.Version
import func POSIX.rename

/// A container for fetched packages.
///
/// Despite being currently called `PackagesDirectory`, this actually holds
/// repositories and is used to vend a set of resolved manifests.
///
/// This object also exposes the capability to resolve a package graph while
/// loading packages. This is not conceptually the right division of
/// responsibility, but it is pragmatic for now.
public final class PackagesDirectory {
    /// The root package path.
    let rootPath: AbsolutePath

    /// The manifest loader.
    let manifestLoader: ManifestLoader

    /// Create a new package directory.
    ///
    /// - Parameters
    ///   - rootPath: The path of the root package, inside which the "Packages/"
    ///   subdirectory will be created.
    public init(root rootPath: AbsolutePath, manifestLoader: ManifestLoader) {
        self.rootPath = rootPath
        self.manifestLoader = manifestLoader
    }

    /// The path to the packages.
    var packagesPath: AbsolutePath {
        return rootPath.appending("Packages")
    }
    
    /// The set of all repositories available within the `Packages` directory, by origin.
    fileprivate lazy var availableRepositories: [String: Git.Repo] = { [unowned self] in
        // FIXME: Lift this higher.
        guard localFileSystem.isDirectory(self.packagesPath) else { return [:] }

        var result = Dictionary<String, Git.Repo>()
        for name in try! localFileSystem.getDirectoryContents(self.packagesPath) {
            let prefix = self.packagesPath.appending(RelativePath(name))
            guard let repo = Git.Repo(path: prefix), let origin = repo.origin else { continue } // TODO: Warn user.
            result[origin] = repo
        }
        return result
    }()

    /// Recursively fetch the dependencies for the root package.
    ///
    /// - Parameters:
    ///   - ignoreDependencies: If true, then skip resolution (and loading) of the package dependencies.
    /// - Returns: The loaded root package and all external packages, with dependencies resolved.
    /// - Throws: Error.InvalidDependencyGraph
    public func loadManifests(ignoreDependencies: Bool = false) throws -> (rootManifest: Manifest, externalManifests: [Manifest]) {
        // Load the manifest for the root package.
        let manifest = try manifestLoader.load(path: rootPath, baseURL: rootPath.asString, version: nil)
        if ignoreDependencies {
            return (manifest, [])
        }

        // Resolve and fetch all package dependencies and their manifests.
        let externalManifests = try recursivelyFetch(manifest.dependencies)

        return (manifest, externalManifests)
    }
}

/// Support fetching using the PackagesDirectory directly.
extension PackagesDirectory: Fetcher {
    typealias T = Manifest

    /// Extract the package version from a path.
    //
    // FIXME: This is really gross, and should not be necessary -- we should
    // maintain the state we care about in a well defined format, not just via
    // the file system path.
    private func extractPackageVersion(_ name: String) -> Version? {
        // Search each suffix separated by a '-'.
        var name = name
        while let separatorIndex = name.characters.rindex(of: "-") {
            // See if there is a parseable version (there could be prerelease identifiers, etc.).
            let versionString = String(name.characters.suffix(from: name.index(after: separatorIndex)))
            if let version = Version(versionString) {
                return version
            }

            // If not, keep looking.
            name = String(name.characters.prefix(upTo: separatorIndex))
        }
        return nil
    }
        
    /// Create a Manifest for a given repositories current state.
    private func createManifest(repo: Git.Repo) throws -> Manifest? {
        guard let origin = repo.origin else {
            throw Package.Error.noOrigin(repo.path.asString)
        }
        guard let version = extractPackageVersion(repo.path.basename) else {
            return nil
        }

        return try manifestLoader.load(path: repo.path, baseURL: origin, version: version)
    }
    
    func find(url: String) throws -> Fetchable? {
        if let repo = availableRepositories[url] {
            return try createManifest(repo: repo)
        }
        return nil
    }

    func fetch(url: String) throws -> Fetchable {
        // Clone into a staging location, we will rename it once all versions are selected.
        let dstdir = packagesPath.appending(component: url.basename)
        if let repo = Git.Repo(path: dstdir), repo.origin == url {
            //TODO need to canonicalize the URL need URL struct
            return try RawClone(path: dstdir, manifestParser: manifestLoader.load)
        }

        // fetch as well, clone does not fetch all tags, only tags on the master branch
        try Git.clone(url, to: dstdir).fetch()

        return try RawClone(path: dstdir, manifestParser: manifestLoader.load)
    }

    func finalize(_ fetchable: Fetchable) throws -> Manifest {
        switch fetchable {
        case let clone as RawClone:
            let prefix = self.packagesPath.appending(component: clone.finalName)
            try mkdir(packagesPath.parentDirectory, recursive: true)
            try rename(old: clone.path.asString, new: prefix.asString)
            //TODO don't reparse the manifest!
            let repo = Git.Repo(path: prefix)!

            // Update the available repositories.
            availableRepositories[repo.origin!] = repo
            
            return try createManifest(repo: repo)!
        case let manifest as Manifest:
            return manifest
        default:
            fatalError("Unexpected Fetchable Type: \(fetchable)")
        }
    }
}

//TODO normalize urls eg http://github.com -> https://github.com
//TODO probably should respect any relocation that applies during git transfer
//TODO detect cycles?

extension Manifest {
    var dependencies: [(String, Range<Version>)] {
        return package.dependencies.map{ ($0.url, $0.versionRange) }
    }
}
