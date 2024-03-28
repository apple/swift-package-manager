//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

struct TestEventRecord: Codable {
    let caseFailure: TestCaseFailureRecord?
    let suiteFailure: TestSuiteFailureRecord?

    let bundleEvent: TestBundleEventRecord?
    let suiteEvent: TestSuiteEventRecord?
    let caseEvent: TestCaseEventRecord?

    init(
        caseFailure: TestCaseFailureRecord? = nil,
        suiteFailure: TestSuiteFailureRecord? = nil,
        bundleEvent: TestBundleEventRecord? = nil,
        suiteEvent: TestSuiteEventRecord? = nil,
        caseEvent: TestCaseEventRecord? = nil
    ) {
        self.caseFailure = caseFailure
        self.suiteFailure = suiteFailure
        self.bundleEvent = bundleEvent
        self.suiteEvent = suiteEvent
        self.caseEvent = caseEvent
    }
}

// MARK: - Records

struct TestAttachment: Codable {
    let name: String?
    // TODO: Handle `userInfo: [AnyHashable : Any]?`
    let uniformTypeIdentifier: String
    let payload: Data?
}

struct TestBundleEventRecord: Codable {
    let bundle: TestBundle
    let event: TestEvent
}

struct TestCaseEventRecord: Codable {
    let testCase: TestCase
    let event: TestEvent
}

struct TestCaseFailureRecord: Codable, CustomStringConvertible {
    let testCase: TestCase
    let issue: TestIssue
    let failureKind: TestFailureKind

    var description: String {
        return "\(issue.sourceCodeContext.description)\(testCase) \(issue.compactDescription)"
    }

    func description(with knownLocation: String) -> String {
        return "\(issue.sourceCodeContext.description(with: knownLocation))\(testCase) \(issue.compactDescription)"
    }
}

struct TestSuiteEventRecord: Codable {
    let suite: TestSuiteRecord
    let event: TestEvent
}

struct TestSuiteFailureRecord: Codable {
    let suite: TestSuiteRecord
    let issue: TestIssue
    let failureKind: TestFailureKind
}

// MARK: Primitives

struct TestBundle: Codable {
    let bundleIdentifier: String?
    let bundlePath: String
}

struct TestCase: Codable, CustomStringConvertible {
    let name: String

    var description: String {
        return name
    }
}

struct TestErrorInfo: Codable {
    let description: String
    let type: String
}

enum TestEvent: Codable {
    case start
    case finish
}

enum TestFailureKind: Codable, Equatable {
    case unexpected
    case expected(failureReason: String?)

    var isExpected: Bool {
        switch self {
        case .expected: return true
        case .unexpected: return false
        }
    }
}

struct TestIssue: Codable {
    let type: TestIssueType
    let compactDescription: String
    let detailedDescription: String?
    let associatedError: TestErrorInfo?
    let sourceCodeContext: TestSourceCodeContext
    let attachments: [TestAttachment]
}

enum TestIssueType: Codable {
    case assertionFailure
    case performanceRegression
    case system
    case thrownError
    case uncaughtException
    case unmatchedExpectedFailure
    case unknown
}

struct TestLocation: Codable, CustomStringConvertible {
    let file: String
    let line: Int

    var description: String {
        return "\(file):\(line) "
    }

    func description(with knownLocation: String) -> String {
        var file = self.file
        ["file:/", knownLocation].forEach {
            if file.hasPrefix($0) {
                file = String(file.dropFirst($0.count + 1))
            }
        }
        return "\(file):\(line) "
    }
}

struct TestSourceCodeContext: Codable, CustomStringConvertible {
    let callStack: [TestSourceCodeFrame]
    let location: TestLocation?

    var description: String {
        return location?.description ?? ""
    }

    func description(with knownLocation: String) -> String {
        return location?.description(with: knownLocation) ?? ""
    }
}

struct TestSourceCodeFrame: Codable {
    let address: UInt64
    let symbolInfo: TestSourceCodeSymbolInfo?
    let symbolicationError: TestErrorInfo?
}

struct TestSourceCodeSymbolInfo: Codable {
    let imageName: String
    let symbolName: String
    let location: TestLocation?
}

