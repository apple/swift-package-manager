//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@testable import Basics
import _InternalTestSupport
import XCTest

// TODO: remove when transition to new diagnostics system is complete
typealias Diagnostic = Basics.Diagnostic

final class ObservabilitySystemTest: XCTestCase {
    func testScopes() throws {
        let collector = Collector()
        let observabilitySystem = ObservabilitySystem(collector)

        var metadata1 = ObservabilityMetadata()
        metadata1.testKey1 = UUID().uuidString
        metadata1.testKey2 = Int.random(in: Int.min..<Int.max)
        metadata1.testKey3 = Int.random(in: Int.min..<Int.max) > Int.max / 2

        let childScope1 = observabilitySystem.topScope.makeChildScope(description: "child 1", metadata: metadata1)
        childScope1.emit(error: "error 1")

        let emitter1 = childScope1.makeDiagnosticsEmitter()
        emitter1.emit(error: "error 1.5")

        testDiagnostics(collector.diagnostics) { result in
            let diagnostic1 = result.check(diagnostic: "error 1", severity: .error)
            XCTAssertEqual(diagnostic1?.metadata?.testKey1, metadata1.testKey1)
            XCTAssertEqual(diagnostic1?.metadata?.testKey2, metadata1.testKey2)
            XCTAssertEqual(diagnostic1?.metadata?.testKey3, metadata1.testKey3)

            let diagnostic1_5 = result.check(diagnostic: "error 1.5", severity: .error)
            XCTAssertEqual(diagnostic1_5?.metadata?.testKey1, metadata1.testKey1)
            XCTAssertEqual(diagnostic1_5?.metadata?.testKey2, metadata1.testKey2)
            XCTAssertEqual(diagnostic1_5?.metadata?.testKey3, metadata1.testKey3)
        }

        collector.clear()

        var metadata2 = ObservabilityMetadata()
        metadata2.testKey1 = UUID().uuidString
        metadata2.testKey2 = Int.random(in: Int.min..<Int.max)

        let mergedMetadata2 = metadata1.merging(metadata2)
        XCTAssertEqual(mergedMetadata2.testKey1, metadata2.testKey1)
        XCTAssertEqual(mergedMetadata2.testKey2, metadata2.testKey2)
        XCTAssertEqual(mergedMetadata2.testKey3, metadata1.testKey3)

        let childScope2 = childScope1.makeChildScope(description: "child 2", metadata: metadata2)
        childScope2.emit(error: "error 2")

        let emitter2 = childScope2.makeDiagnosticsEmitter()
        emitter2.emit(error: "error 2.5")

        testDiagnostics(collector.diagnostics) { result in
            let diagnostic2 = result.check(diagnostic: "error 2", severity: .error)!
            XCTAssertEqual(diagnostic2.metadata?.testKey1, mergedMetadata2.testKey1)
            XCTAssertEqual(diagnostic2.metadata?.testKey2, mergedMetadata2.testKey2)
            XCTAssertEqual(diagnostic2.metadata?.testKey3, mergedMetadata2.testKey3)

            let diagnostic2_5 = result.check(diagnostic: "error 2.5", severity: .error)
            XCTAssertEqual(diagnostic2_5?.metadata?.testKey1, mergedMetadata2.testKey1)
            XCTAssertEqual(diagnostic2_5?.metadata?.testKey2, mergedMetadata2.testKey2)
            XCTAssertEqual(diagnostic2_5?.metadata?.testKey3, mergedMetadata2.testKey3)
        }

        collector.clear()

        var metadata3 = ObservabilityMetadata()
        metadata3.testKey1 = UUID().uuidString

        let mergedMetadata3 = metadata1.merging(metadata2).merging(metadata3)
        XCTAssertEqual(mergedMetadata3.testKey1, metadata3.testKey1)
        XCTAssertEqual(mergedMetadata3.testKey2, metadata2.testKey2)
        XCTAssertEqual(mergedMetadata3.testKey3, metadata1.testKey3)

        let childScope3 = childScope2.makeChildScope(description: "child 3", metadata: metadata3)
        childScope3.emit(error: "error 3")

        var metadata3_5 = ObservabilityMetadata()
        metadata3_5.testKey1 = UUID().uuidString

        let mergedMetadata3_5 = metadata1.merging(metadata2).merging(metadata3).merging(metadata3_5)
        XCTAssertEqual(mergedMetadata3_5.testKey1, metadata3_5.testKey1)
        XCTAssertEqual(mergedMetadata3_5.testKey2, metadata2.testKey2)
        XCTAssertEqual(mergedMetadata3_5.testKey3, metadata1.testKey3)

        let emitter3 = childScope3.makeDiagnosticsEmitter(metadata: metadata3_5)
        emitter3.emit(error: "error 3.5")

        testDiagnostics(collector.diagnostics) { result in
            let diagnostic3 = result.check(diagnostic: "error 3", severity: .error)
            XCTAssertEqual(diagnostic3?.metadata?.testKey1, mergedMetadata3.testKey1)
            XCTAssertEqual(diagnostic3?.metadata?.testKey2, mergedMetadata3.testKey2)
            XCTAssertEqual(diagnostic3?.metadata?.testKey3, mergedMetadata3.testKey3)

            let diagnostic3_5 = result.check(diagnostic: "error 3.5", severity: .error)
            XCTAssertEqual(diagnostic3_5?.metadata?.testKey1, mergedMetadata3_5.testKey1)
            XCTAssertEqual(diagnostic3_5?.metadata?.testKey2, mergedMetadata3_5.testKey2)
            XCTAssertEqual(diagnostic3_5?.metadata?.testKey3, mergedMetadata3_5.testKey3)
        }
    }

