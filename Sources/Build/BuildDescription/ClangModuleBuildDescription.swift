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
import PackageGraph
import PackageLoading
import PackageModel
import struct PackageGraph.ModulesGraph
import struct PackageGraph.ResolvedModule
import struct SPMBuildCore.BuildParameters
import struct SPMBuildCore.BuildToolPluginInvocationResult
import struct SPMBuildCore.PrebuildCommandResult

@available(*, deprecated, renamed: "ClangModuleBuildDescription")
public typealias ClangTargetBuildDescription = ClangModuleBuildDescription

/// Build description for a Clang target i.e. C language family module.
public final class ClangModuleBuildDescription {
    /// The package this target belongs to.
    public let package: ResolvedPackage

    /// The target described by this target.
    public let target: ResolvedModule

    /// The underlying clang target.
    public let clangTarget: ClangModule

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
        self.target.underlying.resources + self.pluginDerivedResources
    }

    /// Path to the bundle generated for this module (if any).
    var bundlePath: AbsolutePath? {
        guard !self.resources.isEmpty else {
            return .none
        }

        if let bundleName = target.underlying.potentialBundleName {
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
        package: ResolvedPackage,
        target: ResolvedModule,
        toolsVersion: ToolsVersion,
        additionalFileRules: [FileRuleDescription] = [],
        buildParameters: BuildParameters,
        buildToolPluginInvocationResults: [BuildToolPluginInvocationResult] = [],
        prebuildCommandResults: [PrebuildCommandResult] = [],
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws {
        guard let clangTarget = target.underlying as? ClangModule else {
            throw InternalError("underlying target type mismatch \(target)")
        }

        self.package = package
        self.clangTarget = clangTarget
        self.fileSystem = fileSystem
        self.target = target
        self.toolsVersion = toolsVersion
        self.buildParameters = buildParameters
        self.tempsPath = target.tempsPath(buildParameters)
        self.derivedSources = Sources(paths: [], root: tempsPath.appending("DerivedSources"))

        // We did not use to apply package plugins to C-family targets in prior tools-versions, this preserves the behavior.
        if toolsVersion >= .v5_9 {
            self.buildToolPluginInvocationResults = buildToolPluginInvocationResults

            (self.pluginDerivedSources, self.pluginDerivedResources) = ModulesGraph.computePluginGeneratedFiles(
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

        // Try computing modulemap path for a C library.  This also creates the file in the file system, if needed.
        if target.type == .library {
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

    /// An array of tuples containing filename, source, object and dependency path for each of the source in this target.
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

    /// Determines the arguments needed to run `swift-symbolgraph-extract` for
    /// this module.
    package func symbolGraphExtractArguments() throws -> [String] {
        var args = [String]()
        if self.clangTarget.isCXX {
            args += ["-cxx-interoperability-mode=default"]
        }
        if let cxxLanguageStandard = self.clangTarget.cxxLanguageStandard {
            args += ["-Xcc", "-std=\(cxxLanguageStandard)"]
        }
        args += ["-I", self.clangTarget.includeDir.pathString]
        args += self.additionalFlags.asSwiftcCCompilerFlags()
        // Unconditionally use clang modules with swift tools.
        args += try self.clangModuleArguments().asSwiftcCCompilerFlags()
        args += try self.currentModuleMapFileArguments().asSwiftcCCompilerFlags()
        return args
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
        if self.buildParameters.triple.isDarwin() {
            args += ["-fobjc-arc"]
        }
        args += try self.buildParameters.tripleArgs(for: target)

        args += optimizationArguments
        args += activeCompilationConditions
        args += ["-fblocks"]

        // Enable index store, if appropriate.
        if let supported = try? ClangSupport.supportsFeature(
            name: "index-unit-output-path",
            toolchain: self.buildParameters.toolchain
        ), supported {
            args += self.buildParameters.indexStoreArguments(for: target)
        }

        // Enable Clang module flags, if appropriate.
        let triple = self.buildParameters.triple
        // Swift is able to use modules on non-Darwin platforms because it injects its own module maps
        // via vfs. However, nothing does that for C based compilation, and so non-Darwin platforms can't
        // support clang modules.
        // Note that if modules get enabled for other platforms later, they can't be used with C++ until
        // https://github.com/llvm/llvm-project/issues/55980 (crash on C++17 and later) is fixed.
        // clang modules aren't fully supported in C++ mode in the current Darwin SDKs.
        let enableModules = triple.isDarwin() && !isCXX
        if enableModules {
            args += try self.clangModuleArguments()
        }

        // Only add the build path to the framework search path if there are binary frameworks to link against.
        if !libraryBinaryPaths.isEmpty {
            args += ["-F", buildParameters.buildPath.pathString]
        }

        args += ["-I", clangTarget.includeDir.pathString]
        args += additionalFlags

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

        // FIXME: Remove this once it becomes possible to express this dependency in a package manifest.
        //
        // On Linux/Android swift-corelibs-foundation depends on dispatch library which is
        // currently shipped with the Swift toolchain.
        if (triple.isLinux() || triple.isAndroid()) && self.package.id == .plain("swift-corelibs-foundation") {
            let swiftCompilerPath = self.buildParameters.toolchain.swiftCompilerPath
            let toolchainResourcesPath = swiftCompilerPath.parentDirectory
                                                          .parentDirectory
                                                          .appending(components: ["lib", "swift"])
            args += ["-I", toolchainResourcesPath.pathString]
        }

        // suppress warnings if the package is remote
        if self.package.isRemote {
            args += ["-w"]
            // `-w` (suppress warnings) and `-Werror` (warnings as errors) flags are mutually exclusive
            if let index = args.firstIndex(of: "-Werror") {
                args.remove(at: index)
            }
        }

        return args
    }

    public func emitCommandLine(for filePath: AbsolutePath) throws -> [String] {
        let standards = [
            (clangTarget.cxxLanguageStandard, SupportedLanguageExtension.cppExtensions),
            (clangTarget.cLanguageStandard, SupportedLanguageExtension.cExtensions),
        ]

        guard let path = try self.compilePaths().first(where: { $0.source == filePath }) else {
            throw BuildDescriptionError.requestedFileNotPartOfTarget(
                targetName: self.target.name,
                requestedFilePath: filePath
            )
        }

        let isCXX = path.source.extension.map { SupportedLanguageExtension.cppExtensions.contains($0) } ?? false
        let isC = path.source.extension.map { $0 == SupportedLanguageExtension.c.rawValue } ?? false

        var args = try basicArguments(isCXX: isCXX, isC: isC)

        args += ["-MD", "-MT", "dependencies", "-MF", path.deps.pathString]

        // Add language standard flag if needed.
        if let ext = path.source.extension {
            for (standard, validExtensions) in standards {
                if let standard, validExtensions.contains(ext) {
                    args += ["-std=\(standard)"]
                }
            }
        }

        args += ["-c", path.source.pathString, "-o", path.object.pathString]

        let clangCompiler = try buildParameters.toolchain.getClangCompiler().pathString
        args.insert(clangCompiler, at: 0)
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

    /// Enable Clang module flags.
    private func clangModuleArguments() throws -> [String] {
        let cachePath = try self.buildParameters.moduleCache.pathString
        return [
            "-fmodules",
            "-fmodule-name=\(self.target.c99name)",
            "-fmodules-cache-path=\(cachePath)",
        ]
    }
    
    private func currentModuleMapFileArguments() throws -> [String] {
        // Pass the path to the current module's module map if present.
        if let moduleMap = self.moduleMap {
            return ["-fmodule-map-file=\(moduleMap.pathString)"]
        }
        return []
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
