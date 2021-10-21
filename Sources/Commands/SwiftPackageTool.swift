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
import PackageModel

/// swift-package tool namespace
public struct SwiftPackageTool: ParsableCommand {
    public static var configuration = CommandConfiguration(
        commandName: "package",
        _superCommandName: "swift",
        abstract: "Perform operations on Swift packages",
        discussion: "SEE ALSO: swift build, swift run, swift test",
        version: SwiftVersion.currentVersion.completeDisplayString,
        subcommands: [
            Clean.self,
            PurgeCache.self,
            Reset.self,
            Update.self,
            Describe.self,
            Init.self,
            Format.self,

            APIDiff.self,
            DeprecatedAPIDiff.self,
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
        ] + (ProcessInfo.processInfo.environment["SWIFTPM_ENABLE_SNIPPETS"] == "1" ? [Learn.self] : [ParsableCommand.Type]()),
        helpNames: [.short, .long, .customLong("help", withSingleDash: true)])

    @OptionGroup()
    var swiftOptions: SwiftToolOptions

    public init() {}

    public static var _errorLabel: String { "error" }
}

extension InitPackage.PackageType: ExpressibleByArgument {}

extension SwiftPackageTool {
    struct Clean: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete build artifacts")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        func run(_ swiftTool: SwiftTool) throws {
            try swiftTool.getActiveWorkspace().clean(with: swiftTool.observabilityScope.makeDiagnosticsEngine())
        }
    }

    struct PurgeCache: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Purge the global repository cache.")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        func run(_ swiftTool: SwiftTool) throws {
            try swiftTool.getActiveWorkspace().purgeCache(with: swiftTool.observabilityScope.makeDiagnosticsEngine())
        }
    }

    struct Reset: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reset the complete cache/build directory")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        func run(_ swiftTool: SwiftTool) throws {
            try swiftTool.getActiveWorkspace().reset(with: swiftTool.observabilityScope.makeDiagnosticsEngine())
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
                diagnostics: swiftTool.observabilityScope.makeDiagnosticsEngine(),
                dryRun: dryRun
            )

            // try to load the graph which will emit any errors
            if !swiftTool.observabilityScope.errorsReported {
                _ = try workspace.loadPackageGraph(
                    rootInput: swiftTool.getWorkspaceRoot(),
                    observabilityScope: swiftTool.observabilityScope
                )
            }

            if let pinsStore = swiftTool.observabilityScope.trap({ try workspace.pinsStore.load() }), let changes = changes, dryRun {
                logPackageChanges(changes: changes, pins: pinsStore, on: swiftTool.outputStream)
            }

            if !dryRun {
                // Throw if there were errors when loading the graph.
                // The actual errors will be printed before exiting.
                guard !swiftTool.observabilityScope.errorsReported else {
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
                workspace.loadRootManifests(packages: root.packages, diagnostics: swiftTool.observabilityScope.makeDiagnosticsEngine(), completion: $0)
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
                fileSystem: localFileSystem,
                observabilityScope: swiftTool.observabilityScope
            )
            let package = try builder.construct()
            self.describe(package, in: type, on: swiftTool.outputStream)
        }

        /// Emits a textual description of `package` to `stream`, in the format indicated by `mode`.
        func describe(_ package: Package, in mode: DescribeMode, on stream: OutputByteStream) {
            let desc = DescribedPackage(from: package)
            let data: Data
            switch mode {
            case .json:
                let encoder = JSONEncoder.makeWithDefaults()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                data = try! encoder.encode(desc)
            case .text:
                var encoder = PlainTextEncoder()
                encoder.formattingOptions = [.prettyPrinted]
                data = try! encoder.encode(desc)
            }
            stream <<< String(decoding: data, as: UTF8.self) <<< "\n"
            stream.flush()
        }

        enum DescribeMode: String, ExpressibleByArgument {
            /// JSON format (guaranteed to be parsable and stable across time).
            case json
            /// Human readable format (not guaranteed to be parsable).
            case text
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
                name: packageName,
                destinationPath: cwd,
                packageType: initMode
            )
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
                swiftTool.observabilityScope.emit(error: "Could not find swift-format in PATH or SWIFT_FORMAT")
                throw Diagnostics.fatalError
            }

            // Get the root package.
            let workspace = try swiftTool.getActiveWorkspace()
            let root = try swiftTool.getWorkspaceRoot()
            let rootManifests = try temp_await {
                workspace.loadRootManifests(
                    packages: root.packages,
                    diagnostics: swiftTool.observabilityScope.makeDiagnosticsEngine(),
                    completion: $0
                )
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
                fileSystem: localFileSystem,
                observabilityScope: swiftTool.observabilityScope
            )
            let package = try builder.construct()

            // Use the user provided flags or default to formatting mode.
            let formatOptions = swiftFormatFlags.isEmpty
                ? ["--mode", "format", "--in-place", "--parallel"]
                : swiftFormatFlags

            // Process each target in the root package.
            let paths = package.targets.flatMap { target in
                target.sources.paths.filter { file in
                    file.extension == SupportedLanguageExtension.swift.rawValue
                }
            }.map { $0.pathString }

            let args = [swiftFormat.pathString] + formatOptions + [rootManifest.path.pathString] + paths
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

    struct DeprecatedAPIDiff: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "experimental-api-diff",
                                                        abstract: "Deprecated - use `swift package diagnose-api-breaking-changes` instead",
                                                        shouldDisplay: false)

        @Argument(parsing: .unconditionalRemaining)
        var args: [String] = []

        func run() throws {
            print("`swift package experimental-api-diff` has been renamed to `swift package diagnose-api-breaking-changes`")
            throw ExitCode.failure
        }
    }

    struct APIDiff: SwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: "diagnose-api-breaking-changes",
            abstract: "Diagnose API-breaking changes to Swift modules in a package",
            discussion: """
            The diagnose-api-breaking-changes command can be used to compare the Swift API of \
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

            let packageRoot = try swiftOptions.packagePath ?? swiftTool.getPackageRoot()
            let repository = GitRepository(path: packageRoot)
            let baselineRevision = try repository.resolveRevision(identifier: treeish)

            // We turn build manifest caching off because we need the build plan.
            let buildOp = try swiftTool.createBuildOperation(cacheBuildManifest: false)

            let packageGraph = try buildOp.getPackageGraph()
            let modulesToDiff = try determineModulesToDiff(
                packageGraph: packageGraph,
                diagnostics: swiftTool.observabilityScope.makeDiagnosticsEngine()
            )

            // Build the current package.
            try buildOp.build()

            // Dump JSON for the baseline package.
            let baselineDumper = try APIDigesterBaselineDumper(
                baselineRevision: baselineRevision,
                packageRoot: swiftTool.getPackageRoot(),
                buildParameters: buildOp.buildParameters,
                apiDigesterTool: apiDigesterTool,
                observabilityScope: swiftTool.observabilityScope
            )

            let baselineDir = try baselineDumper.emitAPIBaseline(
                for: modulesToDiff,
                at: overrideBaselineDir,
                force: regenerateBaseline,
                outputStream: swiftTool.outputStream
            )

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
                swiftTool.observabilityScope.emit(error: "failed to read API digester output for \(failedModule)")
            }

            for result in results.get() {
                printComparisonResult(result, diagnosticsEngine: swiftTool.observabilityScope.makeDiagnosticsEngine())
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
                        diagnostics.emit(error: "no such product '\(productName)'")
                        continue
                    }
                    guard product.type.isLibrary else {
                        diagnostics.emit(error: "'\(productName)' is not a library product")
                        continue
                    }
                    modulesToDiff.formUnion(product.targets.filter { $0.underlyingTarget is SwiftTarget }.map(\.c99name))
                }
                for targetName in targets {
                    guard let target = packageGraph
                            .rootPackages
                            .flatMap(\.targets)
                            .first(where: { $0.name == targetName }) else {
                        diagnostics.emit(error: "no such target '\(targetName)'")
                        continue
                    }
                    guard target.type == .library else {
                        diagnostics.emit(error: "'\(targetName)' is not a library target")
                        continue
                    }
                    guard target.underlyingTarget is SwiftTarget else {
                        diagnostics.emit(error: "'\(targetName)' is not a Swift language target")
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
        static let defaultMinimumAccessLevel = AccessLevel.public

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        @Flag(help: "Pretty-print the output JSON.")
        var prettyPrint = false

        @Flag(help: "Skip members inherited through classes or default implementations.")
        var skipSynthesizedMembers = false

        @Option(help: "Include symbols with this access level or more. Possible values: \(AccessLevel.allValueStrings.joined(separator: " | "))")
        var minimumAccessLevel = defaultMinimumAccessLevel

        @Flag(help: "Skip emitting doc comments for members inherited through classes or default implementations.")
        var skipInheritedDocs = false

        @Flag(help: "Add symbols with SPI information to the symbol graph.")
        var includeSPISymbols = false

        func run(_ swiftTool: SwiftTool) throws {
            let symbolGraphExtract = try SymbolGraphExtract(
                tool: swiftTool.getToolchain().getSymbolGraphExtract())

            // Build the current package.
            //
            // We turn build manifest caching off because we need the build plan.
            let buildOp = try swiftTool.createBuildOperation(cacheBuildManifest: false)
            try buildOp.build()

            try symbolGraphExtract.dumpSymbolGraph(
                buildPlan: buildOp.buildPlan!,
                prettyPrint: prettyPrint,
                skipSynthesisedMembers: skipSynthesizedMembers,
                minimumAccessLevel: minimumAccessLevel,
                skipInheritedDocs: skipInheritedDocs,
                includeSPISymbols: includeSPISymbols
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
                workspace.loadRootManifests(
                    packages: root.packages,
                    diagnostics: swiftTool.observabilityScope.makeDiagnosticsEngine(),
                    completion: $0
                )
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
            let builder = PIFBuilder(
                graph: graph,
                parameters: parameters,
                fileSystem: localFileSystem,
                observabilityScope: swiftTool.observabilityScope
            )
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
                diagnostics: swiftTool.observabilityScope.makeDiagnosticsEngine()
            )
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
                diagnostics: swiftTool.observabilityScope.makeDiagnosticsEngine()
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
            let stream = try outputPath.map { try LocalFileOutputByteStream($0) } ?? swiftTool.outputStream
            Self.dumpDependenciesOf(rootPackage: graph.rootPackages[0], mode: format, on: stream)
        }

        static func dumpDependenciesOf(rootPackage: ResolvedPackage, mode: ShowDependenciesMode, on stream: OutputByteStream) {
            let dumper: DependenciesDumper
            switch mode {
            case .text:
                dumper = PlainTextDumper()
            case .dot:
                dumper = DotDumper()
            case .json:
                dumper = JSONDumper()
            case .flatlist:
                dumper = FlatListDumper()
            }
            dumper.dump(dependenciesOf: rootPackage, on: stream)
            stream.flush()
        }

        enum ShowDependenciesMode: String, RawRepresentable, CustomStringConvertible, ExpressibleByArgument {
            case text, dot, json, flatlist

            public init?(rawValue: String) {
                switch rawValue.lowercased() {
                case "text":
                   self = .text
                case "dot":
                   self = .dot
                case "json":
                   self = .json
                case "flatlist":
                    self = .flatlist
                default:
                    return nil
                }
            }

            public var description: String {
                switch self {
                case .text: return "text"
                case .dot: return "dot"
                case .json: return "json"
                case .flatlist: return "flatlist"
                }
            }
        }
    }

    struct ToolsVersionCommand: SwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: "tools-version",
            abstract: "Manipulate tools version of the current package")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

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
                    // FIXME: Probably lift this error definition to ToolsVersion.
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
                diagnostics: swiftTool.observabilityScope.makeDiagnosticsEngine()
            )

            guard !swiftTool.observabilityScope.errorsReported else {
                throw ExitCode.failure
            }

            swiftTool.outputStream <<< checksum <<< "\n"
            swiftTool.outputStream.flush()
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

            if destination.isDescendantOfOrEqual(to: packageRoot) {
                let relativePath = destination.relative(to: packageRoot)
                swiftTool.outputStream <<< "Created \(relativePath.pathString)" <<< "\n"
            } else {
                swiftTool.outputStream <<< "Created \(destination.pathString)" <<< "\n"
            }

            swiftTool.outputStream.flush()
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
            swiftTool.observabilityScope.emit(warning: "Xcode can open and build Swift Packages directly. 'generate-xcodeproj' is no longer needed and will be deprecated soon.")

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
                fileSystem: localFileSystem,
                observabilityScope: swiftTool.observabilityScope
            )

            print("generated:", xcodeprojPath.prettyPath(cwd: swiftTool.originalWorkingDirectory))

            // Run the file watcher if requested.
            if options.enableAutogeneration {
                try WatchmanHelper(
                    watchmanScriptsDir: swiftTool.buildPath.appending(component: "watchman"),
                    packageRoot: swiftTool.packageRoot!,
                    fileSystem: localFileSystem,
                    observabilityScope: swiftTool.observabilityScope
                ).runXcodeprojWatcher(xcodeprojOptions())
            }
        }
    }
}

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
            let config = try swiftTool.getMirrorsConfig()

            if packageURL != nil {
                swiftTool.observabilityScope.emit(
                    warning: "'--package-url' option is deprecated; use '--original-url' instead")
            }

            guard let originalURL = packageURL ?? originalURL else {
                swiftTool.observabilityScope.emit(.missingRequiredArg("--original-url"))
                throw ExitCode.failure
            }

            try config.applyLocal { mirrors in
                mirrors.set(mirrorURL: mirrorURL, forURL: originalURL)
            }
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
            let config = try swiftTool.getMirrorsConfig()

            if packageURL != nil {
                swiftTool.observabilityScope.emit(
                    warning: "'--package-url' option is deprecated; use '--original-url' instead")
            }

            guard let originalOrMirrorURL = packageURL ?? originalURL ?? mirrorURL else {
                swiftTool.observabilityScope.emit(.missingRequiredArg("--original-url or --mirror-url"))
                throw ExitCode.failure
            }

            try config.applyLocal { mirrors in
                try mirrors.unset(originalOrMirrorURL: originalOrMirrorURL)
            }
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
            let config = try swiftTool.getMirrorsConfig()

            if packageURL != nil {
                swiftTool.observabilityScope.emit(
                    warning: "'--package-url' option is deprecated; use '--original-url' instead")
            }

            guard let originalURL = packageURL ?? originalURL else {
                swiftTool.observabilityScope.emit(.missingRequiredArg("--original-url"))
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
        @Option(help: "The version to resolve at", transform: { Version($0) })
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
                    diagnostics: swiftTool.observabilityScope.makeDiagnosticsEngine()
                )
                if swiftTool.observabilityScope.errorsReported {
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
            swiftTool.observabilityScope.emit(warning: "'fetch' command is deprecated; use 'resolve' instead")

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
            case listSnippets = "list-snippets"
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
                ShowDependencies.dumpDependenciesOf(rootPackage: graph.rootPackages[0], mode: .flatlist, on: swiftTool.outputStream)
            case .listExecutables:
                let graph = try swiftTool.loadPackageGraph()
                let package = graph.rootPackages[0].underlyingPackage
                let executables = package.targets.filter { $0.type == .executable }
                for executable in executables {
                    swiftTool.outputStream <<< "\(executable.name)\n"
                }
                swiftTool.outputStream.flush()
            case .listSnippets:
                let graph = try swiftTool.loadPackageGraph()
                let package = graph.rootPackages[0].underlyingPackage
                let executables = package.targets.filter { $0.type == .snippet }
                for executable in executables {
                    swiftTool.outputStream <<< "\(executable.name)\n"
                }
                swiftTool.outputStream.flush()
            }
        }
    }
}

extension SwiftPackageTool {
    struct Learn: SwiftCommand {

        @OptionGroup()
        var swiftOptions: SwiftToolOptions

        static let configuration = CommandConfiguration(abstract: "Learn about Swift and this package")

        func files(in directory: AbsolutePath, fileExtension: String? = nil) throws -> [AbsolutePath] {
            guard localFileSystem.isDirectory(directory) else {
                return []
            }

            let files = try localFileSystem.getDirectoryContents(directory)
                .map { directory.appending(RelativePath($0)) }
                .filter { localFileSystem.isFile($0) }

            guard let fileExtension = fileExtension else {
                return files
            }

            return files.filter { $0.extension == fileExtension }
        }

        func subdirectories(in directory: AbsolutePath) throws -> [AbsolutePath] {
            guard localFileSystem.isDirectory(directory) else {
                return []
            }
            return try localFileSystem.getDirectoryContents(directory)
                .map { directory.appending(RelativePath($0)) }
                .filter { localFileSystem.isDirectory($0) }
        }

        func loadSnippetsAndSnippetGroups(from package: ResolvedPackage) throws -> [SnippetGroup] {
            let snippetsDirectory = package.path.appending(component: "Snippets")
            guard localFileSystem.isDirectory(snippetsDirectory) else {
                return []
            }

            let topLevelSnippets = try files(in: snippetsDirectory, fileExtension: "swift")
                .map { try Snippet(parsing: $0) }

            let topLevelSnippetGroup = SnippetGroup(name: "Getting Started",
                                                    baseDirectory: snippetsDirectory,
                                                    snippets: topLevelSnippets,
                                                    explanation: "")

            let subdirectoryGroups = try subdirectories(in: snippetsDirectory)
                .map { subdirectory -> SnippetGroup in
                    let snippets = try files(in: subdirectory, fileExtension: "swift")
                        .map { try Snippet(parsing: $0) }

                    let explanationFile = subdirectory.appending(component: "Explanation.md")

                    let snippetGroupExplanation: String
                    if localFileSystem.isFile(explanationFile) {
                        snippetGroupExplanation = try String(contentsOf: explanationFile.asURL)
                    } else {
                        snippetGroupExplanation = ""
                    }

                    return SnippetGroup(name: subdirectory.basename,
                                        baseDirectory: subdirectory,
                                        snippets: snippets,
                                        explanation: snippetGroupExplanation)
                }

            let snippetGroups = [topLevelSnippetGroup] + subdirectoryGroups.sorted {
                $0.baseDirectory.basename < $1.baseDirectory.basename
            }

            return snippetGroups.filter { !$0.snippets.isEmpty }
        }

        func run(_ swiftTool: SwiftTool) throws {
            let graph = try swiftTool.loadPackageGraph()
            let package = graph.rootPackages[0]
            print(package.products.map { $0.description })

            let snippetGroups = try loadSnippetsAndSnippetGroups(from: package)

            var cardStack = CardStack(package: package, snippetGroups: snippetGroups, swiftTool: swiftTool)

            cardStack.run()
        }
    }
}

private extension Basics.Diagnostic {
    static var missingRequiredSubcommand: Self {
        .error("missing required subcommand; use --help to list available subcommands")
    }

    static func missingRequiredArg(_ argument: String) -> Self {
        .error("missing required argument \(argument)")
    }
}

/// Logs all changed dependencies to a stream
/// - Parameter changes: Changes to log
/// - Parameter pins: PinsStore with currently pinned packages to compare changed packages to.
/// - Parameter stream: Stream used for logging
fileprivate func logPackageChanges(changes: [(PackageReference, Workspace.PackageStateChange)], pins: PinsStore, on stream: OutputByteStream) {
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