    func testBasicDiagnostics() throws {
        let collector = Collector()
        let observabilitySystem = ObservabilitySystem(collector)

        var metadata = ObservabilityMetadata()
        metadata.testKey1 = UUID().uuidString

        let emitter = observabilitySystem.topScope.makeDiagnosticsEmitter(metadata: metadata)

        emitter.emit(error: "error")
        emitter.emit(.error("error 2"))
        emitter.emit(StringError("error 3"))
        emitter.emit(warning: "warning")
        emitter.emit(.warning("warning 2"))
        emitter.emit(info: "info")
        emitter.emit(.info("info 2"))
        emitter.emit(debug: "debug")
        emitter.emit(.debug("debug 2"))

        testDiagnostics(collector.diagnostics, problemsOnly: false) { result in
            do {
                let diagnostic = result.check(diagnostic: "error", severity: .error)
                XCTAssertEqual(diagnostic?.metadata?.testKey1, metadata.testKey1)
            }
            do {
                let diagnostic = result.check(diagnostic: "error 2", severity: .error)
                XCTAssertEqual(diagnostic?.metadata?.testKey1, metadata.testKey1)
            }
            do {
                let diagnostic = result.check(diagnostic: "error 3", severity: .error)
                XCTAssertEqual(diagnostic?.metadata?.testKey1, metadata.testKey1)
                XCTAssertEqual(diagnostic?.metadata?.underlyingError as? StringError, StringError("error 3"))
            }
            do {
                let diagnostic = result.check(diagnostic: "warning", severity: .warning)
                XCTAssertEqual(diagnostic?.metadata?.testKey1, metadata.testKey1)
            }
            do {
                let diagnostic = result.check(diagnostic: "warning 2", severity: .warning)
                XCTAssertEqual(diagnostic?.metadata?.testKey1, metadata.testKey1)
            }
            do {
                let diagnostic = result.check(diagnostic: "info", severity: .info)
                XCTAssertEqual(diagnostic?.metadata?.testKey1, metadata.testKey1)
            }
            do {
                let diagnostic = result.check(diagnostic: "info 2", severity: .info)
                XCTAssertEqual(diagnostic?.metadata?.testKey1, metadata.testKey1)
            }
            do {
                let diagnostic = result.check(diagnostic: "debug", severity: .debug)
                XCTAssertEqual(diagnostic?.metadata?.testKey1, metadata.testKey1)
            }
            do {
                let diagnostic = result.check(diagnostic: "debug 2", severity: .debug)
                XCTAssertEqual(diagnostic?.metadata?.testKey1, metadata.testKey1)
            }
        }
    }

    func testDiagnosticsErrorDescription() throws {
        let collector = Collector()
        let observabilitySystem = ObservabilitySystem(collector)

        observabilitySystem.topScope.emit(error: "error")
        observabilitySystem.topScope.emit(.error("error 2"))
        observabilitySystem.topScope.emit(MyError(description: "error 3"))
        observabilitySystem.topScope.emit(MyDescribedError(description: "error 4"))
        observabilitySystem.topScope.emit(MyLocalizedError(errorDescription: "error 5"))

        testDiagnostics(collector.diagnostics, problemsOnly: false) { result in
            do {
                let diagnostic = result.check(diagnostic: "error", severity: .error)
                XCTAssertNil(diagnostic?.metadata?.underlyingError)
            }
            do {
                let diagnostic = result.check(diagnostic: "error 2", severity: .error)
                XCTAssertNil(diagnostic?.metadata?.underlyingError)
            }
            do {
                let diagnostic = result.check(diagnostic: "MyError(description: \"error 3\")", severity: .error)
                XCTAssertEqual(diagnostic?.metadata?.underlyingError as? MyError, MyError(description: "error 3"))
            }
            do {
                let diagnostic = result.check(diagnostic: "error 4", severity: .error)
                XCTAssertEqual(diagnostic?.metadata?.underlyingError as? MyDescribedError, MyDescribedError(description: "error 4"))
            }
            do {
                let diagnostic = result.check(diagnostic: "error 5", severity: .error)
                XCTAssertEqual(diagnostic?.metadata?.underlyingError as? MyLocalizedError, MyLocalizedError(errorDescription: "error 5"))
            }
        }

        struct MyError: Error, Equatable {
            let description: String

        }

        struct MyDescribedError: Error, CustomStringConvertible, Equatable {
            let description: String
        }

        struct MyLocalizedError: LocalizedError, Equatable {
            let errorDescription: String?
        }
    }

