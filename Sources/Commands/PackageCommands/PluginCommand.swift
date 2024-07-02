//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import Basics
import CoreCommands
import Dispatch

import PackageGraph

import PackageModel

struct PluginCommand: AsyncSwiftCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Invoke a command plugin or perform other actions on command plugins"
    )

    @OptionGroup(visibility: .hidden)
    var globalOptions: GlobalOptions

    @Flag(
        name: .customLong("list"),
        help: "List the available command plugins"
    )
    var listCommands: Bool = false

    struct PluginOptions: ParsableArguments {
        @Flag(
            name: .customLong("allow-writing-to-package-directory"),
            help: "Allow the plugin to write to the package directory"
        )
        var allowWritingToPackageDirectory: Bool = false

        @Option(
            name: .customLong("allow-writing-to-directory"),
            help: "Allow the plugin to write to an additional directory"
        )
        var additionalAllowedWritableDirectories: [String] = []

        enum NetworkPermission: EnumerableFlag, ExpressibleByArgument {
            static var allCases: [PluginCommand.PluginOptions.NetworkPermission] {
                return [.none, .local(ports: []), .all(ports: []), .docker, .unixDomainSocket]
            }

            case none
            case local(ports: [Int])
            case all(ports: [Int])
            case docker
            case unixDomainSocket

            init?(argument: String) {
                let arg = argument.lowercased()
                switch arg {
                case "none":
                    self = .none
                case "docker":
                    self = .docker
                case "unixdomainsocket":
                    self = .unixDomainSocket
                default:
                    if "all" == arg.prefix(3) {
                        let ports = Self.parsePorts(arg)
                        self = .all(ports: ports)
                    } else if "local" == arg.prefix(5) {
                        let ports = Self.parsePorts(arg)
                        self = .local(ports: ports)
                    } else {
                        return nil
                    }
                }
            }

            static func parsePorts(_ string: String) -> [Int] {
                let parts = string.split(separator: ":")
                guard parts.count == 2 else {
                    return []
                }
                return parts[1]
                    .split(separator: ",")
                    .compactMap{ String($0).spm_chuzzle() }
                    .compactMap { Int($0) }
            }

            var remedyDescription: String {
                switch self {
                case .none:
                    return "none"
                case .local(let ports):
                    if ports.isEmpty {
                        return "local"
                    } else {
                        return "local:\(ports.map(String.init).joined(separator: ","))"
                    }
                case .all(let ports):
                    if ports.isEmpty {
                        return "all"
                    } else {
                        return "all:\(ports.map(String.init).joined(separator: ","))"
                    }
                case .docker:
                    return "docker"
                case .unixDomainSocket:
                    return "unixDomainSocket"
                }
            }
        }

        @Option(name: .customLong("allow-network-connections"))
        var allowNetworkConnections: NetworkPermission = .none

        @Option(
            name: .customLong("package"),
            help: "Limit available plugins to a single package with the given identity"
        )
        var packageIdentity: String? = nil
    }

    @OptionGroup()
    var pluginOptions: PluginOptions

    @Argument(help: "Verb of the command plugin to invoke")
    var command: String = ""

    @Argument(
        parsing: .captureForPassthrough,
        help: "Arguments to pass to the command plugin"
    )
    var arguments: [String] = []

    func run(_ swiftCommandState: SwiftCommandState) async throws {
        // Check for a missing plugin command verb.
        if self.command == "" && !self.listCommands {
            throw ValidationError("Missing expected plugin command")
        }

        // List the available plugins, if asked to.
        if self.listCommands {
            let packageGraph = try swiftCommandState.loadPackageGraph()
            let allPlugins = PluginCommand.availableCommandPlugins(
                in: packageGraph,
                limitedTo: self.pluginOptions.packageIdentity
            ).map {
                $0.underlying as! PluginModule
            }
            for plugin in allPlugins.sorted(by: { $0.name < $1.name }) {
                guard case .command(let intent, _) = plugin.capability else { continue }
                var line = "‘\(intent.invocationVerb)’ (plugin ‘\(plugin.name)’"
                if let package = packageGraph.packages
                    .first(where: { $0.modules.contains(where: { $0.name == plugin.name }) })
                {
                    line += " in package ‘\(package.manifest.displayName)’"
                }
                line += ")"
                print(line)
            }
            return
        }

        try await Self.run(
            command: self.command,
            options: self.pluginOptions,
            arguments: self.arguments,
            swiftCommandState: swiftCommandState
        )
    }

    static func run(
        command: String,
        options: PluginOptions,
        arguments: [String],
        swiftCommandState: SwiftCommandState
    ) async throws {
        // Load the workspace and resolve the package graph.
        let packageGraph = try swiftCommandState.loadPackageGraph()

        swiftCommandState.observabilityScope.emit(info: "Finding plugin for command ‘\(command)’")
        let matchingPlugins = PluginCommand.findPlugins(matching: command, in: packageGraph, limitedTo: options.packageIdentity)

        // Complain if we didn't find exactly one.
        if matchingPlugins.isEmpty {
            throw ValidationError("Unknown subcommand or plugin name ‘\(command)’")
        } else if matchingPlugins.count > 1 {
            throw ValidationError("\(matchingPlugins.count) plugins found for ‘\(command)’")
        }

        // handle plugin execution arguments that got passed after the plugin name
        let unparsedArguments = Array(arguments.drop(while: { $0 == command }))
        let pluginArguments = try PluginArguments.parse(unparsedArguments)
        // merge the relevant plugin execution options
        let pluginOptions = options.merged(with: pluginArguments.pluginOptions)
        // sandbox is special since its generic not a specific plugin option
        swiftCommandState.shouldDisableSandbox = swiftCommandState.shouldDisableSandbox || pluginArguments.globalOptions.security
            .shouldDisableSandbox

        // At this point we know we found exactly one command plugin, so we run it. In SwiftPM CLI, we have only one root package.
        try await PluginCommand.run(
            plugin: matchingPlugins[0],
            package: packageGraph.rootPackages[packageGraph.rootPackages.startIndex],
            packageGraph: packageGraph,
            options: pluginOptions,
            arguments: unparsedArguments,
            swiftCommandState: swiftCommandState
        )
    }

    static func run(
        plugin: ResolvedModule,
        package: ResolvedPackage,
        packageGraph: ModulesGraph,
        options: PluginOptions,
        arguments: [String],
        swiftCommandState: SwiftCommandState
    ) async throws {
        let pluginTarget = plugin.underlying as! PluginModule

        swiftCommandState.observabilityScope
            .emit(
                info: "Running command plugin \(plugin) on package \(package) with options \(options) and arguments \(arguments)"
            )

        // The `plugins` directory is inside the workspace's main data directory, and contains all temporary files related to this plugin in the workspace.
        let pluginsDir = try swiftCommandState.getActiveWorkspace().location.pluginWorkingDirectory
            .appending(component: plugin.name)

        // The `cache` directory is in the plugin’s directory and is where the plugin script runner caches compiled plugin binaries and any other derived information for this plugin.
        let pluginScriptRunner = try swiftCommandState.getPluginScriptRunner(
            customPluginsDir: pluginsDir
        )

        // The `outputs` directory contains subdirectories for each combination of package and command plugin. Each usage of a plugin has an output directory that is writable by the plugin, where it can write additional files, and to which it can configure tools to write their outputs, etc.
        let outputDir = pluginsDir.appending("outputs")

        var allowNetworkConnections = [SandboxNetworkPermission(options.allowNetworkConnections)]
        // Determine the set of directories under which plugins are allowed to write. We always include the output directory.
        var writableDirectories = [outputDir]
        if options.allowWritingToPackageDirectory {
            writableDirectories.append(package.path)
        }

        // If the plugin requires permissions, we ask the user for approval.
        if case .command(_, let permissions) = pluginTarget.capability {
            try permissions.forEach {
                let permissionString: String
                let reasonString: String
                let remedyOption: String

                switch $0 {
                case .writeToPackageDirectory(let reason):
                    guard !options.allowWritingToPackageDirectory else { return } // permission already granted
                    permissionString = "write to the package directory"
                    reasonString = reason
                    remedyOption = "--allow-writing-to-package-directory"
                case .allowNetworkConnections(let scope, let reason):
                    guard scope != .none else { return } // no need to prompt
                    guard options.allowNetworkConnections != .init(scope) else { return } // permission already granted

                    switch scope {
                    case .all, .local:
                        let portsString = scope.ports
                            .isEmpty ? "on all ports" :
                            "on ports: \(scope.ports.map { "\($0)" }.joined(separator: ", "))"
                        permissionString = "allow \(scope.label) network connections \(portsString)"
                    case .docker, .unixDomainSocket:
                        permissionString = "allow \(scope.label) connections"
                    case .none:
                        permissionString = "" // should not be reached
                    }

                    reasonString = reason
                    remedyOption =
                        "--allow-network-connections \(PluginCommand.PluginOptions.NetworkPermission(scope).remedyDescription)"
                }

                let problem = "Plugin ‘\(plugin.name)’ wants permission to \(permissionString)."
                let reason = "Stated reason: “\(reasonString)”."
                if swiftCommandState.outputStream.isTTY {
                    // We can ask the user directly, so we do so.
                    let query = "Allow this plugin to \(permissionString)?"
                    swiftCommandState.outputStream.write("\(problem)\n\(reason)\n\(query) (yes/no) ".utf8)
                    swiftCommandState.outputStream.flush()
                    let answer = readLine(strippingNewline: true)
                    // Throw an error if we didn't get permission.
                    if answer?.lowercased() != "yes" {
                        throw StringError("Plugin was denied permission to \(permissionString).")
                    }
                } else {
                    // We can't ask the user, so emit an error suggesting passing the flag.
                    let remedy = "Use `\(remedyOption)` to allow this."
                    throw StringError([problem, reason, remedy].joined(separator: "\n"))
                }

                switch $0 {
                case .writeToPackageDirectory:
                    // Otherwise append the directory to the list of allowed ones.
                    writableDirectories.append(package.path)
                case .allowNetworkConnections(let scope, _):
                    allowNetworkConnections.append(.init(scope))
                }
            }
        }

        for pathString in options.additionalAllowedWritableDirectories {
            writableDirectories
                .append(try AbsolutePath(validating: pathString, relativeTo: swiftCommandState.originalWorkingDirectory))
        }

        // Make sure that the package path is read-only unless it's covered by any of the explicitly writable directories.
        let readOnlyDirectories = writableDirectories
            .contains { package.path.isDescendantOfOrEqual(to: $0) } ? [] : [package.path]

        // Use the directory containing the compiler as an additional search directory, and add the $PATH.
        let toolSearchDirs = [try swiftCommandState.getTargetToolchain().swiftCompilerPath.parentDirectory]
            + getEnvSearchPaths(pathString: Environment.current[.path], currentWorkingDirectory: .none)

        let buildParameters = try swiftCommandState.toolsBuildParameters
        // Build or bring up-to-date any executable host-side tools on which this plugin depends. Add them and any binary dependencies to the tool-names-to-path map.
        let buildSystem = try swiftCommandState.createBuildSystem(
            explicitBuildSystem: .native,
            traitConfiguration: .init(),
            cacheBuildManifest: false,
            productsBuildParameters: swiftCommandState.productsBuildParameters,
            toolsBuildParameters: buildParameters,
            packageGraphLoader: { packageGraph }
        )

        let accessibleTools = try plugin.preparePluginTools(
            fileSystem: swiftCommandState.fileSystem,
            environment: buildParameters.buildEnvironment,
            for: try pluginScriptRunner.hostTriple
        ) { name, _ in
            // Build the product referenced by the tool, and add the executable to the tool map. Product dependencies are not supported within a package, so if the tool happens to be from the same package, we instead find the executable that corresponds to the product. There is always one, because of autogeneration of implicit executables with the same name as the target if there isn't an explicit one.
            try await buildSystem.build(subset: .product(name, for: .host))
            if let builtTool = try buildSystem.buildPlan.buildProducts.first(where: {
                $0.product.name == name && $0.buildParameters.destination == .host
            }) {
                return try builtTool.binaryPath
            } else {
                return nil
            }
        }

        // Set up a delegate to handle callbacks from the command plugin.
        let pluginDelegate = PluginDelegate(swiftCommandState: swiftCommandState, plugin: pluginTarget)
        let delegateQueue = DispatchQueue(label: "plugin-invocation")

        // Run the command plugin.
        let buildEnvironment = buildParameters.buildEnvironment
        let _ = try temp_await { pluginTarget.invoke(
            action: .performCommand(package: package, arguments: arguments),
            buildEnvironment: buildEnvironment,
            scriptRunner: pluginScriptRunner,
            workingDirectory: swiftCommandState.originalWorkingDirectory,
            outputDirectory: outputDir,
            toolSearchDirectories: toolSearchDirs,
            accessibleTools: accessibleTools,
            writableDirectories: writableDirectories,
            readOnlyDirectories: readOnlyDirectories,
            allowNetworkConnections: allowNetworkConnections,
            pkgConfigDirectories: swiftCommandState.options.locations.pkgConfigDirectories,
            sdkRootPath: buildParameters.toolchain.sdkRootPath,
            fileSystem: swiftCommandState.fileSystem,
            modulesGraph: packageGraph,
            observabilityScope: swiftCommandState.observabilityScope,
            callbackQueue: delegateQueue,
            delegate: pluginDelegate,
            completion: $0
        ) }

        // TODO: We should also emit a final line of output regarding the result.
    }

    static func availableCommandPlugins(in graph: ModulesGraph, limitedTo packageIdentity: String?) -> [ResolvedModule] {
        // All targets from plugin products of direct dependencies are "available".
        let directDependencyPackages = graph.rootPackages.flatMap {
            $0.dependencies
        }.filter {
            $0.matching(identity: packageIdentity)
        }.compactMap {
            graph.package(for: $0)
        }

        let directDependencyPluginTargets = directDependencyPackages.flatMap { $0.products.filter { $0.type == .plugin } }.flatMap { $0.modules }
        // As well as any plugin targets in root packages.
        let rootPackageTargets = graph.rootPackages.filter { $0.identity.matching(identity: packageIdentity) }.flatMap { $0.modules }
        return (directDependencyPluginTargets + rootPackageTargets).filter {
            guard let plugin = $0.underlying as? PluginModule else {
                return false
            }

            return switch plugin.capability {
            case .buildTool: false
            case .command: true
            }
        }
    }

    static func findPlugins(matching verb: String, in graph: ModulesGraph, limitedTo packageIdentity: String?) -> [ResolvedModule] {
        // Find and return the command plugins that match the command.
        Self.availableCommandPlugins(in: graph, limitedTo: packageIdentity).filter {
            let plugin = $0.underlying as! PluginModule
            // Filter out any non-command plugins and any whose verb is different.
            guard case .command(let intent, _) = plugin.capability else { return false }
            return verb == intent.invocationVerb
        }
    }
}

