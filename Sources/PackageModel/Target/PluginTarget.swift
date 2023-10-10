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

public final class PluginTarget: Target {
    /// Declared capability of the plugin.
    public let capability: PluginCapability

    /// API version to use for PackagePlugin API availability.
    public let apiVersion: ToolsVersion

    public init(
        name: String,
        sources: Sources,
        apiVersion: ToolsVersion,
        pluginCapability: PluginCapability,
        dependencies: [Target.Dependency] = [],
        packageAccess: Bool
    ) {
        self.capability = pluginCapability
        self.apiVersion = apiVersion
        super.init(
            name: name,
            type: .plugin,
            path: .root,
            sources: sources,
            dependencies: dependencies,
            packageAccess: packageAccess,
            buildSettings: .init(),
            pluginUsages: [],
            usesUnsafeFlags: false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case capability
        case apiVersion
    }

    public override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.capability, forKey: .capability)
        try container.encode(self.apiVersion, forKey: .apiVersion)
        try super.encode(to: encoder)
    }

    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.capability = try container.decode(PluginCapability.self, forKey: .capability)
        self.apiVersion = try container.decode(ToolsVersion.self, forKey: .apiVersion)
        try super.init(from: decoder)
    }
}

public enum PluginCapability: Hashable, Codable {
    case buildTool
    case command(intent: PluginCommandIntent, permissions: [PluginPermission])

    private enum CodingKeys: String, CodingKey {
        case buildTool, command
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .buildTool:
            try container.encodeNil(forKey: .buildTool)
        case .command(let a1, let a2):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .command)
            try unkeyedContainer.encode(a1)
            try unkeyedContainer.encode(a2)
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = values.allKeys.first(where: values.contains) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Did not find a matching key"))
        }
        switch key {
        case .buildTool:
            self = .buildTool
        case .command:
            var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
            let a1 = try unkeyedValues.decode(PluginCommandIntent.self)
            let a2 = try unkeyedValues.decode([PluginPermission].self)
            self = .command(intent: a1, permissions: a2)
        }
    }

    public init(from desc: TargetDescription.PluginCapability) {
        switch desc {
        case .buildTool:
            self = .buildTool
        case .command(let intent, let permissions):
            self = .command(intent: .init(from: intent), permissions: permissions.map{ .init(from: $0) })
        }
    }
}

public enum PluginCommandIntent: Hashable, Codable {
    case documentationGeneration
    case sourceCodeFormatting
    case custom(verb: String, description: String)

    public init(from desc: TargetDescription.PluginCommandIntent) {
        switch desc {
        case .documentationGeneration:
            self = .documentationGeneration
        case .sourceCodeFormatting:
            self = .sourceCodeFormatting
        case .custom(let verb, let description):
            self = .custom(verb: verb, description: description)
        }
    }
}

public enum PluginNetworkPermissionScope: Hashable, Codable {
    case none
    case local(ports: [Int])
    case all(ports: [Int])
    case docker
    case unixDomainSocket

    init(_ scope: TargetDescription.PluginNetworkPermissionScope) {
        switch scope {
        case .none: self = .none
        case .local(let ports): self = .local(ports: ports)
        case .all(let ports): self = .all(ports: ports)
        case .docker: self = .docker
        case .unixDomainSocket: self = .unixDomainSocket
        }
    }

    public var label: String {
        switch self {
        case .all: return "all"
        case .local: return "local"
        case .none: return "none"
        case .docker: return "docker unix domain socket"
        case .unixDomainSocket: return "unix domain socket"
        }
    }

    public var ports: [Int] {
        switch self {
        case .all(let ports): return ports
        case .local(let ports): return ports
        case .none, .docker, .unixDomainSocket: return []
        }
    }
}

public enum PluginPermission: Hashable, Codable {
    case allowNetworkConnections(scope: PluginNetworkPermissionScope, reason: String)
    case writeToPackageDirectory(reason: String)

    public init(from desc: TargetDescription.PluginPermission) {
        switch desc {
        case .allowNetworkConnections(let scope, let reason):
            self = .allowNetworkConnections(scope: .init(scope), reason: reason)
        case .writeToPackageDirectory(let reason):
            self = .writeToPackageDirectory(reason: reason)
        }
    }
}
