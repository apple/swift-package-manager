//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics

/// Toolchain configuration required for evaluation of swift code such as the manifests or plugins
///
/// These requirements are abstracted out to make it easier to add support for
/// using the package manager with alternate toolchains in the future.
public struct ToolchainConfiguration {
    /// The path of the librarian.
    public var librarianPath: AbsolutePath

    /// The path of the swift compiler.
    public var swiftCompilerPath: AbsolutePath

    /// Extra arguments to pass the Swift compiler (defaults to the empty string).
    public var swiftCompilerFlags: [String]

    /// Environment to pass to the Swift compiler (defaults to the inherited environment).
    public var swiftCompilerEnvironment: Environment

    /// SwiftPM library paths.
    public var swiftPMLibrariesLocation: SwiftPMLibrariesLocation

    /// The path to SDK root.
    ///
    /// If provided, it will be passed to the swift interpreter.
    public var sdkRootPath: AbsolutePath?

    /// Path to the XCTest utility.
    ///
    /// This is optional for example on macOS w/o Xcode.
    public var xctestPath: AbsolutePath?

    /// Creates the set of manifest resources associated with a `swiftc` executable.
    ///
    /// - Parameters:
    ///     - librarianPath: The absolute path to the librarian
    ///     - swiftCompilerPath: The absolute path of the associated swift compiler executable (`swiftc`).
    ///     - swiftCompilerFlags: Extra flags to pass to the Swift compiler.
    ///     - swiftCompilerEnvironment: Environment variables to pass to the Swift compiler.
    ///     - swiftPMLibrariesRootPath: Custom path for SwiftPM libraries. Computed based on the compiler path by default.
    ///     - sdkRootPath: Optional path to SDK root.
    ///     - xctestPath: Optional path to XCTest.
    public init(
        librarianPath: AbsolutePath,
        swiftCompilerPath: AbsolutePath,
        swiftCompilerFlags: [String] = [],
        swiftCompilerEnvironment: Environment = .current,
        swiftPMLibrariesLocation: SwiftPMLibrariesLocation? = nil,
        sdkRootPath: AbsolutePath? = nil,
        xctestPath: AbsolutePath? = nil
    ) {
        let swiftPMLibrariesLocation = swiftPMLibrariesLocation ?? {
            return .init(swiftCompilerPath: swiftCompilerPath)
        }()

        self.librarianPath = librarianPath
        self.swiftCompilerPath = swiftCompilerPath
        self.swiftCompilerFlags = swiftCompilerFlags
        self.swiftCompilerEnvironment = swiftCompilerEnvironment
        self.swiftPMLibrariesLocation = swiftPMLibrariesLocation
        self.sdkRootPath = sdkRootPath
        self.xctestPath = xctestPath
    }
}

extension ToolchainConfiguration {
    public struct SwiftPMLibrariesLocation {
        public var manifestLibraryPath: AbsolutePath
        public var manifestModulesPath: AbsolutePath
        public var pluginLibraryPath: AbsolutePath
        public var pluginModulesPath: AbsolutePath

