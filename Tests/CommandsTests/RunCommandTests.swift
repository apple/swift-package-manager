//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Commands
import _InternalTestSupport
import XCTest

import class Basics.AsyncProcess

final class RunCommandTests: CommandsTestCase {
    private func execute(
        _ args: [String] = [],
        packagePath: AbsolutePath? = nil
    ) async throws -> (stdout: String, stderr: String) {
        return try await SwiftPM.Run.execute(args, packagePath: packagePath)
    }

    func testUsage() async throws {
        let stdout = try await execute(["-help"]).stdout
        XCTAssert(stdout.contains("USAGE: swift run <options>") || stdout.contains("USAGE: swift run [<options>]"), "got stdout:\n" + stdout)
    }

    func testSeeAlso() async throws {
        let stdout = try await execute(["--help"]).stdout
        XCTAssert(stdout.contains("SEE ALSO: swift build, swift package, swift test"), "got stdout:\n" + stdout)
    }

    func testVersion() async throws {
        let stdout = try await execute(["--version"]).stdout
        XCTAssert(stdout.contains("Swift Package Manager"), "got stdout:\n" + stdout)
    }

    func testUnknownProductAndArgumentPassing() async throws {
        try await fixture(name: "Miscellaneous/EchoExecutable") { fixturePath in
            let (stdout, stderr) = try await SwiftPM.Run.execute(
                ["secho", "1", "--hello", "world"], packagePath: fixturePath)

            // We only expect tool's output on the stdout stream.
            XCTAssertMatch(stdout, .contains("""
                "1" "--hello" "world"
                """))

            // swift-build-tool output should go to stderr.
            XCTAssertMatch(stderr, .regex("Compiling"))
            XCTAssertMatch(stderr, .contains("Linking"))

            await XCTAssertThrowsCommandExecutionError(try await execute(["unknown"], packagePath: fixturePath)) { error in
                XCTAssertMatch(error.stderr, .contains("error: no executable product named 'unknown'"))
            }
        }
    }

    func testMultipleExecutableAndExplicitExecutable() async throws {
        try await fixture(name: "Miscellaneous/MultipleExecutables") { fixturePath in
            await XCTAssertThrowsCommandExecutionError(try await execute(packagePath: fixturePath)) { error in
                XCTAssertMatch(error.stderr, .contains("error: multiple executable products available: exec1, exec2"))
            }
            
            var (runOutput, _) = try await execute(["exec1"], packagePath: fixturePath)
            XCTAssertMatch(runOutput, .contains("1"))

            (runOutput, _) = try await execute(["exec2"], packagePath: fixturePath)
            XCTAssertMatch(runOutput, .contains("2"))
        }
    }

    func testUnreachableExecutable() async throws {
        try await fixture(name: "Miscellaneous/UnreachableTargets") { fixturePath in
            let (output, _) = try await execute(["bexec"], packagePath: fixturePath.appending("A"))
            let outputLines = output.split(whereSeparator: { $0.isNewline })
            XCTAssertMatch(String(outputLines[0]), .contains("BTarget2"))
        }
    }

    func testFileDeprecation() async throws {
        try await fixture(name: "Miscellaneous/EchoExecutable") { fixturePath in
            let filePath = AbsolutePath(fixturePath, "Sources/secho/main.swift").pathString
            let cwd = localFileSystem.currentWorkingDirectory!
            let (stdout, stderr) = try await execute([filePath, "1", "2"], packagePath: fixturePath)
            XCTAssertMatch(stdout, .contains(#""\#(cwd)" "1" "2""#))
            XCTAssertMatch(stderr, .contains("warning: 'swift run file.swift' command to interpret swift files is deprecated; use 'swift file.swift' instead"))
        }
    }

    func testMutualExclusiveFlags() async throws {
        try await fixture(name: "Miscellaneous/EchoExecutable") { fixturePath in
            await XCTAssertThrowsCommandExecutionError(try await execute(["--build-tests", "--skip-build"], packagePath: fixturePath)) { error in
                XCTAssertMatch(error.stderr, .contains("error: '--build-tests' and '--skip-build' are mutually exclusive"))
            }
        }
    }

    func testSwiftRunSIGINT() throws {
        try XCTSkipIfCI()
        try fixture(name: "Miscellaneous/SwiftRun") { fixturePath in
            let mainFilePath = fixturePath.appending("main.swift")
            try localFileSystem.removeFileTree(mainFilePath)
            try localFileSystem.writeFileContents(
                mainFilePath,
                string: """
                import Foundation

                print("sleeping")
                fflush(stdout)

                sleep(10)
                print("done")
                """
            )

            let sync = DispatchGroup()
            let outputHandler = OutputHandler(sync: sync)

            var environment = Environment.current
            environment["SWIFTPM_EXEC_NAME"] = "swift-run"
            let process = AsyncProcess(
                arguments: [SwiftPM.Run.xctestBinaryPath.pathString, "--package-path", fixturePath.pathString],
                environment: environment,
                outputRedirection: .stream(stdout: outputHandler.handle(bytes:), stderr: outputHandler.handle(bytes:))
            )

            sync.enter()
            try process.launch()

            // wait for the process to start
            if case .timedOut = sync.wait(timeout: .now() + 60) {
                return XCTFail("timeout waiting for process to start")
            }

            // interrupt the process
            print("interrupting")
            process.signal(SIGINT)

            // check for interrupt result
            let result = try process.waitUntilExit()
#if os(Windows)
            XCTAssertEqual(result.exitStatus, .abnormal(exception: 2))
#else
            XCTAssertEqual(result.exitStatus, .signalled(signal: SIGINT))
#endif
        }

        class OutputHandler {
            let sync: DispatchGroup
            var state = State.idle
            let lock = NSLock()

            init(sync: DispatchGroup) {
                self.sync = sync
            }

            func handle(bytes: [UInt8]) {
                guard let output = String(bytes: bytes, encoding: .utf8) else {
                    return
                }
                print(output, terminator: "")
                self.lock.withLock {
                    switch self.state {
                    case .idle:
                        self.state = processOutput(output)
                    case .buffering(let buffer):
                        let newBuffer = buffer + output
                        self.state = processOutput(newBuffer)
                    case .done:
                        break //noop
                    }
                }

                func processOutput(_ output: String) -> State {
                    if output.contains("sleeping") {
                        self.sync.leave()
                        return .done
                    } else {
                        return .buffering(output)
                    }
                }
            }

            enum State {
                case idle
                case buffering(String)
                case done
            }
        }
    }

}
