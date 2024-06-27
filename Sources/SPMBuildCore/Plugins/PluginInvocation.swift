//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation
import PackageModel
import PackageLoading
import PackageGraph

import struct OrderedCollections.OrderedDictionary

import protocol TSCBasic.DiagnosticLocation

public enum PluginAction {
    case createBuildToolCommands(
        package: ResolvedPackage,
        target: ResolvedModule,
        pluginGeneratedSources: [AbsolutePath],
        pluginGeneratedResources: [AbsolutePath]
    )
    case performCommand(package: ResolvedPackage, arguments: [String])
}

public struct PluginTool {
    let path: AbsolutePath
    let triples: [String]?

    init(path: AbsolutePath, triples: [String]? = nil) {
        self.path = path
        self.triples = triples
    }
}

extension PluginModule {
    public func invoke(
        action: PluginAction,
        buildEnvironment: BuildEnvironment,
        scriptRunner: PluginScriptRunner,
        workingDirectory: AbsolutePath,
        outputDirectory: AbsolutePath,
        toolSearchDirectories: [AbsolutePath],
        accessibleTools: [String: PluginTool],
        writableDirectories: [AbsolutePath],
        readOnlyDirectories: [AbsolutePath],
        allowNetworkConnections: [SandboxNetworkPermission],
        pkgConfigDirectories: [AbsolutePath],
        sdkRootPath: AbsolutePath?,
        fileSystem: FileSystem,
        modulesGraph: ModulesGraph,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        delegate: PluginInvocationDelegate
    ) async throws -> Bool {
        try await safe_async {
            self.invoke(
                action: action,
                buildEnvironment: buildEnvironment,
                scriptRunner: scriptRunner,
                workingDirectory: workingDirectory,
                outputDirectory: outputDirectory,
                toolSearchDirectories: toolSearchDirectories,
                accessibleTools: accessibleTools,
                writableDirectories: writableDirectories,
                readOnlyDirectories: readOnlyDirectories,
                allowNetworkConnections: allowNetworkConnections,
                pkgConfigDirectories: pkgConfigDirectories,
                sdkRootPath: sdkRootPath,
                fileSystem: fileSystem,
                modulesGraph: modulesGraph,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue,
                delegate: delegate,
                completion: $0
            )
        }
    }
    /// Invokes the plugin by compiling its source code (if needed) and then running it as a subprocess. The specified
    /// plugin action determines which entry point is called in the subprocess, and the package and the tool mapping
    /// determine the context that is available to the plugin.
    ///
    /// The working directory should be a path in the file system into which the plugin is allowed to write information
    /// that persists between all invocations of a plugin for the same purpose. The exact meaning of "same" means here
    /// depends on the particular plugin; for a build tool plugin, it might be the combination of the plugin and target
    /// for which it is being invoked.
    ///
    /// Note that errors thrown by this function relate to problems actually invoking the plugin. Any diagnostics that
    /// are emitted by the plugin are contained in the returned result structure.
    ///
    /// - Parameters:
    ///   - action: The plugin action (i.e. entry point) to invoke, possibly containing parameters.
    ///   - package: The root of the package graph to pass down to the plugin.
    ///   - scriptRunner: Entity responsible for actually running the code of the plugin.
    ///   - workingDirectory: The initial working directory of the invoked plugin.
    ///   - outputDirectory: A directory under which the plugin can write anything it wants to.
    ///   - toolNamesToPaths: A mapping from name of tools available to the plugin to the corresponding absolute paths.
    ///   - pkgConfigDirectory: A directory for searching `pkg-config` `.pc` files in it.
    ///   - fileSystem: The file system to which all of the paths refers.
    ///
    /// - Returns: A PluginInvocationResult that contains the results of invoking the plugin.
    @available(*, noasync, message: "Use the async alternative")
    public func invoke(
        action: PluginAction,
        buildEnvironment: BuildEnvironment,
        scriptRunner: PluginScriptRunner,
        workingDirectory: AbsolutePath,
        outputDirectory: AbsolutePath,
        toolSearchDirectories: [AbsolutePath],
        accessibleTools: [String: PluginTool],
        writableDirectories: [AbsolutePath],
        readOnlyDirectories: [AbsolutePath],
        allowNetworkConnections: [SandboxNetworkPermission],
        pkgConfigDirectories: [AbsolutePath],
        sdkRootPath: AbsolutePath?,
        fileSystem: FileSystem,
        modulesGraph: ModulesGraph,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        delegate: PluginInvocationDelegate,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        // Create the plugin's output directory if needed (but don't do anything with it if it already exists).
        do {
            try fileSystem.createDirectory(outputDirectory, recursive: true)
        }
        catch {
            return callbackQueue.async { completion(.failure(PluginEvaluationError.couldNotCreateOuputDirectory(path: outputDirectory, underlyingError: error))) }
        }

        // Serialize the plugin action to send as the initial message.
        let initialMessage: Data
        do {
            var serializer = PluginContextSerializer(
                fileSystem: fileSystem,
                modulesGraph: modulesGraph,
                buildEnvironment: buildEnvironment,
                pkgConfigDirectories: pkgConfigDirectories,
                sdkRootPath: sdkRootPath
            )
            let pluginWorkDirId = try serializer.serialize(path: outputDirectory)
            let toolSearchDirIds = try toolSearchDirectories.map{ try serializer.serialize(path: $0) }
            let accessibleTools = try accessibleTools.mapValues { (tool) -> HostToPluginMessage.InputContext.Tool in
                let path = try serializer.serialize(path: tool.path)
                return .init(path: path, triples: tool.triples)
            }
            let actionMessage: HostToPluginMessage
            switch action {
                
            case .createBuildToolCommands(let package, let target, let pluginGeneratedSources, let pluginGeneratedResources):
                let rootPackageId = try serializer.serialize(package: package)
                guard let targetId = try serializer.serialize(target: target) else {
                    throw StringError("unexpectedly was unable to serialize target \(target)")
                }
                let generatedSources = try pluginGeneratedSources.map { try serializer.serialize(path: $0) }
                let generatedResources = try pluginGeneratedResources.map { try serializer.serialize(path: $0) }
                let wireInput = WireInput(
                    paths: serializer.paths,
                    targets: serializer.targets,
                    products: serializer.products,
                    packages: serializer.packages,
                    pluginWorkDirId: pluginWorkDirId,
                    toolSearchDirIds: toolSearchDirIds,
                    accessibleTools: accessibleTools)
                actionMessage = .createBuildToolCommands(
                    context: wireInput,
                    rootPackageId: rootPackageId,
                    targetId: targetId,
                    pluginGeneratedSources: generatedSources,
                    pluginGeneratedResources: generatedResources
                )
            case .performCommand(let package, let arguments):
                let rootPackageId = try serializer.serialize(package: package)
                let wireInput = WireInput(
                    paths: serializer.paths,
                    targets: serializer.targets,
                    products: serializer.products,
                    packages: serializer.packages,
                    pluginWorkDirId: pluginWorkDirId,
                    toolSearchDirIds: toolSearchDirIds,
                    accessibleTools: accessibleTools)
                actionMessage = .performCommand(
                    context: wireInput,
                    rootPackageId: rootPackageId,
                    arguments: arguments)
            }
            initialMessage = try actionMessage.toData()
        }
        catch {
            return callbackQueue.async { completion(.failure(PluginEvaluationError.couldNotSerializePluginInput(underlyingError: error))) }
        }
        
        // Handle messages and output from the plugin.
        class ScriptRunnerDelegate: PluginScriptCompilerDelegate, PluginScriptRunnerDelegate {
            /// Delegate that should be told about events involving the plugin.
            let invocationDelegate: PluginInvocationDelegate
            
            /// Observability scope for the invoking of the plugin. Diagnostics from the plugin itself are sent through the delegate.
            let observabilityScope: ObservabilityScope
            
            /// Whether at least one error has been reported; this is used to make sure there is at least one error if the plugin fails.
            var hasReportedError = false

            /// If this is true, we exited early with an error.
            var exitEarly = false
            
            init(invocationDelegate: PluginInvocationDelegate, observabilityScope: ObservabilityScope) {
                self.invocationDelegate = invocationDelegate
                self.observabilityScope = observabilityScope
            }
            
            func willCompilePlugin(commandLine: [String], environment: [String: String]) {
                invocationDelegate.pluginCompilationStarted(commandLine: commandLine, environment: environment)
            }
            
            func didCompilePlugin(result: PluginCompilationResult) {
                invocationDelegate.pluginCompilationEnded(result: result)
            }
            
            func skippedCompilingPlugin(cachedResult: PluginCompilationResult) {
                invocationDelegate.pluginCompilationWasSkipped(cachedResult: cachedResult)
            }
            
            /// Invoked when the plugin emits arbitrary data on its stdout/stderr. There is no guarantee that the data is split on UTF-8 character encoding boundaries etc.  The script runner delegate just passes it on to the invocation delegate.
            func handleOutput(data: Data) {
                invocationDelegate.pluginEmittedOutput(data)
            }

            /// Invoked when the plugin emits a message. The `responder` closure can be used to send any reply messages.
            func handleMessage(data: Data, responder: @escaping (Data) -> Void) throws {
                let message = try PluginToHostMessage(data)
                switch message {
                    
                case .emitDiagnostic(let severity, let message, let file, let line):
                    let metadata: ObservabilityMetadata? = file.map {
                        var metadata = ObservabilityMetadata()
                        // FIXME: We should probably report some kind of protocol error if the path isn't valid.
                        metadata.fileLocation = try? .init(.init(validating: $0), line: line)
                        return metadata
                    }
                    let diagnostic: Basics.Diagnostic
                    switch severity {
                    case .error:
                        diagnostic = .error(message, metadata: metadata)
                        hasReportedError = true
                    case .warning:
                        diagnostic = .warning(message, metadata: metadata)
                    case .remark:
                        diagnostic = .info(message, metadata: metadata)
                    }
                    self.invocationDelegate.pluginEmittedDiagnostic(diagnostic)

                case .emitProgress(let message):
                    self.invocationDelegate.pluginEmittedProgress(message)

                case .defineBuildCommand(let config, let inputFiles, let outputFiles):
                    if config.version != 2 {
                        throw PluginEvaluationError.pluginUsesIncompatibleVersion(expected: 2, actual: config.version)
                    }
                    self.invocationDelegate.pluginDefinedBuildCommand(
                        displayName: config.displayName,
                        executable: try AbsolutePath(validating: config.executable.path),
                        arguments: config.arguments,
                        environment: config.environment,
                        workingDirectory: try config.workingDirectory.map{ try AbsolutePath(validating: $0.path) },
                        inputFiles: try inputFiles.map{ try AbsolutePath(validating: $0.path) },
                        outputFiles: try outputFiles.map{ try AbsolutePath(validating: $0.path) })

                case .definePrebuildCommand(let config, let outputFilesDir):
                    if config.version != 2 {
                        throw PluginEvaluationError.pluginUsesIncompatibleVersion(expected: 2, actual: config.version)
                    }
                    let success = self.invocationDelegate.pluginDefinedPrebuildCommand(
                        displayName: config.displayName,
                        executable: try AbsolutePath(validating: config.executable.path),
                        arguments: config.arguments,
                        environment: config.environment,
                        workingDirectory: try config.workingDirectory.map{ try AbsolutePath(validating: $0.path) },
                        outputFilesDirectory: try AbsolutePath(validating: outputFilesDir.path))

                    if !success {
                        exitEarly = true
                        hasReportedError = true
                    }

                case .buildOperationRequest(let subset, let parameters):
                    self.invocationDelegate.pluginRequestedBuildOperation(subset: .init(subset), parameters: .init(parameters)) {
                        do {
                            switch $0 {
                            case .success(let result):
                                responder(try HostToPluginMessage.buildOperationResponse(result: .init(result)).toData())
                            case .failure(let error):
                                responder(try HostToPluginMessage.errorResponse(error: String(describing: error)).toData())
                            }
                        }
                        catch {
                            self.observabilityScope.emit(debug: "couldn't send reply to plugin", underlyingError: error)
                        }
                    }

                case .testOperationRequest(let subset, let parameters):
                    self.invocationDelegate.pluginRequestedTestOperation(subset: .init(subset), parameters: .init(parameters)) {
                        do {
                            switch $0 {
                            case .success(let result):
                                responder(try HostToPluginMessage.testOperationResponse(result: .init(result)).toData())
                            case .failure(let error):
                                responder(try HostToPluginMessage.errorResponse(error: String(describing: error)).toData())
                            }
                        }
                        catch {
                            self.observabilityScope.emit(debug: "couldn't send reply to plugin", underlyingError: error)
                        }
                    }

                case .symbolGraphRequest(let targetName, let options):
                    // The plugin requested symbol graph information for a target. We ask the delegate and then send a response.
                    self.invocationDelegate.pluginRequestedSymbolGraph(forTarget: .init(targetName), options: .init(options)) {
                        do {
                            switch $0 {
                            case .success(let result):
                                responder(try HostToPluginMessage.symbolGraphResponse(result: .init(result)).toData())
                            case .failure(let error):
                                responder(try HostToPluginMessage.errorResponse(error: String(describing: error)).toData())
                            }
                        }
                        catch {
                            self.observabilityScope.emit(debug: "couldn't send reply to plugin", underlyingError: error)
                        }
                    }
                }
            }
        }
        let runnerDelegate = ScriptRunnerDelegate(invocationDelegate: delegate, observabilityScope: observabilityScope)
        
        // Call the plugin script runner to actually invoke the plugin.
        scriptRunner.runPluginScript(
            sourceFiles: sources.paths,
            pluginName: self.name,
            initialMessage: initialMessage,
            toolsVersion: self.apiVersion,
            workingDirectory: workingDirectory,
            writableDirectories: writableDirectories,
            readOnlyDirectories: readOnlyDirectories,
            allowNetworkConnections: allowNetworkConnections,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope,
            callbackQueue: callbackQueue,
            delegate: runnerDelegate) { result in
                dispatchPrecondition(condition: .onQueue(callbackQueue))
                completion(result.map { exitCode in
                    // Return a result based on the exit code or the `exitEarly` parameter. If the plugin
                    // exits with an error but hasn't already emitted an error, we do so for it.
                    let exitedCleanly = (exitCode == 0) && !runnerDelegate.exitEarly
                    if !exitedCleanly && !runnerDelegate.hasReportedError {
                        delegate.pluginEmittedDiagnostic(
                            .error("Plugin ended with exit code \(exitCode)")
                        )
                    }
                    return exitedCleanly
                })
        }
    }
}

