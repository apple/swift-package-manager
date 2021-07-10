/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import ArgumentParser
import Basics
import TSCBasic
import SPMBuildCore
import Build
import PackageModel
import PackageLoading
import PackageGraph
import SourceControl
import TSCUtility
import Xcodeproj
import XCBuildSupport
import Workspace
import Foundation

#if BUILD_PACKAGE_SYNTAX
import PackageSyntax
#endif

/// swift-package tool namespace
public struct SwiftPackageTool: ParsableCommand {

    private static let subcommands: [ParsableCommand.Type] = {
        var subcommands: [ParsableCommand.Type] = [
            Clean.self,
            PurgeCache.self,
            Reset.self,
            Update.self,
            Describe.self,
            Init.self,
            Format.self,

            APIDiff.self,
            DumpSymbolGraph.self,
            DumpPIF.self,
            DumpPackage.self,

            Edit.self,
            Unedit.self,

            Config.self,
            Resolve.self,
            Fetch.self,

            ShowDependencies.self,
            ToolsVersionCommand.self,
            GenerateXcodeProject.self,
            ComputeChecksum.self,
            ArchiveSource.self,
            CompletionTool.self,
        ]
        #if BUILD_PACKAGE_SYNTAX
        subcommands.append(contentsOf: [
            AddDependency.self,
            AddTarget.self,
            AddProduct.self,
        ])
        #endif
        return subcommands
    }()

    public static var configuration = CommandConfiguration(
        commandName: "package",
        _superCommandName: "swift",
        abstract: "Perform operations on Swift packages",
        discussion: "SEE ALSO: swift build, swift run, swift test",
        version: SwiftVersion.currentVersion.completeDisplayString,
        subcommands: subcommands,
        helpNames: [.short, .long, .customLong("help", withSingleDash: true)])

    @OptionGroup()
    var swiftOptions: SwiftToolOptions

    public init() {}

    public static var _errorLabel: String { "error" }
}

extension DescribeMode: ExpressibleByArgument {}
extension InitPackage.PackageType: ExpressibleByArgument {}
extension ShowDependenciesMode: ExpressibleByArgument {}

