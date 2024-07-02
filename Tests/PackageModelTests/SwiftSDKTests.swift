//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@testable import Basics

@_spi(SwiftPMInternal)
@testable import PackageModel

@testable import SPMBuildCore
import XCTest

private let bundleRootPath = try! AbsolutePath(validating: "/tmp/cross-toolchain")
private let toolchainBinDir = RelativePath("swift.xctoolchain/usr/bin")
private let sdkRootDir = RelativePath("ubuntu-jammy.sdk")
private let hostTriple = try! Triple("arm64-apple-darwin22.1.0")
private let olderHostTriple = try! Triple("arm64-apple-darwin20.1.0")
private let linuxGNUTargetTriple = try! Triple("x86_64-unknown-linux-gnu")
private let linuxMuslTargetTriple = try! Triple("x86_64-unknown-linux-musl")
private let extraFlags = BuildFlags(
    cCompilerFlags: ["-fintegrated-as"],
    cxxCompilerFlags: ["-fno-exceptions"],
    swiftCompilerFlags: ["-enable-experimental-cxx-interop", "-use-ld=lld"],
    linkerFlags: ["-R/usr/lib/swift/linux/"]
)

private let destinationV1 = (
    path: bundleRootPath.appending(component: "destinationV1.json"),
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
    """# as SerializedJSON
)

private let destinationV2 = (
    path: bundleRootPath.appending(component: "destinationV2.json"),
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
    """# as SerializedJSON
)

private let toolsetNoRootDestinationV3 = (
    path: bundleRootPath.appending(component: "toolsetNoRootDestinationV3.json"),
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
    """# as SerializedJSON
)

private let toolsetRootDestinationV3 = (
    path: bundleRootPath.appending(component: "toolsetRootDestinationV3.json"),
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
    """# as SerializedJSON
)

private let missingToolsetDestinationV3 = (
    path: bundleRootPath.appending(component: "missingToolsetDestinationV3.json"),
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
    """# as SerializedJSON
)

private let invalidVersionDestinationV3 = (
    path: bundleRootPath.appending(component: "invalidVersionDestinationV3.json"),
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
    """# as SerializedJSON
)

private let invalidToolsetDestinationV3 = (
    path: bundleRootPath.appending(component: "invalidToolsetDestinationV3.json"),
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
    """# as SerializedJSON
)

private let toolsetNoRootSwiftSDKv4 = (
    path: bundleRootPath.appending(component: "toolsetNoRootSwiftSDKv4.json"),
    json: #"""
    {
        "targetTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/otherToolsNoRoot.json"]
            }
        },
        "schemaVersion": "4.0"
    }
    """# as SerializedJSON
)

private let toolsetRootSwiftSDKv4 = (
    path: bundleRootPath.appending(component: "toolsetRootSwiftSDKv4.json"),
    json: #"""
    {
        "targetTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/someToolsWithRoot.json", "/tools/otherToolsNoRoot.json"]
            }
        },
        "schemaVersion": "4.0"
    }
    """# as SerializedJSON
)

private let missingToolsetSwiftSDKv4 = (
    path: bundleRootPath.appending(component: "missingToolsetSwiftSDKv4.json"),
    json: #"""
    {
        "targetTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/asdf.json"]
            }
        },
        "schemaVersion": "4.0"
    }
    """# as SerializedJSON
)

private let invalidVersionSwiftSDKv4 = (
    path: bundleRootPath.appending(component: "invalidVersionSwiftSDKv4.json"),
    json: #"""
    {
        "targetTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/someToolsWithRoot.json"]
            }
        },
        "schemaVersion": "42.9"
    }
    """# as SerializedJSON
)

private let invalidToolsetSwiftSDKv4 = (
    path: bundleRootPath.appending(component: "invalidToolsetSwiftSDKv4.json"),
    json: #"""
    {
        "targetTriples": {
            "\#(linuxGNUTargetTriple.tripleString)": {
                "sdkRootPath": "\#(sdkRootDir)",
                "toolsetPaths": ["/tools/invalidToolset.json"]
            }
        },
        "schemaVersion": "4.0"
    }
    """# as SerializedJSON
)

private let usrBinTools = Dictionary(uniqueKeysWithValues: Toolset.KnownTool.allCases.map {
    ($0, "/usr/bin/\($0.rawValue)")
})

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

private let cCompilerOptions = ["-fopenmp"]

private let someToolsWithRoot = (
    path: try! AbsolutePath(validating: "/tools/someToolsWithRoot.json"),
    json: #"""
    {
        "schemaVersion": "1.0",
        "rootPath": "/custom",
        "cCompiler": { "extraCLIOptions": \#(cCompilerOptions) },
        "linker": { "path": "ld" },
        "librarian": { "path": "llvm-ar" },
        "debugger": { "path": "\#(usrBinTools[.debugger]!)" }
    }
    """# as SerializedJSON
)

private let invalidToolset = (
    path: try! AbsolutePath(validating: "/tools/invalidToolset.json"),
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
    """# as SerializedJSON
)

