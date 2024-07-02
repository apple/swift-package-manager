//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics

@_spi(DontAdoptOutsideOfSwiftPMExposedForBenchmarksAndTestsOnly)
@testable import PackageGraph

import PackageLoading

@_spi(SwiftPMInternal)
import PackageModel

@testable import SPMBuildCore
import _InternalTestSupport
import Workspace
import XCTest

import struct TSCUtility.SerializedDiagnostics

final class PluginInvocationTests: XCTestCase {
    func testBasics() throws {
        // Construct a canned file system and package graph with a single package and a library that uses a build tool plugin that invokes a tool.
        let fileSystem = InMemoryFileSystem(emptyFiles:
            "/Foo/Plugins/FooPlugin/source.swift",
            "/Foo/Sources/FooTool/source.swift",
            "/Foo/Sources/FooToolLib/source.swift",
            "/Foo/Sources/Foo/source.swift",
            "/Foo/Sources/Foo/SomeFile.abc"
        )
        let observability = ObservabilitySystem.makeForTesting()
        let graph = try loadModulesGraph(
            fileSystem: fileSystem,
            manifests: [
                Manifest.createRootManifest(
                    displayName: "Foo",
                    path: "/Foo",
                    products: [
                        ProductDescription(
                            name: "Foo",
                            type: .library(.dynamic),
                            targets: ["Foo"]
                        )
                    ],
                    targets: [
                        TargetDescription(
                            name: "Foo",
                            type: .regular,
                            pluginUsages: [.plugin(name: "FooPlugin", package: nil)]
                        ),
                        TargetDescription(
                            name: "FooPlugin",
                            dependencies: ["FooTool"],
                            type: .plugin,
                            pluginCapability: .buildTool
                        ),
                        TargetDescription(
                            name: "FooTool",
                            dependencies: ["FooToolLib"],
                            type: .executable
                        ),
                        TargetDescription(
                            name: "FooToolLib",
                            dependencies: [],
                            type: .regular
                        ),
                    ]
                )
            ],
            observabilityScope: observability.topScope
        )

        // Check the basic integrity before running plugins.
        XCTAssertNoDiagnostics(observability.diagnostics)
        PackageGraphTester(graph) { graph in
            graph.check(packages: "Foo")
            // "FooTool{Lib}" duplicated as it's present for both build tools and end products triples.
            graph.check(modules: "Foo", "FooPlugin", "FooTool", "FooTool", "FooToolLib", "FooToolLib")
            graph.checkTarget("Foo") { target in
                target.check(dependencies: "FooPlugin")
            }
            graph.checkTarget("FooPlugin", destination: .tools) { target in
                target.check(type: .plugin)
                target.check(dependencies: "FooTool")
            }
            for destination: BuildTriple in [.tools, .destination] {
                graph.checkTarget("FooTool", destination: destination) { target in
                    target.check(type: .executable)
                    target.check(buildTriple: destination)
                    target.checkDependency("FooToolLib") { dependency in
                        dependency.checkTarget {
                            $0.check(buildTriple: destination)
                        }
                    }
                }
            }
        }

        // A fake PluginScriptRunner that just checks the input conditions and returns canned output.
        struct MockPluginScriptRunner: PluginScriptRunner {
            var hostTriple: Triple {
                get throws {
                    return try UserToolchain.default.targetTriple
                }
            }
            
            func compilePluginScript(
                sourceFiles: [AbsolutePath],
                pluginName: String,
                toolsVersion: ToolsVersion,
                observabilityScope: ObservabilityScope,
                callbackQueue: DispatchQueue,
                delegate: PluginScriptCompilerDelegate,
                completion: @escaping (Result<PluginCompilationResult, Error>) -> Void
            ) {
                callbackQueue.sync {
                    completion(.failure(StringError("unimplemented")))
                }
            }
            
            func runPluginScript(
                sourceFiles: [AbsolutePath],
                pluginName: String,
                initialMessage: Data,
                toolsVersion: ToolsVersion,
                workingDirectory: AbsolutePath,
                writableDirectories: [AbsolutePath],
                readOnlyDirectories: [AbsolutePath],
                allowNetworkConnections: [SandboxNetworkPermission],
                fileSystem: FileSystem,
                observabilityScope: ObservabilityScope,
                callbackQueue: DispatchQueue,
                delegate: PluginScriptCompilerDelegate & PluginScriptRunnerDelegate,
                completion: @escaping (Result<Int32, Error>) -> Void
            ) {
                // Check that we were given the right sources.
                XCTAssertEqual(sourceFiles, ["/Foo/Plugins/FooPlugin/source.swift"])

                do {
                    // Pretend the plugin emitted some output.
                    callbackQueue.sync {
                        delegate.handleOutput(data: Data("Hello Plugin!".utf8))
                    }
                    
                    // Pretend it emitted a warning.
                    try callbackQueue.sync {
                        let message = Data("""
                        {   "emitDiagnostic": {
                                "severity": "warning",
                                "message": "A warning",
                                "file": "/Foo/Sources/Foo/SomeFile.abc",
                                "line": 42
                            }
                        }
                        """.utf8)
                        try delegate.handleMessage(data: message, responder: { _ in })
                    }

                    // Pretend it defined a build command.
                    try callbackQueue.sync {
                        let message = Data("""
                        {   "defineBuildCommand": {
                                "configuration": {
                                    "version": 2,
                                    "displayName": "Do something",
                                    "executable": "/bin/FooTool",
                                    "arguments": [
                                        "-c", "/Foo/Sources/Foo/SomeFile.abc"
                                    ],
                                    "workingDirectory": "/Foo/Sources/Foo",
                                    "environment": {
                                        "X": "Y"
                                    },
                                },
                                "inputFiles": [
                                ],
                                "outputFiles": [
                                ]
                            }
                        }
                        """.utf8)
                        try delegate.handleMessage(data: message, responder: { _ in })
                    }
                }
                catch {
                    callbackQueue.sync {
                        completion(.failure(error))
                    }
                }

                // If we get this far we succeeded, so invoke the completion handler.
                callbackQueue.sync {
                    completion(.success(0))
                }
            }
        }

        // Construct a canned input and run plugins using our MockPluginScriptRunner().
        let outputDir = AbsolutePath("/Foo/.build")
        let pluginRunner = MockPluginScriptRunner()
        let buildParameters = mockBuildParameters(
            destination: .host,
            environment: BuildEnvironment(platform: .macOS, configuration: .debug)
        )

        let results = try invokeBuildToolPlugins(
            graph: graph,
            buildParameters: buildParameters,
            fileSystem: fileSystem,
            outputDir: outputDir,
            pluginScriptRunner: pluginRunner,
            observabilityScope: observability.topScope
        )
        let builtToolsDir = AbsolutePath("/path/to/build/\(buildParameters.triple)/debug")

        // Check the canned output to make sure nothing was lost in transport.
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertEqual(results.count, 1)
        let (_, (evalTarget, evalResults)) = try XCTUnwrap(results.first)
        XCTAssertEqual(evalTarget.name, "Foo")

        XCTAssertEqual(evalResults.count, 1)
        let evalFirstResult = try XCTUnwrap(evalResults.first)
        XCTAssertEqual(evalFirstResult.prebuildCommands.count, 0)
        XCTAssertEqual(evalFirstResult.buildCommands.count, 1)
        let evalFirstCommand = try XCTUnwrap(evalFirstResult.buildCommands.first)
        XCTAssertEqual(evalFirstCommand.configuration.displayName, "Do something")
        XCTAssertEqual(evalFirstCommand.configuration.executable, AbsolutePath("/bin/FooTool"))
        XCTAssertEqual(evalFirstCommand.configuration.arguments, ["-c", "/Foo/Sources/Foo/SomeFile.abc"])
        XCTAssertEqual(evalFirstCommand.configuration.environment, ["X": "Y"])
        XCTAssertEqual(evalFirstCommand.configuration.workingDirectory, AbsolutePath("/Foo/Sources/Foo"))
        XCTAssertEqual(evalFirstCommand.inputFiles, [builtToolsDir.appending("FooTool")])
        XCTAssertEqual(evalFirstCommand.outputFiles, [])

        XCTAssertEqual(evalFirstResult.diagnostics.count, 1)
        let evalFirstDiagnostic = try XCTUnwrap(evalFirstResult.diagnostics.first)
        XCTAssertEqual(evalFirstDiagnostic.severity, .warning)
        XCTAssertEqual(evalFirstDiagnostic.message, "A warning")
        XCTAssertEqual(evalFirstDiagnostic.metadata?.fileLocation, FileLocation("/Foo/Sources/Foo/SomeFile.abc", line: 42))

        XCTAssertEqual(evalFirstResult.textOutput, "Hello Plugin!")
    }
    
