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
import LLBuildManifest
import PackageGraph
import PackageModel
import SPMBuildCore

#if USE_IMPL_ONLY_IMPORTS
@_implementationOnly import SwiftDriver
#else
import SwiftDriver
#endif

import struct TSCBasic.ByteString
import enum TSCBasic.ProcessEnv
import func TSCBasic.topologicalSort

/// High-level interface to ``LLBuildManifest`` and ``LLBuildManifestWriter``.
public class LLBuildManifestBuilder {
    enum Error: Swift.Error {
        case ldPathDriverOptionUnavailable(option: String)

        var description: String {
            switch self {
            case .ldPathDriverOptionUnavailable(let option):
                return "Unable to pass \(option), currently used version of `swiftc` doesn't support it."
            }
        }
    }

    public enum TargetKind {
        case main
        case test

        public var targetName: String {
            switch self {
            case .main: return "main"
            case .test: return "test"
            }
        }
    }

    /// The build plan to work on.
    public let plan: BuildPlan

    /// Whether to sandbox commands from build tool plugins.
    public let disableSandboxForPluginCommands: Bool

    /// File system reference.
    let fileSystem: any FileSystem

    /// ObservabilityScope with which to emit diagnostics
    public let observabilityScope: ObservabilityScope

    public internal(set) var manifest: LLBuildManifest = .init()

    var buildConfig: String { self.buildParameters.configuration.dirname }
    var buildParameters: BuildParameters { self.plan.buildParameters }
    var buildEnvironment: BuildEnvironment { self.buildParameters.buildEnvironment }

    /// Mapping from Swift compiler path to Swift get version files.
    var swiftGetVersionFiles = [AbsolutePath: AbsolutePath]()

    /// Create a new builder with a build plan.
    public init(
        _ plan: BuildPlan,
        disableSandboxForPluginCommands: Bool = false,
        fileSystem: any FileSystem,
        observabilityScope: ObservabilityScope
    ) {
        self.plan = plan
        self.disableSandboxForPluginCommands = disableSandboxForPluginCommands
        self.fileSystem = fileSystem
        self.observabilityScope = observabilityScope
    }

    // MARK: - Generate Manifest

    /// Generate manifest at the given path.
    @discardableResult
    public func generateManifest(at path: AbsolutePath) throws -> LLBuildManifest {
        self.swiftGetVersionFiles.removeAll()

        self.manifest.createTarget(TargetKind.main.targetName)
        self.manifest.createTarget(TargetKind.test.targetName)
        self.manifest.defaultTarget = TargetKind.main.targetName

        addPackageStructureCommand()
        addBinaryDependencyCommands()
        if self.buildParameters.driverParameters.useExplicitModuleBuild {
            // Explicit module builds use the integrated driver directly and
            // require that every target's build jobs specify its dependencies explicitly to plan
            // its build.
            // Currently behind:
            // --experimental-explicit-module-build
            try addTargetsToExplicitBuildManifest()
        } else {
            // Create commands for all target descriptions in the plan.
            for (_, description) in self.plan.targetMap {
                switch description {
                case .swift(let desc):
                    try self.createSwiftCompileCommand(desc)
                case .clang(let desc):
                    try self.createClangCompileCommand(desc)
                case .mixed(let desc):
                    try self.createMixedCompileCommand(desc)
                }
            }
        }

        if self.buildParameters.testingParameters.library == .xctest {
            try self.addTestDiscoveryGenerationCommand()
        }
        try self.addTestEntryPointGenerationCommand()

        // Create command for all products in the plan.
        for (_, description) in self.plan.productMap {
            try self.createProductCommand(description)
        }

        try LLBuildManifestWriter.write(self.manifest, at: path, fileSystem: self.fileSystem)
        return self.manifest
    }

    func addNode(_ node: Node, toTarget targetKind: TargetKind) {
        self.manifest.addNode(node, toTarget: targetKind.targetName)
    }
}

// MARK: - Package Structure

