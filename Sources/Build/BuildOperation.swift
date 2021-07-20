/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basics
import LLBuildManifest
import PackageGraph
import PackageModel
import SPMBuildCore
import SPMLLBuild
import TSCBasic
import TSCUtility

@_implementationOnly import SwiftDriver

public final class BuildOperation: PackageStructureDelegate, SPMBuildCore.BuildSystem, BuildErrorAdviceProvider {

    /// The delegate used by the build system.
    public weak var delegate: SPMBuildCore.BuildSystemDelegate?

    /// The build parameters.
    public let buildParameters: BuildParameters

    /// The diagnostics engine.
    public let diagnostics: DiagnosticsEngine

    /// The closure for loading the package graph.
    let packageGraphLoader: () throws -> PackageGraph
    
    /// The closure for invoking plugins in the package graph.
    let pluginInvoker: (PackageGraph) throws -> [ResolvedTarget: [PluginInvocationResult]]

    /// The llbuild build delegate reference.
    private var buildSystemDelegate: BuildOperationBuildSystemDelegateHandler?

    /// The llbuild build system reference.
    private var buildSystem: SPMLLBuild.BuildSystem?

    /// If build manifest caching should be enabled.
    public let cacheBuildManifest: Bool

    /// The build plan that was computed, if any.
    public private(set) var buildPlan: BuildPlan?

    /// The build description resulting from planing.
    private var buildDescription: BuildDescription?

    /// The loaded package graph.
    private var packageGraph: PackageGraph?

    /// The stdout stream for the build delegate.
    let stdoutStream: OutputByteStream

    public var builtTestProducts: [BuiltTestProduct] {
        (try? getBuildDescription())?.builtTestProducts ?? []
    }

    public init(
        buildParameters: BuildParameters,
        cacheBuildManifest: Bool,
        packageGraphLoader: @escaping () throws -> PackageGraph,
        pluginInvoker: @escaping (PackageGraph) throws -> [ResolvedTarget: [PluginInvocationResult]],
        diagnostics: DiagnosticsEngine,
        stdoutStream: OutputByteStream
    ) {
        self.buildParameters = buildParameters
        self.cacheBuildManifest = cacheBuildManifest
        self.packageGraphLoader = packageGraphLoader
        self.pluginInvoker = pluginInvoker
        self.diagnostics = diagnostics
        self.stdoutStream = stdoutStream
    }

    public func getPackageGraph() throws -> PackageGraph {
        try memoize(to: &packageGraph) {
            try self.packageGraphLoader()
        }
    }
    
    public func getPluginInvocationResults(for graph: PackageGraph) throws -> [ResolvedTarget: [PluginInvocationResult]] {
        return try self.pluginInvoker(graph)
    }

    /// Compute and return the latest build description.
    ///
    /// This will try skip build planning if build manifest caching is enabled
    /// and the package structure hasn't changed.
    public func getBuildDescription() throws -> BuildDescription {
        try memoize(to: &buildDescription) {
            if self.cacheBuildManifest {
                do {
                    try self.buildPackageStructure()
                    // confirm the step above created the build description as expected
                    // we trust it to update the build description when needed
                    let buildDescriptionPath = self.buildParameters.buildDescriptionPath
                    guard localFileSystem.exists(buildDescriptionPath) else {
                        throw InternalError("could not find build descriptor at \(buildDescriptionPath)")
                    }
                    // return the build description that's on disk.
                    return try BuildDescription.load(from: buildDescriptionPath)
                } catch {
                    // since caching is an optimization, warn about failing to load the cached version
                    diagnostics.emit(warning: "failed to load the cached build description: \(error)")
                }
            }

            // We need to perform actual planning if we reach here.
            return try self.plan()
        }
    }

    /// Cancel the active build operation.
    public func cancel() {
        buildSystem?.cancel()
    }

