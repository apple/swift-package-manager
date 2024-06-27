//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@testable import Basics
import _InternalTestSupport
import XCTest

import class Basics.AsyncProcess

final class CancellatorTests: XCTestCase {
    func testHappyCase() throws {
        let observability = ObservabilitySystem.makeForTesting()
        let cancellator = Cancellator(observabilityScope: observability.topScope)
        let worker = Worker(name: "test")
        cancellator.register(name: worker.name, handler: worker.cancel)

        let startSemaphore = DispatchSemaphore(value: 0)
        let finishSemaphore = DispatchSemaphore(value: 0)
        let finishDeadline = DispatchTime.now() + .seconds(5)
        DispatchQueue.sharedConcurrent.async() {
            startSemaphore.signal()
            defer { finishSemaphore.signal() }
            if case .timedOut = worker.work(deadline: finishDeadline) {
                XCTFail("worker \(worker.name) timed out")
            }
        }

        XCTAssertEqual(.success, startSemaphore.wait(timeout: .now() + .seconds(1)), "timeout starting tasks")

        let cancelled = cancellator._cancel(deadline: finishDeadline + .seconds(5))
        XCTAssertEqual(cancelled, 1)

        XCTAssertEqual(.success, finishSemaphore.wait(timeout: finishDeadline + .seconds(5)), "timeout finishing tasks")

        XCTAssertNoDiagnostics(observability.diagnostics)
    }

    func testTSCProcess() throws {
#if os(macOS)
        try withTemporaryDirectory { temporaryDirectory in
            let scriptPath = temporaryDirectory.appending("script")
            try localFileSystem.writeFileContents(
                scriptPath,
                string: """
                set -e

                echo "process started"
                sleep 10
                echo "exit normally"
                """
            )

            let observability = ObservabilitySystem.makeForTesting()
            let cancellator = Cancellator(observabilityScope: observability.topScope)

            // outputRedirection used to signal that the process started
            let startSemaphore = ProcessStartedSemaphore(term: "process started")
            let process = AsyncProcess(
                arguments: ["bash", scriptPath.pathString],
                outputRedirection: .stream(
                    stdout: startSemaphore.handleOutput,
                    stderr: startSemaphore.handleOutput
                )
            )

            let registrationKey = cancellator.register(process)
            XCTAssertNotNil(registrationKey)

            let finishSemaphore = DispatchSemaphore(value: 0)
            DispatchQueue.sharedConcurrent.async {
                defer { finishSemaphore.signal() }
                do {
                    try process.launch()
                    let result = try process.waitUntilExit()
                    print("process finished")
                    XCTAssertEqual(result.exitStatus, .signalled(signal: SIGINT))
                } catch {
                    XCTFail("failed launching process: \(error)")
                }
            }

            XCTAssertEqual(.success, startSemaphore.wait(timeout: .now() + .seconds(5)), "timeout starting tasks")
            print("process started")

            let canncelled = cancellator._cancel(deadline: .now() + .seconds(1))
            XCTAssertEqual(canncelled, 1)

            XCTAssertEqual(.success, finishSemaphore.wait(timeout: .now() + .seconds(5)), "timeout finishing tasks")

            XCTAssertNoDiagnostics(observability.diagnostics)
        }
#else
        try XCTSkipIf(true, "skipping on non-macOS, signal traps do not work well on docker")
#endif
    }

