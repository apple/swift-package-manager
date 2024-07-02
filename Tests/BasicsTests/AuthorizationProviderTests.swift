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

@testable import Basics
import SPMTestSupport
import XCTest

final class AuthorizationProviderTests: XCTestCase {
    func testBasicAPIs() {
        let url = URL("http://\(UUID().uuidString)")
        let user = UUID().uuidString
        let password = UUID().uuidString

        let provider = TestProvider(map: [url: (user: user, password: password)])
        self.assertAuthentication(provider, for: url, expected: (user, password))
    }

    func testNetrc() async throws {
        try await testWithTemporaryDirectory { tmpPath in
            let netrcPath = tmpPath.appending(".netrc")

            let provider = try NetrcAuthorizationProvider(path: netrcPath, fileSystem: localFileSystem)

            let user = UUID().uuidString

            let url = URL("http://\(UUID().uuidString)")
            let password = UUID().uuidString

            let otherURL = URL("https://\(UUID().uuidString)")
            let otherPassword = UUID().uuidString

            // Add
            try await provider.addOrUpdate(for: url, user: user, password: password)
            try await provider.addOrUpdate(for: otherURL, user: user, password: otherPassword)

            self.assertAuthentication(provider, for: url, expected: (user, password))

            // Update - the new password is appended to the end of file
            let newPassword = UUID().uuidString
            try await provider.addOrUpdate(for: url, user: user, password: newPassword)

            // .netrc file now contains two entries for `url`: one with `password` and the other with `newPassword`.
            // `NetrcAuthorizationProvider` returns the last entry it finds.
            self.assertAuthentication(provider, for: url, expected: (user, newPassword))

            // Make sure the previous entry is still there
            XCTAssertNotNil(
                provider.machines.first(where: {
                    $0.name == url.host!.lowercased() && $0.login == user && $0.password == password
                })
            )

            self.assertAuthentication(provider, for: otherURL, expected: (user, otherPassword))
        }
    }

    func testBasicAPIsBearerToken() {
        let url = URL("http://\(UUID().uuidString)")
        let user = "token"
        let token = UUID().uuidString

        let provider = TestProvider(map: [url: (user: user, password: token)])
        self.assertBearerAuthentication(provider, for: url, expected: token)
    }

    func testProtocolHostPort() throws {
        #if !canImport(Security)
        try XCTSkipIf(true)
        #else
        do {
            let url = URL("http://localhost")
            let parsed = KeychainAuthorizationProvider.ProtocolHostPort(from: url)
            XCTAssertNotNil(parsed)
            XCTAssertEqual(parsed?.protocol, "http")
            XCTAssertEqual(parsed?.host, "localhost")
            XCTAssertNil(parsed?.port)
            XCTAssertEqual(parsed?.protocolCFString, kSecAttrProtocolHTTP)
            XCTAssertEqual(parsed?.description, "http://localhost")
        }

        do {
            let url = URL("http://localhost:8080")
            let parsed = KeychainAuthorizationProvider.ProtocolHostPort(from: url)
            XCTAssertNotNil(parsed)
            XCTAssertEqual(parsed?.protocol, "http")
            XCTAssertEqual(parsed?.host, "localhost")
            XCTAssertEqual(parsed?.port, 8080)
            XCTAssertEqual(parsed?.protocolCFString, kSecAttrProtocolHTTP)
            XCTAssertEqual(parsed?.description, "http://localhost:8080")
        }

        do {
            let url = URL("https://localhost")
            let parsed = KeychainAuthorizationProvider.ProtocolHostPort(from: url)
            XCTAssertNotNil(parsed)
            XCTAssertEqual(parsed?.protocol, "https")
            XCTAssertEqual(parsed?.host, "localhost")
            XCTAssertNil(parsed?.port)
            XCTAssertEqual(parsed?.protocolCFString, kSecAttrProtocolHTTPS)
            XCTAssertEqual(parsed?.description, "https://localhost")
        }

        do {
            let url = URL("https://localhost:8080")
            let parsed = KeychainAuthorizationProvider.ProtocolHostPort(from: url)
            XCTAssertNotNil(parsed)
            XCTAssertEqual(parsed?.protocol, "https")
            XCTAssertEqual(parsed?.host, "localhost")
            XCTAssertEqual(parsed?.port, 8080)
            XCTAssertEqual(parsed?.protocolCFString, kSecAttrProtocolHTTPS)
            XCTAssertEqual(parsed?.description, "https://localhost:8080")
        }

        do {
            let url = URL("https://:8080")
            let parsed = KeychainAuthorizationProvider.ProtocolHostPort(from: url)
            XCTAssertNil(parsed)
        }
        #endif
    }

