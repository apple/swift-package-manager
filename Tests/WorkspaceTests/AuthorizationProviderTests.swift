//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@testable import Basics
import _InternalTestSupport
import Workspace
import XCTest

final class AuthorizationProviderTests: XCTestCase {
    func testNetrcAuthorizationProviders() throws {
        let observability = ObservabilitySystem.makeForTesting()

        // custom .netrc file
        do {
            let fileSystem: FileSystem = InMemoryFileSystem()

            let customPath = try fileSystem.homeDirectory.appending(components: UUID().uuidString, "custom-netrc-file")
            try fileSystem.createDirectory(customPath.parentDirectory, recursive: true)
            try fileSystem.writeFileContents(
                customPath,
                string: "machine mymachine.labkey.org login custom@labkey.org password custom"
            )

            let configuration = Workspace.Configuration.Authorization(netrc: .custom(customPath), keychain: .disabled)
            let authorizationProvider = try configuration.makeAuthorizationProvider(fileSystem: fileSystem, observabilityScope: observability.topScope) as? CompositeAuthorizationProvider
            let netrcProviders = authorizationProvider?.providers.compactMap { $0 as? NetrcAuthorizationProvider }

            XCTAssertEqual(netrcProviders?.count, 1)
            XCTAssertEqual(try netrcProviders?.first.map { try resolveSymlinks($0.path) }, try resolveSymlinks(customPath))

            let auth = authorizationProvider?.authentication(for: "https://mymachine.labkey.org")
            XCTAssertEqual(auth?.user, "custom@labkey.org")
            XCTAssertEqual(auth?.password, "custom")

            // delete it
            try fileSystem.removeFileTree(customPath)
            XCTAssertThrowsError(try configuration.makeAuthorizationProvider(fileSystem: fileSystem, observabilityScope: observability.topScope), "error expected") { error in
                XCTAssertEqual(error as? StringError, StringError("Did not find netrc file at \(customPath)."))
            }
        }

        // user .netrc file
        do {
            let fileSystem = InMemoryFileSystem()

            let userPath = try fileSystem.homeDirectory.appending(".netrc")
            try fileSystem.createDirectory(userPath.parentDirectory, recursive: true)
            try fileSystem.writeFileContents(
                userPath,
                string: "machine mymachine.labkey.org login user@labkey.org password user"
            )

            let configuration = Workspace.Configuration.Authorization(netrc: .user, keychain: .disabled)
            let authorizationProvider = try configuration.makeAuthorizationProvider(fileSystem: fileSystem, observabilityScope: observability.topScope) as? CompositeAuthorizationProvider
            let netrcProviders = authorizationProvider?.providers.compactMap { $0 as? NetrcAuthorizationProvider }

            XCTAssertEqual(netrcProviders?.count, 1)
            XCTAssertEqual(try netrcProviders?.first.map { try resolveSymlinks($0.path) }, try resolveSymlinks(userPath))

            let auth = authorizationProvider?.authentication(for: "https://mymachine.labkey.org")
            XCTAssertEqual(auth?.user, "user@labkey.org")
            XCTAssertEqual(auth?.password, "user")

            // delete it
            do {
                try fileSystem.removeFileTree(userPath)
                let authorizationProvider = try configuration.makeAuthorizationProvider(fileSystem: fileSystem, observabilityScope: observability.topScope) as? CompositeAuthorizationProvider
                XCTAssertNil(authorizationProvider)
            }
        }
    }

    func testRegistryNetrcAuthorizationProviders() throws {
        let observability = ObservabilitySystem.makeForTesting()

        // custom .netrc file

        do {
            let fileSystem: FileSystem = InMemoryFileSystem()

            let customPath = try fileSystem.homeDirectory.appending(components: UUID().uuidString, "custom-netrc-file")
            try fileSystem.createDirectory(customPath.parentDirectory, recursive: true)
            try fileSystem.writeFileContents(
                customPath,
                string: "machine mymachine.labkey.org login custom@labkey.org password custom"
            )

            let configuration = Workspace.Configuration.Authorization(netrc: .custom(customPath), keychain: .disabled)
            let netrcProvider = try configuration.makeRegistryAuthorizationProvider(fileSystem: fileSystem, observabilityScope: observability.topScope) as? NetrcAuthorizationProvider

            XCTAssertNotNil(netrcProvider)
            XCTAssertEqual(try netrcProvider.map { try resolveSymlinks($0.path) }, try resolveSymlinks(customPath))

            let auth = netrcProvider?.authentication(for: "https://mymachine.labkey.org")
            XCTAssertEqual(auth?.user, "custom@labkey.org")
            XCTAssertEqual(auth?.password, "custom")

            // delete it
            try fileSystem.removeFileTree(customPath)
            XCTAssertThrowsError(try configuration.makeRegistryAuthorizationProvider(fileSystem: fileSystem, observabilityScope: observability.topScope), "error expected") { error in
                XCTAssertEqual(error as? StringError, StringError("did not find netrc file at \(customPath)"))
            }
        }

        // user .netrc file

        do {
            let fileSystem = InMemoryFileSystem()

            let userPath = try fileSystem.homeDirectory.appending(".netrc")
            try fileSystem.createDirectory(userPath.parentDirectory, recursive: true)
            try fileSystem.writeFileContents(
                userPath,
                string: "machine mymachine.labkey.org login user@labkey.org password user"
            )

            let configuration = Workspace.Configuration.Authorization(netrc: .user, keychain: .disabled)
            let netrcProvider = try configuration.makeRegistryAuthorizationProvider(fileSystem: fileSystem, observabilityScope: observability.topScope) as? NetrcAuthorizationProvider

            XCTAssertNotNil(netrcProvider)
            XCTAssertEqual(try netrcProvider.map { try resolveSymlinks($0.path) }, try resolveSymlinks(userPath))

            let auth = netrcProvider?.authentication(for: "https://mymachine.labkey.org")
            XCTAssertEqual(auth?.user, "user@labkey.org")
            XCTAssertEqual(auth?.password, "user")

            // delete it
            do {
                try fileSystem.removeFileTree(userPath)
                let authorizationProvider = try configuration.makeRegistryAuthorizationProvider(fileSystem: fileSystem, observabilityScope: observability.topScope) as? NetrcAuthorizationProvider
                // Even if user .netrc file doesn't exist, the provider will be non-nil but contain no data.
                XCTAssertNotNil(authorizationProvider)
                XCTAssertEqual(try authorizationProvider.map { try resolveSymlinks($0.path) }, try resolveSymlinks(userPath))

                XCTAssertTrue(authorizationProvider!.machines.isEmpty)
            }
        }
    }
}
