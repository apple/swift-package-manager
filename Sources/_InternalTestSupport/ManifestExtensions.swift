//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation
import PackageModel

import struct TSCUtility.Version

extension Manifest {
    public static func createRootManifest(
        displayName: String,
        path: AbsolutePath = .root,
        defaultLocalization: String? = nil,
        platforms: [PlatformDescription] = [],
        version: TSCUtility.Version? = nil,
        toolsVersion: ToolsVersion = .v4,
        pkgConfig: String? = nil,
        providers: [SystemPackageProviderDescription]? = nil,
        cLanguageStandard: String? = nil,
        cxxLanguageStandard: String? = nil,
        swiftLanguageVersions: [SwiftLanguageVersion]? = nil,
        dependencies: [PackageDependency] = [],
        products: [ProductDescription] = [],
        targets: [TargetDescription] = [],
        traits: Set<TraitDescription> = []
    ) -> Manifest {
        Self.createManifest(
            displayName: displayName,
            path: path,
            packageKind: .root(path),
            packageLocation: path.pathString,
            defaultLocalization: defaultLocalization,
            platforms: platforms,
            version: version,
            toolsVersion: toolsVersion,
            pkgConfig: pkgConfig,
            providers: providers,
            cLanguageStandard: cLanguageStandard,
            cxxLanguageStandard: cxxLanguageStandard,
            swiftLanguageVersions: swiftLanguageVersions,
            dependencies: dependencies,
            products: products,
            targets: targets,
            traits: traits
        )
    }

    public static func createFileSystemManifest(
        displayName: String,
        path: AbsolutePath,
        defaultLocalization: String? = nil,
        platforms: [PlatformDescription] = [],
        version: TSCUtility.Version? = nil,
        toolsVersion: ToolsVersion = .v4,
        pkgConfig: String? = nil,
        providers: [SystemPackageProviderDescription]? = nil,
        cLanguageStandard: String? = nil,
        cxxLanguageStandard: String? = nil,
        swiftLanguageVersions: [SwiftLanguageVersion]? = nil,
        dependencies: [PackageDependency] = [],
        products: [ProductDescription] = [],
        targets: [TargetDescription] = [],
        traits: Set<TraitDescription> = []
    ) -> Manifest {
        Self.createManifest(
            displayName: displayName,
            path: path,
            packageKind: .fileSystem(path),
            packageLocation: path.pathString,
            defaultLocalization: defaultLocalization,
            platforms: platforms,
            version: version,
            toolsVersion: toolsVersion,
            pkgConfig: pkgConfig,
            providers: providers,
            cLanguageStandard: cLanguageStandard,
            cxxLanguageStandard: cxxLanguageStandard,
            swiftLanguageVersions: swiftLanguageVersions,
            dependencies: dependencies,
            products: products,
            targets: targets,
            traits: traits
        )
    }

    public static func createLocalSourceControlManifest(
        displayName: String,
        path: AbsolutePath,
        defaultLocalization: String? = nil,
        platforms: [PlatformDescription] = [],
        version: TSCUtility.Version? = nil,
        toolsVersion: ToolsVersion = .v4,
        pkgConfig: String? = nil,
        providers: [SystemPackageProviderDescription]? = nil,
        cLanguageStandard: String? = nil,
        cxxLanguageStandard: String? = nil,
        swiftLanguageVersions: [SwiftLanguageVersion]? = nil,
        dependencies: [PackageDependency] = [],
        products: [ProductDescription] = [],
        targets: [TargetDescription] = []
    ) -> Manifest {
        Self.createManifest(
            displayName: displayName,
            path: path,
            packageKind: .localSourceControl(path),
            packageLocation: path.pathString,
            defaultLocalization: defaultLocalization,
            platforms: platforms,
            version: version,
            toolsVersion: toolsVersion,
            pkgConfig: pkgConfig,
            providers: providers,
            cLanguageStandard: cLanguageStandard,
            cxxLanguageStandard: cxxLanguageStandard,
            swiftLanguageVersions: swiftLanguageVersions,
            dependencies: dependencies,
            products: products,
            targets: targets
        )
    }