private let sdkRootAbsolutePath = bundleRootPath.appending(sdkRootDir)
private let toolchainBinAbsolutePath = bundleRootPath.appending(toolchainBinDir)

private let parsedDestinationV2GNU = SwiftSDK(
    hostTriple: hostTriple,
    targetTriple: linuxGNUTargetTriple,
    toolset: .init(toolchainBinDir: toolchainBinAbsolutePath, buildFlags: extraFlags),
    pathsConfiguration: .init(sdkRootPath: sdkRootAbsolutePath)
)

private let parsedDestinationV2Musl = SwiftSDK(
    hostTriple: hostTriple,
    targetTriple: linuxMuslTargetTriple,
    toolset: .init(toolchainBinDir: toolchainBinAbsolutePath, buildFlags: extraFlags),
    pathsConfiguration: .init(sdkRootPath: sdkRootAbsolutePath)
)

private let parsedDestinationForOlderHost = SwiftSDK(
    targetTriple: linuxMuslTargetTriple,
    toolset: .init(toolchainBinDir: toolchainBinAbsolutePath, buildFlags: extraFlags),
    pathsConfiguration: .init(sdkRootPath: sdkRootAbsolutePath)
)

private let parsedToolsetNoRootDestination = SwiftSDK(
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

private let parsedToolsetRootDestination = SwiftSDK(
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

private let testFiles: [(path: AbsolutePath, json: SerializedJSON)] = [
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

final class DestinationTests: XCTestCase {
    func testDestinationCodable() throws {
        let fs = InMemoryFileSystem()
        try fs.createDirectory(AbsolutePath(validating: "/tools"))
        try fs.createDirectory(AbsolutePath(validating: "/tmp"))
        try fs.createDirectory(AbsolutePath(validating: "\(bundleRootPath)"))
        for testFile in testFiles {
            try fs.writeFileContents(testFile.path, string: testFile.json.underlying)
        }

        let system = ObservabilitySystem.makeForTesting()
        let observability = system.topScope

        let destinationV1Decoded = try SwiftSDK.decode(
            fromFile: destinationV1.path,
            fileSystem: fs,
            observabilityScope: observability
        )

        var flagsWithoutLinkerFlags = extraFlags
        flagsWithoutLinkerFlags.linkerFlags = []

        XCTAssertEqual(
            destinationV1Decoded,
            [
                SwiftSDK(
                    targetTriple: linuxGNUTargetTriple,
                    toolset: .init(toolchainBinDir: toolchainBinAbsolutePath, buildFlags: flagsWithoutLinkerFlags),
                    pathsConfiguration: .init(
                        sdkRootPath: sdkRootAbsolutePath
                    )
                ),
            ]
        )

        let destinationV2Decoded = try SwiftSDK.decode(
            fromFile: destinationV2.path,
            fileSystem: fs,
            observabilityScope: observability
        )

        XCTAssertEqual(destinationV2Decoded, [parsedDestinationV2GNU])

        let toolsetNoRootDestinationV3Decoded = try SwiftSDK.decode(
            fromFile: toolsetNoRootDestinationV3.path,
            fileSystem: fs,
            observabilityScope: observability
        )

        XCTAssertEqual(toolsetNoRootDestinationV3Decoded, [parsedToolsetNoRootDestination])

        let toolsetRootDestinationV3Decoded = try SwiftSDK.decode(
            fromFile: toolsetRootDestinationV3.path,
            fileSystem: fs,
            observabilityScope: observability
        )

        XCTAssertEqual(toolsetRootDestinationV3Decoded, [parsedToolsetRootDestination])

        XCTAssertThrowsError(try SwiftSDK.decode(
            fromFile: missingToolsetDestinationV3.path,
            fileSystem: fs,
            observabilityScope: observability
        )) {
            let toolsetDefinition: AbsolutePath = "/tools/asdf.json"
            XCTAssertEqual(
                $0 as? StringError,
                StringError(
                    """
                    Couldn't parse toolset configuration at `\(toolsetDefinition)`: \
                    \(toolsetDefinition) doesn't exist in file system
                    """
                )
            )
        }
        XCTAssertThrowsError(try SwiftSDK.decode(
            fromFile: invalidVersionDestinationV3.path,
            fileSystem: fs,
            observabilityScope: observability
        ))

        XCTAssertThrowsError(try SwiftSDK.decode(
            fromFile: invalidToolsetDestinationV3.path,
            fileSystem: fs,
            observabilityScope: observability
        )) {
            let toolsetDefinition: AbsolutePath = "/tools/invalidToolset.json"
            XCTAssertTrue(
                ($0 as? StringError)?.description
                    .hasPrefix("Couldn't parse toolset configuration at `\(toolsetDefinition)`: ") ?? false
            )
        }

        let toolsetNoRootSwiftSDKv4Decoded = try SwiftSDK.decode(
            fromFile: toolsetNoRootSwiftSDKv4.path,
            fileSystem: fs,
            observabilityScope: observability
        )

        XCTAssertEqual(toolsetNoRootSwiftSDKv4Decoded, [parsedToolsetNoRootDestination])

        let toolsetRootSwiftSDKv4Decoded = try SwiftSDK.decode(
            fromFile: toolsetRootSwiftSDKv4.path,
            fileSystem: fs,
            observabilityScope: observability
        )

        XCTAssertEqual(toolsetRootSwiftSDKv4Decoded, [parsedToolsetRootDestination])

        XCTAssertThrowsError(try SwiftSDK.decode(
            fromFile: missingToolsetSwiftSDKv4.path,
            fileSystem: fs,
            observabilityScope: observability
        )) {
            let toolsetDefinition: AbsolutePath = "/tools/asdf.json"
            XCTAssertEqual(
                $0 as? StringError,
                StringError(
                    """
                    Couldn't parse toolset configuration at `\(toolsetDefinition)`: \
                    \(toolsetDefinition) doesn't exist in file system
                    """
                )
            )
        }
        XCTAssertThrowsError(try SwiftSDK.decode(
            fromFile: invalidVersionSwiftSDKv4.path,
            fileSystem: fs,
            observabilityScope: observability
        ))

        XCTAssertThrowsError(try SwiftSDK.decode(
            fromFile: invalidToolsetSwiftSDKv4.path,
            fileSystem: fs,
            observabilityScope: observability
        )) {
            let toolsetDefinition: AbsolutePath = "/tools/invalidToolset.json"
            XCTAssertTrue(
                ($0 as? StringError)?.description
                    .hasPrefix("Couldn't parse toolset configuration at `\(toolsetDefinition)`: ") ?? false
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
                    "id4": [
                        .init(
                            metadata: .init(
                                path: "id4",
                                supportedTriples: [olderHostTriple]
                            ),
                            swiftSDKs: [parsedDestinationForOlderHost]
                        ),
                    ],
                    "id5": [
                        .init(
                            metadata: .init(
                                path: "id5",
                                supportedTriples: nil
                            ),
                            swiftSDKs: [parsedDestinationV2GNU]
                        ),
                    ],
                ]
            ),
        ]

        let system = ObservabilitySystem.makeForTesting()

        XCTAssertEqual(
            bundles.selectSwiftSDK(
                matching: "id1",
                hostTriple: hostTriple,
                observabilityScope: system.topScope
            ),
            parsedDestinationV2GNU
        )

        // Expecting `nil` because no host triple is specified for this destination
        // in the fake destination bundle.
        XCTAssertNil(
            bundles.selectSwiftSDK(
                matching: "id2",
                hostTriple: hostTriple,
                observabilityScope: system.topScope
            )
        )

        XCTAssertEqual(
            bundles.selectSwiftSDK(
                matching: "id3",
                hostTriple: hostTriple,
                observabilityScope: system.topScope
            ),
            parsedDestinationV2Musl
        )

        // Newer hostTriple should match with older supportedTriples
        XCTAssertEqual(
            bundles.selectSwiftSDK(
                id: "id4",
                hostTriple: hostTriple,
                targetTriple: linuxMuslTargetTriple
            ),
            parsedDestinationForOlderHost
        )
        XCTAssertEqual(
            bundles.selectSwiftSDK(
                matching: "id4",
                hostTriple: hostTriple,
                observabilityScope: system.topScope
            ),
            parsedDestinationForOlderHost
        )

        // nil supportedTriples should match with any hostTriple
        XCTAssertEqual(
            bundles.selectSwiftSDK(
                id: "id5",
                hostTriple: hostTriple,
                targetTriple: linuxGNUTargetTriple
            ),
            parsedDestinationV2GNU
        )
        XCTAssertEqual(
            bundles.selectSwiftSDK(
                matching: "id5",
                hostTriple: hostTriple,
                observabilityScope: system.topScope
            ),
            parsedDestinationV2GNU
        )
    }
}