fileprivate extension HostToPluginMessage {
    func toData() throws -> Data {
        return try JSONEncoder.makeWithDefaults().encode(self)
    }
}

fileprivate extension PluginToHostMessage {
    init(_ data: Data) throws {
        self = try JSONDecoder.makeWithDefaults().decode(Self.self, from: data)
    }
}

extension ModulesGraph {
    public func pluginsPerModule(
        satisfying buildEnvironment: BuildEnvironment
    ) -> [ResolvedModule.ID: [ResolvedModule]] {
        var pluginsPerModule = [ResolvedModule.ID: [ResolvedModule]]()
        for module in self.allModules.sorted(by: { $0.name < $1.name }) {
            let pluginDependencies = module.pluginDependencies(
                satisfying: buildEnvironment
            )
            if !pluginDependencies.isEmpty {
                pluginsPerModule[module.id] = pluginDependencies
            }
        }
        return pluginsPerModule
    }

    /// Traverses the given set of targets with their plugin dependencies and applies plugins as needed. Each
    /// plugin is passed an input context that provides information about the target to which it is being applied
    /// (along with some information about that target's dependency closure). The plugin is expected to generate an
    /// output in the form of commands that will later be run before or during the build, and can also emit debug
    /// output and diagnostics.
    ///
    /// This function returns a dictionary that maps each resolved target that specifies at least one plugin to the
    /// results of invoking those plugins in order. Each result includes an ordered list of commands to run before
    /// the build of the target, and another list of the commands to incorporate into the build graph so they run
    /// at the appropriate times during the build.
    ///
    /// This function may cache anything it wants to under the `cacheDir` directory. The `builtToolsDir` directory
    /// is where executables for any dependencies of targets will be made available. Any warnings and errors related
    /// to running the plugin will be emitted to `diagnostics`, and this function will throw an error if evaluation
    /// of any plugin fails.
    ///
    /// Note that warnings emitted by the the plugin itself will be returned in the PluginEvaluationResult structures
    /// for later showing to the user, and not added directly to the diagnostics engine.
    ///
    // TODO: Convert this function to be asynchronous, taking a completion closure. This may require changes to the package graph APIs to make them accessible concurrently.
    public func invokeBuildToolPlugins(
        pluginsPerTarget: [ResolvedModule.ID: [ResolvedModule]],
        pluginTools: [ResolvedModule.ID: [String: PluginTool]],
        outputDir: AbsolutePath,
        buildParameters: BuildParameters,
        additionalFileRules: [FileRuleDescription],
        toolSearchDirectories: [AbsolutePath],
        pkgConfigDirectories: [AbsolutePath],
        pluginScriptRunner: PluginScriptRunner,
        observabilityScope: ObservabilityScope,
        fileSystem: FileSystem
    ) throws -> [ResolvedModule.ID: (target: ResolvedModule, results: [BuildToolPluginInvocationResult])] {
        var pluginResultsByTarget: [ResolvedModule.ID: (target: ResolvedModule, results: [BuildToolPluginInvocationResult])] = [:]
        for (moduleID, plugins) in pluginsPerTarget {
            guard let module = self.allModules[moduleID] else {
                throw InternalError("could not find target for \(moduleID)")
            }

            /// Determine the package that contains the target.
            guard let package = self.package(for: module) else {
                throw InternalError("could not determine package for target \(module)")
            }

            // Apply each build tool plugin used by the target in order, creating a list of results (one for each plugin usage).
            var buildToolPluginResults: [BuildToolPluginInvocationResult] = []
            for plugin  in plugins {
                let pluginTarget = plugin.underlying as! PluginModule
                // Determine the tools to which this plugin has access, and create a name-to-path mapping from tool
                // names to the corresponding paths. Built tools are assumed to be in the build tools directory.
                guard let accessibleTools = pluginTools[plugin.id] else {
                    throw InternalError("No tools found for plugin \(pluginTarget.name)")
                }
                
                // Determine additional input dependencies for any plugin commands, based on any executables the plugin target depends on.
                let toolPaths = accessibleTools.values.map { $0.path }.sorted()

                // Assign a plugin working directory based on the package, target, and plugin.
                let pluginOutputDir = outputDir.appending(components: package.identity.description, module.name, module.buildTriple.rawValue, pluginTarget.name)

                // Determine the set of directories under which plugins are allowed to write. We always include just the output directory, and for now there is no possibility of opting into others.
                let writableDirectories = [outputDir]

                // Determine a set of further directories under which plugins are never allowed to write, even if they are covered by other rules (such as being able to write to the temporary directory).
                let readOnlyDirectories = [package.path]

                // Set up a delegate to handle callbacks from the build tool plugin. We'll capture free-form text output as well as defined commands and diagnostics.
                let delegateQueue = DispatchQueue(label: "plugin-invocation")
                class PluginDelegate: PluginInvocationDelegate {
                    let fileSystem: FileSystem
                    let delegateQueue: DispatchQueue
                    let toolPaths: [AbsolutePath]
                    let builtToolNames: [String]
                    var outputData = Data()
                    var diagnostics = [Basics.Diagnostic]()
                    var buildCommands = [BuildToolPluginInvocationResult.BuildCommand]()
                    var prebuildCommands = [BuildToolPluginInvocationResult.PrebuildCommand]()
                    
                    init(fileSystem: FileSystem, delegateQueue: DispatchQueue, toolPaths: [AbsolutePath], builtToolNames: [String]) {
                        self.fileSystem = fileSystem
                        self.delegateQueue = delegateQueue
                        self.toolPaths = toolPaths
                        self.builtToolNames = builtToolNames
                    }
                    
                    func pluginCompilationStarted(commandLine: [String], environment: [String: String]) {
                    }
                    
                    func pluginCompilationEnded(result: PluginCompilationResult) {
                    }
                    
                    func pluginCompilationWasSkipped(cachedResult: PluginCompilationResult) {
                    }

                    func pluginEmittedOutput(_ data: Data) {
                        dispatchPrecondition(condition: .onQueue(delegateQueue))
                        outputData.append(contentsOf: data)
                    }

                    func pluginEmittedProgress(_ message: String) {}

                    func pluginEmittedDiagnostic(_ diagnostic: Basics.Diagnostic) {
                        dispatchPrecondition(condition: .onQueue(delegateQueue))
                        diagnostics.append(diagnostic)
                    }

                    func pluginDefinedBuildCommand(displayName: String?, executable: AbsolutePath, arguments: [String], environment: [String: String], workingDirectory: AbsolutePath?, inputFiles: [AbsolutePath], outputFiles: [AbsolutePath]) {
                        dispatchPrecondition(condition: .onQueue(delegateQueue))
                        buildCommands.append(.init(
                            configuration: .init(
                                displayName: displayName,
                                executable: executable,
                                arguments: arguments,
                                environment: .init(environment),
                                workingDirectory: workingDirectory),
                            inputFiles: toolPaths + inputFiles,
                            outputFiles: outputFiles))
                    }
                    
                    func pluginDefinedPrebuildCommand(displayName: String?, executable: AbsolutePath, arguments: [String], environment: [String: String], workingDirectory: AbsolutePath?, outputFilesDirectory: AbsolutePath) -> Bool {
                        dispatchPrecondition(condition: .onQueue(delegateQueue))
                        // executable must exist before running prebuild command
                        if builtToolNames.contains(executable.basename) {
                            diagnostics.append(.error("a prebuild command cannot use executables built from source, including executable target '\(executable.basename)'"))
                            return false
                        }
                        prebuildCommands.append(.init(
                            configuration: .init(
                                displayName: displayName,
                                executable: executable,
                                arguments: arguments,
                                environment: .init(environment),
                                workingDirectory: workingDirectory),
                            outputFilesDirectory: outputFilesDirectory))
                        return true
                    }
                }
                let delegate = PluginDelegate(
                    fileSystem: fileSystem,
                    delegateQueue: delegateQueue,
                    toolPaths: toolPaths,
                    builtToolNames: accessibleTools.map { $0.key }
                )

                // In tools version 6.0 and newer, we vend the list of files generated by previous plugins.
                let pluginDerivedSources: Sources
                let pluginDerivedResources: [Resource]
                if package.manifest.toolsVersion >= .v6_0 {
                    // Set up dummy observability because we don't want to emit diagnostics for this before the actual build.
                    let observability = ObservabilitySystem({ _, _ in })
                    // Compute the generated files based on all results we have computed so far.
                    (pluginDerivedSources, pluginDerivedResources) = Self.computePluginGeneratedFiles(
                        target: module,
                        toolsVersion: package.manifest.toolsVersion,
                        additionalFileRules: additionalFileRules,
                        buildParameters: buildParameters,
                        buildToolPluginInvocationResults: buildToolPluginResults,
                        prebuildCommandResults: [],
                        observabilityScope: observability.topScope
                    )
                } else {
                    pluginDerivedSources = .init(paths: [], root: package.path)
                    pluginDerivedResources = []
                }

                // Invoke the build tool plugin with the input parameters and the delegate that will collect outputs.
                let startTime = DispatchTime.now()
                let success = try temp_await { pluginTarget.invoke(
                    action: .createBuildToolCommands(
                        package: package,
                        target: module,
                        pluginGeneratedSources: pluginDerivedSources.paths,
                        pluginGeneratedResources: pluginDerivedResources.map { $0.path }
                    ),
                    buildEnvironment: buildParameters.buildEnvironment,
                    scriptRunner: pluginScriptRunner,
                    workingDirectory: package.path,
                    outputDirectory: pluginOutputDir,
                    toolSearchDirectories: toolSearchDirectories,
                    accessibleTools: accessibleTools,
                    writableDirectories: writableDirectories,
                    readOnlyDirectories: readOnlyDirectories,
                    allowNetworkConnections: [],
                    pkgConfigDirectories: pkgConfigDirectories,
                    sdkRootPath: buildParameters.toolchain.sdkRootPath,
                    fileSystem: fileSystem,
                    modulesGraph: self,
                    observabilityScope: observabilityScope,
                    callbackQueue: delegateQueue,
                    delegate: delegate,
                    completion: $0) }
                let duration = startTime.distance(to: .now())

                // Add a BuildToolPluginInvocationResult to the mapping.
                buildToolPluginResults.append(.init(
                    plugin: pluginTarget,
                    pluginOutputDirectory: pluginOutputDir,
                    package: package,
                    target: module,
                    succeeded: success,
                    duration: duration,
                    diagnostics: delegate.diagnostics,
                    textOutput: String(decoding: delegate.outputData, as: UTF8.self),
                    buildCommands: delegate.buildCommands,
                    prebuildCommands: delegate.prebuildCommands))
            }

            // Associate the list of results with the target. The list will have one entry for each plugin used by the target.
            pluginResultsByTarget[module.id] = (module, buildToolPluginResults)
        }
        return pluginResultsByTarget
    }