    func testTSCProcessForceKill() throws {
#if os(macOS)
        try withTemporaryDirectory { temporaryDirectory in
            let scriptPath = temporaryDirectory.appending("script")
            try localFileSystem.writeFileContents(
                scriptPath,
                string: """
                set -e

                trap_handler() {
                    echo "SIGINT trap"
                    sleep 10
                    echo "exit SIGINT trap"
                }

                echo "process started"
                trap trap_handler SIGINT
                echo "trap installed"

                sleep 10
                echo "exit normally"
                """
            )

            let observability = ObservabilitySystem.makeForTesting()
            let cancellator = Cancellator(observabilityScope: observability.topScope)

            // outputRedirection used to signal that the process SIGINT traps have been set up
            let startSemaphore = ProcessStartedSemaphore(term: "trap installed")
            let process = AsyncProcess(
                arguments: ["bash", scriptPath.pathString],
                outputRedirection: .stream(
                    stdout: startSemaphore.handleOutput,
                    stderr: startSemaphore.handleOutput
                )
            )
            let registrationKey = cancellator.register(process)
            XCTAssertNotNil(registrationKey)

            let finishSemaphore = DispatchSemaphore(value: 0)
            DispatchQueue.sharedConcurrent.async {
                defer { finishSemaphore.signal() }
                do {
                    try process.launch()
                    let result = try process.waitUntilExit()
                    print("process finished")
                    XCTAssertEqual(result.exitStatus, .signalled(signal: SIGKILL))
                } catch {
                    XCTFail("failed launching process: \(error)")
                }
            }

            XCTAssertEqual(.success, startSemaphore.wait(timeout: .now() + .seconds(5)), "timeout starting tasks")
            print("process started")

            let cancelled = cancellator._cancel(deadline: .now() + .seconds(1))
            XCTAssertEqual(cancelled, 1)

            XCTAssertEqual(.success, finishSemaphore.wait(timeout: .now() + .seconds(5)), "timeout finishing tasks")

            XCTAssertNoDiagnostics(observability.diagnostics)
        }
#else
        try XCTSkipIf(true, "skipping on non-macOS, signal traps do not work well on docker")
#endif
    }

    func testFoundationProcess() throws {
#if os(macOS)
        try withTemporaryDirectory { temporaryDirectory in
            let scriptPath = temporaryDirectory.appending("script")
            try localFileSystem.writeFileContents(
                scriptPath,
                string: """
                set -e

                echo "process started"

                sleep 10
                echo "exit normally"
                """
            )

            let observability = ObservabilitySystem.makeForTesting()
            let cancellator = Cancellator(observabilityScope: observability.topScope)

            // pipe used to signal that the process started
            let startSemaphore = ProcessStartedSemaphore(term: "process started")
            let process = Foundation.Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath.pathString]
            let stdoutPipe = Pipe()
            stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                startSemaphore.handleOutput([UInt8](fileHandle.availableData))
            }
            let stderrPipe = Pipe()
            stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                startSemaphore.handleOutput([UInt8](fileHandle.availableData))
            }
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let registrationKey = cancellator.register(process)
            XCTAssertNotNil(registrationKey)

            let finishSemaphore = DispatchSemaphore(value: 0)
            DispatchQueue.sharedConcurrent.async {
                defer { finishSemaphore.signal() }
                process.launch()
                process.waitUntilExit()
                print("process finished")
                XCTAssertEqual(process.terminationStatus, SIGINT)
            }

            XCTAssertEqual(.success, startSemaphore.wait(timeout: .now() + .seconds(5)), "timeout starting tasks")
            print("process started")

            let canncelled = cancellator._cancel(deadline: .now() + .seconds(1))
            XCTAssertEqual(canncelled, 1)

            XCTAssertEqual(.success, finishSemaphore.wait(timeout: .now() + .seconds(5)), "timeout finishing tasks")
            print(startSemaphore.output)
            
            XCTAssertNoDiagnostics(observability.diagnostics)
        }
#else
        try XCTSkipIf(true, "skipping on non-macOS, signal traps do not work well on docker")
#endif
    }

    func testFoundationProcessForceKill() throws {
#if os(macOS)
        try withTemporaryDirectory { temporaryDirectory in
            let scriptPath = temporaryDirectory.appending("script")
            try localFileSystem.writeFileContents(
                scriptPath,
                string: """
                set -e

                trap_handler() {
                    echo "SIGINT trap"
                    sleep 10
                    echo "exit SIGINT trap"
                }

                echo "process started"
                trap trap_handler SIGINT
                echo "trap installed"

                sleep 10
                echo "exit normally"
                """
            )

            let observability = ObservabilitySystem.makeForTesting()
            let cancellator = Cancellator(observabilityScope: observability.topScope)

            // pipe used to signal that the process SIGINT traps have been set up
            let startSemaphore = ProcessStartedSemaphore(term: "trap installed")
            let process = Foundation.Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath.pathString]
            let stdoutPipe = Pipe()
            stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                startSemaphore.handleOutput([UInt8](fileHandle.availableData))
            }
            let stderrPipe = Pipe()
            stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                startSemaphore.handleOutput([UInt8](fileHandle.availableData))
            }
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let registrationKey = cancellator.register(process)
            XCTAssertNotNil(registrationKey)

            let finishSemaphore = DispatchSemaphore(value: 0)
            DispatchQueue.sharedConcurrent.async {
                defer { finishSemaphore.signal() }
                process.launch()
                process.waitUntilExit()
                print("process finished")
                XCTAssertEqual(process.terminationStatus, SIGTERM)
            }

            XCTAssertEqual(.success, startSemaphore.wait(timeout: .now() + .seconds(5)), "timeout starting tasks")
            print("process started")
            print(startSemaphore.output)

            let cancelled = cancellator._cancel(deadline: .now() + .seconds(1))
            XCTAssertEqual(cancelled, 1)

            XCTAssertEqual(.success, finishSemaphore.wait(timeout: .now() + .seconds(5)), "timeout finishing tasks")

            XCTAssertNoDiagnostics(observability.diagnostics)
        }
