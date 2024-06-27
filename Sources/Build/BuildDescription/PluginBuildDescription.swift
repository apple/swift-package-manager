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

import PackageGraph
import PackageModel

import struct Basics.InternalError
import protocol Basics.FileSystem

/// Description for a plugin module. This is treated a bit differently from the
/// regular kinds of modules, and is not included in the LLBuild description.
/// But because the modules graph and build plan are not loaded for incremental
/// builds, this information is included in the BuildDescription, and the plugin
/// modules are compiled directly.
public final class PluginBuildDescription: Codable {
    /// The identity of the package in which the plugin is defined.
    public let package: PackageIdentity

    /// The name of the plugin module in that package (this is also the name of
    /// the plugin).
    public let moduleName: String

    /// The language-level module name.
    public let moduleC99Name: String

    /// The names of any plugin products in that package that vend the plugin
    /// to other packages.
    public let productNames: [String]

    /// The tools version of the package that declared the module. This affects
    /// the API that is available in the PackagePlugin module.
    public let toolsVersion: ToolsVersion

    /// Swift source files that comprise the plugin.
    public let sources: Sources

    /// Initialize a new plugin module description. The module is expected to be
    /// a `PluginTarget`.
    init(
        module: ResolvedModule,
        products: [ResolvedProduct],
        package: ResolvedPackage,
        toolsVersion: ToolsVersion,
        testDiscoveryTarget: Bool = false,
        fileSystem: FileSystem
    ) throws {
        guard module.underlying is PluginModule else {
            throw InternalError("underlying target type mismatch \(module)")
        }

        self.package = package.identity
        self.moduleName = module.name
        self.moduleC99Name = module.c99name
        self.productNames = products.map(\.name)
        self.toolsVersion = toolsVersion
        self.sources = module.sources
    }
}
