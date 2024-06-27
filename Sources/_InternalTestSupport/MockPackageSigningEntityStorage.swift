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
import Dispatch
import class Foundation.NSLock
import PackageModel
import PackageSigning

import struct TSCUtility.Version

public class MockPackageSigningEntityStorage: PackageSigningEntityStorage {
    private var packageSigners: [PackageIdentity: PackageSigners]
    private let lock = NSLock()

    public init(_ packageSigners: [PackageIdentity: PackageSigners] = [:]) {
        self.packageSigners = packageSigners
    }
    
    public func get(
        package: PackageIdentity,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue
    ) async throws -> PackageSigners {
        try await safe_async {
            self.get(
                package: package,
                observabilityScope: observabilityScope,
                callbackQueue: callbackQueue,
                callback: $0
            )
        }
    }

    @available(*, noasync, message: "Use the async alternative")
    public func get(
        package: PackageIdentity,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        callback: @escaping (Result<PackageSigners, Error>) -> Void
    ) {
        if let packageSigners = self.lock.withLock({ self.packageSigners[package] }) {
            callbackQueue.async {
                callback(.success(packageSigners))
            }
        } else {
            callbackQueue.async {
                callback(.success(PackageSigners()))
            }
        }
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
        do {
            try self.lock.withLock {
                let otherSigningEntities = self.packageSigners[package]?.signingEntities(of: version)
                    .filter { $0 != signingEntity } ?? []
                // Error if we try to write a different signing entity for a version
                guard otherSigningEntities.isEmpty else {
                    throw PackageSigningEntityStorageError.conflict(
                        package: package,
                        version: version,
                        given: signingEntity,
                        existing: otherSigningEntities.first! // !-safe because otherSigningEntities is not empty
                    )
                }

                try self.addSigner(
                    package: package,
                    signingEntity: signingEntity,
                    origin: origin,
                    version: version
                )
            }

            callbackQueue.async {
                callback(.success(()))
            }
        } catch {
            callbackQueue.async {
                callback(.failure(error))
            }
        }
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
        do {
            try self.lock.withLock {
                try self.addSigner(
                    package: package,
                    signingEntity: signingEntity,
                    origin: origin,
                    version: version
                )
            }
            callback(.success(()))
        } catch {
            callbackQueue.async {
                callback(.failure(error))
            }
        }
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
        do {
            try self.lock.withLock {
                self.setExpectedSigner(
                    package: package,
                    expectedSigningEntity: signingEntity,
                    expectedFromVersion: version
                )
                try self.addSigner(
                    package: package,
                    signingEntity: signingEntity,
                    origin: origin,
                    version: version
                )
            }
            callback(.success(()))
        } catch {
            callbackQueue.async {
                callback(.failure(error))
            }
        }
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
        do {
            try self.lock.withLock {
                self.setExpectedSigner(
                    package: package,
                    expectedSigningEntity: signingEntity,
                    expectedFromVersion: version
                )
                // Delete all other signers
                if let existing = self.packageSigners[package] {
                    self.packageSigners[package] = PackageSigners(
                        expectedSigner: existing.expectedSigner,
                        signers: existing.signers.filter { $0.key == signingEntity }
                    )
                }
                try self.addSigner(
                    package: package,
                    signingEntity: signingEntity,
                    origin: origin,
                    version: version
                )
            }
            callback(.success(()))
        } catch {
            callbackQueue.async {
                callback(.failure(error))
            }
        }
    }

    private func setExpectedSigner(
        package: PackageIdentity,
        expectedSigningEntity: SigningEntity,
        expectedFromVersion: Version
    ) {
        self.packageSigners[package] = PackageSigners(
            expectedSigner: (signingEntity: expectedSigningEntity, fromVersion: expectedFromVersion),
            signers: self.packageSigners[package]?.signers ?? [:]
        )
    }

    private func addSigner(
        package: PackageIdentity,
        signingEntity: SigningEntity,
        origin: SigningEntity.Origin,
        version: Version
    ) throws {
        guard case .recognized = signingEntity else {
            throw PackageSigningEntityStorageError.unrecognizedSigningEntity(signingEntity)
        }

        let packageSigners = self.packageSigners[package] ?? PackageSigners()

        let packageSigner: PackageSigner
        if let existingSigner = packageSigners.signers[signingEntity] {
            var origins = existingSigner.origins
            origins.insert(origin)
            var versions = existingSigner.versions
            versions.insert(version)
            packageSigner = PackageSigner(
                signingEntity: signingEntity,
                origins: origins,
                versions: versions
            )
        } else {
            packageSigner = PackageSigner(
                signingEntity: signingEntity,
                origins: [origin],
                versions: [version]
            )
        }

        var signers = packageSigners.signers
        signers[signingEntity] = packageSigner

        self.packageSigners[package] = PackageSigners(
            expectedSigner: packageSigners.expectedSigner,
            signers: signers
        )
    }
}
