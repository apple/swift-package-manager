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

import Basics
import Foundation
import LLBuildManifest
import SPMBuildCore
import SPMLLBuild

import class TSCBasic.LocalFileOutputByteStream

import class TSCUtility.IndexStore

class CustomLLBuildCommand: SPMLLBuild.ExternalCommand {
    let context: BuildExecutionContext

    required init(_ context: BuildExecutionContext) {
        self.context = context
    }

    func getSignature(_: SPMLLBuild.Command) -> [UInt8] {
        []
    }

    func execute(
        _: SPMLLBuild.Command,
        _: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        fatalError("subclass responsibility")
    }
}

private protocol TestBuildCommand {}

extension IndexStore.TestCaseClass.TestMethod {
    fileprivate var allTestsEntry: String {
        let baseName = name.hasSuffix("()") ? String(name.dropLast(2)) : name

        return "(\"\(baseName)\", \(isAsync ? "asyncTest(\(baseName))" : baseName))"
    }
}

extension TestEntryPointTool {
    public static func mainFileName(for library: BuildParameters.Testing.Library) -> String {
        "runner-\(library).swift"
    }
}

final class TestDiscoveryCommand: CustomLLBuildCommand, TestBuildCommand {
    private func write(
        tests: [IndexStore.TestCaseClass],
        forModule module: String,
        fileSystem: Basics.FileSystem,
        path: AbsolutePath
    ) throws {
        let testsByClassNames = Dictionary(grouping: tests, by: { $0.name }).sorted(by: { $0.key < $1.key })

        var content = "import XCTest\n"
        content += "@testable import \(module)\n"

        for iterator in testsByClassNames {
            // 'className' provides uniqueness for derived class.
            let className = iterator.key
            let testMethods = iterator.value.flatMap(\.testMethods)
            content +=
                #"""

                fileprivate extension \#(className) {
                    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
                    @MainActor
                    static let __allTests__\#(className) = [
                        \#(testMethods.map(\.allTestsEntry).joined(separator: ",\n        "))
                    ]
                }