    public static func createRemoteSourceControlManifest(
        displayName: String,
        url: SourceControlURL,
        path: AbsolutePath,
        defaultLocalization: String? = nil,
        platforms: [PlatformDescription] = [],
        version: TSCUtility.Version? = nil,
        toolsVersion: ToolsVersion = .v4,
        pkgConfig: String? = nil,
        providers: [SystemPackageProviderDescription]? = nil,
        cLanguageStandard: String? = nil,
        cxxLanguageStandard: String? = nil,
        swiftLanguageVersions: [SwiftLanguageVersion]? = nil,
        dependencies: [PackageDependency] = [],
        products: [ProductDescription] = [],
        targets: [TargetDescription] = []
    ) -> Manifest {
        Self.createManifest(
            displayName: displayName,
            path: path,
            packageKind: .remoteSourceControl(url),
            packageLocation: url.absoluteString,
            defaultLocalization: defaultLocalization,
            platforms: platforms,
            version: version,
            toolsVersion: toolsVersion,
            pkgConfig: pkgConfig,
            providers: providers,
            cLanguageStandard: cLanguageStandard,
            cxxLanguageStandard: cxxLanguageStandard,
            swiftLanguageVersions: swiftLanguageVersions,
            dependencies: dependencies,
            products: products,
            targets: targets
        )
    }

    public static func createRegistryManifest(
        displayName: String,
        identity: PackageIdentity,
        path: AbsolutePath = .root,
        defaultLocalization: String? = nil,
        platforms: [PlatformDescription] = [],
        version: TSCUtility.Version? = nil,
        toolsVersion: ToolsVersion = .v4,
        pkgConfig: String? = nil,
        providers: [SystemPackageProviderDescription]? = nil,
        cLanguageStandard: String? = nil,
        cxxLanguageStandard: String? = nil,
        swiftLanguageVersions: [SwiftLanguageVersion]? = nil,
        dependencies: [PackageDependency] = [],
        products: [ProductDescription] = [],
        targets: [TargetDescription] = []
    ) -> Manifest {
        Self.createManifest(
            displayName: displayName,
            path: path,
            packageKind: .registry(identity),
            packageLocation: identity.description,
            defaultLocalization: defaultLocalization,
            platforms: platforms,
            version: version,
            toolsVersion: toolsVersion,
            pkgConfig: pkgConfig,
            providers: providers,
            cLanguageStandard: cLanguageStandard,
            cxxLanguageStandard: cxxLanguageStandard,
            swiftLanguageVersions: swiftLanguageVersions,
            dependencies: dependencies,
            products: products,
            targets: targets
        )
    }

    public static func createManifest(
        displayName: String,
        path: AbsolutePath = .root,
        packageKind: PackageReference.Kind,
        packageLocation: String? = nil,
        defaultLocalization: String? = nil,
        platforms: [PlatformDescription] = [],
        version: TSCUtility.Version? = nil,
        toolsVersion: ToolsVersion,
        pkgConfig: String? = nil,
        providers: [SystemPackageProviderDescription]? = nil,
        cLanguageStandard: String? = nil,
        cxxLanguageStandard: String? = nil,
        swiftLanguageVersions: [SwiftLanguageVersion]? = nil,
        dependencies: [PackageDependency] = [],
        products: [ProductDescription] = [],
        targets: [TargetDescription] = [],
        traits: Set<TraitDescription> = []
    ) -> Manifest {
        return Manifest(
            displayName: displayName,
            path: path.basename == Manifest.filename ? path : path.appending(component: Manifest.filename),
            packageKind: packageKind,
            packageLocation: packageLocation ?? path.pathString,
            defaultLocalization: defaultLocalization,
            platforms: platforms,
            version: version,
            revision: .none,
            toolsVersion: toolsVersion,
            pkgConfig: pkgConfig,
            providers: providers,
            cLanguageStandard: cLanguageStandard,
            cxxLanguageStandard: cxxLanguageStandard,
            swiftLanguageVersions: swiftLanguageVersions,
            dependencies: dependencies,
            products: products,
            targets: targets,
            traits: traits
        )
    }

    public func with(location: String) -> Manifest {
        Manifest(
            displayName: self.displayName,
            path: self.path,
            packageKind: self.packageKind,
            packageLocation: location,
            defaultLocalization: self.defaultLocalization,
            platforms: self.platforms,
            version: self.version,
            revision: self.revision,
            toolsVersion: self.toolsVersion,
            pkgConfig: self.pkgConfig,
            providers: self.providers,
            cLanguageStandard: self.cLanguageStandard,
            cxxLanguageStandard: self.cxxLanguageStandard,
            swiftLanguageVersions: self.swiftLanguageVersions,
            dependencies: self.dependencies,
            products: self.products,
            targets: self.targets,
            traits: self.traits
        )
    }
}
