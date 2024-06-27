//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

extension PackageCollectionModel {
    public enum V1 {}
}

extension PackageCollectionModel.V1 {
    public struct Collection: Equatable, Codable {
        /// The name of the package collection, for display purposes only.
        public let name: String

        /// A description of the package collection.
        public let overview: String?

        /// An array of keywords that the collection is associated with.
        public let keywords: [String]?

        /// An array of package metadata objects
        public let packages: [PackageCollectionModel.V1.Collection.Package]

        /// The version of the format to which the collection conforms.
        public let formatVersion: PackageCollectionModel.FormatVersion

        /// The revision number of this package collection.
        public let revision: Int?

        /// When the package collection was generated.
        public let generatedAt: Date

        /// The author of this package collection.
        public let generatedBy: Author?

        /// Creates a `Collection`
        public init(
            name: String,
            overview: String?,
            keywords: [String]?,
            packages: [PackageCollectionModel.V1.Collection.Package],
            formatVersion: PackageCollectionModel.FormatVersion,
            revision: Int?,
            generatedAt: Date = Date(),
            generatedBy: Author?
        ) {
            precondition(formatVersion == .v1_0, "Unsupported format version: \(formatVersion)")

            self.name = name
            self.overview = overview
            self.keywords = keywords
            self.packages = packages
            self.formatVersion = formatVersion
            self.revision = revision
            self.generatedAt = generatedAt
            self.generatedBy = generatedBy
        }

        public struct Author: Equatable, Codable {
            /// The author name.
            public let name: String

            /// Creates an `Author`
            public init(name: String) {
                self.name = name
            }
        }
    }
}

extension PackageCollectionModel.V1.Collection {
    public struct Package: Equatable, Codable {
        /// The URL of the package. Currently only Git repository URLs are supported.
        public let url: URL
        
        /// Package identity for registry (https://github.com/swiftlang/swift-package-manager/blob/main/Documentation/PackageRegistry/Registry.md#36-package-identification).
        public let identity: String?

        /// A description of the package.
        public let summary: String?

        /// An array of keywords that the package is associated with.
        public let keywords: [String]?

        /// An array of version objects representing the most recent and/or relevant releases of the package.
        public let versions: [PackageCollectionModel.V1.Collection.Package.Version]

        /// The URL of the package's README.
        public let readmeURL: URL?

        /// The package's current license info
        public let license: PackageCollectionModel.V1.License?

        /// Creates a `Package`
        public init(
            url: URL,
            identity: String? = nil,
            summary: String?,
            keywords: [String]?,
            versions: [PackageCollectionModel.V1.Collection.Package.Version],
            readmeURL: URL?,
            license: PackageCollectionModel.V1.License?
        ) {
            self.url = url
            self.identity = identity
            self.summary = summary
            self.keywords = keywords
            self.versions = versions
            self.readmeURL = readmeURL
            self.license = license
        }
    }
}

extension PackageCollectionModel.V1.Collection.Package {
    public struct Version: Equatable, Codable {
        /// The semantic version string.
        public let version: String

        /// A description of the package version.
        public let summary: String?

        /// Manifests by tools version.
        public let manifests: [String: Manifest]

        /// Tools version of the default manifest.
        public let defaultToolsVersion: String

        /// An array of compatible platforms and Swift versions that has been tested and verified for.
        public let verifiedCompatibility: [PackageCollectionModel.V1.Compatibility]?

        /// The package version's license.
        public let license: PackageCollectionModel.V1.License?

        /// The author of the package version.
        public let author: Author?

        /// The signer of the package version.
        public let signer: PackageCollectionModel.V1.Signer?

        /// When the package version was created.
        public let createdAt: Date?

        /// Creates a `Version`
        public init(
            version: String,
            summary: String?,
            manifests: [String: Manifest],
            defaultToolsVersion: String,
            verifiedCompatibility: [PackageCollectionModel.V1.Compatibility]?,
            license: PackageCollectionModel.V1.License?,
            author: Author?,
            signer: PackageCollectionModel.V1.Signer?,
            createdAt: Date?
        ) {
            self.version = version
            self.summary = summary
            self.manifests = manifests
            self.defaultToolsVersion = defaultToolsVersion
            self.verifiedCompatibility = verifiedCompatibility
            self.license = license
            self.author = author
            self.signer = signer
            self.createdAt = createdAt
        }