    public static func computePluginGeneratedFiles(
        target: ResolvedModule,
        toolsVersion: ToolsVersion,
        additionalFileRules: [FileRuleDescription],
        buildParameters: BuildParameters,
        buildToolPluginInvocationResults: [BuildToolPluginInvocationResult],
        prebuildCommandResults: [PrebuildCommandResult],
        observabilityScope: ObservabilityScope
    ) -> (pluginDerivedSources: Sources, pluginDerivedResources: [Resource]) {
        var pluginDerivedSources = Sources(paths: [], root: buildParameters.dataPath)

        // Add any derived files that were declared for any commands from plugin invocations.
        var pluginDerivedFiles = [AbsolutePath]()
        for command in buildToolPluginInvocationResults.reduce([], { $0 + $1.buildCommands }) {
            for absPath in command.outputFiles {
                pluginDerivedFiles.append(absPath)
            }
        }

        // Add any derived files that were discovered from output directories of prebuild commands.
        for result in prebuildCommandResults {
            for path in result.derivedFiles {
                pluginDerivedFiles.append(path)
            }
        }

        // Let `TargetSourcesBuilder` compute the treatment of plugin generated files.
        let (derivedSources, derivedResources) = TargetSourcesBuilder.computeContents(
            for: pluginDerivedFiles,
            toolsVersion: toolsVersion,
            additionalFileRules: additionalFileRules,
            defaultLocalization: target.defaultLocalization,
            targetName: target.name,
            targetPath: target.underlying.path,
            observabilityScope: observabilityScope
        )
        let pluginDerivedResources = derivedResources
        derivedSources.forEach { absPath in
            let relPath = absPath.relative(to: pluginDerivedSources.root)
            pluginDerivedSources.relativePaths.append(relPath)
        }

        return (pluginDerivedSources, pluginDerivedResources)
    }
}


