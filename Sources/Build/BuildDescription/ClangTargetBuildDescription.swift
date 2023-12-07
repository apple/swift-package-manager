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
import PackageLoading
import PackageModel
import class PackageGraph.ResolvedTarget
import struct SPMBuildCore.BuildParameters
import struct SPMBuildCore.BuildToolPluginInvocationResult
import struct SPMBuildCore.PrebuildCommandResult

import enum TSCBasic.ProcessEnv

/// Target description for a Clang target i.e. C language family target.
public final class ClangTargetBuildDescription {
    /// The target described by this target.
    public let target: ResolvedTarget

    /// The underlying clang target.
    public var clangTarget: ClangTarget {
        target.underlyingTarget as! ClangTarget
    }

    /// The tools version of the package that declared the target.  This can
    /// can be used to conditionalize semantically significant changes in how
    /// a target is built.
    public let toolsVersion: ToolsVersion

    /// The build parameters.
    let buildParameters: BuildParameters

    /// The build environment.
    var buildEnvironment: BuildEnvironment {
        buildParameters.buildEnvironment
    }

    /// The list of all resource files in the target, including the derived ones.
    public var resources: [Resource] {
        self.target.underlyingTarget.resources + self.pluginDerivedResources
    }

    /// Path to the bundle generated for this module (if any).
    var bundlePath: AbsolutePath? {
        guard !resources.isEmpty else {
            return .none
        }

        if let bundleName = target.underlyingTarget.potentialBundleName {
            return self.buildParameters.bundlePath(named: bundleName)
        } else {
            return .none
        }
    }

    /// The modulemap file for this target, if any.
    public private(set) var moduleMap: AbsolutePath?

    /// Path to the temporary directory for this target.
    var tempsPath: AbsolutePath

    /// The directory containing derived sources of this target.
    ///
    /// These are the source files generated during the build.
    private var derivedSources: Sources

    /// These are the source files derived from plugins.
    private var pluginDerivedSources: Sources

    /// These are the resource files derived from plugins.
    private var pluginDerivedResources: [Resource]

    /// Path to the resource accessor header file, if generated.
    public private(set) var resourceAccessorHeaderFile: AbsolutePath?

    /// Path to the resource Info.plist file, if generated.
    public private(set) var resourceBundleInfoPlistPath: AbsolutePath?

    /// The objects in this target.
    public var objects: [AbsolutePath] {
        get throws {
            try compilePaths().map(\.object)
        }
    }

    /// Paths to the binary libraries the target depends on.
    var libraryBinaryPaths: Set<AbsolutePath> = []

    /// Any addition flags to be added. These flags are expected to be computed during build planning.
    var additionalFlags: [String] = []

    /// The filesystem to operate on.
    private let fileSystem: FileSystem

    /// If this target is a test target.
    public var isTestTarget: Bool {
        target.type == .test
    }

    /// The results of applying any build tool plugins to this target.
    public let buildToolPluginInvocationResults: [BuildToolPluginInvocationResult]

    /// Create a new target description with target and build parameters.
    init(
        target: ResolvedTarget,
        toolsVersion: ToolsVersion,
        additionalFileRules: [FileRuleDescription] = [],
        buildParameters: BuildParameters,
        buildToolPluginInvocationResults: [BuildToolPluginInvocationResult] = [],
        prebuildCommandResults: [PrebuildCommandResult] = [],
        fileSystem: FileSystem,
        isWithinMixedTarget: Bool = false,
        observabilityScope: ObservabilityScope
    ) throws {
        guard target.underlyingTarget is ClangTarget else {
            throw InternalError("underlying target type mismatch \(target)")
        }

        self.fileSystem = fileSystem
        self.target = target
        self.toolsVersion = toolsVersion
        self.buildParameters = buildParameters
        self.tempsPath = buildParameters.buildPath.appending(component: target.c99name + ".build")
        self.derivedSources = Sources(paths: [], root: tempsPath.appending("DerivedSources"))

        // We did not use to apply package plugins to C-family targets in prior tools-versions, this preserves the behavior.
        if toolsVersion >= .v5_9 {
            self.buildToolPluginInvocationResults = buildToolPluginInvocationResults

            (self.pluginDerivedSources, self.pluginDerivedResources) = SharedTargetBuildDescription.computePluginGeneratedFiles(
                target: target,
                toolsVersion: toolsVersion,
                additionalFileRules: additionalFileRules,
                buildParameters: buildParameters,
                buildToolPluginInvocationResults: buildToolPluginInvocationResults,
                prebuildCommandResults: prebuildCommandResults,
                observabilityScope: observabilityScope
            )
        } else {
            self.buildToolPluginInvocationResults = []
            self.pluginDerivedSources = Sources(paths: [], root: buildParameters.dataPath)
            self.pluginDerivedResources = []
        }

        // Try computing the modulemap path, creating a module map in the
        // file system if necessary. If building for a mixed target, the mixed
        // target build description handle the module map.
        if target.type == .library, !isWithinMixedTarget {
            // If there's a custom module map, use it as given.
            if case .custom(let path) = clangTarget.moduleMapType {
                self.moduleMap = path
            }
            // If a generated module map is needed, generate one now in our temporary directory.
            else if let generatedModuleMapType = clangTarget.moduleMapType.generatedModuleMapType {
                let path = tempsPath.appending(component: moduleMapFilename)
                let moduleMapGenerator = ModuleMapGenerator(
                    targetName: clangTarget.name,
                    moduleName: clangTarget.c99name,
                    publicHeadersDir: clangTarget.includeDir,
                    fileSystem: fileSystem
                )
                try moduleMapGenerator.generateModuleMap(type: generatedModuleMapType, at: path)
                self.moduleMap = path
            }
            // Otherwise there is no module map, and we leave `moduleMap` unset.
        }

        // Do nothing if we're not generating a bundle.
        if bundlePath != nil {
            try self.generateResourceAccessor()

            let infoPlistPath = tempsPath.appending("Info.plist")
            if try generateResourceInfoPlist(fileSystem: fileSystem, target: target, path: infoPlistPath) {
                resourceBundleInfoPlistPath = infoPlistPath
            }
        }
    }