                """#
        }

        content +=
            #"""
            @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
            @MainActor
            func __\#(module)__allTests() -> [XCTestCaseEntry] {
                return [
                    \#(
                        testsByClassNames.map { "testCase(\($0.key).__allTests__\($0.key))" }
                            .joined(separator: ",\n        ")
            )
                ]
            }
            """#

        try fileSystem.writeFileContents(path, string: content)
    }

    private func execute(fileSystem: Basics.FileSystem, tool: TestDiscoveryTool) throws {
        let outputs = tool.outputs.compactMap { try? AbsolutePath(validating: $0.name) }

        switch self.context.productsBuildParameters.testingParameters.library {
        case .swiftTesting:
            for file in outputs {
                try fileSystem.writeIfChanged(path: file, string: "")
            }
        case .xctest:
            let index = self.context.productsBuildParameters.indexStore
            let api = try self.context.indexStoreAPI.get()
            let store = try IndexStore.open(store: TSCAbsolutePath(index), api: api)

            // FIXME: We can speed this up by having one llbuild command per object file.
            let tests = try store
                .listTests(in: tool.inputs.map { try TSCAbsolutePath(AbsolutePath(validating: $0.name)) })

            let testsByModule = Dictionary(grouping: tests, by: { $0.module.spm_mangledToC99ExtendedIdentifier() })

            // Find the main file path.
            guard let mainFile = outputs.first(where: { path in
                path.basename == TestDiscoveryTool.mainFileName
            }) else {
                throw InternalError("main output (\(TestDiscoveryTool.mainFileName)) not found")
            }

            // Write one file for each test module.
            //
            // We could write everything in one file but that can easily run into type conflicts due
            // in complex packages with large number of test modules.
            for file in outputs where file != mainFile {
                // FIXME: This is relying on implementation detail of the output but passing the
                // the context all the way through is not worth it right now.
                let module = file.basenameWithoutExt.spm_mangledToC99ExtendedIdentifier()

                guard let tests = testsByModule[module] else {
                    // This module has no tests so just write an empty file for it.
                    try fileSystem.writeFileContents(file, bytes: "")
                    continue
                }
                try write(
                    tests: tests,
                    forModule: module,
                    fileSystem: fileSystem,
                    path: file
                )
            }

            let testsKeyword = tests.isEmpty ? "let" : "var"

            // Write the main file.
            let stream = try LocalFileOutputByteStream(mainFile)

            stream.send(
                #"""
                import XCTest

                @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
                @MainActor
                public func __allDiscoveredTests() -> [XCTestCaseEntry] {
                    \#(testsKeyword) tests = [XCTestCaseEntry]()

                    \#(testsByModule.keys.map { "tests += __\($0)__allTests()" }.joined(separator: "\n    "))

                    return tests
                }
                """#
            )

            stream.flush()
        }
    }

    override func execute(
        _ command: SPMLLBuild.Command,
        _: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        do {
            // This tool will never run without the build description.
            guard let buildDescription = self.context.buildDescription else {
                throw InternalError("unknown build description")
            }
            guard let tool = buildDescription.testDiscoveryCommands[command.name] else {
                throw InternalError("command \(command.name) not registered")
            }
            try self.execute(fileSystem: self.context.fileSystem, tool: tool)
            return true
        } catch {
            self.context.observabilityScope.emit(error)
            return false
        }
    }
}

final class TestEntryPointCommand: CustomLLBuildCommand, TestBuildCommand {
    private func execute(fileSystem: Basics.FileSystem, tool: TestEntryPointTool) throws {
        let outputs = tool.outputs.compactMap { try? AbsolutePath(validating: $0.name) }

        // Find the main output file
        let mainFileName = TestEntryPointTool.mainFileName(
            for: self.context.productsBuildParameters.testingParameters.library
        )
        guard let mainFile = outputs.first(where: { path in
            path.basename == mainFileName
        }) else {
            throw InternalError("main file output (\(mainFileName)) not found")
        }

        // Write the main file.
        let stream = try LocalFileOutputByteStream(mainFile)

        switch self.context.productsBuildParameters.testingParameters.library {
        case .swiftTesting:
            stream.send(
                #"""
                #if canImport(Testing)
                import Testing
                #endif

                @main struct Runner {
                    static func main() async {
                #if canImport(Testing)
                        await Testing.__swiftPMEntryPoint() as Never
                #endif
                    }
                }
                """#
            )
        case .xctest:
            // Find the inputs, which are the names of the test discovery module(s)
            let inputs = tool.inputs.compactMap { try? AbsolutePath(validating: $0.name) }
            let discoveryModuleNames = inputs.map(\.basenameWithoutExt)

            let testObservabilitySetup: String
            let buildParameters = self.context.productsBuildParameters
            if buildParameters.testingParameters.experimentalTestOutput && buildParameters.triple.supportsTestSummary {
                testObservabilitySetup = "_ = SwiftPMXCTestObserver()\n"
            } else {
                testObservabilitySetup = ""
            }

            stream.send(
                #"""
                \#(generateTestObservationCode(buildParameters: buildParameters))

                import XCTest
                \#(discoveryModuleNames.map { "import \($0)" }.joined(separator: "\n"))

                @main
                @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
                struct Runner {
                    #if os(WASI)
                    /// On WASI, we can't block the main thread, so XCTestMain is defined as async.
                    static func main() async {
                        \#(testObservabilitySetup)
                        await XCTMain(__allDiscoveredTests()) as Never
                    }
                    #else
                    static func main() {
                        \#(testObservabilitySetup)
                        XCTMain(__allDiscoveredTests()) as Never
                    }
                    #endif
                }
                """#
            )
        }

        stream.flush()
    }

    override func execute(
        _ command: SPMLLBuild.Command,
        _: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        do {
            // This tool will never run without the build description.
            guard let buildDescription = self.context.buildDescription else {
                throw InternalError("unknown build description")
            }
            guard let tool = buildDescription.testEntryPointCommands[command.name] else {
                throw InternalError("command \(command.name) not registered")
            }
            try self.execute(fileSystem: self.context.fileSystem, tool: tool)
            return true
        } catch {
            self.context.observabilityScope.emit(error)
            return false
        }
    }
}

final class WriteAuxiliaryFileCommand: CustomLLBuildCommand {
    override func getSignature(_ command: SPMLLBuild.Command) -> [UInt8] {
        guard let buildDescription = self.context.buildDescription else {
            self.context.observabilityScope.emit(error: "unknown build description")
            return []
        }
        guard let tool = buildDescription.writeCommands[command.name] else {
            self.context.observabilityScope.emit(error: "command \(command.name) not registered")
            return []
        }

        do {
            let encoder = JSONEncoder.makeWithDefaults()
            var hash = Data()
            hash += try encoder.encode(tool.inputs)
            hash += try encoder.encode(tool.outputs)
            return [UInt8](hash)
        } catch {
            self.context.observabilityScope.emit(error: "getSignature() failed: \(error.interpolationDescription)")
            return []
        }
    }

    override func execute(
        _ command: SPMLLBuild.Command,
        _: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        let outputFilePath: AbsolutePath
        let tool: WriteAuxiliaryFile!

        do {
            guard let buildDescription = self.context.buildDescription else {
                throw InternalError("unknown build description")
            }
            guard let _tool = buildDescription.writeCommands[command.name] else {
                throw StringError("command \(command.name) not registered")
            }
            tool = _tool

            guard let output = tool.outputs.first, output.kind == .file else {
                throw StringError("invalid output path")
            }
            outputFilePath = try AbsolutePath(validating: output.name)
        } catch {
            self.context.observabilityScope
                .emit(error: "failed to write auxiliary file: \(error.interpolationDescription)")
            return false
        }

        do {
            try self.context.fileSystem.writeIfChanged(path: outputFilePath, string: self.getFileContents(tool: tool))
            return true
        } catch {
            self.context.observabilityScope
                .emit(
                    error: "failed to write auxiliary file '\(outputFilePath.pathString)': \(error.interpolationDescription)"
                )
            return false
        }
    }

    func getFileContents(tool: WriteAuxiliaryFile) throws -> String {
        guard tool.inputs.first?.kind == .virtual,
              let generatedFileType = tool.inputs.first?.name.dropFirst().dropLast()
        else {
            throw StringError("invalid inputs")
        }

        for fileType in WriteAuxiliary.fileTypes {
            if generatedFileType == fileType.name {
                return try fileType.getFileContents(inputs: Array(tool.inputs.dropFirst()))
            }
        }

        throw InternalError("unhandled generated file type '\(generatedFileType)'")
    }
}

final class PackageStructureCommand: CustomLLBuildCommand {
    override func getSignature(_: SPMLLBuild.Command) -> [UInt8] {
        let encoder = JSONEncoder.makeWithDefaults()
        // Include build parameters and process env in the signature.
        var hash = Data()
        hash += try! encoder.encode(self.context.productsBuildParameters)
        hash += try! encoder.encode(self.context.toolsBuildParameters)
        hash += try! encoder.encode(Environment.current)
        return [UInt8](hash)
    }

    override func execute(
        _: SPMLLBuild.Command,
        _: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        self.context.packageStructureDelegate.packageStructureChanged()
    }
}

final class CopyCommand: CustomLLBuildCommand {
    override func execute(
        _ command: SPMLLBuild.Command,
        _: SPMLLBuild.BuildSystemCommandInterface
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
