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

import Build
import SPMBuildCore
import XCBuildSupport
import PackageGraph

import class Basics.ObservabilityScope
import struct PackageGraph.ModulesGraph
import struct PackageLoading.FileRuleDescription
import protocol TSCBasic.OutputByteStream

private struct NativeBuildSystemFactory: BuildSystemFactory {
    let swiftCommandState: SwiftCommandState

    func makeBuildSystem(
        explicitProduct: String?,
        traitConfiguration: TraitConfiguration,
        cacheBuildManifest: Bool,
        productsBuildParameters: BuildParameters?,
        toolsBuildParameters: BuildParameters?,
        packageGraphLoader: (() async throws -> ModulesGraph)?,
        outputStream: OutputByteStream?,
        logLevel: Diagnostic.Severity?,
        observabilityScope: ObservabilityScope?
    ) throws -> any BuildSystem {
        let rootPackageInfo = try swiftCommandState.getRootPackageInformation()
        let testEntryPointPath = productsBuildParameters?.testingParameters.testProductStyle.explicitlySpecifiedEntryPointPath
        return try BuildOperation(
            productsBuildParameters: try productsBuildParameters ?? self.swiftCommandState.productsBuildParameters,
            toolsBuildParameters: try toolsBuildParameters ?? self.swiftCommandState.toolsBuildParameters,
            cacheBuildManifest: cacheBuildManifest && self.swiftCommandState.canUseCachedBuildManifest(),
            packageGraphLoader: packageGraphLoader ?? {
                try self.swiftCommandState.loadPackageGraph(
                    explicitProduct: explicitProduct,
                    traitConfiguration: traitConfiguration,
                    testEntryPointPath: testEntryPointPath
                )
            },
            pluginConfiguration: .init(
                scriptRunner: self.swiftCommandState.getPluginScriptRunner(),
                workDirectory: try self.swiftCommandState.getActiveWorkspace().location.pluginWorkingDirectory,
                disableSandbox: self.swiftCommandState.shouldDisableSandbox
            ),
            scratchDirectory: self.swiftCommandState.scratchDirectory,
            traitConfiguration: traitConfiguration,
            additionalFileRules: FileRuleDescription.swiftpmFileTypes,
            pkgConfigDirectories: self.swiftCommandState.options.locations.pkgConfigDirectories,
            dependenciesByRootPackageIdentity: rootPackageInfo.dependencies,
            targetsByRootPackageIdentity: rootPackageInfo.targets,
            outputStream: outputStream ?? self.swiftCommandState.outputStream,
            logLevel: logLevel ?? self.swiftCommandState.logLevel,
            fileSystem: self.swiftCommandState.fileSystem,
            observabilityScope: observabilityScope ?? self.swiftCommandState.observabilityScope)
    }
}

private struct XcodeBuildSystemFactory: BuildSystemFactory {
    let swiftCommandState: SwiftCommandState

    func makeBuildSystem(
        explicitProduct: String?,
        traitConfiguration: TraitConfiguration,
        cacheBuildManifest: Bool,
        productsBuildParameters: BuildParameters?,
        toolsBuildParameters: BuildParameters?,
        packageGraphLoader: (() async throws -> ModulesGraph)?,
        outputStream: OutputByteStream?,
        logLevel: Diagnostic.Severity?,
        observabilityScope: ObservabilityScope?
    ) throws -> any BuildSystem {
        return try XcodeBuildSystem(
            buildParameters: productsBuildParameters ?? self.swiftCommandState.productsBuildParameters,
            packageGraphLoader: packageGraphLoader ?? {
                try self.swiftCommandState.loadPackageGraph(
                    explicitProduct: explicitProduct
                )
            },
            outputStream: outputStream ?? self.swiftCommandState.outputStream,
            logLevel: logLevel ?? self.swiftCommandState.logLevel,
            fileSystem: self.swiftCommandState.fileSystem,
            observabilityScope: observabilityScope ?? self.swiftCommandState.observabilityScope
        )
    }
}

extension SwiftCommandState {
    public var defaultBuildSystemProvider: BuildSystemProvider {
        .init(providers: [
            .native: NativeBuildSystemFactory(swiftCommandState: self),
            .xcode: XcodeBuildSystemFactory(swiftCommandState: self)
        ])
    }
}
