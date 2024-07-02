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
import PackageGraph
import PackageModel
import SPMBuildCore

import struct TSCBasic.ByteString
import struct Basics.AsyncProcessResult
import class Basics.AsyncProcess

import struct TSCUtility.SerializedDiagnostics

/// A plugin script runner that compiles the plugin source files as an executable binary for the host platform, and invokes it as a subprocess.
public struct DefaultPluginScriptRunner: PluginScriptRunner, Cancellable {
    private let fileSystem: FileSystem
    private let cacheDir: Basics.AbsolutePath
    private let toolchain: UserToolchain
    private let extraPluginSwiftCFlags: [String]
    private let enableSandbox: Bool
    private let cancellator: Cancellator
    private let verboseOutput: Bool

    private let sdkRootCache = ThreadSafeBox<Basics.AbsolutePath>()

    public init(
        fileSystem: Basics.FileSystem,
        cacheDir: Basics.AbsolutePath,
        toolchain: UserToolchain,
        extraPluginSwiftCFlags: [String] = [],
        enableSandbox: Bool = true,
        verboseOutput: Bool = false
    ) {
        self.fileSystem = fileSystem
        self.cacheDir = cacheDir
        self.toolchain = toolchain
        self.extraPluginSwiftCFlags = extraPluginSwiftCFlags
        self.enableSandbox = enableSandbox
        self.cancellator = Cancellator(observabilityScope: .none)
        self.verboseOutput = verboseOutput
    }
    
    /// Starts evaluating a plugin by compiling it and running it as a subprocess. The name is used as the basename for the executable and auxiliary files.  The tools version controls the availability of APIs in PackagePlugin, and should be set to the tools version of the package that defines the plugin (not the package containing the target to which it is being applied). This function returns immediately and then repeated calls the output handler on the given callback queue as plain-text output is received from the plugin, and then eventually calls the completion handler on the given callback queue once the plugin is done.
    public func runPluginScript(
        sourceFiles: [Basics.AbsolutePath],
        pluginName: String,
        initialMessage: Data,
        toolsVersion: ToolsVersion,
        workingDirectory: Basics.AbsolutePath,
        writableDirectories: [Basics.AbsolutePath],
        readOnlyDirectories: [Basics.AbsolutePath],
        allowNetworkConnections: [SandboxNetworkPermission],
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        delegate: PluginScriptCompilerDelegate & PluginScriptRunnerDelegate
    ) async throws -> Int32 {
        // If needed, compile the plugin script to an executable (asynchronously). Compilation is skipped if the plugin hasn't changed since it was last compiled.
        let result = try await self.compilePluginScript(
            sourceFiles: sourceFiles,
            pluginName: pluginName,
            toolsVersion: toolsVersion,
            observabilityScope: observabilityScope,
            callbackQueue: DispatchQueue.sharedConcurrent,
            delegate: delegate
        )
        if result.succeeded {
            // Compilation succeeded, so run the executable. We are already running on an asynchronous queue.
            return try await self.invoke(
                compiledExec: result.executableFile,
                workingDirectory: workingDirectory,
                writableDirectories: writableDirectories,
                readOnlyDirectories: readOnlyDirectories,
                allowNetworkConnections: allowNetworkConnections,
                initialMessage: initialMessage,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue,
                delegate: delegate
            )
        } else {
            // Compilation failed, so throw an error.
            throw DefaultPluginScriptRunnerError.compilationFailed(result)
        }
    }

    public var hostTriple: Triple {
        return self.toolchain.targetTriple
    }
    
