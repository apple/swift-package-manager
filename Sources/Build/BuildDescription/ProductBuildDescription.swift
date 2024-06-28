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

@_spi(SwiftPMInternal)
import PackageModel

import OrderedCollections
import SPMBuildCore

import struct TSCBasic.SortedArray

/// The build description for a product.
public final class ProductBuildDescription: SPMBuildCore.ProductBuildDescription {
    /// The reference to the product.
    public let package: ResolvedPackage

    /// The reference to the product.
    public let product: ResolvedProduct

    /// The tools version of the package that declared the product.  This can
    /// can be used to conditionalize semantically significant changes in how
    /// a target is built.
    public let toolsVersion: ToolsVersion

    /// The build parameters.
    public let buildParameters: BuildParameters

    /// All object files to link into this product.
    ///
    // Computed during build planning.
    public internal(set) var objects = SortedArray<AbsolutePath>()

    /// The dynamic libraries this product needs to link with.
    // Computed during build planning.
    var dylibs: [ProductBuildDescription] = []

    /// The list of provided libraries that are going to be used by this product.
    var providedLibraries: [String: AbsolutePath] = [:]

    /// Any additional flags to be added. These flags are expected to be computed during build planning.
    var additionalFlags: [String] = []

    /// The list of targets that are going to be linked statically in this product.
    var staticTargets: [ResolvedModule] = []

    /// The list of Swift modules that should be passed to the linker. This is required for debugging to work.
    var swiftASTs: SortedArray<AbsolutePath> = .init()

    /// Paths to the binary libraries the product depends on.
    var libraryBinaryPaths: Set<AbsolutePath> = []

    /// Paths to tools shipped in binary dependencies
    var availableTools: [String: AbsolutePath] = [:]

    /// Path to the temporary directory for this product.
    var tempsPath: AbsolutePath {
        let suffix = buildParameters.suffix
        return self.buildParameters.buildPath.appending(component: "\(self.product.name)\(suffix).product")
    }

    /// Path to the link filelist file.
    var linkFileListPath: AbsolutePath {
        self.tempsPath.appending("Objects.LinkFileList")
    }

    /// File system reference.
    private let fileSystem: FileSystem

    /// ObservabilityScope with which to emit diagnostics
    private let observabilityScope: ObservabilityScope

