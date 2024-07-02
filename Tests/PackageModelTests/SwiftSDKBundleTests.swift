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

import Basics
@_spi(SwiftPMInternal)
@testable import PackageModel
import _InternalTestSupport
import XCTest

import struct TSCBasic.ByteString
import protocol TSCBasic.FileSystem
import class TSCBasic.InMemoryFileSystem
import class Workspace.Workspace

private let testArtifactID = "test-artifact"

private let targetTriple = try! Triple("aarch64-unknown-linux")

private let jsonEncoder = JSONEncoder()

private func generateBundleFiles(bundle: MockBundle) throws -> [(String, ByteString)] {
    try [
        (
            "\(bundle.path)/info.json",
            ByteString(json: """
            {
                "artifacts" : {
                    \(bundle.artifacts.map {
                            """
                            "\($0.id)" : {
                                "type" : "swiftSDK",
                                "version" : "0.0.1",
                                "variants" : [
                                    {
                                        "path" : "\($0.id)/\(targetTriple.triple)",
                                        "supportedTriples" : \($0.supportedTriples.map(\.tripleString))
                                    }
                                ]
                            }
                            """
                        }.joined(separator: ",\n")
                    )
                },
                "schemaVersion" : "1.0"
            }
            """)
        ),

    ] + bundle.artifacts.map {
        (
            "\(bundle.path)/\($0.id)/\(targetTriple.tripleString)/swift-sdk.json",
            ByteString(json: try generateSwiftSDKMetadata(jsonEncoder, createToolset: $0.toolsetRootPath != nil))
        )
    } + bundle.artifacts.compactMap { artifact in
        artifact.toolsetRootPath.map { path in
            (
                "\(bundle.path)/\(artifact.id)/\(targetTriple.tripleString)/toolset.json",
                ByteString(json: """
                {
                    "schemaVersion": "1.0",
                    "rootPath": "\(path)"
                }
                """)
            )
        }
    }
}

private func generateSwiftSDKMetadata(_ encoder: JSONEncoder, createToolset: Bool) throws -> SerializedJSON {
    try """
    {
        "schemaVersion": "4.0",
        "targetTriples": \(
            String(
                bytes: encoder.encode([
                    targetTriple.tripleString: SwiftSDKMetadataV4.TripleProperties(sdkRootPath: "sdk", toolsetPaths: createToolset ? [
                        "toolset.json"
                    ] : nil)
                ]),
                encoding: .utf8
            )!
        )
    }
    """
}

private struct MockBundle {
    let name: String
    let path: String
    let artifacts: [MockArtifact]
}

private struct MockArtifact {
    let id: String
    let supportedTriples: [Triple]
    var toolsetRootPath: AbsolutePath?
}

private func generateTestFileSystem(bundleArtifacts: [MockArtifact]) throws -> (some FileSystem, [MockBundle], AbsolutePath) {
    let bundles = bundleArtifacts.enumerated().map { (i, artifacts) in
        let bundleName = "test\(i).\(artifactBundleExtension)"
        return MockBundle(name: "test\(i).\(artifactBundleExtension)", path: "/\(bundleName)", artifacts: [artifacts])
    }


    let fileSystem = try InMemoryFileSystem(
        files: Dictionary(
            uniqueKeysWithValues: bundles.flatMap {
                try generateBundleFiles(bundle: $0)
            }
        )
    )

    let swiftSDKsDirectory = try AbsolutePath(validating: "/sdks")
    try fileSystem.createDirectory(fileSystem.tempDirectory)
    try fileSystem.createDirectory(swiftSDKsDirectory)

    return (fileSystem, bundles, swiftSDKsDirectory)
}

private let arm64Triple = try! Triple("arm64-apple-macosx13.0")
private let i686Triple = try! Triple("i686-apple-macosx13.0")

