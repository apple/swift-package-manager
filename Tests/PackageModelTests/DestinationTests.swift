//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
@testable import PackageModel
@testable import SPMBuildCore
import TSCBasic
import XCTest

private let bundleRootPath = try! AbsolutePath(validating: "/tmp/cross-toolchain")
private let toolchainBinDir = RelativePath("swift.xctoolchain/usr/bin")
private let sdkRootDir = RelativePath("ubuntu-jammy.sdk")
private let hostTriple = try! Triple("arm64-apple-darwin22.1.0")
private let linuxGNUTargetTriple = try! Triple("x86_64-unknown-linux-gnu")
private let linuxMuslTargetTriple = try! Triple("x86_64-unknown-linux-musl")
private let extraFlags = BuildFlags(
    cCompilerFlags: ["-fintegrated-as"],
    cxxCompilerFlags: ["-fno-exceptions"],
    swiftCompilerFlags: ["-enable-experimental-cxx-interop", "-use-ld=lld"],
    linkerFlags: ["-R/usr/lib/swift/linux/"]
)

private let destinationV1 = (
    path: "\(bundleRootPath)/destinationV1.json",
    json: #"""
    {
        "version": 1,
        "sdk": "\#(bundleRootPath.appending(sdkRootDir))",
        "toolchain-bin-dir": "\#(bundleRootPath.appending(toolchainBinDir))",
        "target": "\#(linuxGNUTargetTriple.tripleString)",
        "extra-cc-flags": \#(extraFlags.cCompilerFlags),
        "extra-swiftc-flags": \#(extraFlags.swiftCompilerFlags),
        "extra-cpp-flags": \#(extraFlags.cxxCompilerFlags)
    }
    """#
)

private let destinationV2 = (
    path: "\(bundleRootPath)/destinationV2.json",
    json: #"""
    {
        "version": 2,
        "sdkRootDir": "\#(sdkRootDir)",
        "toolchainBinDir": "\#(toolchainBinDir)",
        "hostTriples": ["\#(hostTriple.tripleString)"],
        "targetTriples": ["\#(linuxGNUTargetTriple.tripleString)"],
        "extraCCFlags": \#(extraFlags.cCompilerFlags),
        "extraSwiftCFlags": \#(extraFlags.swiftCompilerFlags),
        "extraCXXFlags": \#(extraFlags.cxxCompilerFlags),
        "extraLinkerFlags": \#(extraFlags.linkerFlags)
    }
    """#
)

private let toolsetNoRootDestinationV3 = (
    path: "\(bundleRootPath)/toolsetNoRootDestinationV3.json",
    json: #"""
    {
        "runTimeTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/otherToolsNoRoot.json"]
            }
        },
        "schemaVersion": "3.0"
    }
    """#
)

private let toolsetRootDestinationV3 = (
    path: "\(bundleRootPath)/toolsetRootDestinationV3.json",
    json: #"""
    {
        "runTimeTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/someToolsWithRoot.json", "/tools/otherToolsNoRoot.json"]
            }
        },
        "schemaVersion": "3.0"
    }
    """#
)

private let missingToolsetDestinationV3 = (
    path: "\(bundleRootPath)/missingToolsetDestinationV3.json",
    json: #"""
    {
        "runTimeTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/asdf.json"]
            }
        },
        "schemaVersion": "3.0"
    }
    """#
)

private let invalidVersionDestinationV3 = (
    path: "\(bundleRootPath)/invalidVersionDestinationV3.json",
    json: #"""
    {
        "runTimeTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/someToolsWithRoot.json"]
            }
        },
        "schemaVersion": "2.9"
    }
    """#
)

private let invalidToolsetDestinationV3 = (
    path: "\(bundleRootPath)/invalidToolsetDestinationV3.json",
    json: #"""
    {
        "runTimeTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/invalidToolset.json"]
            }
        },
        "schemaVersion": "3.0"
    }
    """#
)

private let usrBinTools = Dictionary(uniqueKeysWithValues: Toolset.KnownTool.allCases.map {
    ($0, "/usr/bin/\($0.rawValue)")
})

private let otherToolsNoRoot = (
    path: "/tools/otherToolsNoRoot.json",
    json: #"""
    {
        "schemaVersion": "1.0",
        "librarian": { "path": "\#(usrBinTools[.librarian]!)" },
        "linker": { "path": "\#(usrBinTools[.linker]!)" },
        "debugger": { "path": "\#(usrBinTools[.debugger]!)" }
    }
    """#
)

private let cCompilerOptions = ["-fopenmp"]

private let someToolsWithRoot = (
    path: "/tools/someToolsWithRoot.json",
    json: #"""
    {
        "schemaVersion": "1.0",
        "rootPath": "/custom",
        "cCompiler": { "extraCLIOptions": \#(cCompilerOptions) },
        "linker": { "path": "ld" },
        "librarian": { "path": "llvm-ar" },
        "debugger": { "path": "\#(usrBinTools[.debugger]!)" }
    }
    """#
)

private let invalidToolset = (
    path: "/tools/invalidToolset.json",
    json: #"""
    {
      "rootPath" : "swift.xctoolchain\/usr\/bin",
      "tools" : [
        "linker",
        {
          "path" : "ld.lld"
        },
        "swiftCompiler",
        {
          "extraCLIOptions" : [
            "-use-ld=lld",
            "-Xlinker",
            "-R\/usr\/lib\/swift\/linux\/"
          ]
        },
        "cxxCompiler",
        {
          "extraCLIOptions" : [
            "-lstdc++"
          ]
        }
      ],
      "schemaVersion" : "1.0"
    }
    """#
)

private let sdkRootAbsolutePath = bundleRootPath.appending(sdkRootDir)
private let toolchainBinAbsolutePath = bundleRootPath.appending(toolchainBinDir)

private let parsedDestinationV2GNU = Destination(
    hostTriple: hostTriple,
    targetTriple: linuxGNUTargetTriple,
    toolset: .init(toolchainBinDir: toolchainBinAbsolutePath, buildFlags: extraFlags),
    pathsConfiguration: .init(sdkRootPath: sdkRootAbsolutePath)
)

private let parsedDestinationV2Musl = Destination(
    hostTriple: hostTriple,
    targetTriple: linuxMuslTargetTriple,
    toolset: .init(toolchainBinDir: toolchainBinAbsolutePath, buildFlags: extraFlags),
    pathsConfiguration: .init(sdkRootPath: sdkRootAbsolutePath)
)

private let parsedToolsetNoRootDestinationV3 = Destination(
    targetTriple: linuxGNUTargetTriple,
    toolset: .init(
        knownTools: [
            .librarian: .init(path: try! AbsolutePath(validating: "\(usrBinTools[.librarian]!)")),
            .linker: .init(path: try! AbsolutePath(validating: "\(usrBinTools[.linker]!)")),
            .debugger: .init(path: try! AbsolutePath(validating: "\(usrBinTools[.debugger]!)")),
        ],
        rootPaths: []
    ),
    pathsConfiguration: .init(
        sdkRootPath: bundleRootPath.appending(sdkRootDir),
        toolsetPaths: ["/tools/otherToolsNoRoot.json"]
            .map { try! AbsolutePath(validating: $0) }
    )
)

private let parsedToolsetRootDestinationV3 = Destination(
    targetTriple: linuxGNUTargetTriple,
    toolset: .init(
        knownTools: [
            .cCompiler: .init(extraCLIOptions: cCompilerOptions),
            .librarian: .init(path: try! AbsolutePath(validating: "\(usrBinTools[.librarian]!)")),
            .linker: .init(path: try! AbsolutePath(validating: "\(usrBinTools[.linker]!)")),
            .debugger: .init(path: try! AbsolutePath(validating: "\(usrBinTools[.debugger]!)")),
        ],
        rootPaths: [try! AbsolutePath(validating: "/custom")]
    ),
    pathsConfiguration: .init(
        sdkRootPath: bundleRootPath.appending(sdkRootDir),
        toolsetPaths: ["/tools/someToolsWithRoot.json", "/tools/otherToolsNoRoot.json"]
            .map { try! AbsolutePath(validating: $0) }
    )
)

final class DestinationTests: XCTestCase {
    func testDestinationCodable() throws {
        let fs = InMemoryFileSystem()
        try fs.createDirectory(.init(validating: "/tools"))
        try fs.createDirectory(.init(validating: "/tmp"))
        try fs.createDirectory(.init(validating: "\(bundleRootPath)"))
        for testFile in [
            destinationV1,
            destinationV2,
            toolsetNoRootDestinationV3,
            toolsetRootDestinationV3,
            missingToolsetDestinationV3,
            invalidVersionDestinationV3,
            invalidToolsetDestinationV3,
            otherToolsNoRoot,
            someToolsWithRoot,
            invalidToolset,
        ] {
            try fs.writeFileContents(AbsolutePath(validating: testFile.path), string: testFile.json)
        }

        let system = ObservabilitySystem.makeForTesting()
        let observability = system.topScope

        let destinationV1Decoded = try Destination.decode(
            fromFile: AbsolutePath(validating: destinationV1.path),
            fileSystem: fs,
            observabilityScope: observability
        )

        var flagsWithoutLinkerFlags = extraFlags
        flagsWithoutLinkerFlags.linkerFlags = []

        XCTAssertEqual(
            destinationV1Decoded,
            [
                Destination(
                    targetTriple: linuxGNUTargetTriple,
                    toolset: .init(toolchainBinDir: toolchainBinAbsolutePath, buildFlags: flagsWithoutLinkerFlags),
                    pathsConfiguration: .init(
                        sdkRootPath: sdkRootAbsolutePath
                    )
                ),
            ]
        )

        let destinationV2Decoded = try Destination.decode(
            fromFile: AbsolutePath(validating: destinationV2.path),
            fileSystem: fs,
            observabilityScope: observability
        )

        XCTAssertEqual(destinationV2Decoded, [parsedDestinationV2GNU])

        let toolsetNoRootDestinationV3Decoded = try Destination.decode(
            fromFile: AbsolutePath(validating: toolsetNoRootDestinationV3.path),
            fileSystem: fs,
            observabilityScope: observability
        )

        XCTAssertEqual(toolsetNoRootDestinationV3Decoded, [parsedToolsetNoRootDestinationV3])

        let toolsetRootDestinationV3Decoded = try Destination.decode(
            fromFile: AbsolutePath(validating: toolsetRootDestinationV3.path),
            fileSystem: fs,
            observabilityScope: observability
        )

        XCTAssertEqual(toolsetRootDestinationV3Decoded, [parsedToolsetRootDestinationV3])

        XCTAssertThrowsError(try Destination.decode(
            fromFile: AbsolutePath(validating: missingToolsetDestinationV3.path),
            fileSystem: fs,
            observabilityScope: observability
        )) {
            XCTAssertEqual(
                $0 as? StringError,
                StringError(
                    """
                    Couldn't parse toolset configuration at `/tools/asdf.json`: /tools/asdf.json doesn't exist in file \
                    system
                    """
                )
            )
        }
        XCTAssertThrowsError(try Destination.decode(
            fromFile: AbsolutePath(validating: invalidVersionDestinationV3.path),
            fileSystem: fs,
            observabilityScope: observability
        ))

        XCTAssertThrowsError(try Destination.decode(
            fromFile: AbsolutePath(validating: invalidToolsetDestinationV3.path),
            fileSystem: fs,
            observabilityScope: observability
        )) {
            XCTAssertTrue(
                ($0 as? StringError)?.description
                    .hasPrefix("Couldn't parse toolset configuration at `/tools/invalidToolset.json`: ") ?? false
            )
        }
    }

    func testSelectDestination() throws {
        let bundles = [
            SwiftSDKBundle(
                path: try AbsolutePath(validating: "/destination.artifactsbundle"),
                artifacts: [
                    "id1": [
                        .init(
                            metadata: .init(
                                path: "id1",
                                supportedTriples: [hostTriple]
                            ),
                            swiftSDKs: [parsedDestinationV2GNU]
                        ),
                    ],
                    "id2": [
                        .init(
                            metadata: .init(
                                path: "id2",
                                supportedTriples: []
                            ),
                            swiftSDKs: [parsedDestinationV2GNU]
                        ),
                    ],
                    "id3": [
                        .init(
                            metadata: .init(
                                path: "id3",
                                supportedTriples: [hostTriple]
                            ),
                            swiftSDKs: [parsedDestinationV2Musl]
                        ),
                    ],
                ]
            ),
        ]

        let system = ObservabilitySystem.makeForTesting()

        XCTAssertEqual(
            bundles.selectDestination(
                matching: "id1",
                hostTriple: hostTriple,
                observabilityScope: system.topScope
            ),
            parsedDestinationV2GNU
        )

        // Expecting `nil` because no host triple is specified for this destination
        // in the fake destination bundle.
        XCTAssertNil(
            bundles.selectDestination(
                matching: "id2",
                hostTriple: hostTriple,
                observabilityScope: system.topScope
            )
        )

        XCTAssertEqual(
            bundles.selectDestination(
                matching: "id3",
                hostTriple: hostTriple,
                observabilityScope: system.topScope
            ),
            parsedDestinationV2Musl
        )
    }
}
