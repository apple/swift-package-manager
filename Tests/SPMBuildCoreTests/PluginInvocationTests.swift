/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basics
import PackageGraph
import PackageLoading
import PackageModel
@testable import SPMBuildCore
import SPMTestSupport
import TSCBasic
import TSCUtility
import Workspace
import XCTest

class PluginInvocationTests: XCTestCase {

    func testBasics() throws {
        // Construct a canned file system and package graph with a single package and a library that uses a plugin that uses a tool.
        let fileSystem = InMemoryFileSystem(emptyFiles:
            "/Foo/Plugins/FooPlugin/source.swift",
            "/Foo/Sources/FooTool/source.swift",
            "/Foo/Sources/Foo/source.swift",
            "/Foo/Sources/Foo/SomeFile.abc"
        )
        let observability = ObservabilitySystem.makeForTesting()
        let graph = try loadPackageGraph(
            fs: fileSystem,
            manifests: [
                Manifest.createRootManifest(
                    name: "Foo",
                    path: .init("/Foo"),
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
                            dependencies: [],
                            type: .executable
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
            graph.check(targets: "Foo", "FooPlugin", "FooTool")
            graph.checkTarget("Foo") { target in
                target.check(dependencies: "FooPlugin")
            }
            graph.checkTarget("FooPlugin") { target in
                target.check(type: .plugin)
                target.check(dependencies: "FooTool")
            }
            graph.checkTarget("FooTool") { target in
                target.check(type: .executable)
            }
        }

        // A fake PluginScriptRunner that just checks the input conditions and returns canned output.
        struct MockPluginScriptRunner: PluginScriptRunner {
            var hostTriple: Triple {
                return UserToolchain.default.triple
            }
            func runPluginScript(
                sources: Sources,
                inputJSON: Data,
                toolsVersion: ToolsVersion,
                writableDirectories: [AbsolutePath],
                observabilityScope: ObservabilityScope,
                fileSystem: FileSystem
            ) throws -> (outputJSON: Data, stdoutText: Data) {
                // Check that we were given the right sources.
                XCTAssertEqual(sources.root, AbsolutePath("/Foo/Plugins/FooPlugin"))
                XCTAssertEqual(sources.relativePaths, [RelativePath("source.swift")])

                // Deserialize and check the input.
                let decoder = JSONDecoder()
                let context = try decoder.decode(PluginScriptRunnerInput.self, from: inputJSON)
                XCTAssertEqual(context.products.count, 2, "unexpected products: \(dump(context.products))")
                XCTAssertEqual(context.products[0].name, "Foo", "unexpected products: \(dump(context.products))")
                XCTAssertEqual(context.products[0].targetIds.count, 1, "unexpected product targets: \(dump(context.products[0].targetIds))")
                XCTAssertEqual(context.products[1].name, "FooTool", "unexpected products: \(dump(context.products))")
                XCTAssertEqual(context.products[1].targetIds.count, 1, "unexpected product targets: \(dump(context.products[1].targetIds))")
                XCTAssertEqual(context.targets.count, 2, "unexpected targets: \(dump(context.targets))")
                XCTAssertEqual(context.targets[0].name, "Foo", "unexpected targets: \(dump(context.targets))")
                XCTAssertEqual(context.targets[0].dependencies.count, 0, "unexpected target dependencies: \(dump(context.targets[0].dependencies))")
                XCTAssertEqual(context.targets[1].name, "FooTool", "unexpected targets: \(dump(context.targets))")
                XCTAssertEqual(context.targets[1].dependencies.count, 0, "unexpected target dependencies: \(dump(context.targets[1].dependencies))")

                // Emit and return a serialized output PluginInvocationResult JSON.
                let encoder = JSONEncoder()
                let result = PluginScriptRunnerOutput(
                    diagnostics: [
                        .init(
                            severity: .warning,
                            message: "A warning",
                            file: "/Foo/Sources/Foo/SomeFile.abc",
                            line: 42
                        )
                    ],
                    buildCommands: [
                        .init(
                            displayName: "Do something",
                            executable: "/bin/FooTool",
                            arguments: ["-c", "/Foo/Sources/Foo/SomeFile.abc"],
                            environment: [
                                "X": "Y"
                            ],
                            workingDirectory: "/Foo/Sources/Foo",
                            inputFiles: [],
                            outputFiles: []
                        )
                    ],
                    prebuildCommands: [
                    ]
                )
                let outputJSON = try encoder.encode(result)
                return (outputJSON: outputJSON, stdoutText: "Hello Plugin!".data(using: .utf8)!)
            }
        }

        // Construct a canned input and run plugins using our MockPluginScriptRunner().
        let outputDir = AbsolutePath("/Foo/.build")
        let builtToolsDir = AbsolutePath("/Foo/.build/debug")
        let pluginRunner = MockPluginScriptRunner()
        let results = try graph.invokePlugins(
            outputDir: outputDir,
            builtToolsDir: builtToolsDir,
            buildEnvironment: BuildEnvironment(platform: .macOS, configuration: .debug),
            pluginScriptRunner: pluginRunner,
            observabilityScope: observability.topScope,
            fileSystem: fileSystem
        )

        // Check the canned output to make sure nothing was lost in transport.
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertEqual(results.count, 1)
        let (evalTarget, evalResults) = try XCTUnwrap(results.first)
        XCTAssertEqual(evalTarget.name, "Foo")

        XCTAssertEqual(evalResults.count, 1)
        let evalFirstResult = try XCTUnwrap(evalResults.first)
        XCTAssertEqual(evalFirstResult.prebuildCommands.count, 0)
        XCTAssertEqual(evalFirstResult.buildCommands.count, 1)
        let evalFirstCommand = try XCTUnwrap(evalFirstResult.buildCommands.first)
        XCTAssertEqual(evalFirstCommand.configuration.displayName, "Do something")
        XCTAssertEqual(evalFirstCommand.configuration.executable, "/bin/FooTool")
        XCTAssertEqual(evalFirstCommand.configuration.arguments, ["-c", "/Foo/Sources/Foo/SomeFile.abc"])
        XCTAssertEqual(evalFirstCommand.configuration.environment, ["X": "Y"])
        XCTAssertEqual(evalFirstCommand.configuration.workingDirectory, AbsolutePath("/Foo/Sources/Foo"))
        XCTAssertEqual(evalFirstCommand.inputFiles, [])
        XCTAssertEqual(evalFirstCommand.outputFiles, [])

        XCTAssertEqual(evalFirstResult.diagnostics.count, 1)
        let evalFirstDiagnostic = try XCTUnwrap(evalFirstResult.diagnostics.first)
        XCTAssertEqual(evalFirstDiagnostic.severity, .warning)
        XCTAssertEqual(evalFirstDiagnostic.message, "A warning")
        XCTAssertEqual(evalFirstDiagnostic.metadata?.fileLocation, FileLocation(.init("/Foo/Sources/Foo/SomeFile.abc"), line: 42))

        XCTAssertEqual(evalFirstResult.textOutput, "Hello Plugin!")
    }
    
    func testCompilationDiagnostics() throws {
        try testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target and a plugin.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.writeFileContents(packageDir.appending(component: "Package.swift")) {
                $0 <<< """
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
                """
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "Sources", "MyLibrary", "library.swift")) {
                $0 <<< "public func Foo() { }\n"
            }
            try localFileSystem.writeFileContents(packageDir.appending(components: "Plugins", "MyPlugin", "plugin.swift")) {
                $0 <<< "syntax error\n"
            }

            // Load a workspace from the package.
            let observability = ObservabilitySystem.makeForTesting()
            let workspace = try Workspace(
                fileSystem: localFileSystem,
                location: .init(forRootPackage: packageDir, fileSystem: localFileSystem),
                customManifestLoader: ManifestLoader(toolchain: ToolchainConfiguration.default),
                delegate: MockWorkspaceDelegate()
            )
            
            // Load the root manifest.
            let rootInput = PackageGraphRootInput(packages: [packageDir], dependencies: [])
            let rootManifests = try tsc_await {
                workspace.loadRootManifests(
                    packages: rootInput.packages,
                    observabilityScope: observability.topScope,
                    completion: $0
                )
            }
            XCTAssert(rootManifests.count == 1, "\(rootManifests)")

            // Load the package graph.
            let packageGraph = try workspace.loadPackageGraph(rootInput: rootInput, observabilityScope: observability.topScope)
            XCTAssert(observability.diagnostics.isEmpty, "\(observability.diagnostics)")
            XCTAssert(packageGraph.packages.count == 1, "\(packageGraph.packages)")
            
            // Find the build tool plugin.
            let buildToolPlugin = try XCTUnwrap(packageGraph.packages[0].targets.first{ $0.type == .plugin })
            XCTAssertEqual(buildToolPlugin.name, "MyPlugin")
            
            let pluginCacheDir = tmpPath.appending(component: "plugin-cache")
            let pluginScriptRunner = DefaultPluginScriptRunner(cacheDir: pluginCacheDir, toolchain: ToolchainConfiguration.default)
            let result = try pluginScriptRunner.compilePluginScript(sources: buildToolPlugin.sources, toolsVersion: .currentToolsVersion)
            
            // Expect a failure since our input code is intentionally broken.
            XCTAssert(result.compilerResult.exitStatus == .terminated(code: 1), "\(result.compilerResult.exitStatus)")
            XCTAssert(result.compiledExecutable == .none, "\(result.compiledExecutable?.pathString ?? "-")")
            XCTAssert(result.diagnosticsFile.suffix == ".dia", "\(result.diagnosticsFile.pathString)")
        }
    }
}
