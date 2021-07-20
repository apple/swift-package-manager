/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2018-2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basics
import TSCBasic
import TSCUtility
import SPMLLBuild
import PackageModel
import Dispatch
import Foundation
import LLBuildManifest
import SPMBuildCore

#if canImport(llbuildSwift)
typealias LLBuildBuildSystemDelegate = llbuildSwift.BuildSystemDelegate
#else
typealias LLBuildBuildSystemDelegate = llbuild.BuildSystemDelegate
#endif

typealias Diagnostic = TSCBasic.Diagnostic

class CustomLLBuildCommand: SPMLLBuild.ExternalCommand {
    let ctx: BuildExecutionContext

    required init(_ ctx: BuildExecutionContext) {
        self.ctx = ctx
    }

    func getSignature(_ command: SPMLLBuild.Command) -> [UInt8] {
        return []
    }

    func execute(
        _ command: SPMLLBuild.Command,
        _ buildSystemCommandInterface: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        fatalError("subclass responsibility")
    }
}

final class TestDiscoveryCommand: CustomLLBuildCommand {

    private func write(
        tests: [IndexStore.TestCaseClass],
        forModule module: String,
        to path: AbsolutePath
    ) throws {
        let stream = try LocalFileOutputByteStream(path)

        let testsByClassNames = Dictionary(grouping: tests, by: { $0.name }).sorted(by: { $0.key < $1.key })

        stream <<< "import XCTest" <<< "\n"
        stream <<< "@testable import " <<< module <<< "\n"

        for iterator in testsByClassNames {
            let className = iterator.key
            let testMethods = iterator.value.flatMap{ $0.methods }
            stream <<< "\n"
            stream <<< "fileprivate extension " <<< className <<< " {" <<< "\n"
            stream <<< indent(4) <<< "static let __allTests__\(className) = [" <<< "\n"
            for method in testMethods {
                let method = method.hasSuffix("()") ? String(method.dropLast(2)) : method
                stream <<< indent(8) <<< "(\"\(method)\", \(method))," <<< "\n"
            }
            stream <<< indent(4) <<< "]" <<< "\n"
            stream <<< "}" <<< "\n"
        }

        stream <<< """
        func __allTests_\(module)() -> [XCTestCaseEntry] {
            return [\n
        """

        for iterator in testsByClassNames {
            let className = iterator.key
            stream <<< indent(8) <<< "testCase(\(className).__allTests__\(className)),\n"
        }
        stream <<< """
            ]
        }
        """

        stream.flush()
    }

    private func execute(with tool: LLBuildManifest.TestDiscoveryTool) throws {
        let index = ctx.buildParameters.indexStore
        let api = try ctx.indexStoreAPI.get()
        let store = try IndexStore.open(store: index, api: api)

        // FIXME: We can speed this up by having one llbuild command per object file.
        let tests = try tool.inputs.flatMap {
            try store.listTests(inObjectFile: AbsolutePath($0.name))
        }

        let outputs = tool.outputs.compactMap{ try? AbsolutePath(validating: $0.name) }
        let testsByModule = Dictionary(grouping: tests, by: { $0.module.spm_mangledToC99ExtendedIdentifier() })

        func isMainFile(_ path: AbsolutePath) -> Bool {
            return path.basename == "main.swift"
        }

        var maybeMainFile: AbsolutePath?
        // Write one file for each test module.
        //
        // We could write everything in one file but that can easily run into type conflicts due
        // in complex packages with large number of test targets.
        for file in outputs {
            if maybeMainFile == nil && isMainFile(file) {
                maybeMainFile = file
                continue 
            }

            // FIXME: This is relying on implementation detail of the output but passing the
            // the context all the way through is not worth it right now.
            let module = file.basenameWithoutExt.spm_mangledToC99ExtendedIdentifier()

            guard let tests = testsByModule[module] else {
                // This module has no tests so just write an empty file for it.
                try localFileSystem.writeFileContents(file, bytes: "")
                continue
            }
            try write(tests: tests, forModule: module, to: file)
        }

        guard let mainFile = maybeMainFile else {
            throw InternalError("unknown main file")
        }

        // Write the main file.
        let stream = try LocalFileOutputByteStream(mainFile)

        stream <<< "import XCTest" <<< "\n\n"
        stream <<< "var tests = [XCTestCaseEntry]()" <<< "\n"
        for module in testsByModule.keys {
            stream <<< "tests += __allTests_\(module)()" <<< "\n"
        }
        stream <<< "\n"
        stream <<< "XCTMain(tests)" <<< "\n"

        stream.flush()
    }

