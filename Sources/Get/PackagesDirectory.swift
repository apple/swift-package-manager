/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import struct PackageDescription.Version
import func Utility.mkdir
import func Utility.rename
import PackageType
import Utility

/**
 Implementation detail: a container for fetched packages.
 */
class PackagesDirectory {
    let prefix: String
    let manifestParser: (path: String, url: String) throws -> Manifest

    init(prefix: String, manifestParser: (path: String, url: String) throws -> Manifest) {
        self.prefix = prefix
        self.manifestParser = manifestParser
    }
    
    /// The set of all repositories available within the `Packages` directory, by origin.
    private lazy var availableRepositories: [String: Git.Repo] = { [unowned self] in
        var result = Dictionary<String, Git.Repo>()
        for prefix in walk(self.prefix, recursively: false) {
            guard let repo = Git.Repo(path: prefix), origin = repo.origin else { continue } // TODO: Warn user.
            result[origin] = repo
        }
        return result
    }()
}

extension PackagesDirectory: Fetcher {
    typealias T = Package
    
    func find(url: String) throws -> Fetchable? {
        if let repo = availableRepositories[url] {
            return try Package.make(repo: repo, manifestParser: manifestParser)
        }
        return nil
    }

    func fetch(url: String) throws -> Fetchable {
        let dstdir = Path.join(prefix, Package.nameForURL(url))
        if let repo = Git.Repo(path: dstdir) where repo.origin == url {
            //TODO need to canonicalize the URL need URL struct
            return try RawClone(path: dstdir, manifestParser: manifestParser)
        }

        // fetch as well, clone does not fetch all tags, only tags on the master branch
        try Git.clone(url, to: dstdir).fetch()

        return try RawClone(path: dstdir, manifestParser: manifestParser)
    }

    func finalize(_ fetchable: Fetchable) throws -> Package {
        switch fetchable {
        case let clone as RawClone:
            let prefix = Path.join(self.prefix, clone.finalName)
            try mkdir(prefix.parentDirectory)
            try rename(old: clone.path, new: prefix)
            //TODO don't reparse the manifest!
            let repo = Git.Repo(path: prefix)!

            // Update the available repositories.
            availableRepositories[repo.origin!] = repo
            
            return try Package.make(repo: repo, manifestParser: manifestParser)!
        case let pkg as Package:
            return pkg
        default:
            fatalError("Unexpected Fetchable Type: \(fetchable)")
        }
    }
}
