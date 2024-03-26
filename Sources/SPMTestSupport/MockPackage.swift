//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation
import PackageModel

package struct MockPackage {
    package let name: String
    package let platforms: [PlatformDescription]
    package let location: Location
    package let targets: [MockTarget]
    package let products: [MockProduct]
    package let dependencies: [MockDependency]
    package let versions: [String?]
    package let traits: Set<TraitDescription>
    package let defaultTraits: Set<String>

    /// Provides revision identifier for the given version. A random identifier might be assigned if this is nil.
    package let revisionProvider: ((String) -> String)?
    // FIXME: This should be per-version.
    package let toolsVersion: ToolsVersion?

    package init(
        name: String,
        platforms: [PlatformDescription] = [],
        path: String? = nil,
        targets: [MockTarget],
        products: [MockProduct] = [],
        dependencies: [MockDependency] = [],
        traits: Set<TraitDescription> = [],
        defaultTraits: Set<String> = [],
        versions: [String?] = [],
        revisionProvider: ((String) -> String)? = nil,
        toolsVersion: ToolsVersion? = nil
    ) {
        let path = try! RelativePath(validating: path ?? name)
        self.name = name
        self.platforms = platforms
        self.location = .fileSystem(path: path)
        self.targets = targets
        self.products = products
        self.dependencies = dependencies
        self.traits = traits
        self.defaultTraits = defaultTraits
        self.versions = versions
        self.revisionProvider = revisionProvider
        self.toolsVersion = toolsVersion
    }

    package init(
        name: String,
        platforms: [PlatformDescription] = [],
        url: String,
        targets: [MockTarget],
        products: [MockProduct],
        dependencies: [MockDependency] = [],
        traits: Set<TraitDescription> = [],
        defaultTraits: Set<String> = [],
        versions: [String?] = [],
        revisionProvider: ((String) -> String)? = nil,
        toolsVersion: ToolsVersion? = nil
    ) {
        self.name = name
        self.platforms = platforms
        self.location = .sourceControl(url: SourceControlURL(url))
        self.targets = targets
        self.products = products
        self.dependencies = dependencies
        self.traits = traits
        self.defaultTraits = defaultTraits
        self.versions = versions
        self.revisionProvider = revisionProvider
        self.toolsVersion = toolsVersion
    }

    package init(
        name: String,
        platforms: [PlatformDescription] = [],
        identity: String,
        alternativeURLs: [String]? = .none,
        metadata: RegistryReleaseMetadata? = .none,
        targets: [MockTarget],
        products: [MockProduct],
        dependencies: [MockDependency] = [],
        traits: Set<TraitDescription> = [],
        defaultTraits: Set<String> = [],
        versions: [String?] = [],
        revisionProvider: ((String) -> String)? = nil,
        toolsVersion: ToolsVersion? = nil
    ) {
        self.name = name
        self.platforms = platforms
        self.location = .registry(
            identity: .plain(identity),
            alternativeURLs: alternativeURLs?.compactMap{ URL(string: $0) },
            metadata: metadata
        )
        self.targets = targets
        self.products = products
        self.dependencies = dependencies
        self.traits = traits
        self.defaultTraits = defaultTraits
        self.versions = versions
        self.revisionProvider = revisionProvider
        self.toolsVersion = toolsVersion
    }

    package static func genericPackage(named name: String) throws -> MockPackage {
        return MockPackage(
            name: name,
            targets: [
                try MockTarget(name: name),
            ],
            products: [
                MockProduct(name: name, targets: [name]),
            ],
            versions: ["1.0.0"]
        )
    }

    package enum Location {
        case fileSystem(path: RelativePath)
        case sourceControl(url: SourceControlURL)
        case registry(identity: PackageIdentity, alternativeURLs: [URL]?, metadata: RegistryReleaseMetadata?)
    }
}
