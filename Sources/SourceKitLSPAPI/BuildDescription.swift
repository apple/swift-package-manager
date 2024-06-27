//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct Foundation.URL

private import struct Basics.AbsolutePath
private import func Basics.resolveSymlinks

private import SPMBuildCore

// FIXME: should import these module with `private` or `internal` access control
import class Build.BuildPlan
import class Build.ClangModuleBuildDescription
import class Build.SwiftModuleBuildDescription
import struct PackageGraph.ResolvedModule
import struct PackageGraph.ModulesGraph
import enum PackageGraph.BuildTriple

public typealias BuildTriple = PackageGraph.BuildTriple

public protocol BuildTarget {
    var sources: [URL] { get }

    /// The name of the target. It should be possible to build a target by passing this name to `swift build --target`
    var name: String { get }

    var buildTriple: BuildTriple { get }

    /// Whether the target is part of the root package that the user opened or if it's part of a package dependency.
    var isPartOfRootPackage: Bool { get }

    func compileArguments(for fileURL: URL) throws -> [String]
}

private struct WrappedClangTargetBuildDescription: BuildTarget {
    private let description: ClangModuleBuildDescription
    let isPartOfRootPackage: Bool

    init(description: ClangModuleBuildDescription, isPartOfRootPackage: Bool) {
        self.description = description
        self.isPartOfRootPackage = isPartOfRootPackage
    }

    public var sources: [URL] {
        return (try? description.compilePaths().map { URL(fileURLWithPath: $0.source.pathString) }) ?? []
    }

    public var name: String {
        return description.clangTarget.name
    }

    public var buildTriple: BuildTriple {
        return description.target.buildTriple
    }

    public func compileArguments(for fileURL: URL) throws -> [String] {
        let filePath = try resolveSymlinks(try AbsolutePath(validating: fileURL.path))
        let commandLine = try description.emitCommandLine(for: filePath)
        // First element on the command line is the compiler itself, not an argument.
        return Array(commandLine.dropFirst())
    }
}

private struct WrappedSwiftTargetBuildDescription: BuildTarget {
    private let description: SwiftModuleBuildDescription
    let isPartOfRootPackage: Bool

    init(description: SwiftModuleBuildDescription, isPartOfRootPackage: Bool) {
        self.description = description
        self.isPartOfRootPackage = isPartOfRootPackage
    }

    public var name: String {
        return description.target.name
    }

    public var buildTriple: BuildTriple {
        return description.target.buildTriple
    }

    var sources: [URL] {
        return description.sources.map { URL(fileURLWithPath: $0.pathString) }
    }

    func compileArguments(for fileURL: URL) throws -> [String] {
        // Note: we ignore the `fileURL` here as the expectation is that we get a command line for the entire target
        // in case of Swift.
        let commandLine = try description.emitCommandLine(scanInvocation: false)
        // First element on the command line is the compiler itself, not an argument.
        return Array(commandLine.dropFirst())
    }
}

public struct BuildDescription {
    private let buildPlan: Build.BuildPlan

    /// The inputs of the build plan so we don't need to re-compute them  on every call to
    /// `fileAffectsSwiftOrClangBuildSettings`.
    private let inputs: [BuildPlan.Input]

    // FIXME: should not use `BuildPlan` in the public interface
    public init(buildPlan: Build.BuildPlan) {
        self.buildPlan = buildPlan
        self.inputs = buildPlan.inputs
    }

    // FIXME: should not use `ResolvedTarget` in the public interface
    public func getBuildTarget(for target: ResolvedModule, in modulesGraph: ModulesGraph) -> BuildTarget? {
        if let description = buildPlan.targetMap[target.id] {
            switch description {
            case .clang(let description):
                return WrappedClangTargetBuildDescription(
                    description: description,
                    isPartOfRootPackage: modulesGraph.rootPackages.map(\.id).contains(description.package.id)
                )
            case .swift(let description):
                return WrappedSwiftTargetBuildDescription(
                    description: description,
                    isPartOfRootPackage: modulesGraph.rootPackages.map(\.id).contains(description.package.id)
                )
            }
        } else {
            if target.type == .plugin, let package = self.buildPlan.graph.package(for: target) {
                return PluginTargetBuildDescription(
                    target: target,
                    toolsVersion: package.manifest.toolsVersion,
                    isPartOfRootPackage: modulesGraph.rootPackages.map(\.id).contains(package.id)
                )
            }
            return nil
        }
    }

    /// Returns all targets within the module graph in topological order, starting with low-level targets (that have no
    /// dependencies).
    public func allTargetsInTopologicalOrder(in modulesGraph: ModulesGraph) throws -> [BuildTarget] {
        try modulesGraph.allModulesInTopologicalOrder.compactMap {
            getBuildTarget(for: $0, in: modulesGraph)
        }
    }

    /// Returns `true` if the file at the given path might influence build settings for a `swiftc` or `clang` invocation
    /// generated by SwiftPM.
    public func fileAffectsSwiftOrClangBuildSettings(_ url: URL) -> Bool {
        guard let filePath = try? AbsolutePath(validating: url.path) else {
            return false
        }

        for input in self.inputs {
            switch input {
            case .directoryStructure(let path):
                if path.isAncestor(of: filePath) {
                    return true
                }
            case .file(let path):
                if filePath == path {
                    return true
                }
            }
        }
        return false
    }
}