    // Emit a warning if a target imports another target in this build
    // without specifying it as a dependency in the manifest
    private func verifyTargetImports(in description: BuildDescription) throws {
        guard !description.disableExplicitTargetDependencyImportChecking else {
            return
        }
        // Ensure the compiler supports the import-scan operation
        guard SwiftTargetBuildDescription.checkSupportedFrontendFlags(flags: ["import-prescan"], fs: localFileSystem) else {
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
                                        diagnosticsEngine: consumeDiagnostics,
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
                    diagnostics.emit(warning: "Target \(target) imports another target (\(missedDependency)) in the package without declaring it a dependency.", location: nil)
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
        // Get the build description
        let buildDescription = try getBuildDescription()

        // Verify dependency imports on the described targers
        try verifyTargetImports(in: buildDescription)

        // Create the build system.
        let buildSystem = try createBuildSystem(with: buildDescription)
        self.buildSystem = buildSystem

        // Perform the build.
        let llbuildTarget = try computeLLBuildTargetName(for: subset)
        let success = buildSystem.build(target: llbuildTarget)

        buildSystemDelegate?.buildComplete(success: success)
        delegate?.buildSystem(self, didFinishWithResult: success)
        guard success else { throw Diagnostics.fatalError }

        // Create backwards-compatibility symlink to old build path.
        let oldBuildPath = buildParameters.dataPath.parentDirectory.appending(
            component: buildParameters.configuration.dirname
        )
        if localFileSystem.exists(oldBuildPath) {
            do { try localFileSystem.removeFileTree(oldBuildPath) }
            catch {
                diagnostics.emit(warning: "unable to delete \(oldBuildPath), skip creating symbolic link: \(error)")
                return
            }
        }

        do {
            try localFileSystem.createSymbolicLink(oldBuildPath, pointingAt: buildParameters.buildPath, relative: true)
        } catch {
            diagnostics.emit(warning: "unable to create symbolic link at \(oldBuildPath): \(error)")
        }
    }

    /// Compute the llbuild target name using the given subset.
    func computeLLBuildTargetName(for subset: BuildSubset) throws -> String {
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
                diagnostics: diagnostics,
                config: buildParameters.configuration.dirname
            ) {
                return result
            }
            throw Diagnostics.fatalError
        }
    }

    /// Create the build plan and return the build description.
    private func plan() throws -> BuildDescription {
        // Load the package graph.
        let graph = try getPackageGraph()
        
        // Invoke any plugins in the graph, and get the results.
        let pluginInvocationResults = try getPluginInvocationResults(for: graph)

        // Run any prebuild commands provided by plugins. Any failure stops the build.
        let prebuildCommandResults = try graph.reachableTargets.reduce(into: [:], { partial, target in
            partial[target] = try pluginInvocationResults[target].map { try runPrebuildCommands(for: $0) }
        })
        
        // Create the build plan based, on the graph and any information from plugins.
        let plan = try BuildPlan(
            buildParameters: buildParameters,
            graph: graph,
            pluginInvocationResults: pluginInvocationResults,
            prebuildCommandResults: prebuildCommandResults,
            diagnostics: diagnostics
        )
        self.buildPlan = plan
        
        // Finally create the llbuild manifest from the plan.
        return try BuildDescription.create(with: plan)
    }

    /// Build the package structure target.
    private func buildPackageStructure() throws {
        let buildSystem = try self.createBuildSystem(with: nil)
        self.buildSystem = buildSystem

        // Build the package structure target which will re-generate the llbuild manifest, if necessary.
        if !buildSystem.build(target: "PackageStructure") {
            throw Diagnostics.fatalError
        }
    }

    /// Create the build system using the given build description.
    ///
    /// The build description should only be omitted when creating the build system for
    /// building the package structure target.
    private func createBuildSystem(
        with buildDescription: BuildDescription?
    ) throws -> SPMLLBuild.BuildSystem {
        // Figure out which progress bar we have to use during the build.
        let isVerbose = verbosity != .concise
        let progressAnimation: ProgressAnimationProtocol = isVerbose
            ? MultiLineNinjaProgressAnimation(stream: self.stdoutStream)
            : NinjaProgressAnimation(stream: self.stdoutStream)

        let bctx = BuildExecutionContext(
            buildParameters,
            buildDescription: buildDescription,
            packageStructureDelegate: self,
            buildErrorAdviceProvider: self
        )

        // Create the build delegate.
        let buildSystemDelegate = BuildOperationBuildSystemDelegateHandler(
            buildSystem: self,
            bctx: bctx,
            diagnostics: diagnostics,
            outputStream: self.stdoutStream,
            progressAnimation: progressAnimation,
            delegate: self.delegate
        )
        self.buildSystemDelegate = buildSystemDelegate
        buildSystemDelegate.isVerbose = isVerbose

        let databasePath = buildParameters.dataPath.appending(component: "build.db").pathString
        let buildSystem = SPMLLBuild.BuildSystem(
            buildFile: buildParameters.llbuildManifest.pathString,
            databaseFile: databasePath,
            delegate: buildSystemDelegate,
            schedulerLanes: buildParameters.jobs
        )
        buildSystemDelegate.onCommmandFailure = {
            buildSystem.cancel()
            self.delegate?.buildSystemDidCancel(self)
        }

        return buildSystem
    }
    
    public func provideBuildErrorAdvice(for target: String, command: String, message: String) -> String? {
        // Find the target for which the error was emitted.  If we don't find it, we can't give any advice.
        guard let _ = self.buildPlan?.targets.first(where: { $0.target.name == target }) else { return nil }
        
        // Check for cases involving modules that cannot be found.
        if let importedModule = try? RegEx(pattern: "no such module '(.+)'").matchGroups(in: message).first?.first {
            // A target is importing a module that can't be found.  We take a look at the build plan and see if can offer any advice.
            
            // Look for a target with the same module name as the one that's being imported.
            if let importedTarget = self.buildPlan?.targets.first(where: { $0.target.c99name == importedModule }) {
                // For the moment we just check for executables that other targets try to import.
                if importedTarget.target.type == .executable {
                    return "module '\(importedModule)' is the main module of an executable, and cannot be imported by tests and other targets"
                }
                
                // Here we can add more checks in the future.
            }
        }
        return nil
    }

    public func packageStructureChanged() -> Bool {
        do {
            _ = try plan()
        }
        catch Diagnostics.fatalError {
            return false
        }
        catch {
            diagnostics.emit(error)
            return false
        }
        return true
    }
}