        public init(
            manifestLibraryPath: AbsolutePath,
            manifestModulesPath: AbsolutePath? = nil,
            manifestLibraryMinimumDeploymentTarget: PlatformVersion? = nil,
            pluginLibraryPath: AbsolutePath,
            pluginModulesPath: AbsolutePath? = nil,
            pluginLibraryMinimumDeploymentTarget: PlatformVersion? = nil
        ) {
            #if os(macOS)
            if let manifestLibraryMinimumDeploymentTarget {
                self.manifestLibraryMinimumDeploymentTarget = manifestLibraryMinimumDeploymentTarget
            } else if let manifestLibraryMinimumDeploymentTarget = try? MinimumDeploymentTarget.default.computeMinimumDeploymentTarget(of: Self.macOSManifestLibraryPath(for: manifestLibraryPath), platform: .macOS) {
                self.manifestLibraryMinimumDeploymentTarget = manifestLibraryMinimumDeploymentTarget
            } else {
                self.manifestLibraryMinimumDeploymentTarget = nil
            }

            if let pluginLibraryMinimumDeploymentTarget {
                self.pluginLibraryMinimumDeploymentTarget = pluginLibraryMinimumDeploymentTarget
            } else if let pluginLibraryMinimumDeploymentTarget = try? MinimumDeploymentTarget.default.computeMinimumDeploymentTarget(of: Self.macOSPluginLibraryPath(for: pluginLibraryPath), platform: .macOS) {
                self.pluginLibraryMinimumDeploymentTarget = pluginLibraryMinimumDeploymentTarget
            } else {
                self.pluginLibraryMinimumDeploymentTarget = nil
            }
            #else
            precondition(manifestLibraryMinimumDeploymentTarget == nil && pluginLibraryMinimumDeploymentTarget == nil, "deployment targets can only be specified on macOS")
            #endif

            self.manifestLibraryPath = manifestLibraryPath
            if let manifestModulesPath {
                self.manifestModulesPath = manifestModulesPath
            } else {
                self.manifestModulesPath = manifestLibraryPath
            }

            self.pluginLibraryPath = pluginLibraryPath
            if let pluginModulesPath {
                self.pluginModulesPath = pluginModulesPath
            } else {
                self.pluginModulesPath = pluginLibraryPath
            }
        }

        public init(root: AbsolutePath, manifestLibraryMinimumDeploymentTarget: PlatformVersion? = nil, pluginLibraryMinimumDeploymentTarget: PlatformVersion? = nil) {
            self.init(
                manifestLibraryPath: root.appending("ManifestAPI"),
                manifestLibraryMinimumDeploymentTarget: manifestLibraryMinimumDeploymentTarget,
                pluginLibraryPath: root.appending("PluginAPI"),
                pluginLibraryMinimumDeploymentTarget: pluginLibraryMinimumDeploymentTarget
            )
        }

        public init(swiftCompilerPath: AbsolutePath, manifestLibraryMinimumDeploymentTarget: PlatformVersion? = nil, pluginLibraryMinimumDeploymentTarget: PlatformVersion? = nil) {
            let rootPath = swiftCompilerPath.parentDirectory.parentDirectory.appending(components: "lib", "swift", "pm")
            self.init(root: rootPath,
                      manifestLibraryMinimumDeploymentTarget: manifestLibraryMinimumDeploymentTarget,
                      pluginLibraryMinimumDeploymentTarget: pluginLibraryMinimumDeploymentTarget)
        }

#if os(macOS)
        public var manifestLibraryMinimumDeploymentTarget: PlatformVersion?
        public var pluginLibraryMinimumDeploymentTarget: PlatformVersion?

        private static func macOSManifestLibraryPath(for manifestAPI: AbsolutePath) -> AbsolutePath {
            if manifestAPI.extension == "framework" {
                return manifestAPI.appending("PackageDescription")
            } else {
                // note: this is not correct for all platforms, but we only actually use it on macOS.
                return manifestAPI.appending("libPackageDescription.dylib")
            }
        }

        public var macOSManifestLibraryPath: AbsolutePath {
            return Self.macOSManifestLibraryPath(for: manifestLibraryPath)
        }

        private static func macOSPluginLibraryPath(for pluginAPI: AbsolutePath) -> AbsolutePath {
            // if runtimePath is set to "PackageFrameworks" that means we could be developing SwiftPM in Xcode
            // which produces a framework for dynamic package products.
            if pluginAPI.extension == "framework" {
                return pluginAPI.appending("PackagePlugin")
            } else {
                // note: this is not correct for all platforms, but we only actually use it on macOS.
                return pluginAPI.appending("libPackagePlugin.dylib")
            }
        }

        public var macOSPluginLibraryPath: AbsolutePath {
            return Self.macOSPluginLibraryPath(for: pluginLibraryPath)
        }
#endif
    }
}
