//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics

@_spi(SwiftPMInternal)
import Build

import struct PackageGraph.ModulesGraph
import struct PackageGraph.ResolvedModule
import struct PackageGraph.ResolvedProduct
import PackageModel
import SPMBuildCore
import TSCUtility
import XCTest

public struct MockToolchain: PackageModel.Toolchain {
    #if os(Windows)
    public let librarianPath = AbsolutePath("/fake/path/to/link.exe")
    #elseif os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
    public let librarianPath = AbsolutePath("/fake/path/to/libtool")
    #else
    public let librarianPath = AbsolutePath("/fake/path/to/llvm-ar")
    #endif
    public let swiftCompilerPath = AbsolutePath("/fake/path/to/swiftc")
    public let includeSearchPaths = [AbsolutePath]()
    public let librarySearchPaths = [AbsolutePath]()
    public let swiftResourcesPath: AbsolutePath?
    public let swiftStaticResourcesPath: AbsolutePath? = nil
    public let sdkRootPath: AbsolutePath? = nil
    public let extraFlags = PackageModel.BuildFlags()
    public let installedSwiftPMConfiguration = InstalledSwiftPMConfiguration.default
    public let providedLibraries = [ProvidedLibrary]()

    public func getClangCompiler() throws -> AbsolutePath {
        "/fake/path/to/clang"
    }

