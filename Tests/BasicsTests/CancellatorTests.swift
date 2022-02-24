/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2022 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

@testable import Basics
import TSCBasic
import XCTest
import SPMTestSupport

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

    func testProcess() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let scriptPath = temporaryDirectory.appending(component: "script")
            try localFileSystem.writeFileContents(scriptPath) {
                """
                set -e

                echo "process started"
                sleep 10
                echo "exit normally"
                """
            }

            let observability = ObservabilitySystem.makeForTesting()
            let cancellator = Cancellator(observabilityScope: observability.topScope)

            // outputRedirection used to signal that the process SIGINT traps have been set up
            let startSemaphore = ProcessStartedSemaphore(term: "process started")
            let process = TSCBasic.Process(arguments: ["bash", scriptPath.pathString], outputRedirection: .stream(
                stdout: startSemaphore.handleOutput,
                stderr: startSemaphore.handleOutput
            ))

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
    }

    func testProcessForceKill() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let scriptPath = temporaryDirectory.appending(component: "script")
            try localFileSystem.writeFileContents(scriptPath) {
                """
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
            }

            let observability = ObservabilitySystem.makeForTesting()
            let cancellator = Cancellator(observabilityScope: observability.topScope)

            // outputRedirection used to signal that the process SIGINT traps have been set up
            let startSemaphore = ProcessStartedSemaphore(term: "trap installed")
            let process = TSCBasic.Process(arguments: ["bash", scriptPath.pathString], outputRedirection: .stream(
                stdout: startSemaphore.handleOutput,
                stderr: startSemaphore.handleOutput
            ))
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
                sleep(5)
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
    let lock = Lock()
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
