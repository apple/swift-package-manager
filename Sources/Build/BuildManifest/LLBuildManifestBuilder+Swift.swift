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

import struct Basics.InternalError
import struct Basics.AbsolutePath
import struct Basics.RelativePath
import struct Basics.TSCAbsolutePath
import struct LLBuildManifest.Node
import struct LLBuildManifest.LLBuildManifest
import struct SPMBuildCore.BuildParameters
import class PackageGraph.ResolvedTarget
import protocol TSCBasic.FileSystem
import enum TSCBasic.ProcessEnv
import func TSCBasic.topologicalSort

#if USE_IMPL_ONLY_IMPORTS
@_implementationOnly import class DriverSupport.SPMSwiftDriverExecutor
@_implementationOnly import SwiftDriver
#else
import class DriverSupport.SPMSwiftDriverExecutor
import SwiftDriver
#endif

import PackageModel

extension LLBuildManifestBuilder {
    /// Create a llbuild target for a Swift target description and returns the Swift target's outputs.
    @discardableResult
    func createSwiftCompileCommand(
        _ target: SwiftTargetBuildDescription,
        addTargetCmd: Bool = true
    ) throws -> [Node] {
        // Inputs.
        let inputs = try self.computeSwiftCompileCmdInputs(target)

        // Outputs.
        let objectNodes = try target.objects.map(Node.file)
        let moduleNode = Node.file(target.moduleOutputPath)
        let cmdOutputs = objectNodes + [moduleNode]

        if self.buildParameters.driverParameters.useIntegratedSwiftDriver {
            try self.addSwiftCmdsViaIntegratedDriver(
                target,
                inputs: inputs,
                moduleNode: moduleNode
            )
        } else {
            try self.addCmdWithBuiltinSwiftTool(target, inputs: inputs, cmdOutputs: cmdOutputs)
        }

        if addTargetCmd {
            self.addTargetCmd(
                target: target.target,
                isTestTarget: target.isTestTarget,
                inputs: cmdOutputs
            )
        }
        try self.addModuleWrapCmd(target)

        return cmdOutputs
    }

    private func addSwiftCmdsViaIntegratedDriver(
        _ target: SwiftTargetBuildDescription,
        inputs: [Node],
        moduleNode: Node
    ) throws {
        // Use the integrated Swift driver to compute the set of frontend
        // jobs needed to build this Swift target.
        var commandLine = try target.emitCommandLine()
        commandLine.append("-driver-use-frontend-path")
        commandLine.append(self.buildParameters.toolchain.swiftCompilerPath.pathString)
        // FIXME: At some point SwiftPM should provide its own executor for
        // running jobs/launching processes during planning
        let resolver = try ArgsResolver(fileSystem: target.fileSystem)
        let executor = SPMSwiftDriverExecutor(
            resolver: resolver,
            fileSystem: target.fileSystem,
            env: ProcessEnv.vars
        )
        var driver = try Driver(
            args: commandLine,
            diagnosticsOutput: .handler(self.observabilityScope.makeDiagnosticsHandler()),
            fileSystem: self.fileSystem,
            executor: executor
        )
        try driver.checkLDPathOption(commandLine: commandLine)

        let jobs = try driver.planBuild()
        try self.addSwiftDriverJobs(
            for: target,
            jobs: jobs,
            inputs: inputs,
            resolver: resolver,
            isMainModule: { driver.isExplicitMainModuleJob(job: $0) }
        )
    }

