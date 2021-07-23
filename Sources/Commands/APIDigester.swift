/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Dispatch

import TSCBasic
import TSCUtility

import SPMBuildCore
import Basics
import Build
import PackageGraph
import PackageModel
import SourceControl
import Workspace

/// Helper for emitting a JSON API baseline for a module.
struct APIDigesterBaselineDumper {

    /// The revision to emit a baseline for.
    let baselineRevision: Revision

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
        baselineRevision: Revision,
        packageRoot: AbsolutePath,
        buildParameters: BuildParameters,
        manifestLoader: ManifestLoaderProtocol,
        repositoryManager: RepositoryManager,
        apiDigesterTool: SwiftAPIDigester,
        diags: DiagnosticsEngine
    ) {
        self.baselineRevision = baselineRevision
        self.packageRoot = packageRoot
        self.inputBuildParameters = buildParameters
        self.manifestLoader = manifestLoader
        self.repositoryManager = repositoryManager
        self.apiDigesterTool = apiDigesterTool
        self.diags = diags
    }

    /// Emit the API baseline files and return the path to their directory.
    func emitAPIBaseline(for modulesToDiff: Set<String>,
                         at baselineDir: AbsolutePath?,
                         force: Bool) throws -> AbsolutePath {
        var modulesToDiff = modulesToDiff
        let apiDiffDir = inputBuildParameters.apiDiff
        let baselineDir = (baselineDir ?? apiDiffDir).appending(component: baselineRevision.identifier)
        let baselinePath: (String)->AbsolutePath = { module in
            baselineDir.appending(component: module + ".json")
        }

        if !force {
            // Baselines which already exist don't need to be regenerated.
            modulesToDiff = modulesToDiff.filter {
                !localFileSystem.exists(baselinePath($0))
            }
        }

        guard !modulesToDiff.isEmpty else {
            // If none of the baselines need to be regenerated, return.
            return baselineDir
        }

        // Setup a temporary directory where we can checkout and build the baseline treeish.
        let baselinePackageRoot = apiDiffDir.appending(component: "\(baselineRevision.identifier)-checkout")
        if localFileSystem.exists(baselinePackageRoot) {
            try localFileSystem.removeFileTree(baselinePackageRoot)
        }

        // Clone the current package in a sandbox and checkout the baseline revision.
        let specifier = RepositorySpecifier(url: baselinePackageRoot.pathString)
        let workingCopy = try repositoryManager.provider.createWorkingCopy(
            repository: specifier,
            sourcePath: packageRoot,
            at: baselinePackageRoot,
            editable: false
        )

        try workingCopy.checkout(revision: baselineRevision)

        // Create the workspace for this package.
        let workspace = Workspace.create(
            forRootPackage: baselinePackageRoot,
            manifestLoader: manifestLoader,
            repositoryManager: repositoryManager
        )

        let graph = try workspace.loadPackageGraph(
            rootPath: baselinePackageRoot, diagnostics: diags)

        // Don't emit a baseline for a module that didn't exist yet in this revision.
        modulesToDiff.formIntersection(graph.apiDigesterModules)

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
            pluginInvoker: { _ in [:] },
            diagnostics: diags,
            stdoutStream: stdoutStream
        )

        try buildOp.build()

        // Dump the SDK JSON.
        try localFileSystem.createDirectory(baselineDir, recursive: true)
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: Int(buildParameters.jobs))
        let errors = ThreadSafeArrayStore<Swift.Error>()
        for module in modulesToDiff {
            semaphore.wait()
            DispatchQueue.sharedConcurrent.async(group: group) {
                do {
                    try apiDigesterTool.emitAPIBaseline(
                        to: baselinePath(module),
                        for: module,
                        buildPlan: buildOp.buildPlan!
                    )
                } catch {
                    errors.append(error)
                }
                semaphore.signal()
            }
        }
        group.wait()

        for error in errors.get() {
            diags.emit(error)
        }
        if diags.hasErrors {
            throw Diagnostics.fatalError
        }

        return baselineDir
    }
}