extension BuildDescription {
    static func create(with plan: BuildPlan) throws -> BuildDescription {
        // Generate the llbuild manifest.
        let llbuild = LLBuildManifestBuilder(plan)
        try llbuild.generateManifest(at: plan.buildParameters.llbuildManifest)

        let swiftCommands = llbuild.manifest.getCmdToolMap(kind: SwiftCompilerTool.self)
        let swiftFrontendCommands = llbuild.manifest.getCmdToolMap(kind: SwiftFrontendTool.self)
        let testDiscoveryCommands = llbuild.manifest.getCmdToolMap(kind: TestDiscoveryTool.self)
        let copyCommands = llbuild.manifest.getCmdToolMap(kind: CopyTool.self)

        // Create the build description.
        let buildDescription = try BuildDescription(
            plan: plan,
            swiftCommands: swiftCommands,
            swiftFrontendCommands: swiftFrontendCommands,
            testDiscoveryCommands: testDiscoveryCommands,
            copyCommands: copyCommands
        )
        try localFileSystem.createDirectory(
            plan.buildParameters.buildDescriptionPath.parentDirectory,
            recursive: true
        )
        try buildDescription.write(to: plan.buildParameters.buildDescriptionPath)
        return buildDescription
    }
}

extension BuildSubset {
    /// Returns the name of the llbuild target that corresponds to the build subset.
    func llbuildTargetName(for graph: PackageGraph, diagnostics: DiagnosticsEngine, config: String)
        -> String?
    {
        switch self {
        case .allExcludingTests:
            return LLBuildManifestBuilder.TargetKind.main.targetName
        case .allIncludingTests:
            return LLBuildManifestBuilder.TargetKind.test.targetName
        case .product(let productName):
            guard let product = graph.allProducts.first(where: { $0.name == productName }) else {
                diagnostics.emit(error: "no product named '\(productName)'")
                return nil
            }
            // If the product is automatic, we build the main target because automatic products
            // do not produce a binary right now.
            if product.type == .library(.automatic) {
                diagnostics.emit(
                    warning:
                        "'--product' cannot be used with the automatic product '\(productName)'; building the default target instead"
                )
                return LLBuildManifestBuilder.TargetKind.main.targetName
            }
            return diagnostics.wrap {
                try product.getLLBuildTargetName(config: config)
            }
        case .target(let targetName):
            guard let target = graph.allTargets.first(where: { $0.name == targetName }) else {
                diagnostics.emit(error: "no target named '\(targetName)'")
                return nil
            }
            return target.getLLBuildTargetName(config: config)
        }
    }
}
