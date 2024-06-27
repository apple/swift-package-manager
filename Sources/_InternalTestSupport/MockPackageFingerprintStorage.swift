//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Dispatch
import class Foundation.NSLock
import PackageFingerprint
import PackageModel

import struct TSCUtility.Version

public class MockPackageFingerprintStorage: PackageFingerprintStorage {
    private var packageFingerprints: [PackageIdentity: [Version: [Fingerprint
            .Kind: [Fingerprint.ContentType: Fingerprint]]]]
    private let lock = NSLock()

    public init(_ packageFingerprints: [PackageIdentity: [Version: [Fingerprint
            .Kind: [Fingerprint.ContentType: Fingerprint]]]] = [:])
    {
        self.packageFingerprints = packageFingerprints
    }

    public func get(
        package: PackageIdentity,
        version: Version,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        callback: @escaping (Result<[Fingerprint.Kind: [Fingerprint.ContentType: Fingerprint]], Error>) -> Void
    ) {
        if let fingerprints = self.lock.withLock({ self.packageFingerprints[package]?[version] }) {
            callbackQueue.async {
                callback(.success(fingerprints))
            }
        } else {
            callbackQueue.async {
                callback(.failure(PackageFingerprintStorageError.notFound))
            }
        }
    }

    public func put(
        package: PackageIdentity,
        version: Version,
        fingerprint: Fingerprint,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        callback: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            try self.lock.withLock {
                var versionFingerprints = self.packageFingerprints.removeValue(forKey: package) ?? [:]
                var fingerprintsForVersion = versionFingerprints.removeValue(forKey: version) ?? [:]
                var fingerprintsForKind = fingerprintsForVersion.removeValue(forKey: fingerprint.origin.kind) ?? [:]

                if let existing = fingerprintsForKind[fingerprint.contentType] {
                    // Error if we try to write a different fingerprint
                    guard fingerprint == existing else {
                        throw PackageFingerprintStorageError.conflict(given: fingerprint, existing: existing)
                    }
                    // Don't need to do anything if fingerprints are the same
                    return
                }

                fingerprintsForKind[fingerprint.contentType] = fingerprint
                fingerprintsForVersion[fingerprint.origin.kind] = fingerprintsForKind
                versionFingerprints[version] = fingerprintsForVersion
                self.packageFingerprints[package] = versionFingerprints
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

    public func get(
        package: PackageReference,
        version: Version,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        callback: @escaping (Result<[Fingerprint.Kind: [Fingerprint.ContentType: Fingerprint]], Error>) -> Void
    ) {
        self.get(
            package: package.identity,
            version: version,
            observabilityScope: observabilityScope,
            callbackQueue: callbackQueue,
            callback: callback
        )
    }

    public func put(
        package: PackageReference,
        version: Version,
        fingerprint: Fingerprint,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        callback: @escaping (Result<Void, Error>) -> Void
    ) {
        self.put(
            package: package.identity,
            version: version,
            fingerprint: fingerprint,
            observabilityScope: observabilityScope,
            callbackQueue: callbackQueue,
            callback: callback
        )
    }
}
