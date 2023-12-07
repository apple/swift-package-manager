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
import class PackageGraph.ResolvedTarget
import struct PackageModel.Resource
import struct SPMBuildCore.BuildToolPluginInvocationResult

/// A target description which can either be for a Swift or Clang target.
public enum TargetBuildDescription {
    /// Swift target description.
    case swift(SwiftTargetBuildDescription)

    /// Clang target description.
    case clang(ClangTargetBuildDescription)

    /// Mixed (Swift + Clang) target description.
    case mixed(MixedTargetBuildDescription)

    /// The objects in this target.
    var objects: [AbsolutePath] {
        get throws {
            switch self {
            case .swift(let target):
                return try target.objects
            case .clang(let target):
                return try target.objects
            case .mixed(let target):
                return try target.objects
            }
        }
    }

    /// The resources in this target.
    var resources: [Resource] {
        switch self {
        case .swift(let target):
            return target.resources
        case .clang(let target):
            return target.resources
        case .mixed(let target):
            return target.resources
        }
    }

    /// Path to the bundle generated for this module (if any).
    var bundlePath: AbsolutePath? {
        switch self {
        case .swift(let target):
            return target.bundlePath
        case .clang(let target):
            return target.bundlePath
        case .mixed(let target):
            return target.bundlePath
        }
    }

    var target: ResolvedTarget {
        switch self {
        case .swift(let target):
            return target.target
        case .clang(let target):
            return target.target
        case .mixed(let target):
            return target.target
        }
    }

    /// Paths to the binary libraries the target depends on.
    var libraryBinaryPaths: Set<AbsolutePath> {
        switch self {
        case .swift(let target):
            return target.libraryBinaryPaths
        case .clang(let target):
            return target.libraryBinaryPaths
        case .mixed(let target):
            return target.libraryBinaryPaths
        }
    }

    var resourceBundleInfoPlistPath: AbsolutePath? {
        switch self {
        case .swift(let target):
            return target.resourceBundleInfoPlistPath
        case .clang(let target):
            return target.resourceBundleInfoPlistPath
        case .mixed(let target):
            return target.resourceBundleInfoPlistPath
        }
    }

    var buildToolPluginInvocationResults: [BuildToolPluginInvocationResult] {
        switch self {
        case .swift(let target):
            return target.buildToolPluginInvocationResults
        case .clang(let target):
            return target.buildToolPluginInvocationResults
        case .mixed(let target):
            return target.buildToolPluginInvocationResults
        }
    }
}
