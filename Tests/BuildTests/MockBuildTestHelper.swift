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

@testable import PackageModel
@testable import TSCUtility
@testable import Build
import Basics
import SPMBuildCore
import XCTest

struct MockToolchain: PackageModel.Toolchain {
#if os(Windows)
    let librarianPath = AbsolutePath("/fake/path/to/link.exe")
#elseif os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
    let librarianPath = AbsolutePath("/fake/path/to/libtool")
#else
    let librarianPath = AbsolutePath("/fake/path/to/llvm-ar")
#endif
    let swiftCompilerPath = AbsolutePath("/fake/path/to/swiftc")
    let includeSearchPaths = [AbsolutePath]()
    let librarySearchPaths = [AbsolutePath]()
    let swiftResourcesPath: AbsolutePath? = nil
    let swiftStaticResourcesPath: AbsolutePath? = nil
    let isSwiftDevelopmentToolchain = false
    let sdkRootPath: AbsolutePath? = nil
    let swiftPluginServerPath: AbsolutePath? = nil
    let extraFlags = PackageModel.BuildFlags()
    let installedSwiftPMConfiguration = InstalledSwiftPMConfiguration.default

    func getClangCompiler() throws -> AbsolutePath {
        return "/fake/path/to/clang"
    }

    func _isClangCompilerVendorApple() throws -> Bool? {
      #if os(macOS)
        return true
      #else
        return false
      #endif
    }
}


extension Basics.Triple {
    static let x86_64MacOS = try! Self("x86_64-apple-macosx")
    static let x86_64Linux = try! Self("x86_64-unknown-linux-gnu")
    static let arm64Linux = try! Self("aarch64-unknown-linux-gnu")
    static let arm64Android = try! Self("aarch64-unknown-linux-android")
    static let windows = try! Self("x86_64-unknown-windows-msvc")
    static let wasi = try! Self("wasm32-unknown-wasi")
}

let hostTriple = try! UserToolchain.default.targetTriple
#if os(macOS)
    let defaultTargetTriple: String = hostTriple.tripleString(forPlatformVersion: "10.13")
#else
    let defaultTargetTriple: String = hostTriple.tripleString
#endif

func mockBuildParameters(
    buildPath: AbsolutePath = "/path/to/build",
    config: BuildConfiguration = .debug,
    toolchain: PackageModel.Toolchain = MockToolchain(),
    flags: PackageModel.BuildFlags = PackageModel.BuildFlags(),
    shouldLinkStaticSwiftStdlib: Bool = false,
    shouldDisableLocalRpath: Bool = false,
    canRenameEntrypointFunctionName: Bool = false,
    targetTriple: Basics.Triple = hostTriple,
    indexStoreMode: BuildParameters.IndexStoreMode = .off,
    useExplicitModuleBuild: Bool = false,
    linkerDeadStrip: Bool = true,
    linkTimeOptimizationMode: BuildParameters.LinkTimeOptimizationMode? = nil,
    omitFramePointers: Bool? = nil
) -> BuildParameters {
    return try! BuildParameters(
        dataPath: buildPath,
        configuration: config,
        toolchain: toolchain,
        hostTriple: hostTriple,
        targetTriple: targetTriple,
        flags: flags,
        pkgConfigDirectories: [],
        workers: 3,
        indexStoreMode: indexStoreMode,
        debuggingParameters: .init(
            targetTriple: targetTriple,
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

func mockBuildParameters(environment: BuildEnvironment) -> BuildParameters {
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

    return mockBuildParameters(config: environment.configuration ?? .debug, targetTriple: triple)
}

enum BuildError: Swift.Error {
    case error(String)
}

struct BuildPlanResult {

    let plan: Build.BuildPlan
    let targetMap: [String: TargetBuildDescription]
    let productMap: [String: Build.ProductBuildDescription]

    init(plan: Build.BuildPlan) throws {
        self.plan = plan
        self.productMap = try Dictionary(throwingUniqueKeysWithValues: plan.buildProducts.compactMap { $0 as? Build.ProductBuildDescription }.map{ ($0.product.name, $0) })
        self.targetMap = try Dictionary(throwingUniqueKeysWithValues: plan.targetMap.map{ ($0.0.name, $0.1) })
    }

    func checkTargetsCount(_ count: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(plan.targetMap.count, count, file: file, line: line)
    }

    func checkProductsCount(_ count: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(plan.productMap.count, count, file: file, line: line)
    }

    func target(for name: String) throws -> TargetBuildDescription {
        guard let target = targetMap[name] else {
            throw BuildError.error("Target \(name) not found.")
        }
        return target
    }

    func buildProduct(for name: String) throws -> Build.ProductBuildDescription {
        guard let product = productMap[name] else {
            // <rdar://problem/30162871> Display the thrown error on macOS
            throw BuildError.error("Product \(name) not found.")
        }
        return product
    }
}

extension TargetBuildDescription {
    func swiftTarget() throws -> SwiftTargetBuildDescription {
        switch self {
        case .swift(let target):
            return target
        default:
            throw BuildError.error("Unexpected \(self) type found")
        }
    }

    func clangTarget() throws -> ClangTargetBuildDescription {
        switch self {
        case .clang(let target):
            return target
        default:
            throw BuildError.error("Unexpected \(self) type")
        }
    }

    func mixedTarget() throws -> MixedTargetBuildDescription {
        switch self {
        case .mixed(let target):
            return target
        default:
            throw BuildError.error("Unexpected \(self) type")
        }
    }
}
