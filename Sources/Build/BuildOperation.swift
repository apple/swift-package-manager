//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2015-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import LLBuildManifest
import PackageGraph
import PackageLoading
import PackageModel
import SPMBuildCore
import SPMLLBuild
import Foundation

import class TSCBasic.DiagnosticsEngine
import protocol TSCBasic.OutputByteStream
import class TSCBasic.Process
import enum TSCBasic.ProcessEnv

import enum TSCUtility.Diagnostics
import class TSCUtility.MultiLineNinjaProgressAnimation
import class TSCUtility.NinjaProgressAnimation
import protocol TSCUtility.ProgressAnimationProtocol

#if USE_IMPL_ONLY_IMPORTS
@_implementationOnly import DriverSupport
@_implementationOnly import SwiftDriver
#else
import DriverSupport
import SwiftDriver
#endif

public final class BuildOperation: PackageStructureDelegate, SPMBuildCore.BuildSystem, BuildErrorAdviceProvider {
    /// The delegate used by the build system.
    public weak var delegate: SPMBuildCore.BuildSystemDelegate?

    /// Build parameters for products.
    let productsBuildParameters: BuildParameters

    /// Build parameters for build tools: plugins and macros.
    let toolsBuildParameters: BuildParameters

    /// The closure for loading the package graph.
    let packageGraphLoader: () throws -> PackageGraph

    /// the plugin configuration for build plugins
    let pluginConfiguration: PluginConfiguration?

    /// The llbuild build delegate reference.
    private var buildSystemDelegate: BuildOperationBuildSystemDelegateHandler?

    /// The llbuild build system reference.
    private var buildSystem: SPMLLBuild.BuildSystem?

    /// If build manifest caching should be enabled.
    public let cacheBuildManifest: Bool

    /// The build plan that was computed, if any.
    public private(set) var _buildPlan: BuildPlan?

    public var buildPlan: SPMBuildCore.BuildPlan {
        get throws {
            if let buildPlan = _buildPlan {
                return buildPlan
            } else {
                throw StringError("did not compute a build plan yet")
            }
        }
    }

    /// The build description resulting from planing.
    private let buildDescription = ThreadSafeBox<BuildDescription>()

    /// The loaded package graph.
    private let packageGraph = ThreadSafeBox<PackageGraph>()

    /// The output stream for the build delegate.
    private let outputStream: OutputByteStream

    /// The verbosity level to use for diagnostics.
    private let logLevel: Basics.Diagnostic.Severity

    /// File system to operate on.
    private let fileSystem: Basics.FileSystem

    /// ObservabilityScope with which to emit diagnostics.
    private let observabilityScope: ObservabilityScope

    public var builtTestProducts: [BuiltTestProduct] {
        (try? getBuildDescription())?.builtTestProducts ?? []
    }

    /// File rules to determine resource handling behavior.
    private let additionalFileRules: [FileRuleDescription]

    /// Alternative path to search for pkg-config `.pc` files.
    private let pkgConfigDirectories: [AbsolutePath]

    public init(
        productsBuildParameters: BuildParameters,
        toolsBuildParameters: BuildParameters,
        cacheBuildManifest: Bool,
        packageGraphLoader: @escaping () throws -> PackageGraph,
        pluginConfiguration: PluginConfiguration? = .none,
        additionalFileRules: [FileRuleDescription],
        pkgConfigDirectories: [AbsolutePath],
        outputStream: OutputByteStream,
        logLevel: Basics.Diagnostic.Severity,
        fileSystem: Basics.FileSystem,
        observabilityScope: ObservabilityScope
    ) {
        /// Checks if stdout stream is tty.
        var productsBuildParameters = productsBuildParameters
        productsBuildParameters.outputParameters.isColorized = outputStream.isTTY

        var toolsBuildParameters = toolsBuildParameters
        toolsBuildParameters.outputParameters.isColorized = outputStream.isTTY

        self.productsBuildParameters = productsBuildParameters
        self.toolsBuildParameters = toolsBuildParameters
        self.cacheBuildManifest = cacheBuildManifest
        self.packageGraphLoader = packageGraphLoader
        self.additionalFileRules = additionalFileRules
        self.pluginConfiguration = pluginConfiguration
        self.pkgConfigDirectories = pkgConfigDirectories
        self.outputStream = outputStream
        self.logLevel = logLevel
        self.fileSystem = fileSystem
        self.observabilityScope = observabilityScope.makeChildScope(description: "Build Operation")
    }

