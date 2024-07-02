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
import Foundation
import PackageModel
import PackageLoading
import PackageGraph

/// Implements the mechanics of running and communicating with a plugin (implemented as a set of Swift source files). In most environments this is done by compiling the code to an executable, invoking it as a sandboxed subprocess, and communicating with it using pipes. Specific implementations are free to implement things differently, however.
public protocol PluginScriptRunner {
    
    /// Public protocol function that starts compiling the plugin script to an executable. The name is used as the basename for the executable and auxiliary files. The tools version controls the availability of APIs in PackagePlugin, and should be set to the tools version of the package that defines the plugin (not of the target to which it is being applied). This function returns immediately and then calls the completion handler on the callback queue when compilation ends.
    func compilePluginScript(
        sourceFiles: [AbsolutePath],
        pluginName: String,
        toolsVersion: ToolsVersion,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        delegate: PluginScriptCompilerDelegate
    ) async throws -> PluginCompilationResult

    /// Implements the mechanics of running a plugin script implemented as a set of Swift source files, for use
    /// by the package graph when it is evaluating package plugins.
    ///
    /// The `sources` refer to the Swift source files and are accessible in the provided `fileSystem`. The input is
    /// a PluginScriptRunnerInput structure.
    ///
    /// The text output callback handler will receive free-form output from the script as it's running. Structured
    /// diagnostics emitted by the plugin will be added to the observability scope.
    ///
    /// Every concrete implementation should cache any intermediates as necessary to avoid redundant work.
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
        delegate: PluginScriptCompilerDelegate & PluginScriptRunnerDelegate
    ) async throws -> Int32

    /// Returns the Triple that represents the host for which plugin script tools should be built, or for which binary
    /// tools should be selected.
    var hostTriple: Triple { get throws }
}

/// Protocol by which `PluginScriptRunner` communicates back to the caller as it compiles plugins.
public protocol PluginScriptCompilerDelegate {
    /// Called immediately before compiling a plugin. Will not be called if the plugin didn't have to be compiled. This call is always followed by a `didCompilePlugin()` but is mutually exclusive with a `skippedCompilingPlugin()` call.
    func willCompilePlugin(commandLine: [String], environment: [String: String])

    /// Called immediately after compiling a plugin (regardless of whether it succeeded or failed). Will not be called if the plugin didn't have to be compiled. This call is always follows a `willCompilePlugin()` but is mutually exclusive with a `skippedCompilingPlugin()` call.
    func didCompilePlugin(result: PluginCompilationResult)
    
    /// Called if a plugin didn't need to be compiled because previous compilation results were still valid. In this case neither `willCompilePlugin()` nor `didCompilePlugin()` will be called.
    func skippedCompilingPlugin(cachedResult: PluginCompilationResult)
}

/// Protocol by which `PluginScriptRunner` communicates back to the caller as it runs plugins.
public protocol PluginScriptRunnerDelegate {
    /// Called for each piece of textual output data emitted by the plugin. Note that there is no guarantee that the data begins and ends on a UTF-8 byte sequence boundary (much less on a line boundary) so the delegate should buffer partial data as appropriate.
    func handleOutput(data: Data)
    
    /// Called for each length-delimited message received from the plugin. The `responder` is closure that can be used to send one or more messages in reply.
    func handleMessage(data: Data, responder: @escaping (Data) -> Void) async throws
}

/// The result of compiling a plugin. The executable path will only be present if the compilation succeeds, while the other properties are present in all cases.
public struct PluginCompilationResult: Equatable {
    /// Whether compilation succeeded.
    public var succeeded: Bool
    
    /// Complete compiler command line.
    public var commandLine: [String]
    
    /// Path of the compiled executable.
    public var executableFile: AbsolutePath

    /// Path of the libClang diagnostics file emitted by the compiler.
    public var diagnosticsFile: AbsolutePath
    
    /// Any output emitted by the compiler (stdout and stderr combined).
    public var rawCompilerOutput: String
    
    /// Whether the compilation result came from the cache (false means that the compiler did run).
    public var cached: Bool
    
    public init(
        succeeded: Bool,
        commandLine: [String],
        executableFile: AbsolutePath,
        diagnosticsFile: AbsolutePath,
        compilerOutput rawCompilerOutput: String,
        cached: Bool
    ) {
        self.succeeded = succeeded
        self.commandLine = commandLine
        self.executableFile = executableFile
        self.diagnosticsFile = diagnosticsFile
        self.rawCompilerOutput = rawCompilerOutput
        self.cached = cached
    }
}

extension PluginCompilationResult {
    public var compilerOutput: String {
        let output = self.rawCompilerOutput.spm_chomp()
        return output + (output.isEmpty || output.hasSuffix("\n") ? "" : "\n")
    }
}

extension PluginCompilationResult: CustomDebugStringConvertible {
    public var debugDescription: String {
        return """
            <PluginCompilationResult(
                succeeded: \(succeeded),
                commandLine: \(commandLine.map{ $0.spm_shellEscaped() }.joined(separator: " ")),
                executable: \(executableFile.prettyPath())
                diagnostics: \(diagnosticsFile.prettyPath())
                compilerOutput: \(compilerOutput.spm_shellEscaped())
            )>
            """
    }
}
