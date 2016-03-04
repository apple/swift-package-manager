/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import struct PackageType.Manifest
import func POSIX.realpath
import PackageDescription
import Utility

extension Manifest {
    public init(path pathComponents: String..., baseURL: String) throws {

        guard baseURL.chuzzle() != nil else { fatalError() }  //TODO

        // canonicalize the URL
        var baseURL = baseURL
        if URL.scheme(baseURL) == nil {
            baseURL = try realpath(baseURL)
        }

        let joinedPath = Path.join(pathComponents)
        let path: String
        if joinedPath.isDirectory {
            path = Path.join(joinedPath, Manifest.filename)
        } else {
            path = joinedPath
        }

        guard path.isFile else { throw Error.NoManifest(path) }

        if let toml = try parse(path) {
            let toml = try TOMLItem.parse(toml)
            let package = PackageDescription.Package.fromTOML(toml, baseURL: baseURL)
            let products = PackageDescription.Product.fromTOML(toml)

            self.init(path: path, package: package, products: products)
        } else {
            // As a special case, we accept an empty file as an unnamed package.
            self.init(path: path, package: Package(), products: [Product]())
        }
    }
}

private func parse(manifestPath: String) throws -> String? {

    // For now, we load the manifest by having Swift interpret it directly
    // and using a special environment variable to trigger the PackageDescription
    // library to dump the package (as TOML) at exit.  Eventually, we should
    // have two loading processes, one that loads only the the declarative
    // package specification using the Swift compiler directly and validates
    // it.
    //
    // FIXME: We also should make the mechanism for communicating the
    // package between the PackageDescription module more robust, for example by passing
    // in the id of another file descriptor to write the output onto.

    let libdir = Resources.runtimeLibPath

    var cmd = [Resources.path.swiftc]
    cmd += ["--driver-mode=swift"]
    cmd += ["-I", libdir]
    cmd += ["-L", libdir, "-lPackageDescription"]
    cmd += verbosity.ccArgs
#if os(OSX)
    cmd += ["-target", "x86_64-apple-macosx10.10"]
#endif
    cmd += [manifestPath]

    return try popen(cmd, environment: ["SWIFT_DUMP_PACKAGE": "1"]).chuzzle()
}