    public func getPackageGraph() throws -> PackageGraph {
        try self.packageGraph.memoize {
            try self.packageGraphLoader()
        }
    }

    /// Compute and return the latest build description.
    ///
    /// This will try skip build planning if build manifest caching is enabled
    /// and the package structure hasn't changed.
    public func getBuildDescription() throws -> BuildDescription {
        return try self.buildDescription.memoize {
            if self.cacheBuildManifest {
                do {
                    // if buildPackageStructure returns a valid description we use that, otherwise we perform full planning
                    if try self.buildPackageStructure() {
                        // confirm the step above created the build description as expected
                        // we trust it to update the build description when needed
                        let buildDescriptionPath = self.productsBuildParameters.buildDescriptionPath
                        guard self.fileSystem.exists(buildDescriptionPath) else {
                            throw InternalError("could not find build descriptor at \(buildDescriptionPath)")
                        }
                        // return the build description that's on disk.
                        return try BuildDescription.load(fileSystem: self.fileSystem, path: buildDescriptionPath)
                    }
                } catch {
                    // since caching is an optimization, warn about failing to load the cached version
                    self.observabilityScope.emit(
                        warning: "failed to load the cached build description",
                        underlyingError: error
                    )
                }
            }
            // We need to perform actual planning if we reach here.
            return try self.plan().description
        }
    }

    public func getBuildManifest() throws -> LLBuildManifest {
        return try self.plan().manifest
    }

    /// Cancel the active build operation.
    public func cancel(deadline: DispatchTime) throws {
        buildSystem?.cancel()
    }

    // Emit a warning if a target imports another target in this build
    // without specifying it as a dependency in the manifest
    private func verifyTargetImports(in description: BuildDescription) throws {
        let checkingMode = description.explicitTargetDependencyImportCheckingMode
        guard checkingMode != .none else {
            return
        }
        // Ensure the compiler supports the import-scan operation
        guard DriverSupport.checkSupportedFrontendFlags(
            flags: ["import-prescan"],
            toolchain: self.productsBuildParameters.toolchain,
            fileSystem: localFileSystem
        ) else {
            return
        }

        for (target, commandLine) in description.swiftTargetScanArgs {
            do {
                guard let dependencies = description.targetDependencyMap[target] else {
                    // Skip target if no dependency information is present
                    continue
                }
                let targetDependenciesSet = Set(dependencies)
                guard !description.generatedSourceTargetSet.contains(target),
                      targetDependenciesSet.intersection(description.generatedSourceTargetSet).isEmpty else {
                    // Skip targets which contain, or depend-on-targets, with generated source-code.
                    // Such as test discovery targets and targets with plugins.
                    continue
                }
                let resolver = try ArgsResolver(fileSystem: localFileSystem)
                let executor = SPMSwiftDriverExecutor(resolver: resolver,
                                                      fileSystem: localFileSystem,
                                                      env: ProcessEnv.vars)

                let consumeDiagnostics: DiagnosticsEngine = DiagnosticsEngine(handlers: [])
                var driver = try Driver(args: commandLine,
                                        diagnosticsOutput: .engine(consumeDiagnostics),
                                        fileSystem: localFileSystem,
                                        executor: executor)
                guard !consumeDiagnostics.hasErrors else {
                  // If we could not init the driver with this command, something went wrong,
                  // proceed without checking this target.
                  continue
                }
                let imports = try driver.performImportPrescan().imports
                let nonDependencyTargetsSet =
                    Set(description.targetDependencyMap.keys.filter { !targetDependenciesSet.contains($0) })
                let importedTargetsMissingDependency = Set(imports).intersection(nonDependencyTargetsSet)
                if let missedDependency = importedTargetsMissingDependency.first {
                    switch checkingMode {
                        case .error:
                            self.observabilityScope.emit(error: "Target \(target) imports another target (\(missedDependency)) in the package without declaring it a dependency.")
                        case .warn:
                            self.observabilityScope.emit(warning: "Target \(target) imports another target (\(missedDependency)) in the package without declaring it a dependency.")
                        case .none:
                            fatalError("Explicit import checking is disabled.")
                    }
                }
            } catch {
                // The above verification is a best-effort attempt to warn the user about a potential manifest
                // error. If something went wrong during the import-prescan, proceed silently.
                return
            }
        }
    }

