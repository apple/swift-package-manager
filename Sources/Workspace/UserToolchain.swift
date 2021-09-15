/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
import Foundation
import PackageLoading
import PackageModel
import SPMBuildCore
import TSCBasic
import TSCUtility

#if os(Windows)
private let hostExecutableSuffix = ".exe"
#else
private let hostExecutableSuffix = ""
#endif

// FIXME: This is messy and needs a redesign.
public final class UserToolchain: Toolchain {
    public typealias SwiftCompilers = (compile: AbsolutePath, manifest: AbsolutePath)

    /// The manifest resource provider.
    public let configuration: ToolchainConfiguration

    /// Path of the `swiftc` compiler.
    public let swiftCompilerPath: AbsolutePath

    // deprecated 8/2021
    @available(*, deprecated, message: "use swiftCompilerPath instead")
    public var swiftCompiler: AbsolutePath {
        get {
            self.swiftCompilerPath
        }
    }

    public var extraCCFlags: [String]

    public let extraSwiftCFlags: [String]

    public var extraCPPFlags: [String]

    // deprecated 8/2021
    @available(*, deprecated, message: "use configuration instead")
    public var manifestResources: ToolchainConfiguration {
        return self.configuration
    }

    /// Path of the `swift` interpreter.
    public var swiftInterpreterPath: AbsolutePath {
        return self.swiftCompilerPath.parentDirectory.appending(component: "swift" + hostExecutableSuffix)
    }

    // deprecated 8/2021
    @available(*, deprecated, message: "use swiftInterpreterPath instead")
    public var swiftInterpreter: AbsolutePath {
        return self.swiftInterpreterPath
    }

    /// Path to the xctest utility.
    ///
    /// This is only present on macOS.
    public let xctest: AbsolutePath?

    /// The compilation destination object.
    public let destination: Destination

    /// The target triple that should be used for compilation.
    public let triple: Triple

    /// The list of archs to build for.
    public let archs: [String]

    /// Search paths from the PATH environment variable.
    let envSearchPaths: [AbsolutePath]

    private var _clangCompiler: AbsolutePath?

    /// Returns the runtime library for the given sanitizer.
    public func runtimeLibrary(for sanitizer: Sanitizer) throws -> AbsolutePath {
        // FIXME: This is only for SwiftPM development time support. It is OK
        // for now but we shouldn't need to resolve the symlink.  We need to lay
        // down symlinks to runtimes in our fake toolchain as part of the
        // bootstrap script.
        let swiftCompiler = resolveSymlinks(self.swiftCompilerPath)

        let runtime = swiftCompiler.appending(
            RelativePath("../../lib/swift/clang/lib/darwin/libclang_rt.\(sanitizer.shortName)_osx_dynamic.dylib"))

        // Ensure that the runtime is present.
        guard localFileSystem.exists(runtime) else {
            throw InvalidToolchainDiagnostic("Missing runtime for \(sanitizer) sanitizer")
        }

        return runtime
    }

    // MARK: - private utilities

    private static func lookup(variable: String, searchPaths: [AbsolutePath]) -> AbsolutePath? {
        return lookupExecutablePath(filename: ProcessEnv.vars[variable], searchPaths: searchPaths)
    }

    private static func getTool(_ name: String, binDir: AbsolutePath) throws -> AbsolutePath {
        let executableName = "\(name)\(hostExecutableSuffix)"
        let toolPath = binDir.appending(component: executableName)
        guard localFileSystem.isExecutableFile(toolPath) else {
            throw InvalidToolchainDiagnostic("could not find \(name) at expected path \(toolPath)")
        }
        return toolPath
    }

    private static func findTool(_ name: String, envSearchPaths: [AbsolutePath]) throws -> AbsolutePath {
#if os(macOS)
        let foundPath = try Process.checkNonZeroExit(arguments: ["/usr/bin/xcrun", "--find", name]).spm_chomp()
        return try AbsolutePath(validating: foundPath)
#else
        for folder in envSearchPaths {
            if let toolPath = try? getTool(name, binDir: folder) {
                return toolPath
            }
        }
        throw InvalidToolchainDiagnostic("could not find \(name)")
#endif
    }

    // MARK: - public API