/// A description of a tool to which a plugin has access.
public enum PluginAccessibleTool: Hashable {
    /// A tool that is built by an ExecutableTarget (the path is relative to the built-products directory).
    case builtTool(name: String, path: RelativePath)

    /// A tool that is vended by a BinaryTarget (the path is absolute and refers to an unpackaged binary target).
    case vendedTool(name: String, path: AbsolutePath, supportedTriples: [String])
}

/// The set of tools that are accessible to this plugin.
fileprivate func collectAccessibleTools(
    plugin: ResolvedModule,
    fileSystem: FileSystem,
    environment: BuildEnvironment,
    for hostTriple: Triple
) throws -> Set<PluginAccessibleTool> {
    precondition(plugin.underlying is PluginModule)
    return try Set(plugin.dependencies(satisfying: environment).flatMap { dependency -> [PluginAccessibleTool] in
        let builtToolName: String
        let executableOrBinaryModule: Module
        switch dependency {
        case .module(let module, _):
            builtToolName = module.name
            executableOrBinaryModule = module.underlying
        case .product(let product, _):
            guard let executableModule = product.modules.map({ $0.underlying }).executables.spm_only
            else {
                throw StringError("no product named \(product.name)")
            }
            builtToolName = product.name
            executableOrBinaryModule = executableModule
        }

        // For a binary target we create a `vendedTool`.
        if let module = executableOrBinaryModule as? BinaryModule {
            // TODO: Memoize this result for the host triple
            let execInfos = try module.parseArtifactArchives(for: hostTriple, fileSystem: fileSystem)
            return try execInfos.map{ .vendedTool(name: $0.name, path: $0.executablePath, supportedTriples: try $0.supportedTriples.map{ try $0.withoutVersion().tripleString }) }
        }
        // For an executable target we create a `builtTool`.
        else if executableOrBinaryModule.type == .executable {
            return try [.builtTool(name: builtToolName, path: RelativePath(validating: executableOrBinaryModule.name))]
        }
        else {
            return []
        }
    })
}