    /// Perform a build using the given build description and subset.
    public func build(subset: BuildSubset) throws {
        guard !self.productsBuildParameters.shouldSkipBuilding else {
            return
        }

        let buildStartTime = DispatchTime.now()

        // Get the build description (either a cached one or newly created).

        // Get the build description
        let buildDescription = try getBuildDescription()

        // Verify dependency imports on the described targets
        try verifyTargetImports(in: buildDescription)

        // Create the build system.
        let buildSystem = try self.createBuildSystem(buildDescription: buildDescription)
        self.buildSystem = buildSystem

        // If any plugins are part of the build set, compile them now to surface
        // any errors up-front. Returns true if we should proceed with the build
        // or false if not. It will already have thrown any appropriate error.
        guard try self.compilePlugins(in: subset) else {
            return
        }

        // delegate is only available after createBuildSystem is called
        self.buildSystemDelegate?.buildStart(configuration: self.productsBuildParameters.configuration)

        // Perform the build.
        let llbuildTarget = try computeLLBuildTargetName(for: subset)
        let success = buildSystem.build(target: llbuildTarget)

        let duration = buildStartTime.distance(to: .now())

        let subsetDescriptor: String?
        switch subset {
        case .product(let productName):
            subsetDescriptor = "product '\(productName)'"
        case .target(let targetName):
            subsetDescriptor = "target: '\(targetName)'"
        case .allExcludingTests, .allIncludingTests:
            subsetDescriptor = nil
        }

        self.buildSystemDelegate?.buildComplete(
            success: success,
            duration: duration,
            subsetDescriptor: subsetDescriptor
        )
        self.delegate?.buildSystem(self, didFinishWithResult: success)
        guard success else { throw Diagnostics.fatalError }

        // Create backwards-compatibility symlink to old build path.
        let oldBuildPath = productsBuildParameters.dataPath.parentDirectory.appending(
            component: productsBuildParameters.configuration.dirname
        )
        if self.fileSystem.exists(oldBuildPath) {
            do { try self.fileSystem.removeFileTree(oldBuildPath) }
            catch {
                self.observabilityScope.emit(
                    warning: "unable to delete \(oldBuildPath), skip creating symbolic link",
                    underlyingError: error
                )
                return
            }
        }

        do {
            try self.fileSystem.createSymbolicLink(oldBuildPath, pointingAt: productsBuildParameters.buildPath, relative: true)
        } catch {
            self.observabilityScope.emit(
                warning: "unable to create symbolic link at \(oldBuildPath)",
                underlyingError: error
            )
        }
    }

    /// Compiles any plugins specified or implied by the build subset, returning
    /// true if the build should proceed. Throws an error in case of failure. A
    /// reason why the build might not proceed even on success is if only plugins
    /// should be compiled.
    func compilePlugins(in subset: BuildSubset) throws -> Bool {
        // Figure out what, if any, plugin descriptions to compile, and whether
        // to continue building after that based on the subset.
        let allPlugins = try getBuildDescription().pluginDescriptions
        let pluginsToCompile: [PluginDescription]
        let continueBuilding: Bool
        switch subset {
        case .allExcludingTests, .allIncludingTests:
            pluginsToCompile = allPlugins
            continueBuilding = true
        case .product(let productName):
            pluginsToCompile = allPlugins.filter{ $0.productNames.contains(productName) }
            continueBuilding = pluginsToCompile.isEmpty
        case .target(let targetName):
            pluginsToCompile = allPlugins.filter{ $0.targetName == targetName }
            continueBuilding = pluginsToCompile.isEmpty
        }

        // Compile any plugins we ended up with. If any of them fails, it will
        // throw.
        for plugin in pluginsToCompile {
            try compilePlugin(plugin)
        }

        // If we get this far they all succeeded. Return whether to continue the
        // build, based on the subset.
        return continueBuilding
    }