    private func addSwiftDriverJobs(
        for targetDescription: SwiftTargetBuildDescription,
        jobs: [Job],
        inputs: [Node],
        resolver: ArgsResolver,
        isMainModule: (Job) -> Bool,
        uniqueExplicitDependencyTracker: UniqueExplicitDependencyJobTracker? = nil
    ) throws {
        // Add build jobs to the manifest
        for job in jobs {
            let tool = try resolver.resolve(.path(job.tool))
            let commandLine = try job.commandLine.map { try resolver.resolve($0) }
            let arguments = [tool] + commandLine

            // Check if an explicit pre-build dependency job has already been
            // added as a part of this build.
            if let uniqueExplicitDependencyTracker,
               job.isExplicitDependencyPreBuildJob
            {
                if try !uniqueExplicitDependencyTracker.registerExplicitDependencyBuildJob(job) {
                    // This is a duplicate of a previously-seen identical job.
                    // Skip adding it to the manifest
                    continue
                }
            }

            let jobInputs = try job.inputs.map { try $0.resolveToNode(fileSystem: self.fileSystem) }
            let jobOutputs = try job.outputs.map { try $0.resolveToNode(fileSystem: self.fileSystem) }

            // Add target dependencies as inputs to the main module build command.
            //
            // Jobs for a target's intermediate build artifacts, such as PCMs or
            // modules built from a .swiftinterface, do not have a
            // dependency on cross-target build products. If multiple targets share
            // common intermediate dependency modules, such dependencies can lead
            // to cycles in the resulting manifest.
            var manifestNodeInputs: [Node] = []
            if self.buildParameters.driverParameters.useExplicitModuleBuild && !isMainModule(job) {
                manifestNodeInputs = jobInputs
            } else {
                manifestNodeInputs = (inputs + jobInputs).uniqued()
            }

            guard let firstJobOutput = jobOutputs.first else {
                throw InternalError("unknown first JobOutput")
            }

            let moduleName = targetDescription.target.c99name
            let packageName = targetDescription.package.identity.description.spm_mangledToC99ExtendedIdentifier()
            let description = job.description
            if job.kind.isSwiftFrontend {
                self.manifest.addSwiftFrontendCmd(
                    name: firstJobOutput.name,
                    moduleName: moduleName,
                    packageName: packageName,
                    description: description,
                    inputs: manifestNodeInputs,
                    outputs: jobOutputs,
                    arguments: arguments
                )
            } else {
                self.manifest.addShellCmd(
                    name: firstJobOutput.name,
                    description: description,
                    inputs: manifestNodeInputs,
                    outputs: jobOutputs,
                    arguments: arguments
                )
            }
        }
    }

    // Building a Swift module in Explicit Module Build mode requires passing all of its module
    // dependencies as explicit arguments to the build command. Thus, building a SwiftPM package
    // with multiple inter-dependent targets requires that each target’s build job must
    // have its target dependencies’ modules passed into it as explicit module dependencies.
    // Because none of the targets have been built yet, a given target's dependency scanning
    // action will not be able to discover its target dependencies' modules. Instead, it is
    // SwiftPM's responsibility to communicate to the driver, when planning a given target's
    // build, that this target has dependencies that are other targets, along with a list of
    // future artifacts of such dependencies (.swiftmodule and .pcm files).
    // The driver will then use those artifacts as explicit inputs to its module’s build jobs.
    //
    // Consider an example SwiftPM package with two targets: target B, and target A, where A
    // depends on B:
    // SwiftPM will process targets in a topological order and “bubble-up” each target’s
    // inter-module dependency graph to its dependencies. First, SwiftPM will process B, and be
    // able to plan its full build because it does not have any target dependencies. Then the
    // driver is tasked with planning a build for A. SwiftPM will pass as input to the driver
    // the module dependency graph of its target’s dependencies, in this case, just the
    // dependency graph of B. The driver is then responsible for the necessary post-processing
    // to merge the dependency graphs and plan the build for A, using artifacts of B as explicit
    // inputs.
    public func addTargetsToExplicitBuildManifest() throws {
        // Sort the product targets in topological order in order to collect and "bubble up"
        // their respective dependency graphs to the depending targets.
        let nodes: [ResolvedTarget.Dependency] = self.plan.targetMap.keys.map {
            ResolvedTarget.Dependency.target($0, conditions: [])
        }
        let allPackageDependencies = try topologicalSort(nodes, successors: { $0.dependencies })
        // Instantiate the inter-module dependency oracle which will cache commonly-scanned
        // modules across targets' Driver instances.
        let dependencyOracle = InterModuleDependencyOracle()

        // Explicit dependency pre-build jobs may be common to multiple targets.
        // We de-duplicate them here to avoid adding identical entries to the
        // downstream LLBuild manifest
        let explicitDependencyJobTracker = UniqueExplicitDependencyJobTracker()

        // Create commands for all target descriptions in the plan.
        for dependency in allPackageDependencies.reversed() {
            guard case .target(let target, _) = dependency else {
                // Product dependency build jobs are added after the fact.
                // Targets that depend on product dependencies will expand the corresponding
                // product into its constituent targets.
                continue
            }
            guard target.underlyingTarget.type != .systemModule,
                  target.underlyingTarget.type != .binary
            else {
                // Much like non-Swift targets, system modules will consist of a modulemap
                // somewhere in the filesystem, with the path to that module being either
                // manually-specified or computed based on the system module type (apt, brew).
                // Similarly, binary targets will bring in an .xcframework, the contents of
                // which will be exposed via search paths.
                //
                // In both cases, the dependency scanning action in the driver will be automatically
                // be able to detect such targets' modules.
                continue
            }
            guard let description = plan.targetMap[target] else {
                throw InternalError("Expected description for target \(target)")
            }
            switch description {
            case .swift(let desc):
                try self.createExplicitSwiftTargetCompileCommand(
                    description: desc,
                    dependencyOracle: dependencyOracle,
                    explicitDependencyJobTracker: explicitDependencyJobTracker
                )
            case .clang(let desc):
                try self.createClangCompileCommand(desc)
            case .mixed(let desc):
                try self.createMixedCompileCommand(desc)
            }
        }
    }