    func testDiagnosticsMetadataMerge() throws {
        let collector = Collector()
        let observabilitySystem = ObservabilitySystem(collector)

        var scopeMetadata = ObservabilityMetadata()
        scopeMetadata.testKey1 = UUID().uuidString
        scopeMetadata.testKey2 = Int.random(in: Int.min..<Int.max)
        scopeMetadata.testKey3 = Int.random(in: Int.min..<Int.max) > Int.max / 2

        let scope = observabilitySystem.topScope.makeChildScope(description: "child scope", metadata: scopeMetadata)

        var emitterMetadata = ObservabilityMetadata()
        emitterMetadata.testKey1 = UUID().uuidString
        emitterMetadata.testKey2 = Int.random(in: Int.min..<Int.max)

        let emitterMergedMetadata = scopeMetadata.merging(emitterMetadata)
        XCTAssertEqual(emitterMergedMetadata.testKey1, emitterMetadata.testKey1)
        XCTAssertEqual(emitterMergedMetadata.testKey2, emitterMetadata.testKey2)
        XCTAssertEqual(emitterMergedMetadata.testKey3, scopeMetadata.testKey3)

        let emitter = scope.makeDiagnosticsEmitter(metadata: emitterMetadata)
        emitter.emit(error: "error")

        var diagnosticMetadata = ObservabilityMetadata()
        diagnosticMetadata.testKey1 = UUID().uuidString

        let diagnosticMergedMetadata = scopeMetadata.merging(emitterMetadata).merging(diagnosticMetadata)
        XCTAssertEqual(diagnosticMergedMetadata.testKey1, diagnosticMetadata.testKey1)
        XCTAssertEqual(diagnosticMergedMetadata.testKey2, emitterMetadata.testKey2)
        XCTAssertEqual(diagnosticMergedMetadata.testKey3, scopeMetadata.testKey3)

        emitter.emit(warning: "warning", metadata: diagnosticMetadata)

        testDiagnostics(collector.diagnostics) { result in
            do {
                let diagnostic = result.check(diagnostic: "error", severity: .error)
                XCTAssertEqual(diagnostic?.metadata?.testKey1, emitterMergedMetadata.testKey1)
                XCTAssertEqual(diagnostic?.metadata?.testKey2, emitterMergedMetadata.testKey2)
                XCTAssertEqual(diagnostic?.metadata?.testKey3, emitterMergedMetadata.testKey3)
            }
            do {
                let diagnostic = result.check(diagnostic: "warning", severity: .warning)
                XCTAssertEqual(diagnostic?.metadata?.testKey1, diagnosticMergedMetadata.testKey1)
                XCTAssertEqual(diagnostic?.metadata?.testKey2, diagnosticMergedMetadata.testKey2)
                XCTAssertEqual(diagnostic?.metadata?.testKey3, diagnosticMergedMetadata.testKey3)
            }
        }
    }

    struct Collector: ObservabilityHandlerProvider, DiagnosticsHandler {
        private let _diagnostics = ThreadSafeArrayStore<Diagnostic>()

        var diagnosticsHandler: DiagnosticsHandler { self }

        var diagnostics: [Diagnostic] {
            self._diagnostics.get()
        }

        func clear() {
            self._diagnostics.clear()
        }

        func handleDiagnostic(scope: ObservabilityScope, diagnostic: Diagnostic) {
            self._diagnostics.append(diagnostic)
        }
    }
}

extension ObservabilityMetadata {
    public var testKey1: String? {
        get {
            self[TestKey1.self]
        }
        set {
            self[TestKey1.self] = newValue
        }
    }

    public var testKey2: Int? {
        get {
            self[TestKey2.self]
        }
        set {
            self[TestKey2.self] = newValue
        }
    }

    public var testKey3: Bool? {
        get {
            self[TestKey3.self]
        }
        set {
            self[TestKey3.self] = newValue
        }
    }

    enum TestKey1: Key {
        typealias Value = String
    }
    enum TestKey2: Key {
        typealias Value = Int
    }
    enum TestKey3: Key {
        typealias Value = Bool
    }
}
