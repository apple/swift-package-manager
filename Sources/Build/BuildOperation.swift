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

@_spi(SwiftPMInternal)
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
import class Basics.AsyncProcess
import struct TSCBasic.RegEx

import enum TSCUtility.Diagnostics

#if USE_IMPL_ONLY_IMPORTS
@_implementationOnly import DriverSupport
@_implementationOnly import SwiftDriver
#else
import DriverSupport
import SwiftDriver
#endif

package struct LLBuildSystemConfiguration {
    let toolsBuildParameters: BuildParameters
    let destinationBuildParameters: BuildParameters

    let scratchDirectory: AbsolutePath

    let traitConfiguration: TraitConfiguration?

    fileprivate(set) var manifestPath: AbsolutePath
    fileprivate(set) var databasePath: AbsolutePath
    fileprivate(set) var buildDescriptionPath: AbsolutePath

    let fileSystem: any Basics.FileSystem

    let logLevel: Basics.Diagnostic.Severity
    let outputStream: OutputByteStream

    let observabilityScope: ObservabilityScope

    init(
        toolsBuildParameters: BuildParameters,
        destinationBuildParameters: BuildParameters,
        scratchDirectory: AbsolutePath,
        traitConfiguration: TraitConfiguration?,
        manifestPath: AbsolutePath? = nil,
        databasePath: AbsolutePath? = nil,
        buildDescriptionPath: AbsolutePath? = nil,
        fileSystem: any Basics.FileSystem,
        logLevel: Basics.Diagnostic.Severity,
        outputStream: OutputByteStream,
        observabilityScope: ObservabilityScope
    ) {
        self.toolsBuildParameters = toolsBuildParameters
        self.destinationBuildParameters = destinationBuildParameters
        self.scratchDirectory = scratchDirectory
        self.traitConfiguration = traitConfiguration
        self.manifestPath = manifestPath ?? destinationBuildParameters.llbuildManifest
        self.databasePath = databasePath ?? scratchDirectory.appending("build.db")
        self.buildDescriptionPath = buildDescriptionPath ?? destinationBuildParameters.buildDescriptionPath
        self.fileSystem = fileSystem
        self.logLevel = logLevel
        self.outputStream = outputStream
        self.observabilityScope = observabilityScope
    }

    func buildParameters(for destination: BuildParameters.Destination) -> BuildParameters {
        switch destination {
        case .host: self.toolsBuildParameters
        case .target: self.destinationBuildParameters
        }
    }

    func buildEnvironment(for destination:  BuildParameters.Destination) -> BuildEnvironment {
        switch destination {
        case .host: self.toolsBuildParameters.buildEnvironment
        case .target: self.destinationBuildParameters.buildEnvironment
        }
    }

    func shouldSkipBuilding(for destination: BuildParameters.Destination) -> Bool {
        switch destination {
        case .host: self.toolsBuildParameters.shouldSkipBuilding
        case .target: self.destinationBuildParameters.shouldSkipBuilding
        }
    }

    func toolchain(for description: BuildParameters.Destination) -> any PackageModel.Toolchain {
        switch description {
        case .host: self.toolsBuildParameters.toolchain
        case .target: self.destinationBuildParameters.toolchain
        }
    }

    func buildPath(for description: BuildParameters.Destination) -> AbsolutePath {
        switch description {
        case .host: self.toolsBuildParameters.buildPath
        case .target: self.destinationBuildParameters.buildPath
        }
    }

    func dataPath(for description: BuildParameters.Destination) -> AbsolutePath {
        switch description {
        case .host: self.toolsBuildParameters.dataPath
        case .target: self.destinationBuildParameters.dataPath
        }
    }

    func buildDescriptionPath(for description: BuildParameters.Destination) -> AbsolutePath {
        switch description {
        case .host: self.toolsBuildParameters.buildDescriptionPath
        case .target: self.destinationBuildParameters.buildDescriptionPath
        }
    }

    func configuration(for destination: BuildParameters.Destination) -> BuildConfiguration {
        switch destination {
        case .host: self.toolsBuildParameters.configuration
        case .target: self.destinationBuildParameters.configuration
        }
    }
}