        public struct Manifest: Equatable, Codable {
            /// The tools (semantic) version specified in `Package.swift`.
            public let toolsVersion: String

            /// The name of the package.
            public let packageName: String

            /// An array of the package version's targets.
            public let targets: [PackageCollectionModel.V1.Target]

            /// An array of the package version's products.
            public let products: [PackageCollectionModel.V1.Product]

            /// An array of the package version’s supported platforms specified in `Package.swift`.
            public let minimumPlatformVersions: [PackageCollectionModel.V1.PlatformVersion]?

            /// Creates a `Manifest`
            public init(
                toolsVersion: String,
                packageName: String,
                targets: [PackageCollectionModel.V1.Target],
                products: [PackageCollectionModel.V1.Product],
                minimumPlatformVersions: [PackageCollectionModel.V1.PlatformVersion]?
            ) {
                self.toolsVersion = toolsVersion
                self.packageName = packageName
                self.targets = targets
                self.products = products
                self.minimumPlatformVersions = minimumPlatformVersions
            }
        }

        public struct Author: Equatable, Codable {
            /// The author name.
            public let name: String

            /// Creates an `Author`
            public init(name: String) {
                self.name = name
            }
        }
    }
}

extension PackageCollectionModel.V1 {
    public struct Target: Equatable, Codable {
        /// The target name.
        public let name: String

        /// The module name if this target can be imported as a module.
        public let moduleName: String?

        /// Creates a `Target`
        public init(name: String, moduleName: String?) {
            self.name = name
            self.moduleName = moduleName
        }
    }

    public struct Product: Equatable, Codable {
        /// The product name.
        public let name: String

        /// The product type.
        public let type: ProductType

        /// An array of the product’s targets.
        public let targets: [String]

        /// Creates a `Product`
        public init(
            name: String,
            type: ProductType,
            targets: [String]
        ) {
            self.name = name
            self.type = type
            self.targets = targets
        }
    }

    public struct PlatformVersion: Equatable, Codable {
        /// The name of the platform (e.g., macOS, Linux, etc.).
        public let name: String

        /// The semantic version of the platform.
        public let version: String

        /// Creates a `PlatformVersion`
        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    public struct Platform: Equatable, Codable {
        /// The name of the platform (e.g., macOS, Linux, etc.).
        public let name: String

        /// Creates a `Platform`
        public init(name: String) {
            self.name = name
        }
    }

    /// Compatible platform and Swift version.
    public struct Compatibility: Equatable, Codable {
        /// The platform (e.g., macOS, Linux, etc.)
        public let platform: Platform

        /// The Swift version
        public let swiftVersion: String

        /// Creates a `Compatibility`
        public init(platform: Platform, swiftVersion: String) {
            self.platform = platform
            self.swiftVersion = swiftVersion
        }
    }

    public struct License: Equatable, Codable {
        /// License name (e.g., Apache-2.0, MIT, etc.)
        public let name: String?

        /// The URL of the license file.
        public let url: URL

        /// Creates a `License`
        public init(name: String?, url: URL) {
            self.name = name
            self.url = url
        }
    }

    public struct Signer: Equatable, Codable {
        /// The signer type. (e.g., ADP)
        public let type: String

        /// The common name of the signing certificate's subject.
        public let commonName: String

        /// The organizational unit name of the signing certificate's subject.
        public let organizationalUnitName: String

        /// The organization name of the signing certificate's subject.
        public let organizationName: String

        public init(
            type: String,
            commonName: String,
            organizationalUnitName: String,
            organizationName: String
        ) {
            self.type = type
            self.commonName = commonName
            self.organizationalUnitName = organizationalUnitName
            self.organizationName = organizationName
        }
    }
}

extension PackageCollectionModel.V1.Platform: Hashable {
    public var hashValue: Int { name.hashValue }

    public func hash(into hasher: inout Hasher) {
        name.hash(into: &hasher)
    }
}

extension PackageCollectionModel.V1.Platform: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.name < rhs.name
    }
}

extension PackageCollectionModel.V1.Compatibility: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.platform != rhs.platform { return lhs.platform < rhs.platform }
        return lhs.swiftVersion < rhs.swiftVersion
    }
}

// MARK: -  Copy `PackageModel.ProductType` to minimize the module's dependencies

extension PackageCollectionModel.V1 {
    /// The type of product.
    public enum ProductType: Equatable {
        /// The type of library.
        public enum LibraryType: String, Codable {
            /// Static library.
            case `static`