extension LLBuildManifestBuilder {
    private func addPackageStructureCommand() {
        let inputs = self.plan.graph.rootPackages.flatMap { package -> [Node] in
            var inputs = package.targets
                .map(\.sources.root)
                .sorted()
                .map { Node.directoryStructure($0) }

            // Add the output paths of any prebuilds that were run, so that we redo the plan if they change.
            var derivedSourceDirPaths: [AbsolutePath] = []
            for result in self.plan.prebuildCommandResults.values.flatMap({ $0 }) {
                derivedSourceDirPaths.append(contentsOf: result.outputDirectories)
            }
            inputs.append(contentsOf: derivedSourceDirPaths.sorted().map { Node.directoryStructure($0) })

            // FIXME: Need to handle version-specific manifests.
            inputs.append(file: package.manifest.path)

            // FIXME: This won't be the location of Package.resolved for multiroot packages.
            inputs.append(file: package.path.appending("Package.resolved"))

            // FIXME: Add config file as an input

            return inputs
        }

        let name = "PackageStructure"
        let output: Node = .virtual(name)

        self.manifest.addPkgStructureCmd(
            name: name,
            inputs: inputs,
            outputs: [output]
        )
        self.manifest.addNode(output, toTarget: name)
    }
}

// MARK: - Binary Dependencies

extension LLBuildManifestBuilder {
    // Creates commands for copying all binary artifacts depended on in the plan.
    private func addBinaryDependencyCommands() {
        let binaryPaths = Set(plan.targetMap.values.flatMap(\.libraryBinaryPaths))
        for binaryPath in binaryPaths {
            let destination = destinationPath(forBinaryAt: binaryPath)
            addCopyCommand(from: binaryPath, to: destination)
        }
    }
}

// MARK: - Compilation

extension LLBuildManifestBuilder {
    func addBuildToolPlugins(_ target: TargetBuildDescription) throws {
        // Add any regular build commands created by plugins for the target.
        for result in target.buildToolPluginInvocationResults {
            // Only go through the regular build commands — prebuild commands are handled separately.
            for command in result.buildCommands {
                // Create a shell command to invoke the executable. We include the path of the executable as a
                // dependency, and make sure the name is unique.
                let execPath = command.configuration.executable
                let uniquedName = ([execPath.pathString] + command.configuration.arguments).joined(separator: "|")
                let displayName = command.configuration.displayName ?? execPath.basename
                var commandLine = [execPath.pathString] + command.configuration.arguments
                if !self.disableSandboxForPluginCommands {
                    commandLine = try Sandbox.apply(
                        command: commandLine,
                        fileSystem: self.fileSystem,
                        strictness: .writableTemporaryDirectory,
                        writableDirectories: [result.pluginOutputDirectory]
                    )
                }
                self.manifest.addShellCmd(
                    name: displayName + "-" + ByteString(encodingAsUTF8: uniquedName).sha256Checksum,
                    description: displayName,
                    inputs: command.inputFiles.map { .file($0) },
                    outputs: command.outputFiles.map { .file($0) },
                    arguments: commandLine,
                    environment: command.configuration.environment,
                    workingDirectory: command.configuration.workingDirectory?.pathString
                )
            }
        }
    }
}

// MARK: - Test File Generation

extension LLBuildManifestBuilder {
    private func addTestDiscoveryGenerationCommand() throws {
        for testDiscoveryTarget in self.plan.targets.compactMap(\.testDiscoveryTargetBuildDescription) {
            let testTargets = testDiscoveryTarget.target.dependencies
                .compactMap(\.target).compactMap { self.plan.targetMap[$0] }
            let objectFiles = try testTargets.flatMap { try $0.objects }.sorted().map(Node.file)
            let outputs = testDiscoveryTarget.target.sources.paths

            guard let mainOutput = (outputs.first { $0.basename == TestDiscoveryTool.mainFileName }) else {
                throw InternalError("main output (\(TestDiscoveryTool.mainFileName)) not found")
            }
            let cmdName = mainOutput.pathString
            self.manifest.addTestDiscoveryCmd(
                name: cmdName,
                inputs: objectFiles,
                outputs: outputs.map(Node.file)
            )
        }
    }