extension SwiftPackageTool {
    struct Clean: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete build artifacts")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        func run(_ swiftTool: SwiftTool) throws {
            try swiftTool.getActiveWorkspace().clean(with: swiftTool.diagnostics)
        }
    }

    struct PurgeCache: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Purge the global repository cache.")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        func run(_ swiftTool: SwiftTool) throws {
            try swiftTool.getActiveWorkspace().purgeCache(with: swiftTool.diagnostics)
        }
    }
    
    struct Reset: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reset the complete cache/build directory")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        func run(_ swiftTool: SwiftTool) throws {
            try swiftTool.getActiveWorkspace().reset(with: swiftTool.diagnostics)
        }
    }
    
    struct Update: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Update package dependencies")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Flag(name: [.long, .customShort("n")],
              help: "Display the list of dependencies that can be updated")
        var dryRun: Bool = false
        
        @Argument(help: "The packages to update")
        var packages: [String] = []

        func run(_ swiftTool: SwiftTool) throws {
            let workspace = try swiftTool.getActiveWorkspace()
            
            let changes = try workspace.updateDependencies(
                root: swiftTool.getWorkspaceRoot(),
                packages: packages,
                diagnostics: swiftTool.diagnostics,
                dryRun: dryRun
            )

            // try to load the graph which will emit any errors
            if !swiftTool.diagnostics.hasErrors {
                _ = try workspace.loadPackageGraph(
                    rootInput: swiftTool.getWorkspaceRoot(),
                    diagnostics: swiftTool.diagnostics
                )
            }

            if let pinsStore = swiftTool.diagnostics.wrap({ try workspace.pinsStore.load() }), let changes = changes, dryRun {
                logPackageChanges(changes: changes, pins: pinsStore)
            }

            if !dryRun {
                // Throw if there were errors when loading the graph.
                // The actual errors will be printed before exiting.
                guard !swiftTool.diagnostics.hasErrors else {
                    throw ExitCode.failure
                }
            }
        }
    }
    
    struct Describe: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Describe the current package")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
                
        @Option(help: "json | text")
        var type: DescribeMode = .text

        func run(_ swiftTool: SwiftTool) throws {
            let workspace = try swiftTool.getActiveWorkspace()
            let root = try swiftTool.getWorkspaceRoot()

            let rootManifests = try temp_await {
                workspace.loadRootManifests(packages: root.packages, diagnostics: swiftTool.diagnostics, completion: $0)
            }
            guard let rootManifest = rootManifests.values.first else {
                throw StringError("invalid manifests at \(root.packages)")
            }

            let builder = PackageBuilder(
                identity: .plain(rootManifest.name),
                manifest: rootManifest,
                productFilter: .everything,
                path: try swiftTool.getPackageRoot(),
                xcTestMinimumDeploymentTargets: MinimumDeploymentTarget.default.xcTestMinimumDeploymentTargets,
                diagnostics: swiftTool.diagnostics
            )
            let package = try builder.construct()
            describe(package, in: type, on: stdoutStream)
        }
    }

    struct Init: SwiftCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Initialize a new package")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Option(name: .customLong("type"), help: "Package type: empty | library | executable | system-module | manifest")
        var initMode: InitPackage.PackageType = .library
        
        @Option(name: .customLong("name"), help: "Provide custom package name")
        var packageName: String?
        
        func run(_ swiftTool: SwiftTool) throws {
            guard let cwd = localFileSystem.currentWorkingDirectory else {
                throw InternalError("Could not find the current working directory")
            }

            let packageName = self.packageName ?? cwd.basename
            let initPackage = try InitPackage(
                name: packageName, destinationPath: cwd, packageType: initMode)
            initPackage.progressReporter = { message in
                print(message)
            }
            try initPackage.writePackageStructure()
        }
    }
    
    struct Format: SwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: "_format")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Argument(parsing: .unconditionalRemaining,
                  help: "Pass flag through to the swift-format tool")
        var swiftFormatFlags: [String] = []
        
        func run(_ swiftTool: SwiftTool) throws {
            // Look for swift-format binary.
            // FIXME: This should be moved to user toolchain.
            let swiftFormatInEnv = lookupExecutablePath(filename: ProcessEnv.vars["SWIFT_FORMAT"])
            guard let swiftFormat = swiftFormatInEnv ?? Process.findExecutable("swift-format") else {
                print("error: Could not find swift-format in PATH or SWIFT_FORMAT")
                throw Diagnostics.fatalError
            }

            // Get the root package.
            let workspace = try swiftTool.getActiveWorkspace()
            let root = try swiftTool.getWorkspaceRoot()
            let rootManifests = try temp_await {
                workspace.loadRootManifests(packages: root.packages, diagnostics: swiftTool.diagnostics, completion: $0)
            }
            guard let rootManifest = rootManifests.values.first else {
                throw StringError("invalid manifests at \(root.packages)")
            }

            let builder = PackageBuilder(
                identity: .plain(rootManifest.name),
                manifest: rootManifest,
                productFilter: .everything,
                path: try swiftTool.getPackageRoot(),
                xcTestMinimumDeploymentTargets: [:], // Minimum deployment target does not matter for this operation.
                diagnostics: swiftTool.diagnostics
            )
            let package = try builder.construct()

            // Use the user provided flags or default to formatting mode.
            let formatOptions = swiftFormatFlags.isEmpty
                ? ["--mode", "format", "--in-place"]
                : swiftFormatFlags

            // Process each target in the root package.
            for target in package.targets {
                for file in target.sources.paths {
                    // Only process Swift sources.
                    guard let ext = file.extension, ext == SupportedLanguageExtension.swift.rawValue else {
                        continue
                    }

                    let args = [swiftFormat.pathString] + formatOptions + [file.pathString]
                    print("Running:", args.map{ $0.spm_shellEscaped() }.joined(separator: " "))

                    let result = try Process.popen(arguments: args)
                    let output = try (result.utf8Output() + result.utf8stderrOutput())

                    if result.exitStatus != .terminated(code: 0) {
                        print("Non-zero exit", result.exitStatus)
                    }
                    if !output.isEmpty {
                        print(output)
                    }
                }
            }
        }
    }
    
    struct APIDiff: SwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: "experimental-api-diff",
            abstract: "Diagnose API-breaking changes to Swift modules in a package",
            discussion: """
            The experimental-api-diff command can be used to compare the Swift API of \
            a package to a baseline revision, diagnosing any breaking changes which have \
            been introduced. By default, it compares every Swift module from the baseline \
            revision which is part of a library product. For packages with many targets, this \
            behavior may be undesirable as the comparison can be slow. \
            The `--products` and `--targets` options may be used to restrict the scope of \
            the comparison.
            """)

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        @Option(help: """
        The path to a text file containing breaking changes which should be ignored by the API comparison. \
        Each ignored breaking change in the file should appear on its own line and contain the exact message \
        to be ignored (e.g. 'API breakage: func foo() has been removed').
        """)
        var breakageAllowlistPath: AbsolutePath?

        @Argument(help: "The baseline treeish to compare to (e.g. a commit hash, branch name, tag, etc.)")
        var treeish: String

        @Option(parsing: .upToNextOption,
                help: "One or more products to include in the API comparison. If present, only the specified products (and any targets specified using `--targets`) will be compared.")
        var products: [String] = []

        @Option(parsing: .upToNextOption,
                help: "One or more targets to include in the API comparison. If present, only the specified targets (and any products specified using `--products`) will be compared.")
        var targets: [String] = []

        @Option(name: .customLong("baseline-dir"),
                help: "The path to a directory used to store API baseline files. If unspecified, a temporary directory will be used.")
        var overrideBaselineDir: AbsolutePath?

        @Flag(help: "Regenerate the API baseline, even if an existing one is available.")
        var regenerateBaseline: Bool = false

        func run(_ swiftTool: SwiftTool) throws {
            let apiDigesterPath = try swiftTool.getToolchain().getSwiftAPIDigester()
            let apiDigesterTool = SwiftAPIDigester(tool: apiDigesterPath)

            // We turn build manifest caching off because we need the build plan.
            let buildOp = try swiftTool.createBuildOperation(cacheBuildManifest: false)

            let packageGraph = try buildOp.getPackageGraph()
            let modulesToDiff = try determineModulesToDiff(packageGraph: packageGraph,
                                                           diagnostics: swiftTool.diagnostics)

            // Build the current package.
            try buildOp.build()

            // Dump JSON for the baseline package.
            let workspace = try swiftTool.getActiveWorkspace()
            let baselineDumper = try APIDigesterBaselineDumper(
                baselineTreeish: treeish,
                packageRoot: swiftTool.getPackageRoot(),
                buildParameters: buildOp.buildParameters,
                manifestLoader: workspace.manifestLoader,
                repositoryManager: workspace.repositoryManager,
                apiDigesterTool: apiDigesterTool,
                diags: swiftTool.diagnostics
            )
            let baselineDir = try baselineDumper.emitAPIBaseline(for: modulesToDiff,
                                                                 at: overrideBaselineDir,
                                                                 force: regenerateBaseline)

            let results = ThreadSafeArrayStore<SwiftAPIDigester.ComparisonResult>()
            let group = DispatchGroup()
            let semaphore = DispatchSemaphore(value: Int(buildOp.buildParameters.jobs))
            var skippedModules: Set<String> = []

            for module in modulesToDiff {
                let moduleBaselinePath = baselineDir.appending(component: "\(module).json")
                guard localFileSystem.exists(moduleBaselinePath) else {
                    print("\nSkipping \(module) because it does not exist in the baseline")
                    skippedModules.insert(module)
                    continue
                }
                semaphore.wait()
                DispatchQueue.sharedConcurrent.async(group: group) {
                    if let comparisonResult = apiDigesterTool.compareAPIToBaseline(
                        at: moduleBaselinePath,
                        for: module,
                        buildPlan: buildOp.buildPlan!,
                        except: breakageAllowlistPath
                    ) {
                        results.append(comparisonResult)
                    }
                    semaphore.signal()
                }
            }

            group.wait()

            let failedModules = modulesToDiff
                .subtracting(skippedModules)
                .subtracting(results.map(\.moduleName))
            for failedModule in failedModules {
                swiftTool.diagnostics.emit(.error("failed to read API digester output for \(failedModule)"))
            }

            for result in results.get() {
                printComparisonResult(result, diagnosticsEngine: swiftTool.diagnostics)
            }

            guard failedModules.isEmpty && results.get().allSatisfy(\.hasNoAPIBreakingChanges) else {
                throw ExitCode.failure
            }
        }

        private func determineModulesToDiff(packageGraph: PackageGraph, diagnostics: DiagnosticsEngine) throws -> Set<String> {
            var modulesToDiff: Set<String> = []
            if products.isEmpty && targets.isEmpty {
                modulesToDiff.formUnion(packageGraph.apiDigesterModules)
            } else {
                for productName in products {
                    guard let product = packageGraph
                            .rootPackages
                            .flatMap(\.products)
                            .first(where: { $0.name == productName }) else {
                        diagnostics.emit(.error("no such product '\(productName)'"))
                        continue
                    }
                    guard product.type.isLibrary else {
                        diagnostics.emit(.error("'\(productName)' is not a library product"))
                        continue
                    }
                    modulesToDiff.formUnion(product.targets.filter { $0.underlyingTarget is SwiftTarget }.map(\.c99name))
                }
                for targetName in targets {
                    guard let target = packageGraph
                            .rootPackages
                            .flatMap(\.targets)
                            .first(where: { $0.name == targetName }) else {
                        diagnostics.emit(.error("no such target '\(targetName)'"))
                        continue
                    }
                    guard target.type == .library else {
                        diagnostics.emit(.error("'\(targetName)' is not a library target"))
                        continue
                    }
                    guard target.underlyingTarget is SwiftTarget else {
                        diagnostics.emit(.error("'\(targetName)' is not a Swift language target"))
                        continue
                    }
                    modulesToDiff.insert(target.c99name)
                }
                guard !diagnostics.hasErrors else {
                    throw ExitCode.failure
                }
            }
            return modulesToDiff
        }

        private func printComparisonResult(_ comparisonResult: SwiftAPIDigester.ComparisonResult,
                                           diagnosticsEngine: DiagnosticsEngine) {
            for diagnostic in comparisonResult.otherDiagnostics {
                switch diagnostic.level {
                case .error, .fatal:
                    diagnosticsEngine.emit(error: diagnostic.text, location: diagnostic.location)
                case .warning:
                    diagnosticsEngine.emit(warning: diagnostic.text, location: diagnostic.location)
                case .note:
                    diagnosticsEngine.emit(note: diagnostic.text, location: diagnostic.location)
                case .remark:
                    diagnosticsEngine.emit(remark: diagnostic.text, location: diagnostic.location)
                case .ignored:
                    break
                }
            }

            let moduleName = comparisonResult.moduleName
            if comparisonResult.apiBreakingChanges.isEmpty {
                print("\nNo breaking changes detected in \(moduleName)")
            } else {
                let count = comparisonResult.apiBreakingChanges.count
                print("\n\(count) breaking \(count > 1 ? "changes" : "change") detected in \(moduleName):")
                for change in comparisonResult.apiBreakingChanges {
                    print("  💔 \(change.text)")
                }
            }
        }
    }
    
    struct DumpSymbolGraph: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Dump Symbol Graph")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        func run(_ swiftTool: SwiftTool) throws {
            let symbolGraphExtract = try SymbolGraphExtract(
                tool: swiftTool.getToolchain().getSymbolGraphExtract())

            // Build the current package.
            //
            // We turn build manifest caching off because we need the build plan.
            let buildOp = try swiftTool.createBuildOperation(cacheBuildManifest: false)
            try buildOp.build()

            try symbolGraphExtract.dumpSymbolGraph(
                buildPlan: buildOp.buildPlan!
            )
        }
    }
    
    struct DumpPackage: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print parsed Package.swift as JSON")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        func run(_ swiftTool: SwiftTool) throws {
            let workspace = try swiftTool.getActiveWorkspace()
            let root = try swiftTool.getWorkspaceRoot()

            let rootManifests = try temp_await {
                workspace.loadRootManifests(packages: root.packages, diagnostics: swiftTool.diagnostics, completion: $0)
            }
            guard let rootManifest = rootManifests.values.first else {
                throw StringError("invalid manifests at \(root.packages)")
            }

            let encoder = JSONEncoder.makeWithDefaults()
            encoder.userInfo[Manifest.dumpPackageKey] = true

            let jsonData = try encoder.encode(rootManifest)
            let jsonString = String(data: jsonData, encoding: .utf8)!
            print(jsonString)
        }
    }
    
    struct DumpPIF: SwiftCommand {
        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Flag(help: "Preserve the internal structure of PIF")
        var preserveStructure: Bool = false

        func run(_ swiftTool: SwiftTool) throws {
            let graph = try swiftTool.loadPackageGraph(createMultipleTestProducts: true)
            let parameters = try PIFBuilderParameters(swiftTool.buildParameters())
            let builder = PIFBuilder(graph: graph, parameters: parameters, diagnostics: swiftTool.diagnostics)
            let pif = try builder.generatePIF(preservePIFModelStructure: preserveStructure)
            print(pif)
        }
    }
    
    struct Edit: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Put a package in editable mode")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        @Option(help: "The revision to edit", transform: { Revision(identifier: $0) })
        var revision: Revision?
        
        @Option(name: .customLong("branch"), help: "The branch to create")
        var checkoutBranch: String?
        
        @Option(help: "Create or use the checkout at this path")
        var path: AbsolutePath?
        
        @Argument(help: "The name of the package to edit")
        var packageName: String

        func run(_ swiftTool: SwiftTool) throws {
            try swiftTool.resolve()
            let workspace = try swiftTool.getActiveWorkspace()

            // Put the dependency in edit mode.
            workspace.edit(
                packageName: packageName,
                path: path,
                revision: revision,
                checkoutBranch: checkoutBranch,
                diagnostics: swiftTool.diagnostics)
        }
    }

    struct Unedit: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a package from editable mode")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Flag(name: .customLong("force"),
              help: "Unedit the package even if it has uncommited and unpushed changes")
        var shouldForceRemove: Bool = false
        
        @Argument(help: "The name of the package to unedit")
        var packageName: String

        func run(_ swiftTool: SwiftTool) throws {
            try swiftTool.resolve()
            let workspace = try swiftTool.getActiveWorkspace()

            try workspace.unedit(
                packageName: packageName,
                forceRemove: shouldForceRemove,
                root: swiftTool.getWorkspaceRoot(),
                diagnostics: swiftTool.diagnostics
            )
        }
    }
    
    struct ShowDependencies: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the resolved dependency graph")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Option(help: "text | dot | json | flatlist")
        var format: ShowDependenciesMode = .text

        @Option(name: [.long, .customShort("o") ], 
                help: "The absolute or relative path to output the resolved dependency graph.")
        var outputPath: AbsolutePath?

        func run(_ swiftTool: SwiftTool) throws {
            let graph = try swiftTool.loadPackageGraph()
            let stream = try outputPath.map { try LocalFileOutputByteStream($0) } ?? TSCBasic.stdoutStream.stream
            dumpDependenciesOf(rootPackage: graph.rootPackages[0], mode: format, on: stream)
        }
    }
    
    struct ToolsVersionCommand: SwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: "tools-version",
            abstract: "Manipulate tools version of the current package")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Option(help: "text | dot | json | flatlist")
        var format: ShowDependenciesMode = .text

        @Flag(help: "Set tools version of package to the current tools version in use")
        var setCurrent: Bool = false
        
        @Option(help: "Set tools version of package to the given value")
        var set: String?
        
        enum ToolsVersionMode {
            case display
            case set(String)
            case setCurrent
        }
        
        var toolsVersionMode: ToolsVersionMode {
            // TODO: enforce exclusivity
            if let set = set {
                return .set(set)
            } else if setCurrent {
                return .setCurrent
            } else {
                return .display
            }
        }

        func run(_ swiftTool: SwiftTool) throws {
            let pkg = try swiftTool.getPackageRoot()

            switch toolsVersionMode {
            case .display:
                let toolsVersionLoader = ToolsVersionLoader()
                let version = try toolsVersionLoader.load(at: pkg, fileSystem: localFileSystem)
                print("\(version)")

            case .set(let value):
                guard let toolsVersion = ToolsVersion(string: value) else {
                    // FIXME: Probably lift this error defination to ToolsVersion.
                    throw ToolsVersionLoader.Error.malformedToolsVersionSpecification(.versionSpecifier(.isMisspelt(value)))
                }
                try rewriteToolsVersionSpecification(toDefaultManifestIn: pkg, specifying: toolsVersion, fileSystem: localFileSystem)

            case .setCurrent:
                // Write the tools version with current version but with patch set to zero.
                // We do this to avoid adding unnecessary constraints to patch versions, if
                // the package really needs it, they can do it using --set option.
                try rewriteToolsVersionSpecification(
                    toDefaultManifestIn: pkg, specifying: ToolsVersion.currentToolsVersion.zeroedPatch, fileSystem: localFileSystem)
            }
        }
    }
    
    struct ComputeChecksum: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Compute the checksum for a binary artifact.")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Argument(help: "The absolute or relative path to the binary artifact")
        var path: AbsolutePath
        
        func run(_ swiftTool: SwiftTool) throws {
            let workspace = try swiftTool.getActiveWorkspace()
            let checksum = workspace.checksum(
                forBinaryArtifactAt: path,
                diagnostics: swiftTool.diagnostics
            )

            guard !swiftTool.diagnostics.hasErrors else {
                throw ExitCode.failure
            }

            stdoutStream <<< checksum <<< "\n"
            stdoutStream.flush()
        }
    }

    struct ArchiveSource: SwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: "archive-source",
            abstract: "Create a source archive for the package"
        )

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        @Option(
            name: [.short, .long],
            help: "The absolute or relative path for the generated source archive"
        )
        var output: AbsolutePath?

        func run(_ swiftTool: SwiftTool) throws {
            let packageRoot = try swiftOptions.packagePath ?? swiftTool.getPackageRoot()
            let repository = GitRepository(path: packageRoot)

            let destination: AbsolutePath
            if let output = output {
                destination = output
            } else {
                let graph = try swiftTool.loadPackageGraph()
                let packageName = graph.rootPackages[0].manifestName // TODO: use identity instead?
                destination = packageRoot.appending(component: "\(packageName).zip")
            }

            try repository.archive(to: destination)

            if destination.contains(packageRoot) {
                let relativePath = destination.relative(to: packageRoot)
                stdoutStream <<< "Created \(relativePath.pathString)" <<< "\n"
            } else {
                stdoutStream <<< "Created \(destination.pathString)" <<< "\n"
            }

            stdoutStream.flush()
        }
    }
}

