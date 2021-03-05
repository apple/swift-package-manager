/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import TSCBasic
import PackageModel

/// A fully resolved package. Contains resolved targets, products and dependencies of the package.
public final class ResolvedPackage: ObjectIdentifierProtocol {

    /// The underlying package reference.
    public let underlyingPackage: Package

    // The identity of the package.
    public var identity: PackageIdentity {
        return self.underlyingPackage.identity
    }

    /// The manifest describing the package.
    public var manifest: Manifest {
        return self.underlyingPackage.manifest
    }

    /// The name of the package.
    @available(*, deprecated, message: "use identity (or manifestName, but only if you must) instead")
    public var name: String {
        return self.underlyingPackage.name
    }

    /// The name of the package as entered in the manifest.
    @available(*, deprecated, message: "use identity instead")
    public var manifestName: String {
        return self.underlyingPackage.manifestName
    }

    /// The local path of the package.
    public var path: AbsolutePath {
        return self.underlyingPackage.path
    }

    /// The targets contained in the package.
    public let targets: [ResolvedTarget]

    /// The products produced by the package.
    public let products: [ResolvedProduct]

    /// The dependencies of the package.
    public let dependencies: [ResolvedPackage]

    public init(
        package: Package,
        dependencies: [ResolvedPackage],
        targets: [ResolvedTarget],
        products: [ResolvedProduct]
    ) {
        self.underlyingPackage = package
        self.dependencies = dependencies
        self.targets = targets
        self.products = products
    }
}

extension ResolvedPackage: CustomStringConvertible {
    public var description: String {
        return "<ResolvedPackage: \(self.identity)>"
    }
}