public extension ResolvedModule {
    func preparePluginTools(
        fileSystem: FileSystem,
        environment: BuildEnvironment,
        for hostTriple: Triple,
        builtToolHandler: (_ name: String, _ path: RelativePath) throws -> AbsolutePath?
    ) throws -> [String: PluginTool] {
        precondition(self.underlying is PluginModule)

        var tools: [String: PluginTool] = [:]

        for tool in try collectAccessibleTools(
            plugin: self,
            fileSystem: fileSystem,
            environment: environment,
            for: hostTriple
        ) {
            switch tool {
            case .builtTool(let name, let path):
                if let path = try builtToolHandler(name, path) {
                    tools[name] = PluginTool(path: path)
                }
            case .vendedTool(let name, let path, let triples):
                // Avoid having the path of an unsupported tool overwrite a supported one.
                guard !triples.isEmpty || tools[name] == nil else {
                    continue
                }
                let priorTriples = tools[name]?.triples ?? []
                tools[name] = PluginTool(path: path, triples: priorTriples + triples)
            }
        }

        return tools
    }
}

/// Represents the result of invoking a build tool plugin for a particular target. The result includes generated build commands and prebuild commands as well as any diagnostics and stdout/stderr output emitted by the plugin.
public struct BuildToolPluginInvocationResult {
    /// The plugin that produced the results.
    public var plugin: PluginModule