extension SwiftPackageTool {
    struct GenerateXcodeProject: SwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: "generate-xcodeproj",
            abstract: "Generates an Xcode project. This command will be deprecated soon.")

        struct Options: ParsableArguments {
            @Option(help: "Path to xcconfig file", completion: .file())
            var xcconfigOverrides: AbsolutePath?
            
            @Option(name: .customLong("output"),
                    help: "Path where the Xcode project should be generated")
            var outputPath: AbsolutePath?
            
            @Flag(name: .customLong("legacy-scheme-generator"),
                  help: "Use the legacy scheme generator")
            var useLegacySchemeGenerator: Bool = false
            
            @Flag(name: .customLong("watch"),
                  help: "Watch for changes to the Package manifest to regenerate the Xcode project")
            var enableAutogeneration: Bool = false
            
            @Flag(help: "Do not add file references for extra files to the generated Xcode project")
            var skipExtraFiles: Bool = false
        }

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        @OptionGroup()
        var options: Options
        
        func xcodeprojOptions() -> XcodeprojOptions {
            XcodeprojOptions(
                flags: swiftOptions.buildFlags,
                xcconfigOverrides: options.xcconfigOverrides,
                isCodeCoverageEnabled: swiftOptions.shouldEnableCodeCoverage,
                useLegacySchemeGenerator: options.useLegacySchemeGenerator,
                enableAutogeneration: options.enableAutogeneration,
                addExtraFiles: !options.skipExtraFiles)
        }

        func run(_ swiftTool: SwiftTool) throws {
            swiftTool.diagnostics.emit(.warning("Xcode can open and build Swift Packages directly. 'generate-xcodeproj' is no longer needed and will be deprecated soon."))

            let graph = try swiftTool.loadPackageGraph()

            let projectName: String
            let dstdir: AbsolutePath

            switch options.outputPath {
            case let outpath? where outpath.suffix == ".xcodeproj":
                // if user specified path ending with .xcodeproj, use that
                projectName = String(outpath.basename.dropLast(10))
                dstdir = outpath.parentDirectory
            case let outpath?:
                dstdir = outpath
                projectName = graph.rootPackages[0].manifestName // TODO: use identity instead?
            case _:
                dstdir = try swiftTool.getPackageRoot()
                projectName = graph.rootPackages[0].manifestName // TODO: use identity instead?
            }
            let xcodeprojPath = Xcodeproj.buildXcodeprojPath(outputDir: dstdir, projectName: projectName)

            var genOptions = xcodeprojOptions()
            genOptions.manifestLoader = try swiftTool.getManifestLoader()

            try Xcodeproj.generate(
                projectName: projectName,
                xcodeprojPath: xcodeprojPath,
                graph: graph,
                options: genOptions,
                diagnostics: swiftTool.diagnostics
            )

            print("generated:", xcodeprojPath.prettyPath(cwd: swiftTool.originalWorkingDirectory))

            // Run the file watcher if requested.
            if options.enableAutogeneration {
                try WatchmanHelper(
                    diagnostics: swiftTool.diagnostics,
                    watchmanScriptsDir: swiftTool.buildPath.appending(component: "watchman"),
                    packageRoot: swiftTool.packageRoot!
                ).runXcodeprojWatcher(xcodeprojOptions())
            }
        }
    }
}