    /// Starts compiling a plugin script asynchronously and when done, calls the completion handler on the callback queue with the results (including the path of the compiled plugin executable and with any emitted diagnostics, etc).  Existing compilation results that are still valid are reused, if possible.  This function itself returns immediately after starting the compile.  Note that the completion handler only receives a `.failure` result if the compiler couldn't be invoked at all; a non-zero exit code from the compiler still returns `.success` with a full compilation result that notes the error in the diagnostics (in other words, a `.failure` result only means "failure to invoke the compiler").
    public func compilePluginScript(
        sourceFiles: [Basics.AbsolutePath],
        pluginName: String,
        toolsVersion: ToolsVersion,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        delegate: PluginScriptCompilerDelegate
    ) async throws -> PluginCompilationResult {
        // Determine the path of the executable and other produced files.
        let execName = pluginName.spm_mangledToC99ExtendedIdentifier()
        #if os(Windows)
        let execSuffix = ".exe"
        #else
        let execSuffix = ""
        #endif
        let execFilePath = self.cacheDir.appending(component: execName + execSuffix)
        let diagFilePath = self.cacheDir.appending(component: execName + ".dia")
        observabilityScope.emit(debug: "Compiling plugin to executable at \(execFilePath)")

        // Construct the command line for compiling the plugin script(s).
        // FIXME: Much of this is similar to what the ManifestLoader is doing. This should be consolidated.

        // We use the toolchain's Swift compiler for compiling the plugin.
        var commandLine = [self.toolchain.swiftCompilerPathForManifests.pathString]
        
        observabilityScope.emit(debug: "Using compiler \(self.toolchain.swiftCompilerPathForManifests.pathString)")

        // Get access to the path containing the PackagePlugin module and library.
        let pluginLibraryPath = self.toolchain.swiftPMLibrariesLocation.pluginLibraryPath
        let pluginModulesPath = self.toolchain.swiftPMLibrariesLocation.pluginModulesPath

        // if runtimePath is set to "PackageFrameworks" that means we could be developing SwiftPM in Xcode
        // which produces a framework for dynamic package products.
        if pluginLibraryPath.extension == "framework" {
            commandLine += [
                "-F", pluginLibraryPath.parentDirectory.pathString,
                "-framework", "PackagePlugin",
                "-Xlinker", "-rpath", "-Xlinker", pluginLibraryPath.parentDirectory.pathString,
            ]
        } else {
            commandLine += [
                "-L", pluginLibraryPath.pathString,
                "-lPackagePlugin",
            ]
            #if !os(Windows)
            // -rpath argument is not supported on Windows,
            // so we add runtimePath to PATH when executing the manifest instead
            commandLine += ["-Xlinker", "-rpath", "-Xlinker", pluginLibraryPath.pathString]
            #endif
        }

        #if os(macOS)
        // On macOS earlier than 12, add an rpath to the directory that contains the concurrency fallback library.
        if #available(macOS 12.0, *) {
            // Nothing is needed; the system has everything we need.
        }
        else {
            // Add an `-rpath` so the Swift 5.5 fallback libraries can be found.
            let swiftSupportLibPath = self.toolchain.swiftCompilerPathForManifests.parentDirectory.parentDirectory.appending(components: "lib", "swift-5.5", "macosx")
            commandLine += ["-Xlinker", "-rpath", "-Xlinker", swiftSupportLibPath.pathString]
        }
        #endif

        // Use the same minimum deployment target as the PackagePlugin library (with a fallback to the default host triple).
        #if os(macOS)
        if let version = self.toolchain.swiftPMLibrariesLocation.pluginLibraryMinimumDeploymentTarget?.versionString {
            commandLine += ["-target", "\(self.toolchain.targetTriple.tripleString(forPlatformVersion: version))"]
        } else {
            commandLine += ["-target", self.toolchain.targetTriple.tripleString]
        }
        #endif

        // Add any extra flags required as indicated by the ManifestLoader.
        commandLine += self.toolchain.swiftCompilerFlags

        commandLine.append("-g")

        // Add the Swift language version implied by the package tools version.
        commandLine += ["-swift-version", toolsVersion.swiftLanguageVersion.rawValue]

        // Add the PackageDescription version specified by the package tools version, which controls what PackagePlugin API is seen.
        commandLine += ["-package-description-version", toolsVersion.description]

        // if runtimePath is set to "PackageFrameworks" that means we could be developing SwiftPM in Xcode
        // which produces a framework for dynamic package products.
        if pluginModulesPath.extension == "framework" {
            commandLine += ["-I", pluginModulesPath.parentDirectory.parentDirectory.pathString]
        } else {
            commandLine += ["-I", pluginModulesPath.pathString]
        }
        #if os(macOS)
        if let sdkRoot = self.toolchain.sdkRootPath ?? self.sdkRoot() {
            commandLine += ["-sdk", sdkRoot.pathString]
        }
        #endif

        // Honor any module cache override that's set in the environment.
        let moduleCachePath = Environment.current["SWIFTPM_MODULECACHE_OVERRIDE"] ?? Environment.current["SWIFTPM_TESTS_MODULECACHE"]
        if let moduleCachePath {
            commandLine += ["-module-cache-path", moduleCachePath]
        }

        // Parse the plugin as a library so that `@main` is supported even though there might be only a single source file.
        commandLine += ["-parse-as-library"]