/// A wrapper for the swift-api-digester tool.
public struct SwiftAPIDigester {

    /// The absolute path to `swift-api-digester` in the toolchain.
    let tool: AbsolutePath

    init(tool: AbsolutePath) {
        self.tool = tool
    }

    /// Emit an API baseline file for the specified module at the specified location.
    public func emitAPIBaseline(
        to outputPath: AbsolutePath,
        for module: String,
        buildPlan: BuildPlan
    ) throws {
        var args = ["-dump-sdk"]
        args += buildPlan.createAPIToolCommonArgs(includeLibrarySearchPaths: false)
        args += ["-module", module, "-o", outputPath.pathString]

        try runTool(args)

        if !localFileSystem.exists(outputPath) {
            throw Error.failedToGenerateBaseline(module)
        }
    }

    /// Compare the current package API to a provided baseline file.
    public func compareAPIToBaseline(
        at baselinePath: AbsolutePath,
        for module: String,
        buildPlan: BuildPlan,
        except breakageAllowlistPath: AbsolutePath?
    ) -> ComparisonResult? {
        var args = [
            "-diagnose-sdk",
            "-baseline-path", baselinePath.pathString,
            "-module", module
        ]
        args.append(contentsOf: buildPlan.createAPIToolCommonArgs(includeLibrarySearchPaths: false))
        if let breakageAllowlistPath = breakageAllowlistPath {
            args.append(contentsOf: ["-breakage-allowlist-path", breakageAllowlistPath.pathString])
        }

        return try? withTemporaryFile(deleteOnClose: false) { file in
            args.append(contentsOf: ["-serialize-diagnostics-path", file.path.pathString])
            try runTool(args)
            let contents = try localFileSystem.readFileContents(file.path)
            guard contents.count > 0 else {
                return nil
            }
            let serializedDiagnostics = try SerializedDiagnostics(bytes: contents)
            let apiDigesterCategory = "api-digester-breaking-change"
            let apiBreakingChanges = serializedDiagnostics.diagnostics.filter { $0.category == apiDigesterCategory }
            let otherDiagnostics = serializedDiagnostics.diagnostics.filter { $0.category != apiDigesterCategory }
            return ComparisonResult(moduleName: module,
                                    apiBreakingChanges: apiBreakingChanges,
                                    otherDiagnostics: otherDiagnostics)
        }
    }

    private func runTool(_ args: [String]) throws {
        let arguments = [tool.pathString] + args
        let process = Process(
            arguments: arguments,
            outputRedirection: .collect,
            verbose: verbosity != .concise
        )
        try process.launch()
        try process.waitUntilExit()
    }
}

extension SwiftAPIDigester {
    public enum Error: Swift.Error, DiagnosticData {
        case failedToGenerateBaseline(String)

        public var description: String {
            switch self {
            case .failedToGenerateBaseline(let module):
                return "failed to generate baseline for \(module)"
            }
        }
    }
}

extension SwiftAPIDigester {
    /// The result of comparing a module's API to a provided baseline.
    public struct ComparisonResult {
        /// The name of the module being diffed.
        var moduleName: String
        /// Breaking changes made to the API since the baseline was generated.
        var apiBreakingChanges: [SerializedDiagnostics.Diagnostic]
        /// Other diagnostics emitted while comparing the current API to the baseline.
        var otherDiagnostics: [SerializedDiagnostics.Diagnostic]

        /// `true` if the comparison succeeded and no breaking changes were found, otherwise `false`.
        var hasNoAPIBreakingChanges: Bool {
            apiBreakingChanges.isEmpty && otherDiagnostics.filter { [.fatal, .error].contains($0.level) }.isEmpty
        }
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
            .flatMap(\.products)
            .filter { $0.type.isLibrary }
            .flatMap(\.targets)
            .filter { $0.underlyingTarget is SwiftTarget }
            .map { $0.c99name }
    }
}

extension SerializedDiagnostics.SourceLocation: DiagnosticLocation {
    public var description: String {
        return "\(filename):\(line):\(column)"
    }
}
