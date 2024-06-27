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

@available(*, deprecated, renamed: "ClangModule")
public typealias ClangTarget = ClangModule

public final class ClangModule: Module {
    /// Description of the module type used in `swift package describe` output. Preserved for backwards compatibility.
    public override class var typeDescription: String { "ClangTarget" }

    /// The default public include directory component.
    public static let defaultPublicHeadersComponent = "include"

    /// The path to include directory.
    public let includeDir: AbsolutePath

    /// The target's module map type, which determines whether this target vends a custom module map, a generated module map, or no module map at all.
    public let moduleMapType: ModuleMapType

    /// The headers present in the target.
    ///
    /// Note that this contains both public and non-public headers.
    public let headers: [AbsolutePath]

    /// True if this is a C++ target.
    public let isCXX: Bool

    /// The C language standard flag.
    public let cLanguageStandard: String?

    /// The C++ language standard flag.
    public let cxxLanguageStandard: String?

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
        dependencies: [Module.Dependency] = [],
        buildSettings: BuildSettings.AssignmentTable = .init(),
        buildSettingsDescription: [TargetBuildSettingDescription.Setting] = [],
        usesUnsafeFlags: Bool
    ) throws {
        guard includeDir.isDescendantOfOrEqual(to: sources.root) else {
            throw StringError("\(includeDir) should be contained in the source root \(sources.root)")
        }
        self.isCXX = sources.containsCXXFiles
        self.cLanguageStandard = cLanguageStandard
        self.cxxLanguageStandard = cxxLanguageStandard
        self.includeDir = includeDir
        self.moduleMapType = moduleMapType
        self.headers = headers
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
            packageAccess: false,
            buildSettings: buildSettings,
            buildSettingsDescription: buildSettingsDescription,
            pluginUsages: [],
            usesUnsafeFlags: usesUnsafeFlags
        )
    }
}