        // Ask the compiler to create a diagnostics file (we'll put it next to the executable).
        commandLine += ["-Xfrontend", "-serialize-diagnostics-path", "-Xfrontend", diagFilePath.pathString]

        // Add all the source files that comprise the plugin scripts.
        commandLine += sourceFiles.map { $0.pathString }

        // Finally add the output path of the compiled executable.
        commandLine += ["-o", execFilePath.pathString]

        // Add any extra flags passed for the host in the command line
        commandLine += self.extraPluginSwiftCFlags

        if (verboseOutput) {
            commandLine.append("-v")
        }
        // Pass through the compilation environment.
        let environment = toolchain.swiftCompilerEnvironment

        // First try to create the output directory.
        do {
            observabilityScope.emit(debug: "Plugin compilation output directory '\(execFilePath.parentDirectory)'")
            try FileManager.default.createDirectory(at: execFilePath.parentDirectory.asURL, withIntermediateDirectories: true, attributes: nil)
        }
        catch {
            // Bail out right away if we didn't even get this far.
            throw DefaultPluginScriptRunnerError.compilationPreparationFailed(error: error)
        }
        
        // Hash the compiler inputs to decide whether we really need to recompile.
        let compilerInputHash: String?
        do {
            // Include the full compiler arguments and environment, and the contents of the source files.
            var stringToHash = commandLine.description
            for (key, value) in toolchain.swiftCompilerEnvironment.sorted(by: { $0.key < $1.key }) {
                stringToHash.append("\(key)=\(value)\n")
            }
            for sourceFile in sourceFiles {
                let source: String = try fileSystem.readFileContents(sourceFile)
                stringToHash.append(source)
            }
            compilerInputHash = ByteString(encodingAsUTF8: stringToHash).sha256Checksum
            observabilityScope.emit(debug: "Computed hash of plugin compilation inputs: \(compilerInputHash!)")
        }
        catch {
            // We couldn't compute the hash. We warn about it but proceed with the compilation (a cache miss).
            observabilityScope.emit(debug: "Couldn't compute hash of plugin compilation inputs", underlyingError: error)
            compilerInputHash = .none
        }
        
        /// Persisted information about the last time the compiler was invoked.
        struct PersistedCompilationState: Codable {
            var commandLine: [String]
            var environment: Environment
            var inputHash: String?
            var output: String
            var result: Result
            enum Result: Equatable, Codable {
                case exit(code: Int32)
                case abnormal(exception: UInt32)
                case signal(number: Int32)
                
                init(_ processExitStatus: AsyncProcessResult.ExitStatus) {
                    switch processExitStatus {
                    case .terminated(let code):
                        self = .exit(code: code)
                    #if os(Windows)
                    case .abnormal(let exception):
                        self = .abnormal(exception: exception)
                    #else
                    case .signalled(let signal):
                        self = .signal(number: signal)
                    #endif
                    }
                }
            }
            
            var succeeded: Bool {
                return result == .exit(code: 0)
            }
        }
        
        // Check if we already have a compiled executable and a persisted state (we only recompile if things have changed).
        let stateFilePath = self.cacheDir.appending(component: execName + "-state" + ".json")
        var compilationState: PersistedCompilationState? = .none
        if fileSystem.exists(execFilePath) && fileSystem.exists(stateFilePath) {
            do {
                // Try to load the previous compilation state.
                let previousState = try JSONDecoder.makeWithDefaults().decode(
                    path: stateFilePath,
                    fileSystem: fileSystem,
                    as: PersistedCompilationState.self)
                
                // If it succeeded last time and the compiler inputs are the same, we don't need to recompile.
                if previousState.succeeded && previousState.inputHash == compilerInputHash {
                    compilationState = previousState
                }
            }
            catch {
                // We couldn't read the compilation state file even though it existed. We warn about it but proceed with recompiling.
                observabilityScope.emit(debug: "Couldn't read previous compilation state", underlyingError: error)
            }
        }
        
        // If we still have a compilation state, it means the executable is still valid and we don't need to do anything.
        if let compilationState {
            // Just call the completion handler with the persisted results.
            let result = PluginCompilationResult(
                succeeded: compilationState.succeeded,
                commandLine: commandLine,
                executableFile: execFilePath,
                diagnosticsFile: diagFilePath,
                compilerOutput: compilationState.output,
                cached: true
            )
            delegate.skippedCompilingPlugin(cachedResult: result)
            return result
        }

