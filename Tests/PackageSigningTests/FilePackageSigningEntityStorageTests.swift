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

import Basics
import PackageModel
@testable import PackageSigning
import _InternalTestSupport
import XCTest

import class TSCBasic.InMemoryFileSystem

import struct TSCUtility.Version

final class FilePackageSigningEntityStorageTests: XCTestCase {
    func testHappyCase() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/signing")
        let storage = FilePackageSigningEntityStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)

        // Record signing entities for mona.LinkedList
        let package = PackageIdentity.plain("mona.LinkedList")
        let appleseed = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit 1",
            organization: "SwiftPM Test"
        )
        let davinci = SigningEntity.recognized(
            type: .adp,
            name: "L. da Vinci",
            organizationalUnit: "SwiftPM Test Unit 2",
            organization: "SwiftPM Test"
        )
        try await storage.put(
            package: package,
            version: Version("1.0.0"),
            signingEntity: davinci,
            origin: .registry(URL("http://foo.com"))
        )
        try await storage.put(
            package: package,
            version: Version("1.1.0"),
            signingEntity: davinci,
            origin: .registry(URL("http://bar.com"))
        )
        try await storage.put(
            package: package,
            version: Version("2.0.0"),
            signingEntity: appleseed,
            origin: .registry(URL("http://foo.com"))
        )
        // Record signing entity for another package
        let otherPackage = PackageIdentity.plain("other.LinkedList")
        try await storage.put(
            package: otherPackage,
            version: Version("1.0.0"),
            signingEntity: appleseed,
            origin: .registry(URL("http://foo.com"))
        )

        // A data file should have been created for each package
        XCTAssertTrue(mockFileSystem.exists(storage.directoryPath.appending(component: package.signedVersionsFilename)))
        XCTAssertTrue(
            mockFileSystem
                .exists(storage.directoryPath.appending(component: otherPackage.signedVersionsFilename))
        )

        // Signed versions should be saved
        do {
            let packageSigners = try await storage.get(package: package)
            XCTAssertNil(packageSigners.expectedSigner)
            XCTAssertEqual(packageSigners.signers.count, 2)
            XCTAssertEqual(packageSigners.signers[davinci]?.versions, [Version("1.0.0"), Version("1.1.0")])
            XCTAssertEqual(
                packageSigners.signers[davinci]?.origins,
                [.registry(URL("http://foo.com")), .registry(URL("http://bar.com"))]
            )
            XCTAssertEqual(packageSigners.signers[appleseed]?.versions, [Version("2.0.0")])
            XCTAssertEqual(packageSigners.signers[appleseed]?.origins, [.registry(URL("http://foo.com"))])
        }

        do {
            let packageSigners = try await storage.get(package: otherPackage)
            XCTAssertNil(packageSigners.expectedSigner)
            XCTAssertEqual(packageSigners.signers.count, 1)
            XCTAssertEqual(packageSigners.signers[appleseed]?.versions, [Version("1.0.0")])
            XCTAssertEqual(packageSigners.signers[appleseed]?.origins, [.registry(URL("http://foo.com"))])
        }
    }

    func testPutDifferentSigningEntityShouldConflict() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/signing")
        let storage = FilePackageSigningEntityStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)

        let package = PackageIdentity.plain("mona.LinkedList")
        let appleseed = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit 1",
            organization: "SwiftPM Test"
        )
        let davinci = SigningEntity.recognized(
            type: .adp,
            name: "L. da Vinci",
            organizationalUnit: "SwiftPM Test Unit 2",
            organization: "SwiftPM Test"
        )
        let version = Version("1.0.0")
        try await storage.put(
            package: package,
            version: version,
            signingEntity: davinci,
            origin: .registry(URL("http://foo.com"))
        )

        // Writing different signing entities for the same version should fail
        await XCTAssertAsyncThrowsError(try await storage.put(
            package: package,
            version: version,
            signingEntity: appleseed,
            origin: .registry(URL("http://foo.com"))
        )) { error in
            guard case PackageSigningEntityStorageError.conflict = error else {
                return XCTFail("Expected PackageSigningEntityStorageError.conflict, got \(error)")
            }
        }
    }

    func testPutSameSigningEntityShouldNotConflict() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/signing")
        let storage = FilePackageSigningEntityStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)

        let package = PackageIdentity.plain("mona.LinkedList")
        let appleseed = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit",
            organization: "SwiftPM Test"
        )
        let version = Version("1.0.0")
        try await storage.put(
            package: package,
            version: version,
            signingEntity: appleseed,
            origin: .registry(URL("http://foo.com"))
        )

        // Writing same signing entity for version should be ok
        try await storage.put(
            package: package,
            version: version,
            signingEntity: appleseed,
            origin: .registry(URL("http://bar.com")) // origin is different and should be added
        )

        let packageSigners = try await storage.get(package: package)
        XCTAssertNil(packageSigners.expectedSigner)
        XCTAssertEqual(packageSigners.signers.count, 1)
        XCTAssertEqual(packageSigners.signers[appleseed]?.versions, [Version("1.0.0")])
        XCTAssertEqual(
            packageSigners.signers[appleseed]?.origins,
            [.registry(URL("http://foo.com")), .registry(URL("http://bar.com"))]
        )
    }

    func testPutUnrecognizedSigningEntityShouldError() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/signing")
        let storage = FilePackageSigningEntityStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)

        let package = PackageIdentity.plain("mona.LinkedList")
        let appleseed = SigningEntity.unrecognized(name: "J. Appleseed", organizationalUnit: nil, organization: nil)
        let version = Version("1.0.0")

        await XCTAssertAsyncThrowsError(try await storage.put(
            package: package,
            version: version,
            signingEntity: appleseed,
            origin: .registry(URL("http://bar.com")) // origin is different and should be added
        )) { error in
            guard case PackageSigningEntityStorageError.unrecognizedSigningEntity = error else {
                return XCTFail("Expected PackageSigningEntityStorageError.unrecognizedSigningEntity but got \(error)")
            }
        }
    }

    func testAddDifferentSigningEntityShouldNotConflict() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/signing")
        let storage = FilePackageSigningEntityStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)

        let package = PackageIdentity.plain("mona.LinkedList")
        let appleseed = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit 1",
            organization: "SwiftPM Test"
        )
        let davinci = SigningEntity.recognized(
            type: .adp,
            name: "L. da Vinci",
            organizationalUnit: "SwiftPM Test Unit 2",
            organization: "SwiftPM Test"
        )
        let version = Version("1.0.0")
        try await storage.put(
            package: package,
            version: version,
            signingEntity: davinci,
            origin: .registry(URL("http://foo.com"))
        )

        // Adding different signing entity for the same version should not fail
        try await storage.add(
            package: package,
            version: version,
            signingEntity: appleseed,
            origin: .registry(URL("http://bar.com"))
        )

        let packageSigners = try await storage.get(package: package)
        XCTAssertNil(packageSigners.expectedSigner)
        XCTAssertEqual(packageSigners.signers.count, 2)
        XCTAssertEqual(packageSigners.signers[appleseed]?.versions, [Version("1.0.0")])
        XCTAssertEqual(packageSigners.signers[appleseed]?.origins, [.registry(URL("http://bar.com"))])
        XCTAssertEqual(packageSigners.signers[davinci]?.versions, [Version("1.0.0")])
        XCTAssertEqual(packageSigners.signers[davinci]?.origins, [.registry(URL("http://foo.com"))])
        XCTAssertEqual(packageSigners.signingEntities(of: Version("1.0.0")), [appleseed, davinci])
    }

    func testAddUnrecognizedSigningEntityShouldError() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/signing")
        let storage = FilePackageSigningEntityStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)

        let package = PackageIdentity.plain("mona.LinkedList")
        let appleseed = SigningEntity.unrecognized(name: "J. Appleseed", organizationalUnit: nil, organization: nil)
        let davinci = SigningEntity.recognized(
            type: .adp,
            name: "L. da Vinci",
            organizationalUnit: "SwiftPM Test Unit",
            organization: "SwiftPM Test"
        )
        let version = Version("1.0.0")
        try await storage.put(
            package: package,
            version: version,
            signingEntity: davinci,
            origin: .registry(URL("http://foo.com"))
        )

        await XCTAssertAsyncThrowsError(try await storage.add(
            package: package,
            version: version,
            signingEntity: appleseed,
            origin: .registry(URL("http://bar.com"))
        )) { error in
            guard case PackageSigningEntityStorageError.unrecognizedSigningEntity = error else {
                return XCTFail("Expected PackageSigningEntityStorageError.unrecognizedSigningEntity but got \(error)")
            }
        }
    }

    func testChangeSigningEntityFromVersion() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/signing")
        let storage = FilePackageSigningEntityStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)

        let package = PackageIdentity.plain("mona.LinkedList")
        let appleseed = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit 1",
            organization: "SwiftPM Test"
        )
        let davinci = SigningEntity.recognized(
            type: .adp,
            name: "L. da Vinci",
            organizationalUnit: "SwiftPM Test Unit 2",
            organization: "SwiftPM Test"
        )
        try await storage.put(
            package: package,
            version: Version("1.0.0"),
            signingEntity: davinci,
            origin: .registry(URL("http://foo.com"))
        )

        // Sets package's expectedSigner and add package version signer
        try await storage.changeSigningEntityFromVersion(
            package: package,
            version: Version("1.5.0"),
            signingEntity: appleseed,
            origin: .registry(URL("http://bar.com"))
        )

        let packageSigners = try await storage.get(package: package)
        XCTAssertEqual(packageSigners.expectedSigner?.signingEntity, appleseed)
        XCTAssertEqual(packageSigners.expectedSigner?.fromVersion, Version("1.5.0"))
        XCTAssertEqual(packageSigners.signers.count, 2)
        XCTAssertEqual(packageSigners.signers[appleseed]?.versions, [Version("1.5.0")])
        XCTAssertEqual(packageSigners.signers[appleseed]?.origins, [.registry(URL("http://bar.com"))])
        XCTAssertEqual(packageSigners.signers[davinci]?.versions, [Version("1.0.0")])
        XCTAssertEqual(packageSigners.signers[davinci]?.origins, [.registry(URL("http://foo.com"))])
    }

    func testChangeSigningEntityFromVersion_unrecognizedSigningEntityShouldError() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/signing")
        let storage = FilePackageSigningEntityStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)

        let package = PackageIdentity.plain("mona.LinkedList")
        let appleseed = SigningEntity.unrecognized(name: "J. Appleseed", organizationalUnit: nil, organization: nil)
        let davinci = SigningEntity.recognized(
            type: .adp,
            name: "L. da Vinci",
            organizationalUnit: "SwiftPM Test Unit",
            organization: "SwiftPM Test"
        )
        try await storage.put(
            package: package,
            version: Version("1.0.0"),
            signingEntity: davinci,
            origin: .registry(URL("http://foo.com"))
        )

        await XCTAssertAsyncThrowsError(try await storage.changeSigningEntityFromVersion(
            package: package,
            version: Version("1.5.0"),
            signingEntity: appleseed,
            origin: .registry(URL("http://bar.com"))
        )) { error in
            guard case PackageSigningEntityStorageError.unrecognizedSigningEntity = error else {
                return XCTFail("Expected PackageSigningEntityStorageError.unrecognizedSigningEntity but got \(error)")
            }
        }
    }

    func testChangeSigningEntityForAllVersions() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/signing")
        let storage = FilePackageSigningEntityStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)

        let package = PackageIdentity.plain("mona.LinkedList")
        let appleseed = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit 1",
            organization: "SwiftPM Test"
        )
        let davinci = SigningEntity.recognized(
            type: .adp,
            name: "L. da Vinci",
            organizationalUnit: "SwiftPM Test Unit 2",
            organization: "SwiftPM Test"
        )
        try await storage.put(
            package: package,
            version: Version("1.0.0"),
            signingEntity: davinci,
            origin: .registry(URL("http://foo.com"))
        )
        try await storage.put(
            package: package,
            version: Version("2.0.0"),
            signingEntity: appleseed,
            origin: .registry(URL("http://bar.com"))
        )

        // Sets package's expectedSigner and remove all other signers
        try await storage.changeSigningEntityForAllVersions(
            package: package,
            version: Version("1.5.0"),
            signingEntity: appleseed,
            origin: .registry(URL("http://bar.com"))
        )

        let packageSigners = try await storage.get(package: package)
        XCTAssertEqual(packageSigners.expectedSigner?.signingEntity, appleseed)
        XCTAssertEqual(packageSigners.expectedSigner?.fromVersion, Version("1.5.0"))
        XCTAssertEqual(packageSigners.signers.count, 1)
        XCTAssertEqual(packageSigners.signers[appleseed]?.versions, [Version("1.5.0"), Version("2.0.0")])
        XCTAssertEqual(packageSigners.signers[appleseed]?.origins, [.registry(URL("http://bar.com"))])
    }

    func testChangeSigningEntityForAllVersions_unrecognizedSigningEntityShouldError() async throws {
        let mockFileSystem = InMemoryFileSystem()
        let directoryPath = AbsolutePath("/signing")
        let storage = FilePackageSigningEntityStorage(fileSystem: mockFileSystem, directoryPath: directoryPath)

        let package = PackageIdentity.plain("mona.LinkedList")
        let appleseed = SigningEntity.unrecognized(name: "J. Appleseed", organizationalUnit: nil, organization: nil)
        let davinci = SigningEntity.recognized(
            type: .adp,
            name: "L. da Vinci",
            organizationalUnit: "SwiftPM Test Unit",
            organization: "SwiftPM Test"
        )
        try await storage.put(
            package: package,
            version: Version("1.0.0"),
            signingEntity: davinci,
            origin: .registry(URL("http://foo.com"))
        )

        await XCTAssertAsyncThrowsError(try await storage.changeSigningEntityForAllVersions(
            package: package,
            version: Version("1.5.0"),
            signingEntity: appleseed,
            origin: .registry(URL("http://bar.com"))
        )) { error in
            guard case PackageSigningEntityStorageError.unrecognizedSigningEntity = error else {
                return XCTFail("Expected PackageSigningEntityStorageError.unrecognizedSigningEntity but got \(error)")
            }
        }
    }
}

