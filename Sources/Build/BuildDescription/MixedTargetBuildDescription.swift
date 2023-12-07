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
import Foundation
import PackageGraph
import PackageLoading
import PackageModel
import SPMBuildCore

public final class MixedTargetBuildDescription {
    /// The target described by this target.
    let target: ResolvedTarget

    /// The list of all resource files in the target.
    var resources: [Resource] { self.target.underlyingTarget.resources }

    /// If this target is a test target.
    var isTestTarget: Bool { self.target.underlyingTarget.type == .test }

    /// The objects in this target. This includes both the Swift and Clang object files.
    var objects: [AbsolutePath] {
        get throws {
            try self.swiftTargetBuildDescription.objects +
                self.clangTargetBuildDescription.objects
        }
    }

    /// Path to the bundle generated for this module (if any).
    var bundlePath: AbsolutePath? { self.swiftTargetBuildDescription.bundlePath }

    /// Path to the resource Info.plist file, if generated.
    var resourceBundleInfoPlistPath: AbsolutePath? {
        self.swiftTargetBuildDescription.resourceBundleInfoPlistPath
    }

    /// The path to the VFS overlay file that overlays the public headers of
    /// the Clang part of the target over the target's build directory.
    let allProductHeadersOverlay: AbsolutePath

    /// The paths to the targets's public headers.
    var publicHeadersDir: AbsolutePath {
        clangTargetBuildDescription.clangTarget.includeDir
    }

    /// The modulemap file for this target.
    let moduleMap: AbsolutePath

    /// Paths to the binary libraries the target depends on.
    var libraryBinaryPaths: Set<AbsolutePath> {
        self.swiftTargetBuildDescription.libraryBinaryPaths
            .union(self.clangTargetBuildDescription.libraryBinaryPaths)
    }
    
    /// The results of applying any build tool plugins to this target.
    let buildToolPluginInvocationResults: [BuildToolPluginInvocationResult]

    /// The build description for the Clang sources.
    let clangTargetBuildDescription: ClangTargetBuildDescription

    /// The build description for the Swift sources.
    let swiftTargetBuildDescription: SwiftTargetBuildDescription