    public func _isClangCompilerVendorApple() throws -> Bool? {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    public init(swiftResourcesPath: AbsolutePath? = nil) {
        self.swiftResourcesPath = swiftResourcesPath
    }
}

extension Basics.Triple {
    public static let x86_64MacOS = try! Self("x86_64-apple-macosx")
    public static let x86_64Linux = try! Self("x86_64-unknown-linux-gnu")
    public static let arm64Linux = try! Self("aarch64-unknown-linux-gnu")
    public static let arm64Android = try! Self("aarch64-unknown-linux-android")
    public static let windows = try! Self("x86_64-unknown-windows-msvc")
    public static let wasi = try! Self("wasm32-unknown-wasi")
    public static let arm64iOS = try! Self("arm64-apple-ios")
}

public let hostTriple = try! UserToolchain.default.targetTriple
#if os(macOS)
public let defaultTargetTriple: String = hostTriple.tripleString(forPlatformVersion: "10.13")
#else
public let defaultTargetTriple: String = hostTriple.tripleString
#endif

public func mockBuildParameters(
    destination: BuildParameters.Destination,
    buildPath: AbsolutePath? = nil,
    config: BuildConfiguration = .debug,
    toolchain: PackageModel.Toolchain = MockToolchain(),
    flags: PackageModel.BuildFlags = PackageModel.BuildFlags(),
    shouldLinkStaticSwiftStdlib: Bool = false,
    shouldDisableLocalRpath: Bool = false,
    canRenameEntrypointFunctionName: Bool = false,
    triple: Basics.Triple = hostTriple,
    indexStoreMode: BuildParameters.IndexStoreMode = .off,
    useExplicitModuleBuild: Bool = false,
    linkerDeadStrip: Bool = true,
    linkTimeOptimizationMode: BuildParameters.LinkTimeOptimizationMode? = nil,
    omitFramePointers: Bool? = nil,
    prepareForIndexing: Bool = false
) -> BuildParameters {
    try! BuildParameters(
        destination: destination,
        dataPath: buildPath ?? AbsolutePath("/path/to/build").appending(triple.tripleString),
        configuration: config,
        toolchain: toolchain,
        triple: triple,
        flags: flags,
        pkgConfigDirectories: [],
        workers: 3,
        indexStoreMode: indexStoreMode,
        prepareForIndexing: prepareForIndexing,
        debuggingParameters: .init(
            triple: triple,
            shouldEnableDebuggingEntitlement: config == .debug,
            omitFramePointers: omitFramePointers
        ),
        driverParameters: .init(
            canRenameEntrypointFunctionName: canRenameEntrypointFunctionName,
            useExplicitModuleBuild: useExplicitModuleBuild
        ),
        linkingParameters: .init(
            linkerDeadStrip: linkerDeadStrip,
            linkTimeOptimizationMode: linkTimeOptimizationMode,
            shouldDisableLocalRpath: shouldDisableLocalRpath,
            shouldLinkStaticSwiftStdlib: shouldLinkStaticSwiftStdlib
        )
    )
}

public func mockBuildParameters(
    destination: BuildParameters.Destination,
    environment: BuildEnvironment
) -> BuildParameters {
    let triple: Basics.Triple
    switch environment.platform {
    case .macOS:
        triple = Triple.x86_64MacOS
    case .linux:
        triple = Triple.arm64Linux
    case .android:
        triple = Triple.arm64Android
    case .windows:
        triple = Triple.windows
    default:
        fatalError("unsupported platform in tests")
    }

    return mockBuildParameters(
        destination: destination,
        config: environment.configuration ?? .debug,
        triple: triple
    )
}

public func mockBuildPlan(
    buildPath: AbsolutePath? = nil,
    environment: BuildEnvironment,
    toolchain: PackageModel.Toolchain = MockToolchain(),
    graph: ModulesGraph,
    commonFlags: PackageModel.BuildFlags = .init(),
    indexStoreMode: BuildParameters.IndexStoreMode = .off,
    omitFramePointers: Bool? = nil,
    driverParameters: BuildParameters.Driver = .init(),
    linkingParameters: BuildParameters.Linking = .init(),
    targetSanitizers: EnabledSanitizers = .init(),
    fileSystem fs: any FileSystem,
    observabilityScope: ObservabilityScope
) throws -> Build.BuildPlan {
    try mockBuildPlan(
        buildPath: buildPath,
        config: environment.configuration ?? .debug,
        platform: environment.platform,
        toolchain: toolchain,
        graph: graph,
        commonFlags: commonFlags,
        indexStoreMode: indexStoreMode,
        omitFramePointers: omitFramePointers,
        driverParameters: driverParameters,
        linkingParameters: linkingParameters,
        targetSanitizers: targetSanitizers,
        fileSystem: fs,
        observabilityScope: observabilityScope
    )
}

public func mockBuildPlan(
    buildPath: AbsolutePath? = nil,
    config: BuildConfiguration = .debug,
    triple: Basics.Triple? = nil,
    platform: PackageModel.Platform? = nil,
    toolchain: PackageModel.Toolchain = MockToolchain(),
    graph: ModulesGraph,
    commonFlags: PackageModel.BuildFlags = .init(),
    indexStoreMode: BuildParameters.IndexStoreMode = .off,
    omitFramePointers: Bool? = nil,
    driverParameters: BuildParameters.Driver = .init(),
    linkingParameters: BuildParameters.Linking = .init(),
    targetSanitizers: EnabledSanitizers = .init(),
    fileSystem fs: any FileSystem,
    observabilityScope: ObservabilityScope
) throws -> Build.BuildPlan {
    let inferredTriple: Basics.Triple
    if let platform {
        precondition(triple == nil)

        inferredTriple = switch platform {
        case .macOS:
            Triple.x86_64MacOS
        case .linux:
            Triple.arm64Linux
        case .android:
            Triple.arm64Android
        case .windows:
            Triple.windows
        default:
            fatalError("unsupported platform in tests")
        }
    } else {
        inferredTriple = triple ?? hostTriple
    }

    let commonDebuggingParameters = BuildParameters.Debugging(
        triple: inferredTriple,
        shouldEnableDebuggingEntitlement: config == .debug,
        omitFramePointers: omitFramePointers
    )

    var destinationParameters = mockBuildParameters(
        destination: .target,
        buildPath: buildPath,
        config: config,
        toolchain: toolchain,
        flags: commonFlags,
        triple: inferredTriple,
        indexStoreMode: indexStoreMode
    )
    destinationParameters.debuggingParameters = commonDebuggingParameters
    destinationParameters.driverParameters = driverParameters
    destinationParameters.linkingParameters = linkingParameters
    destinationParameters.sanitizers = targetSanitizers

    var hostParameters = mockBuildParameters(
        destination: .host,
        buildPath: buildPath,
        config: config,
        toolchain: toolchain,
        flags: commonFlags,
        triple: inferredTriple,
        indexStoreMode: indexStoreMode
    )
    hostParameters.debuggingParameters = commonDebuggingParameters
    hostParameters.driverParameters = driverParameters
    hostParameters.linkingParameters = linkingParameters

    return try BuildPlan(
        destinationBuildParameters: destinationParameters,
        toolsBuildParameters: hostParameters,
        graph: graph,
        fileSystem: fs,
        observabilityScope: observabilityScope
    )
}

package func mockPluginTools(
    plugins: IdentifiableSet<ResolvedModule>,
    fileSystem: any FileSystem,
    buildParameters: BuildParameters,
    hostTriple: Basics.Triple
) throws -> [ResolvedModule.ID: [String: PluginTool]] {
    var accessibleToolsPerPlugin: [ResolvedModule.ID: [String: PluginTool]] = [:]
    for plugin in plugins where accessibleToolsPerPlugin[plugin.id] == nil {
        let accessibleTools = try plugin.preparePluginTools(
            fileSystem: fileSystem,
            environment: buildParameters.buildEnvironment,
            for: hostTriple
        ) { name, path in
            buildParameters.buildPath.appending(path)
        }

        accessibleToolsPerPlugin[plugin.id] = accessibleTools
    }

    return accessibleToolsPerPlugin
}

enum BuildError: Swift.Error {
    case error(String)
}

public struct BuildPlanResult {
    public let plan: Build.BuildPlan
    public let targetMap: [ResolvedModule.ID: ModuleBuildDescription]
    public let productMap: [ResolvedProduct.ID: Build.ProductBuildDescription]

