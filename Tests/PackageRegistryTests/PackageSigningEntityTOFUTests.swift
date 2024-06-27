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
@testable import PackageRegistry
@testable import PackageSigning
import _InternalTestSupport
import XCTest

import struct TSCUtility.Version

final class PackageSigningEntityTOFUTests: XCTestCase {
    func testSigningEntitySeenForTheFirstTime() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("1.1.1")
        let signingEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit",
            organization: "SwiftPM Test"
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // Package doesn't have any recorded signer.
        // It should be ok to assign one.
        _ = try await tofu.validate(
            registry: registry,
            package: package,
            version: version,
            signingEntity: signingEntity
        )

        // `signingEntity` meets requirement to be used for TOFU
        // (i.e., it's .recognized), so it should be saved to storage.
        let packageSigners = try await signingEntityStorage.get(
            package: package.underlying,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
        XCTAssertEqual(packageSigners.signers.count, 1)
        XCTAssertEqual(packageSigners.signers[signingEntity]?.versions, [version])
    }

    func testNilSigningEntityShouldNotBeSaved() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("1.1.1")

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // Package doesn't have any recorded signer.
        // It should be ok to continue not to have one.
        _ = try await tofu.validate(
            registry: registry,
            package: package,
            version: version,
            signingEntity: .none
        )

        // `signingEntity` is nil, so it should not be saved to storage.
        let packageSigners = try await signingEntityStorage.get(
            package: package.underlying,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
        XCTAssertTrue(packageSigners.isEmpty)
    }

    func testUnrecognizedSigningEntityShouldNotBeSaved() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("1.1.1")
        let signingEntity = SigningEntity.unrecognized(
            name: "J. Appleseed",
            organizationalUnit: nil,
            organization: nil
        )

        let signingEntityStorage = MockPackageSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // Package doesn't have any recorded signer.
        // It should be ok to continue not to have one.
        _ = try await tofu.validate(
            registry: registry,
            package: package,
            version: version,
            signingEntity: signingEntity
        )

        // `signingEntity` is not .recognized, so it should not be saved to storage.
        let packageSigners = try await signingEntityStorage.get(
            package: package.underlying,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
        XCTAssertTrue(packageSigners.isEmpty)
    }

