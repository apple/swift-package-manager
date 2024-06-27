//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct Basics.AbsolutePath
import struct Basics.SwiftVersion

@available(*, deprecated, renamed: "SwiftModule")
public typealias SwiftTarget = SwiftModule

public final class SwiftModule: Module {
    /// Description of the module type used in `swift package describe` output. Preserved for backwards compatibility.
    public override class var typeDescription: String { "SwiftTarget" }

    /// The default name for the test entry point file located in a package.
    public static let defaultTestEntryPointName = "XCTMain.swift"

    /// The list of all supported names for the test entry point file located in a package.
    public static var testEntryPointNames: [String] {
        [defaultTestEntryPointName, "LinuxMain.swift"]
    }

    public init(name: String, dependencies: [Module.Dependency], packageAccess: Bool, testDiscoverySrc: Sources) {
        self.declaredSwiftVersions = []

        super.init(
            name: name,
            type: .library,
            path: .root,
            sources: testDiscoverySrc,
            dependencies: dependencies,
            packageAccess: packageAccess,
            buildSettings: .init(),
            buildSettingsDescription: [],
            pluginUsages: [],
            usesUnsafeFlags: false
        )
    }

    /// The list of swift versions declared by the manifest.
    public let declaredSwiftVersions: [SwiftLanguageVersion]

    public init(
        name: String,
        potentialBundleName: String? = nil,
        type: Kind,
        path: AbsolutePath,
        sources: Sources,
        resources: [Resource] = [],
        ignored: [AbsolutePath] = [],
        others: [AbsolutePath] = [],
        dependencies: [Module.Dependency] = [],
        packageAccess: Bool,
        declaredSwiftVersions: [SwiftLanguageVersion] = [],
        buildSettings: BuildSettings.AssignmentTable = .init(),
        buildSettingsDescription: [TargetBuildSettingDescription.Setting] = [],
        pluginUsages: [PluginUsage] = [],
        usesUnsafeFlags: Bool
    ) {
        self.declaredSwiftVersions = declaredSwiftVersions
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
            buildSettingsDescription: buildSettingsDescription,
            pluginUsages: pluginUsages,
            usesUnsafeFlags: usesUnsafeFlags
        )
    }

    /// Create an executable Swift target from test entry point file.
    public init(
        name: String,
        dependencies: [Module.Dependency],
        packageAccess: Bool,
        testEntryPointPath: AbsolutePath
    ) {
        // Look for the first swift test target and use the same swift version
        // for linux main target. This will need to change if we move to a model
        // where we allow per target swift language version build settings.
        let swiftTestTarget = dependencies.first {
            guard case .module(let target as SwiftModule, _) = $0 else { return false }
            return target.type == .test
        }.flatMap { $0.module as? SwiftModule }

        // We need to select the latest Swift language version that can
        // satisfy the current tools version but there is not a good way to
        // do that currently.
        var buildSettings: BuildSettings.AssignmentTable = .init()
        do {
            let toolsSwiftVersion = swiftTestTarget?.buildSettings.assignments[.SWIFT_VERSION]?
                .filter(\.default)
                .filter(\.conditions.isEmpty)
                .flatMap(\.values)

            var versionAssignment = BuildSettings.Assignment()
            versionAssignment.values = toolsSwiftVersion ?? [String(SwiftVersion.current.major)]

            buildSettings.add(versionAssignment, for: .SWIFT_VERSION)
        }

        self.declaredSwiftVersions = []
        let sources = Sources(paths: [testEntryPointPath], root: testEntryPointPath.parentDirectory)

        super.init(
            name: name,
            type: .executable,
            path: .root,
            sources: sources,
            dependencies: dependencies,
            packageAccess: packageAccess,
            buildSettings: buildSettings,
            buildSettingsDescription: [],
            pluginUsages: [],
            usesUnsafeFlags: false
        )
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