    private func createExplicitSwiftTargetCompileCommand(
        description: SwiftTargetBuildDescription,
        dependencyOracle: InterModuleDependencyOracle,
        explicitDependencyJobTracker: UniqueExplicitDependencyJobTracker?
    ) throws {
        // Inputs.
        let inputs = try self.computeSwiftCompileCmdInputs(description)

        // Outputs.
        let objectNodes = try description.objects.map(Node.file)
        let moduleNode = Node.file(description.moduleOutputPath)
        let cmdOutputs = objectNodes + [moduleNode]

        // Commands.
        try addExplicitBuildSwiftCmds(
            description,
            inputs: inputs,
            dependencyOracle: dependencyOracle,
            explicitDependencyJobTracker: explicitDependencyJobTracker
        )

        self.addTargetCmd(
            target: description.target,
            isTestTarget: description.isTestTarget,
            inputs: cmdOutputs
        )
        try self.addModuleWrapCmd(description)
    }

    private func addExplicitBuildSwiftCmds(
        _ targetDescription: SwiftTargetBuildDescription,
        inputs: [Node],
        dependencyOracle: InterModuleDependencyOracle,
        explicitDependencyJobTracker: UniqueExplicitDependencyJobTracker? = nil
    ) throws {
        // Pass the driver its external dependencies (target dependencies)
        var dependencyModuleDetailsMap: SwiftDriver.ExternalTargetModuleDetailsMap = [:]
        // Collect paths for target dependencies of this target (direct and transitive)
        try self.collectTargetDependencyModuleDetails(
            for: targetDescription.target,
            dependencyModuleDetailsMap: &dependencyModuleDetailsMap
        )

        // Compute the set of frontend
        // jobs needed to build this Swift target.
        var commandLine = try targetDescription.emitCommandLine()
        commandLine.append("-driver-use-frontend-path")
        commandLine.append(self.buildParameters.toolchain.swiftCompilerPath.pathString)
        commandLine.append("-experimental-explicit-module-build")
        let resolver = try ArgsResolver(fileSystem: self.fileSystem)
        let executor = SPMSwiftDriverExecutor(
            resolver: resolver,
            fileSystem: self.fileSystem,
            env: ProcessEnv.vars
        )
        var driver = try Driver(
            args: commandLine,
            fileSystem: self.fileSystem,
            executor: executor,
            externalTargetModuleDetailsMap: dependencyModuleDetailsMap,
            interModuleDependencyOracle: dependencyOracle
        )
        try driver.checkLDPathOption(commandLine: commandLine)

        let jobs = try driver.planBuild()
        try self.addSwiftDriverJobs(
            for: targetDescription,
            jobs: jobs,
            inputs: inputs,
            resolver: resolver,
            isMainModule: { driver.isExplicitMainModuleJob(job: $0) },
            uniqueExplicitDependencyTracker: explicitDependencyJobTracker
        )
    }