    init(
        package: ResolvedPackage,
        target: ResolvedTarget,
        toolsVersion: ToolsVersion,
        additionalFileRules: [FileRuleDescription] = [],
        buildParameters: BuildParameters,
        buildToolPluginInvocationResults: [BuildToolPluginInvocationResult] = [],
        prebuildCommandResults: [PrebuildCommandResult] = [],
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws {
        guard let mixedTarget = target.underlyingTarget as? MixedTarget else {
            throw InternalError("underlying target type mismatch \(target)")
        }

        self.target = target
        self.buildToolPluginInvocationResults = buildToolPluginInvocationResults

        let clangResolvedTarget = ResolvedTarget(
            target: mixedTarget.clangTarget,
            dependencies: target.dependencies,
            defaultLocalization: target.defaultLocalization,
            platforms: target.platforms
        )
        self.clangTargetBuildDescription = try ClangTargetBuildDescription(
            target: clangResolvedTarget,
            toolsVersion: toolsVersion,
            buildParameters: buildParameters,
            buildToolPluginInvocationResults: buildToolPluginInvocationResults,
            prebuildCommandResults: prebuildCommandResults,
            fileSystem: fileSystem,
            isWithinMixedTarget: true,
            observabilityScope: observabilityScope
        )

        let swiftResolvedTarget = ResolvedTarget(
            target: mixedTarget.swiftTarget,
            dependencies: target.dependencies,
            defaultLocalization: target.defaultLocalization,
            platforms: target.platforms
        )
        self.swiftTargetBuildDescription = try SwiftTargetBuildDescription(
            package: package,
            target: swiftResolvedTarget,
            toolsVersion: toolsVersion,
            additionalFileRules: additionalFileRules,
            buildParameters: buildParameters,
            buildToolPluginInvocationResults: buildToolPluginInvocationResults,
            prebuildCommandResults: prebuildCommandResults,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope,
            isWithinMixedTarget: true
        )

        let interopHeaderPath = self.swiftTargetBuildDescription.objCompatibilityHeaderPath

        // A mixed target's build directory uses three subdirectories to
        // distinguish between build artifacts:
        // - Product: Stores artifacts used by clients of the target.
        let tempsPath = buildParameters.buildPath.appending(component: target.c99name + ".build")

        // Filenames for VFS overlay files.
        let allProductHeadersFilename = "all-product-headers.yaml"
        let unextendedModuleOverlayFilename = "unextended-module-overlay.yaml"

        // Used to generate both product and intermediate artifacts for the
        // target.
        let moduleMapGenerator = ModuleMapGenerator(
            targetName: mixedTarget.clangTarget.name,
            moduleName: mixedTarget.clangTarget.c99name,
            publicHeadersDir: mixedTarget.clangTarget.includeDir,
            fileSystem: fileSystem
        )

        // MARK: Generate products to be used by client of the target.

        switch mixedTarget.clangTarget.moduleMapType {
        // When the mixed target has a custom module map, clients of the target
        // will be passed a module map *and* VFS overlay at buildtime to access
        // the mixed target's public API. The following is therefore needed:
        // - Create a copy of the custom module map, and extend its contents by
        //   adding a submodule that modularizes the target's generated interop
        //   header. This allows clients of the target to consume the mixed
        //   target's public Obj-C compatible Swift API in a Clang context.
        // - Create a VFS overlay to swap in the extended module map for the
        //   original custom module map. This is done so relative paths in the
        //   modified module map can be resolved as they would have been in the
        //   original module map.
        case .custom(let customModuleMapPath):
            // Set the original custom module map path as the module map path
            // for the target. With the below VFS overlay, evaluating the
            // custom module map path will redirect to the extended module map
            // path.
            self.moduleMap = customModuleMapPath
            self.allProductHeadersOverlay = tempsPath.appending(component: allProductHeadersFilename)

            // If it's named 'module.modulemap', there will be a module
            // redeclaration error as both the public headers dir. and the
            // build dir. are passed as import paths and there will be a
            // `module.modulemap` in each directory.
            let extendedCustomModuleMapPath = tempsPath.appending(component: "extended-custom-module.modulemap")
            try generateExtendedModuleMap(
                from: customModuleMapPath,
                at: extendedCustomModuleMapPath,
                fileSystem: fileSystem
            )

            try VFSOverlay(roots: [
                VFSOverlay.Directory(
                    name: customModuleMapPath.parentDirectory.pathString,
                    contents: [
                        // Redirect the custom `module.modulemap` to the
                        // modified module map in the product directory.
                        VFSOverlay.File(
                            name: moduleMapFilename,
                            externalContents: extendedCustomModuleMapPath.pathString
                        ),
                        // Add a generated Swift header that redirects to the
                        // generated header in the build directory's root.
                        VFSOverlay.File(
                            name: interopHeaderPath.basename,
                            externalContents: interopHeaderPath.pathString
                        ),
                    ]
                ),
            ]).write(to: self.allProductHeadersOverlay, fileSystem: fileSystem)
            
            // Importing the underlying module will build the Objective-C
            // part of the module. In order to find the underlying module,
            // a `module.modulemap` needs to be discoverable via directory passed
            // as a header search path.
            self.swiftTargetBuildDescription.additionalFlags += [
                "-import-underlying-module",
                "-I", mixedTarget.clangTarget.includeDir.pathString
            ]

        // When the mixed target does not have a custom module map, one will be
        // generated as a product for use by clients.
        // - Note: When `.none`, the mixed target has no public headers. Even
        //   then, a module map is created to expose the generated interop
        //   header so clients can access the public Objective-C compatible
        //   Swift API in a Clang context.
        case .umbrellaHeader, .umbrellaDirectory, .none:
            let generatedModuleMapType = mixedTarget.clangTarget.moduleMapType.generatedModuleMapType
            let unextendedModuleMapPath = tempsPath.appending(component: unextendedModuleMapFilename)

            try moduleMapGenerator.generateModuleMap(
                type: generatedModuleMapType,
                at: unextendedModuleMapPath
            )

            let unextendedModuleMapOverlayPath = tempsPath.appending(component: unextendedModuleOverlayFilename)
            try VFSOverlay(roots: [
                VFSOverlay.Directory(
                    name: tempsPath.pathString,
                    contents: [
                        // Redirect the `module.modulemap` to the *unextended*
                        // module map in the intermediates directory.
                        VFSOverlay.File(
                            name: moduleMapFilename,
                            externalContents: unextendedModuleMapPath.pathString
                        ),
                    ]
                ),
            ]).write(to: unextendedModuleMapOverlayPath, fileSystem: fileSystem)

            let extendedModuleMapPath = tempsPath.appending(component: moduleMapFilename)

            // Set the generated module map as the module map for the target.
            self.moduleMap = extendedModuleMapPath
            self.allProductHeadersOverlay = tempsPath.appending(component: allProductHeadersFilename)

            try generateExtendedModuleMap(
                from: unextendedModuleMapPath,
                at: extendedModuleMapPath,
                fileSystem: fileSystem
            )

            try VFSOverlay(roots: [
                VFSOverlay.Directory(
                    name: mixedTarget.clangTarget.includeDir.pathString,
                    contents: [
                        // Add a generated Swift header that redirects to the
                        // generated header in the build directory's root.
                        VFSOverlay.File(
                            name: interopHeaderPath.basename,
                            externalContents: interopHeaderPath.pathString
                        ),
                    ]
                ),
            ]).write(to: self.allProductHeadersOverlay, fileSystem: fileSystem)

            // Importing the underlying module will build the Objective-C
            // part of the module. In order to find the underlying module,
            // a `module.modulemap` needs to be discoverable via directory passed
            // as a header search path.
            self.swiftTargetBuildDescription.additionalFlags += [
                "-import-underlying-module",
                "-I", tempsPath.pathString,
                "-Xcc", "-ivfsoverlay", "-Xcc", unextendedModuleMapOverlayPath.pathString
            ]
        }

        self.swiftTargetBuildDescription.appendClangFlags(
            // Adding the root of the target's source as a header search
            // path allows for importing headers (within the mixed target's
            // headers) using paths relative to the root.
            "-I", mixedTarget.path.pathString,
            // Adding the public headers directory as a header search
            // path allows for importing public headers within the mixed
            // target's headers. Note that this directory may not exist in the
            // case that there are no public headers. In this case, adding this
            // header search path is a no-op.
            "-I", mixedTarget.clangTarget.includeDir.pathString
        )

        self.clangTargetBuildDescription.additionalFlags += [
            // Adding the root of the target's source as a header search
            // path allows for importing headers using paths relative to
            // the root.
            "-I", mixedTarget.path.pathString,
            // Include overlay file to add interop header to overlay directory.
            "-I", interopHeaderPath.parentDirectory.pathString
        ]
    }

    /// Extends the contents of the given module map to contain the target's generated Swift header
    /// modularized in a submodule. This "extended" module map is written at the given `path`.
    private func generateExtendedModuleMap(
        from unextendedModuleMapPath: AbsolutePath,
        at path: AbsolutePath,
        fileSystem: FileSystem
    ) throws {
        let unextendedModuleMapContents: String =
            try fileSystem.readFileContents(unextendedModuleMapPath)

        // Check that custom module map does not contain a Swift submodule.
        if unextendedModuleMapContents.contains("\(target.c99name).Swift") {
            throw StringError(
                "The target's module map may not contain a Swift " +
                    "submodule for the module \(target.c99name)."
            )
        }

        // Extend the contents and write it to disk, if needed.
        let productModuleMap = """
        \(unextendedModuleMapContents)
        module \(target.c99name).Swift {
            header "\(target.c99name)-Swift.h"
        }
        """
        try fileSystem.writeFileContentsIfNeeded(
            path,
            string: productModuleMap
        )
    }
}
