//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Dispatch
import Foundation
import LLBuildManifest
import PackageModel
import SPMBuildCore
import SPMLLBuild
import TSCBasic

import class TSCUtility.IndexStore
import class TSCUtility.IndexStoreAPI
import protocol TSCUtility.ProgressAnimationProtocol

#if canImport(llbuildSwift)
typealias LLBuildBuildSystemDelegate = llbuildSwift.BuildSystemDelegate
#else
typealias LLBuildBuildSystemDelegate = llbuild.BuildSystemDelegate
#endif

typealias Diagnostic = TSCBasic.Diagnostic

class CustomLLBuildCommand: SPMLLBuild.ExternalCommand {
    let context: BuildExecutionContext

    required init(_ context: BuildExecutionContext) {
        self.context = context
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

private extension IndexStore.TestCaseClass.TestMethod {

    var allTestsEntry: String {
        let baseName = name.hasSuffix("()") ? String(name.dropLast(2)) : name

        return "(\"\(baseName)\", __testFunction__(\(baseName)))"
    }
}

final class TestDiscoveryCommand: CustomLLBuildCommand, TestBuildCommand {

    private func write(
        tests: [IndexStore.TestCaseClass],
        forModule module: String,
        to path: AbsolutePath
    ) throws {
        let stream = try LocalFileOutputByteStream(path)

        let testsByClassNames = Dictionary(grouping: tests, by: { $0.name }).sorted(by: { $0.key < $1.key })

        stream <<< "import XCTest" <<< "\n"
        stream <<< "@testable import " <<< module <<< "\n"

        // Inject an overloaded helper function, __testFunction__, to help us
        // disambiguate between synchronous and asynchronous functions.
        stream <<< """
        typealias __TestFunction__<T: XCTestCase> = (T) -> () throws -> Void
        typealias __AsyncTestFunction__<T: XCTestCase> = (T) -> () async throws -> Void

        func __testFunction__<T: XCTestCase>(_ function: @escaping __TestFunction__<T>) -> __TestFunction__<T> {
            return function
        }

        func __testFunction__<T: XCTestCase>(_ function: @escaping __AsyncTestFunction__<T>) -> __TestFunction__<T> {
            return asyncTest(function)
        }
        """

        for iterator in testsByClassNames {
            let className = iterator.key
            let testMethods = iterator.value.flatMap{ $0.testMethods }
            stream <<< "\n"
            stream <<< "fileprivate extension " <<< className <<< " {" <<< "\n"
            stream <<< indent(4) <<< "@available(*, deprecated, message: \"Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings\")" <<< "\n"
            // 'className' provides uniqueness for derived class.
            stream <<< indent(4) <<< "static let __allTests__\(className) = [" <<< "\n"
            for method in testMethods {
                stream <<< indent(8) <<< method.allTestsEntry <<< ",\n"
            }
            stream <<< indent(4) <<< "]" <<< "\n"
            stream <<< "}" <<< "\n"
        }

        stream <<< """
        @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
        func __\(module)__allTests() -> [XCTestCaseEntry] {
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

    private func execute(fileSystem: TSCBasic.FileSystem, tool: LLBuildManifest.TestDiscoveryTool) throws {
        let index = self.context.buildParameters.indexStore
        let api = try self.context.indexStoreAPI.get()
        let store = try IndexStore.open(store: index, api: api)

        // FIXME: We can speed this up by having one llbuild command per object file.
        let tests = try store.listTests(in: tool.inputs.map{ try AbsolutePath(validating: $0.name) })

        let outputs = tool.outputs.compactMap{ try? AbsolutePath(validating: $0.name) }
        let testsByModule = Dictionary(grouping: tests, by: { $0.module.spm_mangledToC99ExtendedIdentifier() })

        func isMainFile(_ path: AbsolutePath) -> Bool {
            return path.basename == LLBuildManifest.TestDiscoveryTool.mainFileName
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
                try fileSystem.writeFileContents(file, bytes: "")
                continue
            }
            try write(tests: tests, forModule: module, to: file)
        }

        guard let mainFile = maybeMainFile else {
            throw InternalError("main output (\(LLBuildManifest.TestDiscoveryTool.mainFileName)) not found")
        }

        let testsKeyword = tests.isEmpty ? "let" : "var"

        // Write the main file.
        let stream = try LocalFileOutputByteStream(mainFile)

        stream <<< "import XCTest" <<< "\n\n"

        stream <<< "@available(*, deprecated, message: \"Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings\")" <<< "\n"
        stream <<< "public func __allDiscoveredTests() -> [XCTestCaseEntry] {" <<< "\n"
        stream <<< indent(4) <<< "\(testsKeyword) tests = [XCTestCaseEntry]()" <<< "\n\n"

        for module in testsByModule.keys {
            stream <<< indent(4) <<< "tests += __\(module)__allTests()" <<< "\n"
        }

        stream <<< "\n"
        stream <<< indent(4) <<< "return tests" <<< "\n"
        stream <<< "}" <<< "\n"

        stream.flush()
    }

    override func execute(
        _ command: SPMLLBuild.Command,
        _ buildSystemCommandInterface: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        do {
            // This tool will never run without the build description.
            guard let buildDescription = self.context.buildDescription else {
                throw InternalError("unknown build description")
            }
            guard let tool = buildDescription.testDiscoveryCommands[command.name] else {
                throw InternalError("command \(command.name) not registered")
            }
            try execute(fileSystem: self.context.fileSystem, tool: tool)
            return true
        } catch {
            self.context.observabilityScope.emit(error)
            return false
        }
    }
}

final class TestEntryPointCommand: CustomLLBuildCommand, TestBuildCommand {

    private func execute(fileSystem: TSCBasic.FileSystem, tool: LLBuildManifest.TestEntryPointTool) throws {
        // Find the inputs, which are the names of the test discovery module(s)
        let inputs = tool.inputs.compactMap { try? AbsolutePath(validating: $0.name) }
        let discoveryModuleNames = inputs.map { $0.basenameWithoutExt }

        let outputs = tool.outputs.compactMap { try? AbsolutePath(validating: $0.name) }

        // Find the main output file
        guard let mainFile = outputs.first(where: { path in
            path.basename == LLBuildManifest.TestEntryPointTool.mainFileName
        }) else {
            throw InternalError("main file output (\(LLBuildManifest.TestEntryPointTool.mainFileName)) not found")
        }

        // Write the main file.
        let stream = try LocalFileOutputByteStream(mainFile)

        stream <<< "import XCTest" <<< "\n"
        for discoveryModuleName in discoveryModuleNames {
            stream <<< "import \(discoveryModuleName)" <<< "\n"
        }
        stream <<< "\n"

        stream <<< "@main" <<< "\n"
        stream <<< "@available(*, deprecated, message: \"Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings\")" <<< "\n"
        stream <<< "struct Runner" <<< " {" <<< "\n"
        stream <<< indent(4) <<< "static func main()" <<< " {" <<< "\n"
        stream <<< indent(8) <<< "XCTMain(__allDiscoveredTests())" <<< "\n"
        stream <<< indent(4) <<< "}" <<< "\n"
        stream <<< "}" <<< "\n"

        stream.flush()
    }

    override func execute(
        _ command: SPMLLBuild.Command,
        _ buildSystemCommandInterface: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        do {
            // This tool will never run without the build description.
            guard let buildDescription = self.context.buildDescription else {
                throw InternalError("unknown build description")
            }
            guard let tool = buildDescription.testEntryPointCommands[command.name] else {
                throw InternalError("command \(command.name) not registered")
            }
            try execute(fileSystem: self.context.fileSystem, tool: tool)
            return true
        } catch {
            self.context.observabilityScope.emit(error)
            return false
        }
    }
}

private protocol TestBuildCommand {}

/// Functionality common to all build commands related to test targets.
extension TestBuildCommand {

    /// Returns a value containing `spaces` number of space characters.
    /// Intended to facilitate indenting generated code a specified number of levels.
    fileprivate func indent(_ spaces: Int) -> ByteStreamable {
        return Format.asRepeating(string: " ", count: spaces)
    }

}

private final class InProcessTool: Tool {
    let context: BuildExecutionContext
    let type: CustomLLBuildCommand.Type

    init(_ context: BuildExecutionContext, type: CustomLLBuildCommand.Type) {
        self.context = context
        self.type = type
    }

    func createCommand(_ name: String) -> ExternalCommand? {
        return type.init(self.context)
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

    /// The map of test entry point commands.
    let testEntryPointCommands: [BuildManifest.CmdName: LLBuildManifest.TestEntryPointTool]

    /// The map of copy commands.
    let copyCommands: [BuildManifest.CmdName: LLBuildManifest.CopyTool]

    /// A flag that inidcates this build should perform a check for whether targets only import
    /// their explicitly-declared dependencies
    let explicitTargetDependencyImportCheckingMode: BuildParameters.TargetDependencyImportCheckingMode

    /// Every target's set of dependencies.
    let targetDependencyMap: [TargetName: [TargetName]]

    /// A full swift driver command-line invocation used to dependency-scan a given Swift target
    let swiftTargetScanArgs: [TargetName: [CommandLineFlag]]

    /// A set of all targets with generated source
    let generatedSourceTargetSet: Set<TargetName>

    /// The built test products.
    public let builtTestProducts: [BuiltTestProduct]

    /// Distilled information about any plugins defined in the package.
    let pluginDescriptions: [PluginDescription]

    public init(
        plan: BuildPlan,
        swiftCommands: [BuildManifest.CmdName : SwiftCompilerTool],
        swiftFrontendCommands: [BuildManifest.CmdName : SwiftFrontendTool],
        testDiscoveryCommands: [BuildManifest.CmdName: LLBuildManifest.TestDiscoveryTool],
        testEntryPointCommands: [BuildManifest.CmdName: LLBuildManifest.TestEntryPointTool],
        copyCommands: [BuildManifest.CmdName: LLBuildManifest.CopyTool],
        pluginDescriptions: [PluginDescription]
    ) throws {
        self.swiftCommands = swiftCommands
        self.swiftFrontendCommands = swiftFrontendCommands
        self.testDiscoveryCommands = testDiscoveryCommands
        self.testEntryPointCommands = testEntryPointCommands
        self.copyCommands = copyCommands
        self.explicitTargetDependencyImportCheckingMode = plan.buildParameters.explicitTargetDependencyImportCheckingMode
        self.targetDependencyMap = try plan.targets.reduce(into: [TargetName: [TargetName]]()) {
            let deps = try $1.target.recursiveDependencies(satisfying: plan.buildParameters.buildEnvironment).compactMap { $0.target }.map { $0.c99name }
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
                                                                  plan.buildParameters.toolchain.swiftCompilerPath.pathString]
            if case .discovery = desc.testTargetRole {
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
                binaryPath: desc.binaryPath
            )
        }
        self.pluginDescriptions = pluginDescriptions
    }

    public func write(fileSystem: TSCBasic.FileSystem, path: AbsolutePath) throws {
        let encoder = JSONEncoder.makeWithDefaults()
        let data = try encoder.encode(self)
        try fileSystem.writeFileContents(path, bytes: ByteString(data))
    }

    public static func load(fileSystem: TSCBasic.FileSystem, path: AbsolutePath) throws -> BuildDescription {
        let contents: Data = try fileSystem.readFileContents(path)
        let decoder = JSONDecoder.makeWithDefaults()
        return try decoder.decode(BuildDescription.self, from: contents)
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

    let fileSystem: TSCBasic.FileSystem

    let observabilityScope: ObservabilityScope

    public init(
        _ buildParameters: BuildParameters,
        buildDescription: BuildDescription? = nil,
        fileSystem: TSCBasic.FileSystem,
        observabilityScope: ObservabilityScope,
        packageStructureDelegate: PackageStructureDelegate,
        buildErrorAdviceProvider: BuildErrorAdviceProvider? = nil
    ) {
        self.buildParameters = buildParameters
        self.buildDescription = buildDescription
        self.fileSystem = fileSystem
        self.observabilityScope = observabilityScope
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
            let indexStoreLib = buildParameters.toolchain.swiftCompilerPath
                                    .parentDirectory
                                    .appending(component: "libIndexStore.dll")
#else
            let ext = buildParameters.hostTriple.dynamicLibraryExtension
            let indexStoreLib = try buildParameters.toolchain.toolchainLibDir.appending(component: "libIndexStore" + ext)
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
        hash += try! encoder.encode(self.context.buildParameters)
        hash += try! encoder.encode(ProcessEnv.vars)
        return [UInt8](hash)
    }

    override func execute(
        _ command: SPMLLBuild.Command,
        _ commandInterface: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        return self.context.packageStructureDelegate.packageStructureChanged()
    }
}

final class CopyCommand: CustomLLBuildCommand {
    override func execute(
        _ command: SPMLLBuild.Command,
        _ commandInterface: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        do {
            // This tool will never run without the build description.
            guard let buildDescription = self.context.buildDescription else {
                throw InternalError("unknown build description")
            }
            guard let tool = buildDescription.copyCommands[command.name] else {
                throw StringError("command \(command.name) not registered")
            }

            let input = try AbsolutePath(validating: tool.inputs[0].name)
            let output = try AbsolutePath(validating: tool.outputs[0].name)
            try self.context.fileSystem.createDirectory(output.parentDirectory, recursive: true)
            try self.context.fileSystem.removeFileTree(output)
            try self.context.fileSystem.copy(from: input, to: output)
        } catch {
            self.context.observabilityScope.emit(error)
            return false
        }
        return true
    }
}

/// Convenient llbuild build system delegate implementation
final class BuildOperationBuildSystemDelegateHandler: LLBuildBuildSystemDelegate, SwiftCompilerOutputParserDelegate {
    private let outputStream: ThreadSafeOutputByteStream
    private let progressAnimation: ProgressAnimationProtocol
    var commandFailureHandler: (() -> Void)?
    private let logLevel: Basics.Diagnostic.Severity
    private weak var delegate: SPMBuildCore.BuildSystemDelegate?
    private let buildSystem: SPMBuildCore.BuildSystem
    private let queue = DispatchQueue(label: "org.swift.swiftpm.build-delegate")
    private var taskTracker = CommandTaskTracker()
    private var errorMessagesByTarget: [String: [String]] = [:]
    private let observabilityScope: ObservabilityScope
    private var cancelled: Bool = false

    /// Swift parsers keyed by llbuild command name.
    private var swiftParsers: [String: SwiftCompilerOutputParser] = [:]

    /// Buffer to accumulate non-swift output until command is finished
    private var nonSwiftMessageBuffers: [String: [UInt8]] = [:]

    /// The build execution context.
    private let buildExecutionContext: BuildExecutionContext

    init(
        buildSystem: SPMBuildCore.BuildSystem,
        buildExecutionContext: BuildExecutionContext,
        outputStream: OutputByteStream,
        progressAnimation: ProgressAnimationProtocol,
        logLevel: Basics.Diagnostic.Severity,
        observabilityScope: ObservabilityScope,
        delegate: SPMBuildCore.BuildSystemDelegate?
    ) {
        self.buildSystem = buildSystem
        self.buildExecutionContext = buildExecutionContext
        // FIXME: Implement a class convenience initializer that does this once they are supported
        // https://forums.swift.org/t/allow-self-x-in-class-convenience-initializers/15924
        self.outputStream = outputStream as? ThreadSafeOutputByteStream ?? ThreadSafeOutputByteStream(outputStream)
        self.progressAnimation = progressAnimation
        self.logLevel = logLevel
        self.observabilityScope = observabilityScope
        self.delegate = delegate

        let swiftParsers = buildExecutionContext.buildDescription?.swiftCommands.mapValues { tool in
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
        case TestEntryPointTool.name:
            return InProcessTool(buildExecutionContext, type: TestEntryPointCommand.self)
        case PackageStructureTool.name:
            return InProcessTool(buildExecutionContext, type: PackageStructureCommand.self)
        case CopyTool.name:
            return InProcessTool(buildExecutionContext, type: CopyCommand.self)
        default:
            return nil
        }
    }

    func hadCommandFailure() {
        self.commandFailureHandler?()
    }

    func handleDiagnostic(_ diagnostic: SPMLLBuild.Diagnostic) {
        switch diagnostic.kind {
        case .note:
            self.observabilityScope.emit(info: diagnostic.message)
        case .warning:
            self.observabilityScope.emit(warning: diagnostic.message)
        case .error:
            self.observabilityScope.emit(error: diagnostic.message)
        @unknown default:
            self.observabilityScope.emit(info: diagnostic.message)
        }
    }

    func commandStatusChanged(_ command: SPMLLBuild.Command, kind: CommandStatusKind) {
        guard !self.logLevel.isVerbose else { return }
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
            if self.logLevel.isVerbose {
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
            if result == .cancelled {
                self.cancelled = true
                self.delegate?.buildSystemDidCancel(self.buildSystem)
            }

            self.delegate?.buildSystem(self.buildSystem, didFinishCommand: BuildSystemCommand(command))

            if !self.logLevel.isVerbose {
                let targetName = self.swiftParsers[command.name]?.targetName
                self.taskTracker.commandFinished(command, result: result, targetName: targetName)
                self.updateProgress()
            }
        }
    }

    func commandHadError(_ command: SPMLLBuild.Command, message: String) {
        self.observabilityScope.emit(error: message)
    }

    func commandHadNote(_ command: SPMLLBuild.Command, message: String) {
        self.observabilityScope.emit(info: message)
    }

    func commandHadWarning(_ command: SPMLLBuild.Command, message: String) {
        self.observabilityScope.emit(warning: message)
    }

    func commandCannotBuildOutputDueToMissingInputs(
        _ command: SPMLLBuild.Command,
        output: BuildKey,
        inputs: [BuildKey]
    ) {
        self.observabilityScope.emit(.missingInputs(output: output, inputs: inputs))
    }

    func cannotBuildNodeDueToMultipleProducers(output: BuildKey, commands: [SPMLLBuild.Command]) {
        self.observabilityScope.emit(.multipleProducers(output: output, commands: commands))
    }

    func commandProcessStarted(_ command: SPMLLBuild.Command, process: ProcessHandle) {
    }

    func commandProcessHadError(_ command: SPMLLBuild.Command, process: ProcessHandle, message: String) {
        self.observabilityScope.emit(.commandError(command: command, message: message))
    }

    func commandProcessHadOutput(_ command: SPMLLBuild.Command, process: ProcessHandle, data: [UInt8]) {
        guard command.shouldShowStatus else { return }

        if let swiftParser = swiftParsers[command.name] {
            swiftParser.parse(bytes: data)
        } else {
            queue.async {
                self.nonSwiftMessageBuffers[command.name, default: []] += data
            }
        }
    }

    func commandProcessFinished(
        _ command: SPMLLBuild.Command,
        process: ProcessHandle,
        result: CommandExtendedResult
    ) {
        queue.async {
            if let buffer = self.nonSwiftMessageBuffers[command.name] {
                self.progressAnimation.clear()
                self.outputStream <<< buffer
                self.outputStream.flush()
                self.nonSwiftMessageBuffers[command.name] = nil
            }
        }

        switch result.result {
        case .cancelled:
            self.cancelled = true
            self.delegate?.buildSystemDidCancel(self.buildSystem)
        case .failed:
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
        case .succeeded, .skipped:
            break
        @unknown default:
            break
        }
    }

    func cycleDetected(rules: [BuildKey]) {
        self.observabilityScope.emit(.cycleError(rules: rules))

        queue.async {
            self.delegate?.buildSystemDidDetectCycleInRules(self.buildSystem)
        }
    }

    func shouldResolveCycle(rules: [BuildKey], candidate: BuildKey, action: CycleAction) -> Bool {
        return false
    }

    /// Invoked right before running an action taken before building.
    func preparationStepStarted(_ name: String) {
        queue.async {
            self.taskTracker.buildPreparationStepStarted(name)
            self.updateProgress()
        }
    }

    /// Invoked when an action taken before building emits output.
    func preparationStepHadOutput(_ name: String, output: String) {
        queue.async {
            self.progressAnimation.clear()
            if self.logLevel.isVerbose {
                self.outputStream <<< output.spm_chomp() <<< "\n"
                self.outputStream.flush()
            }
        }
    }

    /// Invoked right after running an action taken before building. The result
    /// indicates whether the action succeeded, failed, or was cancelled.
    func preparationStepFinished(_ name: String, result: CommandResult) {
        queue.async {
            self.taskTracker.buildPreparationStepFinished(name)
            self.updateProgress()
        }
    }

    // MARK: SwiftCompilerOutputParserDelegate

    func swiftCompilerOutputParser(_ parser: SwiftCompilerOutputParser, didParse message: SwiftCompilerMessage) {
        queue.async {
            if self.logLevel.isVerbose {
                if let text = message.verboseProgressText {
                    self.outputStream <<< text <<< "\n"
                    self.outputStream.flush()
                }
            } else {
                self.taskTracker.swiftCompilerDidOutputMessage(message, targetName: parser.targetName)
                self.updateProgress()
            }

            if let output = message.standardOutput {
                // first we want to print the output so users have it handy
                if !self.logLevel.isVerbose {
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
        self.observabilityScope.emit(.swiftCompilerOutputParsingError(message))
        self.commandFailureHandler?()
    }

    func buildStart(configuration: BuildConfiguration) {
        queue.sync {
            self.progressAnimation.clear()
            self.outputStream <<< "Building for \(configuration == .debug ? "debugging" : "production")...\n"
            self.outputStream.flush()
        }
    }

    func buildComplete(success: Bool, duration: DispatchTimeInterval) {
        queue.sync {
            self.progressAnimation.complete(success: success)
            if success {
                let message = cancelled ? "Build cancelled!" : "Build complete!"
                self.progressAnimation.clear()
                self.outputStream <<< "\(message) (\(duration.descriptionInSeconds))\n"
                self.outputStream.flush()
            }
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
            self.totalCount += 1
        case .isUpToDate:
            self.totalCount -= 1
        case .isComplete:
            self.finishedCount += 1
        @unknown default:
            assertionFailure("unhandled command status kind \(kind) for command \(command)")
            break
        }
    }

    mutating func commandFinished(_ command: SPMLLBuild.Command, result: CommandResult, targetName: String?) {
        let progressTextValue = progressText(of: command, targetName: targetName)
        self.onTaskProgressUpdateText?(progressTextValue, targetName)

        self.latestFinishedText = progressTextValue
    }

    mutating func swiftCompilerDidOutputMessage(_ message: SwiftCompilerMessage, targetName: String) {
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
           let lastDirectorySeparatorIndex = command.description.lastIndex(of: "/")
        {
            let action = command.description[..<firstSpaceIndex]
            let fileNameStartIndex = command.description.index(after: lastDirectorySeparatorIndex)
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
                    let sourceFilePath = try! AbsolutePath(validating: sourceFile)
                    return "Compiling \(targetName) \(sourceFilePath.components.last!)"
                }
            case "link":
                return "Linking \(targetName)"
            case "merge-module":
                return "Merging module \(targetName)"
            case "emit-module":
                return "Emitting module \(targetName)"
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
    
    mutating func buildPreparationStepStarted(_ name: String) {
        self.totalCount += 1
    }

    mutating func buildPreparationStepFinished(_ name: String) {
        latestFinishedText = name
        self.finishedCount += 1
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

private extension Basics.Diagnostic {
    static func cycleError(rules: [BuildKey]) -> Self {
        .error("build cycle detected: " + rules.map{ $0.key }.joined(separator: ", "))
    }

    static func missingInputs(output: BuildKey, inputs: [BuildKey]) -> Self {
        let missingInputs = inputs.map{ $0.key }.joined(separator: ", ")
        return .error("couldn't build \(output.key) because of missing inputs: \(missingInputs)")
    }

    static func multipleProducers(output: BuildKey, commands: [SPMLLBuild.Command]) -> Self {
        let producers = commands.map{ $0.description }.joined(separator: ", ")
        return .error("couldn't build \(output.key) because of missing producers: \(producers)")
    }

    static func commandError(command: SPMLLBuild.Command, message: String) -> Self {
        .error("command \(command.description) failed: \(message)")
    }

    static func swiftCompilerOutputParsingError(_ error: String) -> Self {
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