    // Compiles a single plugin, emitting its output and throwing an error if it
    // fails.
    func compilePlugin(_ plugin: PluginDescription) throws {
        guard let pluginConfiguration else {
            throw InternalError("unknown plugin script runner")
        }
        // Compile the plugin, getting back a PluginCompilationResult.
        class Delegate: PluginScriptCompilerDelegate {
            let preparationStepName: String
            let buildSystemDelegate: BuildOperationBuildSystemDelegateHandler?
            init(preparationStepName: String, buildSystemDelegate: BuildOperationBuildSystemDelegateHandler?) {
                self.preparationStepName = preparationStepName
                self.buildSystemDelegate = buildSystemDelegate
            }
            func willCompilePlugin(commandLine: [String], environment: EnvironmentVariables) {
                self.buildSystemDelegate?.preparationStepStarted(preparationStepName)
            }
            func didCompilePlugin(result: PluginCompilationResult) {
                self.buildSystemDelegate?.preparationStepHadOutput(
                    preparationStepName,
                    output: result.commandLine.joined(separator: " "),
                    verboseOnly: true
                )
                if !result.compilerOutput.isEmpty {
                    self.buildSystemDelegate?.preparationStepHadOutput(
                        preparationStepName,
                        output: result.compilerOutput,
                        verboseOnly: false
                    )
                }
                self.buildSystemDelegate?.preparationStepFinished(preparationStepName, result: (result.succeeded ? .succeeded : .failed))
            }
            func skippedCompilingPlugin(cachedResult: PluginCompilationResult) {
                // Historically we have emitted log info about cached plugins that are used. We should reconsider whether this is the right thing to do.
                self.buildSystemDelegate?.preparationStepStarted(preparationStepName)
                if !cachedResult.compilerOutput.isEmpty {
                    self.buildSystemDelegate?.preparationStepHadOutput(
                        preparationStepName,
                        output: cachedResult.compilerOutput,
                        verboseOnly: false
                    )
                }
                self.buildSystemDelegate?.preparationStepFinished(preparationStepName, result: (cachedResult.succeeded ? .succeeded : .failed))
            }
        }
        let delegate = Delegate(preparationStepName: "Compiling plugin \(plugin.targetName)", buildSystemDelegate: self.buildSystemDelegate)
        let result = try temp_await {
            pluginConfiguration.scriptRunner.compilePluginScript(
                sourceFiles: plugin.sources.paths,
                pluginName: plugin.targetName,
                toolsVersion: plugin.toolsVersion,
                observabilityScope: self.observabilityScope,
                callbackQueue: DispatchQueue.sharedConcurrent,
                delegate: delegate,
                completion: $0)
        }

        // Throw an error on failure; we will already have emitted the compiler's output in this case.
        if !result.succeeded {
            throw Diagnostics.fatalError
        }
    }

    /// Compute the llbuild target name using the given subset.
    private func computeLLBuildTargetName(for subset: BuildSubset) throws -> String {
        switch subset {
        case .allExcludingTests:
            return LLBuildManifestBuilder.TargetKind.main.targetName
        case .allIncludingTests:
            return LLBuildManifestBuilder.TargetKind.test.targetName
        default:
            // FIXME: This is super unfortunate that we might need to load the package graph.
            let graph = try getPackageGraph()
            if let result = subset.llbuildTargetName(
                for: graph,
                config: self.productsBuildParameters.configuration.dirname,
                observabilityScope: self.observabilityScope
            ) {
                return result
            }
            throw Diagnostics.fatalError
        }
    }