    public init(plan: Build.BuildPlan) throws {
        self.plan = plan
        self.productMap = try Dictionary(
            throwingUniqueKeysWithValues: plan.buildProducts
                .compactMap { $0 as? Build.ProductBuildDescription }
                .map { ($0.product.id, $0) }
        )
        self.targetMap = try Dictionary(
            throwingUniqueKeysWithValues: plan.targetMap.compactMap {
                guard 
                    let target = plan.graph.allModules[$0] ??
                        IdentifiableSet(plan.derivedTestTargetsMap.values.flatMap { $0 })[$0]
                else {
                    throw BuildError.error("Target \($0) not found.")
                }
                return (target.id, $1)
            }
        )
    }

    public func checkTargetsCount(_ count: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(self.plan.targetMap.count, count, file: file, line: line)
    }

    public func checkProductsCount(_ count: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(self.plan.productMap.count, count, file: file, line: line)
    }

    public func moduleBuildDescription(for name: String) throws -> ModuleBuildDescription {
        let matchingIDs = targetMap.keys.filter({ $0.moduleName == name })
        guard matchingIDs.count == 1, let target = targetMap[matchingIDs[0]] else {
            if matchingIDs.isEmpty {
                throw BuildError.error("Target \(name) not found.")
            } else {
                throw BuildError.error("More than one target \(name) found.")
            }
        }
        return target
    }

    public func buildProduct(for name: String) throws -> Build.ProductBuildDescription {
        let matchingIDs = productMap.keys.filter({ $0.productName == name })
        guard matchingIDs.count == 1, let product = productMap[matchingIDs[0]] else {
            if matchingIDs.isEmpty {
                // <rdar://problem/30162871> Display the thrown error on macOS
                throw BuildError.error("Product \(name) not found.")
            } else {
                throw BuildError.error("More than one target \(name) found.")
            }
        }
        return product
    }
}

extension ModuleBuildDescription {
    public func swift() throws -> SwiftModuleBuildDescription {
        switch self {
        case .swift(let description):
            return description
        default:
            throw BuildError.error("Unexpected \(self) type found")
        }
    }

    public func clang() throws -> ClangModuleBuildDescription {
        switch self {
        case .clang(let description):
            return description
        default:
            throw BuildError.error("Unexpected \(self) type")
        }
    }
}
