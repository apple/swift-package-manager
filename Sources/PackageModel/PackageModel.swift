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
import struct Foundation.URL

import enum TSCUtility.PackageLocation
import struct TSCUtility.Version

/// The basic package representation.
///
/// The package manager conceptually works with five different kinds of
/// packages, of which this is only one:
///
/// 1. Informally, the repository containing a package can be thought of in some
/// sense as the "package". However, this isn't accurate, because the actual
/// Package is derived from its manifest, a Package only actually exists at a
/// particular repository revision (typically a tag). We also may eventually
/// want to support multiple packages within a single repository.
///
/// 2. The `PackageDescription.Package` as defined inside a manifest is a
/// declarative specification for (part of) the package but not the object that
/// the package manager itself is typically working with internally. Rather,
/// that specification is primarily used to load the package (see the
/// `PackageLoading` target).
///
/// 3. A loaded `PackageModel.Manifest` is an abstract representation of a
/// package, and is used during package dependency resolution. It contains the
/// loaded PackageDescription and information necessary for dependency
/// resolution, but nothing else.
///
/// 4. A loaded `PackageModel.Package` which has had dependencies loaded and
/// resolved. This is the result after `Get.get()`.
///
/// 5. A loaded package, as in #4, for which the targets have also been
/// loaded. There is not currently a data structure for this, but it is the
/// result after `PackageLoading.transmute()`.
public final class Package {
    /// The identity of the package.
    public let identity: PackageIdentity

    /// The manifest describing the package.
    public let manifest: Manifest

    /// The local path of the package.
    public let path: AbsolutePath

    /// The targets contained in the package.
    public var modules: [Module]

    /// The products produced by the package.
    public let products: [Product]

    // The directory containing the targets which did not explicitly specify
    // their path. If all targets are explicit, this is the preferred path for
    // future targets.
    public let targetSearchPath: AbsolutePath

    // The directory containing the test targets which did not explicitly specify
    // their path. If all test targets are explicit, this is the preferred path
    // for future test targets.
    public let testTargetSearchPath: AbsolutePath

    public init(
        identity: PackageIdentity,
        manifest: Manifest,
        path: AbsolutePath,
        targets: [Module],
        products: [Product],
        targetSearchPath: AbsolutePath,
        testTargetSearchPath: AbsolutePath
    ) {
        self.identity = identity
        self.manifest = manifest
        self.path = path
        self.modules = targets
        self.products = products
        self.targetSearchPath = targetSearchPath
        self.testTargetSearchPath = testTargetSearchPath
    }

    public enum Error: Swift.Error, Equatable {
        case noManifest(at: AbsolutePath, version: Version?)
    }
}

extension Package: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public static func == (lhs: Package, rhs: Package) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
}

extension Package {
    public var diagnosticsMetadata: ObservabilityMetadata {
        return .packageMetadata(identity: self.identity, kind: self.manifest.packageKind)
    }
}

extension Package: CustomStringConvertible {
    public var description: String {
        return self.identity.description
    }
}

extension Package.Error: CustomStringConvertible {
   public var description: String {
        switch self {
        case .noManifest(let path, let version):
            var string = "\(path) has no Package.swift manifest"
            if let version {
                string += " for version \(version)"
            }
            return string
        }
    }
}

extension Manifest {
    public var disambiguateByProductIDs: Bool {
        return self.toolsVersion >= .v5_8
    }
    public var usePackageNameFlag: Bool {
        return self.toolsVersion >= .v5_9
    }
}

extension ObservabilityMetadata {
    public static func packageMetadata(identity: PackageIdentity, kind: PackageReference.Kind) -> Self {
        var metadata = ObservabilityMetadata()
        metadata.packageIdentity = identity
        metadata.packageKind = kind
        return metadata
    }
}

extension ObservabilityMetadata {
    public var packageIdentity: PackageIdentity? {
        get {
            self[PackageIdentityKey.self]
        }
        set {
            self[PackageIdentityKey.self] = newValue
        }
    }

    enum PackageIdentityKey: Key {
        typealias Value = PackageIdentity
    }
}

/*
extension ObservabilityMetadata {
    public var packageLocation: String? {
        get {
            self[PackageLocationKey.self]
        }
        set {
            self[PackageLocationKey.self] = newValue
        }
    }

    enum PackageLocationKey: Key {
        typealias Value = String
    }
}*/

extension ObservabilityMetadata {
    public var packageKind: PackageReference.Kind? {
        get {
            self[PackageKindKey.self]
        }
        set {
            self[PackageKindKey.self] = newValue
        }
    }

    enum PackageKindKey: Key {
        typealias Value = PackageReference.Kind
    }
}