        // Otherwise we need to recompile. We start by telling the delegate.
        delegate.willCompilePlugin(commandLine: commandLine, environment: .init(environment))

        // Clean up any old files to avoid confusion if the compiler can't be invoked.
        do {
            try fileSystem.removeFileTree(execFilePath)
            try fileSystem.removeFileTree(diagFilePath)
            try fileSystem.removeFileTree(stateFilePath)
        }
        catch {
            observabilityScope.emit(debug: "Couldn't clean up before invoking compiler", underlyingError: error)
        }
        
        // Now invoke the compiler asynchronously.
        let process = try await AsyncPorcess.Process.popen(arguments: commandLine, environment: environment)

        // Emit the compiler output as observable info.
        let compilerOutput = ((try? process.utf8Output()) ?? "") + ((try? process.utf8stderrOutput()) ?? "")
        if !compilerOutput.isEmpty {
            observabilityScope.emit(info: compilerOutput)
        }

        // Save the persisted compilation state for possible reuse next time.
        let newCompilationState = PersistedCompilationState(
            commandLine: commandLine,
            environment: toolchain.swiftCompilerEnvironment.cachable,
            inputHash: compilerInputHash,
            output: compilerOutput,
            result: .init(process.exitStatus))
        do {
            try JSONEncoder.makeWithDefaults().encode(path: stateFilePath, fileSystem: self.fileSystem, newCompilationState)
        }
        catch {
            // We couldn't write out the `.state` file. We warn about it but proceed.
            observabilityScope.emit(debug: "Couldn't save plugin compilation state", underlyingError: error)
        }

        // Construct a PluginCompilationResult for both the successful and unsuccessful cases (to convey diagnostics, etc).
        let result = PluginCompilationResult(
            succeeded: newCompilationState.succeeded,
            commandLine: commandLine,
            executableFile: execFilePath,
            diagnosticsFile: diagFilePath,
            compilerOutput: compilerOutput,
            cached: false)

        // Tell the delegate that we're done compiling the plugin, passing it the result.
        delegate.didCompilePlugin(result: result)