    /// Collect a map from all target dependencies of the specified target to the build planning artifacts for said
    /// dependency,
    /// in the form of a path to a .swiftmodule file and the dependency's InterModuleDependencyGraph.
    private func collectTargetDependencyModuleDetails(
        for target: ResolvedTarget,
        dependencyModuleDetailsMap: inout SwiftDriver.ExternalTargetModuleDetailsMap
    ) throws {
        for dependency in target.dependencies(satisfying: self.buildEnvironment) {
            switch dependency {
            case .product:
                // Product dependencies are broken down into the targets that make them up.
                guard let dependencyProduct = dependency.product else {
                    throw InternalError("unknown dependency product for \(dependency)")
                }
                for dependencyProductTarget in dependencyProduct.targets {
                    try self.addTargetDependencyInfo(
                        for: dependencyProductTarget,
                        dependencyModuleDetailsMap: &dependencyModuleDetailsMap
                    )
                }
            case .target:
                // Product dependencies are broken down into the targets that make them up.
                guard let dependencyTarget = dependency.target else {
                    throw InternalError("unknown dependency target for \(dependency)")
                }
                try self.addTargetDependencyInfo(
                    for: dependencyTarget,
                    dependencyModuleDetailsMap: &dependencyModuleDetailsMap
                )
            }
        }
    }

    private func addTargetDependencyInfo(
        for target: ResolvedTarget,
        dependencyModuleDetailsMap: inout SwiftDriver.ExternalTargetModuleDetailsMap
    ) throws {
        guard case .swift(let dependencySwiftTargetDescription) = self.plan.targetMap[target] else {
            return
        }
        dependencyModuleDetailsMap[ModuleDependencyId.swiftPlaceholder(target.c99name)] =
            SwiftDriver.ExternalTargetModuleDetails(
                path: TSCAbsolutePath(dependencySwiftTargetDescription.moduleOutputPath),
                isFramework: false
            )
        try self.collectTargetDependencyModuleDetails(
            for: target,
            dependencyModuleDetailsMap: &dependencyModuleDetailsMap
        )
    }

    private func addCmdWithBuiltinSwiftTool(
        _ target: SwiftTargetBuildDescription,
        inputs: [Node],
        cmdOutputs: [Node]
    ) throws {
        let isLibrary = target.target.type == .library || target.target.type == .test
        let cmdName = target.target.getCommandName(config: self.buildConfig)

        self.manifest.addWriteSourcesFileListCommand(sources: target.sources, sourcesFileListPath: target.sourcesFileListPath)
        self.manifest.addSwiftCmd(
            name: cmdName,
            inputs: inputs + [Node.file(target.sourcesFileListPath)],
            outputs: cmdOutputs,
            executable: target.buildParameters.toolchain.swiftCompilerPath,
            moduleName: target.target.c99name,
            moduleAliases: target.target.moduleAliases,
            moduleOutputPath: target.moduleOutputPath,
            importPath: target.modulesPath,
            tempsPath: target.tempsPath,
            objects: try target.objects,
            otherArguments: try target.compileArguments(),
            sources: target.sources,
            fileList: target.sourcesFileListPath,
            isLibrary: isLibrary,
            wholeModuleOptimization: target.buildParameters.configuration == .release,
            outputFileMapPath: try target.writeOutputFileMap() // FIXME: Eliminate side effect.
        )
    }