    private func indent(_ spaces: Int) -> ByteStreamable {
        return Format.asRepeating(string: " ", count: spaces)
    }

    override func execute(
        _ command: SPMLLBuild.Command,
        _ buildSystemCommandInterface: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        // This tool will never run without the build description.
        let buildDescription = ctx.buildDescription!
        guard let tool = buildDescription.testDiscoveryCommands[command.name] else {
            print("command \(command.name) not registered")
            return false
        }
        do {
            try execute(with: tool)
        } catch {
            // FIXME: Shouldn't use "print" here.
            print("error:", error)
            return false
        }
        return true
    }
}

private final class InProcessTool: Tool {
    let ctx: BuildExecutionContext
    let type: CustomLLBuildCommand.Type

    init(_ ctx: BuildExecutionContext, type: CustomLLBuildCommand.Type) {
        self.ctx = ctx
        self.type = type
    }

    func createCommand(_ name: String) -> ExternalCommand {
        return type.init(ctx)
    }
}

/// Contains the description of the build that is needed during the execution.
public struct BuildDescription: Codable {
    public typealias CommandName = String
    public typealias TargetName = String
    public typealias CommandLineFlag = String

    /// The Swift compiler invocation targets.
    let swiftCommands: [BuildManifest.CmdName : SwiftCompilerTool]

    /// The Swift compiler frontend invocation targets.
    let swiftFrontendCommands: [BuildManifest.CmdName : SwiftFrontendTool]

    /// The map of test discovery commands.
    let testDiscoveryCommands: [BuildManifest.CmdName: LLBuildManifest.TestDiscoveryTool]

    /// The map of copy commands.
    let copyCommands: [BuildManifest.CmdName: LLBuildManifest.CopyTool]

    /// A flag that inidcates this build should skip checking whether targets only import
    /// their explicitly-declared dependencies
    let disableExplicitTargetDependencyImportChecking: Bool

    /// Every target's set of dependencies.
    let targetDependencyMap: [TargetName: [TargetName]]

    /// A full swift driver command-line invocation used to dependency-scan a given Swift target
    let swiftTargetScanArgs: [TargetName: [CommandLineFlag]]

    /// A set of all targets with generated source
    let generatedSourceTargetSet: Set<TargetName>

    /// The built test products.
    public let builtTestProducts: [BuiltTestProduct]

    public init(
        plan: BuildPlan,
        swiftCommands: [BuildManifest.CmdName : SwiftCompilerTool],
        swiftFrontendCommands: [BuildManifest.CmdName : SwiftFrontendTool],
        testDiscoveryCommands: [BuildManifest.CmdName: LLBuildManifest.TestDiscoveryTool],
        copyCommands: [BuildManifest.CmdName: LLBuildManifest.CopyTool]
    ) throws {
        self.swiftCommands = swiftCommands
        self.swiftFrontendCommands = swiftFrontendCommands
        self.testDiscoveryCommands = testDiscoveryCommands
        self.copyCommands = copyCommands
        self.disableExplicitTargetDependencyImportChecking = plan.buildParameters.disableExplicitTargetDependencyImportChecking
        self.targetDependencyMap = try plan.targets.reduce(into: [TargetName: [TargetName]]()) {
            let deps = try $1.target.recursiveTargetDependencies().map { $0.c99name }
            $0[$1.target.c99name] = deps
        }
        var targetCommandLines: [TargetName: [CommandLineFlag]] = [:]
        var generatedSourceTargets: [TargetName] = []
        for (target, description) in plan.targetMap {
            guard case .swift(let desc) = description else {
                continue
            }
            targetCommandLines[target.c99name] =
                try desc.emitCommandLine(scanInvocation: true) + ["-driver-use-frontend-path",
                                                                  plan.buildParameters.toolchain.swiftCompiler.pathString]
            if desc.testDiscoveryTarget {
                generatedSourceTargets.append(target.c99name)
            }
        }
        generatedSourceTargets.append(contentsOf: plan.graph.allTargets.filter {$0.type == .plugin}
                                                                       .map { $0.c99name })
        self.swiftTargetScanArgs = targetCommandLines
        self.generatedSourceTargetSet = Set(generatedSourceTargets)
        self.builtTestProducts = plan.buildProducts.filter{ $0.product.type == .test }.map { desc in
            return BuiltTestProduct(
                productName: desc.product.name,
                binaryPath: desc.binary
            )
        }
    }