            /// Dynamic library.
            case dynamic

            /// The type of library is unspecified and should be decided by package manager.
            case automatic
        }

        /// A library product.
        case library(LibraryType)

        /// An executable product.
        case executable

        /// An plugin product.
        case plugin
        
        /// An executable code snippet.
        case snippet

        /// A test product.
        case test
        
        /// A macro product.
        case `macro`
    }
}

extension PackageCollectionModel.V1.ProductType: Codable {
    private enum CodingKeys: String, CodingKey {
        case library, executable, plugin, snippet, test, `macro`
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .library(let a1):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .library)
            try unkeyedContainer.encode(a1)
        case .executable:
            try container.encodeNil(forKey: .executable)
        case .plugin:
            try container.encodeNil(forKey: .plugin)
        case .snippet:
            try container.encodeNil(forKey: .snippet)
        case .test:
            try container.encodeNil(forKey: .test)
        case .macro:
            try container.encodeNil(forKey: .macro)
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = values.allKeys.first(where: values.contains) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Did not find a matching key"))
        }
        switch key {
        case .library:
            var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
            let a1 = try unkeyedValues.decode(PackageCollectionModel.V1.ProductType.LibraryType.self)
            self = .library(a1)
        case .executable:
            self = .executable
        case .plugin:
            self = .plugin
        case .snippet:
            self = .snippet
        case .test:
            self = .test
        case .macro:
            self = .macro
        }
    }
}

// MARK: - Signed package collection

extension PackageCollectionModel.V1 {
    /// A  signed package collection. The only difference between this and `Collection`
    /// is the presence of `signature`.
    public struct SignedCollection: Equatable {
        /// The package collection
        public let collection: PackageCollectionModel.V1.Collection

        /// The signature and metadata
        public let signature: PackageCollectionModel.V1.Signature

        /// Creates a `SignedCollection`
        public init(collection: PackageCollectionModel.V1.Collection, signature: PackageCollectionModel.V1.Signature) {
            self.collection = collection
            self.signature = signature
        }
    }

    /// Package collection signature and associated metadata
    public struct Signature: Equatable, Codable {
        /// The signature
        public let signature: String

        /// Details about the certificate used to generate the signature
        public let certificate: Certificate

        public init(signature: String, certificate: Certificate) {
            self.signature = signature
            self.certificate = certificate
        }

        public struct Certificate: Equatable, Codable {
            /// Subject of the certificate
            public let subject: Name

            /// Issuer of the certificate
            public let issuer: Name

            /// Creates a `Certificate`
            public init(subject: Name, issuer: Name) {
                self.subject = subject
                self.issuer = issuer
            }

            /// Generic certificate name (e.g., subject, issuer)
            public struct Name: Equatable, Codable {
                /// User ID
                public let userID: String?

                /// Common name
                public let commonName: String?

                /// Organizational unit
                public let organizationalUnit: String?

                /// Organization
                public let organization: String?

                /// Creates a `Name`
                public init(userID: String?,
                            commonName: String?,
                            organizationalUnit: String?,
                            organization: String?) {
                    self.userID = userID
                    self.commonName = commonName
                    self.organizationalUnit = organizationalUnit
                    self.organization = organization
                }
            }
        }
    }
}

extension PackageCollectionModel.V1.SignedCollection: Codable {
    enum CodingKeys: String, CodingKey {
        // Collection properties
        case name
        case overview
        case keywords
        case packages
        case formatVersion
        case revision
        case generatedAt
        case generatedBy

        case signature
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.collection.name, forKey: .name)
        try container.encodeIfPresent(self.collection.overview, forKey: .overview)
        try container.encodeIfPresent(self.collection.keywords, forKey: .keywords)
        try container.encode(self.collection.packages, forKey: .packages)
        try container.encode(self.collection.formatVersion, forKey: .formatVersion)
        try container.encodeIfPresent(self.collection.revision, forKey: .revision)
        try container.encode(self.collection.generatedAt, forKey: .generatedAt)
        try container.encodeIfPresent(self.collection.generatedBy, forKey: .generatedBy)
        try container.encode(self.signature, forKey: .signature)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.collection = try PackageCollectionModel.V1.Collection(from: decoder)
        self.signature = try container.decode(PackageCollectionModel.V1.Signature.self, forKey: .signature)
    }
}