    /// The directory given to the plugin as a place in which it and the commands are allowed to write.
    public var pluginOutputDirectory: AbsolutePath

    /// The package to which the plugin was applied.
    public var package: ResolvedPackage

    /// The target in that package to which the plugin was applied.
    public var target: ResolvedModule

    /// If the plugin finished successfully.
    public var succeeded: Bool

    /// Duration of the plugin invocation.
    public var duration: DispatchTimeInterval

    /// Any diagnostics emitted by the plugin.
    public var diagnostics: [Basics.Diagnostic]

    /// Any textual output emitted by the plugin.
    public var textOutput: String

    /// The build commands generated by the plugin (in the order in which they should run).
    public var buildCommands: [BuildCommand]

    /// The prebuild commands generated by the plugin (in the order in which they should run).
    public var prebuildCommands: [PrebuildCommand]

    /// A command to incorporate into the build graph so that it runs during the build whenever it needs to.
    public struct BuildCommand {
        public var configuration: CommandConfiguration
        public var inputFiles: [AbsolutePath]
        public var outputFiles: [AbsolutePath]
    }

    /// A command to run before the start of every build.
    public struct PrebuildCommand {
        // TODO: In the future these should be folded into regular build commands when the build system can handle not knowing the names of all the outputs before the command runs.
        public var configuration: CommandConfiguration
        public var outputFilesDirectory: AbsolutePath
    }

    /// Launch configuration of a command that can be run (including a display name to show in logs etc).
    public struct CommandConfiguration {
        public var displayName: String?
        public var executable: AbsolutePath
        public var arguments: [String]
        public var environment: Environment
        public var workingDirectory: AbsolutePath?
    }

    /// A location representing a file name or path and an optional line number.
    // FIXME: This should be part of the Diagnostics APIs.
    struct FileLineLocation: DiagnosticLocation {
        var file: String
        var line: Int?
        var description: String {
            "\(file)\(line.map{":\($0)"} ?? "")"
        }
    }
}


/// An error in plugin evaluation.
public enum PluginEvaluationError: Swift.Error {
    case couldNotCreateOuputDirectory(path: AbsolutePath, underlyingError: Error)
    case couldNotSerializePluginInput(underlyingError: Error)
    case runningPluginFailed(underlyingError: Error)
    case decodingPluginOutputFailed(json: Data, underlyingError: Error)
    case pluginUsesIncompatibleVersion(expected: Int, actual: Int)
}

public protocol PluginInvocationDelegate {
    /// Called before a plugin is compiled. This call is always followed by a `pluginCompilationEnded()`, but is mutually exclusive with `pluginCompilationWasSkipped()` (which is called if the plugin didn't need to be recompiled).
    func pluginCompilationStarted(commandLine: [String], environment: [String: String])

    /// Called after a plugin is compiled. This call always follows a `pluginCompilationStarted()`, but is mutually exclusive with `pluginCompilationWasSkipped()` (which is called if the plugin didn't need to be recompiled).
    func pluginCompilationEnded(result: PluginCompilationResult)
    
    /// Called if a plugin didn't need to be recompiled. This call is always mutually exclusive with `pluginCompilationStarted()` and `pluginCompilationEnded()`.
    func pluginCompilationWasSkipped(cachedResult: PluginCompilationResult)
    
    /// Called for each piece of textual output data emitted by the plugin. Note that there is no guarantee that the data begins and ends on a UTF-8 byte sequence boundary (much less on a line boundary) so the delegate should buffer partial data as appropriate.
    func pluginEmittedOutput(_: Data)
    
    /// Called when a plugin emits a diagnostic through the PackagePlugin APIs.
    func pluginEmittedDiagnostic(_: Basics.Diagnostic)

    /// Called when a plugin emits a progress message through the PackagePlugin APIs.
    func pluginEmittedProgress(_: String)

    /// Called when a plugin defines a build command through the PackagePlugin APIs.
    func pluginDefinedBuildCommand(displayName: String?, executable: AbsolutePath, arguments: [String], environment: [String: String], workingDirectory: AbsolutePath?, inputFiles: [AbsolutePath], outputFiles: [AbsolutePath])