    /// Determines the Swift compiler paths for compilation and manifest parsing.
    public static func determineSwiftCompilers(binDir: AbsolutePath) throws -> SwiftCompilers {
        func validateCompiler(at path: AbsolutePath?) throws {
            guard let path = path else { return }
            guard localFileSystem.isExecutableFile(path) else {
                throw InvalidToolchainDiagnostic("could not find the `swiftc\(hostExecutableSuffix)` at expected path \(path)")
            }
        }

        // Get the search paths from PATH.
        let envSearchPaths = getEnvSearchPaths(
            pathString: ProcessEnv.path,
            currentWorkingDirectory: localFileSystem.currentWorkingDirectory
        )

        let lookup = { UserToolchain.lookup(variable: $0, searchPaths: envSearchPaths) }
        // Get overrides.
        let SWIFT_EXEC_MANIFEST = lookup("SWIFT_EXEC_MANIFEST")
        let SWIFT_EXEC = lookup("SWIFT_EXEC")

        // Validate the overrides.
        try validateCompiler(at: SWIFT_EXEC)
        try validateCompiler(at: SWIFT_EXEC_MANIFEST)

        // We require there is at least one valid swift compiler, either in the
        // bin dir or SWIFT_EXEC.
        let resolvedBinDirCompiler: AbsolutePath
        if let SWIFT_EXEC = SWIFT_EXEC {
            resolvedBinDirCompiler = SWIFT_EXEC
        } else if let binDirCompiler = try? UserToolchain.getTool("swiftc", binDir: binDir) {
            resolvedBinDirCompiler = binDirCompiler
        } else {
            // Try to lookup swift compiler on the system which is possible when
            // we're built outside of the Swift toolchain.
            resolvedBinDirCompiler = try UserToolchain.findTool("swiftc", envSearchPaths: envSearchPaths)
        }

        // The compiler for compilation tasks is SWIFT_EXEC or the bin dir compiler.
        // The compiler for manifest is either SWIFT_EXEC_MANIFEST or the bin dir compiler.
        return (SWIFT_EXEC ?? resolvedBinDirCompiler, SWIFT_EXEC_MANIFEST ?? resolvedBinDirCompiler)
    }

    /// Returns the path to clang compiler tool.
    public func getClangCompiler() throws -> AbsolutePath {
        // Check if we already computed.
        if let clang = self._clangCompiler {
            return clang
        }

        // Check in the environment variable first.
        if let toolPath = UserToolchain.lookup(variable: "CC", searchPaths: self.envSearchPaths) {
            self._clangCompiler = toolPath
            return toolPath
        }

        // Then, check the toolchain.
        do {
            if let toolPath = try? UserToolchain.getTool("clang", binDir: self.destination.binDir) {
                self._clangCompiler = toolPath
                return toolPath
            }
        }

        // Otherwise, lookup it up on the system.
        let toolPath = try UserToolchain.findTool("clang", envSearchPaths: self.envSearchPaths)
        self._clangCompiler = toolPath
        return toolPath
    }

    public func _isClangCompilerVendorApple() throws -> Bool? {
        // Assume the vendor is Apple on macOS.
        // FIXME: This might not be the best way to determine this.
#if os(macOS)
        return true
#else
        return false
#endif
    }

    /// Returns the path to lldb.
    public func getLLDB() throws -> AbsolutePath {
        // Look for LLDB next to the compiler first.
        if let lldbPath = try? UserToolchain.getTool("lldb", binDir: self.swiftCompilerPath.parentDirectory) {
            return lldbPath
        }
        // If that fails, fall back to xcrun, PATH, etc.
        return try UserToolchain.findTool("lldb", envSearchPaths: self.envSearchPaths)
    }

    /// Returns the path to llvm-cov tool.
    public func getLLVMCov() throws -> AbsolutePath {
        return try UserToolchain.getTool("llvm-cov", binDir: self.destination.binDir)
    }

    /// Returns the path to llvm-prof tool.
    public func getLLVMProf() throws -> AbsolutePath {
        return try UserToolchain.getTool("llvm-profdata", binDir: self.destination.binDir)
    }

    public func getSwiftAPIDigester() throws -> AbsolutePath {
        if let envValue = UserToolchain.lookup(variable: "SWIFT_API_DIGESTER", searchPaths: self.envSearchPaths) {
            return envValue
        }
        return try UserToolchain.getTool("swift-api-digester", binDir: self.swiftCompilerPath.parentDirectory)
    }

    public func getSymbolGraphExtract() throws -> AbsolutePath {
        if let envValue = UserToolchain.lookup(variable: "SWIFT_SYMBOLGRAPH_EXTRACT", searchPaths: self.envSearchPaths) {
            return envValue
        }
        return try UserToolchain.getTool("swift-symbolgraph-extract", binDir: self.swiftCompilerPath.parentDirectory)
    }