    private func addTestEntryPointGenerationCommand() throws {
        for target in self.plan.targets {
            guard case .swift(let target) = target,
                  case .entryPoint(let isSynthesized) = target.testTargetRole,
                  isSynthesized else { continue }

            let testEntryPointTarget = target

            // Get the Swift target build descriptions of all discovery targets this synthesized entry point target
            // depends on.
            let discoveredTargetDependencyBuildDescriptions = testEntryPointTarget.target.dependencies
                .compactMap(\.target)
                .compactMap { self.plan.targetMap[$0] }
                .compactMap(\.testDiscoveryTargetBuildDescription)

            // The module outputs of the discovery targets this synthesized entry point target depends on are
            // considered the inputs to the entry point command.
            let inputs = discoveredTargetDependencyBuildDescriptions.map(\.moduleOutputPath)

            let outputs = testEntryPointTarget.target.sources.paths

            let mainFileName = TestEntryPointTool.mainFileName(for: buildParameters.testingParameters.library)
            guard let mainOutput = (outputs.first { $0.basename == mainFileName }) else {
                throw InternalError("main output (\(mainFileName)) not found")
            }
            let cmdName = mainOutput.pathString
            self.manifest.addTestEntryPointCmd(
                name: cmdName,
                inputs: inputs.map(Node.file),
                outputs: outputs.map(Node.file)
            )
        }
    }
}

extension TargetBuildDescription {
    /// If receiver represents a Swift target build description whose test target role is Discovery,
    /// then this returns that Swift target build description, else returns nil.
    fileprivate var testDiscoveryTargetBuildDescription: SwiftTargetBuildDescription? {
        guard case .swift(let targetBuildDescription) = self,
              case .discovery = targetBuildDescription.testTargetRole else { return nil }
        return targetBuildDescription
    }
}

extension ResolvedTarget {
    public func getCommandName(config: String) -> String {
        "C." + self.getLLBuildTargetName(config: config)
    }

    public func getLLBuildTargetName(config: String) -> String {
        "\(name)-\(config).module"
    }

    public func getLLBuildResourcesCmdName(config: String) -> String {
        "\(name)-\(config).module-resources"
    }
}

extension ResolvedProduct {
    public func getLLBuildTargetName(config: String) throws -> String {
        let potentialExecutableTargetName = "\(name)-\(config).exe"
        let potentialLibraryTargetName = "\(name)-\(config).dylib"

        switch type {
        case .library(.dynamic):
            return potentialLibraryTargetName
        case .test:
            return "\(name)-\(config).test"
        case .library(.static):
            return "\(name)-\(config).a"
        case .library(.automatic):
            throw InternalError("automatic library not supported")
        case .executable, .snippet:
            return potentialExecutableTargetName
        case .macro:
            #if BUILD_MACROS_AS_DYLIBS
            return potentialLibraryTargetName
            #else
            return potentialExecutableTargetName
            #endif
        case .plugin:
            throw InternalError("unexpectedly asked for the llbuild target name of a plugin product")
        }
    }

    public func getCommandName(config: String) throws -> String {
        try "C." + self.getLLBuildTargetName(config: config)
    }
}

// MARK: - Helper

extension LLBuildManifestBuilder {
    @discardableResult
    func addCopyCommand(
        from source: AbsolutePath,
        to destination: AbsolutePath
    ) -> (inputNode: Node, outputNode: Node) {
        let isDirectory = self.fileSystem.isDirectory(source)
        let nodeType = isDirectory ? Node.directory : Node.file
        let inputNode = nodeType(source)
        let outputNode = nodeType(destination)
        self.manifest.addCopyCmd(name: destination.pathString, inputs: [inputNode], outputs: [outputNode])
        return (inputNode, outputNode)
    }

    func destinationPath(forBinaryAt path: AbsolutePath) -> AbsolutePath {
        self.plan.buildParameters.buildPath.appending(component: path.basename)
    }
}

extension Sequence where Element: Hashable {
    /// Unique the elements in a sequence.
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
