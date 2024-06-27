//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2015-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import struct PackageGraph.ResolvedModule
import struct PackageModel.Resource
import struct PackageModel.ToolsVersion
import struct SPMBuildCore.BuildToolPluginInvocationResult
import struct SPMBuildCore.BuildParameters

public enum BuildDescriptionError: Swift.Error {
    case requestedFileNotPartOfTarget(targetName: String, requestedFilePath: AbsolutePath)
}

@available(*, deprecated, renamed: "ModuleBuildDescription")
public typealias TargetBuildDescription = ModuleBuildDescription

/// A module build description which can either be for a Swift or Clang module.
public enum ModuleBuildDescription {
    /// Swift target description.
    case swift(SwiftModuleBuildDescription)

    /// Clang target description.
    case clang(ClangModuleBuildDescription)

    /// The objects in this target.
    var objects: [AbsolutePath] {
        get throws {
            switch self {
            case .swift(let module):
                return try module.objects
            case .clang(let module):
                return try module.objects
            }
        }
    }

    /// The resources in this target.
    var resources: [Resource] {
        switch self {
        case .swift(let buildDescription):
            return buildDescription.resources
        case .clang(let buildDescription):
            return buildDescription.resources
        }
    }

    /// Path to the bundle generated for this module (if any).
    var bundlePath: AbsolutePath? {
        switch self {
        case .swift(let buildDescription):
            return buildDescription.bundlePath
        case .clang(let buildDescription):
            return buildDescription.bundlePath
        }
    }

    var target: ResolvedModule {
        switch self {
        case .swift(let buildDescription):
            return buildDescription.target
        case .clang(let buildDescription):
            return buildDescription.target
        }
    }

    /// Paths to the binary libraries the target depends on.
    var libraryBinaryPaths: Set<AbsolutePath> {
        switch self {
        case .swift(let target):
            return target.libraryBinaryPaths
        case .clang(let target):
            return target.libraryBinaryPaths
        }
    }

    var resourceBundleInfoPlistPath: AbsolutePath? {
        switch self {
        case .swift(let buildDescription):
            return buildDescription.resourceBundleInfoPlistPath
        case .clang(let buildDescription):
            return buildDescription.resourceBundleInfoPlistPath
        }
    }

    var buildToolPluginInvocationResults: [BuildToolPluginInvocationResult] {
        switch self {
        case .swift(let buildDescription):
            return buildDescription.buildToolPluginInvocationResults
        case .clang(let buildDescription):
            return buildDescription.buildToolPluginInvocationResults
        }
    }

    var buildParameters: BuildParameters {
        switch self {
        case .swift(let buildDescription):
            return buildDescription.buildParameters
        case .clang(let buildDescription):
            return buildDescription.buildParameters
        }
    }

    var toolsVersion: ToolsVersion {
        switch self {
        case .swift(let buildDescription):
            return buildDescription.toolsVersion
        case .clang(let buildDescription):
            return buildDescription.toolsVersion
        }
    }

    /// Determines the arguments needed to run `swift-symbolgraph-extract` for
    /// this module.
    package func symbolGraphExtractArguments() throws -> [String] {
        switch self {
        case .swift(let buildDescription): try buildDescription.symbolGraphExtractArguments()
        case .clang(let buildDescription): try buildDescription.symbolGraphExtractArguments()
        }
    }
}
