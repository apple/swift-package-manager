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

/// A manifest condition.
public protocol PackageConditionProtocol: Codable {
    func satisfies(_ environment: BuildEnvironment) -> Bool
}

/// Wrapper for package condition so it can conform to Codable.
struct PackageConditionWrapper: Codable, Equatable, Hashable {
    var platform: PlatformsCondition?
    var config: ConfigurationCondition?
    var traits: TraitCondition?

    @available(*, deprecated, renamed: "underlying")
    var condition: PackageConditionProtocol {
        if let platform {
            return platform
        } else if let config {
            return config
        } else {
            fatalError("unreachable")
        }
    }

    var underlying: PackageCondition {
        if let platform {
            return .platforms(platform)
        } else if let config {
            return .configuration(config)
        } else if let traits {
            return .traits(traits)
        } else {
            fatalError("unreachable")
        }
    }

    @available(*, deprecated, message: "Use .init(_ condition: PackageCondition) instead")
    init(_ condition: PackageConditionProtocol) {
        switch condition {
        case let platform as PlatformsCondition:
            self.platform = platform
        case let config as ConfigurationCondition:
            self.config = config
        default:
            fatalError("unknown condition \(condition)")
        }
    }

    init(_ condition: PackageCondition) {
        switch condition {
        case let .platforms(platforms):
            self.platform = platforms
        case let .configuration(configuration):
            self.config = configuration
        case .traits(let traits):
            self.traits = traits
        }
    }
}

/// One of possible conditions used in package manifests to restrict targets from being built for certain platforms or
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
public struct PlatformsCondition: PackageConditionProtocol, Hashable, Sendable {
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
public struct ConfigurationCondition: PackageConditionProtocol, Hashable, Sendable {
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
public struct TraitCondition: PackageConditionProtocol, Hashable, Sendable {
    public let enabledTraits: Set<String>

    public init(enabledTraits: Set<String>) {
        self.enabledTraits = enabledTraits
    }

    public func satisfies(_ environment: BuildEnvironment) -> Bool {
        return true
    }
}