    /// Create the build plan and return the build description.
    private func plan() throws -> (description: BuildDescription, manifest: LLBuildManifest) {
        // Load the package graph.
        let graph = try getPackageGraph()

        let buildToolPluginInvocationResults: [ResolvedTarget.ID: (target: ResolvedTarget, results: [BuildToolPluginInvocationResult])]
        let prebuildCommandResults: [ResolvedTarget.ID: [PrebuildCommandResult]]
        // Invoke any build tool plugins in the graph to generate prebuild commands and build commands.
        if let pluginConfiguration, !self.productsBuildParameters.shouldSkipBuilding {
            // Hacky workaround for rdar://120560817, but it replicates precisely enough the original behavior before
            // products/tools build parameters were split. Ideally we want to have specify the correct path at the time
            // when `toolsBuildParameters` is initialized, but we have too many places in the codebase where that's
            // done, which makes it hard to realign them all at once.
            var pluginsBuildParameters = self.toolsBuildParameters
            pluginsBuildParameters.dataPath = pluginsBuildParameters.dataPath.parentDirectory.appending(components: ["plugins", "tools"])
            let buildOperationForPluginDependencies = BuildOperation(
                // FIXME: this doesn't maintain the products/tools split cleanly
                productsBuildParameters: pluginsBuildParameters,
                toolsBuildParameters: pluginsBuildParameters,
                cacheBuildManifest: false,
                packageGraphLoader: { return graph },
                additionalFileRules: self.additionalFileRules,
                pkgConfigDirectories: self.pkgConfigDirectories,
                outputStream: self.outputStream,
                logLevel: self.logLevel,
                fileSystem: self.fileSystem,
                observabilityScope: self.observabilityScope
            )
            buildToolPluginInvocationResults = try graph.invokeBuildToolPlugins(
                outputDir: pluginConfiguration.workDirectory.appending("outputs"),
                buildParameters: pluginsBuildParameters,
                additionalFileRules: self.additionalFileRules,
                toolSearchDirectories: [self.toolsBuildParameters.toolchain.swiftCompilerPath.parentDirectory],
                pkgConfigDirectories: self.pkgConfigDirectories,
                pluginScriptRunner: pluginConfiguration.scriptRunner,
                observabilityScope: self.observabilityScope,
                fileSystem: self.fileSystem
            ) { name, path in
                try buildOperationForPluginDependencies.build(subset: .product(name))
                if let builtTool = try buildOperationForPluginDependencies.buildPlan.buildProducts.first(where: { $0.product.name == name}) {
                    return try builtTool.binaryPath
                } else {
                    return nil
                }
            }


            // Surface any diagnostics from build tool plugins.
            var succeeded = true
            for (_, (target, results)) in buildToolPluginInvocationResults {
                // There is one result for each plugin that gets applied to a target.
                for result in results {
                    let diagnosticsEmitter = self.observabilityScope.makeDiagnosticsEmitter {
                        var metadata = ObservabilityMetadata()
                        metadata.targetName = target.name
                        metadata.pluginName = result.plugin.name
                        return metadata
                    }
                    for line in result.textOutput.split(separator: "\n") {
                        diagnosticsEmitter.emit(info: line)
                    }
                    for diag in result.diagnostics {
                        diagnosticsEmitter.emit(diag)
                    }
                    succeeded = succeeded && result.succeeded
                }

                if !succeeded {
                    throw StringError("build stopped due to build-tool plugin failures")
                }
            }

            // Run any prebuild commands provided by build tool plugins. Any failure stops the build.
            prebuildCommandResults = try graph.reachableTargets.reduce(into: [:], { partial, target in
                partial[target.id] = try buildToolPluginInvocationResults[target.id].map {
                    try self.runPrebuildCommands(for: $0.results)
                }
            })
        } else {
            buildToolPluginInvocationResults = [:]
            prebuildCommandResults = [:]
        }

        // Emit warnings about any unhandled files in authored packages. We do this after applying build tool plugins, once we know what files they handled.
        for package in graph.rootPackages where package.manifest.toolsVersion >= .v5_3 {
            for target in package.targets {
                // Get the set of unhandled files in targets.
                var unhandledFiles = Set(target.underlying.others)
                if unhandledFiles.isEmpty { continue }

                // Subtract out any that were inputs to any commands generated by plugins.
                if let result = buildToolPluginInvocationResults[target.id]?.results {
                    let handledFiles = result.flatMap { $0.buildCommands.flatMap { $0.inputFiles } }
                    unhandledFiles.subtract(handledFiles)
                }
                if unhandledFiles.isEmpty { continue }

                // Emit a diagnostic if any remain. This is kept the same as the previous message for now, but this could be improved.
                let diagnosticsEmitter = self.observabilityScope.makeDiagnosticsEmitter {
                    var metadata = ObservabilityMetadata()
                    metadata.packageIdentity = package.identity
                    metadata.packageKind = package.manifest.packageKind
                    metadata.targetName = target.name
                    return metadata
                }
                var warning = "found \(unhandledFiles.count) file(s) which are unhandled; explicitly declare them as resources or exclude from the target\n"
                for file in unhandledFiles {
                    warning += "    " + file.pathString + "\n"
                }
                diagnosticsEmitter.emit(warning: warning)
            }
        }

        // Create the build plan based, on the graph and any information from plugins.
        let plan = try BuildPlan(
            productsBuildParameters: self.productsBuildParameters,
            toolsBuildParameters: self.toolsBuildParameters,
            graph: graph,
            additionalFileRules: additionalFileRules,
            buildToolPluginInvocationResults: buildToolPluginInvocationResults.mapValues(\.results),
            prebuildCommandResults: prebuildCommandResults,
            disableSandbox: self.pluginConfiguration?.disableSandbox ?? false,
            fileSystem: self.fileSystem,
            observabilityScope: self.observabilityScope
        )
        self._buildPlan = plan

        let (buildDescription, buildManifest) = try BuildDescription.create(
            with: plan,
            disableSandboxForPluginCommands: self.pluginConfiguration?.disableSandbox ?? false,
            fileSystem: self.fileSystem,
            observabilityScope: self.observabilityScope
        )

        // Finally create the llbuild manifest from the plan.
        return (buildDescription, buildManifest)
    }