    func testSigningEntityMatchesStorageForSameVersion() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("1.1.1")
        let signingEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit",
            organization: "SwiftPM Test"
        )

        let signingEntityStorage = MockPackageSigningEntityStorage(
            [package.underlying: PackageSigners(
                expectedSigner: .none,
                signers: [signingEntity: PackageSigner(
                    signingEntity: signingEntity,
                    origins: [.registry(registry.url)],
                    versions: [version]
                )]
            )]
        )
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // Storage has "J. Appleseed" as signer for package version.
        // Signer remaining the same should be ok.
        _ = try await tofu.validate(
            registry: registry,
            package: package,
            version: version,
            signingEntity: signingEntity
        )
    }

    func testSigningEntityDoesNotMatchStorageForSameVersion_strictMode() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("1.1.1")
        let signingEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit 1",
            organization: "SwiftPM Test"
        )
        let existingSigningEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Smith",
            organizationalUnit: "SwiftPM Test Unit 2",
            organization: "SwiftPM Test"
        )

        let signingEntityStorage = MockPackageSigningEntityStorage(
            [package.underlying: PackageSigners(
                expectedSigner: .none,
                signers: [existingSigningEntity: PackageSigner(
                    signingEntity: existingSigningEntity,
                    origins: [.registry(registry.url)],
                    versions: [version]
                )]
            )]
        )
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict // intended for this test; don't change

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // Storage has "J. Smith" as signer for package version.
        // The given signer "J. Appleseed" is different so it should fail.
        await XCTAssertAsyncThrowsError(
            try await tofu.validate(
                registry: registry,
                package: package,
                version: version,
                signingEntity: signingEntity
            )
        ) { error in
            guard case RegistryError.signingEntityForReleaseChanged(_, _, _, let latest, let previous) = error else {
                return XCTFail("Expected RegistryError.signingEntityForReleaseChanged, got '\(error)'")
            }
            XCTAssertEqual(latest, signingEntity)
            XCTAssertEqual(previous, existingSigningEntity)
        }

        // Storage should not be updated
        let packageSigners = try await signingEntityStorage.get(
            package: package.underlying,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
        XCTAssertEqual(packageSigners.signers.count, 1)
        XCTAssertEqual(packageSigners.signers[existingSigningEntity]?.versions, [version])
    }

    func testSigningEntityDoesNotMatchStorageForSameVersion_warnMode() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("1.1.1")
        let signingEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit 1",
            organization: "SwiftPM Test"
        )
        let existingSigningEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Smith",
            organizationalUnit: "SwiftPM Test Unit 2",
            organization: "SwiftPM Test"
        )

        let signingEntityStorage = MockPackageSigningEntityStorage(
            [package.underlying: PackageSigners(
                expectedSigner: .none,
                signers: [existingSigningEntity: PackageSigner(
                    signingEntity: existingSigningEntity,
                    origins: [.registry(registry.url)],
                    versions: [version]
                )]
            )]
        )
        let signingEntityCheckingMode = SigningEntityCheckingMode.warn // intended for this test; don't change

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let observability = ObservabilitySystem.makeForTesting()

        // Storage has "J. Smith" as signer for package version.
        // The given signer "J. Appleseed" is different, but because
        // of .warn mode, no error is thrown.
        _ = try await tofu.validate(
            registry: registry,
            package: package,
            version: version,
            signingEntity: signingEntity,
            observabilityScope: observability.topScope
        )

        // But there should be a warning
        testDiagnostics(observability.diagnostics) { result in
            result.check(diagnostic: .contains("different from the previously recorded value"), severity: .warning)
        }

        // Storage should not be updated
        let packageSigners = try await signingEntityStorage.get(
            package: package.underlying,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
        XCTAssertEqual(packageSigners.signers.count, 1)
        XCTAssertEqual(packageSigners.signers[existingSigningEntity]?.versions, [version])
    }

    func testPackageVersionLosingSigningEntity_strictMode() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("1.1.1")
        let existingSigningEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Smith",
            organizationalUnit: "SwiftPM Test Unit",
            organization: "SwiftPM Test"
        )

        let signingEntityStorage = MockPackageSigningEntityStorage(
            [package.underlying: PackageSigners(
                expectedSigner: .none,
                signers: [existingSigningEntity: PackageSigner(
                    signingEntity: existingSigningEntity,
                    origins: [.registry(registry.url)],
                    versions: [version]
                )]
            )]
        )
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict // intended for this test; don't change

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // Storage has "J. Smith" as signer for package version.
        // The given signer is nil which is different so it should fail.
        await XCTAssertAsyncThrowsError(
            try await tofu.validate(
                registry: registry,
                package: package,
                version: version,
                signingEntity: .none
            )
        ) { error in
            guard case RegistryError.signingEntityForReleaseChanged(_, _, _, let latest, let previous) = error else {
                return XCTFail("Expected RegistryError.signingEntityForReleaseChanged, got '\(error)'")
            }
            XCTAssertNil(latest)
            XCTAssertEqual(previous, existingSigningEntity)
        }

        // Storage should not be updated
        let packageSigners = try await signingEntityStorage.get(
            package: package.underlying,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
        XCTAssertEqual(packageSigners.signers.count, 1)
        XCTAssertEqual(packageSigners.signers[existingSigningEntity]?.versions, [version])
    }

    func testSigningEntityMatchesStorageForDifferentVersion() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("1.1.1")
        let existingVersion = Version("2.0.0")
        let signingEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit",
            organization: "SwiftPM Test"
        )

        let signingEntityStorage = MockPackageSigningEntityStorage(
            [package.underlying: PackageSigners(
                expectedSigner: .none,
                signers: [signingEntity: PackageSigner(
                    signingEntity: signingEntity,
                    origins: [.registry(registry.url)],
                    versions: [existingVersion]
                )]
            )]
        )
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // Storage has "J. Appleseed" as signer for package v2.0.0.
        // Signer remaining the same should be ok.
        _ = try await tofu.validate(
            registry: registry,
            package: package,
            version: version,
            signingEntity: signingEntity
        )

        // Storage should be updated with version 1.1.1 added
        let packageSigners = try await signingEntityStorage.get(
            package: package.underlying,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
        XCTAssertEqual(packageSigners.signers.count, 1)
        XCTAssertEqual(packageSigners.signers[signingEntity]?.versions, [existingVersion, version])
    }

    func testSigningEntityDoesNotMatchStorageForDifferentVersion_strictMode() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("1.1.1")
        let existingVersion = Version("2.0.0")
        let signingEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit 1",
            organization: "SwiftPM Test"
        )
        let existingSigningEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Smith",
            organizationalUnit: "SwiftPM Test Unit 2",
            organization: "SwiftPM Test"
        )

        let signingEntityStorage = MockPackageSigningEntityStorage(
            [package.underlying: PackageSigners(
                expectedSigner: .none,
                signers: [existingSigningEntity: PackageSigner(
                    signingEntity: existingSigningEntity,
                    origins: [.registry(registry.url)],
                    versions: [existingVersion]
                )]
            )]
        )
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict // intended for this test; don't change

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // Storage has "J. Smith" as signer for package v2.0.0.
        // The given signer "J. Appleseed" is different so it should fail.
        await XCTAssertAsyncThrowsError(
            try await tofu.validate(
                registry: registry,
                package: package,
                version: version,
                signingEntity: signingEntity
            )
        ) { error in
            guard case RegistryError.signingEntityForPackageChanged(
                _,
                _,
                _,
                let latest,
                let previous,
                let previousVersion
            ) = error else {
                return XCTFail("Expected RegistryError.signingEntityForPackageChanged, got '\(error)'")
            }
            XCTAssertEqual(latest, signingEntity)
            XCTAssertEqual(previous, existingSigningEntity)
            XCTAssertEqual(previousVersion, existingVersion)
        }

        // Storage should not be updated
        let packageSigners = try await signingEntityStorage.get(
            package: package.underlying,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
        XCTAssertEqual(packageSigners.signers.count, 1)
        XCTAssertEqual(packageSigners.signers[existingSigningEntity]?.versions, [existingVersion])
    }

    func testSigningEntityDoesNotMatchStorageForDifferentVersion_warnMode() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("1.1.1")
        let existingVersion = Version("2.0.0")
        let signingEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit 1",
            organization: "SwiftPM Test"
        )
        let existingSigningEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Smith",
            organizationalUnit: "SwiftPM Test Unit 2",
            organization: "SwiftPM Test"
        )

        let signingEntityStorage = MockPackageSigningEntityStorage(
            [package.underlying: PackageSigners(
                expectedSigner: .none,
                signers: [existingSigningEntity: PackageSigner(
                    signingEntity: existingSigningEntity,
                    origins: [.registry(registry.url)],
                    versions: [existingVersion]
                )]
            )]
        )
        let signingEntityCheckingMode = SigningEntityCheckingMode.warn // intended for this test; don't change

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let observability = ObservabilitySystem.makeForTesting()

        // Storage has "J. Smith" as signer for package v2.0.0.
        // The given signer "J. Appleseed" is different, but because
        // of .warn mode, no error is thrown.
        _ = try await tofu.validate(
            registry: registry,
            package: package,
            version: version,
            signingEntity: signingEntity,
            observabilityScope: observability.topScope
        )

        // But there should be a warning
        testDiagnostics(observability.diagnostics) { result in
            result.check(diagnostic: .contains("different from the previously recorded value"), severity: .warning)
        }

        // Storage should not be updated
        let packageSigners = try await signingEntityStorage.get(
            package: package.underlying,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
        XCTAssertEqual(packageSigners.signers.count, 1)
        XCTAssertEqual(packageSigners.signers[existingSigningEntity]?.versions, [existingVersion])
    }

    func testNilSigningEntityWhenStorageHasNewerSignedVersions() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("1.1.1")
        let existingVersions = Set([Version("1.5.0"), Version("2.0.0")])
        let existingSigningEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Smith",
            organizationalUnit: "SwiftPM Test Unit",
            organization: "SwiftPM Test"
        )

        let signingEntityStorage = MockPackageSigningEntityStorage(
            [package.underlying: PackageSigners(
                expectedSigner: .none,
                signers: [existingSigningEntity: PackageSigner(
                    signingEntity: existingSigningEntity,
                    origins: [.registry(registry.url)],
                    versions: existingVersions
                )]
            )]
        )
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // Storage has versions 1.5.0 and 2.0.0 signed. The given version 1.1.1 is
        // "older" than both, and we allow nil signer in this case, assuming
        // this is before package started being signed.
        _ = try await tofu.validate(
            registry: registry,
            package: package,
            version: version,
            signingEntity: .none
        )

        // Storage should not be updated
        let packageSigners = try await signingEntityStorage.get(
            package: package.underlying,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
        XCTAssertEqual(packageSigners.signers.count, 1)
        XCTAssertEqual(packageSigners.signers[existingSigningEntity]?.versions, existingVersions)
    }

    func testNilSigningEntityWhenStorageHasOlderSignedVersions_strictMode() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("1.6.1")
        let existingVersions = Set([Version("1.5.0"), Version("2.0.0")])
        let existingSigningEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Smith",
            organizationalUnit: "SwiftPM Test Unit",
            organization: "SwiftPM Test"
        )

        let signingEntityStorage = MockPackageSigningEntityStorage(
            [package.underlying: PackageSigners(
                expectedSigner: .none,
                signers: [existingSigningEntity: PackageSigner(
                    signingEntity: existingSigningEntity,
                    origins: [.registry(registry.url)],
                    versions: existingVersions
                )]
            )]
        )
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict // intended for this test; don't change

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // Storage has versions 1.5.0 and 2.0.0 signed. The given version 1.6.1 is
        // "newer" than 1.5.0, which we don't allow, because we assume from 1.5.0
        // onwards all versions are signed.
        await XCTAssertAsyncThrowsError(
            try await tofu.validate(
                registry: registry,
                package: package,
                version: version,
                signingEntity: .none
            )
        ) { error in
            guard case RegistryError.signingEntityForPackageChanged(
                _,
                _,
                _,
                let latest,
                let previous,
                let previousVersion
            ) = error else {
                return XCTFail("Expected RegistryError.signingEntityForPackageChanged, got '\(error)'")
            }
            XCTAssertNil(latest)
            XCTAssertEqual(previous, existingSigningEntity)
            XCTAssertEqual(previousVersion, Version("1.5.0"))
        }

        // Storage should not be updated
        let packageSigners = try await signingEntityStorage.get(
            package: package.underlying,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
        XCTAssertEqual(packageSigners.signers.count, 1)
        XCTAssertEqual(packageSigners.signers[existingSigningEntity]?.versions, existingVersions)
    }

    func testNilSigningEntityWhenStorageHasOlderSignedVersions_warnMode() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("1.6.1")
        let existingVersions = Set([Version("1.5.0"), Version("2.0.0")])
        let existingSigningEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Smith",
            organizationalUnit: "SwiftPM Test Unit",
            organization: "SwiftPM Test"
        )

        let signingEntityStorage = MockPackageSigningEntityStorage(
            [package.underlying: PackageSigners(
                expectedSigner: .none,
                signers: [existingSigningEntity: PackageSigner(
                    signingEntity: existingSigningEntity,
                    origins: [.registry(registry.url)],
                    versions: existingVersions
                )]
            )]
        )
        let signingEntityCheckingMode = SigningEntityCheckingMode.warn // intended for this test; don't change

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let observability = ObservabilitySystem.makeForTesting()

        // Storage has versions 1.5.0 and 2.0.0 signed. The given version 1.6.1 is
        // "newer" than 1.5.0, which we don't allow, because we assume from 1.5.0
        // onwards all versions are signed. However, because of .warn mode,
        // no error is thrown.
        _ = try await tofu.validate(
            registry: registry,
            package: package,
            version: version,
            signingEntity: .none,
            observabilityScope: observability.topScope
        )

        // But there should be a warning
        testDiagnostics(observability.diagnostics) { result in
            result.check(diagnostic: .contains("different from the previously recorded value"), severity: .warning)
        }

        // Storage should not be updated
        let packageSigners = try await signingEntityStorage.get(
            package: package.underlying,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
        XCTAssertEqual(packageSigners.signers.count, 1)
        XCTAssertEqual(packageSigners.signers[existingSigningEntity]?.versions, existingVersions)
    }

    func testNilSigningEntityWhenStorageHasOlderSignedVersionsInDifferentMajorVersion() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("2.0.0")
        let existingVersions = Set([Version("1.5.0"), Version("3.0.0")])
        let existingSigningEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Smith",
            organizationalUnit: "SwiftPM Test Unit",
            organization: "SwiftPM Test"
        )

        let signingEntityStorage = MockPackageSigningEntityStorage(
            [package.underlying: PackageSigners(
                expectedSigner: .none,
                signers: [existingSigningEntity: PackageSigner(
                    signingEntity: existingSigningEntity,
                    origins: [.registry(registry.url)],
                    versions: existingVersions
                )]
            )]
        )
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // Storage has versions 1.5.0 and 3.0.0 signed. The given version 2.0.0 is
        // "newer" than 1.5.0, but in a different major version (i.e., 1.x vs. 2.x).
        // We allow this with the assumption that package signing might not have
        // begun until a later 2.x version, so until we encounter a signed 2.x version,
        // we assume none of them is signed.
        _ = try await tofu.validate(
            registry: registry,
            package: package,
            version: version,
            signingEntity: .none
        )

        // Storage should not be updated
        let packageSigners = try await signingEntityStorage.get(
            package: package.underlying,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
        XCTAssertEqual(packageSigners.signers.count, 1)
        XCTAssertEqual(packageSigners.signers[existingSigningEntity]?.versions, existingVersions)
    }

    func testSigningEntityOfNewerVersionMatchesExpectedSigner() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("2.0.0")
        let expectedSigningEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Smith",
            organizationalUnit: "SwiftPM Test Unit",
            organization: "SwiftPM Test"
        )
        let expectedFromVersion = Version("1.5.0")

        let signingEntityStorage = MockPackageSigningEntityStorage(
            [package.underlying: PackageSigners(
                expectedSigner: (signingEntity: expectedSigningEntity, fromVersion: expectedFromVersion),
                signers: [expectedSigningEntity: PackageSigner(
                    signingEntity: expectedSigningEntity,
                    origins: [.registry(registry.url)],
                    versions: [expectedFromVersion]
                )]
            )]
        )
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // Package has expected signer starting from v1.5.0.
        // The given v2.0.0 is newer than v1.5.0, and signer
        // matches the expected signer.
        _ = try await tofu.validate(
            registry: registry,
            package: package,
            version: version,
            signingEntity: expectedSigningEntity
        )

        // Storage should be updated with v2.0.0 added
        let packageSigners = try await signingEntityStorage.get(
            package: package.underlying,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
        XCTAssertEqual(packageSigners.signers.count, 1)
        XCTAssertEqual(packageSigners.signers[expectedSigningEntity]?.versions, [expectedFromVersion, version])
    }

    func testSigningEntityOfNewerVersionDoesNotMatchExpectedSignerButOlderThanExisting() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("2.0.0")
        let signingEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit 1",
            organization: "SwiftPM Test"
        )
        let existingVersion = Version("2.2.0")
        let expectedSigningEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Smith",
            organizationalUnit: "SwiftPM Test Unit 2",
            organization: "SwiftPM Test"
        )
        let expectedFromVersion = Version("1.5.0")

        let signingEntityStorage = MockPackageSigningEntityStorage(
            [package.underlying: PackageSigners(
                expectedSigner: (signingEntity: expectedSigningEntity, fromVersion: expectedFromVersion),
                signers: [
                    expectedSigningEntity: PackageSigner(
                        signingEntity: expectedSigningEntity,
                        origins: [.registry(registry.url)],
                        versions: [expectedFromVersion]
                    ),
                    signingEntity: PackageSigner(
                        signingEntity: signingEntity,
                        origins: [.registry(registry.url)],
                        versions: [existingVersion]
                    ),
                ]
            )]
        )
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // Package has expected signer starting from v1.5.0, but
        // the given signer was recorded previously for v2.2.0.
        // The given v2.0.0 is before v2.2.0, and we allow the same
        // signer for older versions.
        _ = try await tofu.validate(
            registry: registry,
            package: package,
            version: version,
            signingEntity: signingEntity
        )

        // Storage should be updated with v2.0.0 added
        let packageSigners = try await signingEntityStorage.get(
            package: package.underlying,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
        XCTAssertEqual(packageSigners.signers.count, 2)
        XCTAssertEqual(packageSigners.signers[expectedSigningEntity]?.versions, [expectedFromVersion])
        XCTAssertEqual(packageSigners.signers[signingEntity]?.versions, [existingVersion, version])
    }

    func testSigningEntityOfNewerVersionDoesNotMatchExpectedSignerAndNewerThanExisting() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("2.3.0")
        let signingEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit 1",
            organization: "SwiftPM Test"
        )
        let existingVersion = Version("2.2.0")
        let expectedSigningEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Smith",
            organizationalUnit: "SwiftPM Test Unit 2",
            organization: "SwiftPM Test"
        )
        let expectedFromVersion = Version("1.5.0")

        let signingEntityStorage = MockPackageSigningEntityStorage(
            [package.underlying: PackageSigners(
                expectedSigner: (signingEntity: expectedSigningEntity, fromVersion: expectedFromVersion),
                signers: [
                    expectedSigningEntity: PackageSigner(
                        signingEntity: expectedSigningEntity,
                        origins: [.registry(registry.url)],
                        versions: [expectedFromVersion]
                    ),
                    signingEntity: PackageSigner(
                        signingEntity: signingEntity,
                        origins: [.registry(registry.url)],
                        versions: [existingVersion]
                    ),
                ]
            )]
        )
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // Package has expected signer starting from v1.5.0, and
        // the given signer was recorded previously for v2.2.0, but
        // the given v2.3.0 is after v2.2.0, which we don't allow
        // because we assume the signer has "stopped" signing at v2.2.0.
        await XCTAssertAsyncThrowsError(
            try await tofu.validate(
                registry: registry,
                package: package,
                version: version,
                signingEntity: signingEntity
            )
        ) { error in
            guard case RegistryError.signingEntityForPackageChanged(
                _,
                _,
                _,
                let latest,
                let previous,
                let previousVersion
            ) = error else {
                return XCTFail("Expected RegistryError.signingEntityForPackageChanged, got '\(error)'")
            }
            XCTAssertEqual(latest, signingEntity)
            XCTAssertEqual(previous, expectedSigningEntity)
            XCTAssertEqual(previousVersion, expectedFromVersion)
        }

        // Storage should not be updated
        let packageSigners = try await signingEntityStorage.get(
            package: package.underlying,
            observabilityScope: ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
        XCTAssertEqual(packageSigners.signers.count, 2)
        XCTAssertEqual(packageSigners.signers[expectedSigningEntity]?.versions, [expectedFromVersion])
        XCTAssertEqual(packageSigners.signers[signingEntity]?.versions, [existingVersion])
    }

    func testWriteConflictsWithStorage_strictMode() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("1.1.1")
        let signingEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit",
            organization: "SwiftPM Test"
        )

        let signingEntityStorage = WriteConflictSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.strict // intended for this test; don't change

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        // This triggers a storage write conflict
        await XCTAssertAsyncThrowsError(
            try await tofu.validate(
                registry: registry,
                package: package,
                version: version,
                signingEntity: signingEntity
            )
        ) { error in
            guard case RegistryError.signingEntityForReleaseChanged = error else {
                return XCTFail("Expected RegistryError.signingEntityForReleaseChanged, got '\(error)'")
            }
        }
    }

    func testWriteConflictsWithStorage_warnMode() async throws {
        let registry = Registry(url: URL("https://packages.example.com"), supportsAvailability: false)
        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let version = Version("1.1.1")
        let signingEntity = SigningEntity.recognized(
            type: .adp,
            name: "J. Appleseed",
            organizationalUnit: "SwiftPM Test Unit",
            organization: "SwiftPM Test"
        )

        let signingEntityStorage = WriteConflictSigningEntityStorage()
        let signingEntityCheckingMode = SigningEntityCheckingMode.warn // intended for this test; don't change

        let tofu = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )

        let observability = ObservabilitySystem.makeForTesting()

        // This triggers a storage write conflict, but
        // because of .warn mode, no error is thrown.
        _ = try await tofu.validate(
            registry: registry,
            package: package,
            version: version,
            signingEntity: signingEntity,
            observabilityScope: observability.topScope
        )

        // But there should be a warning
        testDiagnostics(observability.diagnostics) { result in
            result.check(diagnostic: .contains("different from the previously recorded value"), severity: .warning)
        }
    }
}