#if BUILD_PACKAGE_SYNTAX
extension SwiftPackageTool {
    struct AddDependency: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a dependency to the current package.")

        @OptionGroup()
        var swiftOptions: SwiftToolOptions

        @Argument(help: "The URL of a remote package, or the path to a local package")
        var dependencyURL: String

        @Option(help: "Specifies an exact package version requirement")
        var exact: Version?

        @Option(help: "Specifies a package revision requirement")
        var revision: String?

        @Option(help: "Specifies a package branch requirement")
        var branch: String?

        @Option(help: "Specifies a package version requirement from the specified version up to the next major version")
        var from: Version?

        @Option(help: "Specifies a package version requirement from the specified version up to the next minor version")
        var upToNextMinorFrom: Version?

        @Option(help: "Specifies the upper bound of a range-based package version requirement")
        var to: Version?

        @Option(help: "Specifies the upper bound of a closed range-based package version requirement")
        var through: Version?

        func run(_ swiftTool: SwiftTool) throws {
            var requirements: [PackageDependencyRequirement] = []
            if let exactVersion = exact {
                requirements.append(.exact(exactVersion.description))
            }
            if let revision = revision {
                requirements.append(.revision(revision))
            }
            if let branch = branch {
                requirements.append(.branch(branch))
            }
            if let version = from {
                requirements.append(.upToNextMajor(version.description))
            }
            if let version = upToNextMinorFrom {
                requirements.append(.upToNextMinor(version.description))
            }

            guard requirements.count <= 1 else {
                swiftTool.diagnostics.emit(.error("only one requirement is allowed when specifiying a dependency"))
                throw ExitCode.failure
            }

            var requirement = requirements.first

            if case .upToNextMajor(let rangeStart) = requirement {
                guard to == nil || through == nil else {
                    swiftTool.diagnostics.emit(.error("'--to' and '--through' may not be used in the same requirement"))
                    throw ExitCode.failure
                }
                if let rangeEnd = to {
                    requirement = .range(rangeStart.description, rangeEnd.description)
                } else if let closedRangeEnd = through {
                    requirement = .closedRange(rangeStart.description, closedRangeEnd.description)
                }
            } else {
                guard to == nil, through == nil else {
                    swiftTool.diagnostics.emit(.error("'--to' and '--through' may only be used with '--from' to specify a range requirement"))
                    throw ExitCode.failure
                }
            }

            let manifestPath = try Manifest.path(atPackagePath: swiftTool.getPackageRoot(),
                                                 fileSystem: localFileSystem)
            let editor = try PackageEditor(manifestPath: manifestPath,
                                           repositoryManager: swiftTool.getActiveWorkspace().repositoryManager,
                                           toolchain: swiftTool.getToolchain(),
                                           diagnosticsEngine: swiftTool.diagnostics)
            do {
                try editor.addPackageDependency(url: dependencyURL, requirement: requirement)
            } catch Diagnostics.fatalError {
                throw ExitCode.failure
            }
        }
    }

    struct AddTarget: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a target to the current package.")

        @OptionGroup()
        var swiftOptions: SwiftToolOptions

        @Argument(help: "The name of the new target")
        var name: String

        @Option(help: "The type of the new target (library, executable, test, or binary)")
        var type: String = "library"

        @Flag(help: "If present, no corresponding test target will be created for a new library target")
        var noTestTarget: Bool = false

        @Option(parsing: .upToNextOption,
                help: "A list of target dependency names (targets and/or dependency products)")
        var dependencies: [String] = []

        @Option(help: "The URL for a remote binary target")
        var url: String?

        @Option(help: "The checksum for a remote binary target")
        var checksum: String?

        @Option(help: "The path for a local binary target")
        var path: String?

        func run(_ swiftTool: SwiftTool) throws {
            let manifestPath = try Manifest.path(atPackagePath: swiftTool.getPackageRoot(),
                                                 fileSystem: localFileSystem)
            let editor = try PackageEditor(manifestPath: manifestPath,
                                           repositoryManager: swiftTool.getActiveWorkspace().repositoryManager,
                                           toolchain: swiftTool.getToolchain(),
                                           diagnosticsEngine: swiftTool.diagnostics)
            let newTarget: NewTarget
            switch type {
            case "library":
                try verifyNoTargetBinaryOptionsPassed(swiftTool: swiftTool)
                newTarget = .library(name: name,
                                     includeTestTarget: !noTestTarget,
                                     dependencyNames: dependencies)
            case "executable":
                try verifyNoTargetBinaryOptionsPassed(swiftTool: swiftTool)
                newTarget = .executable(name: name,
                                        dependencyNames: dependencies)
            case "test":
                try verifyNoTargetBinaryOptionsPassed(swiftTool: swiftTool)
                newTarget = .test(name: name,
                                  dependencyNames: dependencies)
            case "binary":
                guard dependencies.isEmpty else {
                    swiftTool.diagnostics.emit(.error("option '--dependencies' is not supported for binary targets"))
                    throw ExitCode.failure
                }
                // This check is somewhat forgiving, and does the right thing if
                // the user passes a url with --path or a path with --url.
                guard let urlOrPath = url ?? path, url == nil || path == nil else {
                    swiftTool.diagnostics.emit(.error("binary targets must specify either a path or both a URL and a checksum"))
                    throw ExitCode.failure
                }
                newTarget = .binary(name: name,
                                    urlOrPath: urlOrPath,
                                    checksum: checksum)
            default:
                swiftTool.diagnostics.emit(.error("unsupported target type '\(type)'; supported types are library, executable, test, and binary"))
                throw ExitCode.failure
            }

            do {
                try editor.addTarget(newTarget,
                                     productPackageNameMapping: createProductPackageNameMapping(swiftTool: swiftTool))
            } catch Diagnostics.fatalError {
                throw ExitCode.failure
            }
        }

        private func createProductPackageNameMapping(swiftTool: SwiftTool) throws -> [String: String] {
            let graph = try swiftTool.loadPackageGraph()
            var productPackageNameMapping: [String: String] = [:]
            for dependencyPackage in graph.rootPackages.flatMap(\.dependencies) {
                for product in dependencyPackage.products {
                    productPackageNameMapping[product.name] = dependencyPackage.manifestName
                }
            }
            return productPackageNameMapping
        }

        private func verifyNoTargetBinaryOptionsPassed(swiftTool: SwiftTool) throws {
            guard url == nil else {
                swiftTool.diagnostics.emit(.error("option '--url' is only supported for binary targets"))
                throw ExitCode.failure
            }
            guard path == nil else {
                swiftTool.diagnostics.emit(.error("option '--path' is only supported for binary targets"))
                throw ExitCode.failure
            }
            guard checksum == nil else {
                swiftTool.diagnostics.emit(.error("option '--checksum' is only supported for binary targets"))
                throw ExitCode.failure
            }
        }
    }

    struct AddProduct: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a product to the current package.")

        @OptionGroup()
        var swiftOptions: SwiftToolOptions

        @Argument(help: "The name of the new product")
        var name: String

        @Option(help: "The type of the new product (library, static-library, dynamic-library, or executable)")
        var type: ProductType?

        @Option(parsing: .upToNextOption,
                help: "A list of target names to add to the new product")
        var targets: [String]

        func run(_ swiftTool: SwiftTool) throws {
            let manifestPath = try Manifest.path(atPackagePath: swiftTool.getPackageRoot(),
                                                 fileSystem: localFileSystem)
            let editor = try PackageEditor(manifestPath: manifestPath,
                                           repositoryManager: swiftTool.getActiveWorkspace().repositoryManager,
                                           toolchain: swiftTool.getToolchain(),
                                           diagnosticsEngine: swiftTool.diagnostics)
            do {
                try editor.addProduct(name: name, type: type ?? .library(.automatic), targets: targets)
            } catch Diagnostics.fatalError {
                throw ExitCode.failure
            }
        }
    }

}