    func testKeychain_protocol() throws {
        #if !canImport(Security) || !ENABLE_KEYCHAIN_TEST
        try XCTSkipIf(true)
        #else
        let provider = KeychainAuthorizationProvider(observabilityScope: ObservabilitySystem.NOOP)

        let user = UUID().uuidString

        let httpURL = URL("http://\(UUID().uuidString)")
        let httpPassword = UUID().uuidString

        let httpsURL = URL("https://\(UUID().uuidString)")
        let httpsPassword = UUID().uuidString

        // Add
        try await provider.addOrUpdate(for: httpURL, user: user, password: httpPassword)
        try await provider.addOrUpdate(for: httpsURL, user: user, password: httpsPassword)

        self.assertAuthentication(provider, for: httpURL, expected: (user, httpPassword))
        self.assertAuthentication(provider, for: httpsURL, expected: (user, httpsPassword))

        // Update
        let newHTTPPassword = UUID().uuidString
        try await provider.addOrUpdate(for: httpURL, user: user, password: newHTTPPassword)

        let newHTTPSPassword = UUID().uuidString
        try await provider.addOrUpdate(for: httpsURL, user: user, password: newHTTPSPassword)


        // Existing password is updated
        self.assertAuthentication(provider, for: httpURL, expected: (user, newHTTPPassword))
        self.assertAuthentication(provider, for: httpsURL, expected: (user, newHTTPSPassword))

        // Delete
        try await provider.remove(for: httpURL)
        XCTAssertNil(provider.authentication(for: httpURL))
        self.assertAuthentication(provider, for: httpsURL, expected: (user, newHTTPSPassword))

        try await provider.remove(for: httpsURL)
        XCTAssertNil(provider.authentication(for: httpsURL))
        #endif
    }

    func testKeychain_port() throws {
        #if !canImport(Security) || !ENABLE_KEYCHAIN_TEST
        try XCTSkipIf(true)
        #else
        let provider = KeychainAuthorizationProvider(observabilityScope: ObservabilitySystem.NOOP)

        let user = UUID().uuidString

        let noPortURL = URL("http://\(UUID().uuidString)")
        let noPortPassword = UUID().uuidString

        let portURL = URL("http://\(UUID().uuidString):8971")
        let portPassword = UUID().uuidString

        // Add
        try await provider.addOrUpdate(for: noPortURL, user: user, password: noPortPassword)
        try await provider.addOrUpdate(for: portURL, user: user, password: portPassword)

        self.assertAuthentication(provider, for: noPortURL, expected: (user, noPortPassword))
        self.assertAuthentication(provider, for: portURL, expected: (user, portPassword))

        // Update
        let newPortPassword = UUID().uuidString
        try await provider.addOrUpdate(for: portURL, user: user, password: newPortPassword)

        let newNoPortPassword = UUID().uuidString
        try await provider.addOrUpdate(for: noPortURL, user: user, password: newNoPortPassword)

        // Existing password is updated
        self.assertAuthentication(provider, for: portURL, expected: (user, newPortPassword))
        self.assertAuthentication(provider, for: noPortURL, expected: (user, newNoPortPassword))

        // Delete
        try await provider.remove(for: noPortURL)
        XCTAssertNil(provider.authentication(for: noPortURL))
        self.assertAuthentication(provider, for: portURL, expected: (user, newPortPassword))

        try await provider.remove(for: portURL)
        XCTAssertNil(provider.authentication(for: portURL))
        #endif
    }

    func testComposite() throws {
        let url = URL("http://\(UUID().uuidString)")
        let user = UUID().uuidString
        let passwordOne = UUID().uuidString
        let passwordTwo = UUID().uuidString

        let providerOne = TestProvider(map: [url: (user: user, password: passwordOne)])
        let providerTwo = TestProvider(map: [url: (user: user, password: passwordTwo)])

        do {
            // providerOne's password is returned first
            let provider = CompositeAuthorizationProvider(
                providerOne,
                providerTwo,
                observabilityScope: ObservabilitySystem.NOOP
            )
            self.assertAuthentication(provider, for: url, expected: (user, passwordOne))
        }

        do {
            // providerTwo's password is returned first
            let provider = CompositeAuthorizationProvider(
                providerTwo,
                providerOne,
                observabilityScope: ObservabilitySystem.NOOP
            )
            self.assertAuthentication(provider, for: url, expected: (user, passwordTwo))
        }

        do {
            // Neither has password
            let unknownURL = URL("http://\(UUID().uuidString)")
            let provider = CompositeAuthorizationProvider(
                providerOne,
                providerTwo,
                observabilityScope: ObservabilitySystem.NOOP
            )
            XCTAssertNil(provider.authentication(for: unknownURL))
        }
    }

    private func assertAuthentication(
        _ provider: AuthorizationProvider,
        for url: URL,
        expected: (user: String, password: String)
    ) {
        let authentication = provider.authentication(for: url)
        XCTAssertEqual(authentication?.user, expected.user)
        XCTAssertEqual(authentication?.password, expected.password)
        XCTAssertEqual(
            provider.httpAuthorizationHeader(for: url),
            "Basic " + Data("\(expected.user):\(expected.password)".utf8).base64EncodedString()
        )
    }

    private func assertBearerAuthentication(
        _ provider: AuthorizationProvider,
        for url: URL,
        expected: String
    ) {
        let authentication = provider.authentication(for: url)
        XCTAssertEqual(authentication?.user, "token")
        XCTAssertEqual(authentication?.password, expected)
        XCTAssertEqual(
            provider.httpAuthorizationHeader(for: url),
            "Bearer \(expected)"
        )
    }
}

private struct TestProvider: AuthorizationProvider {
    let map: [URL: (user: String, password: String)]

    func authentication(for url: URL) -> (user: String, password: String)? {
        self.map[url]
    }
}