        // Also return the result to the caller.
        return result
    }

    /// Returns path to the sdk, if possible.
    // FIXME: This is copied from ManifestLoader.  This should be consolidated when ManifestLoader is cleaned up.
    private func sdkRoot() -> Basics.AbsolutePath? {
        if let sdkRoot = self.sdkRootCache.get() {
            return sdkRoot
        }

        var sdkRootPath: Basics.AbsolutePath?
        // Find SDKROOT on macOS using xcrun.
        #if os(macOS)
        let foundPath = try? AsyncProcess.checkNonZeroExit(
            args: "/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"
        )
        guard let sdkRoot = foundPath?.spm_chomp(), !sdkRoot.isEmpty else {
            return nil
        }
        if let path = try? Basics.AbsolutePath(validating: sdkRoot) {
            sdkRootPath = path
            self.sdkRootCache.put(path)
        }
        #endif

        return sdkRootPath
    }

    private func invoke(
        compiledExec: Basics.AbsolutePath,
        workingDirectory: Basics.AbsolutePath,
        writableDirectories: [Basics.AbsolutePath],
        readOnlyDirectories: [Basics.AbsolutePath],
        allowNetworkConnections: [SandboxNetworkPermission],
        initialMessage: Data,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        delegate: PluginScriptRunnerDelegate
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation {
            self.invoke(
                compiledExec: compiledExec,
                workingDirectory: workingDirectory,
                writableDirectories: writableDirectories,
                readOnlyDirectories: readOnlyDirectories,
                allowNetworkConnections: allowNetworkConnections,
                initialMessage: initialMessage,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue,
                delegate: delegate,
                completion: $0.resume(with:)
            )
        }
    }

    /// Private function that invokes a compiled plugin executable and communicates with it until it finishes.
    fileprivate func invoke(
        compiledExec: Basics.AbsolutePath,
        workingDirectory: Basics.AbsolutePath,
        writableDirectories: [Basics.AbsolutePath],
        readOnlyDirectories: [Basics.AbsolutePath],
        allowNetworkConnections: [SandboxNetworkPermission],
        initialMessage: Data,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        delegate: PluginScriptRunnerDelegate,
        completion: @escaping (Result<Int32, Error>) -> Void
    ) {
#if os(iOS) || os(watchOS) || os(tvOS)
        callbackQueue.async {
            completion(.failure(DefaultPluginScriptRunnerError.pluginUnavailable(reason: "subprocess invocations are unavailable on this platform")))
        }
#else
        // Construct the command line. Currently we just invoke the executable built from the plugin without any parameters.
        var command = [compiledExec.pathString]

        // Optionally wrap the command in a sandbox, which places some limits on what it can do. In particular, it blocks network access and restricts the paths to which the plugin can make file system changes. It does allow writing to temporary directories.
        if self.enableSandbox {
            do {
                command = try Sandbox.apply(
                    command: command,
                    fileSystem: self.fileSystem,
                    strictness: .writableTemporaryDirectory,
                    writableDirectories: writableDirectories + [self.cacheDir],
                    readOnlyDirectories: readOnlyDirectories,
                    allowNetworkConnections: allowNetworkConnections
                )
            } catch {
                return callbackQueue.async {
                    completion(.failure(error))
                }
            }
        }

        // Create and configure a Process. We set the working directory to the cache directory, so that relative paths end up there.
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.environment = ProcessInfo.processInfo.environment
#if os(Windows)
        let pluginLibraryPath = self.toolchain.swiftPMLibrariesLocation.pluginLibraryPath.pathString
        var env = ProcessInfo.processInfo.environment
        if let Path = env["Path"] {
            env["Path"] = "\(pluginLibraryPath);\(Path)"
        } else {
            env["Path"] = pluginLibraryPath
        }
        process.environment = env
#endif
        process.currentDirectoryURL = workingDirectory.asURL
        
        // Set up a pipe for sending structured messages to the plugin on its stdin.
        let stdinPipe = Pipe()
        let outputHandle = stdinPipe.fileHandleForWriting
        let outputQueue = DispatchQueue(label: "plugin-send-queue")
        process.standardInput = stdinPipe

        // Set up a pipe for receiving messages from the plugin on its stdout.
        let stdoutPipe = Pipe()
        let stdoutLock = NSLock()
        stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            // Receive the next message and pass it on to the delegate.
            stdoutLock.withLock {
                do {
                    while let message = try fileHandle.readPluginMessage() {
                        // FIXME: We should handle backpressure and errors here.
                        do {
                            try await delegate.handleMessage(data: message, responder: { data in
                                outputQueue.async {
                                    do {
                                        try outputHandle.writePluginMessage(data)
                                    }
                                    catch {
                                        print("error while trying to send message to plugin: \(error.interpolationDescription)")
                                    }
                                }
                            })
                        }
                        catch DecodingError.keyNotFound(let key, _) where key.stringValue == "version" {
                            observabilityScope.emit(error: "message from plugin did not contain a 'version' key, likely an incompatible plugin library is being loaded by the plugin")
                        }
                        catch {
                            observabilityScope.emit(error: "error while trying to handle message from plugin: \(error.interpolationDescription)")
                        }

                    }
                }
                catch {
                    observabilityScope.emit(error: "error while trying to read message from plugin: \(error.interpolationDescription)")
                }
            }
        }
        process.standardOutput = stdoutPipe

        // Set up a pipe for receiving free-form text output from the plugin on its stderr.
        let stderrPipe = Pipe()
        let stderrLock = NSLock()
        var stderrData = Data()
        let stderrHandler = { (data: Data) in
            // Pass on any available data to the delegate.
            if data.isEmpty { return }
            stderrData.append(contentsOf: data)
            callbackQueue.async { delegate.handleOutput(data: data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            // Read and pass on any available free-form text output from the plugin.
            // We need the lock since we could run concurrently with the termination handler.
            stderrLock.withLock { stderrHandler(fileHandle.availableData) }
        }
        process.standardError = stderrPipe
        
        // Add it to the list of currently running plugin processes, so it can be cancelled if the host is interrupted.
        guard let cancellationKey = self.cancellator.register(process) else {
            return callbackQueue.async {
                completion(.failure(CancellationError()))
            }
        }

        // Set up a handler to deal with the exit of the plugin process.
        process.terminationHandler = { process in
            // Remove the process from the list of currently running ones.
            self.cancellator.deregister(cancellationKey)

            // Close the output handle through which we talked to the plugin.
            try? outputHandle.close()

            // Read and pass on any remaining free-form text output from the plugin.
            // We need the lock since we could run concurrently with the readability handler.
            stderrLock.withLock {
                try? stderrPipe.fileHandleForReading.readToEnd().map{ stderrHandler($0) }
            }

            // Read and pass on any remaining messages from the plugin.
            let handle = stdoutPipe.fileHandleForReading
            if let handler = handle.readabilityHandler {
                handler(handle)
            }

            // Call the completion block with a result that depends on how the process ended.
            callbackQueue.async {
                completion(Result {
                    // We throw an error if the plugin ended with a signal.
                    if process.terminationReason == .uncaughtSignal {
                        throw DefaultPluginScriptRunnerError.invocationEndedBySignal(
                            signal: process.terminationStatus,
                            command: command,
                            output: String(decoding: stderrData, as: UTF8.self))
                    }
                    // Otherwise return the termination satatus.
                    return process.terminationStatus
                })
            }
        }
 
        // Start the plugin process.
        do {
            try process.run()
        }
        catch {
            callbackQueue.async {
                completion(.failure(DefaultPluginScriptRunnerError.invocationFailed(error: error, command: command)))
            }
        }

        /// Send the initial message to the plugin.
        outputQueue.async {
            try? outputHandle.writePluginMessage(initialMessage)
        }
#endif
    }

    public func cancel(deadline: DispatchTime) throws {
        try self.cancellator.cancel(deadline: deadline)
    }
}

