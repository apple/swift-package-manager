//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageGraph
import PackageLoading
import PackageModel
@testable import SPMBuildCore
import SPMTestSupport
import Workspace
import XCTest

class PluginTests: XCTestCase {
    
    func testUseOfBuildToolPluginTargetByExecutableInSamePackage() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try fixture(name: "Miscellaneous/Plugins") { fixturePath in
            let (stdout, _) = try executeSwiftBuild(fixturePath.appending("MySourceGenPlugin"), configuration: .Debug, extraArgs: ["--product", "MyLocalTool"])
            XCTAssert(stdout.contains("Linking MySourceGenBuildTool"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Generating foo.swift from foo.dat"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Linking MyLocalTool"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Build complete!"), "stdout:\n\(stdout)")
        }
    }

    func testUseOfBuildToolPluginProductByExecutableAcrossPackages() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try fixture(name: "Miscellaneous/Plugins") { fixturePath in
            let (stdout, _) = try executeSwiftBuild(fixturePath.appending("MySourceGenClient"), configuration: .Debug, extraArgs: ["--product", "MyTool"])
            XCTAssert(stdout.contains("Linking MySourceGenBuildTool"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Generating foo.swift from foo.dat"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Linking MyTool"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Build complete!"), "stdout:\n\(stdout)")
        }
    }

    func testUseOfPrebuildPluginTargetByExecutableAcrossPackages() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try fixture(name: "Miscellaneous/Plugins") { fixturePath in
            let (stdout, _) = try executeSwiftBuild(fixturePath.appending("MySourceGenPlugin"), configuration: .Debug, extraArgs: ["--product", "MyOtherLocalTool"])
            XCTAssert(stdout.contains("Compiling MyOtherLocalTool bar.swift"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Compiling MyOtherLocalTool baz.swift"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Linking MyOtherLocalTool"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Build complete!"), "stdout:\n\(stdout)")
        }
    }

    func testUseOfPluginWithInternalExecutable() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        
        try fixture(name: "Miscellaneous/Plugins") { fixturePath in
            let (stdout, _) = try executeSwiftBuild(fixturePath.appending("ClientOfPluginWithInternalExecutable"))
            XCTAssert(stdout.contains("Compiling PluginExecutable main.swift"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Linking PluginExecutable"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Generating foo.swift from foo.dat"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Compiling RootTarget foo.swift"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Linking RootTarget"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Build complete!"), "stdout:\n\(stdout)")
        }
    }

    func testInternalExecutableAvailableOnlyToPlugin() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try fixture(name: "Miscellaneous/Plugins") { fixturePath in
            XCTAssertThrowsCommandExecutionError(try executeSwiftBuild(fixturePath.appending("InvalidUseOfInternalPluginExecutable")), "Illegally used internal executable") { error in
                XCTAssert(
                    error.stderr.contains("product 'PluginExecutable' required by package 'invaliduseofinternalpluginexecutable' target 'RootTarget' not found in package 'PluginWithInternalExecutable'."), "stderr:\n\(error.stderr)"
                )
            }
        }
    }
    
    func testLocalBuildToolPluginUsingRemoteExecutable() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        
        try fixture(name: "Miscellaneous/Plugins") { fixturePath in
            let (stdout, _) = try executeSwiftBuild(fixturePath.appending("LibraryWithLocalBuildToolPluginUsingRemoteTool"))
            XCTAssert(stdout.contains("Compiling MySourceGenBuildTool main.swift"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Linking MySourceGenBuildTool"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Generating generated.swift from generated.dat"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Compiling MyLibrary generated.swift"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Build complete!"), "stdout:\n\(stdout)")
        }
    }
    
    func testBuildToolPluginDependencies() throws {        
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        
        try fixture(name: "Miscellaneous/Plugins") { fixturePath in
            let (stdout, _) = try executeSwiftBuild(fixturePath.appending("MyBuildToolPluginDependencies"))
            XCTAssert(stdout.contains("Compiling MySourceGenBuildTool main.swift"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Linking MySourceGenBuildTool"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Generating foo.swift from foo.dat"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Compiling MyLocalTool foo.swift"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Build complete!"), "stdout:\n\(stdout)")
        }
    }

    func testContrivedTestCases() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try fixture(name: "Miscellaneous/Plugins") { fixturePath in
            let (stdout, _) = try executeSwiftBuild(fixturePath.appending("ContrivedTestPlugin"), configuration: .Debug, extraArgs: ["--product", "MyLocalTool"])
            XCTAssert(stdout.contains("Linking MySourceGenBuildTool"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Generating foo.swift from foo.dat"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Linking MyLocalTool"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Build complete!"), "stdout:\n\(stdout)")
        }
    }

    func testPluginScriptSandbox() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        try fixture(name: "Miscellaneous/Plugins") { fixturePath in
            let (stdout, _) = try executeSwiftBuild(fixturePath.appending("SandboxTesterPlugin"), configuration: .Debug, extraArgs: ["--product", "MyLocalTool"])
            XCTAssert(stdout.contains("Linking MyLocalTool"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Build complete!"), "stdout:\n\(stdout)")
        }
    }

    func testUseOfVendedBinaryTool() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        try fixture(name: "Miscellaneous/Plugins") { fixturePath in
            let (stdout, _) = try executeSwiftBuild(fixturePath.appending("MyBinaryToolPlugin"), configuration: .Debug, extraArgs: ["--product", "MyLocalTool"])
            XCTAssert(stdout.contains("Linking MyLocalTool"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Build complete!"), "stdout:\n\(stdout)")
        }
    }

    func testUseOfBinaryToolVendedAsProduct() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        try fixture(name: "Miscellaneous/Plugins") { fixturePath in
            let (stdout, _) = try executeSwiftBuild(fixturePath.appending("BinaryToolProductPlugin"), configuration: .Debug, extraArgs: ["--product", "MyLocalTool"])
            XCTAssert(stdout.contains("Linking MyLocalTool"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Build complete!"), "stdout:\n\(stdout)")
        }
    }
    
    func testCommandPluginInvocation() throws {
        try XCTSkipIf(true, "test is disabled because it isn't stable, see rdar://117870608")

        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        
        // FIXME: This test is getting quite long — we should add some support functionality for creating synthetic plugin tests and factor this out into separate tests.
        try testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a library target and a plugin. It depends on a sample package.
            let packageDir = tmpPath.appending(components: "MyPackage")
            let manifestFile = packageDir.appending("Package.swift")
            try localFileSystem.createDirectory(manifestFile.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(
                manifestFile,
                string: """
                // swift-tools-version: 5.6
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    dependencies: [
                        .package(name: "HelperPackage", path: "VendoredDependencies/HelperPackage")
                    ],
                    targets: [
                        .target(
                            name: "MyLibrary",
                            dependencies: [
                                .product(name: "HelperLibrary", package: "HelperPackage")
                            ]
                        ),
                        .plugin(
                            name: "PluginPrintingInfo",
                            capability: .command(
                                intent: .custom(verb: "print-info", description: "Description of the command"),
                                permissions: [.writeToPackageDirectory(reason: "Reason for wanting to write to package directory")]
                            )
                        ),
                        .plugin(
                            name: "PluginFailingWithError",
                            capability: .command(
                                intent: .custom(verb: "fail-with-error", description: "Sample plugin that throws an error")
                            )
                        ),
                        .plugin(
                            name: "PluginFailingWithoutError",
                            capability: .command(
                                intent: .custom(verb: "fail-without-error", description: "Sample plugin that exits without error")
                            )
                        ),
                        .plugin(
                            name: "NeverendingPlugin",
                            capability: .command(
                                intent: .custom(verb: "neverending-plugin", description: "A plugin that doesn't end running")
                            )
                        ),
                    ]
                )
                """
            )
            let librarySourceFile = packageDir.appending(components: "Sources", "MyLibrary", "library.swift")
            try localFileSystem.createDirectory(librarySourceFile.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(
                librarySourceFile,
                string: """
                public func Foo() { }
                """
            )
            let printingPluginSourceFile = packageDir.appending(components: "Plugins", "PluginPrintingInfo", "plugin.swift")
            try localFileSystem.createDirectory(printingPluginSourceFile.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(
                printingPluginSourceFile,
                string: """
                import PackagePlugin
                @main struct MyCommandPlugin: CommandPlugin {
                    func performCommand(
                        context: PluginContext,
                        arguments: [String]
                    ) throws {
                        // Check the identity of the root packages.
                        print("Root package is \\(context.package.displayName).")

                        // Check that we can find a tool in the toolchain.
                        let swiftc = try context.tool(named: "swiftc")
                        print("Found the swiftc tool at \\(swiftc.path).")
                    }
                }
                """
            )
            let pluginFailingWithErrorSourceFile = packageDir.appending(components: "Plugins", "PluginFailingWithError", "plugin.swift")
            try localFileSystem.createDirectory(pluginFailingWithErrorSourceFile.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(
                pluginFailingWithErrorSourceFile,
                string: """
                import PackagePlugin
                @main struct MyCommandPlugin: CommandPlugin {
                    func performCommand(
                        context: PluginContext,
                        arguments: [String]
                    ) throws {
                        // Print some output that should appear before the error diagnostic.
                        print("This text should appear before the uncaught thrown error.")

                        // Throw an uncaught error that should be reported as a diagnostics.
                        throw "This is the uncaught thrown error."
                    }
                }
                extension String: Error { }
                """
            )
            let pluginFailingWithoutErrorSourceFile = packageDir.appending(components: "Plugins", "PluginFailingWithoutError", "plugin.swift")
            try localFileSystem.createDirectory(pluginFailingWithoutErrorSourceFile.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(
                pluginFailingWithoutErrorSourceFile,
                string: """
                import PackagePlugin
                import Foundation
                @main struct MyCommandPlugin: CommandPlugin {
                    func performCommand(
                        context: PluginContext,
                        arguments: [String]
                    ) throws {
                        // Print some output that should appear before we exit.
                        print("This text should appear before we exit.")

                        // Just exit with an error code without an emitting error.
                        exit(1)
                    }
                }
                extension String: Error { }
                """
            )
            let neverendingPluginSourceFile = packageDir.appending(components: "Plugins", "NeverendingPlugin", "plugin.swift")
            try localFileSystem.createDirectory(neverendingPluginSourceFile.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(
                neverendingPluginSourceFile,
                string: """
                import PackagePlugin
                import Foundation
                @main struct MyCommandPlugin: CommandPlugin {
                    func performCommand(
                        context: PluginContext,
                        arguments: [String]
                    ) throws {
                        // Print some output that should appear before we exit.
                        print("This text should appear before we exit.")

                        // Just exit with an error code without an emitting error.
                        exit(1)
                    }
                }
                extension String: Error { }
                """
            )

            // Create the sample vendored dependency package.
            let library1Path = packageDir.appending(components: "VendoredDependencies", "HelperPackage", "Package.swift")
            try localFileSystem.createDirectory(library1Path.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(
                library1Path,
                string: """
                // swift-tools-version: 5.5
                import PackageDescription
                let package = Package(
                    name: "HelperPackage",
                    products: [
                        .library(
                            name: "HelperLibrary",
                            targets: ["HelperLibrary"]
                        ),
                    ],
                    targets: [
                        .target(
                            name: "HelperLibrary"
                        ),
                    ]
                )
                """
            )

            let library2Path = packageDir.appending(components: "VendoredDependencies", "HelperPackage", "Sources", "HelperLibrary", "library.swift")
            try localFileSystem.createDirectory(library2Path.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(
                library2Path,
                string: """
                public func Bar() { }
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
            let rootManifests = try temp_await {
                workspace.loadRootManifests(
                    packages: rootInput.packages,
                    observabilityScope: observability.topScope,
                    completion: $0
                )
            }
            XCTAssert(rootManifests.count == 1, "\(rootManifests)")

            // Load the package graph.
            let packageGraph = try workspace.loadPackageGraph(rootInput: rootInput, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssert(packageGraph.packages.count == 2, "\(packageGraph.packages)")
            XCTAssert(packageGraph.rootPackages.count == 1, "\(packageGraph.rootPackages)")
            let package = try XCTUnwrap(packageGraph.rootPackages.first)
            
            // Find the regular target in our test package.
            let libraryTarget = try XCTUnwrap(package.targets.map(\.underlyingTarget).first{ $0.name == "MyLibrary" } as? SwiftTarget)
            XCTAssertEqual(libraryTarget.type, .library)
            
            // Set up a delegate to handle callbacks from the command plugin.
            let delegateQueue = DispatchQueue(label: "plugin-invocation")
            class PluginDelegate: PluginInvocationDelegate {
                let delegateQueue: DispatchQueue
                var diagnostics: [Basics.Diagnostic] = []

                init(delegateQueue: DispatchQueue) {
                    self.delegateQueue = delegateQueue
                }
                
                func pluginCompilationStarted(commandLine: [String], environment: EnvironmentVariables) {
                }
                
                func pluginCompilationEnded(result: PluginCompilationResult) {
                }
                    
                func pluginCompilationWasSkipped(cachedResult: PluginCompilationResult) {
                }

                func pluginEmittedOutput(_ data: Data) {
                    // Add each line of emitted output as a `.info` diagnostic.
                    dispatchPrecondition(condition: .onQueue(delegateQueue))
                    let textlines = String(decoding: data, as: UTF8.self).split(separator: "\n")
                    print(textlines.map{ "[TEXT] \($0)" }.joined(separator: "\n"))
                    diagnostics.append(contentsOf: textlines.map{
                        Basics.Diagnostic(severity: .info, message: String($0), metadata: .none)
                    })
                }
                
                func pluginEmittedDiagnostic(_ diagnostic: Basics.Diagnostic) {
                    // Add the diagnostic as-is.
                    dispatchPrecondition(condition: .onQueue(delegateQueue))
                    print("[DIAG] \(diagnostic)")
                    diagnostics.append(diagnostic)
                }
            }

            // Helper function to invoke a plugin with given input and to check its outputs.
            func testCommand(
                package: ResolvedPackage,
                plugin pluginName: String,
                targets targetNames: [String],
                arguments: [String],
                toolNamesToPaths: [String: AbsolutePath] = [:],
                file: StaticString = #file,
                line: UInt = #line,
                expectFailure: Bool = false,
                diagnosticsChecker: (DiagnosticsTestResult) throws -> Void
            ) {
                // Find the named plugin.
                let plugins = package.targets.compactMap{ $0.underlyingTarget as? PluginTarget }
                guard let plugin = plugins.first(where: { $0.name == pluginName }) else {
                    return XCTFail("There is no plugin target named ‘\(pluginName)’")
                }
                XCTAssertTrue(plugin.type == .plugin, "Target \(plugin) isn’t a plugin")

                // Find the named input targets to the plugin.
                var targets: [ResolvedTarget] = []
                for targetName in targetNames {
                    guard let target = package.targets.first(where: { $0.underlyingTarget.name == targetName }) else {
                        return XCTFail("There is no target named ‘\(targetName)’")
                    }
                    XCTAssertTrue(target.type != .plugin, "Target \(target) is a plugin")
                    targets.append(target)
                }

                let pluginDir = tmpPath.appending(components: package.identity.description, plugin.name)
                let delegate = PluginDelegate(delegateQueue: delegateQueue)
                do {
                    let scriptRunner = DefaultPluginScriptRunner(
                        fileSystem: localFileSystem,
                        cacheDir: pluginDir.appending("cache"),
                        toolchain: try UserToolchain.default
                    )

                    let toolSearchDirectories = [try UserToolchain.default.swiftCompilerPath.parentDirectory]
                    let success = try temp_await { plugin.invoke(
                        action: .performCommand(package: package, arguments: arguments),
                        buildEnvironment: BuildEnvironment(platform: .macOS, configuration: .debug),
                        scriptRunner: scriptRunner,
                        workingDirectory: package.path,
                        outputDirectory: pluginDir.appending("output"),
                        toolSearchDirectories: toolSearchDirectories,
                        accessibleTools: [:],
                        writableDirectories: [pluginDir.appending("output")],
                        readOnlyDirectories: [package.path],
                        allowNetworkConnections: [],
                        pkgConfigDirectories: [],
                        sdkRootPath: nil,
                        fileSystem: localFileSystem,
                        observabilityScope: observability.topScope,
                        callbackQueue: delegateQueue,
                        delegate: delegate,
                        completion: $0) }
                    if expectFailure {
                        XCTAssertFalse(success, "expected command to fail, but it succeeded", file: file, line: line)
                    }
                    else {
                        XCTAssertTrue(success, "expected command to succeed, but it failed", file: file, line: line)
                    }
                }
                catch {
                    XCTFail("error \(String(describing: error))", file: file, line: line)
                }
                
                // Check that we didn't end up with any completely empty diagnostics.
                XCTAssertNil(observability.diagnostics.first{ $0.message.isEmpty })

                // Invoke the diagnostics checker for the plugin output.
                testDiagnostics(delegate.diagnostics, problemsOnly: false, file: file, line: line, handler: diagnosticsChecker)
            }

            // Invoke the command plugin that prints out various things it was given, and check them.
            testCommand(package: package, plugin: "PluginPrintingInfo", targets: ["MyLibrary"], arguments: ["veni", "vidi", "vici"]) { output in
                output.check(diagnostic: .equal("Root package is MyPackage."), severity: .info)
                output.check(diagnostic: .and(.prefix("Found the swiftc tool"), .suffix(".")), severity: .info)
            }

            // Invoke the command plugin that throws an unhandled error at the top level.
            testCommand(package: package, plugin: "PluginFailingWithError", targets: [], arguments: [], expectFailure: true) { output in
                output.check(diagnostic: .equal("This text should appear before the uncaught thrown error."), severity: .info)
                output.check(diagnostic: .equal("This is the uncaught thrown error."), severity: .error)

            }
            // Invoke the command plugin that exits with code 1 without returning an error.
            testCommand(package: package, plugin: "PluginFailingWithoutError", targets: [], arguments: [], expectFailure: true) { output in
                output.check(diagnostic: .equal("This text should appear before we exit."), severity: .info)
                output.check(diagnostic: .equal("Plugin ended with exit code 1"), severity: .error)
            }
        }
    }

    func testLocalAndRemoteToolDependencies() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try fixture(name: "Miscellaneous/Plugins/PluginUsingLocalAndRemoteTool") { path in
            let (stdout, stderr) = try executeSwiftPackage(path.appending("MyLibrary"), configuration: .Debug, extraArgs: ["plugin", "my-plugin"])
            XCTAssert(stderr.contains("Linking RemoteTool"), "stdout:\n\(stderr)\n\(stdout)")
            XCTAssert(stderr.contains("Linking LocalTool"), "stdout:\n\(stderr)\n\(stdout)")
            XCTAssert(stderr.contains("Linking ImpliedLocalTool"), "stdout:\n\(stderr)\n\(stdout)")
            XCTAssert(stderr.contains("Build complete!"), "stdout:\n\(stderr)\n\(stdout)")
            XCTAssert(stdout.contains("A message from the remote tool."), "stdout:\n\(stderr)\n\(stdout)")
            XCTAssert(stdout.contains("A message from the local tool."), "stdout:\n\(stderr)\n\(stdout)")
            XCTAssert(stdout.contains("A message from the implied local tool."), "stdout:\n\(stderr)\n\(stdout)")
        }
    }

    func testPluginUsageDoesntAffectTestTargetMappings() throws {
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try fixture(name: "Miscellaneous/Plugins/MySourceGenPlugin") { packageDir in
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
            let rootManifests = try temp_await {
                workspace.loadRootManifests(
                    packages: rootInput.packages,
                    observabilityScope: observability.topScope,
                    completion: $0
                )
            }
            XCTAssert(rootManifests.count == 1, "\(rootManifests)")

            // Load the package graph.
            let packageGraph = try workspace.loadPackageGraph(rootInput: rootInput, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)

            // Make sure that the use of plugins doesn't bleed into the use of plugins by tools.
            let testTargetMappings = try packageGraph.computeTestTargetsForExecutableTargets()
            for (target, testTargets) in testTargetMappings {
                XCTAssertFalse(testTargets.contains{ $0.name == "MySourceGenPluginTests" }, "target: \(target), testTargets: \(testTargets)")
            }
        }
    }

    func testCommandPluginCancellation() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")
        
        try testWithTemporaryDirectory { tmpPath in
            // Create a sample package with a couple of plugins a other targets and products.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(
                packageDir.appending(components: "Package.swift"),
                string: """
                // swift-tools-version: 5.6
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    products: [
                        .library(
                            name: "MyLibrary",
                            targets: ["MyLibrary"]
                        ),
                    ],
                    targets: [
                        .target(
                            name: "MyLibrary"
                        ),
                        .plugin(
                            name: "NeverendingPlugin",
                            capability: .command(
                                intent: .custom(verb: "neverending-plugin", description: "Help description")
                            )
                        ),
                    ]
                )
                """
            )
            let myLibraryTargetDir = packageDir.appending(components: "Sources", "MyLibrary")
            try localFileSystem.createDirectory(myLibraryTargetDir, recursive: true)
            try localFileSystem.writeFileContents(
                myLibraryTargetDir.appending("library.swift"),
                string: """
                public func GetGreeting() -> String { return "Hello" }
                """
            )
            let neverendingPluginTargetDir = packageDir.appending(components: "Plugins", "NeverendingPlugin")
            try localFileSystem.createDirectory(neverendingPluginTargetDir, recursive: true)
            try localFileSystem.writeFileContents(
                neverendingPluginTargetDir.appending("plugin.swift"),
                string: """
                import PackagePlugin
                import Foundation
                @main struct NeverendingPlugin: CommandPlugin {
                    func performCommand(
                        context: PluginContext,
                        arguments: [String]
                    ) throws {
                        print("pid: \\(ProcessInfo.processInfo.processIdentifier)")
                        while true {
                            Thread.sleep(forTimeInterval: 1.0)
                            print("still here")
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
            let rootManifests = try temp_await {
                workspace.loadRootManifests(
                    packages: rootInput.packages,
                    observabilityScope: observability.topScope,
                    completion: $0
                )
            }
            XCTAssert(rootManifests.count == 1, "\(rootManifests)")

            // Load the package graph.
            let packageGraph = try workspace.loadPackageGraph(rootInput: rootInput, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssert(packageGraph.packages.count == 1, "\(packageGraph.packages)")
            XCTAssert(packageGraph.rootPackages.count == 1, "\(packageGraph.rootPackages)")
            let package = try XCTUnwrap(packageGraph.rootPackages.first)
            
            // Find the regular target in our test package.
            let libraryTarget = try XCTUnwrap(package.targets.map(\.underlyingTarget).first{ $0.name == "MyLibrary" } as? SwiftTarget)
            XCTAssertEqual(libraryTarget.type, .library)
            
            // Set up a delegate to handle callbacks from the command plugin.  In particular we want to know the process identifier.
            let delegateQueue = DispatchQueue(label: "plugin-invocation")
            class PluginDelegate: PluginInvocationDelegate {
                let delegateQueue: DispatchQueue
                var diagnostics: [Basics.Diagnostic] = []
                var parsedProcessIdentifier: Int? = .none

                init(delegateQueue: DispatchQueue) {
                    self.delegateQueue = delegateQueue
                }
                
                func pluginCompilationStarted(commandLine: [String], environment: EnvironmentVariables) {
                }
                
                func pluginCompilationEnded(result: PluginCompilationResult) {
                }
                    
                func pluginCompilationWasSkipped(cachedResult: PluginCompilationResult) {
                }
                
                func pluginEmittedOutput(_ data: Data) {
                    // Add each line of emitted output as a `.info` diagnostic.
                    dispatchPrecondition(condition: .onQueue(delegateQueue))
                    let textlines = String(decoding: data, as: UTF8.self).split(separator: "\n")
                    diagnostics.append(contentsOf: textlines.map{
                        Basics.Diagnostic(severity: .info, message: String($0), metadata: .none)
                    })
                    
                    // If we don't already have the process identifier, we try to find it.
                    if parsedProcessIdentifier == .none {
                        func parseProcessIdentifier(_ string: String) -> Int? {
                            guard let match = try? NSRegularExpression(pattern: "pid: (\\d+)", options: []).firstMatch(in: string, options: [], range: NSRange(location: 0, length: string.count)) else { return .none }
                            // We have a match, so extract the process identifier.
                            assert(match.numberOfRanges == 2)
                            return Int((string as NSString).substring(with: match.range(at: 1)))
                        }
                        parsedProcessIdentifier = textlines.compactMap{ parseProcessIdentifier(String($0)) }.first
                    }
                }
                
                func pluginEmittedDiagnostic(_ diagnostic: Basics.Diagnostic) {
                    // Add the diagnostic as-is.
                    dispatchPrecondition(condition: .onQueue(delegateQueue))
                    diagnostics.append(diagnostic)
                }
            }

            // Find the relevant plugin.
            let plugins = package.targets.compactMap{ $0.underlyingTarget as? PluginTarget }
            guard let plugin = plugins.first(where: { $0.name == "NeverendingPlugin" }) else {
                return XCTFail("There is no plugin target named ‘NeverendingPlugin’")
            }
            XCTAssertTrue(plugin.type == .plugin, "Target \(plugin) isn’t a plugin")

            // Run the plugin.
            let pluginDir = tmpPath.appending(components: package.identity.description, plugin.name)
            let scriptRunner = DefaultPluginScriptRunner(
                fileSystem: localFileSystem,
                cacheDir: pluginDir.appending("cache"),
                toolchain: try UserToolchain.default
            )
            let delegate = PluginDelegate(delegateQueue: delegateQueue)
            let sync = DispatchSemaphore(value: 0)
            plugin.invoke(
                action: .performCommand(package: package, arguments: []),
                buildEnvironment: BuildEnvironment(platform: .macOS, configuration: .debug),
                scriptRunner: scriptRunner,
                workingDirectory: package.path,
                outputDirectory: pluginDir.appending("output"),
                toolSearchDirectories: [try UserToolchain.default.swiftCompilerPath.parentDirectory],
                accessibleTools: [:],
                writableDirectories: [pluginDir.appending("output")],
                readOnlyDirectories: [package.path],
                allowNetworkConnections: [],
                pkgConfigDirectories: [],
                sdkRootPath: try UserToolchain.default.sdkRootPath,
                fileSystem: localFileSystem,
                observabilityScope: observability.topScope,
                callbackQueue: delegateQueue,
                delegate: delegate,
                completion: { _ in
                    sync.signal()
                }
            )
            
            // Wait for three seconds.
            let result = sync.wait(timeout: .now() + 3)
            XCTAssertEqual(result, .timedOut, "expected the plugin to time out")
            
            // At this point we should have parsed out the process identifier. But it's possible we don't always — this is being investigated in rdar://88792829.
            var pid: Int? = .none
            delegateQueue.sync {
                pid = delegate.parsedProcessIdentifier
            }
            guard let pid else {
                throw XCTSkip("skipping test because no pid was received from the plugin; being investigated as rdar://88792829\n\(delegate.diagnostics.description)")
            }
            
            // Check that it's running (we do this by asking for its priority — this only works on some platforms).
            #if os(macOS)
            errno = 0
            getpriority(Int32(PRIO_PROCESS), UInt32(pid))
            XCTAssertEqual(errno, 0, "unexpectedly got errno \(errno) when trying to check process \(pid)")
            #endif
            
            // Ask the plugin running to cancel all plugins.
            try scriptRunner.cancel(deadline: .now() + .seconds(5))
            
            // Check that it's no longer running (we do this by asking for its priority — this only works on some platforms).
            #if os(macOS)
            errno = 0
            getpriority(Int32(PRIO_PROCESS), UInt32(pid))
            XCTAssertEqual(errno, ESRCH, "unexpectedly got errno \(errno) when trying to check process \(pid)")
            #endif
        }
    }

    func testUnusedPluginProductWarnings() throws {
        // Test the warnings we get around unused plugin products in package dependencies.
        try testWithTemporaryDirectory { tmpPath in
            // Create a sample package that uses three packages that vend plugins.
            let packageDir = tmpPath.appending(components: "MyPackage")
            try localFileSystem.createDirectory(packageDir, recursive: true)
            try localFileSystem.writeFileContents(
                packageDir.appending("Package.swift"),
                string: """
                // swift-tools-version: 5.6
                import PackageDescription
                let package = Package(
                    name: "MyPackage",
                    dependencies: [
                        .package(name: "BuildToolPluginPackage", path: "VendoredDependencies/BuildToolPluginPackage"),
                        .package(name: "UnusedBuildToolPluginPackage", path: "VendoredDependencies/UnusedBuildToolPluginPackage"),
                        .package(name: "CommandPluginPackage", path: "VendoredDependencies/CommandPluginPackage")
                    ],
                    targets: [
                        .target(
                            name: "MyLibrary",
                            path: ".",
                            plugins: [
                                .plugin(name: "BuildToolPlugin", package: "BuildToolPluginPackage")
                            ]
                        ),
                    ]
                )
                """
            )
            try localFileSystem.writeFileContents(
                packageDir.appending("Library.swift"),
                string: """
                public var Foo: String
                """
            )

            // Create the depended-upon package that vends a build tool plugin that is used by the main package.
            let buildToolPluginPackageDir = packageDir.appending(components: "VendoredDependencies", "BuildToolPluginPackage")
            try localFileSystem.createDirectory(buildToolPluginPackageDir, recursive: true)
            try localFileSystem.writeFileContents(
                buildToolPluginPackageDir.appending("Package.swift"),
                string: """
                // swift-tools-version: 5.6
                import PackageDescription
                let package = Package(
                    name: "BuildToolPluginPackage",
                    products: [
                        .plugin(
                            name: "BuildToolPlugin",
                            targets: ["BuildToolPlugin"])
                    ],
                    targets: [
                        .plugin(
                            name: "BuildToolPlugin",
                            capability: .buildTool(),
                            path: ".")
                    ]
                )
                """
            )
            try localFileSystem.writeFileContents(
                buildToolPluginPackageDir.appending("Plugin.swift"),
                string: """
                import PackagePlugin
                @main struct MyPlugin: BuildToolPlugin {
                    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
                        return []
                    }
                }
                """
            )

            // Create the depended-upon package that vends a build tool plugin that is not used by the main package.
            let unusedBuildToolPluginPackageDir = packageDir.appending(components: "VendoredDependencies", "UnusedBuildToolPluginPackage")
            try localFileSystem.createDirectory(unusedBuildToolPluginPackageDir, recursive: true)
            try localFileSystem.writeFileContents(
                unusedBuildToolPluginPackageDir.appending("Package.swift"),
                string: """
                // swift-tools-version: 5.6
                import PackageDescription
                let package = Package(
                    name: "UnusedBuildToolPluginPackage",
                    products: [
                        .plugin(
                            name: "UnusedBuildToolPlugin",
                            targets: ["UnusedBuildToolPlugin"])
                    ],
                    targets: [
                        .plugin(
                            name: "UnusedBuildToolPlugin",
                            capability: .buildTool(),
                            path: ".")
                    ]
                )
                """
            )
            try localFileSystem.writeFileContents(
                unusedBuildToolPluginPackageDir.appending("Plugin.swift"),
                string: """
                import PackagePlugin
                @main struct MyPlugin: BuildToolPlugin {
                    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
                        return []
                    }
                }
                """
            )

            // Create the depended-upon package that vends a command plugin.
            let commandPluginPackageDir = packageDir.appending(components: "VendoredDependencies", "CommandPluginPackage")
            try localFileSystem.createDirectory(commandPluginPackageDir, recursive: true)
            try localFileSystem.writeFileContents(
                commandPluginPackageDir.appending("Package.swift"),
                string: """
                // swift-tools-version: 5.6
                import PackageDescription
                let package = Package(
                    name: "CommandPluginPackage",
                    products: [
                        .plugin(
                            name: "CommandPlugin",
                            targets: ["CommandPlugin"])
                    ],
                    targets: [
                        .plugin(
                            name: "CommandPlugin",
                            capability: .command(intent: .custom(verb: "how", description: "why")),
                            path: ".")
                    ]
                )
                """
            )
            try localFileSystem.writeFileContents(
                commandPluginPackageDir.appending("Plugin.swift"),
                string: """
                import PackagePlugin
                @main struct MyPlugin: CommandPlugin {
                    func performCommand(context: PluginContext, targets: [Target], arguments: [String]) throws {
                    }
                }
                """
            )

            // Load a workspace from the package.
            let observability = ObservabilitySystem.makeForTesting()
            let workspace = try Workspace(
                fileSystem: localFileSystem,
                location: .init(forRootPackage: packageDir, fileSystem: localFileSystem),
                customManifestLoader: ManifestLoader(toolchain: UserToolchain.default),
                delegate: MockWorkspaceDelegate()
            )

            // Load the root manifest.
            let rootInput = PackageGraphRootInput(packages: [packageDir], dependencies: [])
            let rootManifests = try temp_await {
                workspace.loadRootManifests(
                    packages: rootInput.packages,
                    observabilityScope: observability.topScope,
                    completion: $0
                )
            }
            XCTAssert(rootManifests.count == 1, "\(rootManifests)")

            // Load the package graph.
            let packageGraph = try workspace.loadPackageGraph(rootInput: rootInput, observabilityScope: observability.topScope)
            XCTAssert(packageGraph.packages.count == 4, "\(packageGraph.packages)")
            XCTAssert(packageGraph.rootPackages.count == 1, "\(packageGraph.rootPackages)")

            // Check that we have only a warning about the unused build tool plugin (not about the used one and not about the command plugin).
            testDiagnostics(observability.diagnostics, problemsOnly: true) { result in
                result.checkUnordered(diagnostic: .contains("dependency 'unusedbuildtoolpluginpackage' is not used by any target"), severity: .warning)
            }
        }
    }

    func testSnippetSupport() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try fixture(name: "Miscellaneous/Plugins") { path in
            let (stdout, stderr) = try executeSwiftPackage(path.appending("PluginsAndSnippets"), configuration: .Debug, extraArgs: ["do-something"])
            XCTAssert(stdout.contains("type of snippet target: snippet"), "output:\n\(stderr)\n\(stdout)")
        }
    }

    func testIncorrectDependencies() throws {
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try fixture(name: "Miscellaneous/Plugins") { path in
            let (stdout, stderr) = try executeSwiftBuild(path.appending("IncorrectDependencies"), extraArgs: ["--build-tests"])
            XCTAssert(stdout.contains("Build complete!"), "output:\n\(stderr)\n\(stdout)")
        }
    }

    func testSandboxViolatingBuildToolPluginCommands() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "sandboxing tests are only supported on macOS")
        #endif
        
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        // Check that the build fails with a sandbox violation by default.
        try fixture(name: "Miscellaneous/Plugins/SandboxViolatingBuildToolPluginCommands") { path in
            XCTAssertThrowsError(try executeSwiftBuild(path.appending("MyLibrary"), configuration: .Debug)) { error in
                XCTAssertMatch("\(error)", .contains("You don’t have permission to save the file “generated” in the folder “MyLibrary”."))
            }
        }

        // Check that the build succeeds if we disable the sandbox.
        try fixture(name: "Miscellaneous/Plugins/SandboxViolatingBuildToolPluginCommands") { path in
            let (stdout, stderr) = try executeSwiftBuild(path.appending("MyLibrary"), configuration: .Debug, extraArgs: ["--disable-sandbox"])
            XCTAssert(stdout.contains("Compiling MyLibrary foo.swift"), "[STDOUT]\n\(stdout)\n[STDERR]\n\(stderr)\n")
        }

    }

    func testTransitivePluginOnlyDependency() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try fixture(name: "Miscellaneous/Plugins") { fixturePath in
            let (stdout, _) = try executeSwiftBuild(fixturePath.appending("TransitivePluginOnlyDependency"))
            XCTAssert(stdout.contains("Compiling plugin MyPlugin"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Compiling Library Library.swift"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Build complete!"), "stdout:\n\(stdout)")
        }
    }

    func testMissingPlugin() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try fixture(name: "Miscellaneous/Plugins") { fixturePath in
            do {
                try executeSwiftBuild(fixturePath.appending("MissingPlugin"))
            } catch SwiftPMError.executionFailure(_, _, let stderr) {
                XCTAssert(stderr.contains("error: 'missingplugin': no plugin named 'NonExistingPlugin' found"), "stderr:\n\(stderr)")
            }
        }
    }

    func testPluginCanBeReferencedByProductName() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the plugin APIs require).
        try XCTSkipIf(!UserToolchain.default.supportsSwiftConcurrency(), "skipping because test environment doesn't support concurrency")

        try fixture(name: "Miscellaneous/Plugins") { fixturePath in
            let (stdout, _) = try executeSwiftBuild(fixturePath.appending("PluginCanBeReferencedByProductName"))
            XCTAssert(stdout.contains("Compiling plugin MyPlugin"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Compiling PluginCanBeReferencedByProductName gen.swift"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Build complete!"), "stdout:\n\(stdout)")
        }
    }

    func testPluginCanBeAffectedByXBuildToolsParameters() throws {
        // Only run the test if the environment in which we're running actually supports Swift concurrency (which the
        // plugin APIs require).
        try XCTSkipIf(
            !UserToolchain.default.supportsSwiftConcurrency(),
            "skipping because test environment doesn't support concurrency"
        )

        try fixture(name: "Miscellaneous/Plugins") { fixturePath in
            let (stdout, _) = try executeSwiftBuild(
                fixturePath.appending(component: "MySourceGenPlugin"),
                configuration: .Debug,
                extraArgs: ["--product", "MyLocalTool", "-Xbuild-tools-swiftc", "-DUSE_CREATE"]
            )
            XCTAssert(stdout.contains("Linking MySourceGenBuildTool"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Creating foo.swift from foo.dat"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Linking MyLocalTool"), "stdout:\n\(stdout)")
            XCTAssert(stdout.contains("Build complete!"), "stdout:\n\(stdout)")
        }
    }
}