    /// Called when a plugin defines a prebuild command through the PackagePlugin APIs.
    func pluginDefinedPrebuildCommand(displayName: String?, executable: AbsolutePath, arguments: [String], environment: [String: String], workingDirectory: AbsolutePath?, outputFilesDirectory: AbsolutePath) -> Bool

    /// Called when a plugin requests a build operation through the PackagePlugin APIs.
    func pluginRequestedBuildOperation(subset: PluginInvocationBuildSubset, parameters: PluginInvocationBuildParameters, completion: @escaping (Result<PluginInvocationBuildResult, Error>) -> Void)

    /// Called when a plugin requests a test operation through the PackagePlugin APIs.
    func pluginRequestedTestOperation(subset: PluginInvocationTestSubset, parameters: PluginInvocationTestParameters, completion: @escaping (Result<PluginInvocationTestResult, Error>) -> Void)

    /// Called when a plugin requests that the host computes and returns symbol graph information for a particular target.
    func pluginRequestedSymbolGraph(forTarget name: String, options: PluginInvocationSymbolGraphOptions, completion: @escaping (Result<PluginInvocationSymbolGraphResult, Error>) -> Void)
}

public struct PluginInvocationSymbolGraphOptions {
    public var minimumAccessLevel: AccessLevel
    public enum AccessLevel: String {
        case `private`, `fileprivate`, `internal`, `public`, `open`
    }
    public var includeSynthesized: Bool
    public var includeSPI: Bool
    public var emitExtensionBlocks: Bool
}

public struct PluginInvocationSymbolGraphResult {
    public var directoryPath: String
    public init(directoryPath: String) {
        self.directoryPath = directoryPath
    }
}

public enum PluginInvocationBuildSubset {
    case all(includingTests: Bool)
    case product(String)
    case target(String)
}

public struct PluginInvocationBuildParameters {
    public var configuration: Configuration
    public enum Configuration: String {
        case debug, release, inherit
    }
    public var logging: LogVerbosity
    public enum LogVerbosity: String {
        case concise, verbose, debug
    }
    public var echoLogs: Bool
    public var otherCFlags: [String]
    public var otherCxxFlags: [String]
    public var otherSwiftcFlags: [String]
    public var otherLinkerFlags: [String]
}

public struct PluginInvocationBuildResult {
    public var succeeded: Bool
    public var logText: String
    public var builtArtifacts: [BuiltArtifact]
    public struct BuiltArtifact {
        public var path: String
        public var kind: Kind
        public enum Kind: String {
            case executable, dynamicLibrary, staticLibrary
        }
        public init(path: String, kind: Kind) {
            self.path = path
            self.kind = kind
        }
    }
    public init(succeeded: Bool, logText: String, builtArtifacts: [BuiltArtifact]) {
        self.succeeded = succeeded
        self.logText = logText
        self.builtArtifacts = builtArtifacts
    }
}

public enum PluginInvocationTestSubset {
    case all
    case filtered([String])
}

public struct PluginInvocationTestParameters {
    public var enableCodeCoverage: Bool
}

public struct PluginInvocationTestResult {
    public var succeeded: Bool
    public var testTargets: [TestTarget]
    public var codeCoverageDataFile: String?

    public struct TestTarget {
        public var name: String
        public var testCases: [TestCase]
        public struct TestCase {
            public var name: String
            public var tests: [Test]
            public struct Test {
                public var name: String
                public var result: Result
                public var duration: Double
                public enum Result: String {
                    case succeeded, skipped, failed
                }
                public init(name: String, result: Result, duration: Double) {
                    self.name = name
                    self.result = result
                    self.duration = duration
                }
            }
            public init(name: String, tests: [Test]) {
                self.name = name
                self.tests = tests
            }
        }
        public init(name: String, testCases: [TestCase]) {
            self.name = name
            self.testCases = testCases
        }
    }
    public init(succeeded: Bool, testTargets: [TestTarget], codeCoverageDataFile: String?) {
        self.succeeded = succeeded
        self.testTargets = testTargets
        self.codeCoverageDataFile = codeCoverageDataFile
    }
}

public extension PluginInvocationDelegate {
    func pluginDefinedBuildCommand(displayName: String?, executable: AbsolutePath, arguments: [String], environment: [String: String], workingDirectory: AbsolutePath?, inputFiles: [AbsolutePath], outputFiles: [AbsolutePath]) {
    }
    func pluginDefinedPrebuildCommand(displayName: String?, executable: AbsolutePath, arguments: [String], environment: [String: String], workingDirectory: AbsolutePath?, outputFilesDirectory: AbsolutePath) -> Bool {
        return true
    }
    func pluginRequestedBuildOperation(subset: PluginInvocationBuildSubset, parameters: PluginInvocationBuildParameters, completion: @escaping (Result<PluginInvocationBuildResult, Error>) -> Void) {
        DispatchQueue.sharedConcurrent.async { completion(Result.failure(StringError("unimplemented"))) }
    }
    func pluginRequestedTestOperation(subset: PluginInvocationTestSubset, parameters: PluginInvocationTestParameters, completion: @escaping (Result<PluginInvocationTestResult, Error>) -> Void) {
        DispatchQueue.sharedConcurrent.async { completion(Result.failure(StringError("unimplemented"))) }
    }
    func pluginRequestedSymbolGraph(forTarget name: String, options: PluginInvocationSymbolGraphOptions, completion: @escaping (Result<PluginInvocationSymbolGraphResult, Error>) -> Void) {
        DispatchQueue.sharedConcurrent.async { completion(Result.failure(StringError("unimplemented"))) }
    }
}

fileprivate extension PluginInvocationBuildSubset {
    init(_ subset: PluginToHostMessage.BuildSubset) {
        switch subset {
        case .all(let includingTests):
            self = .all(includingTests: includingTests)
        case .product(let name):
            self = .product(name)
        case .target(let name):
            self = .target(name)
        }
    }
}