extension PackageSigningEntityStorage {
    fileprivate func get(package: PackageIdentity) async throws -> PackageSigners {
        try await self.get(
            package: package,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
    }

    fileprivate func put(
        package: PackageIdentity,
        version: Version,
        signingEntity: SigningEntity,
        origin: SigningEntity.Origin
    ) async throws {
        try await self.put(
                package: package,
                version: version,
                signingEntity: signingEntity,
                origin: origin,
                observabilityScope: ObservabilitySystem.NOOP,
                callbackQueue: .sharedConcurrent
        )
    }

    fileprivate func add(
        package: PackageIdentity,
        version: Version,
        signingEntity: SigningEntity,
        origin: SigningEntity.Origin
    ) async throws {
        try await self.add(
            package: package,
            version: version,
            signingEntity: signingEntity,
            origin: origin,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
    }

    fileprivate func changeSigningEntityFromVersion(
        package: PackageIdentity,
        version: Version,
        signingEntity: SigningEntity,
        origin: SigningEntity.Origin
    ) async throws {
        try await self.changeSigningEntityFromVersion(
            package: package,
            version: version,
            signingEntity: signingEntity,
            origin: origin,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )

    }

    fileprivate func changeSigningEntityForAllVersions(
        package: PackageIdentity,
        version: Version,
        signingEntity: SigningEntity,
        origin: SigningEntity.Origin
    ) async throws {
        try await self.changeSigningEntityForAllVersions(
            package: package,
            version: version,
            signingEntity: signingEntity,
            origin: origin,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
    }
}