public final class BuildOperation: PackageStructureDelegate, SPMBuildCore.BuildSystem, BuildErrorAdviceProvider {
    /// The delegate used by the build system.
    public weak var delegate: SPMBuildCore.BuildSystemDelegate?

    private let config: LLBuildSystemConfiguration

    /// The closure for loading the package graph.
    let packageGraphLoader: () async throws -> ModulesGraph

    /// the plugin configuration for build plugins
    let pluginConfiguration: PluginConfiguration?

    /// The llbuild build system reference previously created
    /// via `createBuildSystem` call.
    private var current: (buildSystem: SPMLLBuild.BuildSystem, tracker: LLBuildProgressTracker)?

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
    private let packageGraph = ThreadSafeBox<ModulesGraph>()

    /// File system to operate on.
    private var fileSystem: Basics.FileSystem {
        config.fileSystem
    }

    /// ObservabilityScope with which to emit diagnostics.
    private var observabilityScope: ObservabilityScope {
        config.observabilityScope
    }

    public var builtTestProducts: [BuiltTestProduct] {
        get async {
            (try? await getBuildDescription())?.builtTestProducts ?? []
        }
    }

    /// File rules to determine resource handling behavior.
    private let additionalFileRules: [FileRuleDescription]

    /// Alternative path to search for pkg-config `.pc` files.
    private let pkgConfigDirectories: [AbsolutePath]

    /// Map of dependency package identities by root packages that depend on them.
    private let dependenciesByRootPackageIdentity: [PackageIdentity: [PackageIdentity]]

    /// Map of  root package identities by target names which are declared in them.
    private let rootPackageIdentityByTargetName: [String: PackageIdentity]

    public convenience init(
        productsBuildParameters: BuildParameters,
        toolsBuildParameters: BuildParameters,
        cacheBuildManifest: Bool,
        packageGraphLoader: @escaping () async throws -> ModulesGraph,
        pluginConfiguration: PluginConfiguration? = .none,
        scratchDirectory: AbsolutePath,
        additionalFileRules: [FileRuleDescription],
        pkgConfigDirectories: [AbsolutePath],
        dependenciesByRootPackageIdentity: [PackageIdentity: [PackageIdentity]],
        targetsByRootPackageIdentity: [PackageIdentity: [String]],
        outputStream: OutputByteStream,
        logLevel: Basics.Diagnostic.Severity,
        fileSystem: Basics.FileSystem,
        observabilityScope: ObservabilityScope
    ) {
        self.init(
            productsBuildParameters: productsBuildParameters,
            toolsBuildParameters: toolsBuildParameters,
            cacheBuildManifest: cacheBuildManifest,
            packageGraphLoader: packageGraphLoader,
            pluginConfiguration: pluginConfiguration,
            scratchDirectory: scratchDirectory,
            traitConfiguration: nil,
            additionalFileRules: additionalFileRules,
            pkgConfigDirectories: pkgConfigDirectories,
            dependenciesByRootPackageIdentity: dependenciesByRootPackageIdentity,
            targetsByRootPackageIdentity: targetsByRootPackageIdentity,
            outputStream: outputStream,
            logLevel: logLevel,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )
    }

    package init(
        productsBuildParameters: BuildParameters,
        toolsBuildParameters: BuildParameters,
        cacheBuildManifest: Bool,
        packageGraphLoader: @escaping () throws -> ModulesGraph,
        pluginConfiguration: PluginConfiguration? = .none,
        scratchDirectory: AbsolutePath,
        traitConfiguration: TraitConfiguration?,
        additionalFileRules: [FileRuleDescription],
        pkgConfigDirectories: [AbsolutePath],
        dependenciesByRootPackageIdentity: [PackageIdentity: [PackageIdentity]],
        targetsByRootPackageIdentity: [PackageIdentity: [String]],
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

        self.config = LLBuildSystemConfiguration(
            toolsBuildParameters: toolsBuildParameters,
            destinationBuildParameters: productsBuildParameters,
            scratchDirectory: scratchDirectory,
            traitConfiguration: traitConfiguration,
            fileSystem: fileSystem,
            logLevel: logLevel,
            outputStream: outputStream,
            observabilityScope: observabilityScope.makeChildScope(description: "Build Operation")
        )

        self.cacheBuildManifest = cacheBuildManifest
        self.packageGraphLoader = packageGraphLoader
        self.additionalFileRules = additionalFileRules
        self.pluginConfiguration = pluginConfiguration
        self.pkgConfigDirectories = pkgConfigDirectories
        self.dependenciesByRootPackageIdentity = dependenciesByRootPackageIdentity
        self.rootPackageIdentityByTargetName = (try? Dictionary<String, PackageIdentity>(throwingUniqueKeysWithValues: targetsByRootPackageIdentity.lazy.flatMap { e in e.value.map { ($0, e.key) } })) ?? [:]
    }