fileprivate extension PluginInvocationBuildParameters {
    init(_ parameters: PluginToHostMessage.BuildParameters) {
        self.configuration = .init(parameters.configuration)
        self.logging = .init(parameters.logging)
        self.echoLogs = parameters.echoLogs
        self.otherCFlags = parameters.otherCFlags
        self.otherCxxFlags = parameters.otherCxxFlags
        self.otherSwiftcFlags = parameters.otherSwiftcFlags
        self.otherLinkerFlags = parameters.otherLinkerFlags
    }
}

fileprivate extension PluginInvocationBuildParameters.Configuration {
    init(_ configuration: PluginToHostMessage.BuildParameters.Configuration) {
        switch configuration {
        case .debug:
            self = .debug
        case .release:
            self = .release
        case .inherit:
            self = .inherit
        }
    }
}

fileprivate extension PluginInvocationBuildParameters.LogVerbosity {
    init(_ verbosity: PluginToHostMessage.BuildParameters.LogVerbosity) {
        switch verbosity {
        case .concise:
            self = .concise
        case .verbose:
            self = .verbose
        case .debug:
            self = .debug
        }
    }
}

fileprivate extension HostToPluginMessage.BuildResult {
    init(_ result: PluginInvocationBuildResult) {
        self.succeeded = result.succeeded
        self.logText = result.logText
        self.builtArtifacts = result.builtArtifacts.map { .init($0) }
    }
}

fileprivate extension HostToPluginMessage.BuildResult.BuiltArtifact {
    init(_ artifact: PluginInvocationBuildResult.BuiltArtifact) {
        self.path = .init(fileURLWithPath: artifact.path)
        self.kind = .init(artifact.kind)
    }
}

fileprivate extension HostToPluginMessage.BuildResult.BuiltArtifact.Kind {
    init(_ kind: PluginInvocationBuildResult.BuiltArtifact.Kind) {
        switch kind {
        case .executable:
            self = .executable
        case .dynamicLibrary:
            self = .dynamicLibrary
        case .staticLibrary:
            self = .staticLibrary
        }
    }
}

fileprivate extension PluginInvocationTestSubset {
    init(_ subset: PluginToHostMessage.TestSubset) {
        switch subset {
        case .all:
            self = .all
        case .filtered(let regexes):
            self = .filtered(regexes)
        }
    }
}

fileprivate extension PluginInvocationTestParameters {
    init(_ parameters: PluginToHostMessage.TestParameters) {
        self.enableCodeCoverage = parameters.enableCodeCoverage
    }
}

fileprivate extension HostToPluginMessage.TestResult {
    init(_ result: PluginInvocationTestResult) {
        self.succeeded = result.succeeded
        self.testTargets = result.testTargets.map{ .init($0) }
        self.codeCoverageDataFile = result.codeCoverageDataFile.map{ .init($0) }
    }
}

fileprivate extension HostToPluginMessage.TestResult.TestTarget {
    init(_ testTarget: PluginInvocationTestResult.TestTarget) {
        self.name = testTarget.name
        self.testCases = testTarget.testCases.map{ .init($0) }
    }
}

fileprivate extension HostToPluginMessage.TestResult.TestTarget.TestCase {
    init(_ testCase: PluginInvocationTestResult.TestTarget.TestCase) {
        self.name = testCase.name
        self.tests = testCase.tests.map{ .init($0) }
    }
}

fileprivate extension HostToPluginMessage.TestResult.TestTarget.TestCase.Test {
    init(_ test: PluginInvocationTestResult.TestTarget.TestCase.Test) {
        self.name = test.name
        self.result = .init(test.result)
        self.duration = test.duration
    }
}

fileprivate extension HostToPluginMessage.TestResult.TestTarget.TestCase.Test.Result {
    init(_ result: PluginInvocationTestResult.TestTarget.TestCase.Test.Result) {
        switch result {
        case .succeeded:
            self = .succeeded
        case .skipped:
            self = .skipped
        case .failed:
            self = .failed
        }
    }
}

fileprivate extension PluginInvocationSymbolGraphOptions {
    init(_ options: PluginToHostMessage.SymbolGraphOptions) {
        self.minimumAccessLevel = .init(options.minimumAccessLevel)
        self.includeSynthesized = options.includeSynthesized
        self.includeSPI = options.includeSPI
        self.emitExtensionBlocks = options.emitExtensionBlocks
    }
}

fileprivate extension PluginInvocationSymbolGraphOptions.AccessLevel {
    init(_ accessLevel: PluginToHostMessage.SymbolGraphOptions.AccessLevel) {
        switch accessLevel {
        case .private:
            self = .private
        case .fileprivate:
            self = .fileprivate
        case .internal:
            self = .internal
        case .public:
            self = .public
        case .open:
            self = .open
        }
    }
}

fileprivate extension HostToPluginMessage.SymbolGraphResult {
    init(_ result: PluginInvocationSymbolGraphResult) {
        self.directoryPath = .init(fileURLWithPath: result.directoryPath)
    }
}

extension ObservabilityMetadata {
    public var fileLocation: FileLocation? {
        get {
            self[FileLocationKey.self]
        }
        set {
            self[FileLocationKey.self] = newValue
        }
    }

    private enum FileLocationKey: Key {
        typealias Value = FileLocation
    }
}

public struct FileLocation: Equatable, CustomStringConvertible, Sendable {
    public let file: AbsolutePath
    public let line: Int?

    public init(_ file: AbsolutePath, line: Int?) {
        self.file = file
        self.line = line
    }

    public var description: String {
        "\(self.file)\(self.line?.description.appending(" ") ?? "")"
    }
}

extension ObservabilityMetadata {
    /// Provides information about the plugin from which the diagnostics originated.
    public var pluginName: String? {
        get {
            self[PluginNameKey.self]
        }
        set {
            self[PluginNameKey.self] = newValue
        }
    }

    enum PluginNameKey: Key {
        typealias Value = String
    }
}
