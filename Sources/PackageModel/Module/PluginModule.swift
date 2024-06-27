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

@available(*, deprecated, renamed: "PluginModule")
public typealias PluginTarget = PluginModule

public final class PluginModule: Module {
    /// Description of the module type used in `swift package describe` output. Preserved for backwards compatibility.
    public override class var typeDescription: String { "PluginTarget" }

    /// Declared capability of the plugin.
    public let capability: PluginCapability

    /// API version to use for PackagePlugin API availability.
    public let apiVersion: ToolsVersion

    public init(
        name: String,
        sources: Sources,
        apiVersion: ToolsVersion,
        pluginCapability: PluginCapability,
        dependencies: [Module.Dependency] = [],
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
            buildSettingsDescription: [],
            pluginUsages: [],
            usesUnsafeFlags: false
        )
    }
}

public enum PluginCapability: Hashable {
    case buildTool
    case command(intent: PluginCommandIntent, permissions: [PluginPermission])

    public init(from desc: TargetDescription.PluginCapability) {
        switch desc {
        case .buildTool:
            self = .buildTool
        case .command(let intent, let permissions):
            self = .command(intent: .init(from: intent), permissions: permissions.map{ .init(from: $0) })
        }
    }
}

public enum PluginCommandIntent: Hashable {
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

public enum PluginNetworkPermissionScope: Hashable {
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

public enum PluginPermission: Hashable {
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
