/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import func POSIX.realpath
import func POSIX.unlink
import PackageDescription
import PackageType
import Utility
import func Utility.fopen
import Foundation

extension Manifest {
    public init(path pathComponents: String..., baseURL: String, swiftc: String, libdir: String) throws {

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

        guard path.isFile else { throw PackageType.Package.Error.NoManifest(path) }

        if let toml = try parse(path: path, swiftc: swiftc, libdir: libdir) {
            let toml = try TOMLItem.parse(toml)
            let package = PackageDescription.Package.fromTOML(toml, baseURL: baseURL)
            let products = PackageDescription.Product.fromTOML(toml)

            self.init(path: path, package: package, products: products)
        } else {
            // As a special case, we accept an empty file as an unnamed package.
            self.init(path: path, package: PackageDescription.Package(), products: [])
        }
    }
}

private func parse(path manifestPath: String, swiftc: String, libdir: String) throws -> String? {

    // For now, we load the manifest by having Swift interpret it directly.
    // Eventually, we should have two loading processes, one that loads only
    // the the declarative package specification using the Swift compiler
    // directly and validates it.

    var cmd = [swiftc]
    cmd += ["--driver-mode=swift"]
    cmd += verbosity.ccArgs
    cmd += ["-I", libdir]
    cmd += ["-L", libdir, "-lPackageDescription"]
#if os(OSX)
    cmd += ["-target", "x86_64-apple-macosx10.10"]
#endif
    cmd += [manifestPath]

    //Previous implementation used a temporary file, however NSTask doesn't
    //allow child process to access parent's file descriptors. So instruct
    //swiftc to dump the package information on stdout.
    #if os(OSX) || os(iOS)
        let handle = NSFileHandle.standardOutput()
    #else
        let handle = NSFileHandle.fileHandleWithStandardOutput()
    #endif

    cmd += ["-fileno",  String(handle.fileDescriptor)]
    let toml = try Utility.popen(cmd)

    return toml != "" ? toml : nil
}