    public func write(to path: AbsolutePath) throws {
        let encoder = JSONEncoder.makeWithDefaults()
        let data = try encoder.encode(self)
        try localFileSystem.writeFileContents(path, bytes: ByteString(data))
    }

    public static func load(from path: AbsolutePath) throws -> BuildDescription {
        let contents = try localFileSystem.readFileContents(path).contents
        let decoder = JSONDecoder.makeWithDefaults()
        return try decoder.decode(BuildDescription.self, from: Data(contents))
    }
}

/// A provider of advice about build errors.
public protocol BuildErrorAdviceProvider {
    /// Invoked after a command fails and an error message is detected in the output.  Should return a string containing advice or additional information, if any, based on the build plan.
    func provideBuildErrorAdvice(for target: String, command: String, message: String) -> String?
}

/// The context available during build execution.
public final class BuildExecutionContext {

    /// Reference to the index store API.
    var indexStoreAPI: Result<IndexStoreAPI, Error> {
        indexStoreAPICache.getValue(self)
    }

    /// The build parameters.
    let buildParameters: BuildParameters

    /// The build description.
    ///
    /// This is optional because we might not have a valid build description when performing the
    /// build for PackageStructure target.
    let buildDescription: BuildDescription?

    /// The package structure delegate.
    let packageStructureDelegate: PackageStructureDelegate
    
    /// Optional provider of build error resolution advice.
    let buildErrorAdviceProvider: BuildErrorAdviceProvider?

    public init(
        _ buildParameters: BuildParameters,
        buildDescription: BuildDescription? = nil,
        packageStructureDelegate: PackageStructureDelegate,
        buildErrorAdviceProvider: BuildErrorAdviceProvider? = nil
    ) {
        self.buildParameters = buildParameters
        self.buildDescription = buildDescription
        self.packageStructureDelegate = packageStructureDelegate
        self.buildErrorAdviceProvider = buildErrorAdviceProvider
    }

    // MARK:- Private

    private var indexStoreAPICache = LazyCache(createIndexStoreAPI)
    private func createIndexStoreAPI() -> Result<IndexStoreAPI, Error> {
        Result {
#if os(Windows)
            // The library's runtime component is in the `bin` directory on
            // Windows rather than the `lib` directory as on unicies.  The `lib`
            // directory contains the import library (and possibly static
            // archives) which are used for linking.  The runtime component is
            // not (necessarily) part of the SDK distributions.
            //
            // NOTE: the library name here `libIndexStore.dll` is technically
            // incorrect as per the Windows naming convention.  However, the
            // library is currently installed as `libIndexStore.dll` rather than
            // `IndexStore.dll`.  In the future, this may require a fallback
            // search, preferring `IndexStore.dll` over `libIndexStore.dll`.
            let indexStoreLib = buildParameters.toolchain.swiftCompiler
                                    .parentDirectory
                                    .appending(component: "libIndexStore.dll")
#else
            let ext = buildParameters.hostTriple.dynamicLibraryExtension
            let indexStoreLib = buildParameters.toolchain.toolchainLibDir.appending(component: "libIndexStore" + ext)
#endif
            return try IndexStoreAPI(dylib: indexStoreLib)
        }
    }
}

public protocol PackageStructureDelegate {
    func packageStructureChanged() -> Bool
}