struct TestSuiteRecord: Codable {
    let name: String
}

// MARK: XCTest compatibility

extension TestIssue {
    init(description: String, inFile filePath: String?, atLine lineNumber: Int) {
        let location: TestLocation?
        if let filePath = filePath {
            location = .init(file: filePath, line: lineNumber)
        } else {
            location = nil
        }
        self.init(type: .assertionFailure, compactDescription: description, detailedDescription: description, associatedError: nil, sourceCodeContext: .init(callStack: [], location: location), attachments: [])
    }
}

#if false // This is just here for pre-flighting the code generation done in `SwiftTargetBuildDescription`.
import XCTest

#if canImport(Darwin) // XCTAttachment is unavailable in swift-corelibs-xctest.
extension TestAttachment {
    init(_ attachment: XCTAttachment) {
        self.init(
            name: attachment.name,
            uniformTypeIdentifier: attachment.uniformTypeIdentifier,
            payload: attachment.value(forKey: "payload") as? Data
        )
    }
}
#endif

extension TestBundle {
    init(_ testBundle: Bundle) {
        self.init(
            bundleIdentifier: testBundle.bundleIdentifier,
            bundlePath: testBundle.bundlePath
        )
    }
}

extension TestCase {
    init(_ testCase: XCTestCase) {
        self.init(name: testCase.name)
    }
}

extension TestErrorInfo {
    init(_ error: Swift.Error) {
        self.init(description: "\(error)", type: "\(Swift.type(of: error))")
    }
}

#if canImport(Darwin) // XCTIssue is unavailable in swift-corelibs-xctest.
extension TestIssue {
    init(_ issue: XCTIssue) {
        self.init(
            type: .init(defaultBuildParameters: issue.type),
            compactDescription: issue.compactDescription,
            detailedDescription: issue.detailedDescription,
            associatedError: issue.associatedError.map { .init(defaultBuildParameters: $0) },
            sourceCodeContext: .init(defaultBuildParameters: issue.sourceCodeContext),
            attachments: issue.attachments.map { .init(defaultBuildParameters: $0) }
        )
    }
}

extension TestIssueType {
    init(_ type: XCTIssue.IssueType) {
        switch type {
        case .assertionFailure: self = .assertionFailure
        case .thrownError: self = .thrownError
        case .uncaughtException: self = .uncaughtException
        case .performanceRegression: self = .performanceRegression
        case .system: self = .system
        case .unmatchedExpectedFailure: self = .unmatchedExpectedFailure
        @unknown default: self = .unknown
        }
    }
}
#endif

#if canImport(Darwin) // XCTSourceCodeLocation/XCTSourceCodeContext/XCTSourceCodeFrame/XCTSourceCodeSymbolInfo is unavailable in swift-corelibs-xctest.
extension TestLocation {
    init(_ location: XCTSourceCodeLocation) {
        self.init(
            file: location.fileURL.absoluteString,
            line: location.lineNumber
        )
    }
}

extension TestSourceCodeContext {
    init(_ context: XCTSourceCodeContext) {
        self.init(
            callStack: context.callStack.map { .init(defaultBuildParameters: $0) },
            location: context.location.map { .init(defaultBuildParameters: $0) }
        )
    }
}

extension TestSourceCodeFrame {
    init(_ frame: XCTSourceCodeFrame) {
        self.init(
            address: frame.address,
            symbolInfo: (try? frame.symbolInfo()).map { .init(defaultBuildParameters: $0) },
            symbolicationError: frame.symbolicationError.map { .init(defaultBuildParameters: $0) }
        )
    }
}

extension TestSourceCodeSymbolInfo {
    init(_ symbolInfo: XCTSourceCodeSymbolInfo) {
        self.init(
            imageName: symbolInfo.imageName,
            symbolName: symbolInfo.symbolName,
            location: symbolInfo.location.map { .init(defaultBuildParameters: $0) }
        )
    }
}
#endif

extension TestSuiteRecord {
    init(_ testSuite: XCTestSuite) {
        self.init(name: testSuite.name)
    }
}
#endif