#else
        try XCTSkipIf(true, "skipping on non-macOS, signal traps do not work well on docker")
#endif
    }

    func testConcurrency() throws {
        let observability = ObservabilitySystem.makeForTesting()
        let cancellator = Cancellator(observabilityScope: observability.topScope)

        let total = Concurrency.maxOperations
        let workers: [Worker] = (0 ..< total).map { index in
            let worker = Worker(name: "worker \(index)")
            cancellator.register(name: worker.name, handler: worker.cancel)
            return worker
        }

        let startGroup = DispatchGroup()
        let finishGroup = DispatchGroup()
        let finishDeadline = DispatchTime.now() + .seconds(5)
        let results = ThreadSafeKeyValueStore<String, DispatchTimeoutResult>()
        for worker in workers {
            startGroup.enter()
            DispatchQueue.sharedConcurrent.async(group: finishGroup) {
                startGroup.leave()
                results[worker.name] = worker.work(deadline: finishDeadline)
            }
        }

        XCTAssertEqual(.success, startGroup.wait(timeout: .now() + .seconds(1)), "timeout starting tasks")

        let cancelled = cancellator._cancel(deadline: finishDeadline + .seconds(5))
        XCTAssertEqual(cancelled, total)

        XCTAssertEqual(.success, finishGroup.wait(timeout: finishDeadline + .seconds(5)), "timeout finishing tasks")

        XCTAssertEqual(results.count, total)
        for (name, result) in results.get() {
            if case .timedOut = result {
                XCTFail("worker \(name) timed out")
            }
        }

        XCTAssertNoDiagnostics(observability.diagnostics)
    }

    func testTimeout() throws {
        struct Worker {
            func work()  {}

            func cancel() {
                Thread.sleep(forTimeInterval: 5)
            }
        }

        let observability = ObservabilitySystem.makeForTesting()
        let cancellator = Cancellator(observabilityScope: observability.topScope)
        let worker = Worker()
        cancellator.register(name: "test", handler: worker.cancel)

        let startSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.sharedConcurrent.async {
            startSemaphore.signal()
            worker.work()
        }

        XCTAssertEqual(.success, startSemaphore.wait(timeout: .now() + .seconds(1)), "timeout starting tasks")

        let cancelled = cancellator._cancel(deadline: .now() + .seconds(1))
        XCTAssertEqual(cancelled, 0)

        testDiagnostics(observability.diagnostics) { result in
            result.check(
                diagnostic: .contains("timeout waiting for cancellation"),
                severity: .warning
            )
        }
    }
}

fileprivate struct Worker {
    let name: String
    let semaphore = DispatchSemaphore(value: 0)

    init(name: String) {
        self.name = name
    }

    func work(deadline: DispatchTime) -> DispatchTimeoutResult {
        print("\(self.name) work")
        return self.semaphore.wait(timeout: deadline)
    }

    func cancel() {
        print("\(self.name) cancel")
        self.semaphore.signal()
    }
}

class ProcessStartedSemaphore {
    let term: String
    let underlying = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var trapped = false
    var output = ""

    init(term: String) {
        self.term = term
    }

    func handleOutput(_ bytes: [UInt8]) {
        self.lock.withLock {
            guard !self.trapped else {
                return
            }
            if let output = String(bytes: bytes, encoding: .utf8) {
                self.output += output
            }
            if self.output.contains(self.term) {
                self.trapped = true
                self.underlying.signal()
            }
        }
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        self.underlying.wait(timeout: timeout)
    }
}