final class PackageStructureCommand: CustomLLBuildCommand {

    override func getSignature(_ command: SPMLLBuild.Command) -> [UInt8] {
        let encoder = JSONEncoder.makeWithDefaults()
        // Include build parameters and process env in the signature.
        var hash = Data()
        hash += try! encoder.encode(self.ctx.buildParameters)
        hash += try! encoder.encode(ProcessEnv.vars)
        return [UInt8](hash)
    }

    override func execute(
        _ command: SPMLLBuild.Command,
        _ commandInterface: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        return self.ctx.packageStructureDelegate.packageStructureChanged()
    }
}

final class CopyCommand: CustomLLBuildCommand {
    override func execute(
        _ command: SPMLLBuild.Command,
        _ commandInterface: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        // This tool will never run without the build description.
        let buildDescription = ctx.buildDescription!
        guard let tool = buildDescription.copyCommands[command.name] else {
            print("command \(command.name) not registered")
            return false
        }

        do {
            let input = AbsolutePath(tool.inputs[0].name)
            let output = AbsolutePath(tool.outputs[0].name)
            try localFileSystem.createDirectory(output.parentDirectory, recursive: true)
            try localFileSystem.removeFileTree(output)
            try localFileSystem.copy(from: input, to: output)
        } catch {
            // FIXME: Shouldn't use "print" here.
            print("error:", error)
            return false
        }
        return true
    }
}

/// Convenient llbuild build system delegate implementation
final class BuildOperationBuildSystemDelegateHandler: LLBuildBuildSystemDelegate, SwiftCompilerOutputParserDelegate {
    private let diagnostics: DiagnosticsEngine
    var outputStream: ThreadSafeOutputByteStream
    var progressAnimation: ProgressAnimationProtocol
    var onCommmandFailure: (() -> Void)?
    var isVerbose: Bool = false
    weak var delegate: SPMBuildCore.BuildSystemDelegate?
    private let buildSystem: SPMBuildCore.BuildSystem
    private let queue = DispatchQueue(label: "org.swift.swiftpm.build-delegate")
    private var taskTracker = CommandTaskTracker()
    private var errorMessagesByTarget: [String: [String]] = [:]
    
    /// Swift parsers keyed by llbuild command name.
    private var swiftParsers: [String: SwiftCompilerOutputParser] = [:]

    /// The build execution context.
    private let buildExecutionContext: BuildExecutionContext

    init(
        buildSystem: SPMBuildCore.BuildSystem,
        bctx: BuildExecutionContext,
        diagnostics: DiagnosticsEngine,
        outputStream: OutputByteStream,
        progressAnimation: ProgressAnimationProtocol,
        delegate: SPMBuildCore.BuildSystemDelegate?
    ) {
        self.diagnostics = diagnostics
        // FIXME: Implement a class convenience initializer that does this once they are supported
        // https://forums.swift.org/t/allow-self-x-in-class-convenience-initializers/15924
        self.outputStream = outputStream as? ThreadSafeOutputByteStream ?? ThreadSafeOutputByteStream(outputStream)
        self.progressAnimation = progressAnimation
        self.buildExecutionContext = bctx
        self.delegate = delegate
        self.buildSystem = buildSystem

        let swiftParsers = bctx.buildDescription?.swiftCommands.mapValues { tool in
            SwiftCompilerOutputParser(targetName: tool.moduleName, delegate: self)
        } ?? [:]
        self.swiftParsers = swiftParsers

        self.taskTracker.onTaskProgressUpdateText = { progressText, _ in
            self.queue.async {
                self.delegate?.buildSystem(self.buildSystem, didUpdateTaskProgress: progressText)
            }
        }
    }

    // MARK: llbuildSwift.BuildSystemDelegate

    var fs: SPMLLBuild.FileSystem? {
        return nil
    }

    func lookupTool(_ name: String) -> Tool? {
        switch name {
        case TestDiscoveryTool.name:
            return InProcessTool(buildExecutionContext, type: TestDiscoveryCommand.self)
        case PackageStructureTool.name:
            return InProcessTool(buildExecutionContext, type: PackageStructureCommand.self)
        case CopyTool.name:
            return InProcessTool(buildExecutionContext, type: CopyCommand.self)
        default:
            return nil
        }
    }

