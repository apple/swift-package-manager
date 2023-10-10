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
import struct Basics.SwiftVersion

public final class SwiftTarget: Target {
    /// The default name for the test entry point file located in a package.
    public static let defaultTestEntryPointName = "XCTMain.swift"

    /// The list of all supported names for the test entry point file located in a package.
    public static var testEntryPointNames: [String] {
        [defaultTestEntryPointName, "LinuxMain.swift"]
    }

    public init(name: String, dependencies: [Target.Dependency], packageAccess: Bool, testDiscoverySrc: Sources) {
        self.swiftVersion = .v5

        super.init(
            name: name,
            type: .library,
            path: .root,
            sources: testDiscoverySrc,
            dependencies: dependencies,
            packageAccess: packageAccess,
            buildSettings: .init(),
            pluginUsages: [],
            usesUnsafeFlags: false
        )
    }

    /// The swift version of this target.
    public let swiftVersion: SwiftLanguageVersion

    public init(
        name: String,
        potentialBundleName: String? = nil,
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
    ) {
        self.swiftVersion = swiftVersion
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

    /// Create an executable Swift target from test entry point file.
    public init(name: String, dependencies: [Target.Dependency], packageAccess: Bool, testEntryPointPath: AbsolutePath) {
        // Look for the first swift test target and use the same swift version
        // for linux main target. This will need to change if we move to a model
        // where we allow per target swift language version build settings.
        let swiftTestTarget = dependencies.first {
            guard case .target(let target as SwiftTarget, _) = $0 else { return false }
            return target.type == .test
        }.flatMap { $0.target as? SwiftTarget }

        // FIXME: This is not very correct but doesn't matter much in practice.
        // We need to select the latest Swift language version that can
        // satisfy the current tools version but there is not a good way to
        // do that currently.
        self.swiftVersion = swiftTestTarget?.swiftVersion ?? SwiftLanguageVersion(string: String(SwiftVersion.current.major)) ?? .v4
        let sources = Sources(paths: [testEntryPointPath], root: testEntryPointPath.parentDirectory)

        super.init(
            name: name,
            type: .executable,
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
        case swiftVersion
    }

    public override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(swiftVersion, forKey: .swiftVersion)
        try super.encode(to: encoder)
    }

    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.swiftVersion = try container.decode(SwiftLanguageVersion.self, forKey: .swiftVersion)
        try super.init(from: decoder)
    }

    public var supportsTestableExecutablesFeature: Bool {
        // Exclude macros from testable executables if they are built as dylibs.
        #if BUILD_MACROS_AS_DYLIBS
        return type == .executable || type == .snippet
        #else
        return type == .executable || type == .macro || type == .snippet
        #endif
    }
}