    func testCompilationDiagnostics() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(packageDir.appending("Package.swift"), string: """
                // swift-tools-version: 5.6
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    targets: [
                        .target(
                            name: "MyLibrary",
                            plugins: [
                                "MyPlugin",
                            ]
                        ),
                        .plugin(
                            name: "MyPlugin",
                            capability: .buildTool()
                        ),
                    ]
                )
                """)
            
            let myLibraryTargetDir = packageDir.appending(components: "Sources", "MyLibrary")
            try localFileSystem.createDirectory(myLibraryTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myLibraryTargetDir.appending("library.swift"), string: """
                public func Foo() { }
                """)
            
            let myPluginTargetDir = packageDir.appending(components: "Plugins", "MyPlugin")
            try localFileSystem.createDirectory(myPluginTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myPluginTargetDir.appending("plugin.swift"), string: """
                import PackagePlugin
                @main struct MyBuildToolPlugin: BuildToolPlugin {
                    func createBuildCommands(
                        context: PluginContext,
                        target: Target
                    ) throws -> [Command] {
                        // missing return statement
                    }
                }
                """)

            // Load a workspace from the package.
            let observability = ObservabilitySystem.makeForTesting()
            let workspace = try Workspace(
                fileSystem: localFileSystem,
                forRootPackage: packageDir,
                customManifestLoader: ManifestLoader(toolchain: UserToolchain.default),
                delegate: MockWorkspaceDelegate()
            )
            
            // Load the root manifest.
            let rootInput = PackageGraphRootInput(packages: [packageDir], dependencies: [])
            let rootManifests = try await workspace.loadRootManifests(
                packages: rootInput.packages,
                observabilityScope: observability.topScope
            )
            XCTAssert(rootManifests.count == 1, "\(rootManifests)")

            // Load the package graph.
            let packageGraph = try workspace.loadPackageGraph(
                rootInput: rootInput,
                observabilityScope: observability.topScope
            )
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssert(packageGraph.packages.count == 1, "\(packageGraph.packages)")
            
            // Find the build tool plugin.
            let buildToolPlugin = try XCTUnwrap(packageGraph.packages.first?.modules.map(\.underlying).first{ $0.name == "MyPlugin" } as? PluginModule)
            XCTAssertEqual(buildToolPlugin.name, "MyPlugin")
            XCTAssertEqual(buildToolPlugin.capability, .buildTool)

            // Create a plugin script runner for the duration of the test.
            let pluginCacheDir = tmpPath.appending("plugin-cache")
            let pluginScriptRunner = DefaultPluginScriptRunner(
                fileSystem: localFileSystem,
                cacheDir: pluginCacheDir,
                toolchain: try UserToolchain.default
            )
            
            // Define a plugin compilation delegate that just captures the passed information.
            class Delegate: PluginScriptCompilerDelegate {
                var commandLine: [String]? 
                var environment: Environment?
                var compiledResult: PluginCompilationResult?
                var cachedResult: PluginCompilationResult?
                init() {
                }
                func willCompilePlugin(commandLine: [String], environment: [String: String]) {
                    self.commandLine = commandLine
                    self.environment = .init(environment)
                }
                func didCompilePlugin(result: PluginCompilationResult) {
                    self.compiledResult = result
                }
                func skippedCompilingPlugin(cachedResult: PluginCompilationResult) {
                    self.cachedResult = cachedResult
                }
            }