/// An error encountered by the default plugin runner.
public enum DefaultPluginScriptRunnerError: Error, CustomStringConvertible {
    /// The plugin is not available for some reason.
    case pluginUnavailable(reason: String)

    /// An error occurred while preparing to compile the plugin script.
    case compilationPreparationFailed(error: Error)

    /// An error occurred while compiling the plugin script (e.g. syntax error).
    /// The diagnostics are available in the plugin compilation result.
    case compilationFailed(PluginCompilationResult)

    /// The plugin invocation couldn't be started.
    case invocationFailed(error: Error, command: [String])

    /// The plugin invocation ended by a signal.
    case invocationEndedBySignal(signal: Int32, command: [String], output: String)

    /// The plugin invocation ended with a non-zero exit code.
    case invocationEndedWithNonZeroExitCode(exitCode: Int32, command: [String], output: String)

    /// There was an error communicating with the plugin.
    case pluginCommunicationError(message: String, command: [String], output: String)

    public var description: String {
        func makeContextString(_ command: [String], _ output: String) -> String {
            return "<command: \(command.map{ $0.spm_shellEscaped() }.joined(separator: " "))>, <output:\n\(output.spm_shellEscaped())>"
        }
        switch self {
        case .pluginUnavailable(let reason):
            return "plugin is unavailable: \(reason)"
        case .compilationPreparationFailed(let error):
            return "plugin compilation preparation failed: \(error.interpolationDescription)"
        case .compilationFailed(let result):
            return "plugin compilation failed: \(result)"
        case .invocationFailed(let error, let command):
            return "plugin invocation failed: \(error.interpolationDescription) \(makeContextString(command, ""))"
        case .invocationEndedBySignal(let signal, let command, let output):
            return "plugin process ended by an uncaught signal: \(signal) \(makeContextString(command, output))"
        case .invocationEndedWithNonZeroExitCode(let exitCode, let command, let output):
            return "plugin process ended with a non-zero exit code: \(exitCode) \(makeContextString(command, output))"
        case .pluginCommunicationError(let message, let command, let output):
            return "plugin communication error: \(message) \(makeContextString(command, output))"
        }
    }
}

fileprivate extension FileHandle {
    
    func writePluginMessage(_ message: Data) throws {
        // Write the header (a 64-bit length field in little endian byte order).
        var length = UInt64(littleEndian: UInt64(message.count))
        let header = Swift.withUnsafeBytes(of: &length) { Data($0) }
        assert(header.count == 8)
        try self.write(contentsOf: header)
        
        // Write the payload.
        try self.write(contentsOf: message)
    }
    
    func readPluginMessage() throws -> Data? {
        // Read the header (a 64-bit length field in little endian byte order).
        guard let header = try self.read(upToCount: 8) else { return nil }
        guard header.count == 8 else {
            throw PluginMessageError.truncatedHeader
        }
        let length = header.withUnsafeBytes{ $0.loadUnaligned(as: UInt64.self).littleEndian }
        guard length >= 2 else {
            throw PluginMessageError.invalidPayloadSize
        }

        // Read and return the message.
        guard let message = try self.read(upToCount: Int(length)), message.count == length else {
            throw PluginMessageError.truncatedPayload
        }
        return message
    }

    enum PluginMessageError: Swift.Error {
        case truncatedHeader
        case invalidPayloadSize
        case truncatedPayload
    }
}