extension Version: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(string: argument)
    }
}

extension ProductType: ExpressibleByArgument {
    public init?(argument: String) {
        switch argument {
        case "library":
            self = .library(.automatic)
        case "static-library":
            self = .library(.static)
        case "dynamic-library":
            self = .library(.dynamic)
        case "executable":
            self = .executable
        default:
            return nil
        }
    }

    public static var defaultCompletionKind: CompletionKind {
        .list(["library", "static-library", "dynamic-library", "executable"])
    }
}
#endif

extension SwiftPackageTool {
    struct Config: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manipulate configuration of the package",
            subcommands: [SetMirror.self, UnsetMirror.self, GetMirror.self])
    }
}

extension SwiftPackageTool.Config {
    struct SetMirror: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set a mirror for a dependency")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Option(help: "The package dependency url")
        var packageURL: String?
        
        @Option(help: "The original url")
        var originalURL: String?
        
        @Option(help: "The mirror url")
        var mirrorURL: String
        
        func run(_ swiftTool: SwiftTool) throws {
            let config = try swiftTool.getSwiftPMConfig()

            if packageURL != nil {
                swiftTool.diagnostics.emit(
                    warning: "'--package-url' option is deprecated; use '--original-url' instead")
            }

            guard let originalURL = packageURL ?? originalURL else {
                swiftTool.diagnostics.emit(.missingRequiredArg("--original-url"))
                throw ExitCode.failure
            }

            config.mirrors.set(mirrorURL: mirrorURL, forURL: originalURL)
            try config.saveState()
        }
    }

    struct UnsetMirror: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove an existing mirror")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Option(help: "The package dependency url")
        var packageURL: String?
        
        @Option(help: "The original url")
        var originalURL: String?
        
        @Option(help: "The mirror url")
        var mirrorURL: String?
        
        func run(_ swiftTool: SwiftTool) throws {
            let config = try swiftTool.getSwiftPMConfig()

            if packageURL != nil {
                swiftTool.diagnostics.emit(
                    warning: "'--package-url' option is deprecated; use '--original-url' instead")
            }

            guard let originalOrMirrorURL = packageURL ?? originalURL ?? mirrorURL else {
                swiftTool.diagnostics.emit(.missingRequiredArg("--original-url or --mirror-url"))
                throw ExitCode.failure
            }

            try config.mirrors.unset(originalOrMirrorURL: originalOrMirrorURL)
            try config.saveState()
        }
    }

    struct GetMirror: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print mirror configuration for the given package dependency")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Option(help: "The package dependency url")
        var packageURL: String?
        
        @Option(help: "The original url")
        var originalURL: String?

        func run(_ swiftTool: SwiftTool) throws {
            let config = try swiftTool.getSwiftPMConfig()

            if packageURL != nil {
                swiftTool.diagnostics.emit(
                    warning: "'--package-url' option is deprecated; use '--original-url' instead")
            }

            guard let originalURL = packageURL ?? originalURL else {
                swiftTool.diagnostics.emit(.missingRequiredArg("--original-url"))
                throw ExitCode.failure
            }

            if let mirror = config.mirrors.mirrorURL(for: originalURL) {
                print(mirror)
            } else {
                stderrStream <<< "not found\n"
                stderrStream.flush()
                throw ExitCode.failure
            }
        }
    }
}