    internal static func deriveSwiftCFlags(triple: Triple, destination: Destination) -> [String] {
        guard let sdk = destination.sdk else {
            if triple.isWindows() {
                // Windows uses a variable named SDKROOT to determine the root of
                // the SDK.  This is not the same value as the SDKROOT parameter
                // in Xcode, however, the value represents a similar concept.
                if let SDKROOT = ProcessEnv.vars["SDKROOT"], let root = try? AbsolutePath(validating: SDKROOT) {
                    var runtime: [String] = []
                    var xctest: [String] = []
                    var extraSwiftCFlags: [String] = []

                    if let settings = WindowsSDKSettings(reading: root.appending(component: "SDKSettings.plist"),
                                                         diagnostics: nil, filesystem: localFileSystem) {
                        switch settings.defaults.runtime {
                        case .multithreadedDebugDLL:
                            runtime = [ "-libc", "MDd" ]
                        case .multithreadedDLL:
                            runtime = [ "-libc", "MD" ]
                        case .multithreadedDebug:
                            runtime = [ "-libc", "MTd" ]
                        case .multithreaded:
                            runtime = [ "-libc", "MT" ]
                        }
                    }

                    if let DEVELOPER_DIR = ProcessEnv.vars["DEVELOPER_DIR"],
                       let root = try? AbsolutePath(validating: DEVELOPER_DIR)
                        .appending(component: "Platforms")
                        .appending(component: "Windows.platform") {
                        if let info = WindowsPlatformInfo(reading: root.appending(component: "Info.plist"),
                                                          diagnostics: nil, filesystem: localFileSystem) {
                            let path: AbsolutePath =
                            root.appending(component: "Developer")
                                .appending(component: "Library")
                                .appending(component: "XCTest-\(info.defaults.xctestVersion)")
                            xctest = [
                                "-I", path.appending(RelativePath("usr/lib/swift/windows/\(triple.arch)")).pathString,
                                "-L", path.appending(RelativePath("usr/lib/swift/windows")).pathString,
                            ]

                            extraSwiftCFlags = info.defaults.extraSwiftCFlags ??  []
                        }
                    }

                    return [ "-sdk", root.pathString, ] + runtime + xctest + extraSwiftCFlags
                }
            }

            return destination.extraSwiftCFlags
        }

        return (triple.isDarwin() || triple.isAndroid() || triple.isWASI()
                ? ["-sdk", sdk.pathString]
                : [])
        + destination.extraSwiftCFlags
    }

    // MARK: - initializer

    public init(destination: Destination, environment: [String: String] = ProcessEnv.vars) throws {
        self.destination = destination

        // Get the search paths from PATH.
        self.envSearchPaths = getEnvSearchPaths(
            pathString: ProcessEnv.path,
            currentWorkingDirectory: localFileSystem.currentWorkingDirectory
        )

        // Get the binDir from destination.
        let binDir = destination.binDir

        let swiftCompilers = try UserToolchain.determineSwiftCompilers(binDir: binDir)
        self.swiftCompilerPath = swiftCompilers.compile
        self.archs = destination.archs

        // Use the triple from destination or compute the host triple using swiftc.
        var triple = destination.target ?? Triple.getHostTriple(usingSwiftCompiler: swiftCompilers.compile)

        // Change the triple to the specified arch if there's exactly one of them.
        // The Triple property is only looked at by the native build system currently.
        if archs.count == 1 {
            let components = triple.tripleString.drop(while: { $0 != "-" })
            triple = try Triple(archs[0] + components)
        }

        self.triple = triple

        // We require xctest to exist on macOS.
        if triple.isDarwin() {
            // FIXME: We should have some general utility to find tools.
            let xctestFindArgs = ["/usr/bin/xcrun", "--sdk", "macosx", "--find", "xctest"]
            self.xctest = try AbsolutePath(
                validating: Process.checkNonZeroExit(arguments: xctestFindArgs, environment: environment
                                                    ).spm_chomp())
        } else {
            self.xctest = nil
        }

        self.extraSwiftCFlags = Self.deriveSwiftCFlags(triple: triple, destination: destination)

        if let sdk = destination.sdk {
            self.extraCCFlags = [
                triple.isDarwin() ? "-isysroot" : "--sysroot", sdk.pathString
            ] + destination.extraCCFlags

            self.extraCPPFlags = destination.extraCPPFlags
        } else {
            self.extraCCFlags = destination.extraCCFlags
            self.extraCPPFlags = destination.extraCPPFlags
        }

        if triple.isWindows() {
            if let SDKROOT = ProcessEnv.vars["SDKROOT"], let root = try? AbsolutePath(validating: SDKROOT) {
                if let settings = WindowsSDKSettings(reading: root.appending(component: "SDKSettings.plist"),
                                                     diagnostics: nil, filesystem: localFileSystem) {
                    switch settings.defaults.runtime {
                    case .multithreadedDebugDLL:
                        // Defines _DEBUG, _MT, and _DLL
                        // Linker uses MSVCRTD.lib
                        self.extraCCFlags += ["-D_DEBUG", "-D_MT", "-D_DLL", "-Xclang", "--dependent-lib=msvcrtd"]

                    case .multithreadedDLL:
                        // Defines _MT, and _DLL
                        // Linker uses MSVCRT.lib
                        self.extraCCFlags += ["-D_MT", "-D_DLL", "-Xclang", "--dependent-lib=msvcrt"]

                    case .multithreadedDebug:
                        // Defines _DEBUG, and _MT
                        // Linker uses LIBCMTD.lib
                        self.extraCCFlags += ["-D_DEBUG", "-D_MT", "-Xclang", "--dependent-lib=libcmtd"]

                    case .multithreaded:
                        // Defines _MT
                        // Linker uses LIBCMT.lib
                        self.extraCCFlags += ["-D_MT", "-Xclang", "--dependent-lib=libcmt"]
                    }
                }
            }
        }

        let swiftPMLibrariesLocation = try Self.deriveSwiftPMLibrariesLocation(swiftCompilerPath: swiftCompilerPath, destination: destination)

        let xctestPath = Self.deriveXCTestPath()

        self.configuration = .init(
            swiftCompilerPath: swiftCompilers.manifest,
            swiftCompilerFlags: self.extraSwiftCFlags,
            swiftPMLibrariesLocation: swiftPMLibrariesLocation,
            sdkRootPath: self.destination.sdk,
            xctestPath: xctestPath
        )
    }