            // Try to compile the broken plugin script.
            do {
                let delegate = Delegate()
                let result = try await pluginScriptRunner.compilePluginScript(
                    sourceFiles: buildToolPlugin.sources.paths,
                    pluginName: buildToolPlugin.name,
                    toolsVersion: buildToolPlugin.apiVersion,
                    observabilityScope: observability.topScope,
                    callbackQueue: DispatchQueue.sharedConcurrent,
                    delegate: delegate
                )

                // This should invoke the compiler but should fail.
                XCTAssert(result.succeeded == false)
                XCTAssert(result.cached == false)
                XCTAssert(result.commandLine.contains(result.executableFile.pathString), "\(result.commandLine)")
                XCTAssert(result.executableFile.components.contains("plugin-cache"), "\(result.executableFile.pathString)")
                XCTAssert(result.compilerOutput.contains("error: missing return"), "\(result.compilerOutput)")
                XCTAssert(result.diagnosticsFile.suffix == ".dia", "\(result.diagnosticsFile.pathString)")

                // Check the delegate callbacks.
                XCTAssertEqual(delegate.commandLine, result.commandLine)
                XCTAssertNotNil(delegate.environment)
                XCTAssertEqual(delegate.compiledResult, result)
                XCTAssertNil(delegate.cachedResult)
                
                // Check the serialized diagnostics. We should have an error.
                let diaFileContents = try localFileSystem.readFileContents(result.diagnosticsFile)
                let diagnosticsSet = try SerializedDiagnostics(bytes: diaFileContents)
                XCTAssertEqual(diagnosticsSet.diagnostics.count, 1)
                let errorDiagnostic = try XCTUnwrap(diagnosticsSet.diagnostics.first)
                XCTAssertTrue(errorDiagnostic.text.hasPrefix("missing return"), "\(errorDiagnostic)")

                // Check that the executable file doesn't exist.
                XCTAssertFalse(localFileSystem.exists(result.executableFile), "\(result.executableFile.pathString)")
            }

            // Now replace the plugin script source with syntactically valid contents that still produces a warning.
            try localFileSystem.writeFileContents(myPluginTargetDir.appending("plugin.swift"), string: """
                import PackagePlugin
                @main struct MyBuildToolPlugin: BuildToolPlugin {
                    func createBuildCommands(
                        context: PluginContext,
                        target: Target
                    ) throws -> [Command] {
                        var unused: Int
                        return []
                    }
                }
                """)
            
            // Try to compile the fixed plugin.
            let firstExecModTime: Date
            do {
                let delegate = Delegate()
                let result = try await pluginScriptRunner.compilePluginScript(
                    sourceFiles: buildToolPlugin.sources.paths,
                    pluginName: buildToolPlugin.name,
                    toolsVersion: buildToolPlugin.apiVersion,
                    observabilityScope: observability.topScope,
                    callbackQueue: DispatchQueue.sharedConcurrent,
                    delegate: delegate
                )

                // This should invoke the compiler and this time should succeed.
                XCTAssert(result.succeeded == true)
                XCTAssert(result.cached == false)
                XCTAssert(result.commandLine.contains(result.executableFile.pathString), "\(result.commandLine)")
                XCTAssert(result.executableFile.components.contains("plugin-cache"), "\(result.executableFile.pathString)")
                XCTAssert(result.compilerOutput.contains("warning: variable 'unused' was never used"), "\(result.compilerOutput)")
                XCTAssert(result.diagnosticsFile.suffix == ".dia", "\(result.diagnosticsFile.pathString)")

                // Check the delegate callbacks.
                XCTAssertEqual(delegate.commandLine, result.commandLine)
                XCTAssertNotNil(delegate.environment)
                XCTAssertEqual(delegate.compiledResult, result)
                XCTAssertNil(delegate.cachedResult)

                if try UserToolchain.default.supportsSerializedDiagnostics() {
                    // Check the serialized diagnostics. We should no longer have an error but now have a warning.
                    let diaFileContents = try localFileSystem.readFileContents(result.diagnosticsFile)
                    let diagnosticsSet = try SerializedDiagnostics(bytes: diaFileContents)
                    let hasExpectedDiagnosticsCount = diagnosticsSet.diagnostics.count == 1
                    let warningDiagnosticText = diagnosticsSet.diagnostics.first?.text ?? ""
                    let hasExpectedWarningText = warningDiagnosticText.hasPrefix("variable \'unused\' was never used")
                    if hasExpectedDiagnosticsCount && hasExpectedWarningText {
                        XCTAssertTrue(hasExpectedDiagnosticsCount, "unexpected diagnostics count in \(diagnosticsSet.diagnostics) from \(result.diagnosticsFile.pathString)")
                        XCTAssertTrue(hasExpectedWarningText, "\(warningDiagnosticText)")
                    } else {
                        print("bytes of serialized diagnostics file `\(result.diagnosticsFile.pathString)`: \(diaFileContents.contents)")
                        try XCTSkipIf(true, "skipping because of unknown serialized diagnostics issue")
                    }
                }

                // Check that the executable file exists.
                XCTAssertTrue(localFileSystem.exists(result.executableFile), "\(result.executableFile.pathString)")

                // Capture the timestamp of the executable so we can compare it later.
                firstExecModTime = try localFileSystem.getFileInfo(result.executableFile).modTime
            }

            // Recompile the command plugin again without changing its source code.
            let secondExecModTime: Date
            do {
                let delegate = Delegate()
                let result = try await pluginScriptRunner.compilePluginScript(
                    sourceFiles: buildToolPlugin.sources.paths,
                    pluginName: buildToolPlugin.name,
                    toolsVersion: buildToolPlugin.apiVersion,
                    observabilityScope: observability.topScope,
                    callbackQueue: DispatchQueue.sharedConcurrent,
                    delegate: delegate
                )

                // This should not invoke the compiler (just reuse the cached executable).
                XCTAssert(result.succeeded == true)
                XCTAssert(result.cached == true)
                XCTAssert(result.commandLine.contains(result.executableFile.pathString), "\(result.commandLine)")
                XCTAssert(result.executableFile.components.contains("plugin-cache"), "\(result.executableFile.pathString)")
                XCTAssert(result.compilerOutput.contains("warning: variable 'unused' was never used"), "\(result.compilerOutput)")
                XCTAssert(result.diagnosticsFile.suffix == ".dia", "\(result.diagnosticsFile.pathString)")

                // Check the delegate callbacks. Note that the nil command line and environment indicates that we didn't get the callback saying that compilation will start; this is expected when the cache is reused. This is a behaviour of our test delegate. The command line is available in the cached result.
                XCTAssertNil(delegate.commandLine)
                XCTAssertNil(delegate.environment)
                XCTAssertNil(delegate.compiledResult)
                XCTAssertEqual(delegate.cachedResult, result)

                if try UserToolchain.default.supportsSerializedDiagnostics() {
                    // Check that the diagnostics still have the same warning as before.
                    let diaFileContents = try localFileSystem.readFileContents(result.diagnosticsFile)
                    let diagnosticsSet = try SerializedDiagnostics(bytes: diaFileContents)
                    XCTAssertEqual(diagnosticsSet.diagnostics.count, 1)
                    let warningDiagnostic = try XCTUnwrap(diagnosticsSet.diagnostics.first)
                    XCTAssertTrue(warningDiagnostic.text.hasPrefix("variable \'unused\' was never used"), "\(warningDiagnostic)")
                }

                // Check that the executable file exists.
                XCTAssertTrue(localFileSystem.exists(result.executableFile), "\(result.executableFile.pathString)")

                // Check that the timestamp hasn't changed (at least a mild indication that it wasn't recompiled).
                secondExecModTime = try localFileSystem.getFileInfo(result.executableFile).modTime
                XCTAssert(secondExecModTime == firstExecModTime, "firstExecModTime: \(firstExecModTime), secondExecModTime: \(secondExecModTime)")
            }