    func hadCommandFailure() {
        onCommmandFailure?()
    }

    func handleDiagnostic(_ diagnostic: SPMLLBuild.Diagnostic) {
        switch diagnostic.kind {
        case .note:
            diagnostics.emit(note: diagnostic.message)
        case .warning:
            diagnostics.emit(warning: diagnostic.message)
        case .error:
            diagnostics.emit(error: diagnostic.message)
        @unknown default:
            diagnostics.emit(note: diagnostic.message)
        }
    }

    func commandStatusChanged(_ command: SPMLLBuild.Command, kind: CommandStatusKind) {
        guard !isVerbose else { return }
        guard command.shouldShowStatus else { return }
        guard !swiftParsers.keys.contains(command.name) else { return }

        queue.async {
            self.taskTracker.commandStatusChanged(command, kind: kind)
            self.updateProgress()
        }
    }

    func commandPreparing(_ command: SPMLLBuild.Command) {
        queue.async {
            self.delegate?.buildSystem(self.buildSystem, willStartCommand: BuildSystemCommand(command))
        }
    }

    func commandStarted(_ command: SPMLLBuild.Command) {
        guard command.shouldShowStatus else { return }

        queue.async {
            self.delegate?.buildSystem(self.buildSystem, didStartCommand: BuildSystemCommand(command))
            if self.isVerbose {
                self.outputStream <<< command.verboseDescription <<< "\n"
                self.outputStream.flush()
            }
        }
    }

    func shouldCommandStart(_ command: SPMLLBuild.Command) -> Bool {
        return true
    }

    func commandFinished(_ command: SPMLLBuild.Command, result: CommandResult) {
        guard command.shouldShowStatus else { return }
        guard !swiftParsers.keys.contains(command.name) else { return }

        queue.async {
            self.delegate?.buildSystem(self.buildSystem, didFinishCommand: BuildSystemCommand(command))
            
            if !self.isVerbose {
                let targetName = self.swiftParsers[command.name]?.targetName
                self.taskTracker.commandFinished(command, result: result, targetName: targetName)
                self.updateProgress()
            }
        }
    }

    func commandHadError(_ command: SPMLLBuild.Command, message: String) {
        diagnostics.emit(error: message)
    }

    func commandHadNote(_ command: SPMLLBuild.Command, message: String) {
        diagnostics.emit(note: message)
    }

    func commandHadWarning(_ command: SPMLLBuild.Command, message: String) {
        diagnostics.emit(warning: message)
    }

    func commandCannotBuildOutputDueToMissingInputs(
        _ command: SPMLLBuild.Command,
        output: BuildKey,
        inputs: [BuildKey]
    ) {
        diagnostics.emit(.missingInputs(output: output, inputs: inputs))
    }

    func cannotBuildNodeDueToMultipleProducers(output: BuildKey, commands: [SPMLLBuild.Command]) {
        diagnostics.emit(.multipleProducers(output: output, commands: commands))
    }

    func commandProcessStarted(_ command: SPMLLBuild.Command, process: ProcessHandle) {
    }

    func commandProcessHadError(_ command: SPMLLBuild.Command, process: ProcessHandle, message: String) {
        diagnostics.emit(.commandError(command: command, message: message))
    }

    func commandProcessHadOutput(_ command: SPMLLBuild.Command, process: ProcessHandle, data: [UInt8]) {
        guard command.shouldShowStatus else { return }

        if let swiftParser = swiftParsers[command.name] {
            swiftParser.parse(bytes: data)
        } else {
            queue.async {
                self.progressAnimation.clear()
                self.outputStream <<< data
                self.outputStream.flush()
            }
        }
    }

