/*
This source file is part of the Swift.org open source project

Copyright 2015 - 2016 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import ArgumentParser
import Basics
import Build
import PackageGraph
import PackageModel
import TSCBasic

import enum TSCUtility.Diagnostics

/// An enumeration of the errors that can be generated by the run tool.
private enum RunError: Swift.Error {
    /// The package manifest has no executable product.
    case noExecutableFound

    /// Could not find a specific executable in the package manifest.
    case executableNotFound(String)

    /// There are multiple executables and one must be chosen.
    case multipleExecutables([String])
}

extension RunError: CustomStringConvertible {
    var description: String {
        switch self {
        case .noExecutableFound:
            return "no executable product available"
        case .executableNotFound(let executable):
            return "no executable product named '\(executable)'"
        case .multipleExecutables(let executables):
            let joinedExecutables = executables.joined(separator: ", ")
            return "multiple executable products available: \(joinedExecutables)"
        }
    }
}

struct RunToolOptions: ParsableArguments {
    enum RunMode: EnumerableFlag {
        case repl
        case debugger
        case run

        static func help(for value: RunToolOptions.RunMode) -> ArgumentHelp? {
            switch value {
            case .repl:
                return "Launch Swift REPL for the package"
            case .debugger:
                return "Launch the executable in a debugger session"
            case .run:
                return "Launch the executable with the provided arguments"
            }
        }
    }

    /// The mode in with the tool command should run.
    @Flag var mode: RunMode = .run

    /// If the executable product should be built before running.
    @Flag(name: .customLong("skip-build"), help: "Skip building the executable product")
    var shouldSkipBuild: Bool = false

    var shouldBuild: Bool { !shouldSkipBuild }

    /// If the test should be built.
    @Flag(name: .customLong("build-tests"), help: "Build both source and test targets")
    var shouldBuildTests: Bool = false

    /// The executable product to run.
    @Argument(help: "The executable to run", completion: .shellCommand("swift package completion-tool list-executables"))
    var executable: String?

    /// The arguments to pass to the executable.
    @Argument(parsing: .unconditionalRemaining,
              help: "The arguments to pass to the executable")
    var arguments: [String] = []
}

/// swift-run tool namespace
public struct SwiftRunTool: SwiftCommand {
    public static var configuration = CommandConfiguration(
        commandName: "run",
        _superCommandName: "swift",
        abstract: "Build and run an executable product",
        discussion: "SEE ALSO: swift build, swift package, swift test",
        version: SwiftVersion.current.completeDisplayString,
        helpNames: [.short, .long, .customLong("help", withSingleDash: true)])

    @OptionGroup()
    var globalOptions: GlobalOptions

    @OptionGroup()
    var options: RunToolOptions

    public func run(_ swiftTool: SwiftTool) throws {
        if options.shouldBuildTests && options.shouldSkipBuild {
            swiftTool.observabilityScope.emit(
              .mutuallyExclusiveArgumentsError(arguments: ["--build-tests", "--skip-build"])
            )
            throw ExitCode.failure
        }

        switch options.mode {
        case .repl:
            // Load a custom package graph which has a special product for REPL.
            let graphLoader = {
                try swiftTool.loadPackageGraph(
                    explicitProduct: self.options.executable,
                    createREPLProduct: true
                )
            }
            let buildParameters = try swiftTool.buildParameters()

            // Construct the build operation.
            // FIXME: We need to implement the build tool invocation closure here so that build tool plugins work with the REPL. rdar://86112934
            let buildOp = try swiftTool.createBuildOperation(
                cacheBuildManifest: false,
                customBuildParameters: buildParameters,
                customPackageGraphLoader: graphLoader
            )

            // Perform build.
            try buildOp.build()

            // Execute the REPL.
            let arguments = buildOp.buildPlan!.createREPLArguments()
            print("Launching Swift REPL with arguments: \(arguments.joined(separator: " "))")
            try self.run(
                fileSystem: swiftTool.fileSystem,
                executablePath: swiftTool.getToolchain().swiftInterpreterPath,
                originalWorkingDirectory: swiftTool.originalWorkingDirectory,
                arguments: arguments
            )

        case .debugger:
            do {
                let buildSystem = try swiftTool.createBuildSystem(explicitProduct: options.executable)
                let productName = try findProductName(in: buildSystem.getPackageGraph())
                if options.shouldBuildTests {
                    try buildSystem.build(subset: .allIncludingTests)
                } else if options.shouldBuild {
                    try buildSystem.build(subset: .product(productName))
                }

                let executablePath = try swiftTool.buildParameters().buildPath.appending(component: productName)

                // Make sure we are running from the original working directory.
                let cwd: AbsolutePath? = swiftTool.fileSystem.currentWorkingDirectory
                if cwd == nil || swiftTool.originalWorkingDirectory != cwd {
                    try ProcessEnv.chdir(swiftTool.originalWorkingDirectory)
                }

                let pathRelativeToWorkingDirectory = executablePath.relative(to: swiftTool.originalWorkingDirectory)
                let lldbPath = try swiftTool.getToolchain().getLLDB()
                try exec(path: lldbPath.pathString, args: ["--", pathRelativeToWorkingDirectory.pathString] + options.arguments)
            } catch let error as RunError {
                swiftTool.observabilityScope.emit(error)
                throw ExitCode.failure
            }

        case .run:
            // Detect deprecated uses of swift run to interpret scripts.
            if let executable = options.executable, isValidSwiftFilePath(fileSystem: swiftTool.fileSystem, path: executable) {
                swiftTool.observabilityScope.emit(.runFileDeprecation)
                // Redirect execution to the toolchain's swift executable.
                let swiftInterpreterPath = try swiftTool.getToolchain().swiftInterpreterPath
                // Prepend the script to interpret to the arguments.
                let arguments = [executable] + options.arguments
                try self.run(
                    fileSystem: swiftTool.fileSystem,
                    executablePath: swiftInterpreterPath,
                    originalWorkingDirectory: swiftTool.originalWorkingDirectory,
                    arguments: arguments
                )
                return
            }

            do {
                let buildSystem = try swiftTool.createBuildSystem(explicitProduct: options.executable)
                let productName = try findProductName(in: buildSystem.getPackageGraph())
                if options.shouldBuildTests {
                    try buildSystem.build(subset: .allIncludingTests)
                } else if options.shouldBuild {
                    try buildSystem.build(subset: .product(productName))
                }

                let executablePath = try swiftTool.buildParameters().buildPath.appending(component: productName)
                try self.run(
                    fileSystem: swiftTool.fileSystem,
                    executablePath: executablePath,
                    originalWorkingDirectory: swiftTool.originalWorkingDirectory,
                    arguments: options.arguments
                )
            } catch Diagnostics.fatalError {
                throw ExitCode.failure
            } catch let error as RunError {
                swiftTool.observabilityScope.emit(error)
                throw ExitCode.failure
            }
        }
    }

    /// Returns the path to the correct executable based on options.
    private func findProductName(in graph: PackageGraph) throws -> String {
        if let executable = options.executable {
            let executableExists = graph.allProducts.contains { ($0.type == .executable || $0.type == .snippet) && $0.name == executable }
            guard executableExists else {
                throw RunError.executableNotFound(executable)
            }
            return executable
        }

        // If the executable is implicit, search through root products.
        let rootExecutables = graph.rootPackages
            .flatMap { $0.products }
            .filter { $0.type == .executable || $0.type == .snippet }
            .map { $0.name }

        // Error out if the package contains no executables.
        guard rootExecutables.count > 0 else {
            throw RunError.noExecutableFound
        }

        // Only implicitly deduce the executable if it is the only one.
        guard rootExecutables.count == 1 else {
            throw RunError.multipleExecutables(rootExecutables)
        }

        return rootExecutables[0]
    }

    /// Executes the executable at the specified path.
    private func run(
        fileSystem: FileSystem,
        executablePath: AbsolutePath,
        originalWorkingDirectory: AbsolutePath,
        arguments: [String]) throws
    {
        // Make sure we are running from the original working directory.
        let cwd: AbsolutePath? = fileSystem.currentWorkingDirectory
        if cwd == nil || originalWorkingDirectory != cwd {
            try ProcessEnv.chdir(originalWorkingDirectory)
        }

        let pathRelativeToWorkingDirectory = executablePath.relative(to: originalWorkingDirectory)
        try exec(path: executablePath.pathString, args: [pathRelativeToWorkingDirectory.pathString] + arguments)
    }

    /// Determines if a path points to a valid swift file.
    private func isValidSwiftFilePath(fileSystem: FileSystem, path: String) -> Bool {
        guard path.hasSuffix(".swift") else { return false }
        //FIXME: Return false when the path is not a valid path string.
        let absolutePath: AbsolutePath
        if path.first == "/" {
            absolutePath = AbsolutePath(path)
        } else {
            guard let cwd = fileSystem.currentWorkingDirectory else {
                return false
            }
            absolutePath = AbsolutePath(cwd, path)
        }
        return fileSystem.isFile(absolutePath)
    }

    public init() {}
}

private extension Basics.Diagnostic {
    static var runFileDeprecation: Self {
        .warning("'swift run file.swift' command to interpret swift files is deprecated; use 'swift file.swift' instead")
    }
}