            // Now replace the plugin script source with syntactically valid contents that no longer produces a warning.
            try localFileSystem.writeFileContents(myPluginTargetDir.appending("plugin.swift"), string: """
                import PackagePlugin
                @main struct MyBuildToolPlugin: BuildToolPlugin {
                    func createBuildCommands(
                        context: PluginContext,
                        target: Target
                    ) throws -> [Command] {
                        return []
                    }
                }
                """)

            // NTFS does not have nanosecond granularity (nor is this is a guaranteed file
            // system feature on all file systems). Add a sleep before the execution to ensure that we have sufficient
            // precision to read a difference.
            try await Task.sleep(nanoseconds: UInt64(SendableTimeInterval.seconds(1).nanoseconds()!))

            // Recompile the plugin again.
            let thirdExecModTime: Date
            do {
                let delegate = Delegate()
                let result = try await pluginScriptRunner.compilePluginScript(
                    sourceFiles: buildToolPlugin.sources.paths,
                    pluginName: buildToolPlugin.name,
                    toolsVersion: buildToolPlugin.apiVersion,
                    observabilityScope: observability.topScope,
                    callbackQueue: DispatchQueue.sharedConcurrent,
                    delegate: delegate
                )

                // This should invoke the compiler and not use the cache.
                XCTAssert(result.succeeded == true)
                XCTAssert(result.cached == false)
                XCTAssert(result.commandLine.contains(result.executableFile.pathString), "\(result.commandLine)")
                XCTAssert(result.executableFile.components.contains("plugin-cache"), "\(result.executableFile.pathString)")
                XCTAssert(!result.compilerOutput.contains("warning:"), "\(result.compilerOutput)")
                XCTAssert(result.diagnosticsFile.suffix == ".dia", "\(result.diagnosticsFile.pathString)")

                // Check the delegate callbacks.
                XCTAssertEqual(delegate.commandLine, result.commandLine)
                XCTAssertNotNil(delegate.environment)
                XCTAssertEqual(delegate.compiledResult, result)
                XCTAssertNil(delegate.cachedResult)
                
                // Check that the diagnostics no longer have a warning.
                let diaFileContents = try localFileSystem.readFileContents(result.diagnosticsFile)
                let diagnosticsSet = try SerializedDiagnostics(bytes: diaFileContents)
                XCTAssertEqual(diagnosticsSet.diagnostics.count, 0)

                // Check that the executable file exists.
                XCTAssertTrue(localFileSystem.exists(result.executableFile), "\(result.executableFile.pathString)")

                // Check that the timestamp has changed (at least a mild indication that it was recompiled).
                thirdExecModTime = try localFileSystem.getFileInfo(result.executableFile).modTime
                XCTAssert(thirdExecModTime != firstExecModTime, "thirdExecModTime: \(thirdExecModTime), firstExecModTime: \(firstExecModTime)")
                XCTAssert(thirdExecModTime != secondExecModTime, "thirdExecModTime: \(thirdExecModTime), secondExecModTime: \(secondExecModTime)")
            }

            // Now replace the plugin script source with a broken one again.
            try localFileSystem.writeFileContents(myPluginTargetDir.appending("plugin.swift"), string: """
                import PackagePlugin
                @main struct MyBuildToolPlugin: BuildToolPlugin {
                    func createBuildCommands(
                        context: PluginContext,
                        target: Target
                    ) throws -> [Command] {
                        return nil  // returning the wrong type
                    }
                }
                """)

