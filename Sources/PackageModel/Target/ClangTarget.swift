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

public final class ClangTarget: Target {
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
        dependencies: [Target.Dependency] = [],
        buildSettings: BuildSettings.AssignmentTable = .init(),
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
            pluginUsages: [],
            usesUnsafeFlags: usesUnsafeFlags
        )
    }

    private enum CodingKeys: String, CodingKey {
        case includeDir, moduleMapType, headers, isCXX, cLanguageStandard, cxxLanguageStandard
    }

    public override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(includeDir, forKey: .includeDir)
        try container.encode(moduleMapType, forKey: .moduleMapType)
        try container.encode(headers, forKey: .headers)
        try container.encode(isCXX, forKey: .isCXX)
        try container.encode(cLanguageStandard, forKey: .cLanguageStandard)
        try container.encode(cxxLanguageStandard, forKey: .cxxLanguageStandard)
        try super.encode(to: encoder)
    }

    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.includeDir = try container.decode(AbsolutePath.self, forKey: .includeDir)
        self.moduleMapType = try container.decode(ModuleMapType.self, forKey: .moduleMapType)
        self.headers = try container.decode([AbsolutePath].self, forKey: .headers)
        self.isCXX = try container.decode(Bool.self, forKey: .isCXX)
        self.cLanguageStandard = try container.decodeIfPresent(String.self, forKey: .cLanguageStandard)
        self.cxxLanguageStandard = try container.decodeIfPresent(String.self, forKey: .cxxLanguageStandard)
        try super.init(from: decoder)
    }
}