    private func computeSwiftCompileCmdInputs(
        _ target: SwiftTargetBuildDescription
    ) throws -> [Node] {
        var inputs = target.sources.map(Node.file)

        let swiftVersionFilePath = addSwiftGetVersionCommand(buildParameters: target.buildParameters)
        inputs.append(.file(swiftVersionFilePath))

        // Add resources node as the input to the target. This isn't great because we
        // don't need to block building of a module until its resources are assembled but
        // we don't currently have a good way to express that resources should be built
        // whenever a module is being built.
        if let resourcesNode = try createResourcesBundle(for: .swift(target)) {
            inputs.append(resourcesNode)
        }

        func addStaticTargetInputs(_ target: ResolvedTarget) throws {
            // Ignore C Modules.
            if target.underlyingTarget is SystemLibraryTarget { return }
            // Ignore Binary Modules.
            if target.underlyingTarget is BinaryTarget { return }
            // Ignore Plugin Targets.
            if target.underlyingTarget is PluginTarget { return }

            // Depend on the binary for executable targets.
            if target.type == .executable {
                // FIXME: Optimize.
                let product = try plan.graph.allProducts.first {
                    try $0.type == .executable && $0.executableTarget == target
                }
                if let product {
                    guard let planProduct = plan.productMap[product] else {
                        throw InternalError("unknown product \(product)")
                    }
                    try inputs.append(file: planProduct.binaryPath)
                }
                return
            }

            switch self.plan.targetMap[target] {
            case .swift(let target)?:
                inputs.append(file: target.moduleOutputPath)
            case .clang(let target)?:
                for object in try target.objects {
                    inputs.append(file: object)
                }
            case .mixed(let target)?:
                inputs.append(file: target.swiftTargetBuildDescription.moduleOutputPath)

                for object in try target.clangTargetBuildDescription.objects {
                    inputs.append(file: object)
                }
            case nil:
                throw InternalError("unexpected: target \(target) not in target map \(self.plan.targetMap)")
            }
        }

        for dependency in target.target.dependencies(satisfying: self.buildEnvironment) {
            switch dependency {
            case .target(let target, _):
                try addStaticTargetInputs(target)

            case .product(let product, _):
                switch product.type {
                case .executable, .snippet, .library(.dynamic), .macro:
                    guard let planProduct = plan.productMap[product] else {
                        throw InternalError("unknown product \(product)")
                    }
                    // Establish a dependency on binary of the product.
                    try inputs.append(file: planProduct.binaryPath)

                // For automatic and static libraries, and plugins, add their targets as static input.
                case .library(.automatic), .library(.static), .plugin:
                    for target in product.targets {
                        try addStaticTargetInputs(target)
                    }

                case .test:
                    break
                }
            }
        }

        for binaryPath in target.libraryBinaryPaths {
            let path = self.destinationPath(forBinaryAt: binaryPath)
            if self.fileSystem.isDirectory(binaryPath) {
                inputs.append(directory: path)
            } else {
                inputs.append(file: path)
            }
        }

        try self.addBuildToolPlugins(.swift(target))

        // Depend on any required macro product's output.
        try target.requiredMacroProducts.forEach { macro in
            try inputs.append(.virtual(macro.getLLBuildTargetName(config: buildConfig)))
        }

        return inputs
    }

    /// Adds a top-level phony command that builds the entire target.
    func addTargetCmd(
        target: ResolvedTarget,
        isTestTarget: Bool,
        inputs: [Node]
    ) {
        // Create a phony node to represent the entire target.
        let targetName = target.getLLBuildTargetName(config: self.buildConfig)
        let targetOutput: Node = .virtual(targetName)

        self.manifest.addNode(targetOutput, toTarget: targetName)
        self.manifest.addPhonyCmd(
            name: targetOutput.name,
            inputs: inputs,
            outputs: [targetOutput]
        )
        if plan.graph.isInRootPackages(target, satisfying: self.buildEnvironment) {
            if !isTestTarget {
                addNode(targetOutput, toTarget: .main)
            }
            self.addNode(targetOutput, toTarget: .test)
        }
    }

    private func addModuleWrapCmd(_ target: SwiftTargetBuildDescription) throws {
        // Add commands to perform the module wrapping Swift modules when debugging strategy is `modulewrap`.
        guard self.buildParameters.debuggingStrategy == .modulewrap else { return }
        var moduleWrapArgs = [
            target.buildParameters.toolchain.swiftCompilerPath.pathString,
            "-modulewrap", target.moduleOutputPath.pathString,
            "-o", target.wrappedModuleOutputPath.pathString,
        ]
        moduleWrapArgs += try self.buildParameters.targetTripleArgs(for: target.target)
        self.manifest.addShellCmd(
            name: target.wrappedModuleOutputPath.pathString,
            description: "Wrapping AST for \(target.target.name) for debugging",
            inputs: [.file(target.moduleOutputPath)],
            outputs: [.file(target.wrappedModuleOutputPath)],
            arguments: moduleWrapArgs
        )
    }