    /// An array of tuple containing filename, source, object and dependency path for each of the source in this target.
    public func compilePaths()
        throws -> [(filename: RelativePath, source: AbsolutePath, object: AbsolutePath, deps: AbsolutePath)]
    {
        let sources = [
            target.sources.root: target.sources.relativePaths,
            derivedSources.root: derivedSources.relativePaths,
            pluginDerivedSources.root: pluginDerivedSources.relativePaths
        ]

        return try sources.flatMap { root, relativePaths in
            try relativePaths.map { source in
                let path = root.appending(source)
                let object = try AbsolutePath(validating: "\(source.pathString).o", relativeTo: tempsPath)
                let deps = try AbsolutePath(validating: "\(source.pathString).d", relativeTo: tempsPath)
                return (source, path, object, deps)
            }
        }
    }

    /// Builds up basic compilation arguments for a source file in this target; these arguments may be different for C++
    /// vs non-C++.
    /// NOTE: The parameter to specify whether to get C++ semantics is currently optional, but this is only for revlock
    /// avoidance with clients. Callers should always specify what they want based either the user's indication or on a
    /// default value (possibly based on the filename suffix).
    public func basicArguments(
        isCXX isCXXOverride: Bool? = .none,
        isC: Bool = false
    ) throws -> [String] {
        // For now fall back on the hold semantics if the C++ nature isn't specified. This is temporary until clients
        // have been updated.
        let isCXX = isCXXOverride ?? clangTarget.isCXX

        var args = [String]()
        // Only enable ARC on macOS.
        if buildParameters.targetTriple.isDarwin() {
            args += ["-fobjc-arc"]
        }
        args += try buildParameters.targetTripleArgs(for: target)

        args += optimizationArguments
        args += activeCompilationConditions
        args += ["-fblocks"]

        // Enable index store, if appropriate.
        //
        // This feature is not widely available in OSS clang. So, we only enable
        // index store for Apple's clang or if explicitly asked to.
        if ProcessEnv.vars.keys.contains("SWIFTPM_ENABLE_CLANG_INDEX_STORE") {
            args += buildParameters.indexStoreArguments(for: target)
        } else if buildParameters.targetTriple.isDarwin(),
                  (try? buildParameters.toolchain._isClangCompilerVendorApple()) == true
        {
            args += buildParameters.indexStoreArguments(for: target)
        }

        // Enable Clang module flags, if appropriate.
        let enableModules: Bool
        if toolsVersion < .v5_8 {
            // For version < 5.8, we enable them except in these cases:
            // 1. on Darwin when compiling for C++, because C++ modules are disabled on Apple-built Clang releases
            // 2. on Windows when compiling for any language, because of issues with the Windows SDK
            // 3. on Android when compiling for any language, because of issues with the Android SDK
            enableModules = !(buildParameters.targetTriple.isDarwin() && isCXX) && !buildParameters.targetTriple
                .isWindows() && !buildParameters.targetTriple.isAndroid()
        } else {
            // For version >= 5.8, we disable them when compiling for C++ regardless of platforms, see:
            // https://github.com/llvm/llvm-project/issues/55980 for clang frontend crash when module
            // enabled for C++ on c++17 standard and above.
            enableModules = !isCXX && !buildParameters.targetTriple.isWindows() && !buildParameters.targetTriple.isAndroid()
        }

        if enableModules {
            // Using modules currently conflicts with the Windows and Android SDKs.
            args += ["-fmodules", "-fmodule-name=" + target.c99name]
        }

        // Only add the build path to the framework search path if there are binary frameworks to link against.
        if !libraryBinaryPaths.isEmpty {
            args += ["-F", buildParameters.buildPath.pathString]
        }

        args += ["-I", clangTarget.includeDir.pathString]
        args += additionalFlags
        if enableModules {
            args += try moduleCacheArgs
        }
        args += buildParameters.sanitizers.compileCFlags()

        // Add arguments from declared build settings.
        args += try self.buildSettingsFlags()

        // Include the path to the resource header unless the arguments are
        // being evaluated for a C file. A C file cannot depend on the resource
        // accessor header due to it exporting a Foundation type (`NSBundle`).
        if let resourceAccessorHeaderFile, !isC {
            args += ["-include", resourceAccessorHeaderFile.pathString]
        }

        args += self.buildParameters.toolchain.extraFlags.cCompilerFlags
        // User arguments (from -Xcc) should follow generated arguments to allow user overrides
        args += self.buildParameters.flags.cCompilerFlags

        // Add extra C++ flags if this target contains C++ files.
        if isCXX {
            args += self.buildParameters.toolchain.extraFlags.cxxCompilerFlags
            // User arguments (from -Xcxx) should follow generated arguments to allow user overrides
            args += self.buildParameters.flags.cxxCompilerFlags
        }

        // Enable the correct lto mode if requested.
        switch self.buildParameters.linkingParameters.linkTimeOptimizationMode {
        case nil:
            break
        case .full:
            args += ["-flto=full"]
        case .thin:
            args += ["-flto=thin"]
        }

        // rdar://117578677
        // Pass -fno-omit-frame-pointer to support backtraces
        // this can be removed once the backtracer uses DWARF instead of frame pointers
        if let omitFramePointers = self.buildParameters.debuggingParameters.omitFramePointers {
            if omitFramePointers {
                args += ["-fomit-frame-pointer"]
            } else {
                args += ["-fno-omit-frame-pointer"]
            }
        }

        // Pass default include paths from the toolchain.
        for includeSearchPath in self.buildParameters.toolchain.includeSearchPaths {
            args += ["-I", includeSearchPath.pathString]
        }

        return args
    }

