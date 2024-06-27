//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// Represents a manifest condition.
public struct PackageConditionDescription: Codable, Hashable, Sendable {
    public let platformNames: [String]
    public let config: String?
    public let traits: Set<String>?

    public init(platformNames: [String] = [], config: String? = nil, traits: Set<String>? = nil) {
        assert(!(platformNames.isEmpty && config == nil && traits == nil))
        self.platformNames = platformNames
        self.config = config
        self.traits = traits
    }
}

/// One of possible conditions used in package manifests to restrict modules from being built for certain platforms or
/// build configurations.
public enum PackageCondition: Hashable, Sendable {
    case platforms(PlatformsCondition)
    case configuration(ConfigurationCondition)
    case traits(TraitCondition)

    public func satisfies(_ environment: BuildEnvironment) -> Bool {
        switch self {
        case .configuration(let configuration):
            return configuration.satisfies(environment)
        case .platforms(let platforms):
            return platforms.satisfies(environment)
        case .traits(let traits):
            return traits.satisfies(environment)
        }
    }

    public var platformsCondition: PlatformsCondition? {
        guard case let .platforms(platformsCondition) = self else {
            return nil
        }

        return platformsCondition
    }

    public var configurationCondition: ConfigurationCondition? {
        guard case let .configuration(configurationCondition) = self else {
            return nil
        }

        return configurationCondition
    }

    public var traitCondition: TraitCondition? {
        guard case let .traits(traitCondition) = self else {
            return nil
        }

        return traitCondition
    }

    public init(platforms: [Platform]) {
        self = .platforms(.init(platforms: platforms))
    }

    public init(configuration: BuildConfiguration) {
        self = .configuration(.init(configuration: configuration))
    }
}

/// Platforms condition implies that an assignment is valid on these platforms.
public struct PlatformsCondition: Hashable, Sendable {
    public let platforms: [Platform]

    public init(platforms: [Platform]) {
        assert(!platforms.isEmpty, "List of platforms should not be empty")
        self.platforms = platforms
    }

    public func satisfies(_ environment: BuildEnvironment) -> Bool {
        platforms.contains(environment.platform)
    }
}

/// A configuration condition implies that an assignment is valid on
/// a particular build configuration.
public struct ConfigurationCondition: Hashable, Sendable {
    public let configuration: BuildConfiguration

    public init(configuration: BuildConfiguration) {
        self.configuration = configuration
    }

    public func satisfies(_ environment: BuildEnvironment) -> Bool {
        if environment.configuration == nil {
            return true
        } else {
            return configuration == environment.configuration
        }
    }
}


/// A configuration condition implies that an assignment is valid on
/// a particular build configuration.
public struct TraitCondition: Hashable, Sendable {
    public let traits: Set<String>

    public init(traits: Set<String>) {
        self.traits = traits
    }

    public func satisfies(_ environment: BuildEnvironment) -> Bool {
        return true
    }
}