    private func addSwiftGetVersionCommand(buildParameters: BuildParameters) -> AbsolutePath {
        let swiftCompilerPath = buildParameters.toolchain.swiftCompilerPath

        // If we are already tracking this compiler, we can re-use the existing command by just returning the tracking file.
        if let swiftVersionFilePath = swiftGetVersionFiles[swiftCompilerPath] {
            return swiftVersionFilePath
        }

        // Otherwise, come up with a path for the new file and generate a command to populate it.
        let swiftCompilerPathHash = String(swiftCompilerPath.pathString.hash, radix: 16, uppercase: true)
        let swiftVersionFilePath = buildParameters.buildPath.appending(component: "swift-version-\(swiftCompilerPathHash).txt")
        self.manifest.addSwiftGetVersionCommand(swiftCompilerPath: swiftCompilerPath, swiftVersionFilePath: swiftVersionFilePath)
        swiftGetVersionFiles[swiftCompilerPath] = swiftVersionFilePath
        return swiftVersionFilePath
    }
}

extension SwiftDriver.Job {
    fileprivate var isExplicitDependencyPreBuildJob: Bool {
        (kind == .emitModule && inputs.contains { $0.file.extension == "swiftinterface" }) || kind == .generatePCM
    }
}

/// A simple mechanism to keep track of already-known explicit module pre-build jobs.
/// It uses the output filename of the job (either a `.swiftmodule` or a `.pcm`) for uniqueness,
/// because the SwiftDriver encodes the module's context hash into this filename. Any two jobs
/// producing an binary module file with an identical name are therefore duplicate
private class UniqueExplicitDependencyJobTracker {
    private var uniqueDependencyModuleIDSet: Set<Int> = []

    /// Registers the input Job with the tracker. Returns `false` if this job is already known
    func registerExplicitDependencyBuildJob(_ job: SwiftDriver.Job) throws -> Bool {
        guard job.isExplicitDependencyPreBuildJob,
              let soleOutput = job.outputs.spm_only
        else {
            throw InternalError("Expected explicit module dependency build job")
        }
        let jobUniqueID = soleOutput.file.basename.hashValue
        let (new, _) = self.uniqueDependencyModuleIDSet.insert(jobUniqueID)
        return new
    }
}

// MARK: - Compile Mixed Languages

// TODO(ncooke3): Post-merge move to other file?
extension LLBuildManifestBuilder {
    /// Create a llbuild target for a mixed target description.
    func createMixedCompileCommand(
        _ target: MixedTargetBuildDescription
    ) throws {
        let swiftOutputs = try createSwiftCompileCommand(target.swiftTargetBuildDescription, addTargetCmd: false)
        let clangOutputs = try createClangCompileCommand(
            target.clangTargetBuildDescription,
            addTargetCmd: false,
            // This forces the Swift sub-target to build first. This is needed
            // since the Clang sub-target depends on build artifacts from the
            // Swift sub-target (e.g. generated Swift header).
            inputs: swiftOutputs,
            // The Swift compile command already created the resource bundle.
            createResourceBundle: false
        )
        self.addTargetCmd(target: target.target, isTestTarget: target.isTestTarget, inputs: swiftOutputs + clangOutputs)
    }
}

extension TypedVirtualPath {
    /// Resolve a typed virtual path provided by the Swift driver to
    /// a node in the build graph.
    fileprivate func resolveToNode(fileSystem: some FileSystem) throws -> Node {
        if let absolutePath = (file.absolutePath.flatMap { AbsolutePath($0) }) {
            return Node.file(absolutePath)
        } else if let relativePath = (file.relativePath.flatMap { RelativePath($0) }) {
            guard let workingDirectory: AbsolutePath = fileSystem.currentWorkingDirectory else {
                throw InternalError("unknown working directory")
            }
            return Node.file(workingDirectory.appending(relativePath))
        } else if let temporaryFileName = file.temporaryFileName {
            return Node.virtual(temporaryFileName.pathString)
        } else {
            throw InternalError("Cannot resolve VirtualPath: \(file)")
        }
    }
}

extension Driver {
    func checkLDPathOption(commandLine: [String]) throws {
        // `-ld-path` option is only available in recent versions of the compiler: rdar://117049947
        if let option = commandLine.first(where: { $0.hasPrefix("-ld-path") }),
           !self.supportedFrontendFeatures.contains("ld-path-driver-option") {
            throw LLBuildManifestBuilder.Error.ldPathDriverOptionUnavailable(option: option)
        }
    }
}