    func commandProcessFinished(
        _ command: SPMLLBuild.Command,
        process: ProcessHandle,
        result: CommandExtendedResult
    ) {
        if result.result == .failed {
            // The command failed, so we queue up an asynchronous task to see if we have any error messages from the target to provide advice about.
            queue.async {
                guard let target = self.swiftParsers[command.name]?.targetName else { return }
                guard let errorMessages = self.errorMessagesByTarget[target] else { return }
                for errorMessage in errorMessages {
                    // Emit any advice that's provided for each error message.
                    if let adviceMessage = self.buildExecutionContext.buildErrorAdviceProvider?.provideBuildErrorAdvice(for: target, command: command.name, message: errorMessage) {
                        self.outputStream <<< "note: " <<< adviceMessage <<< "\n"
                        self.outputStream.flush()
                    }
                }
            }
        }
    }

    func cycleDetected(rules: [BuildKey]) {
        diagnostics.emit(.cycleError(rules: rules))

        queue.async {
            self.delegate?.buildSystemDidDetectCycleInRules(self.buildSystem)
        }
    }

    func shouldResolveCycle(rules: [BuildKey], candidate: BuildKey, action: CycleAction) -> Bool {
        return false
    }

    // MARK: SwiftCompilerOutputParserDelegate

    func swiftCompilerOutputParser(_ parser: SwiftCompilerOutputParser, didParse message: SwiftCompilerMessage) {
        queue.async {
            if self.isVerbose {
                if let text = message.verboseProgressText {
                    self.outputStream <<< text <<< "\n"
                    self.outputStream.flush()
                }
            } else {
                self.taskTracker.swiftCompilerDidOuputMessage(message, targetName: parser.targetName)
                self.updateProgress()
            }

            if let output = message.standardOutput {
                // first we want to print the output so users have it handy
                if !self.isVerbose {
                    self.progressAnimation.clear()
                }

                self.outputStream <<< output
                self.outputStream.flush()

                // next we want to try and scoop out any errors from the output (if reasonable size, otherwise this will be very slow),
                // so they can later be passed to the advice provider in case of failure.
                if output.utf8.count < 1024 * 10 {
                    let regex = try! RegEx(pattern: #".*(error:[^\n]*)\n.*"#, options: .dotMatchesLineSeparators)
                    for match in regex.matchGroups(in: output) {
                        self.errorMessagesByTarget[parser.targetName] = (self.errorMessagesByTarget[parser.targetName] ?? []) + [match[0]]
                    }
                }
            }
        }
    }

    func swiftCompilerOutputParser(_ parser: SwiftCompilerOutputParser, didFailWith error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        diagnostics.emit(.swiftCompilerOutputParsingError(message))
        onCommmandFailure?()
    }

    func buildComplete(success: Bool) {
        queue.sync {
            if success {
                self.progressAnimation.update(
                    step: self.taskTracker.finishedCount,
                    total: self.taskTracker.totalCount,
                    text: "Build complete!")
            }
            self.progressAnimation.complete(success: success)
        }
    }

    // MARK: Private

    private func updateProgress() {
        if let progressText = taskTracker.latestFinishedText {
            self.progressAnimation.update(
                step: taskTracker.finishedCount,
                total: taskTracker.totalCount,
                text: progressText
            )
        }
    }
}

/// Tracks tasks based on command status and swift compiler output.
fileprivate struct CommandTaskTracker {
    private(set) var totalCount = 0
    private(set) var finishedCount = 0
    private var swiftTaskProgressTexts: [Int: String] = [:]

    /// The last task text before the task list was emptied.
    private(set) var latestFinishedText: String?

    var onTaskProgressUpdateText: ((_ text: String, _ targetName: String?) -> Void)?

    mutating func commandStatusChanged(_ command: SPMLLBuild.Command, kind: CommandStatusKind) {
        switch kind {
        case .isScanning:
            totalCount += 1
        case .isUpToDate:
            totalCount -= 1
        case .isComplete:
            break
        @unknown default:
            assertionFailure("unhandled command status kind \(kind) for command \(command)")
            break
        }
    }
    
    mutating func commandFinished(_ command: SPMLLBuild.Command, result: CommandResult, targetName: String?) {
        let progressTextValue = progressText(of: command, targetName: targetName)
        onTaskProgressUpdateText?(progressTextValue, targetName)

        latestFinishedText = progressTextValue

        switch result {
        case .succeeded, .skipped:
            finishedCount += 1
        case .cancelled, .failed:
            break
        default:
            break
        }
    }
    
    mutating func swiftCompilerDidOuputMessage(_ message: SwiftCompilerMessage, targetName: String) {
        switch message.kind {
        case .began(let info):
            if let text = progressText(of: message, targetName: targetName) {
                swiftTaskProgressTexts[info.pid] = text
                onTaskProgressUpdateText?(text, targetName)
            }

            totalCount += 1
        case .finished(let info):
            if let progressText = swiftTaskProgressTexts[info.pid] {
                latestFinishedText = progressText
                swiftTaskProgressTexts[info.pid] = nil
            }

            finishedCount += 1
        case .unparsableOutput, .signalled, .skipped:
            break
        }
    }

    private func progressText(of command: SPMLLBuild.Command, targetName: String?) -> String {
        // Transforms descriptions like "Linking ./.build/x86_64-apple-macosx/debug/foo" into "Linking foo".
        if let firstSpaceIndex = command.description.firstIndex(of: " "),
           let lastDirectorySeperatorIndex = command.description.lastIndex(of: "/")
        {
            let action = command.description[..<firstSpaceIndex]
            let fileNameStartIndex = command.description.index(after: lastDirectorySeperatorIndex)
            let fileName = command.description[fileNameStartIndex...]

            if let targetName = targetName {
                return "\(action) \(targetName) \(fileName)"
            } else {
                return "\(action) \(fileName)"
            }
        } else {
            return command.description
        }
    }

    private func progressText(of message: SwiftCompilerMessage, targetName: String) -> String? {
        if case .began(let info) = message.kind {
            switch message.name {
            case "compile":
                if let sourceFile = info.inputs.first {
                    return "Compiling \(targetName) \(AbsolutePath(sourceFile).components.last!)"
                }
            case "link":
                return "Linking \(targetName)"
            case "merge-module":
                return "Merging module \(targetName)"
            case "generate-dsym":
                return "Generating \(targetName) dSYM"
            case "generate-pch":
                return "Generating \(targetName) PCH"
            default:
                break
            }
        }

        return nil
    }
}

extension SwiftCompilerMessage {
    fileprivate var verboseProgressText: String? {
        switch kind {
        case .began(let info):
            return ([info.commandExecutable] + info.commandArguments).joined(separator: " ")
        case .skipped, .finished, .signalled, .unparsableOutput:
            return nil
        }
    }