    /// Returns the build flags from the declared build settings.
    private func buildSettingsFlags() throws -> [String] {
        let scope = buildParameters.createScope(for: target)
        var flags: [String] = []

        // C defines.
        let cDefines = scope.evaluate(.GCC_PREPROCESSOR_DEFINITIONS)
        flags += cDefines.map { "-D" + $0 }

        // Header search paths.
        let headerSearchPaths = scope.evaluate(.HEADER_SEARCH_PATHS)
        flags += try headerSearchPaths.map {
            "-I\(try AbsolutePath(validating: $0, relativeTo: target.sources.root).pathString)"
        }

        // Other C flags.
        flags += scope.evaluate(.OTHER_CFLAGS)

        // Other CXX flags.
        flags += scope.evaluate(.OTHER_CPLUSPLUSFLAGS)

        return flags
    }

    /// Optimization arguments according to the build configuration.
    private var optimizationArguments: [String] {
        switch buildParameters.configuration {
        case .debug:
            return ["-O0"]
        case .release:
            return ["-O2"]
        }
    }

    /// A list of compilation conditions to enable for conditional compilation expressions.
    private var activeCompilationConditions: [String] {
        var compilationConditions = ["-DSWIFT_PACKAGE=1"]

        switch buildParameters.configuration {
        case .debug:
            compilationConditions += ["-DDEBUG=1"]
        case .release:
            break
        }

        return compilationConditions
    }

    /// Module cache arguments.
    private var moduleCacheArgs: [String] {
        get throws {
            try ["-fmodules-cache-path=\(buildParameters.moduleCache.pathString)"]
        }
    }

    /// Generate the resource bundle accessor, if appropriate.
    private func generateResourceAccessor() throws {
        // Only generate access when we have a bundle and ObjC files.
        guard let bundlePath, clangTarget.sources.containsObjcFiles else { return }

        // Compute the basename of the bundle.
        let bundleBasename = bundlePath.basename

        let implContent =
            """
            #import <Foundation/Foundation.h>

            NSBundle* \(target.c99name)_SWIFTPM_MODULE_BUNDLE() {
                NSURL *bundleURL = [[[NSBundle mainBundle] bundleURL] URLByAppendingPathComponent:@"\(bundleBasename)"];

                NSBundle *preferredBundle = [NSBundle bundleWithURL:bundleURL];
                if (preferredBundle == nil) {
                  return [NSBundle bundleWithPath:@"\(bundlePath.pathString)"];
                }

                return preferredBundle;
            }
            """

        let implFileSubpath = try RelativePath(validating: "resource_bundle_accessor.m")

        // Add the file to the derived sources.
        derivedSources.relativePaths.append(implFileSubpath)

        // Write this file out.
        // FIXME: We should generate this file during the actual build.
        try fileSystem.writeIfChanged(
            path: derivedSources.root.appending(implFileSubpath),
            string: implContent
        )

        let headerContent =
            """
            #import <Foundation/Foundation.h>

            #if __cplusplus
            extern "C" {
            #endif

            NSBundle* \(target.c99name)_SWIFTPM_MODULE_BUNDLE(void);

            #define SWIFTPM_MODULE_BUNDLE \(target.c99name)_SWIFTPM_MODULE_BUNDLE()

            #if __cplusplus
            }
            #endif
            """

        let headerFile = derivedSources.root.appending("resource_bundle_accessor.h")
        self.resourceAccessorHeaderFile = headerFile

        try fileSystem.writeIfChanged(
            path: headerFile,
            string: headerContent
        )
    }
}