    /// Build the package structure target.
    private func buildPackageStructure() throws -> Bool {
        let buildSystem = try self.createBuildSystem(buildDescription: .none)
        self.buildSystem = buildSystem

        // Build the package structure target which will re-generate the llbuild manifest, if necessary.
        return buildSystem.build(target: "PackageStructure")
    }

    /// Create the build system using the given build description.
    ///
    /// The build description should only be omitted when creating the build system for
    /// building the package structure target.
    private func createBuildSystem(buildDescription: BuildDescription?) throws -> SPMLLBuild.BuildSystem {
        // Figure out which progress bar we have to use during the build.
        let progressAnimation: ProgressAnimationProtocol = self.logLevel.isVerbose
            ? MultiLineNinjaProgressAnimation(stream: self.outputStream)
            : NinjaProgressAnimation(stream: self.outputStream)

        let buildExecutionContext = BuildExecutionContext(
            productsBuildParameters: self.productsBuildParameters,
            toolsBuildParameters: self.toolsBuildParameters,
            buildDescription: buildDescription,
            fileSystem: self.fileSystem,
            observabilityScope: self.observabilityScope,
            packageStructureDelegate: self,
            buildErrorAdviceProvider: self
        )

        // Create the build delegate.
        let buildSystemDelegate = BuildOperationBuildSystemDelegateHandler(
            buildSystem: self,
            buildExecutionContext: buildExecutionContext,
            outputStream: self.outputStream,
            progressAnimation: progressAnimation,
            logLevel: self.logLevel,
            observabilityScope: self.observabilityScope,
            delegate: self.delegate
        )
        self.buildSystemDelegate = buildSystemDelegate

        let databasePath = self.productsBuildParameters.dataPath.appending("build.db").pathString
        let buildSystem = SPMLLBuild.BuildSystem(
            buildFile: self.productsBuildParameters.llbuildManifest.pathString,
            databaseFile: databasePath,
            delegate: buildSystemDelegate,
            schedulerLanes: self.productsBuildParameters.workers
        )

        // TODO: this seems fragile, perhaps we replace commandFailureHandler by adding relevant calls in the delegates chain
        buildSystemDelegate.commandFailureHandler = {
            buildSystem.cancel()
            self.delegate?.buildSystemDidCancel(self)
        }

        return buildSystem
    }

