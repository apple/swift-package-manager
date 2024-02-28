//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2018-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import _Concurrency
import Basics
import LLBuildManifest
import enum PackageModel.BuildConfiguration
import TSCBasic
import TSCUtility

@_spi(SwiftPMInternal)
import SPMBuildCore

import SPMLLBuild

import enum Dispatch.DispatchTimeInterval
import protocol Foundation.LocalizedError

/// Async-friendly llbuild delegate implementation
final class AsyncLLBuildDelegate: LLBuildBuildSystemDelegate, SwiftCompilerOutputParserDelegate {
    private let outputStream: ThreadSafeOutputByteStream
    private let progressAnimation: ProgressAnimationProtocol
    var commandFailureHandler: (() -> Void)?
    private let logLevel: Basics.Diagnostic.Severity
    private let eventsContinuation: AsyncStream<BuildSystemEvent>.Continuation
    private let buildSystem: AsyncBuildOperation
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
        buildSystem: AsyncBuildOperation,
        buildExecutionContext: BuildExecutionContext,
        eventsContinuation: AsyncStream<BuildSystemEvent>.Continuation,
        outputStream: OutputByteStream,
        progressAnimation: ProgressAnimationProtocol,
        logLevel: Basics.Diagnostic.Severity,
        observabilityScope: ObservabilityScope
    ) {
        self.buildSystem = buildSystem
        self.buildExecutionContext = buildExecutionContext
        // FIXME: Implement a class convenience initializer that does this once they are supported
        // https://forums.swift.org/t/allow-self-x-in-class-convenience-initializers/15924
        self.outputStream = outputStream as? ThreadSafeOutputByteStream ?? ThreadSafeOutputByteStream(outputStream)
        self.progressAnimation = progressAnimation
        self.logLevel = logLevel
        self.observabilityScope = observabilityScope
        self.eventsContinuation = eventsContinuation

        let swiftParsers = buildExecutionContext.buildDescription?.swiftCommands.mapValues { tool in
            SwiftCompilerOutputParser(targetName: tool.moduleName, delegate: self)
        } ?? [:]
        self.swiftParsers = swiftParsers

        self.taskTracker.onTaskProgressUpdateText = { progressText, _ in
            self.eventsContinuation.yield(.didUpdateTaskProgress(text: progressText))
        }
    }

    // MARK: llbuildSwift.BuildSystemDelegate

    var fs: SPMLLBuild.FileSystem? {
        nil
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
        case WriteAuxiliaryFile.name:
            return InProcessTool(buildExecutionContext, type: WriteAuxiliaryFileCommand.self)
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

        self.taskTracker.commandStatusChanged(command, kind: kind)
        self.updateProgress()
    }

    func commandPreparing(_ command: SPMLLBuild.Command) {
        self.eventsContinuation.yield(.willStart(command: .init(command)))
    }

    func commandStarted(_ command: SPMLLBuild.Command) {
        guard command.shouldShowStatus else { return }

        self.eventsContinuation.yield(.didStart(command: .init(command)))
        if self.logLevel.isVerbose {
            self.outputStream.send("\(command.verboseDescription)\n")
            self.outputStream.flush()
        }
    }

    func shouldCommandStart(_: SPMLLBuild.Command) -> Bool {
        true
    }

    func commandFinished(_ command: SPMLLBuild.Command, result: CommandResult) {
        guard command.shouldShowStatus else { return }
        guard !swiftParsers.keys.contains(command.name) else { return }

        if result == .cancelled {
            self.cancelled = true
            self.eventsContinuation.yield(.didCancel)
        }

        self.eventsContinuation.yield(.didFinish(command: .init(command)))

        if !self.logLevel.isVerbose {
            let targetName = self.swiftParsers[command.name]?.targetName
            self.taskTracker.commandFinished(command, result: result, targetName: targetName)
            self.updateProgress()
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

    func commandProcessStarted(_ command: SPMLLBuild.Command, process: ProcessHandle) {}

    func commandProcessHadError(_ command: SPMLLBuild.Command, process: ProcessHandle, message: String) {
        self.observabilityScope.emit(.commandError(command: command, message: message))
    }

    func commandProcessHadOutput(_ command: SPMLLBuild.Command, process: ProcessHandle, data: [UInt8]) {
        guard command.shouldShowStatus else { return }

        if let swiftParser = swiftParsers[command.name] {
            swiftParser.parse(bytes: data)
        } else {
            self.nonSwiftMessageBuffers[command.name, default: []] += data
        }
    }

    func commandProcessFinished(
        _ command: SPMLLBuild.Command,
        process: ProcessHandle,
        result: CommandExtendedResult
    ) {
        // FIXME: This should really happen at the command-level and is just a stopgap measure.
        let shouldFilterOutput = !self.logLevel.isVerbose && command.verboseDescription.hasPrefix("codesign ") && result.result != .failed
        if let buffer = self.nonSwiftMessageBuffers[command.name], !shouldFilterOutput {
            self.progressAnimation.clear()
            self.outputStream.send(buffer)
            self.outputStream.flush()
            self.nonSwiftMessageBuffers[command.name] = nil
        }

        switch result.result {
        case .cancelled:
            self.cancelled = true
            self.eventsContinuation.yield(.didCancel)
        case .failed:
            // The command failed, so we queue up an asynchronous task to see if we have any error messages from the
            // target to provide advice about.
            guard let target = self.swiftParsers[command.name]?.targetName else { return }
            guard let errorMessages = self.errorMessagesByTarget[target] else { return }
            for errorMessage in errorMessages {
                // Emit any advice that's provided for each error message.
                if let adviceMessage = self.buildExecutionContext.buildErrorAdviceProvider?.provideBuildErrorAdvice(
                    for: target,
                    command: command.name,
                    message: errorMessage
                ) {
                    self.outputStream.send("note: \(adviceMessage)\n")
                    self.outputStream.flush()
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

        self.eventsContinuation.yield(.didDetectCycleInRules)
    }

    func shouldResolveCycle(rules: [BuildKey], candidate: BuildKey, action: CycleAction) -> Bool {
        false
    }

    /// Invoked right before running an action taken before building.
    func preparationStepStarted(_ name: String) {
        self.taskTracker.buildPreparationStepStarted(name)
        self.updateProgress()
    }

    /// Invoked when an action taken before building emits output.
    /// when verboseOnly is set to true, the output will only be printed in verbose logging mode
    func preparationStepHadOutput(_ name: String, output: String, verboseOnly: Bool) {
        self.progressAnimation.clear()
        if !verboseOnly || self.logLevel.isVerbose {
            self.outputStream.send("\(output.spm_chomp())\n")
            self.outputStream.flush()
        }
    }

    /// Invoked right after running an action taken before building. The result
    /// indicates whether the action succeeded, failed, or was cancelled.
    func preparationStepFinished(_ name: String, result: CommandResult) {
        self.taskTracker.buildPreparationStepFinished(name)
        self.updateProgress()
    }

    // MARK: SwiftCompilerOutputParserDelegate

    func swiftCompilerOutputParser(_ parser: SwiftCompilerOutputParser, didParse message: SwiftCompilerMessage) {
        if self.logLevel.isVerbose {
            if let text = message.verboseProgressText {
                self.outputStream.send("\(text)\n")
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

            self.outputStream.send(output)
            self.outputStream.flush()

            // next we want to try and scoop out any errors from the output (if reasonable size, otherwise this
            // will be very slow), so they can later be passed to the advice provider in case of failure.
            if output.utf8.count < 1024 * 10 {
                let regex = try! RegEx(pattern: #".*(error:[^\n]*)\n.*"#, options: .dotMatchesLineSeparators)
                for match in regex.matchGroups(in: output) {
                    self.errorMessagesByTarget[parser.targetName] = (
                            self.errorMessagesByTarget[parser.targetName] ?? []
                    ) + [match[0]]
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
        self.progressAnimation.clear()
        self.outputStream.send("Building for \(configuration == .debug ? "debugging" : "production")...\n")
        self.outputStream.flush()
    }

    func buildComplete(success: Bool, duration: DispatchTimeInterval, subsetDescriptor: String? = nil) {
        let subsetString: String
        if let subsetDescriptor {
            subsetString = "of \(subsetDescriptor) "
        } else {
            subsetString = ""
        }

        self.progressAnimation.complete(success: success)
        if success {
            let message = cancelled ? "Build \(subsetString)cancelled!" : "Build \(subsetString)complete!"
            self.progressAnimation.clear()
            self.outputStream.send("\(message) (\(duration.descriptionInSeconds))\n")
            self.outputStream.flush()
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
