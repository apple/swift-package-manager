//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2018-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation
import LLBuildManifest
import SPMBuildCore
import PackageGraph

import struct TSCBasic.ByteString

/// Contains the description of the build that is needed during the execution.
public struct BuildDescription: Codable {
    public typealias CommandName = String
    public typealias TargetName = String
    public typealias CommandLineFlag = String

    /// The Swift compiler invocation targets.
    let swiftCommands: [LLBuildManifest.CmdName: SwiftCompilerTool]

    /// The Swift compiler frontend invocation targets.
    let swiftFrontendCommands: [LLBuildManifest.CmdName: SwiftFrontendTool]

    /// The map of test discovery commands.
    let testDiscoveryCommands: [LLBuildManifest.CmdName: TestDiscoveryTool]

    /// The map of test entry point commands.
    let testEntryPointCommands: [LLBuildManifest.CmdName: TestEntryPointTool]

    /// The map of copy commands.
    let copyCommands: [LLBuildManifest.CmdName: CopyTool]

    /// The map of write commands.
    let writeCommands: [LLBuildManifest.CmdName: WriteAuxiliaryFile]

    /// A flag that indicates this build should perform a check for whether targets only import
    /// their explicitly-declared dependencies
    let explicitTargetDependencyImportCheckingMode: BuildParameters.TargetDependencyImportCheckingMode

    /// Every target's set of dependencies.
    let targetDependencyMap: [TargetName: [TargetName]]

    /// A full swift driver command-line invocation used to dependency-scan a given Swift target
    let swiftTargetScanArgs: [TargetName: [CommandLineFlag]]

    /// A set of all targets with generated source
    let generatedSourceTargetSet: Set<TargetName>

    /// The built test products.
    public let builtTestProducts: [BuiltTestProduct]

    /// Distilled information about any plugins defined in the package.
    let pluginDescriptions: [PluginBuildDescription]

    /// The enabled traits of the root package.
    let traitConfiguration: TraitConfiguration?

    public init(
        plan: BuildPlan,
        swiftCommands: [LLBuildManifest.CmdName: SwiftCompilerTool],
        swiftFrontendCommands: [LLBuildManifest.CmdName: SwiftFrontendTool],
        testDiscoveryCommands: [LLBuildManifest.CmdName: TestDiscoveryTool],
        testEntryPointCommands: [LLBuildManifest.CmdName: TestEntryPointTool],
        copyCommands: [LLBuildManifest.CmdName: CopyTool],
        writeCommands: [LLBuildManifest.CmdName: WriteAuxiliaryFile],
        pluginDescriptions: [PluginBuildDescription]
    ) throws {
        try self.init(
            plan: plan,
            swiftCommands: swiftCommands,
            swiftFrontendCommands: swiftFrontendCommands,
            testDiscoveryCommands: testDiscoveryCommands,
            testEntryPointCommands: testEntryPointCommands,
            copyCommands: copyCommands,
            writeCommands: writeCommands,
            pluginDescriptions: pluginDescriptions,
            traitConfiguration: nil
        )
    }

    package init(
        plan: BuildPlan,
        swiftCommands: [LLBuildManifest.CmdName: SwiftCompilerTool],
        swiftFrontendCommands: [LLBuildManifest.CmdName: SwiftFrontendTool],
        testDiscoveryCommands: [LLBuildManifest.CmdName: TestDiscoveryTool],
        testEntryPointCommands: [LLBuildManifest.CmdName: TestEntryPointTool],
        copyCommands: [LLBuildManifest.CmdName: CopyTool],
        writeCommands: [LLBuildManifest.CmdName: WriteAuxiliaryFile],
        pluginDescriptions: [PluginBuildDescription],
        traitConfiguration: TraitConfiguration?
    ) throws {
        self.swiftCommands = swiftCommands
        self.swiftFrontendCommands = swiftFrontendCommands
        self.testDiscoveryCommands = testDiscoveryCommands
        self.testEntryPointCommands = testEntryPointCommands
        self.copyCommands = copyCommands
        self.writeCommands = writeCommands
        self.explicitTargetDependencyImportCheckingMode = plan.destinationBuildParameters.driverParameters
            .explicitTargetDependencyImportCheckingMode
        self.traitConfiguration = traitConfiguration
        self.targetDependencyMap = try plan.targets
            .reduce(into: [TargetName: [TargetName]]()) { partial, targetBuildDescription in
                let deps = try targetBuildDescription.target.recursiveDependencies(
                    satisfying: targetBuildDescription.buildParameters.buildEnvironment
                )
                .compactMap(\.module).map(\.c99name)
                partial[targetBuildDescription.target.c99name] = deps
            }
        var targetCommandLines: [TargetName: [CommandLineFlag]] = [:]
        var generatedSourceTargets: [TargetName] = []
        for description in plan.targets {
            guard case .swift(let desc) = description else {
                continue
            }
            let buildParameters = description.buildParameters
            targetCommandLines[desc.target.c99name] =
                try desc.emitCommandLine(scanInvocation: true) + [
                    "-driver-use-frontend-path", buildParameters.toolchain.swiftCompilerPath.pathString,
                ]
            if case .discovery = desc.testTargetRole {
                generatedSourceTargets.append(desc.target.c99name)
            }
        }
        generatedSourceTargets.append(
            contentsOf: plan.pluginDescriptions
                .map(\.moduleC99Name)
        )
        self.swiftTargetScanArgs = targetCommandLines
        self.generatedSourceTargetSet = Set(generatedSourceTargets)
        self.builtTestProducts = try plan.buildProducts.filter { $0.product.type == .test }.map { desc in
            try BuiltTestProduct(
                productName: desc.product.name,
                binaryPath: desc.binaryPath,
                packagePath: desc.package.path,
                library: desc.buildParameters.testingParameters.library
            )
        }
        self.pluginDescriptions = pluginDescriptions
    }

    public func write(fileSystem: Basics.FileSystem, path: AbsolutePath) throws {
        let encoder = JSONEncoder.makeWithDefaults()
        let data = try encoder.encode(self)
        try fileSystem.writeFileContents(path, bytes: ByteString(data))
    }

    public static func load(fileSystem: Basics.FileSystem, path: AbsolutePath) throws -> BuildDescription {
        let contents: Data = try fileSystem.readFileContents(path)
        let decoder = JSONDecoder.makeWithDefaults()
        return try decoder.decode(BuildDescription.self, from: contents)
    }
}
