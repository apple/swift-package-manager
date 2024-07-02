//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import struct Foundation.URL
@testable import PackageFingerprint
import PackageModel
import _InternalTestSupport
import XCTest

import struct TSCUtility.Version

final class FilePackageFingerprintStorageTests: XCTestCase {
    func testHappyCase() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/fingerprints")
        let storage = FilePackageFingerprintStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)
        let registryURL = URL("https://example.packages.com")
        let sourceControlURL = SourceControlURL("https://example.com/mona/LinkedList.git")

        // Add fingerprints for mona.LinkedList
        let package = PackageIdentity.plain("mona.LinkedList")
        try await storage.put(
            package: package,
            version: Version("1.0.0"),
            fingerprint: .init(origin: .registry(registryURL), value: "checksum-1.0.0", contentType: .sourceCode)
        )
        try await storage.put(
            package: package,
            version: Version("1.0.0"),
            fingerprint: .init(
                origin: .sourceControl(sourceControlURL),
                value: "gitHash-1.0.0",
                contentType: .sourceCode
            )
        )
        try await storage.put(
            package: package,
            version: Version("1.1.0"),
            fingerprint: .init(origin: .registry(registryURL), value: "checksum-1.1.0", contentType: .sourceCode)
        )

        // Fingerprint for another package
        let otherPackage = PackageIdentity.plain("other.LinkedList")
        try await storage.put(
            package: otherPackage,
            version: Version("1.0.0"),
            fingerprint: .init(origin: .registry(registryURL), value: "checksum-1.0.0", contentType: .sourceCode)
        )

        // A checksum file should have been created for each package
        XCTAssertTrue(mockFileSystem.exists(storage.directoryPath.appending(component: package.fingerprintsFilename)))
        XCTAssertTrue(
            mockFileSystem
                .exists(storage.directoryPath.appending(component: otherPackage.fingerprintsFilename))
        )

        // Fingerprints should be saved
        do {
            let fingerprints = try await storage.get(package: package, version: Version("1.0.0"))
            XCTAssertEqual(fingerprints.count, 2)

            let registryFingerprints = fingerprints[.registry]
            XCTAssertEqual(registryFingerprints?.count, 1)
            XCTAssertEqual(registryFingerprints?[.sourceCode]?.origin.url, SourceControlURL(registryURL))
            XCTAssertEqual(registryFingerprints?[.sourceCode]?.value, "checksum-1.0.0")

            let scmFingerprints = fingerprints[.sourceControl]
            XCTAssertEqual(scmFingerprints?.count, 1)
            XCTAssertEqual(scmFingerprints?[.sourceCode]?.origin.url, sourceControlURL)
            XCTAssertEqual(scmFingerprints?[.sourceCode]?.value, "gitHash-1.0.0")
        }

        do {
            let fingerprints = try await storage.get(package: package, version: Version("1.1.0"))
            XCTAssertEqual(fingerprints.count, 1)

            let registryFingerprints = fingerprints[.registry]
            XCTAssertEqual(registryFingerprints?.count, 1)
            XCTAssertEqual(registryFingerprints?[.sourceCode]?.origin.url, SourceControlURL(registryURL))
            XCTAssertEqual(registryFingerprints?[.sourceCode]?.value, "checksum-1.1.0")
        }

        do {
            let fingerprints = try await storage.get(package: otherPackage, version: Version("1.0.0"))
            XCTAssertEqual(fingerprints.count, 1)

            let registryFingerprints = fingerprints[.registry]
            XCTAssertEqual(registryFingerprints?.count, 1)
            XCTAssertEqual(registryFingerprints?[.sourceCode]?.origin.url, SourceControlURL(registryURL))
            XCTAssertEqual(registryFingerprints?[.sourceCode]?.value, "checksum-1.0.0")
        }
    }

    func testNotFound() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/fingerprints")
        let storage = FilePackageFingerprintStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)
        let registryURL = URL("https://example.packages.com")

        let package = PackageIdentity.plain("mona.LinkedList")
        try await storage.put(
            package: package,
            version: Version("1.0.0"),
            fingerprint: .init(origin: .registry(registryURL), value: "checksum-1.0.0", contentType: .sourceCode)
        )

        // No fingerprints found for the content type
        await XCTAssertAsyncThrowsError(try await storage.get(
            package: package,
            version: Version("1.0.0"),
            kind: .registry,
            contentType: .manifest(.none)
        )) { error in
            guard case PackageFingerprintStorageError.notFound = error else {
                return XCTFail("Expected PackageFingerprintStorageError.notFound, got \(error)")
            }
        }

        // No fingerprints found for the version
        await XCTAssertAsyncThrowsError(try await storage.get(package: package, version: Version("1.1.0"))) { error in
            guard case PackageFingerprintStorageError.notFound = error else {
                return XCTFail("Expected PackageFingerprintStorageError.notFound, got \(error)")
            }
        }

        // No fingerprints found for the package
        let otherPackage = PackageIdentity.plain("other.LinkedList")
        await XCTAssertAsyncThrowsError(try await storage.get(package: otherPackage, version: Version("1.0.0"))) { error in
            guard case PackageFingerprintStorageError.notFound = error else {
                return XCTFail("Expected PackageFingerprintStorageError.notFound, got \(error)")
            }
        }
    }

    func testSingleFingerprintPerKindAndContentType() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/fingerprints")
        let storage = FilePackageFingerprintStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)
        let registryURL = URL("https://example.packages.com")

        let package = PackageIdentity.plain("mona.LinkedList")
        // Write registry checksum for v1.0.0
        try await storage.put(
            package: package,
            version: Version("1.0.0"),
            fingerprint: .init(origin: .registry(registryURL), value: "checksum-1.0.0", contentType: .sourceCode)
        )

        // Writing for the same version and kind and content type but different checksum should fail
        await XCTAssertAsyncThrowsError(try await storage.put(
            package: package,
            version: Version("1.0.0"),
            fingerprint: .init(
                origin: .registry(registryURL),
                value: "checksum-1.0.0-1",
                contentType: .sourceCode
            )
        )) { error in
            guard case PackageFingerprintStorageError.conflict = error else {
                return XCTFail("Expected PackageFingerprintStorageError.conflict, got \(error)")
            }
        }

        // Writing for the same version and kind and content type same checksum should not fail
        _ = try await storage.put(
            package: package,
            version: Version("1.0.0"),
            fingerprint: .init(
                origin: .registry(registryURL),
                value: "checksum-1.0.0",
                contentType: .sourceCode
            )
        )
    }

    func testHappyCase_PackageReferenceAPI() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/fingerprints")
        let storage = FilePackageFingerprintStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)
        let sourceControlURL = SourceControlURL("https://example.com/mona/LinkedList.git")
        let packageRef = PackageReference.remoteSourceControl(
            identity: PackageIdentity(url: sourceControlURL),
            url: sourceControlURL
        )

        try await storage.put(
            package: packageRef,
            version: Version("1.0.0"),
            fingerprint: .init(
                origin: .sourceControl(sourceControlURL),
                value: "gitHash-1.0.0",
                contentType: .sourceCode
            )
        )
        try await storage.put(
            package: packageRef,
            version: Version("1.1.0"),
            fingerprint: .init(
                origin: .sourceControl(sourceControlURL),
                value: "gitHash-1.1.0",
                contentType: .sourceCode
            )
        )

        // Fingerprints should be saved
        let fingerprints = try await storage.get(package: packageRef, version: Version("1.1.0"))
        XCTAssertEqual(fingerprints.count, 1)

        let scmFingerprints = fingerprints[.sourceControl]
        XCTAssertEqual(scmFingerprints?.count, 1)

        XCTAssertEqual(scmFingerprints?[.sourceCode]?.origin.url, sourceControlURL)
        XCTAssertEqual(scmFingerprints?[.sourceCode]?.value, "gitHash-1.1.0")
    }

    func testDifferentRepoURLsThatHaveSameIdentity() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/fingerprints")
        let storage = FilePackageFingerprintStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)
        let fooURL = SourceControlURL("https://example.com/foo/LinkedList.git")
        let barURL = SourceControlURL("https://example.com/bar/LinkedList.git")

        // foo and bar have the same identity `LinkedList`
        let fooRef = PackageReference.remoteSourceControl(identity: PackageIdentity(url: fooURL), url: fooURL)
        let barRef = PackageReference.remoteSourceControl(identity: PackageIdentity(url: barURL), url: barURL)

        try await storage.put(
            package: fooRef,
            version: Version("1.0.0"),
            fingerprint: .init(origin: .sourceControl(fooURL), value: "abcde-foo", contentType: .sourceCode)
        )
        // This should succeed because they get written to different files
        try await storage.put(
            package: barRef,
            version: Version("1.0.0"),
            fingerprint: .init(origin: .sourceControl(barURL), value: "abcde-bar", contentType: .sourceCode)
        )

        XCTAssertNotEqual(try fooRef.fingerprintsFilename, try barRef.fingerprintsFilename)

        // A checksum file should have been created for each package
        XCTAssertTrue(
            mockFileSystem
                .exists(storage.directoryPath.appending(component: try fooRef.fingerprintsFilename))
        )
        XCTAssertTrue(
            mockFileSystem
                .exists(storage.directoryPath.appending(component: try barRef.fingerprintsFilename))
        )

        // This should fail because fingerprint for 1.0.0 already exists and it's different
        await XCTAssertAsyncThrowsError(try await storage.put(
            package: fooRef,
            version: Version("1.0.0"),
            fingerprint: .init(
                origin: .sourceControl(fooURL),
                value: "abcde-foo-foo",
                contentType: .sourceCode
            )
        )) { error in
            guard case PackageFingerprintStorageError.conflict = error else {
                return XCTFail("Expected PackageFingerprintStorageError.conflict, got \(error)")
            }
        }

        // This should succeed because fingerprint for 2.0.0 doesn't exist yet
        try await storage.put(
            package: fooRef,
            version: Version("2.0.0"),
            fingerprint: .init(origin: .sourceControl(fooURL), value: "abcde-foo", contentType: .sourceCode)
        )
    }

    func testConvertingFromV1ToV2() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/fingerprints")
        try mockFileSystem.createDirectory(directoryPath, recursive: true)
        let storage = FilePackageFingerprintStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)

        let sourceControlURL = SourceControlURL("https://example.com/mona/LinkedList.git")
        let package = PackageIdentity.plain("mona.LinkedList")
        let fingerprintsPath = directoryPath.appending(package.fingerprintsFilename)
        let v1Fingerprints = """
        {
          "versionFingerprints" : {
            "1.0.3" : {
              "sourceControl" : {
                "fingerprint" : "e394bf350e38cb100b6bc4172834770ede1b7232",
                "origin" : "\(sourceControlURL)"
              }
            },
            "1.2.2" : {
              "sourceControl" : {
                "fingerprint" : "fee6933f37fde9a5e12a1e4aeaa93fe60116ff2a",
                "origin" : "\(sourceControlURL)"
              }
            }
          }
        }
        """
        // Write v1 fingerprints file
        try mockFileSystem.writeFileContents(fingerprintsPath, string: v1Fingerprints)

        // v1 fingerprints file should be converted to v2 when read
        let fingerprints = try await storage.get(package: package, version: Version("1.0.3"))
        XCTAssertEqual(fingerprints.count, 1)

        let scmFingerprints = fingerprints[.sourceControl]
        XCTAssertEqual(scmFingerprints?.count, 1)
        // All v1 fingerprints have content type source code
        XCTAssertEqual(scmFingerprints?[.sourceCode]?.origin.url, sourceControlURL)
        XCTAssertEqual(scmFingerprints?[.sourceCode]?.value, "e394bf350e38cb100b6bc4172834770ede1b7232")
    }

    func testFingerprintsOfDifferentContentTypes() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/fingerprints")
        let storage = FilePackageFingerprintStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)
        let registryURL = URL("https://example.packages.com")
        let sourceControlURL = SourceControlURL("https://example.com/mona/LinkedList.git")

        // Add fingerprints for 1.0.0 source archive/code
        let package = PackageIdentity.plain("mona.LinkedList")
        try await storage.put(
            package: package,
            version: Version("1.0.0"),
            fingerprint: .init(
                origin: .registry(registryURL),
                value: "archive-checksum-1.0.0",
                contentType: .sourceCode
            )
        )
        try await storage.put(
            package: package,
            version: Version("1.0.0"),
            fingerprint: .init(
                origin: .sourceControl(sourceControlURL),
                value: "gitHash-1.0.0",
                contentType: .sourceCode
            )
        )

        // Add fingerprints for 1.0.0 manifests
        try await storage.put(
            package: package,
            version: Version("1.0.0"),
            fingerprint: .init(
                origin: .registry(registryURL),
                value: "manifest-checksum-1.0.0",
                contentType: .manifest(.none)
            )
        )
        try await storage.put(
            package: package,
            version: Version("1.0.0"),
            fingerprint: .init(
                origin: .registry(registryURL),
                value: "manifest-5.6-checksum-1.0.0",
                contentType: .manifest(ToolsVersion.v5_6)
            )
        )

        // Add fingerprint for 1.1.0 source archive
        try await storage.put(
            package: package,
            version: Version("1.1.0"),
            fingerprint: .init(
                origin: .registry(registryURL),
                value: "archive-checksum-1.1.0",
                contentType: .sourceCode
            )
        )

        let fingerprints = try await storage.get(package: package, version: Version("1.0.0"))
        XCTAssertEqual(fingerprints.count, 2)

        let registryFingerprints = fingerprints[.registry]
        XCTAssertEqual(registryFingerprints?.count, 3)
        XCTAssertEqual(registryFingerprints?[.sourceCode]?.origin.url, SourceControlURL(registryURL))
        XCTAssertEqual(registryFingerprints?[.sourceCode]?.value, "archive-checksum-1.0.0")
        XCTAssertEqual(registryFingerprints?[.manifest(.none)]?.origin.url, SourceControlURL(registryURL))
        XCTAssertEqual(registryFingerprints?[.manifest(.none)]?.value, "manifest-checksum-1.0.0")
        XCTAssertEqual(registryFingerprints?[.manifest(ToolsVersion.v5_6)]?.origin.url, SourceControlURL(registryURL))
        XCTAssertEqual(registryFingerprints?[.manifest(ToolsVersion.v5_6)]?.value, "manifest-5.6-checksum-1.0.0")

        let scmFingerprints = fingerprints[.sourceControl]
        XCTAssertEqual(scmFingerprints?.count, 1)
        XCTAssertEqual(scmFingerprints?[.sourceCode]?.origin.url, sourceControlURL)
        XCTAssertEqual(scmFingerprints?[.sourceCode]?.value, "gitHash-1.0.0")
    }
}