extension PackageSigningEntityTOFU {
    fileprivate func validate(
        registry: Registry,
        package: PackageIdentity.RegistryIdentity,
        version: Version,
        signingEntity: SigningEntity?,
        observabilityScope: ObservabilityScope? = nil
    ) async throws {
        try await self.validate(
            registry: registry,
            package: package,
            version: version,
            signingEntity: signingEntity,
            observabilityScope: observabilityScope ?? ObservabilitySystem.NOOP,
            callbackQueue: .sharedConcurrent
        )
    }
}

private class WriteConflictSigningEntityStorage: PackageSigningEntityStorage {
    public func get(
        package: PackageIdentity,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        callback: @escaping (Result<PackageSigners, Error>) -> Void
    ) {
        callback(.success(PackageSigners()))
    }

    public func put(
        package: PackageIdentity,
        version: Version,
        signingEntity: SigningEntity,
        origin: SigningEntity.Origin,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        callback: @escaping (Result<Void, Error>) -> Void
    ) {
        let existing = SigningEntity.recognized(
            type: .adp,
            name: "xxx-\(signingEntity.name ?? "")",
            organizationalUnit: "xxx-\(signingEntity.organizationalUnit ?? "")",
            organization: "xxx-\(signingEntity.organization ?? "")"
        )
        callback(.failure(PackageSigningEntityStorageError.conflict(
            package: package,
            version: version,
            given: signingEntity,
            existing: existing
        )))
    }