extension SwiftPackageTool {
    struct ResolveOptions: ParsableArguments {
        @Option(help: "The version to resolve at", transform: { Version(string: $0) })
        var version: Version?
        
        @Option(help: "The branch to resolve at")
        var branch: String?
        
        @Option(help: "The revision to resolve at")
        var revision: String?

        @Argument(help: "The name of the package to resolve")
        var packageName: String?
    }
    
    struct Resolve: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Resolve package dependencies")
        
        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        @OptionGroup()
        var resolveOptions: ResolveOptions
        
        func run(_ swiftTool: SwiftTool) throws {
            // If a package is provided, use that to resolve the dependencies.
            if let packageName = resolveOptions.packageName {
                let workspace = try swiftTool.getActiveWorkspace()
                try workspace.resolve(
                    packageName: packageName,
                    root: swiftTool.getWorkspaceRoot(),
                    version: resolveOptions.version,
                    branch: resolveOptions.branch,
                    revision: resolveOptions.revision,
                    diagnostics: swiftTool.diagnostics)
                if swiftTool.diagnostics.hasErrors {
                    throw ExitCode.failure
                }
            } else {
                // Otherwise, run a normal resolve.
                try swiftTool.resolve()
            }
        }
    }
    
    struct Fetch: SwiftCommand {
        static let configuration = CommandConfiguration(shouldDisplay: false)
        
        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @OptionGroup()
        var resolveOptions: ResolveOptions
        
        func run(_ swiftTool: SwiftTool) throws {
            swiftTool.diagnostics.emit(warning: "'fetch' command is deprecated; use 'resolve' instead")
            
            let resolveCommand = Resolve(swiftOptions: _swiftOptions, resolveOptions: _resolveOptions)
            try resolveCommand.run(swiftTool)
        }
    }
}