extension PackageFingerprintStorage {
    fileprivate func get(
        package: PackageIdentity,
        version: Version
    ) async throws -> [Fingerprint.Kind: [Fingerprint.ContentType: Fingerprint]] {
        try await safe_async {
            self.get(
                package: package,
                version: version,
                observabilityScope: ObservabilitySystem.NOOP,
                callbackQueue: .sharedConcurrent,
                callback: $0
            )
        }
    }

    fileprivate func get(
        package: PackageIdentity,
        version: Version,
        kind: Fingerprint.Kind,
        contentType: Fingerprint.ContentType
    ) async throws -> Fingerprint {
        try await safe_async {
            self.get(
                package: package,
                version: version,
                kind: kind,
                contentType: contentType,
                observabilityScope: ObservabilitySystem.NOOP,
                callbackQueue: .sharedConcurrent,
                callback: $0
            )
        }
    }

    fileprivate func put(
        package: PackageIdentity,
        version: Version,
        fingerprint: Fingerprint
    ) async throws {
        try await safe_async {
            self.put(
                package: package,
                version: version,
                fingerprint: fingerprint,
                observabilityScope: ObservabilitySystem.NOOP,
                callbackQueue: .sharedConcurrent,
                callback: $0
            )
        }
    }

    fileprivate func get(
        package: PackageReference,
        version: Version
    ) async throws -> [Fingerprint.Kind: [Fingerprint.ContentType: Fingerprint]] {
        try await safe_async {
            self.get(
                package: package,
                version: version,
                observabilityScope: ObservabilitySystem.NOOP,
                callbackQueue: .sharedConcurrent,
                callback: $0
            )
        }
    }

    fileprivate func get(
        package: PackageReference,
        version: Version,
        kind: Fingerprint.Kind,
        contentType: Fingerprint.ContentType
    ) async throws -> Fingerprint {
        try await safe_async {
            self.get(
                package: package,
                version: version,
                kind: kind,
                contentType: contentType,
                observabilityScope: ObservabilitySystem.NOOP,
                callbackQueue: .sharedConcurrent,
                callback: $0
            )
        }
    }

    fileprivate func put(
        package: PackageReference,
        version: Version,
        fingerprint: Fingerprint
    ) async throws {
        try await safe_async {
            self.put(
                package: package,
                version: version,
                fingerprint: fingerprint,
                observabilityScope: ObservabilitySystem.NOOP,
                callbackQueue: .sharedConcurrent,
                callback: $0
            )
        }
    }
}