    public func add(
        package: PackageIdentity,
        version: Version,
        signingEntity: SigningEntity,
        origin: SigningEntity.Origin,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        callback: @escaping (Result<Void, Error>) -> Void
    ) {
        callback(.failure(StringError("unexpected call")))
    }

    public func changeSigningEntityFromVersion(
        package: PackageIdentity,
        version: Version,
        signingEntity: SigningEntity,
        origin: SigningEntity.Origin,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        callback: @escaping (Result<Void, Error>) -> Void
    ) {
        callback(.failure(StringError("unexpected call")))
    }

    public func changeSigningEntityForAllVersions(
        package: PackageIdentity,
        version: Version,
        signingEntity: SigningEntity,
        origin: SigningEntity.Origin,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        callback: @escaping (Result<Void, Error>) -> Void
    ) {
        callback(.failure(StringError("unexpected call")))
    }
}

extension SigningEntity {
    var name: String? {
        switch self {
        case .recognized(_, let name, _, _):
            return name
        case .unrecognized(let name, _, _):
            return name
        }
    }

    var organizationalUnit: String? {
        switch self {
        case .recognized(_, _, let organizationalUnit, _):
            return organizationalUnit
        case .unrecognized(_, let organizationalUnit, _):
            return organizationalUnit
        }
    }

    var organization: String? {
        switch self {
        case .recognized(_, _, _, let organization):
            return organization
        case .unrecognized(_, _, let organization):
            return organization
        }
    }
}