    /// Runs any prebuild commands associated with the given list of plugin invocation results, in order, and returns the
    /// results of running those prebuild commands.
    private func runPrebuildCommands(for pluginResults: [BuildToolPluginInvocationResult]) throws -> [PrebuildCommandResult] {
        guard let pluginConfiguration = self.pluginConfiguration else {
            throw InternalError("unknown plugin script runner")

        }
        // Run through all the commands from all the plugin usages in the target.
        return try pluginResults.map { pluginResult in
            // As we go we will collect a list of prebuild output directories whose contents should be input to the build,
            // and a list of the files in those directories after running the commands.
            var derivedFiles: [AbsolutePath] = []
            var prebuildOutputDirs: [AbsolutePath] = []
            for command in pluginResult.prebuildCommands {
                self.observabilityScope.emit(info: "Running " + (command.configuration.displayName ?? command.configuration.executable.basename))

                // Run the command configuration as a subshell. This doesn't return until it is done.
                // TODO: We need to also use any working directory, but that support isn't yet available on all platforms at a lower level.
                var commandLine = [command.configuration.executable.pathString] + command.configuration.arguments
                if !pluginConfiguration.disableSandbox {
                    commandLine = try Sandbox.apply(command: commandLine, fileSystem: self.fileSystem, strictness: .writableTemporaryDirectory, writableDirectories: [pluginResult.pluginOutputDirectory])
                }
                let processResult = try Process.popen(arguments: commandLine, environment: command.configuration.environment)
                let output = try processResult.utf8Output() + processResult.utf8stderrOutput()
                if processResult.exitStatus != .terminated(code: 0) {
                    throw StringError("failed: \(command)\n\n\(output)")
                }

                // Add any files found in the output directory declared for the prebuild command after the command ends.
                let outputFilesDir = command.outputFilesDirectory
                if let swiftFiles = try? self.fileSystem.getDirectoryContents(outputFilesDir).sorted() {
                    derivedFiles.append(contentsOf: swiftFiles.map{ outputFilesDir.appending(component: $0) })
                }

                // Add the output directory to the list of directories whose structure should affect the build plan.
                prebuildOutputDirs.append(outputFilesDir)
            }

            // Add the results of running any prebuild commands for this invocation.
            return PrebuildCommandResult(derivedFiles: derivedFiles, outputDirectories: prebuildOutputDirs)
        }
    }

    public func provideBuildErrorAdvice(for target: String, command: String, message: String) -> String? {
        // Find the target for which the error was emitted.  If we don't find it, we can't give any advice.
        guard let _ = self._buildPlan?.targets.first(where: { $0.target.name == target }) else { return nil }

        // Check for cases involving modules that cannot be found.
        if let importedModule = message.firstMatch(of: #/no such module '(?<module>.+)'/#)?.module {
            // A target is importing a module that can't be found.  We take a look at the build plan and see if can offer any advice.

            // Look for a target with the same module name as the one that's being imported.
            if let importedTarget = self._buildPlan?.targets.first(where: { $0.target.c99name == importedModule }) {
                // For the moment we just check for executables that other targets try to import.
                if importedTarget.target.type == .executable {
                    return "module '\(importedModule)' is the main module of an executable, and cannot be imported by tests and other targets"
                }
                if importedTarget.target.type == .macro {
                    return "module '\(importedModule)' is a macro, and cannot be imported by tests and other targets"
                }

                // Here we can add more checks in the future.
            }
        }
        return nil
    }

    public func packageStructureChanged() -> Bool {
        do {
            _ = try self.plan()
        }
        catch Diagnostics.fatalError {
            return false
        }
        catch {
            self.observabilityScope.emit(error)
            return false
        }
        return true
    }
}

