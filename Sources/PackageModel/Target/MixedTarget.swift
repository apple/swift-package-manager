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

import struct Basics.AbsolutePath
import struct Basics.StringError

public final class MixedTarget: Target {

    // The Clang target for the mixed target's Clang sources.
    public let clangTarget: ClangTarget

    // The Swift target for the mixed target's Swift sources.
    public let swiftTarget: SwiftTarget

    public init(
        name: String,
        potentialBundleName: String? = nil,
        cLanguageStandard: String?,
        cxxLanguageStandard: String?,
        includeDir: AbsolutePath,
        moduleMapType: ModuleMapType,
        headers: [AbsolutePath] = [],
        type: Kind,
        path: AbsolutePath,
        sources: Sources,
        resources: [Resource] = [],
        ignored: [AbsolutePath] = [],
        others: [AbsolutePath] = [],
        dependencies: [Target.Dependency] = [],
        packageAccess: Bool,
        swiftVersion: SwiftLanguageVersion,
        buildSettings: BuildSettings.AssignmentTable = .init(),
        pluginUsages: [PluginUsage] = [],
        usesUnsafeFlags: Bool
    ) throws {
        guard type == .library || type == .test else {
            throw StringError(
                "Target with mixed sources at '\(path)' is a \(type) " +
                "target; targets with mixed language sources are only " +
                "supported for library and test targets."
            )
        }

        let swiftSources = Sources(
            paths: sources.paths.filter { path in
                guard let ext = path.extension else { return false }
                return SupportedLanguageExtension.swiftExtensions.contains(ext)
            },
            root: sources.root
        )

        self.swiftTarget = SwiftTarget(
            name: name,
            potentialBundleName: potentialBundleName,
            type: type,
            path: path,
            sources: swiftSources,
            resources: resources,
            ignored: ignored,
            others: others,
            dependencies: dependencies,
            packageAccess: packageAccess,
            swiftVersion: swiftVersion,
            buildSettings: buildSettings,
            pluginUsages: pluginUsages,
            usesUnsafeFlags: usesUnsafeFlags
        )

        let clangSources = Sources(
            paths: sources.paths.filter { path in
                guard let ext = path.extension else { return false }
                return SupportedLanguageExtension.clangTargetExtensions(toolsVersion: .current).contains(ext)
            },
            root: sources.root
        )

        self.clangTarget = try ClangTarget(
            name: name,
            potentialBundleName: potentialBundleName,
            cLanguageStandard: cLanguageStandard,
            cxxLanguageStandard: cxxLanguageStandard,
            includeDir: includeDir,
            moduleMapType: moduleMapType,
            headers: headers,
            type: type,
            path: path,
            sources: clangSources,
            resources: resources,
            ignored: ignored,
            others: others,
            buildSettings: buildSettings,
            usesUnsafeFlags: usesUnsafeFlags
        )

        super.init(
            name: name,
            potentialBundleName: potentialBundleName,
            type: type,
            path: path,
            sources: sources,
            resources: resources,
            ignored: ignored,
            others: others,
            dependencies: dependencies,
            packageAccess: packageAccess,
            buildSettings: buildSettings,
            pluginUsages: pluginUsages,
            usesUnsafeFlags: usesUnsafeFlags
        )
    }

    private enum CodingKeys: String, CodingKey {
        case clangTarget, swiftTarget
    }

    public override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clangTarget, forKey: .clangTarget)
        try container.encode(swiftTarget, forKey: .swiftTarget)
        try super.encode(to: encoder)
    }

    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.clangTarget = try container.decode(ClangTarget.self, forKey: .clangTarget)
        self.swiftTarget = try container.decode(SwiftTarget.self, forKey: .swiftTarget)
        try super.init(from: decoder)
    }
}