    fileprivate var standardOutput: String? {
        switch kind {
        case .finished(let info),
             .signalled(let info):
            return info.output
        case .unparsableOutput(let output):
            return output
        case .skipped, .began:
            return nil
        }
    }
}

private extension Diagnostic.Message {
    static func cycleError(rules: [BuildKey]) -> Diagnostic.Message {
        .error("build cycle detected: " + rules.map{ $0.key }.joined(separator: ", "))
    }

    static func missingInputs(output: BuildKey, inputs: [BuildKey]) -> Diagnostic.Message {
        let missingInputs = inputs.map{ $0.key }.joined(separator: ", ")
        return .error("couldn't build \(output.key) because of missing inputs: \(missingInputs)")
    }

    static func multipleProducers(output: BuildKey, commands: [SPMLLBuild.Command]) -> Diagnostic.Message {
        let producers = commands.map{ $0.description }.joined(separator: ", ")
        return .error("couldn't build \(output.key) because of missing producers: \(producers)")
    }

    static func commandError(command: SPMLLBuild.Command, message: String) -> Diagnostic.Message {
        .error("command \(command.description) failed: \(message)")
    }

    static func swiftCompilerOutputParsingError(_ error: String) -> Diagnostic.Message {
        .error("failed parsing the Swift compiler output: \(error)")
    }
}

private extension BuildSystemCommand {
    init(_ command: SPMLLBuild.Command) {
        self.init(
            name: command.name,
            description: command.description,
            verboseDescription: command.verboseDescription
        )
    }
}
