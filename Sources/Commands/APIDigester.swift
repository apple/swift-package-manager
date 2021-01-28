/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import TSCBasic
import TSCUtility

import SPMBuildCore
import Build
import PackageGraph
import PackageModel
import SourceControl
import Workspace

/// Helper for dumping the SDK JSON file for the baseline.
struct APIDigesterBaselineDumper {
    /// The baseline we're diffing against.
    ///
    /// This is the git treeish.
    let baselineTreeish: String

    /// The root package path.
    let packageRoot: AbsolutePath

    /// The input build parameters.
    let inputBuildParameters: BuildParameters

    /// The manifest loader.
    let manifestLoader: ManifestLoaderProtocol

    /// The repository manager.
    let repositoryManager: RepositoryManager

    /// The API digester tool.
    let apiDigesterTool: SwiftAPIDigester

    /// The diagnostics engine for emitting errors/warnings.
    let diags: DiagnosticsEngine

    init(
        baselineTreeish: String,
        packageRoot: AbsolutePath,
        buildParameters: BuildParameters,
        manifestLoader: ManifestLoaderProtocol,
        repositoryManager: RepositoryManager,
        apiDigesterTool: SwiftAPIDigester,
        diags: DiagnosticsEngine
    ) {
        self.baselineTreeish = baselineTreeish
        self.packageRoot = packageRoot
        self.inputBuildParameters = buildParameters
        self.manifestLoader = manifestLoader
        self.repositoryManager = repositoryManager
        self.apiDigesterTool = apiDigesterTool
        self.diags = diags
    }

    /// Dump the baseline SDK JSON and return its path.
    func dumpBaselineSDKJSON() throws -> AbsolutePath {
        let apiDiffDir = inputBuildParameters.apiDiff
        let sdkJSON = apiDiffDir.appending(component: baselineTreeish + ".json")

        // We're done if the JSON already exists on disk.
        if localFileSystem.exists(sdkJSON) {
            return sdkJSON
        }

        let baselinePackageRoot = apiDiffDir.appending(component: baselineTreeish)
        if localFileSystem.exists(baselinePackageRoot) {
            try localFileSystem.removeFileTree(baselinePackageRoot)
        }

        // Clone the current package in a sandbox and checkout the baseline revision.
        let specifier = RepositorySpecifier(url: baselinePackageRoot.pathString)
        try repositoryManager.provider.cloneCheckout(
            repository: specifier,
            at: packageRoot,
            to: baselinePackageRoot,
            editable: false
        )

        let workingCheckout = try repositoryManager.provider.openCheckout(at: baselinePackageRoot)
        try workingCheckout.checkout(revision: Revision(identifier: baselineTreeish))

        // Create the workspace for this package.
        let workspace = Workspace.create(
            forRootPackage: baselinePackageRoot,
            manifestLoader: manifestLoader,
            repositoryManager: repositoryManager,
            verbosity: TSCUtility.verbosity
        )

        let graph = try workspace.loadPackageGraph(
            rootPath: baselinePackageRoot, diagnostics: diags)

        // Abort if we weren't able to load the package graph.
        if diags.hasErrors {
            throw Diagnostics.fatalError
        }

        // Update the data path input build parameters so it's built in the sandbox.
        var buildParameters = inputBuildParameters
        buildParameters.dataPath = workspace.dataPath

        // Build the baseline module.
        let buildOp = BuildOperation(
            buildParameters: buildParameters,
            cacheBuildManifest: false,
            packageGraphLoader: { graph },
            verbosity: TSCUtility.verbosity,
            diagnostics: diags,
            stdoutStream: stdoutStream
        )

        // FIXME: Need a way to register this build operation with the interrupt handler.

        try buildOp.build()

        // Dump the SDK JSON.
        try apiDigesterTool.dumpSDKJSON(
            at: sdkJSON,
            modules: graph.apiDigesterModules,
            additionalArgs: buildOp.buildPlan!.createAPIDigesterArgs()
        )

        return sdkJSON
    }
}

/// A wrapper for swift-api-digester tool.
public struct SwiftAPIDigester {
    let tool: AbsolutePath

    init(tool: AbsolutePath) {
        self.tool = tool
    }

    public func dumpSDKJSON(
        at json: AbsolutePath,
        modules: [String],
        additionalArgs: [String]
    ) throws {
        var args = ["-dump-sdk"]
        args += additionalArgs
        args += modules.flatMap { ["-module", $0] }
        args += ["-o", json.pathString]
        try localFileSystem.createDirectory(json.parentDirectory, recursive: true)

        try runTool(args)

        // FIXME: The tool doesn't exit with 1 if it fails.
        if !localFileSystem.exists(json) {
            throw Diagnostics.fatalError
        }
    }

    public func diagnoseSDK(
        currentSDKJSON: AbsolutePath,
        baselineSDKJSON: AbsolutePath
    ) throws {
        let args = [
            "-diagnose-sdk",
            "--input-paths",
            baselineSDKJSON.pathString,
            "-input-paths",
            currentSDKJSON.pathString,
        ]

        try runTool(args)
    }

    func runTool(_ args: [String]) throws {
        let arguments = [tool.pathString] + args
        let process = Process(
            arguments: arguments,
            outputRedirection: .none,
            verbose: TSCUtility.verbosity != .concise
        )
        try process.launch()
        try process.waitUntilExit()
    }
}

extension BuildParameters {
    /// The directory containing artifacts for API diffing operations.
    var apiDiff: AbsolutePath {
        dataPath.appending(component: "apidiff")
    }
}

extension PackageGraph {
    /// The list of modules that should be used as an input to the API digester.
    var apiDigesterModules: [String] {
        self.rootPackages
            .flatMap { $0.targets }
            .filter { $0.type == .library }
            .filter { $0.underlyingTarget is SwiftTarget }
            .map { $0.c99name }
    }
}
