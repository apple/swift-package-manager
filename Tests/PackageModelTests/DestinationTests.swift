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
    path: try! AbsolutePath(validating: "\(bundleRootPath)/destinationV1.json"),
    json: ByteString(encodingAsUTF8: #"""
    {
        "version": 1,
        "sdk": "\#(bundleRootPath.appending(sdkRootDir))",
        "toolchain-bin-dir": "\#(bundleRootPath.appending(toolchainBinDir))",
        "target": "\#(linuxGNUTargetTriple.tripleString)",
        "extra-cc-flags": \#(extraFlags.cCompilerFlags),
        "extra-swiftc-flags": \#(extraFlags.swiftCompilerFlags),
        "extra-cpp-flags": \#(extraFlags.cxxCompilerFlags)
    }
    """#)
)

private let destinationV2 = (
    path: try! AbsolutePath(validating: "\(bundleRootPath)/destinationV2.json"),
    json: ByteString(encodingAsUTF8: #"""
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
    """#)
)

private let toolsetNoRootDestinationV3 = (
    path: try! AbsolutePath(validating: "\(bundleRootPath)/toolsetNoRootDestinationV3.json"),
    json: ByteString(encodingAsUTF8: #"""
    {
        "runTimeTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/otherToolsNoRoot.json"]
            }
        },
        "schemaVersion": "3.0"
    }
    """#)
)

private let toolsetRootDestinationV3 = (
    path: try! AbsolutePath(validating: "\(bundleRootPath)/toolsetRootDestinationV3.json"),
    json: ByteString(encodingAsUTF8: #"""
    {
        "runTimeTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/someToolsWithRoot.json", "/tools/otherToolsNoRoot.json"]
            }
        },
        "schemaVersion": "3.0"
    }
    """#)
)

private let missingToolsetDestinationV3 = (
    path: try! AbsolutePath(validating: "\(bundleRootPath)/missingToolsetDestinationV3.json"),
    json: ByteString(encodingAsUTF8: #"""
    {
        "runTimeTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/asdf.json"]
            }
        },
        "schemaVersion": "3.0"
    }
    """#)
)

private let invalidVersionDestinationV3 = (
    path: try! AbsolutePath(validating: "\(bundleRootPath)/invalidVersionDestinationV3.json"),
    json: ByteString(encodingAsUTF8: #"""
    {
        "runTimeTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/someToolsWithRoot.json"]
            }
        },
        "schemaVersion": "2.9"
    }
    """#)
)

private let invalidToolsetDestinationV3 = (
    path: try! AbsolutePath(validating: "\(bundleRootPath)/invalidToolsetDestinationV3.json"),
    json: ByteString(encodingAsUTF8: #"""
    {
        "runTimeTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/invalidToolset.json"]
            }
        },
        "schemaVersion": "3.0"
    }
    """#)
)

private let toolsetNoRootSwiftSDKv4 = (
    path: try! AbsolutePath(validating: "\(bundleRootPath)/toolsetNoRootSwiftSDKv4.json"),
    json: ByteString(encodingAsUTF8: #"""
    {
        "targetTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/otherToolsNoRoot.json"]
            }
        },
        "schemaVersion": "4.0"
    }
    """#)
)

private let toolsetRootSwiftSDKv4 = (
    path: try! AbsolutePath(validating: "\(bundleRootPath)/toolsetRootSwiftSDKv4.json"),
    json: ByteString(encodingAsUTF8: #"""
    {
        "targetTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/someToolsWithRoot.json", "/tools/otherToolsNoRoot.json"]
            }
        },
        "schemaVersion": "4.0"
    }
    """#)
)

private let missingToolsetSwiftSDKv4 = (
    path: try! AbsolutePath(validating: "\(bundleRootPath)/missingToolsetSwiftSDKv4.json"),
    json: ByteString(encodingAsUTF8: #"""
    {
        "targetTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/asdf.json"]
            }
        },
        "schemaVersion": "4.0"
    }
    """#)
)

private let invalidVersionSwiftSDKv4 = (
    path: try! AbsolutePath(validating: "\(bundleRootPath)/invalidVersionSwiftSDKv4.json"),
    json: ByteString(encodingAsUTF8: #"""
    {
        "targetTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/someToolsWithRoot.json"]
            }
        },
        "schemaVersion": "42.9"
    }
    """#)
)

private let invalidToolsetSwiftSDKv4 = (
    path: try! AbsolutePath(validating: "\(bundleRootPath)/invalidToolsetSwiftSDKv4.json"),
    json: ByteString(encodingAsUTF8: #"""
    {
        "targetTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/invalidToolset.json"]
            }
        },
        "schemaVersion": "4.0"
    }
    """#)
)

private let usrBinTools = Dictionary(uniqueKeysWithValues: Toolset.KnownTool.allCases.map {
    ($0, try! AbsolutePath(validating: "/usr/bin/\($0.rawValue)"))
})

private let otherToolsNoRoot = (
    path: try! AbsolutePath(validating: "/tools/otherToolsNoRoot.json"),
    json: ByteString(encodingAsUTF8: #"""
    {
        "schemaVersion": "1.0",
        "librarian": { "path": "\#(usrBinTools[.librarian]!)" },
        "linker": { "path": "\#(usrBinTools[.linker]!)" },
        "debugger": { "path": "\#(usrBinTools[.debugger]!)" }
    }
    """#)
)

private let cCompilerOptions = ["-fopenmp"]

private let someToolsWithRoot = (
    path: try! AbsolutePath(validating: "/tools/someToolsWithRoot.json"),
    json: ByteString(encodingAsUTF8: #"""
    {
        "schemaVersion": "1.0",
        "rootPath": "/custom",
        "cCompiler": { "extraCLIOptions": \#(cCompilerOptions) },
        "linker": { "path": "ld" },
        "librarian": { "path": "llvm-ar" },
        "debugger": { "path": "\#(usrBinTools[.debugger]!)" }
    }
    """#)
)

private let invalidToolset = (
    path: try! AbsolutePath(validating: "/tools/invalidToolset.json"),
    json: ByteString(encodingAsUTF8: #"""
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
    """#)
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

private let parsedToolsetNoRootDestination = Destination(
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

private let parsedToolsetRootDestination = Destination(
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
        let arr: [(path: AbsolutePath, json: ByteString)] = [
            destinationV1,
            destinationV2,
            toolsetNoRootDestinationV3,
            toolsetRootDestinationV3,
            missingToolsetDestinationV3,
            invalidVersionDestinationV3,
            invalidToolsetDestinationV3,
            toolsetNoRootSwiftSDKv4,
            toolsetRootSwiftSDKv4,
            missingToolsetSwiftSDKv4,
            invalidVersionSwiftSDKv4,
            invalidToolsetSwiftSDKv4,
            otherToolsNoRoot,
            someToolsWithRoot,
            invalidToolset,
        ]
        for testFile in arr {
            try fs.writeFileContents(testFile.path, bytes: testFile.json)
        }

        let system = ObservabilitySystem.makeForTesting()
        let observability = system.topScope

        let destinationV1Decoded = try Destination.decode(
            fromFile: destinationV1.path,
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
            fromFile: destinationV2.path,
            fileSystem: fs,
            observabilityScope: observability
        )

        XCTAssertEqual(destinationV2Decoded, [parsedDestinationV2GNU])

        let toolsetNoRootDestinationV3Decoded = try Destination.decode(
            fromFile: toolsetNoRootDestinationV3.path,
            fileSystem: fs,
            observabilityScope: observability
        )

        XCTAssertEqual(toolsetNoRootDestinationV3Decoded, [parsedToolsetNoRootDestination])

        let toolsetRootDestinationV3Decoded = try Destination.decode(
            fromFile: toolsetRootDestinationV3.path,
            fileSystem: fs,
            observabilityScope: observability
        )

        XCTAssertEqual(toolsetRootDestinationV3Decoded, [parsedToolsetRootDestination])

        XCTAssertThrowsError(try Destination.decode(
            fromFile: missingToolsetDestinationV3.path,
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
            fromFile: invalidVersionDestinationV3.path,
            fileSystem: fs,
            observabilityScope: observability
        ))

        XCTAssertThrowsError(try Destination.decode(
            fromFile: invalidToolsetDestinationV3.path,
            fileSystem: fs,
            observabilityScope: observability
        )) {
            XCTAssertTrue(
                ($0 as? StringError)?.description
                    .hasPrefix("Couldn't parse toolset configuration at `/tools/invalidToolset.json`: ") ?? false
            )
        }

        let toolsetNoRootSwiftSDKv4Decoded = try Destination.decode(
            fromFile: toolsetNoRootSwiftSDKv4.path,
            fileSystem: fs,
            observabilityScope: observability
        )

        XCTAssertEqual(toolsetNoRootSwiftSDKv4Decoded, [parsedToolsetNoRootDestination])

        let toolsetRootSwiftSDKv4Decoded = try Destination.decode(
            fromFile: toolsetRootSwiftSDKv4.path,
            fileSystem: fs,
            observabilityScope: observability
        )

        XCTAssertEqual(toolsetRootSwiftSDKv4Decoded, [parsedToolsetRootDestination])

        XCTAssertThrowsError(try Destination.decode(
            fromFile: missingToolsetSwiftSDKv4.path,
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
            fromFile: invalidVersionSwiftSDKv4.path,
            fileSystem: fs,
            observabilityScope: observability
        ))

        XCTAssertThrowsError(try Destination.decode(
            fromFile: invalidToolsetSwiftSDKv4.path,
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
