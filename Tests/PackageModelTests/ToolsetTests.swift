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

@testable import Basics
@testable import PackageModel
import _InternalTestSupport
import XCTest

import class TSCBasic.InMemoryFileSystem

private let usrBinTools = Dictionary(uniqueKeysWithValues: Toolset.KnownTool.allCases.map {
    ($0, try! AbsolutePath(validating: "/usr/bin/\($0.rawValue)"))
})

private let cCompilerOptions = ["-fopenmp"]
private let newCCompilerOptions = ["-pedantic"]
private let cxxCompilerOptions = ["-nostdinc++"]

private let compilersNoRoot = (
    path: try! AbsolutePath(validating: "/tools/compilersNoRoot.json"),
    json: #"""
    {
        "schemaVersion": "1.0",
        "swiftCompiler": { "path": "\#(usrBinTools[.swiftCompiler]!)" },
        "cCompiler": { "path": "\#(usrBinTools[.cCompiler]!)", "extraCLIOptions": \#(cCompilerOptions) },
        "cxxCompiler": { "path": "\#(usrBinTools[.cxxCompiler]!)", "extraCLIOptions": \#(cxxCompilerOptions) },
    }
    """# as SerializedJSON
)

private let noValidToolsNoRoot = (
    path: try! AbsolutePath(validating: "/tools/noValidToolsNoRoot.json"),
    json: #"""
    {
        "schemaVersion": "1.0",
        "cCompiler": {}
    }
    """# as SerializedJSON
)

private let unknownToolsNoRoot = (
    path: try! AbsolutePath(validating: "/tools/unknownToolsNoRoot.json"),
    json: #"""
    {
        "schemaVersion": "1.0",
        "foo": {},
        "bar": {}
    }
    """# as SerializedJSON
)

private let otherToolsNoRoot = (
    path: try! AbsolutePath(validating: "/tools/otherToolsNoRoot.json"),
    json: #"""
    {
        "schemaVersion": "1.0",
        "librarian": { "path": "\#(usrBinTools[.librarian]!)" },
        "linker": { "path": "\#(usrBinTools[.linker]!)" },
        "debugger": { "path": "\#(usrBinTools[.debugger]!)" }
    }
    """# as SerializedJSON
)

private let someToolsWithRoot = (
    path: try! AbsolutePath(validating: "/tools/someToolsWithRoot.json"),
    json: #"""
    {
        "schemaVersion": "1.0",
        "rootPath": "/custom",
        "cCompiler": { "extraCLIOptions": \#(newCCompilerOptions) },
        "linker": { "path": "ld" },
        "librarian": { "path": "llvm-ar" },
        "debugger": { "path": "\#(usrBinTools[.debugger]!)" }
    }
    """# as SerializedJSON
)

private let someToolsWithRelativeRoot = (
    path: try! AbsolutePath(validating: "/tools/someToolsWithRelativeRoot.json"),
    json: #"""
    {
        "schemaVersion": "1.0",
        "rootPath": "relative/custom",
        "cCompiler": { "extraCLIOptions": \#(newCCompilerOptions) }
    }
    """# as SerializedJSON
)

final class ToolsetTests: XCTestCase {
    func testToolset() throws {
        let fileSystem = InMemoryFileSystem()
        try fileSystem.createDirectory(AbsolutePath(validating: "/tools"))
        for testFile in [compilersNoRoot, noValidToolsNoRoot, unknownToolsNoRoot, otherToolsNoRoot, someToolsWithRoot, someToolsWithRelativeRoot] {
            try fileSystem.writeFileContents(testFile.path, string: testFile.json.underlying)
        }
        let observability = ObservabilitySystem.makeForTesting()

        let compilersToolset = try Toolset(from: compilersNoRoot.path, at: fileSystem, observability.topScope)

        XCTAssertEqual(
            compilersToolset.knownTools[.swiftCompiler],
            Toolset.ToolProperties(path: usrBinTools[.swiftCompiler]!)
        )
        XCTAssertEqual(
            compilersToolset.knownTools[.cCompiler],
            Toolset.ToolProperties(path: usrBinTools[.cCompiler]!, extraCLIOptions: cCompilerOptions)
        )
        XCTAssertEqual(
            compilersToolset.knownTools[.cxxCompiler],
            Toolset.ToolProperties(path: usrBinTools[.cxxCompiler]!, extraCLIOptions: cxxCompilerOptions)
        )

        XCTAssertThrowsError(try Toolset(from: noValidToolsNoRoot.path, at: fileSystem, observability.topScope))

        XCTAssertEqual(observability.errors.count, 1)
        XCTAssertEqual(observability.warnings.count, 0)

        let unknownToolsToolset = try Toolset(from: unknownToolsNoRoot.path, at: fileSystem, observability.topScope)

        XCTAssertTrue(unknownToolsToolset.knownTools.isEmpty)
        // +2 warnings for each unknown tool, no new errors
        XCTAssertEqual(observability.errors.count, 1)
        XCTAssertEqual(observability.warnings.count, 2)

        var otherToolsToolset = try Toolset(from: otherToolsNoRoot.path, at: fileSystem, observability.topScope)

        XCTAssertEqual(otherToolsToolset.knownTools.count, 3)
        // no new warnings and errors were emitted
        XCTAssertEqual(observability.errors.count, 1)
        XCTAssertEqual(observability.warnings.count, 2)

        otherToolsToolset.merge(with: compilersToolset)

        XCTAssertEqual(
            compilersToolset.knownTools[.swiftCompiler],
            Toolset.ToolProperties(path: usrBinTools[.swiftCompiler]!)
        )
        XCTAssertEqual(
            compilersToolset.knownTools[.cCompiler],
            Toolset.ToolProperties(path: usrBinTools[.cCompiler]!, extraCLIOptions: cCompilerOptions)
        )
        XCTAssertEqual(
            compilersToolset.knownTools[.cxxCompiler],
            Toolset.ToolProperties(path: usrBinTools[.cxxCompiler]!, extraCLIOptions: cxxCompilerOptions)
        )
        XCTAssertEqual(
            otherToolsToolset.knownTools[.librarian],
            Toolset.ToolProperties(path: usrBinTools[.librarian]!)
        )
        XCTAssertEqual(
            otherToolsToolset.knownTools[.linker],
            Toolset.ToolProperties(path: usrBinTools[.linker]!)
        )
        XCTAssertEqual(
            otherToolsToolset.knownTools[.debugger],
            Toolset.ToolProperties(path: usrBinTools[.debugger]!)
        )

        let someToolsWithRoot = try Toolset(from: someToolsWithRoot.path, at: fileSystem, observability.topScope)

        XCTAssertEqual(someToolsWithRoot.knownTools.count, 4)
        // no new warnings and errors emitted
        XCTAssertEqual(observability.errors.count, 1)
        XCTAssertEqual(observability.warnings.count, 2)

        otherToolsToolset.merge(with: someToolsWithRoot)
        XCTAssertEqual(
            otherToolsToolset.knownTools[.swiftCompiler],
            Toolset.ToolProperties(path: usrBinTools[.swiftCompiler]!)
        )
        XCTAssertEqual(
            otherToolsToolset.knownTools[.cCompiler],
            Toolset.ToolProperties(
                path: usrBinTools[.cCompiler]!,
                extraCLIOptions: cCompilerOptions + newCCompilerOptions
            )
        )
        XCTAssertEqual(
            otherToolsToolset.knownTools[.cxxCompiler],
            Toolset.ToolProperties(path: usrBinTools[.cxxCompiler]!, extraCLIOptions: cxxCompilerOptions)
        )
        XCTAssertEqual(
            otherToolsToolset.knownTools[.librarian],
            Toolset.ToolProperties(path: try! AbsolutePath(validating: "/custom/llvm-ar"))
        )
        XCTAssertEqual(
            otherToolsToolset.knownTools[.linker],
            Toolset.ToolProperties(path: try! AbsolutePath(validating: "/custom/ld"))
        )
        XCTAssertEqual(
            otherToolsToolset.knownTools[.debugger],
            Toolset.ToolProperties(path: usrBinTools[.debugger]!)
        )

        let someToolsWithRelativeRoot = try Toolset(from: someToolsWithRelativeRoot.path, at: fileSystem, observability.topScope)
        XCTAssertEqual(
            someToolsWithRelativeRoot,
            Toolset(
                knownTools: [.cCompiler: .init(extraCLIOptions: newCCompilerOptions)],
                rootPaths: [try AbsolutePath(validating: "/tools/relative/custom")]
            )
        )
    }
}