    /// Create a build description for a product.
    init(
        package: ResolvedPackage,
        product: ResolvedProduct,
        toolsVersion: ToolsVersion,
        buildParameters: BuildParameters,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws {
        guard product.type != .library(.automatic) else {
            throw InternalError("Automatic type libraries should not be described.")
        }

        self.package = package
        self.product = product
        self.toolsVersion = toolsVersion
        self.buildParameters = buildParameters
        self.fileSystem = fileSystem
        self.observabilityScope = observabilityScope
    }

    /// Strips the arguments which should *never* be passed to Swift compiler
    /// when we're linking the product.
    ///
    /// We might want to get rid of this method once Swift driver can strip the
    /// flags itself, <rdar://problem/31215562>.
    private func stripInvalidArguments(_ args: [String]) -> [String] {
        let invalidArguments: Set<String> = ["-wmo", "-whole-module-optimization"]
        return args.filter { !invalidArguments.contains($0) }
    }

    private var deadStripArguments: [String] {
        if !self.buildParameters.linkingParameters.linkerDeadStrip {
            return []
        }

        let triple = self.buildParameters.triple
        switch self.buildParameters.configuration {
        case .debug:
            return []
        case .release:
            if triple.isApple() {
                return ["-Xlinker", "-dead_strip"]
            } else if triple.isWindows() {
                return ["-Xlinker", "/OPT:REF"]
            } else {
                return ["-Xlinker", "--gc-sections"]
            }
        }
    }

    /// The arguments to the librarian to create a static library.
    public func archiveArguments() throws -> [String] {
        let librarian = self.buildParameters.toolchain.librarianPath.pathString
        let triple = self.buildParameters.triple
        if triple.isWindows(), librarian.hasSuffix("link") || librarian.hasSuffix("link.exe") {
            return try [librarian, "/LIB", "/OUT:\(binaryPath.pathString)", "@\(self.linkFileListPath.pathString)"]
        }
        if triple.isApple(), librarian.hasSuffix("libtool") {
            return try [librarian, "-static", "-o", binaryPath.pathString, "@\(self.linkFileListPath.pathString)"]
        }
        return try [librarian, "crs", binaryPath.pathString, "@\(self.linkFileListPath.pathString)"]
    }

    /// The arguments to link and create this product.
    public func linkArguments() throws -> [String] {
        var args = [buildParameters.toolchain.swiftCompilerPath.pathString]
        args += self.buildParameters.sanitizers.linkSwiftFlags()
        args += self.additionalFlags

        // pass `-v` during verbose builds.
        if self.buildParameters.outputParameters.isVerbose {
            args += ["-v"]
        }

        // Only add the build path to the framework search path if there are binary frameworks to link against.
        if !self.libraryBinaryPaths.isEmpty {
            args += ["-F", self.buildParameters.buildPath.pathString]
        }

        self.providedLibraries.forEach { args += ["-L", $1.pathString, "-l", $0] }

        args += ["-L", self.buildParameters.buildPath.pathString]
        args += try ["-o", binaryPath.pathString]
        args += ["-module-name", self.product.name.spm_mangledToC99ExtendedIdentifier()]
        args += self.dylibs.map { "-l" + $0.product.name }

        // Add arguments needed for code coverage if it is enabled.
        if self.buildParameters.testingParameters.enableCodeCoverage {
            args += ["-profile-coverage-mapping", "-profile-generate"]
        }

        let containsSwiftTargets = self.product.containsSwiftModules

        let derivedProductType: ProductType
        switch self.product.type {
        case .macro:
            #if BUILD_MACROS_AS_DYLIBS
            derivedProductType = .library(.dynamic)
            #else
            derivedProductType = .executable
            #endif
        default:
            derivedProductType = self.product.type
        }

        var isLinkingStaticStdlib = false
        let triple = self.buildParameters.triple

        // radar://112671586 supress unnecessary warnings
        if triple.isMacOSX {
            args += ["-Xlinker", "-no_warn_duplicate_libraries"]
        }

        func linkSwiftStdlibStaticallyIfRequested() {
            // TODO: unify this logic with SwiftTargetBuildDescription.stdlibArguments
            if self.buildParameters.linkingParameters.shouldLinkStaticSwiftStdlib {
                if triple.isDarwin() {
                    self.observabilityScope.emit(.swiftBackDeployError)
                } else if triple.isSupportingStaticStdlib {
                    args += ["-static-stdlib"]
                    isLinkingStaticStdlib = true
                }
            }
        }

        switch derivedProductType {
        case .macro:
            throw InternalError("macro not supported") // should never be reached
        case .library(.automatic):
            throw InternalError("automatic library not supported")
        case .library(.static):
            // No arguments for static libraries.
            return []
        case .test:
            // Test products are bundle when using Objective-C, executable when using test entry point.
            switch self.buildParameters.testingParameters.testProductStyle {
            case .loadableBundle:
                args += ["-Xlinker", "-bundle"]
            case .entryPointExecutable:
                args += ["-emit-executable"]
            }
            args += self.deadStripArguments
        case .library(.dynamic):
            linkSwiftStdlibStaticallyIfRequested()
            args += ["-emit-library"]
            if triple.isDarwin() {
                let relativePath = try "@rpath/\(buildParameters.binaryRelativePath(for: self.product).pathString)"
                args += ["-Xlinker", "-install_name", "-Xlinker", relativePath]
            }
            args += self.deadStripArguments
        case .executable, .snippet:
            linkSwiftStdlibStaticallyIfRequested()
            args += ["-emit-executable"]
            args += self.deadStripArguments

            // If we're linking an executable whose main module is implemented in Swift,
            // we rename the `_<modulename>_main` entry point symbol to `_main` again.
            // This is because executable modules implemented in Swift are compiled with
            // a main symbol named that way to allow tests to link against it without
            // conflicts. If we're using a linker that doesn't support symbol renaming,
            // we will instead have generated a source file containing the redirect.
            // Support for linking tests against executables is conditional on the tools
            // version of the package that defines the executable product.
            let executableTarget = try product.executableModule
            if let target = executableTarget.underlying as? SwiftModule, 
                self.toolsVersion >= .v5_5,
                self.buildParameters.driverParameters.canRenameEntrypointFunctionName,
                target.supportsTestableExecutablesFeature
            {
                if let flags = buildParameters.linkerFlagsForRenamingMainFunction(of: executableTarget) {
                    args += flags
                }
            }
        case .plugin:
            throw InternalError("unexpectedly asked to generate linker arguments for a plugin product")
        }

        if let resourcesPath = self.buildParameters.toolchain.swiftResourcesPath(isStatic: isLinkingStaticStdlib) {
            args += ["-resource-dir", "\(resourcesPath)"]
        }

        // clang resources are always in lib/swift/
        if let dynamicResourcesPath = self.buildParameters.toolchain.swiftResourcesPath {
            let clangResourcesPath = dynamicResourcesPath.appending("clang")
            args += ["-Xclang-linker", "-resource-dir", "-Xclang-linker", "\(clangResourcesPath)"]
        }

        // Set rpath such that dynamic libraries are looked up
        // adjacent to the product, unless overridden.
        if !self.buildParameters.linkingParameters.shouldDisableLocalRpath {
            if triple.isLinux() {
                args += ["-Xlinker", "-rpath=$ORIGIN"]
            } else if triple.isDarwin() {
                let rpath = self.product.type == .test ? "@loader_path/../../../" : "@loader_path"
                args += ["-Xlinker", "-rpath", "-Xlinker", rpath]
            }
        }
        args += ["@\(self.linkFileListPath.pathString)"]

        if containsSwiftTargets {
            // Pass experimental features to link jobs in addition to compile jobs. Preserve ordering while eliminating
            // duplicates with `OrderedSet`.
            var experimentalFeatures = OrderedSet<String>()
            for target in self.product.modules {
                let swiftSettings = target.underlying.buildSettingsDescription.filter { $0.tool == .swift }
                for case let .enableExperimentalFeature(feature) in swiftSettings.map(\.kind)  {
                    experimentalFeatures.append(feature)
                }
            }
            for feature in experimentalFeatures {
                args += ["-enable-experimental-feature", feature]
            }

            // Embed the swift stdlib library path inside tests and executables on Darwin.
            let useStdlibRpath: Bool
            switch self.product.type {
            case .library(let type):
                useStdlibRpath = type == .dynamic
            case .test, .executable, .snippet, .macro:
                useStdlibRpath = true
            case .plugin:
                throw InternalError("unexpectedly asked to generate linker arguments for a plugin product")
            }

            // When deploying to macOS prior to macOS 12, add an rpath to the
            // back-deployed concurrency libraries.
            if useStdlibRpath, triple.isMacOSX {
                let macOSSupportedPlatform = self.package.getSupportedPlatform(for: .macOS, usingXCTest: product.isLinkingXCTest)

                if macOSSupportedPlatform.version.major < 12 {
                    let backDeployedStdlib = try buildParameters.toolchain.macosSwiftStdlib
                        .parentDirectory
                        .parentDirectory
                        .appending("swift-5.5")
                        .appending("macosx")
                    args += ["-Xlinker", "-rpath", "-Xlinker", backDeployedStdlib.pathString]
                }
            }
        } else {
            // Don't link runtime compatibility patch libraries if there are no
            // Swift sources in the target.
            args += ["-runtime-compatibility-version", "none"]
        }

        // Add the target triple from the first target in the product.
        //
        // We can just use the first target of the product because the deployment target
        // setting is the package-level right now. We might need to figure out a better
        // answer for libraries if/when we support specifying deployment target at the
        // target-level.
        args += try self.buildParameters.tripleArgs(for: self.product.modules[self.product.modules.startIndex])

        // Add arguments from declared build settings.
        args += self.buildSettingsFlags

        // Add AST paths to make the product debuggable. This array is only populated when we're
        // building for Darwin in debug configuration.
        args += self.swiftASTs.flatMap { ["-Xlinker", "-add_ast_path", "-Xlinker", $0.pathString] }

        args += self.buildParameters.toolchain.extraFlags.swiftCompilerFlags
        // User arguments (from -Xswiftc) should follow generated arguments to allow user overrides
        args += self.buildParameters.flags.swiftCompilerFlags

        args += self.buildParameters.toolchain.extraFlags.linkerFlags.asSwiftcLinkerFlags()
        // User arguments (from -Xlinker) should follow generated arguments to allow user overrides
        args += self.buildParameters.flags.linkerFlags.asSwiftcLinkerFlags()

        // Enable the correct lto mode if requested.
        switch self.buildParameters.linkingParameters.linkTimeOptimizationMode {
        case nil:
            break
        case .full:
            args += ["-lto=llvm-full"]
        case .thin:
            args += ["-lto=llvm-thin"]
        }

        // Pass default library paths from the toolchain.
        for librarySearchPath in self.buildParameters.toolchain.librarySearchPaths {
            args += ["-L", librarySearchPath.pathString]
        }

        // Library search path for the toolchain's copy of SwiftSyntax.
        #if BUILD_MACROS_AS_DYLIBS
        if product.type == .macro {
            args += try ["-L", defaultBuildParameters.toolchain.hostLibDir.pathString]
        }
        #endif

        return self.stripInvalidArguments(args)
    }

    /// Returns the build flags from the declared build settings.
    private var buildSettingsFlags: [String] {
        var flags: [String] = []

        // Linked libraries.
        let libraries = OrderedSet(self.staticTargets.reduce([]) {
            $0 + self.buildParameters.createScope(for: $1).evaluate(.LINK_LIBRARIES)
        })
        flags += libraries.map { "-l" + $0 }

        // Linked frameworks.
        if self.buildParameters.triple.supportsFrameworks {
            let frameworks = OrderedSet(self.staticTargets.reduce([]) {
                $0 + self.buildParameters.createScope(for: $1).evaluate(.LINK_FRAMEWORKS)
            })
            flags += frameworks.flatMap { ["-framework", $0] }
        }

        // Other linker flags.
        for target in self.staticTargets {
            let scope = self.buildParameters.createScope(for: target)
            flags += scope.evaluate(.OTHER_LDFLAGS)
        }

        return flags
    }

    func codeSigningArguments(plistPath: AbsolutePath, binaryPath: AbsolutePath) -> [String] {
        ["codesign", "--force", "--sign", "-", "--entitlements", plistPath.pathString, binaryPath.pathString]
    }
}

extension SortedArray where Element == AbsolutePath {
    public static func +=<S: Sequence>(lhs: inout SortedArray, rhs: S) where S.Iterator.Element == AbsolutePath {
        lhs.insert(contentsOf: rhs)
    }
}

extension Triple {
    var supportsFrameworks: Bool {
        return self.isDarwin()
    }
}
