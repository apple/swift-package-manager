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

import Dispatch

import class Foundation.JSONDecoder

private let defaultImports = ["Swift", "SwiftOnoneSupport", "_Concurrency",
                              "_StringProcessing", "_SwiftConcurrencyShims"]

private struct Imports: Decodable {
    let imports: [String]
}

package protocol ImportScanner {
    func scanImports(_ filePathToScan: AbsolutePath) async throws -> [String]
}

public struct SwiftcImportScanner: ImportScanner {
    private let swiftCompilerEnvironment: Environment
    private let swiftCompilerFlags: [String]
    private let swiftCompilerPath: AbsolutePath

    package init(
        swiftCompilerEnvironment: Environment,
        swiftCompilerFlags: [String],
        swiftCompilerPath: AbsolutePath
    ) {
        self.swiftCompilerEnvironment = swiftCompilerEnvironment
        self.swiftCompilerFlags = swiftCompilerFlags
        self.swiftCompilerPath = swiftCompilerPath
    }

    public func scanImports(_ filePathToScan: AbsolutePath) async throws -> [String] {
        let cmd = [swiftCompilerPath.pathString,
                   filePathToScan.pathString,
                   "-scan-dependencies", "-Xfrontend", "-import-prescan"] + self.swiftCompilerFlags

        let result = try await AsyncProcess.popen(arguments: cmd, environment: self.swiftCompilerEnvironment)

        let stdout = try result.utf8Output()
        return try JSONDecoder.makeWithDefaults().decode(Imports.self, from: stdout).imports
            .filter { !defaultImports.contains($0) }
    }
}