    private static func deriveSwiftPMLibrariesLocation(
        swiftCompilerPath: AbsolutePath,
        destination: Destination
    ) throws -> ToolchainConfiguration.SwiftPMLibrariesLocation? {
        // Look for an override in the env.
        if let pathEnvVariable = ProcessEnv.vars["SWIFTPM_CUSTOM_LIBS_DIR"] ?? ProcessEnv.vars["SWIFTPM_PD_LIBS"] {
            if ProcessEnv.vars["SWIFTPM_PD_LIBS"] != nil {
                print("SWIFTPM_PD_LIBS was deprecated in favor of SWIFTPM_CUSTOM_LIBS_DIR")
            }
            // We pick the first path which exists in an environment variable
            // delimited by the platform specific string separator.
#if os(Windows)
            let separator: Character = ";"
#else
            let separator: Character = ":"
#endif
            let paths = pathEnvVariable.split(separator: separator).map(String.init)
            for pathString in paths {
                if let path = try? AbsolutePath(validating: pathString), localFileSystem.exists(path) {
                    // we found the custom one
                    return .init(root: path)
                }
            }

            // fail if custom one specified but not found
            throw InternalError("Couldn't find the custom libraries location defined by SWIFTPM_CUSTOM_LIBS_DIR / SWIFTPM_PD_LIBS: \(pathEnvVariable)")
        }

        // FIXME: the following logic is pretty fragile, but has always been this way
        // an alternative cloud be to force explicit locations to always be set explicitly when running in XCode/SwiftPM
        // debug and assert if not set but we detect that we are in this mode

        let applicationPath = destination.binDir

        // this is the normal case when using the toolchain
        let librariesPath = applicationPath.parentDirectory.appending(components: "lib", "swift", "pm")
        if localFileSystem.exists(librariesPath) {
            return .init(root: librariesPath)
        }

        // this tests if we are debugging / testing SwiftPM with Xcode
        let manifestFrameworksPath = applicationPath.appending(components: "PackageFrameworks", "PackageDescription.framework")
        let pluginFrameworksPath = applicationPath.appending(components: "PackageFrameworks", "PackagePlugin.framework")
        if localFileSystem.exists(manifestFrameworksPath) && localFileSystem.exists(pluginFrameworksPath) {
            return .init(
                manifestAPI: manifestFrameworksPath,
                pluginAPI: pluginFrameworksPath
            )
        }

        // this tests if we are debugging / testing SwiftPM with SwiftPM
        if localFileSystem.exists(applicationPath.appending(component: "swift-package")) {
            return .init(
                manifestAPI: applicationPath,
                pluginAPI: applicationPath
            )
        }

        // we are using a SwiftPM outside a toolchain, use the compiler path to compute the location
        return .init(swiftCompilerPath: swiftCompilerPath)
    }

    // TODO: why is this only required on Windows? is there something better we can do?
    private static func deriveXCTestPath() -> AbsolutePath? {
#if os(Windows)
        if let DEVELOPER_DIR = ProcessEnv.vars["DEVELOPER_DIR"],
           let root = try? AbsolutePath(validating: DEVELOPER_DIR)
            .appending(component: "Platforms")
            .appending(component: "Windows.platform") {
            if let info = WindowsPlatformInfo(reading: root.appending(component: "Info.plist"),
                                              diagnostics: nil,
                                              filesystem: localFileSystem) {
                return root.appending(component: "Developer")
                    .appending(component: "Library")
                    .appending(component: "XCTest-\(info.defaults.xctestVersion)")
                    .appending(component: "usr")
                    .appending(component: "bin")
            }
        }
#endif
        return nil
    }
}