extension SwiftPackageTool {
    struct CompletionTool: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Completion tool (for shell completions)"
        )

        enum Mode: String, CaseIterable, ExpressibleByArgument {
            case generateBashScript = "generate-bash-script"
            case generateZshScript = "generate-zsh-script"
            case generateFishScript = "generate-fish-script"
            case listDependencies = "list-dependencies"
            case listExecutables = "list-executables"
        }

        /// A dummy version of the root `swift` command, to act as a parent
        /// for all the subcommands.
        fileprivate struct SwiftCommand: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "swift",
                abstract: "The Swift compiler",
                subcommands: [
                    SwiftRunTool.self,
                    SwiftBuildTool.self,
                    SwiftTestTool.self,
                    SwiftPackageTool.self,
                ]
            )
        }
      
        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        @Argument(help: "generate-bash-script | generate-zsh-script |\ngenerate-fish-script | list-dependencies | list-executables")
        var mode: Mode

        func run(_ swiftTool: SwiftTool) throws {
            switch mode {
            case .generateBashScript:
                let script = SwiftCommand.completionScript(for: .bash)
                print(script)
            case .generateZshScript:
                let script = SwiftCommand.completionScript(for: .zsh)
                print(script)
            case .generateFishScript:
                let script = SwiftCommand.completionScript(for: .fish)
                print(script)
            case .listDependencies:
                let graph = try swiftTool.loadPackageGraph()
                dumpDependenciesOf(rootPackage: graph.rootPackages[0], mode: .flatlist)
            case .listExecutables:
                let graph = try swiftTool.loadPackageGraph()
                let package = graph.rootPackages[0].underlyingPackage
                let executables = package.targets.filter { $0.type == .executable }
                for executable in executables {
                    stdoutStream <<< "\(executable.name)\n"
                }
                stdoutStream.flush()
            }
        }
    }
}