// helper to parse plugin arguments passed after the plugin name
struct PluginArguments: ParsableCommand {
    static var configuration: CommandConfiguration {
        .init(helpNames: [])
    }

    @OptionGroup
    var globalOptions: GlobalOptions

    @OptionGroup()
    var pluginOptions: PluginCommand.PluginOptions

    @Argument(parsing: .allUnrecognized)
    var remaining: [String] = []
}

extension PluginCommandIntent {
    var invocationVerb: String {
        switch self {
        case .documentationGeneration:
            return "generate-documentation"
        case .sourceCodeFormatting:
            return "format-source-code"
        case .custom(let verb, _):
            return verb
        }
    }
}

extension SandboxNetworkPermission {
    init(_ scope: PluginNetworkPermissionScope) {
        switch scope {
        case .none: self = .none
        case .local(let ports): self = .local(ports: ports)
        case .all(let ports): self = .all(ports: ports)
        case .docker: self = .docker
        case .unixDomainSocket: self = .unixDomainSocket
        }
    }
}

extension PluginCommand.PluginOptions.NetworkPermission {
    fileprivate init(_ scope: PluginNetworkPermissionScope) {
        switch scope {
        case .unixDomainSocket: self = .unixDomainSocket
        case .docker: self = .docker
        case .none: self = .none
        case .all(let ports): self = .all(ports: ports)
        case .local(let ports): self = .local(ports: ports)
        }
    }
}

extension SandboxNetworkPermission {
    init(_ permission: PluginCommand.PluginOptions.NetworkPermission) {
        switch permission {
        case .none: self = .none
        case .local(let ports): self = .local(ports: ports)
        case .all(let ports): self = .all(ports: ports)
        case .docker: self = .docker
        case .unixDomainSocket: self = .unixDomainSocket
        }
    }
}

extension PackageIdentity {
    fileprivate func matching(identity: String?) -> Bool {
        if let identity {
            return self == .plain(identity)
        } else {
            return true
        }
    }
}