private let fixtureSDKsPath = try! AbsolutePath(validating: #file)
    .parentDirectory
    .parentDirectory
    .parentDirectory
    .appending(components: ["Fixtures", "SwiftSDKs"])

final class SwiftSDKBundleTests: XCTestCase {
    func testInstallRemote() async throws {
        #if canImport(Darwin) && !os(macOS)
        try XCTSkipIf(true, "skipping test because process launching is not available")
        #endif

        let system = ObservabilitySystem.makeForTesting()
        let observabilityScope = system.topScope
        let cancellator = Cancellator(observabilityScope: observabilityScope)
        let archiver = UniversalArchiver(localFileSystem, cancellator)

        let fixtureAndURLs: [(url: String, fixture: String, checksum: String)] = [
            ("https://localhost/archive?test=foo", "test-sdk.artifactbundle.tar.gz", "724b5abf125287517dbc5be9add055d4755dfca679e163b249ea1045f5800c6e"),
            ("https://localhost/archive.tar.gz", "test-sdk.artifactbundle.tar.gz", "724b5abf125287517dbc5be9add055d4755dfca679e163b249ea1045f5800c6e"),
            ("https://localhost/archive.zip", "test-sdk.artifactbundle.zip", "74f6df5aa91c582c12e3a6670ff95973e463dd3266aabbc52ad13c3cd27e2793"),
        ]

        for (bundleURLString, fixture, checksum) in fixtureAndURLs {
            let httpClient = HTTPClient { request, _ in
                guard case let .download(_, downloadPath) = request.kind else {
                    XCTFail("Unexpected HTTPClient.Request.Kind")
                    return .init(statusCode: 400)
                }
                let fixturePath = fixtureSDKsPath.appending(component: fixture)
                try localFileSystem.copy(from: fixturePath, to: downloadPath)
                return .init(statusCode: 200)
            }

            try await withTemporaryDirectory(fileSystem: localFileSystem, removeTreeOnDeinit: true) { tmpDir in
                var output = [SwiftSDKBundleStore.Output]()
                let store = SwiftSDKBundleStore(
                    swiftSDKsDirectory: tmpDir,
                    fileSystem: localFileSystem,
                    observabilityScope: observabilityScope,
                    outputHandler: {
                        output.append($0)
                    }
                )
                try await store.install(bundlePathOrURL: bundleURLString, checksum: checksum, archiver, httpClient) {
                    try Workspace.BinaryArtifactsManager.checksum(forBinaryArtifactAt: $0, fileSystem: localFileSystem)
                }

                let bundleURL = URL(string: bundleURLString)!
                XCTAssertEqual(output, [
                    .downloadStarted(bundleURL),
                    .downloadFinishedSuccessfully(bundleURL),
                    .verifyingChecksum,
                    .checksumValid,
                    .unpackingArchive(bundlePathOrURL: bundleURLString),
                    .installationSuccessful(
                        bundlePathOrURL: bundleURLString,
                        bundleName: "test-sdk.artifactbundle"
                    ),
                ])
            }.value
        }
    }

    func testInstall() async throws {
        let system = ObservabilitySystem.makeForTesting()

        let (fileSystem, bundles, swiftSDKsDirectory) = try generateTestFileSystem(
            bundleArtifacts: [
                .init(id: testArtifactID, supportedTriples: [arm64Triple]),
                .init(id: testArtifactID, supportedTriples: [arm64Triple])
            ]
        )

        let archiver = MockArchiver()

        var output = [SwiftSDKBundleStore.Output]()
        let store = SwiftSDKBundleStore(
            swiftSDKsDirectory: swiftSDKsDirectory,
            fileSystem: fileSystem,
            observabilityScope: system.topScope,
            outputHandler: {
                output.append($0)
            }
        )

        // Expected to be successful:
        try await store.install(bundlePathOrURL: bundles[0].path, archiver)

        // Expected to fail:
        let invalidPath = "foobar"
        do {
            try await store.install(bundlePathOrURL: invalidPath, archiver)

            XCTFail("Function expected to throw")
        } catch {
            guard let error = error as? SwiftSDKError else {
                XCTFail("Unexpected error type")
                return
            }

            switch error {
            case let .invalidBundleArchive(archivePath):
                XCTAssertEqual(archivePath, AbsolutePath.root.appending(invalidPath))
            default:
                XCTFail("Unexpected error value")
            }
        }

        do {
            try await store.install(bundlePathOrURL: bundles[0].path, archiver)

            XCTFail("Function expected to throw")
        } catch {
            guard let error = error as? SwiftSDKError else {
                XCTFail("Unexpected error type")
                return
            }

            switch error {
            case let .swiftSDKArtifactAlreadyInstalled(installedBundleName, newBundleName, artifactID):
                XCTAssertEqual(bundles[0].name, installedBundleName)
                XCTAssertEqual(newBundleName, "test0.\(artifactBundleExtension)")
                XCTAssertEqual(artifactID, testArtifactID)
            default:
                XCTFail("Unexpected error value")
            }
        }

        do {
            try await store.install(bundlePathOrURL: bundles[1].path, archiver)

             XCTFail("Function expected to throw")
         } catch {
            guard let error = error as? SwiftSDKError else {
                XCTFail("Unexpected error type")
                return
            }

            switch error {
            case .swiftSDKArtifactAlreadyInstalled(let installedBundleName, let newBundleName, let artifactID):
                XCTAssertEqual(bundles[0].name, installedBundleName)
                XCTAssertEqual(bundles[1].name, newBundleName)
                XCTAssertEqual(artifactID, testArtifactID)
            default:
                XCTFail("Unexpected error value")
            }
        }

        XCTAssertEqual(output, [
            .installationSuccessful(
                bundlePathOrURL: bundles[0].path,
                bundleName: AbsolutePath(bundles[0].path).components.last!
            ),
            .unpackingArchive(bundlePathOrURL: invalidPath),
        ])
    }

    func testList() async throws {
        let (fileSystem, bundles, swiftSDKsDirectory) = try generateTestFileSystem(
            bundleArtifacts: [
                .init(id: "\(testArtifactID)2", supportedTriples: [i686Triple]),
                .init(id: "\(testArtifactID)1", supportedTriples: [arm64Triple]),
            ]
        )
        let system = ObservabilitySystem.makeForTesting()
        let archiver = MockArchiver()

        var output = [SwiftSDKBundleStore.Output]()
        let store = SwiftSDKBundleStore(
            swiftSDKsDirectory: swiftSDKsDirectory,
            fileSystem: fileSystem,
            observabilityScope: system.topScope,
            outputHandler: {
                output.append($0)
            }
        )

        for bundle in bundles {
            try await store.install(bundlePathOrURL: bundle.path, archiver)
        }

        let validBundles = try store.allValidBundles

        XCTAssertEqual(validBundles.count, bundles.count)

        XCTAssertEqual(validBundles.sortedArtifactIDs, ["\(testArtifactID)1", "\(testArtifactID)2"])
        XCTAssertEqual(output, [
            .installationSuccessful(
                bundlePathOrURL: bundles[0].path,
                bundleName: AbsolutePath(bundles[0].path).components.last!
            ),
            .installationSuccessful(
                bundlePathOrURL: bundles[1].path,
                bundleName: AbsolutePath(bundles[1].path).components.last!
            ),
        ])
    }

    func testBundleSelection() async throws {
        let (fileSystem, bundles, swiftSDKsDirectory) = try generateTestFileSystem(
            bundleArtifacts: [
                .init(id: "\(testArtifactID)1", supportedTriples: [arm64Triple]),
                .init(id: "\(testArtifactID)2", supportedTriples: [i686Triple])
            ]
        )
        let system = ObservabilitySystem.makeForTesting()

        var output = [SwiftSDKBundleStore.Output]()
        let store = SwiftSDKBundleStore(
            swiftSDKsDirectory: swiftSDKsDirectory,
            fileSystem: fileSystem,
            observabilityScope: system.topScope,
            outputHandler: {
                output.append($0)
            }
        )

        let archiver = MockArchiver()
        for bundle in bundles {
            try await store.install(bundlePathOrURL: bundle.path, archiver)
        }

        let sdk = try store.selectBundle(
            matching: "\(testArtifactID)1",
            hostTriple: Triple("arm64-apple-macosx14.0")
        )

        XCTAssertEqual(sdk.targetTriple, targetTriple)
        XCTAssertEqual(output, [
            .installationSuccessful(
                bundlePathOrURL: bundles[0].path,
                bundleName: AbsolutePath(bundles[0].path).components.last!
            ),
            .installationSuccessful(
                bundlePathOrURL: bundles[1].path,
                bundleName: AbsolutePath(bundles[1].path).components.last!
            ),
        ])
    }

    func testTargetSDKDerivation() async throws {
        let toolsetRootPath = AbsolutePath("/path/to/toolpath")
        let (fileSystem, bundles, swiftSDKsDirectory) = try generateTestFileSystem(
            bundleArtifacts: [
                .init(id: "\(testArtifactID)1", supportedTriples: [arm64Triple]),
                .init(id: "\(testArtifactID)2", supportedTriples: [arm64Triple], toolsetRootPath: toolsetRootPath),
            ]
        )
        let system = ObservabilitySystem.makeForTesting()
        let hostSwiftSDK = try SwiftSDK.hostSwiftSDK(environment: [:])
        let hostTriple = try! Triple("arm64-apple-macosx14.0")
        let archiver = MockArchiver()
        let store = SwiftSDKBundleStore(
            swiftSDKsDirectory: swiftSDKsDirectory,
            fileSystem: fileSystem,
            observabilityScope: system.topScope,
            outputHandler: { _ in }
        )
        for bundle in bundles {
            try await store.install(bundlePathOrURL: bundle.path, archiver)
        }

        do {
            let targetSwiftSDK = try SwiftSDK.deriveTargetSwiftSDK(
                hostSwiftSDK: hostSwiftSDK,
                hostTriple: hostTriple,
                store: store,
                observabilityScope: system.topScope,
                fileSystem: fileSystem
            )
            // By default, the target SDK is the same as the host SDK.
            XCTAssertEqual(targetSwiftSDK, hostSwiftSDK)
        }

        do {
            let targetSwiftSDK = try SwiftSDK.deriveTargetSwiftSDK(
                hostSwiftSDK: hostSwiftSDK,
                hostTriple: hostTriple,
                swiftSDKSelector: "\(testArtifactID)1",
                store: store,
                observabilityScope: system.topScope,
                fileSystem: fileSystem
            )
            // With a target SDK selector, SDK should be chosen from the store.
            XCTAssertEqual(targetSwiftSDK.targetTriple, targetTriple)
            // No toolset in the SDK, so it should be the same as the host SDK.
            XCTAssertEqual(targetSwiftSDK.toolset.rootPaths, hostSwiftSDK.toolset.rootPaths)
        }

        do {
            let targetSwiftSDK = try SwiftSDK.deriveTargetSwiftSDK(
                hostSwiftSDK: hostSwiftSDK,
                hostTriple: hostTriple,
                swiftSDKSelector: "\(testArtifactID)2",
                store: store,
                observabilityScope: system.topScope,
                fileSystem: fileSystem
            )
            // With toolset in the target SDK, it should contain the host toolset roots at the end.
            XCTAssertEqual(targetSwiftSDK.toolset.rootPaths, [toolsetRootPath] + hostSwiftSDK.toolset.rootPaths)
        }

        do {
            // Check explicit overriding options.
            let customCompileSDK = AbsolutePath("/path/to/sdk")
            let archs = ["x86_64-apple-macosx10.15"]
            let customCompileToolchain = AbsolutePath("/path/to/toolchain")
            try fileSystem.createDirectory(customCompileToolchain, recursive: true)

            let targetSwiftSDK = try SwiftSDK.deriveTargetSwiftSDK(
                hostSwiftSDK: hostSwiftSDK,
                hostTriple: hostTriple,
                customCompileToolchain: customCompileToolchain,
                customCompileSDK: customCompileSDK,
                architectures: archs,
                store: store,
                observabilityScope: system.topScope,
                fileSystem: fileSystem
            )
            XCTAssertEqual(targetSwiftSDK.architectures, archs)
            XCTAssertEqual(targetSwiftSDK.pathsConfiguration.sdkRootPath, customCompileSDK)
            XCTAssertEqual(
                targetSwiftSDK.toolset.rootPaths,
                [customCompileToolchain.appending(components: ["usr", "bin"])] + hostSwiftSDK.toolset.rootPaths
            )
        }
    }
}