extension BuildOperation {
    public struct PluginConfiguration {
        /// Entity responsible for compiling and running plugin scripts.
        let scriptRunner: PluginScriptRunner

        /// Directory where plugin intermediate files are stored.
        let workDirectory: AbsolutePath

        /// Whether to sandbox commands from build tool plugins.
        let disableSandbox: Bool

        public init(scriptRunner: PluginScriptRunner, workDirectory: AbsolutePath, disableSandbox: Bool) {
            self.scriptRunner = scriptRunner
            self.workDirectory = workDirectory
            self.disableSandbox = disableSandbox
        }
    }
}

extension BuildDescription {
    static func create(
        with plan: BuildPlan,
        disableSandboxForPluginCommands: Bool,
        fileSystem: Basics.FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> (BuildDescription, LLBuildManifest) {
        // Generate the llbuild manifest.
        let llbuild = LLBuildManifestBuilder(plan, disableSandboxForPluginCommands: disableSandboxForPluginCommands, fileSystem: fileSystem, observabilityScope: observabilityScope)
        let buildManifest = try llbuild.generateManifest(at: plan.destinationBuildParameters.llbuildManifest)

        let swiftCommands = llbuild.manifest.getCmdToolMap(kind: SwiftCompilerTool.self)
        let swiftFrontendCommands = llbuild.manifest.getCmdToolMap(kind: SwiftFrontendTool.self)
        let testDiscoveryCommands = llbuild.manifest.getCmdToolMap(kind: TestDiscoveryTool.self)
        let testEntryPointCommands = llbuild.manifest.getCmdToolMap(kind: TestEntryPointTool.self)
        let copyCommands = llbuild.manifest.getCmdToolMap(kind: CopyTool.self)
        let writeCommands = llbuild.manifest.getCmdToolMap(kind: WriteAuxiliaryFile.self)

        // Create the build description.
        let buildDescription = try BuildDescription(
            plan: plan,
            swiftCommands: swiftCommands,
            swiftFrontendCommands: swiftFrontendCommands,
            testDiscoveryCommands: testDiscoveryCommands,
            testEntryPointCommands: testEntryPointCommands,
            copyCommands: copyCommands,
            writeCommands: writeCommands,
            pluginDescriptions: plan.pluginDescriptions
        )
        try fileSystem.createDirectory(
            plan.destinationBuildParameters.buildDescriptionPath.parentDirectory,
            recursive: true
        )
        try buildDescription.write(fileSystem: fileSystem, path: plan.destinationBuildParameters.buildDescriptionPath)
        return (buildDescription, buildManifest)
    }
}

extension BuildSubset {
    /// Returns the name of the llbuild target that corresponds to the build subset.
    func llbuildTargetName(for graph: PackageGraph, config: String, observabilityScope: ObservabilityScope)
        -> String?
    {
        switch self {
        case .allExcludingTests:
            return LLBuildManifestBuilder.TargetKind.main.targetName
        case .allIncludingTests:
            return LLBuildManifestBuilder.TargetKind.test.targetName
        case .product(let productName):
            guard let product = graph.allProducts.first(where: { $0.name == productName }) else {
                observabilityScope.emit(error: "no product named '\(productName)'")
                return nil
            }
            // If the product is automatic, we build the main target because automatic products
            // do not produce a binary right now.
            if product.type == .library(.automatic) {
                observabilityScope.emit(
                    warning:
                        "'--product' cannot be used with the automatic product '\(productName)'; building the default target instead"
                )
                return LLBuildManifestBuilder.TargetKind.main.targetName
            }
            return observabilityScope.trap {
                try product.getLLBuildTargetName(config: config)
            }
        case .target(let targetName):
            guard let target = graph.allTargets.first(where: { $0.name == targetName }) else {
                observabilityScope.emit(error: "no target named '\(targetName)'")
                return nil
            }
            return target.getLLBuildTargetName(config: config)
        }
    }
}

extension Basics.Diagnostic.Severity {
    var isVerbose: Bool {
        return self <= .info
    }
}
