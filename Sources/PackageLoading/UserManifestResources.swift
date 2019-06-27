/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basic

/// Concrete object for manifest resource provider.
public struct UserManifestResources: ManifestResourceProvider {
    public let swiftCompiler: AbsolutePath
    public let libDir: AbsolutePath
    public let sdkRoot: AbsolutePath?

    public init(
        swiftCompiler: AbsolutePath,
        libDir: AbsolutePath,
        sdkRoot: AbsolutePath? = nil
        ) {
        self.swiftCompiler = swiftCompiler
        self.libDir = libDir
        self.sdkRoot = sdkRoot
    }

    public static func libDir(forBinDir binDir: AbsolutePath) -> AbsolutePath {
        return binDir.parentDirectory.appending(components: "lib", "swift", "pm")
    }

    /// Creates the set of manifest resources associated with a `swift` executable.
    ///
    /// - Parameters:
    ///     - swiftExectuable: The absolute path of the associated `swift` executable.
    public init(swiftExectuable: AbsolutePath) throws {
        let binDir = swiftExectuable.parentDirectory
        self.init(
            swiftCompiler: swiftExectuable.parentDirectory.appending(component: "swiftc"),
            libDir: UserManifestResources.libDir(forBinDir: binDir))
    }
}
