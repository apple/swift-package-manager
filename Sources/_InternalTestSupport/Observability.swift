//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import func XCTest.XCTAssertEqual
import func XCTest.XCTFail

import struct TSCBasic.StringError

import TSCTestSupport

extension ObservabilitySystem {
    public static func makeForTesting(verbose: Bool = true) -> TestingObservability {
        let collector = TestingObservability.Collector(verbose: verbose)
        let observabilitySystem = ObservabilitySystem(collector)
        return TestingObservability(collector: collector, topScope: observabilitySystem.topScope)
    }
}

public struct TestingObservability {
    private let collector: Collector
    public let topScope: ObservabilityScope

    fileprivate init(collector: Collector, topScope: ObservabilityScope) {
        self.collector = collector
        self.topScope = topScope
    }

    public var diagnostics: [Basics.Diagnostic] {
        self.collector.diagnostics.get()
    }

    public var errors: [Basics.Diagnostic] {
        self.diagnostics.filter { $0.severity == .error }
    }

    public var warnings: [Basics.Diagnostic] {
        self.diagnostics.filter { $0.severity == .warning }
    }

    public var hasErrorDiagnostics: Bool {
        self.collector.hasErrors
    }

    public var hasWarningDiagnostics: Bool {
        self.collector.hasWarnings
    }

    final class Collector: ObservabilityHandlerProvider, DiagnosticsHandler, CustomStringConvertible {
        var diagnosticsHandler: DiagnosticsHandler { self }

        let diagnostics: ThreadSafeArrayStore<Basics.Diagnostic>
        private let verbose: Bool

        init(verbose: Bool) {
            self.verbose = verbose
            self.diagnostics = .init()
        }

        // TODO: do something useful with scope
        func handleDiagnostic(scope: ObservabilityScope, diagnostic: Basics.Diagnostic) {
            if self.verbose {
                print(diagnostic.description)
            }
            self.diagnostics.append(diagnostic)
        }

        var hasErrors: Bool {
            self.diagnostics.get().hasErrors
        }

        var hasWarnings: Bool {
            self.diagnostics.get().hasWarnings
        }

        var description: String {
            let diagnostics = self.diagnostics.get()
            return "\(diagnostics)"
        }
    }
}

public func XCTAssertNoDiagnostics(
    _ diagnostics: [Basics.Diagnostic],
    problemsOnly: Bool = true,
    file: StaticString = #file,
    line: UInt = #line
) {
    let diagnostics = problemsOnly ? diagnostics.filter { $0.severity >= .warning } : diagnostics
    if diagnostics.isEmpty { return }
    let description = diagnostics.map { "- " + $0.description }.joined(separator: "\n")
    XCTFail("Found unexpected diagnostics: \n\(description)", file: file, line: line)
}

public func testDiagnostics(
    _ diagnostics: [Basics.Diagnostic],
    problemsOnly: Bool = true,
    file: StaticString = #file,
    line: UInt = #line,
    handler: (DiagnosticsTestResult) throws -> Void
) {
    testDiagnostics(
        diagnostics,
        minSeverity: problemsOnly ? .warning : .debug,
        file: file,
        line: line,
        handler: handler
    )
}

public func testDiagnostics(
    _ diagnostics: [Basics.Diagnostic],
    minSeverity: Basics.Diagnostic.Severity,
    file: StaticString = #file,
    line: UInt = #line,
    handler: (DiagnosticsTestResult) throws -> Void
) {
    let diagnostics = diagnostics.filter { $0.severity >= minSeverity }
    let testResult = DiagnosticsTestResult(diagnostics)

    do {
        try handler(testResult)
    } catch {
        XCTFail("error \(String(describing: error))", file: file, line: line)
    }

    if !testResult.uncheckedDiagnostics.isEmpty {
        XCTFail("unchecked diagnostics \(testResult.uncheckedDiagnostics)", file: file, line: line)
    }
}

public func testPartialDiagnostics(
    _ diagnostics: [Basics.Diagnostic],
    minSeverity: Basics.Diagnostic.Severity,
    file: StaticString = #file,
    line: UInt = #line,
    handler: (DiagnosticsTestResult) throws -> Void
) {
    let diagnostics = diagnostics.filter { $0.severity >= minSeverity }
    let testResult = DiagnosticsTestResult(diagnostics)

    do {
        try handler(testResult)
    } catch {
        XCTFail("error \(String(describing: error))", file: file, line: line)
    }
}

/// Helper to check diagnostics in the engine.
public class DiagnosticsTestResult {
    fileprivate var uncheckedDiagnostics: [Basics.Diagnostic]

    init(_ diagnostics: [Basics.Diagnostic]) {
        self.uncheckedDiagnostics = diagnostics
    }

    @discardableResult
    public func check(
        diagnostic message: StringPattern,
        severity: Basics.Diagnostic.Severity,
        //metadata: ObservabilityMetadata? = .none,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Basics.Diagnostic? {
        guard !self.uncheckedDiagnostics.isEmpty else {
            XCTFail("No diagnostics left to check", file: file, line: line)
            return nil
        }

        let diagnostic: Basics.Diagnostic = self.uncheckedDiagnostics.removeFirst()

        XCTAssertMatch(diagnostic.message, message, file: file, line: line)
        XCTAssertEqual(diagnostic.severity, severity, file: file, line: line)
        // FIXME: (diagnostics) compare complete metadata when legacy bridge is removed
        //XCTAssertEqual(diagnostic.metadata, metadata, file: file, line: line)
        //XCTAssertEqual(diagnostic.metadata?.droppingLegacyKeys(), metadata?.droppingLegacyKeys(), file: file, line: line)

        return diagnostic
    }

    @discardableResult
    public func checkUnordered(
        diagnostic diagnosticPattern: StringPattern,
        severity: Basics.Diagnostic.Severity,
        //metadata: ObservabilityMetadata? = .none,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Basics.Diagnostic? {
        guard !self.uncheckedDiagnostics.isEmpty else {
            XCTFail("No diagnostics left to check", file: file, line: line)
            return nil
        }

        let matching = self.uncheckedDiagnostics.indices
            .filter { diagnosticPattern ~= self.uncheckedDiagnostics[$0].message }
        if matching.isEmpty {
            XCTFail("No diagnostics match \(diagnosticPattern)", file: file, line: line)
            return nil
        } else if matching.count == 1, let index = matching.first {
            let diagnostic = self.uncheckedDiagnostics[index]
            XCTAssertEqual(diagnostic.severity, severity, file: file, line: line)
            // FIXME: (diagnostics) compare complete metadata when legacy bridge is removed
            //XCTAssertEqual(diagnostic.metadata, metadata, file: file, line: line)
            //XCTAssertEqual(diagnostic.metadata?.droppingLegacyKeys(), metadata?.droppingLegacyKeys(), file: file, line: line)
            self.uncheckedDiagnostics.remove(at: index)
            return diagnostic
        // FIXME: (diagnostics) compare complete metadata when legacy bridge is removed
        } else if let index = self.uncheckedDiagnostics.firstIndex(where: { diagnostic in diagnostic.severity == severity /*&& diagnostic.metadata == metadata*/}) {
        //} else if let index = self.uncheckedDiagnostics.firstIndex(where: { diagnostic in diagnostic.severity == severity && diagnostic.metadata?.droppingLegacyKeys() == metadata?.droppingLegacyKeys()}) {
            let diagnostic = self.uncheckedDiagnostics[index]
            self.uncheckedDiagnostics.remove(at: index)
            return diagnostic
        } else {
            return nil
        }
    }
}