    public var modulesGraph: ModulesGraph {
        get async throws {
            try await self.packageGraph.memoize {
                try await self.packageGraphLoader()
            }
        }
    }

    /// Compute and return the latest build description.
    ///
    /// This will try skip build planning if build manifest caching is enabled
    /// and the package structure hasn't changed.
    public func getBuildDescription(subset: BuildSubset? = nil) async throws -> BuildDescription {
        return try await self.buildDescription.memoize {
            if self.cacheBuildManifest {
                do {
                    // if buildPackageStructure returns a valid description we use that, otherwise we perform full planning
                    if try self.buildPackageStructure() {
                        // confirm the step above created the build description as expected
                        // we trust it to update the build description when needed
                        let buildDescriptionPath = self.config.buildDescriptionPath(for: .target)
                        guard self.fileSystem.exists(buildDescriptionPath) else {
                            throw InternalError("could not find build descriptor at \(buildDescriptionPath)")
                        }
                        // return the build description that's on disk.
                        let buildDescription = try BuildDescription.load(fileSystem: self.fileSystem, path: buildDescriptionPath)

                        // We need to check that the build has same traits enabled for the cached build operation
                        // match otherwise we have to re-plan.
                        if buildDescription.traitConfiguration == self.config.traitConfiguration {
                            return buildDescription
                        }
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
            return try await self.plan(subset: subset).description
        }
    }

    public func getBuildManifest() async throws -> LLBuildManifest {
        return try await self.plan().manifest
    }

    /// Cancel the active build operation.
    public func cancel(deadline: DispatchTime) throws {
        current?.buildSystem.cancel()
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
            toolchain: self.config.toolchain(for: .target),
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
                                                      env: Environment.current)

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

    private static var didEmitUnexpressedDependencies = false

    private func detectUnexpressedDependencies() {
        return self.detectUnexpressedDependencies(
            // Note: once we switch from the toolchain global metadata, we will have to ensure we can match the right metadata used during the build.
            availableLibraries: self.config.toolchain(for: .target).providedLibraries,
            targetDependencyMap: self.buildDescription.targetDependencyMap
        )
    }

    // TODO: Currently this function will only match frameworks.
    func detectUnexpressedDependencies(
        availableLibraries: [ProvidedLibrary],
        targetDependencyMap: [String: [String]]?
    ) {
        // Ensure we only emit these once, regardless of how many builds are being done.
        guard !Self.didEmitUnexpressedDependencies else {
            return
        }
        Self.didEmitUnexpressedDependencies = true

        let availableFrameworks = Dictionary<String, PackageIdentity>(uniqueKeysWithValues: availableLibraries.compactMap {
            if let identity = Set($0.metadata.identities.map(\.identity)).spm_only {
                return ("\($0.metadata.productName).framework", identity)
            } else {
                return nil
            }
        })

        targetDependencyMap?.keys.forEach { targetName in
            let c99name = targetName.spm_mangledToC99ExtendedIdentifier()
            // Since we're analysing post-facto, we don't know which parameters are the correct ones.
            let possibleTempsPaths = [BuildParameters.Destination]([.target, .host]).map {
                self.config.buildPath(for: $0).appending(component: "\(c99name).build")
            }

            let usedSDKDependencies: [String] = Set(possibleTempsPaths).flatMap { possibleTempsPath in
                guard let contents = try? self.fileSystem.readFileContents(
                    possibleTempsPath.appending(component: "\(c99name).d")
                ) else {
                    return [String]()
                }

                // FIXME: We need a real makefile deps parser here...
                let deps = contents.description.split(whereSeparator: { $0.isWhitespace })
                return deps.filter {
                    !$0.hasPrefix(possibleTempsPath.parentDirectory.pathString)
                }.compactMap {
                    try? AbsolutePath(validating: String($0))
                }.compactMap {
                    return $0.components.first(where: { $0.hasSuffix(".framework") })
                }
            }

            let dependencies: [PackageIdentity]
            if let rootPackageIdentity = self.rootPackageIdentityByTargetName[targetName] {
                dependencies = self.dependenciesByRootPackageIdentity[rootPackageIdentity] ?? []
            } else {
                dependencies = []
            }

            Set(usedSDKDependencies).forEach {
                if availableFrameworks.keys.contains($0) {
                    if let availableFrameworkPackageIdentity = availableFrameworks[$0], !dependencies.contains(
                        availableFrameworkPackageIdentity
                    ) {
                        observabilityScope.emit(
                            warning: "target '\(targetName)' has an unexpressed depedency on '\(availableFrameworkPackageIdentity)'"
                        )
                    }
                }
            }
        }
    }

    /// Perform a build using the given build description and subset.
    public func build(subset: BuildSubset) async throws {
        guard !self.config.shouldSkipBuilding(for: .target) else {
            return
        }

        let buildStartTime = DispatchTime.now()

        // Get the build description (either a cached one or newly created).

        // Get the build description
        let buildDescription = try await getBuildDescription(subset: subset)

        // Verify dependency imports on the described targets
        try verifyTargetImports(in: buildDescription)

        // Create the build system.
        let (buildSystem, progressTracker) = try self.createBuildSystem(
            buildDescription: buildDescription,
            config: self.config
        )
        self.current = (buildSystem, progressTracker)

        // If any plugins are part of the build set, compile them now to surface
        // any errors up-front. Returns true if we should proceed with the build
        // or false if not. It will already have thrown any appropriate error.
        guard try await self.compilePlugins(in: subset) else {
            return
        }

        let configuration = self.config.configuration(for: .target)
        // delegate is only available after createBuildSystem is called
        progressTracker.buildStart(configuration: configuration)

        // Perform the build.
        let llbuildTarget = try await computeLLBuildTargetName(for: subset)
        let success = buildSystem.build(target: llbuildTarget)

        let duration = buildStartTime.distance(to: .now())

        self.detectUnexpressedDependencies()

        let subsetDescriptor: String?
        switch subset {
        case .product(let productName, _):
            subsetDescriptor = "product '\(productName)'"
        case .target(let targetName, _):
            subsetDescriptor = "target: '\(targetName)'"
        case .allExcludingTests, .allIncludingTests:
            subsetDescriptor = nil
        }

        progressTracker.buildComplete(
            success: success,
            duration: duration,
            subsetDescriptor: subsetDescriptor
        )
        guard success else { throw Diagnostics.fatalError }

        // Create backwards-compatibility symlink to old build path.
        let oldBuildPath = self.config.dataPath(for: .target).parentDirectory.appending(
            component: configuration.dirname
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
            try self.fileSystem.createSymbolicLink(
                oldBuildPath,
                pointingAt: self.config.buildPath(for: .target),
                relative: true
            )
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
    func compilePlugins(in subset: BuildSubset) async throws -> Bool {
        // Figure out what, if any, plugin descriptions to compile, and whether
        // to continue building after that based on the subset.
        let allPlugins = try await getBuildDescription().pluginDescriptions
        let pluginsToCompile: [PluginBuildDescription]
        let continueBuilding: Bool
        switch subset {
        case .allExcludingTests, .allIncludingTests:
            pluginsToCompile = allPlugins
            continueBuilding = true
        case .product(let productName, _):
            pluginsToCompile = allPlugins.filter{ $0.productNames.contains(productName) }
            continueBuilding = pluginsToCompile.isEmpty
        case .target(let targetName, _):
            pluginsToCompile = allPlugins.filter{ $0.moduleName == targetName }
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
    func compilePlugin(_ plugin: PluginBuildDescription) throws {
        guard let pluginConfiguration else {
            throw InternalError("unknown plugin script runner")
        }
        // Compile the plugin, getting back a PluginCompilationResult.
        final class Delegate: PluginScriptCompilerDelegate {
            let preparationStepName: String
            let progressTracker: LLBuildProgressTracker?
            init(preparationStepName: String, progressTracker: LLBuildProgressTracker?) {
                self.preparationStepName = preparationStepName
                self.progressTracker = progressTracker
            }
            func willCompilePlugin(commandLine: [String], environment: [String: String]) {
                self.progressTracker?.preparationStepStarted(preparationStepName)
            }
            func didCompilePlugin(result: PluginCompilationResult) {
                self.progressTracker?.preparationStepHadOutput(
                    preparationStepName,
                    output: result.commandLine.joined(separator: " "),
                    verboseOnly: true
                )
                if !result.compilerOutput.isEmpty {
                    self.progressTracker?.preparationStepHadOutput(
                        preparationStepName,
                        output: result.compilerOutput,
                        verboseOnly: false
                    )
                }
                self.progressTracker?.preparationStepFinished(preparationStepName, result: (result.succeeded ? .succeeded : .failed))
            }
            func skippedCompilingPlugin(cachedResult: PluginCompilationResult) {
                // Historically we have emitted log info about cached plugins that are used. We should reconsider whether this is the right thing to do.
                self.progressTracker?.preparationStepStarted(preparationStepName)
                if !cachedResult.compilerOutput.isEmpty {
                    self.progressTracker?.preparationStepHadOutput(
                        preparationStepName,
                        output: cachedResult.compilerOutput,
                        verboseOnly: false
                    )
                }
                self.progressTracker?.preparationStepFinished(preparationStepName, result: (cachedResult.succeeded ? .succeeded : .failed))
            }
        }
        let delegate = Delegate(
            preparationStepName: "Compiling plugin \(plugin.moduleName)",
            progressTracker: self.current?.tracker
        )
        let result = try temp_await {
            pluginConfiguration.scriptRunner.compilePluginScript(
                sourceFiles: plugin.sources.paths,
                pluginName: plugin.moduleName,
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
    func computeLLBuildTargetName(for subset: BuildSubset) async throws -> String {
        switch subset {
        case .allExcludingTests:
            return LLBuildManifestBuilder.TargetKind.main.targetName
        case .allIncludingTests:
            return LLBuildManifestBuilder.TargetKind.test.targetName
        case .product(let productName, let destination):
            // FIXME: This is super unfortunate that we might need to load the package graph.
            let graph = try await self.modulesGraph

            let buildTriple: BuildTriple? = if let destination {
                destination == .host ? .tools : .destination
            } else {
                nil
            }

            let product = graph.product(
                for: productName,
                destination: buildTriple
            )

            guard let product else {
                observabilityScope.emit(error: "no product named '\(productName)'")
                throw Diagnostics.fatalError
            }

            let buildParameters = config.buildParameters(
                for: product.buildTriple == .tools ? .host : .target
            )

            // If the product is automatic, we build the main target because automatic products
            // do not produce a binary right now.
            if product.type == .library(.automatic) {
                observabilityScope.emit(
                    warning:
                        "'--product' cannot be used with the automatic product '\(productName)'; building the default target instead"
                )
                return LLBuildManifestBuilder.TargetKind.main.targetName
            }
            return try product.getLLBuildTargetName(buildParameters: buildParameters)
        case .target(let targetName, let destination):
            // FIXME: This is super unfortunate that we might need to load the package graph.
            let graph = try await self.modulesGraph

            let buildTriple: BuildTriple? = if let destination {
                destination == .host ? .tools : .destination
            } else {
                nil
            }

            let target = graph.module(
                for: targetName,
                destination: buildTriple
            )

            guard let target else {
                observabilityScope.emit(error: "no target named '\(targetName)'")
                throw Diagnostics.fatalError
            }

            let buildParameters = config.buildParameters(
                for: target.buildTriple == .tools ? .host : .target
            )

            return target.getLLBuildTargetName(buildParameters: buildParameters)
        }
    }

    /// Create the build plan and return the build description.
    private func plan(subset: BuildSubset? = nil) async throws -> BuildManifestDescription {
        // Load the package graph.
        let graph = try await self.modulesGraph
        let buildToolPluginInvocationResults: [ResolvedModule.ID: (target: ResolvedModule, results: [BuildToolPluginInvocationResult])]
        let prebuildCommandResults: [ResolvedModule.ID: [PrebuildCommandResult]]
        // Invoke any build tool plugins in the graph to generate prebuild commands and build commands.
        if let pluginConfiguration, !self.config.shouldSkipBuilding(for: .target) {
            let pluginsPerModule = graph.pluginsPerModule(
                satisfying: self.config.buildEnvironment(for: .host)
            )

            let pluginTools = try buildPluginTools(
                graph: graph,
                pluginsPerModule: pluginsPerModule,
                hostTriple: try pluginConfiguration.scriptRunner.hostTriple
            )

            buildToolPluginInvocationResults = try await graph.invokeBuildToolPlugins(
                pluginsPerTarget: pluginsPerModule,
                pluginTools: pluginTools,
                outputDir: pluginConfiguration.workDirectory.appending("outputs"),
                buildParameters: self.config.toolsBuildParameters,
                additionalFileRules: self.additionalFileRules,
                toolSearchDirectories: [self.config.toolchain(for: .host).swiftCompilerPath.parentDirectory],
                pkgConfigDirectories: self.pkgConfigDirectories,
                pluginScriptRunner: pluginConfiguration.scriptRunner,
                observabilityScope: self.observabilityScope,
                fileSystem: self.fileSystem
            )

            // Surface any diagnostics from build tool plugins.
            var succeeded = true
            for (_, (target, results)) in buildToolPluginInvocationResults {
                // There is one result for each plugin that gets applied to a target.
                for result in results {
                    let diagnosticsEmitter = self.observabilityScope.makeDiagnosticsEmitter {
                        var metadata = ObservabilityMetadata()
                        metadata.moduleName = target.name
                        metadata.pluginName = result.plugin.name
                        return metadata
                    }
                    for line in result.textOutput.split(whereSeparator: { $0.isNewline }) {
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
            prebuildCommandResults = try graph.reachableModules.reduce(into: [:], { partial, target in
                partial[target.id] = try buildToolPluginInvocationResults[target.id].map {
                    try self.runPrebuildCommands(for: $0.results)
                }
            })
        } else {
            buildToolPluginInvocationResults = [:]
            prebuildCommandResults = [:]
        }

        // Emit warnings about any unhandled files in authored packages. We do this after applying build tool plugins, once we know what files they handled.
        // rdar://113256834 This fix works for the plugins that do not have PreBuildCommands.
        let targetsToConsider: [ResolvedModule]
        if let subset = subset, let recursiveDependencies = try
            subset.recursiveDependencies(for: graph, observabilityScope: observabilityScope) {
            targetsToConsider = recursiveDependencies
        } else {
            targetsToConsider = Array(graph.reachableModules)
        }

        for target in targetsToConsider {
            guard let package = graph.package(for: target), package.manifest.toolsVersion >= .v5_3 else {
                continue
            }

            // Get the set of unhandled files in targets.
            var unhandledFiles = Set(target.underlying.others)
            if unhandledFiles.isEmpty { continue }

            // Subtract out any that were inputs to any commands generated by plugins.
            if let result = buildToolPluginInvocationResults[target.id]?.results {
                let handledFiles = result.flatMap{ $0.buildCommands.flatMap{ $0.inputFiles } }
                unhandledFiles.subtract(handledFiles)
            }
            if unhandledFiles.isEmpty { continue }

            // Emit a diagnostic if any remain. This is kept the same as the previous message for now, but this could be improved.
            let diagnosticsEmitter = self.observabilityScope.makeDiagnosticsEmitter {
                var metadata = ObservabilityMetadata()
                metadata.packageIdentity = package.identity
                metadata.packageKind = package.manifest.packageKind
                metadata.moduleName = target.name
                return metadata
            }
            var warning = "found \(unhandledFiles.count) file(s) which are unhandled; explicitly declare them as resources or exclude from the target\n"
            for file in unhandledFiles {
                warning += "    " + file.pathString + "\n"
            }
            diagnosticsEmitter.emit(warning: warning)
        }

        // Create the build plan based, on the graph and any information from plugins.
        let plan = try BuildPlan(
            destinationBuildParameters: self.config.destinationBuildParameters,
            toolsBuildParameters: self.config.buildParameters(for: .host),
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
            from: plan,
            using: self.config,
            disableSandboxForPluginCommands: self.pluginConfiguration?.disableSandbox ?? false
        )

        // Finally create the llbuild manifest from the plan.
        return .init(description: buildDescription, manifest: buildManifest)
    }

    /// Build the package structure target.
    private func buildPackageStructure() throws -> Bool {
        let (buildSystem, tracker) = try self.createBuildSystem(
            buildDescription: .none,
            config: self.config
        )
        self.current = (buildSystem, tracker)

        // Build the package structure target which will re-generate the llbuild manifest, if necessary.
        return buildSystem.build(target: "PackageStructure")
    }

    /// Create the build system using the given build description.
    ///
    /// The build description should only be omitted when creating the build system for
    /// building the package structure target.
    private func createBuildSystem(
        buildDescription: BuildDescription?,
        config: LLBuildSystemConfiguration
    ) throws -> (buildSystem: SPMLLBuild.BuildSystem, tracker: LLBuildProgressTracker) {
        // Figure out which progress bar we have to use during the build.
        let progressAnimation = ProgressAnimation.ninja(
            stream: config.outputStream,
            verbose: config.logLevel.isVerbose
        )
        let buildExecutionContext = BuildExecutionContext(
            productsBuildParameters: config.destinationBuildParameters,
            toolsBuildParameters: config.toolsBuildParameters,
            buildDescription: buildDescription,
            fileSystem: config.fileSystem,
            observabilityScope: config.observabilityScope,
            packageStructureDelegate: self,
            buildErrorAdviceProvider: self
        )

        // Create the build delegate.
        let progressTracker = LLBuildProgressTracker(
            buildSystem: self,
            buildExecutionContext: buildExecutionContext,
            outputStream: config.outputStream,
            progressAnimation: progressAnimation,
            logLevel: config.logLevel,
            observabilityScope: config.observabilityScope,
            delegate: self.delegate
        )

        let llbuildSystem = SPMLLBuild.BuildSystem(
            buildFile: config.manifestPath.pathString,
            databaseFile: config.databasePath.pathString,
            delegate: progressTracker,
            schedulerLanes: config.destinationBuildParameters.workers
        )

        return (buildSystem: llbuildSystem, tracker: progressTracker)
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
                let processResult = try AsyncProcess.popen(arguments: commandLine, environment: command.configuration.environment)
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
        if let importedModule = try? RegEx(pattern: "no such module '(.+)'").matchGroups(in: message).first?.first {
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
            _ = try temp_await { (callback: @escaping (Result<BuildManifestDescription, any Error>) -> Void) in
                _Concurrency.Task {
                    do {
                        let value = try await self.plan()
                        callback(.success(value))
                    } catch {
                        callback(.failure(error))
                    }
                }
            }
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

extension BuildOperation {
    private func buildPluginTools(
        graph: ModulesGraph,
        pluginsPerModule: [ResolvedModule.ID: [ResolvedModule]],
        hostTriple: Basics.Triple
    ) throws -> [ResolvedModule.ID: [String: PluginTool]] {
        var accessibleToolsPerPlugin: [ResolvedModule.ID: [String: PluginTool]] = [:]

        var config = self.config

        config.manifestPath = config.dataPath(for: .host).appending(
            components: "..", "plugin-tools.yaml"
        )

        // FIXME: It should be possible to share database between plugin tools
        // and regular builds. To make that happen we need to refactor
        // `buildPackageStructure` to recognize the split.
        config.databasePath = config.scratchDirectory.appending("plugin-tools.db")

        config.buildDescriptionPath = config.buildPath(for: .host).appending(
            component: "plugin-tools-description.json"
        )

        let buildPlan = try BuildPlan(
            destinationBuildParameters: config.destinationBuildParameters,
            toolsBuildParameters: config.toolsBuildParameters,
            graph: graph,
            additionalFileRules: [],
            buildToolPluginInvocationResults: [:],
            prebuildCommandResults: [:],
            disableSandbox: false,
            fileSystem: config.fileSystem,
            observabilityScope: config.observabilityScope
        )

        let (buildDescription, _) = try BuildDescription.create(
            from: buildPlan,
            using: config,
            disableSandboxForPluginCommands: false
        )

        let (buildSystem, _) = try self.createBuildSystem(
            buildDescription: buildDescription,
            config: config
        )

        func buildToolBuilder(_ name: String, _ path: RelativePath) throws -> AbsolutePath? {
            let llbuildTarget = try self.computeLLBuildTargetName(for: .product(name, for: .host))
            let success = buildSystem.build(target: llbuildTarget)

            if !success {
                return nil
            }

            return try buildPlan.buildProducts.first {
                $0.product.name == name && $0.buildParameters.destination == .host
            }?.binaryPath
        }

        for (_, plugins) in pluginsPerModule {
            for plugin in plugins where accessibleToolsPerPlugin[plugin.id] == nil {
                // Determine the tools to which this plugin has access, and create a name-to-path mapping from tool
                // names to the corresponding paths. Built tools are assumed to be in the build tools directory.
                let accessibleTools = try plugin.preparePluginTools(
                    fileSystem: fileSystem,
                    environment: config.buildEnvironment(for: .host),
                    for: hostTriple
                ) { name, path in
                    if let result = try buildToolBuilder(name, path) {
                        return result
                    } else {
                        return config.buildPath(for: .host).appending(path)
                    }
                }

                accessibleToolsPerPlugin[plugin.id] = accessibleTools
            }
        }

        return accessibleToolsPerPlugin
    }
}

extension BuildDescription {
    static func create(
        from plan: BuildPlan,
        using config: LLBuildSystemConfiguration,
        disableSandboxForPluginCommands: Bool
    ) throws -> (BuildDescription, LLBuildManifest) {
        let fileSystem = config.fileSystem

        // Generate the llbuild manifest.
        let llbuild = LLBuildManifestBuilder(
            plan,
            disableSandboxForPluginCommands: disableSandboxForPluginCommands,
            fileSystem: fileSystem,
            observabilityScope: config.observabilityScope
        )
        let buildManifest = plan.destinationBuildParameters.prepareForIndexing == .off
            ? try llbuild.generateManifest(at: config.manifestPath)
            : try llbuild.generatePrepareManifest(at: config.manifestPath)

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
            pluginDescriptions: plan.pluginDescriptions,
            traitConfiguration: config.traitConfiguration
        )
        try fileSystem.createDirectory(
            config.buildDescriptionPath.parentDirectory,
            recursive: true
        )
        try buildDescription.write(
            fileSystem: fileSystem,
            path: config.buildDescriptionPath
        )
        return (buildDescription, buildManifest)
    }
}

extension BuildSubset {
    func recursiveDependencies(for graph: ModulesGraph, observabilityScope: ObservabilityScope) throws -> [ResolvedModule]? {
        switch self {
        case .allIncludingTests:
            return Array(graph.reachableModules)
        case .allExcludingTests:
            return graph.reachableModules.filter { $0.type != .test }
        case .product(let productName, let destination):
            let buildTriple: BuildTriple? = if let destination {
                destination == .host ? .tools : .destination
            } else {
                nil
            }

            guard let product = graph.product(
                for: productName,
                destination: buildTriple
            ) else {
                observabilityScope.emit(error: "no product named '\(productName)'")
                return nil
            }
            return try product.recursiveModuleDependencies()
        case .target(let targetName, let destination):
            let buildTriple: BuildTriple? = if let destination {
                destination == .host ? .tools : .destination
            } else {
                nil
            }

            guard let target = graph.module(
                for: targetName,
                destination: buildTriple
            ) else {
                observabilityScope.emit(error: "no target named '\(targetName)'")
                return nil
            }
            return try target.recursiveModuleDependencies()
        }
    }
}

extension Basics.Diagnostic.Severity {
    var isVerbose: Bool {
        return self <= .info
    }
}