private extension Diagnostic.Message {
    static var missingRequiredSubcommand: Diagnostic.Message {
        .error("missing required subcommand; use --help to list available subcommands")
    }

    static func missingRequiredArg(_ argument: String) -> Diagnostic.Message {
        .error("missing required argument \(argument)")
    }
}

/// Logs all changed dependencies to a stream
/// - Parameter changes: Changes to log
/// - Parameter pins: PinsStore with currently pinned packages to compare changed packages to.
/// - Parameter stream: Stream used for logging
fileprivate func logPackageChanges(changes: [(PackageReference, Workspace.PackageStateChange)], pins: PinsStore, on stream: OutputByteStream = TSCBasic.stdoutStream) {
    let changes = changes.filter { $0.1 != .unchanged }
    
    stream <<< "\n"
    stream <<< "\(changes.count) dependenc\(changes.count == 1 ? "y has" : "ies have") changed\(changes.count > 0 ? ":" : ".")"
    stream <<< "\n"
    
    for (package, change) in changes {
        let currentVersion = pins.pinsMap[package.identity]?.state.description ?? ""
        switch change {
        case let .added(state):
            stream <<< "+ \(package.name) \(state.requirement.prettyPrinted)"
        case let .updated(state):
            stream <<< "~ \(package.name) \(currentVersion) -> \(package.name) \(state.requirement.prettyPrinted)"
        case .removed:
            stream <<< "- \(package.name) \(currentVersion)"
        case .unchanged:
            continue
        }
        stream <<< "\n"
    }
    stream.flush()
}