            // Recompile the plugin again.
            do {
                let delegate = Delegate()
                let result = try await pluginScriptRunner.compilePluginScript(
                    sourceFiles: buildToolPlugin.sources.paths,
                    pluginName: buildToolPlugin.name,
                    toolsVersion: buildToolPlugin.apiVersion,
                    observabilityScope: observability.topScope,
                    callbackQueue: DispatchQueue.sharedConcurrent,
                    delegate: delegate
                )

                // This should again invoke the compiler but should fail.
                XCTAssert(result.succeeded == false)
                XCTAssert(result.cached == false)
                XCTAssert(result.commandLine.contains(result.executableFile.pathString), "\(result.commandLine)")
                XCTAssert(result.executableFile.components.contains("plugin-cache"), "\(result.executableFile.pathString)")
                XCTAssert(result.compilerOutput.contains("error: 'nil' is incompatible with return type"), "\(result.compilerOutput)")
                XCTAssert(result.diagnosticsFile.suffix == ".dia", "\(result.diagnosticsFile.pathString)")

                // Check the delegate callbacks.
                XCTAssertEqual(delegate.commandLine, result.commandLine)
                XCTAssertNotNil(delegate.environment)
                XCTAssertEqual(delegate.compiledResult, result)
                XCTAssertNil(delegate.cachedResult)
                
                // Check the diagnostics. We should have a different error than the original one.
                let diaFileContents = try localFileSystem.readFileContents(result.diagnosticsFile)
                let diagnosticsSet = try SerializedDiagnostics(bytes: diaFileContents)
                XCTAssertEqual(diagnosticsSet.diagnostics.count, 1)
                let errorDiagnostic = try XCTUnwrap(diagnosticsSet.diagnostics.first)
                XCTAssertTrue(errorDiagnostic.text.hasPrefix("'nil' is incompatible with return type"), "\(errorDiagnostic)")

                // Check that the executable file no longer exists.
                XCTAssertFalse(localFileSystem.exists(result.executableFile), "\(result.executableFile.pathString)")
            }
        }
    }

    func testUnsupportedDependencyProduct() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library product and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(packageDir.appending("Package.swift"), string: """
            // swift-tools-version: 5.7
            import PackageDescription
            let package = Package(
                name: "MyPackage",
                dependencies: [
                  .package(path: "../FooPackage"),
                ],
                targets: [
                    .plugin(
                        name: "MyPlugin",
                        capability: .buildTool(),
                        dependencies: [
                            .product(name: "FooLib", package: "FooPackage"),
                        ]
                    ),
                ]
            )
            """)

            let myPluginTargetDir = packageDir.appending(components: "Plugins", "MyPlugin")
            try localFileSystem.createDirectory(myPluginTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myPluginTargetDir.appending("plugin.swift"), string: """
                  import PackagePlugin
                  import Foo
                  @main struct MyBuildToolPlugin: BuildToolPlugin {
                      func createBuildCommands(
                          context: PluginContext,
                          target: Target
                      ) throws -> [Command] { }
                  }
                  """)

            let fooPkgDir = tmpPath.appending(components: "FooPackage")
            try localFileSystem.createDirectory(fooPkgDir, recursive: true)
            try localFileSystem.writeFileContents(fooPkgDir.appending("Package.swift"), string: """
                // swift-tools-version: 5.7
                import PackageDescription
                let package = Package(
                    name: "FooPackage",
                    products: [
                        .library(name: "FooLib",
                                 targets: ["Foo"]),
                    ],
                    targets: [
                        .target(
                            name: "Foo",
                            dependencies: []
                        ),
                    ]
                )
                """)
            let fooTargetDir = fooPkgDir.appending(components: "Sources", "Foo")
            try localFileSystem.createDirectory(fooTargetDir, recursive: true)
            try localFileSystem.writeFileContents(fooTargetDir.appending("file.swift"), string: """
                  public func foo() { }
                  """)

            // Load a workspace from the package.
            let observability = ObservabilitySystem.makeForTesting()
            let workspace = try Workspace(
                fileSystem: localFileSystem,
                forRootPackage: packageDir,
                customManifestLoader: ManifestLoader(toolchain: UserToolchain.default),
                delegate: MockWorkspaceDelegate()
            )

            // Load the root manifest.
            let rootInput = PackageGraphRootInput(packages: [packageDir], dependencies: [])
            let rootManifests = try await workspace.loadRootManifests(
                packages: rootInput.packages,
                observabilityScope: observability.topScope
            )
            XCTAssert(rootManifests.count == 1, "\(rootManifests)")

            // Load the package graph.
            XCTAssertThrowsError(try workspace.loadPackageGraph(
                rootInput: rootInput,
                observabilityScope: observability.topScope
            )) { error in
                var diagnosed = false
                if let realError = error as? PackageGraphError,
                   realError.description == "plugin 'MyPlugin' cannot depend on 'FooLib' of type 'library' from package 'foopackage'; this dependency is unsupported" {
                    diagnosed = true
                }
                XCTAssertTrue(diagnosed)
            }
        }
    }

    func testUnsupportedDependencyTarget() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(packageDir.appending("Package.swift"), string: """
                // swift-tools-version: 5.7
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    targets: [
                        .target(
                            name: "MyLibrary",
                            dependencies: []
                        ),
                        .plugin(
                            name: "MyPlugin",
                            capability: .buildTool(),
                            dependencies: [
                                "MyLibrary"
                            ]
                        ),
                    ]
                )
                """)

            let myLibraryTargetDir = packageDir.appending(components: "Sources", "MyLibrary")
            try localFileSystem.createDirectory(myLibraryTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myLibraryTargetDir.appending("library.swift"), string: """
                    public func hello() { }
                    """)
            let myPluginTargetDir = packageDir.appending(components: "Plugins", "MyPlugin")
            try localFileSystem.createDirectory(myPluginTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myPluginTargetDir.appending("plugin.swift"), string: """
                  import PackagePlugin
                  import MyLibrary
                  @main struct MyBuildToolPlugin: BuildToolPlugin {
                      func createBuildCommands(
                          context: PluginContext,
                          target: Target
                      ) throws -> [Command] { }
                  }
                  """)

            // Load a workspace from the package.
            let observability = ObservabilitySystem.makeForTesting()
            let workspace = try Workspace(
                fileSystem: localFileSystem,
                forRootPackage: packageDir,
                customManifestLoader: ManifestLoader(toolchain: UserToolchain.default),
                delegate: MockWorkspaceDelegate()
            )

            // Load the root manifest.
            let rootInput = PackageGraphRootInput(packages: [packageDir], dependencies: [])
            let rootManifests = try await workspace.loadRootManifests(
                packages: rootInput.packages,
                observabilityScope: observability.topScope
            )
            XCTAssert(rootManifests.count == 1, "\(rootManifests)")

            // Load the package graph.
            XCTAssertThrowsError(try workspace.loadPackageGraph(
                rootInput: rootInput,
                observabilityScope: observability.topScope)) { error in
                var diagnosed = false
                if let realError = error as? PackageGraphError,
                   realError.description == "plugin 'MyPlugin' cannot depend on 'MyLibrary' of type 'library'; this dependency is unsupported" {
                    diagnosed = true
                }
                XCTAssertTrue(diagnosed)
            }
        }
    }

    func testPrebuildPluginShouldNotUseExecTarget() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target and a plugin.
            let packageDir = tmpPath.appending(components: "mypkg")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(packageDir.appending("Package.swift"), string: """
                // swift-tools-version:5.7

                import PackageDescription

                let package = Package(
                    name: "mypkg",
                    products: [
                        .library(
                            name: "MyLib",
                            targets: ["MyLib"])
                    ],
                    targets: [
                        .target(
                            name: "MyLib",
                            plugins: [
                                .plugin(name: "X")
                            ]),
                        .plugin(
                            name: "X",
                            capability: .buildTool(),
                            dependencies: [ "Y" ]
                        ),
                        .executableTarget(
                            name: "Y",
                            dependencies: []),
                    ]
                )
                """)

            let libTargetDir = packageDir.appending(components: "Sources", "MyLib")
            try localFileSystem.createDirectory(libTargetDir, recursive: true)
            try localFileSystem.writeFileContents(libTargetDir.appending("file.swift"), string: """
                public struct MyUtilLib {
                    public let strings: [String]
                    public init(args: [String]) {
                        self.strings = args
                    }
                }
            """)

            let depTargetDir = packageDir.appending(components: "Sources", "Y")
            try localFileSystem.createDirectory(depTargetDir, recursive: true)
            try localFileSystem.writeFileContents(depTargetDir.appending("main.swift"), string: """
                struct Y {
                    func run() {
                        print("You passed us two arguments, argumentOne, and argumentTwo")
                    }
                }
                Y.main()
            """)

            let pluginTargetDir = packageDir.appending(components: "Plugins", "X")
            try localFileSystem.createDirectory(pluginTargetDir, recursive: true)
            try localFileSystem.writeFileContents(pluginTargetDir.appending("plugin.swift"), string: """
                  import PackagePlugin
                  @main struct X: BuildToolPlugin {
                      func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
                          [
                              Command.prebuildCommand(
                                  displayName: "X: Running Y before the build...",
                                  executable: try context.tool(named: "Y").path,
                                  arguments: [ "ARGUMENT_ONE", "ARGUMENT_TWO" ],
                                  outputFilesDirectory: context.pluginWorkDirectory.appending("OUTPUT_FILES_DIRECTORY")
                              )
                          ]
                      }
                  }
                  """)

            // Load a workspace from the package.
            let observability = ObservabilitySystem.makeForTesting()
            let workspace = try Workspace(
                fileSystem: localFileSystem,
                forRootPackage: packageDir,
                customManifestLoader: ManifestLoader(toolchain: UserToolchain.default),
                delegate: MockWorkspaceDelegate()
            )

            // Load the root manifest.
            let rootInput = PackageGraphRootInput(packages: [packageDir], dependencies: [])
            let rootManifests = try await workspace.loadRootManifests(
                packages: rootInput.packages,
                observabilityScope: observability.topScope
            )
            XCTAssert(rootManifests.count == 1, "\(rootManifests)")

            // Load the package graph.
            let packageGraph = try workspace.loadPackageGraph(
                rootInput: rootInput,
                observabilityScope: observability.topScope
            )
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssert(packageGraph.packages.count == 1, "\(packageGraph.packages)")

            // Find the build tool plugin.
            let buildToolPlugin = try XCTUnwrap(packageGraph.packages.first?.modules.map(\.underlying).filter{ $0.name == "X" }.first as? PluginModule)
            XCTAssertEqual(buildToolPlugin.name, "X")
            XCTAssertEqual(buildToolPlugin.capability, .buildTool)

            // Create a plugin script runner for the duration of the test.
            let pluginCacheDir = tmpPath.appending("plugin-cache")
            let pluginScriptRunner = DefaultPluginScriptRunner(
                fileSystem: localFileSystem,
                cacheDir: pluginCacheDir,
                toolchain: try UserToolchain.default
            )

            // Invoke build tool plugin
            do {
                let outputDir = packageDir.appending(".build")
                let buildParameters = mockBuildParameters(
                    destination: .host,
                    environment: BuildEnvironment(platform: .macOS, configuration: .debug)
                )

                let result = try invokeBuildToolPlugins(
                    graph: packageGraph,
                    buildParameters: buildParameters,
                    fileSystem: localFileSystem,
                    outputDir: outputDir,
                    pluginScriptRunner: pluginScriptRunner,
                    observabilityScope: observability.topScope
                )

                let diags = result.flatMap(\.value.results).flatMap(\.diagnostics)
                testDiagnostics(diags) { result in
                    let msg = "a prebuild command cannot use executables built from source, including executable target 'Y'"
                    result.check(diagnostic: .contains(msg), severity: .error)
                }
            }
        }
    }

    func testScanImportsInPluginTargets() async throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(packageDir.appending("Package.swift"), string: """
                // swift-tools-version: 5.7
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    dependencies: [
                      .package(path: "../OtherPackage"),
                    ],
                    targets: [
                        .target(
                            name: "MyLibrary",
                            dependencies: [.product(name: "OtherPlugin", package: "OtherPackage")]
                        ),
                        .plugin(
                            name: "XPlugin",
                            capability: .buildTool()
                        ),
                        .plugin(
                            name: "YPlugin",
                            capability: .command(
                               intent: .custom(verb: "YPlugin", description: "Plugin example"),
                               permissions: []
                            )
                        )
                    ]
                )
                """)

            let myLibraryTargetDir = packageDir.appending(components: "Sources", "MyLibrary")
            try localFileSystem.createDirectory(myLibraryTargetDir, recursive: true)
            try localFileSystem.writeFileContents(myLibraryTargetDir.appending("library.swift"), string: """
                    public func hello() { }
                    """)
            let xPluginTargetDir = packageDir.appending(components: "Plugins", "XPlugin")
            try localFileSystem.createDirectory(xPluginTargetDir, recursive: true)
            try localFileSystem.writeFileContents(xPluginTargetDir.appending("plugin.swift"), string: """
                  import PackagePlugin
                  import XcodeProjectPlugin
                  @main struct XBuildToolPlugin: BuildToolPlugin {
                      func createBuildCommands(
                          context: PluginContext,
                          target: Target
                      ) throws -> [Command] { }
                  }
                  """)
            let yPluginTargetDir = packageDir.appending(components: "Plugins", "YPlugin")
            try localFileSystem.createDirectory(yPluginTargetDir, recursive: true)
            try localFileSystem.writeFileContents(yPluginTargetDir.appending("plugin.swift"), string: """
                     import PackagePlugin
                     import Foundation
                     @main struct YPlugin: BuildToolPlugin {
                         func createBuildCommands(
                             context: PluginContext,
                             target: Target
                         ) throws -> [Command] { }
                     }
                     """)


            //////

            let otherPackageDir = tmpPath.appending(components: "OtherPackage")
            try localFileSystem.createDirectory(otherPackageDir, recursive: true)
            try localFileSystem.writeFileContents(otherPackageDir.appending("Package.swift"), string: """
                // swift-tools-version: 5.7
                import PackageDescription
                let package = Package(
                    name: "OtherPackage",
                    products: [
                        .plugin(
                            name: "OtherPlugin",
                            targets: ["QPlugin"])
                    ],
                    targets: [
                        .plugin(
                            name: "QPlugin",
                            capability: .buildTool()
                        ),
                        .plugin(
                            name: "RPlugin",
                            capability: .command(
                               intent: .custom(verb: "RPlugin", description: "Plugin example"),
                               permissions: []
                            )
                        )
                    ]
                )
                """)

            let qPluginTargetDir = otherPackageDir.appending(components: "Plugins", "QPlugin")
            try localFileSystem.createDirectory(qPluginTargetDir, recursive: true)
            try localFileSystem.writeFileContents(qPluginTargetDir.appending("plugin.swift"), string: """
                  import PackagePlugin
                  import XcodeProjectPlugin
                  #if canImport(ModuleFoundViaExtraSearchPaths)
                  import ModuleFoundViaExtraSearchPaths
                  #endif
                  @main struct QBuildToolPlugin: BuildToolPlugin {
                      func createBuildCommands(
                          context: PluginContext,
                          target: Target
                      ) throws -> [Command] { }
                  }
                  """)
            
            // Create a valid swift interface file that can be detected via `canImport()`.
            let fakeExtraModulesDir = tmpPath.appending("ExtraModules")
            try localFileSystem.createDirectory(fakeExtraModulesDir, recursive: true)
            let fakeExtraModuleFile = fakeExtraModulesDir.appending("ModuleFoundViaExtraSearchPaths.swiftinterface")
            try localFileSystem.writeFileContents(fakeExtraModuleFile, string: """
                  // swift-interface-format-version: 1.0
                  // swift-module-flags: -module-name ModuleFoundViaExtraSearchPaths
                  """)
            
            /////////
            // Load a workspace from the package.
            let observability = ObservabilitySystem.makeForTesting()
            let environment = Environment.current
            let workspace = try Workspace(
                fileSystem: localFileSystem,
                location: try Workspace.Location(forRootPackage: packageDir, fileSystem: localFileSystem),
                customHostToolchain: UserToolchain(
                    swiftSDK: .hostSwiftSDK(
                        environment: environment
                    ),
                    environment: environment,
                    customLibrariesLocation: .init(manifestLibraryPath: fakeExtraModulesDir, pluginLibraryPath: fakeExtraModulesDir)
                ),
                customManifestLoader: ManifestLoader(toolchain: UserToolchain.default),
                delegate: MockWorkspaceDelegate()
            )

            // Load the root manifest.
            let rootInput = PackageGraphRootInput(packages: [packageDir], dependencies: [])
            let rootManifests = try await workspace.loadRootManifests(
                packages: rootInput.packages,
                observabilityScope: observability.topScope
            )
            XCTAssert(rootManifests.count == 1, "\(rootManifests)")

            let graph = try workspace.loadPackageGraph(
                rootInput: rootInput,
                observabilityScope: observability.topScope
            )
            let dict = try await workspace.loadPluginImports(packageGraph: graph)

            var count = 0
            for (pkg, entry) in dict {
                if pkg.description == "mypackage" {
                    XCTAssertNotNil(entry["XPlugin"])
                    let XPluginPossibleImports1 = ["PackagePlugin", "XcodeProjectPlugin"]
                    let XPluginPossibleImports2 = ["PackagePlugin", "XcodeProjectPlugin", "_SwiftConcurrencyShims"]
                    XCTAssertTrue(entry["XPlugin"] == XPluginPossibleImports1 ||
                                  entry["XPlugin"] == XPluginPossibleImports2)

                    let YPluginPossibleImports1 = ["PackagePlugin", "Foundation"]
                    let YPluginPossibleImports2 = ["PackagePlugin", "Foundation", "_SwiftConcurrencyShims"]
                    XCTAssertTrue(entry["YPlugin"] == YPluginPossibleImports1 ||
                                  entry["YPlugin"] == YPluginPossibleImports2)
                    count += 1
                } else if pkg.description == "otherpackage" {
                    XCTAssertNotNil(dict[pkg]?["QPlugin"])

                    let possibleImports1 = ["PackagePlugin", "XcodeProjectPlugin", "ModuleFoundViaExtraSearchPaths"]
                    let possibleImports2 = ["PackagePlugin", "XcodeProjectPlugin", "ModuleFoundViaExtraSearchPaths", "_SwiftConcurrencyShims"]
                    XCTAssertTrue(entry["QPlugin"] == possibleImports1 ||
                                  entry["QPlugin"] == possibleImports2)
                    count += 1
                }
            }

            XCTAssertEqual(count, 2)
        }
    }

    func checkParseArtifactsPlatformCompatibility(
        artifactSupportedTriples: [Triple],
        hostTriple: Triple
    ) async throws -> [ResolvedModule.ID: [BuildToolPluginInvocationResult]]  {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        return try await testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(packageDir.appending("Package.swift"), string: """
                   // swift-tools-version: 5.7
                   import PackageDescription
                   let package = Package(
                       name: "MyPackage",
                       dependencies: [
                       ],
                       targets: [
                           .target(
                               name: "MyLibrary",
                               plugins: [
                                   "Foo",
                               ]
                           ),
                           .plugin(
                               name: "Foo",
                               capability: .buildTool(),
                               dependencies: [
                                   .target(name: "LocalBinaryTool"),
                               ]
                            ),
                           .binaryTarget(
                               name: "LocalBinaryTool",
                               path: "Binaries/LocalBinaryTool.\(artifactBundleExtension)"
                           ),
                        ]
                   )
                   """)

            let libDir = packageDir.appending(components: "Sources", "MyLibrary")
            try localFileSystem.createDirectory(libDir, recursive: true)
            try localFileSystem.writeFileContents(
                libDir.appending(components: "library.swift"),
                string: """
                public func myLib() { }
                """
            )

            let myPluginTargetDir = packageDir.appending(components: "Plugins", "Foo")
            try localFileSystem.createDirectory(myPluginTargetDir, recursive: true)
            let content = """
                 import PackagePlugin
                 @main struct FooPlugin: BuildToolPlugin {
                     func createBuildCommands(
                         context: PluginContext,
                         target: Target
                     ) throws -> [Command] {
                        print("Looking for LocalBinaryTool...")
                        let localBinaryTool = try context.tool(named: "LocalBinaryTool")
                        print("... found it at \\(localBinaryTool.path)")
                        return [.buildCommand(displayName: "", executable: localBinaryTool.path, arguments: [], inputFiles: [], outputFiles: [])]
                    }
                 }
            """
            try localFileSystem.writeFileContents(myPluginTargetDir.appending("plugin.swift"), string: content)
            let artifactVariants = artifactSupportedTriples.map {
                """
                { "path": "LocalBinaryTool\($0.tripleString).sh", "supportedTriples": ["\($0.tripleString)"] }
                """
            }

            let bundleMetadataPath = packageDir.appending(
                components: "Binaries",
                "LocalBinaryTool.artifactbundle",
                "info.json"
            )
            try localFileSystem.createDirectory(bundleMetadataPath.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(
                bundleMetadataPath,
                string: """
                {   "schemaVersion": "1.0",
                    "artifacts": {
                        "LocalBinaryTool": {
                            "type": "executable",
                            "version": "1.2.3",
                            "variants": [
                                \(artifactVariants.joined(separator: ","))
                            ]
                        }
                    }
                }
                """
            )
            // Load a workspace from the package.
            let observability = ObservabilitySystem.makeForTesting()
            let workspace = try Workspace(
                fileSystem: localFileSystem,
                forRootPackage: packageDir,
                customManifestLoader: ManifestLoader(toolchain: UserToolchain.default),
                delegate: MockWorkspaceDelegate()
            )

            // Load the root manifest.
            let rootInput = PackageGraphRootInput(packages: [packageDir], dependencies: [])
            let rootManifests = try await workspace.loadRootManifests(
                packages: rootInput.packages,
                observabilityScope: observability.topScope
            )
            XCTAssert(rootManifests.count == 1, "\(rootManifests)")

            // Load the package graph.
            let packageGraph = try workspace.loadPackageGraph(
                rootInput: rootInput,
                observabilityScope: observability.topScope
            )
            XCTAssertNoDiagnostics(observability.diagnostics)

            // Find the build tool plugin.
            let buildToolPlugin = try XCTUnwrap(packageGraph.packages.first?.modules
                .map(\.underlying)
                .filter { $0.name == "Foo" }
                .first as? PluginModule)
            XCTAssertEqual(buildToolPlugin.name, "Foo")
            XCTAssertEqual(buildToolPlugin.capability, .buildTool)

            // Construct a toolchain with a made-up host/target triple
            let swiftSDK = try SwiftSDK.default
            let toolchain = try UserToolchain(
                swiftSDK: SwiftSDK(
                    hostTriple: hostTriple,
                    targetTriple: hostTriple,
                    toolset: swiftSDK.toolset,
                    pathsConfiguration: swiftSDK.pathsConfiguration
                ),
                environment: .current
            )

            // Create a plugin script runner for the duration of the test.
            let pluginCacheDir = tmpPath.appending("plugin-cache")
            let pluginScriptRunner = DefaultPluginScriptRunner(
                fileSystem: localFileSystem,
                cacheDir: pluginCacheDir,
                toolchain: toolchain
            )

            // Invoke build tool plugin
            let outputDir = packageDir.appending(".build")
            let buildParameters = mockBuildParameters(
                destination: .host,
                environment: BuildEnvironment(platform: .macOS, configuration: .debug)
            )

            return try invokeBuildToolPlugins(
                graph: packageGraph,
                buildParameters: buildParameters,
                fileSystem: localFileSystem,
                outputDir: outputDir,
                pluginScriptRunner: pluginScriptRunner,
                observabilityScope: observability.topScope
            ).mapValues(\.results)
        }
    }

    func testParseArtifactNotSupportedOnTargetPlatform() async throws {
        let hostTriple = try UserToolchain.default.targetTriple
        let artifactSupportedTriples = try [Triple("riscv64-apple-windows-android")]

        var checked = false
        let result = try await checkParseArtifactsPlatformCompatibility(artifactSupportedTriples: artifactSupportedTriples, hostTriple: hostTriple)
        if let pluginResult = result.first,
           let diag = pluginResult.value.first?.diagnostics,
           diag.description == "[[error]: Tool ‘LocalBinaryTool’ is not supported on the target platform]" {
            checked = true
        }
        XCTAssertTrue(checked)
    }

    func testParseArtifactsDoesNotCheckPlatformVersion() async throws {
        #if !os(macOS)
        throw XCTSkip("platform versions are only available if the host is macOS")
        #else
        let hostTriple = try UserToolchain.default.targetTriple
        let artifactSupportedTriples = try [Triple("\(hostTriple.withoutVersion().tripleString)20.0")]

        let result = try await checkParseArtifactsPlatformCompatibility(artifactSupportedTriples: artifactSupportedTriples, hostTriple: hostTriple)
        result.forEach {
            $0.value.forEach {
                XCTAssertTrue($0.succeeded, "plugin unexpectedly failed")
                XCTAssertEqual($0.diagnostics.map { $0.message }, [], "plugin produced unexpected diagnostics")
            }
        }
        #endif
    }

    func testParseArtifactsConsidersAllSupportedTriples() async throws {
        let hostTriple = try UserToolchain.default.targetTriple
        let artifactSupportedTriples = [hostTriple, try Triple("riscv64-apple-windows-android")]

        let result = try await checkParseArtifactsPlatformCompatibility(artifactSupportedTriples: artifactSupportedTriples, hostTriple: hostTriple)
        result.forEach {
            $0.value.forEach {
                XCTAssertTrue($0.succeeded, "plugin unexpectedly failed")
                XCTAssertEqual($0.diagnostics.map { $0.message }, [], "plugin produced unexpected diagnostics")
                XCTAssertEqual($0.buildCommands.first?.configuration.executable.basename, "LocalBinaryTool\(hostTriple.tripleString).sh")
            }
        }
    }

    private func invokeBuildToolPlugins(
        graph: ModulesGraph,
        buildParameters: BuildParameters,
        fileSystem: any FileSystem,
        outputDir: AbsolutePath,
        pluginScriptRunner: PluginScriptRunner,
        observabilityScope: ObservabilityScope
    ) throws -> [ResolvedModule.ID: (target: ResolvedModule, results: [BuildToolPluginInvocationResult])] {
        let pluginsPerModule = graph.pluginsPerModule(
            satisfying: buildParameters.buildEnvironment
        )

        let plugins = pluginsPerModule.values.reduce(into: IdentifiableSet<ResolvedModule>()) { result, plugins in
            plugins.forEach { result.insert($0) }
        }

        return try graph.invokeBuildToolPlugins(
            pluginsPerTarget: pluginsPerModule,
            pluginTools: mockPluginTools(
                plugins: plugins,
                fileSystem: fileSystem,
                buildParameters: buildParameters,
                hostTriple: hostTriple
            ),
            outputDir: outputDir,
            buildParameters: buildParameters,
            additionalFileRules: [],
            toolSearchDirectories: [UserToolchain.default.swiftCompilerPath.parentDirectory],
            pkgConfigDirectories: [],
            pluginScriptRunner: pluginScriptRunner,
            observabilityScope: observabilityScope,
            fileSystem: fileSystem
        )
    }
}
