//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@testable import Basics
import Foundation
#if canImport(FoundationNetworking)
// TODO: this brings OpenSSL dependency` on Linux
// need to decide how to best deal with that
import FoundationNetworking
#endif
import _InternalTestSupport
import XCTest

import struct TSCBasic.ByteString
import enum TSCBasic.FileMode
import struct TSCBasic.FileSystemError

final class URLSessionHTTPClientTest: XCTestCase {
    func testHead() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = LegacyHTTPClient(handler: urlSession.execute)

        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])

        let responseStatus = 200
        let responseHeaders = [UUID().uuidString: UUID().uuidString]
        let responseBody = Data(UUID().uuidString.utf8)

        MockURLProtocol.onRequest("HEAD", url) { request in
            self.assertRequestHeaders(request.allHTTPHeaderFields, expected: requestHeaders)
            MockURLProtocol.respond(request, statusCode: responseStatus, headers: responseHeaders, body: responseBody)
        }

        let promise = XCTestExpectation(description: "completed")
        httpClient.head(url, headers: requestHeaders) { result in
            switch result {
            case .failure(let error):
                XCTFail("unexpected error \(error)")
            case .success(let response):
                XCTAssertEqual(response.statusCode, responseStatus)
                self.assertResponseHeaders(response.headers, expected: responseHeaders)
                XCTAssertEqual(response.body, responseBody)
            }
            promise.fulfill()
        }

        wait(for: [promise], timeout: 1.0)
    }

    func testGet() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = LegacyHTTPClient(handler: urlSession.execute)

        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])

        let responseStatus = 200
        let responseHeaders = [UUID().uuidString: UUID().uuidString]
        let responseBody = Data(UUID().uuidString.utf8)

        MockURLProtocol.onRequest("GET", url) { request in
            self.assertRequestHeaders(request.allHTTPHeaderFields, expected: requestHeaders)
            MockURLProtocol.respond(request, statusCode: responseStatus, headers: responseHeaders, body: responseBody)
        }

        let promise = XCTestExpectation(description: "completed")
        httpClient.get(url, headers: requestHeaders) { result in
            switch result {
            case .failure(let error):
                XCTFail("unexpected error \(error)")
            case .success(let response):
                XCTAssertEqual(response.statusCode, responseStatus)
                self.assertResponseHeaders(response.headers, expected: responseHeaders)
                XCTAssertEqual(response.body, responseBody)
            }
            promise.fulfill()
        }

        wait(for: [promise], timeout: 1.0)
    }

    func testPost() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = LegacyHTTPClient(handler: urlSession.execute)

        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let requestBody = Data(UUID().uuidString.utf8)

        let responseStatus = 200
        let responseHeaders = [UUID().uuidString: UUID().uuidString]
        let responseBody = Data(UUID().uuidString.utf8)

        MockURLProtocol.onRequest("POST", url) { request in
            // FIXME:
            XCTAssertEqual(request.httpBody, requestBody)
            self.assertRequestHeaders(request.allHTTPHeaderFields, expected: requestHeaders)
            MockURLProtocol.respond(request, statusCode: responseStatus, headers: responseHeaders, body: responseBody)
        }

        let promise = XCTestExpectation(description: "completed")
        httpClient.post(url, body: requestBody, headers: requestHeaders) { result in
            switch result {
            case .failure(let error):
                XCTFail("unexpected error \(error)")
            case .success(let response):
                XCTAssertEqual(response.statusCode, responseStatus)
                self.assertResponseHeaders(response.headers, expected: responseHeaders)
                XCTAssertEqual(response.body, responseBody)
            }
            promise.fulfill()
        }

        wait(for: [promise], timeout: 1.0)
    }

    func testPut() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = LegacyHTTPClient(handler: urlSession.execute)

        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let requestBody = Data(UUID().uuidString.utf8)

        let responseStatus = 200
        let responseHeaders = [UUID().uuidString: UUID().uuidString]
        let responseBody = Data(UUID().uuidString.utf8)

        MockURLProtocol.onRequest("PUT", url) { request in
            XCTAssertEqual(request.httpBody, requestBody)
            self.assertRequestHeaders(request.allHTTPHeaderFields, expected: requestHeaders)
            MockURLProtocol.respond(request, statusCode: responseStatus, headers: responseHeaders, body: responseBody)
        }

        let promise = XCTestExpectation(description: "completed")
        httpClient.put(url, body: requestBody, headers: requestHeaders) { result in
            switch result {
            case .failure(let error):
                XCTFail("unexpected error \(error)")
            case .success(let response):
                XCTAssertEqual(response.statusCode, responseStatus)
                self.assertResponseHeaders(response.headers, expected: responseHeaders)
                XCTAssertEqual(response.body, responseBody)
            }
            promise.fulfill()
        }

        wait(for: [promise], timeout: 1.0)
    }

    func testDelete() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = LegacyHTTPClient(handler: urlSession.execute)

        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])

        let responseStatus = 200
        let responseHeaders = [UUID().uuidString: UUID().uuidString]
        let responseBody = Data(UUID().uuidString.utf8)

        MockURLProtocol.onRequest("DELETE", url) { request in
            self.assertRequestHeaders(request.allHTTPHeaderFields, expected: requestHeaders)
            MockURLProtocol.respond(request, statusCode: responseStatus, headers: responseHeaders, body: responseBody)
        }

        let promise = XCTestExpectation(description: "completed")
        httpClient.delete(url, headers: requestHeaders) { result in
            switch result {
            case .failure(let error):
                XCTFail("unexpected error \(error)")
            case .success(let response):
                XCTAssertEqual(response.statusCode, responseStatus)
                self.assertResponseHeaders(response.headers, expected: responseHeaders)
                XCTAssertEqual(response.body, responseBody)
            }
            promise.fulfill()
        }

        wait(for: [promise], timeout: 1.0)
    }

    private func assertRequestHeaders(_ headers: [String: String]?, expected: HTTPClientHeaders) {
        let headers = (headers?.filter { $0.key != "User-Agent" && $0.key != "Content-Length" } ?? [])
            .flatMap { HTTPClientHeaders($0.map { .init(name: $0.key, value: $0.value) }) } ?? .init()
        XCTAssertEqual(headers, expected)
    }

    private func assertResponseHeaders(_ headers: HTTPClientHeaders, expected: [String: String]) {
        let expected = HTTPClientHeaders(expected.map { .init(name: $0.key, value: $0.value) })
        XCTAssertEqual(headers, expected)
    }

    // MARK: - download


    func testDownloadSuccess() throws {
        #if !os(macOS)
        // URLSession Download tests can only run on macOS
        // as re-libs-foundation's URLSessionTask implementation which expects the temporaryFileURL property to be on the request.
        // and there is no way to set it in a mock
        // https://github.com/apple/swift-corelibs-foundation/pull/2593 tries to address the latter part
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = LegacyHTTPClient(handler: urlSession.execute)

        try testWithTemporaryDirectory { temporaryDirectory in
            let didStartLoadingExpectation = XCTestExpectation(description: "didStartLoading")
            let progress50Expectation = XCTestExpectation(description: "progress50")
            let progress100Expectation = XCTestExpectation(description: "progress100")
            let completionExpectation = XCTestExpectation(description: "completion")

            let url = URL("https://downloader-tests.com/testBasics.zip")
            let destination = temporaryDirectory.appending("download")
            let request = LegacyHTTPClient.Request.download(url: url, fileSystem: localFileSystem, destination: destination)
            httpClient.execute(
                request,
                progress: { bytesDownloaded, totalBytesToDownload in
                    switch (bytesDownloaded, totalBytesToDownload) {
                    case (512, 1024):
                        progress50Expectation.fulfill()
                    case (1024, 1024):
                        progress100Expectation.fulfill()
                    default:
                        XCTFail("unexpected progress")
                    }
                },
                completion: { result in
                    switch result {
                    case .success:
                        XCTAssertFileExists(destination)
                        let bytes = ByteString(Array(repeating: 0xBE, count: 512) + Array(repeating: 0xEF, count: 512))
                        XCTAssertEqual(try! localFileSystem.readFileContents(destination), bytes)
                    case .failure(let error):
                        XCTFail("\(error)")
                    }
                    completionExpectation.fulfill()
                }
            )

            MockURLProtocol.onRequest(request) { request in
                MockURLProtocol.sendResponse(statusCode: 200, headers: ["Content-Length": "1024"], for: request)
                didStartLoadingExpectation.fulfill()
            }
            wait(for: [didStartLoadingExpectation], timeout: 1.0)

            let urlRequest = URLRequest(request)
            MockURLProtocol.sendData(Data(repeating: 0xBE, count: 512), for: urlRequest)
            wait(for: [progress50Expectation], timeout: 1.0)
            MockURLProtocol.sendData(Data(repeating: 0xEF, count: 512), for: urlRequest)
            wait(for: [progress100Expectation], timeout: 1.0)
            MockURLProtocol.sendCompletion(for: urlRequest)
            wait(for: [completionExpectation], timeout: 1.0)
        }
    }

    func testDownloadAuthenticatedSuccess() throws {
        #if !os(macOS)
        // URLSession Download tests can only run on macOS
        // as re-libs-foundation's URLSessionTask implementation which expects the temporaryFileURL property to be on the request.
        // and there is no way to set it in a mock
        // https://github.com/apple/swift-corelibs-foundation/pull/2593 tries to address the latter part
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        let netrcContent = "machine protected.downloader-tests.com login anonymous password qwerty"
        let netrc = try NetrcAuthorizationWrapper(underlying: NetrcParser.parse(netrcContent))
        let authData = Data("anonymous:qwerty".utf8)
        let testAuthHeader = "Basic \(authData.base64EncodedString())"

        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = LegacyHTTPClient(handler: urlSession.execute)

        try testWithTemporaryDirectory { temporaryDirectory in
            let didStartLoadingExpectation = XCTestExpectation(description: "didStartLoading")
            let progress50Expectation = XCTestExpectation(description: "progress50")
            let progress100Expectation = XCTestExpectation(description: "progress100")
            let completionExpectation = XCTestExpectation(description: "completion")

            let url = URL("https://protected.downloader-tests.com/testBasics.zip")
            let destination = temporaryDirectory.appending("download")
            var request = LegacyHTTPClient.Request.download(url: url, fileSystem: localFileSystem, destination: destination)
            request.options.authorizationProvider = netrc.httpAuthorizationHeader(for:)

            httpClient.execute(
                request,
                progress: { bytesDownloaded, totalBytesToDownload in
                    switch (bytesDownloaded, totalBytesToDownload) {
                    case (512, 1024):
                        progress50Expectation.fulfill()
                    case (1024, 1024):
                        progress100Expectation.fulfill()
                    default:
                        XCTFail("unexpected progress")
                    }
                },
                completion: { result in
                    switch result {
                    case .success:
                        XCTAssertFileExists(destination)
                        let bytes = ByteString(Array(repeating: 0xBE, count: 512) + Array(repeating: 0xEF, count: 512))
                        XCTAssertEqual(try! localFileSystem.readFileContents(destination), bytes)
                    case .failure(let error):
                        XCTFail("\(error)")
                    }
                    completionExpectation.fulfill()
                }
            )

            MockURLProtocol.onRequest(request) { request in
                XCTAssertEqual(request.allHTTPHeaderFields?["Authorization"], testAuthHeader)
                MockURLProtocol.sendResponse(statusCode: 200, headers: ["Content-Length": "1024"], for: request)
                didStartLoadingExpectation.fulfill()
            }
            wait(for: [didStartLoadingExpectation], timeout: 1.0)

            let urlRequest = URLRequest(request)
            MockURLProtocol.sendData(Data(repeating: 0xBE, count: 512), for: urlRequest)
            wait(for: [progress50Expectation], timeout: 1.0)
            MockURLProtocol.sendData(Data(repeating: 0xEF, count: 512), for: urlRequest)
            wait(for: [progress100Expectation], timeout: 1.0)
            MockURLProtocol.sendCompletion(for: urlRequest)
            wait(for: [completionExpectation], timeout: 1.0)
        }
    }

    func testDownloadDefaultAuthenticationSuccess() throws {
        #if !os(macOS)
        // URLSession Download tests can only run on macOS
        // as re-libs-foundation's URLSessionTask implementation which expects the temporaryFileURL property to be on the request.
        // and there is no way to set it in a mock
        // https://github.com/apple/swift-corelibs-foundation/pull/2593 tries to address the latter part
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        try XCTSkipIfCI()
        let netrcContent = "default login default password default"
        let netrc = try NetrcAuthorizationWrapper(underlying: NetrcParser.parse(netrcContent))
        let authData = Data("default:default".utf8)
        let testAuthHeader = "Basic \(authData.base64EncodedString())"

        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = LegacyHTTPClient(handler: urlSession.execute)

        try testWithTemporaryDirectory { temporaryDirectory in
            let didStartLoadingExpectation = XCTestExpectation(description: "didStartLoading")
            let progress50Expectation = XCTestExpectation(description: "progress50")
            let progress100Expectation = XCTestExpectation(description: "progress100")
            let completionExpectation = XCTestExpectation(description: "completion")

            let url = URL("https://restricted.downloader-tests.com/testBasics.zip")
            let destination = temporaryDirectory.appending("download")
            var request = LegacyHTTPClient.Request.download(url: url, fileSystem: localFileSystem, destination: destination)
            request.options.authorizationProvider = netrc.httpAuthorizationHeader(for:)

            httpClient.execute(
                request,
                progress: { bytesDownloaded, totalBytesToDownload in
                    switch (bytesDownloaded, totalBytesToDownload) {
                    case (512, 1024):
                        progress50Expectation.fulfill()
                    case (1024, 1024):
                        progress100Expectation.fulfill()
                    default:
                        XCTFail("unexpected progress")
                    }
                },
                completion: { result in
                    switch result {
                    case .success:
                        XCTAssertFileExists(destination)
                        let bytes = ByteString(Array(repeating: 0xBE, count: 512) + Array(repeating: 0xEF, count: 512))
                        XCTAssertEqual(try! localFileSystem.readFileContents(destination), bytes)
                    case .failure(let error):
                        XCTFail("\(error)")
                    }
                    completionExpectation.fulfill()
                }
            )

            MockURLProtocol.onRequest(request) { request in
                XCTAssertEqual(request.allHTTPHeaderFields?["Authorization"], testAuthHeader)
                MockURLProtocol.sendResponse(statusCode: 200, headers: ["Content-Length": "1024"], for: request)
                didStartLoadingExpectation.fulfill()
            }
            wait(for: [didStartLoadingExpectation], timeout: 1.0)

            let urlRequest = URLRequest(request)
            MockURLProtocol.sendData(Data(repeating: 0xBE, count: 512), for: urlRequest)
            wait(for: [progress50Expectation], timeout: 1.0)
            MockURLProtocol.sendData(Data(repeating: 0xEF, count: 512), for: urlRequest)
            wait(for: [progress100Expectation], timeout: 1.0)
            MockURLProtocol.sendCompletion(for: urlRequest)
            wait(for: [completionExpectation], timeout: 1.0)
        }
    }

    func testDownloadClientError() throws {
        #if !os(macOS)
        // URLSession Download tests can only run on macOS
        // as re-libs-foundation's URLSessionTask implementation which expects the temporaryFileURL property to be on the request.
        // and there is no way to set it in a mock
        // https://github.com/apple/swift-corelibs-foundation/pull/2593 tries to address the latter part
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = LegacyHTTPClient(handler: urlSession.execute)

        try testWithTemporaryDirectory { temporaryDirectory in
            let didStartLoadingExpectation = XCTestExpectation(description: "didStartLoading")
            let progress50Expectation = XCTestExpectation(description: "progress50")
            let completionExpectation = XCTestExpectation(description: "completion")

            let clientError = StringError("boom")
            let url = URL("https://downloader-tests.com/testClientError.zip")
            let request = LegacyHTTPClient.Request.download(url: url, fileSystem: localFileSystem, destination: temporaryDirectory.appending("download"))
            httpClient.execute(
                request,
                progress: { bytesDownloaded, totalBytesToDownload in
                    switch (bytesDownloaded, totalBytesToDownload) {
                    case (512, 1024):
                        progress50Expectation.fulfill()
                    default:
                        XCTFail("unexpected progress")
                    }
                },
                completion: { result in
                    switch result {
                    case .success:
                        XCTFail("unexpected success")
                    case .failure(let error):
                        XCTAssertEqual(error as? HTTPClientError, HTTPClientError.downloadError(clientError.description))
                    }
                    completionExpectation.fulfill()
                }
            )

            MockURLProtocol.onRequest(request) { request in
                MockURLProtocol.sendResponse(statusCode: 200, headers: ["Content-Length": "1024"], for: request)
                didStartLoadingExpectation.fulfill()
            }
            wait(for: [didStartLoadingExpectation], timeout: 3.0)

            let urlRequest = URLRequest(request)
            MockURLProtocol.sendData(Data(count: 512), for: urlRequest)
            wait(for: [progress50Expectation], timeout: 3.0)
            MockURLProtocol.sendError(clientError, for: urlRequest)
            wait(for: [completionExpectation], timeout: 3.0)
        }
    }

    func testDownloadServerError() throws {
        #if !os(macOS)
        // URLSession Download tests can only run on macOS
        // as re-libs-foundation's URLSessionTask implementation which expects the temporaryFileURL property to be on the request.
        // and there is no way to set it in a mock
        // https://github.com/apple/swift-corelibs-foundation/pull/2593 tries to address the latter part
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = LegacyHTTPClient(handler: urlSession.execute)

        try testWithTemporaryDirectory { temporaryDirectory in
            let didStartLoadingExpectation = XCTestExpectation(description: "didStartLoading")
            let completionExpectation = XCTestExpectation(description: "completion")

            let url = URL("https://downloader-tests.com/testServerError.zip")
            var request = LegacyHTTPClient.Request.download(url: url, fileSystem: localFileSystem, destination: temporaryDirectory.appending("download"))
            request.options.validResponseCodes = [200]

            httpClient.execute(
                request,
                progress: { _, _ in
                    XCTFail("unexpected progress")
                },
                completion: { result in
                    switch result {
                    case .success:
                        XCTFail("unexpected success")
                    case .failure(let error):
                        XCTAssertEqual(error as? HTTPClientError, HTTPClientError.badResponseStatusCode(500))
                    }
                    completionExpectation.fulfill()
                }
            )

            MockURLProtocol.onRequest(request) { request in
                MockURLProtocol.sendResponse(statusCode: 500, for: request)
                didStartLoadingExpectation.fulfill()
            }
            wait(for: [didStartLoadingExpectation], timeout: 1.0)

            MockURLProtocol.sendCompletion(for: URLRequest(request))
            wait(for: [completionExpectation], timeout: 1.0)
        }
    }

    func testDownloadFileSystemError() throws {
        #if !os(macOS)
        // URLSession Download tests can only run on macOS
        // as re-libs-foundation's URLSessionTask implementation which expects the temporaryFileURL property to be on the request.
        // and there is no way to set it in a mock
        // https://github.com/apple/swift-corelibs-foundation/pull/2593 tries to address the latter part
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = LegacyHTTPClient(handler: urlSession.execute)

        try testWithTemporaryDirectory { temporaryDirectory in
            let didStartLoadingExpectation = XCTestExpectation(description: "didStartLoading")
            let completionExpectation = XCTestExpectation(description: "error")

            let url = URL("https://downloader-tests.com/testFileSystemError.zip")
            let request = LegacyHTTPClient.Request.download(url: url, fileSystem: FailingFileSystem(), destination: temporaryDirectory.appending("download"))
            httpClient.execute(request, progress: { _, _ in }, completion: { result in
                switch result {
                case .success:
                    XCTFail("unexpected success")
                case .failure(let error):
                    XCTAssertEqual(error as? FileSystemError, FileSystemError(.unsupported))
                }
                completionExpectation.fulfill()
            })

            MockURLProtocol.onRequest(request) { request in
                MockURLProtocol.sendResponse(statusCode: 200, for: request)
                didStartLoadingExpectation.fulfill()
            }
            wait(for: [didStartLoadingExpectation], timeout: 1.0)

            let urlRequest = URLRequest(request)
            MockURLProtocol.sendData(Data([0xDE, 0xAD, 0xBE, 0xEF]), for: urlRequest)
            MockURLProtocol.sendCompletion(for: urlRequest)
            wait(for: [completionExpectation], timeout: 1.0)
        }
    }

    // FIXME: remove this availability check when back-deployment is available on CI hosts.
    func testAsyncHead() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = HTTPClient(implementation: urlSession.execute)

        let url = URL("http://async-head-test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])

        let responseStatus = 200
        let responseHeaders = [UUID().uuidString: UUID().uuidString]
        let responseBody = Data(UUID().uuidString.utf8)

        MockURLProtocol.onRequest("HEAD", url) { request in
            self.assertRequestHeaders(request.allHTTPHeaderFields, expected: requestHeaders)
            MockURLProtocol.respond(request, statusCode: responseStatus, headers: responseHeaders, body: responseBody)
        }

        let response = try await httpClient.execute(.init(method: .head, url: url, headers: requestHeaders))

        XCTAssertEqual(response.statusCode, responseStatus)
        self.assertResponseHeaders(response.headers, expected: responseHeaders)
        XCTAssertEqual(response.body, responseBody)
    }

    func testAsyncGet() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = HTTPClient(implementation: urlSession.execute)

        let url = URL("http://async-get-test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])

        let responseStatus = 200
        let responseHeaders = [UUID().uuidString: UUID().uuidString]
        let responseBody = Data(UUID().uuidString.utf8)

        MockURLProtocol.onRequest("GET", url) { request in
            self.assertRequestHeaders(request.allHTTPHeaderFields, expected: requestHeaders)
            MockURLProtocol.respond(request, statusCode: responseStatus, headers: responseHeaders, body: responseBody)
        }

        let response = try await httpClient.execute(.init(method: .get, url: url, headers: requestHeaders))
        XCTAssertEqual(response.statusCode, responseStatus)
        self.assertResponseHeaders(response.headers, expected: responseHeaders)
        XCTAssertEqual(response.body, responseBody)
    }

    func testAsyncPost() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = HTTPClient(implementation: urlSession.execute)

        let url = URL("http://async-post-test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let requestBody = Data(UUID().uuidString.utf8)

        let responseStatus = 200
        let responseHeaders = [UUID().uuidString: UUID().uuidString]
        let responseBody = Data(UUID().uuidString.utf8)

        MockURLProtocol.onRequest("POST", url) { request in
            // FIXME:
            XCTAssertEqual(request.httpBody, requestBody)
            self.assertRequestHeaders(request.allHTTPHeaderFields, expected: requestHeaders)
            MockURLProtocol.respond(request, statusCode: responseStatus, headers: responseHeaders, body: responseBody)
        }

        let response = try await httpClient.execute(.init(method: .post, url: url, headers: requestHeaders, body: requestBody))

        XCTAssertEqual(response.statusCode, responseStatus)
        self.assertResponseHeaders(response.headers, expected: responseHeaders)
        XCTAssertEqual(response.body, responseBody)
    }

    func testAsyncPut() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = HTTPClient(implementation: urlSession.execute)

        let url = URL("http://async-put-test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let requestBody = Data(UUID().uuidString.utf8)

        let responseStatus = 200
        let responseHeaders = [UUID().uuidString: UUID().uuidString]
        let responseBody = Data(UUID().uuidString.utf8)

        MockURLProtocol.onRequest("PUT", url) { request in
            XCTAssertEqual(request.httpBody, requestBody)
            self.assertRequestHeaders(request.allHTTPHeaderFields, expected: requestHeaders)
            MockURLProtocol.respond(request, statusCode: responseStatus, headers: responseHeaders, body: responseBody)
        }

        let response = try await httpClient.execute(.init(method: .put, url: url, headers: requestHeaders, body: requestBody))

        XCTAssertEqual(response.statusCode, responseStatus)
        self.assertResponseHeaders(response.headers, expected: responseHeaders)
        XCTAssertEqual(response.body, responseBody)
    }

    func testAsyncDelete() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = HTTPClient(implementation: urlSession.execute)

        let url = URL("http://async-delete-test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])

        let responseStatus = 200
        let responseHeaders = [UUID().uuidString: UUID().uuidString]
        let responseBody = Data(UUID().uuidString.utf8)

        MockURLProtocol.onRequest("DELETE", url) { request in
            self.assertRequestHeaders(request.allHTTPHeaderFields, expected: requestHeaders)
            MockURLProtocol.respond(request, statusCode: responseStatus, headers: responseHeaders, body: responseBody)
        }

        let response = try await httpClient.execute(.init(method: .delete, url: url, headers: requestHeaders))

        XCTAssertEqual(response.statusCode, responseStatus)
        self.assertResponseHeaders(response.headers, expected: responseHeaders)
        XCTAssertEqual(response.body, responseBody)
    }

    // MARK: - download

    func testAsyncDownloadSuccess() async throws {
        #if !os(macOS)
        // URLSession Download tests can only run on macOS
        // as re-libs-foundation's URLSessionTask implementation which expects the temporaryFileURL property to be on the request.
        // and there is no way to set it in a mock
        // https://github.com/apple/swift-corelibs-foundation/pull/2593 tries to address the latter part
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = HTTPClient(implementation: urlSession.execute)

        try await testWithTemporaryDirectory { temporaryDirectory in
            let url = URL("https://async-downloader-tests.com/testBasics.zip")
            let destination = temporaryDirectory.appending("download")
            let request = HTTPClient.Request.download(
                url: url,
                fileSystem: localFileSystem,
                destination: destination
            )

            MockURLProtocol.onRequest(request) { request in
                MockURLProtocol.sendResponse(statusCode: 200, headers: ["Content-Length": "1024"], for: request)
                MockURLProtocol.sendData(Data(repeating: 0xBE, count: 512), for: request)
                MockURLProtocol.sendData(Data(repeating: 0xEF, count: 512), for: request)
                MockURLProtocol.sendCompletion(for: request)
            }

            _ = try await httpClient.execute(
                request,
                progress: { bytesDownloaded, totalBytesToDownload in
                    switch (bytesDownloaded, totalBytesToDownload) {
                    case (512, 1024):
                        break
                    case (1024, 1024):
                        break
                    default:
                        XCTFail("unexpected progress")
                    }
                }
            )

            XCTAssertFileExists(destination)
            let bytes = ByteString(Array(repeating: 0xBE, count: 512) + Array(repeating: 0xEF, count: 512))
            XCTAssertEqual(try! localFileSystem.readFileContents(destination), bytes)
        }
    }

    func testAsyncDownloadAuthenticatedSuccess() async throws {
        #if !os(macOS)
        // URLSession Download tests can only run on macOS
        // as re-libs-foundation's URLSessionTask implementation which expects the temporaryFileURL property to be on the request.
        // and there is no way to set it in a mock
        // https://github.com/apple/swift-corelibs-foundation/pull/2593 tries to address the latter part
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        let netrcContent = "machine async-protected.downloader-tests.com login anonymous password qwerty"
        let netrc = try NetrcAuthorizationWrapper(underlying: NetrcParser.parse(netrcContent))
        let authData = Data("anonymous:qwerty".utf8)
        let testAuthHeader = "Basic \(authData.base64EncodedString())"

        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = HTTPClient(implementation: urlSession.execute)

        try await testWithTemporaryDirectory { temporaryDirectory in
            let url = URL("https://async-protected.downloader-tests.com/testBasics.zip")
            let destination = temporaryDirectory.appending("download")
            var options = HTTPClientRequest.Options()
            options.authorizationProvider = netrc.httpAuthorizationHeader(for:)
            let request = HTTPClient.Request.download(
                url: url,
                options: options,
                fileSystem: localFileSystem,
                destination: destination
            )

            MockURLProtocol.onRequest(request) { request in
                XCTAssertEqual(request.allHTTPHeaderFields?["Authorization"], testAuthHeader)
                MockURLProtocol.sendResponse(statusCode: 200, headers: ["Content-Length": "1024"], for: request)
                MockURLProtocol.sendData(Data(repeating: 0xBE, count: 512), for: request)
                MockURLProtocol.sendData(Data(repeating: 0xEF, count: 512), for: request)
                MockURLProtocol.sendCompletion(for: request)
            }

            _ = try await httpClient.execute(
                request,
                progress: { bytesDownloaded, totalBytesToDownload in
                    switch (bytesDownloaded, totalBytesToDownload) {
                    case (512, 1024):
                        break
                    case (1024, 1024):
                        break
                    default:
                        XCTFail("unexpected progress")
                    }
                }
            )

            XCTAssertFileExists(destination)
            let bytes = ByteString(Array(repeating: 0xBE, count: 512) + Array(repeating: 0xEF, count: 512))
            XCTAssertEqual(try! localFileSystem.readFileContents(destination), bytes)
        }
    }

    func testAsyncDownloadDefaultAuthenticationSuccess() async throws {
        #if !os(macOS)
        // URLSession Download tests can only run on macOS
        // as re-libs-foundation's URLSessionTask implementation which expects the temporaryFileURL property to be on the request.
        // and there is no way to set it in a mock
        // https://github.com/apple/swift-corelibs-foundation/pull/2593 tries to address the latter part
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        let netrcContent = "default login default password default"
        let netrc = try NetrcAuthorizationWrapper(underlying: NetrcParser.parse(netrcContent))
        let authData = Data("default:default".utf8)
        let testAuthHeader = "Basic \(authData.base64EncodedString())"

        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = HTTPClient(implementation: urlSession.execute)

        try await testWithTemporaryDirectory { temporaryDirectory in
            let url = URL("https://async-restricted.downloader-tests.com/testBasics.zip")
            let destination = temporaryDirectory.appending("download")

            var options = HTTPClientRequest.Options()
            options.authorizationProvider = netrc.httpAuthorizationHeader(for:)
            let request = HTTPClient.Request.download(
                url: url,
                options: options,
                fileSystem: localFileSystem,
                destination: destination
            )

            MockURLProtocol.onRequest(request) { request in
                XCTAssertEqual(request.allHTTPHeaderFields?["Authorization"], testAuthHeader)
                MockURLProtocol.sendResponse(statusCode: 200, headers: ["Content-Length": "1024"], for: request)
                MockURLProtocol.sendData(Data(repeating: 0xBE, count: 512), for: request)
                MockURLProtocol.sendData(Data(repeating: 0xEF, count: 512), for: request)
                MockURLProtocol.sendCompletion(for: request)
            }

            _ = try await httpClient.execute(
                request,
                progress: { bytesDownloaded, totalBytesToDownload in
                    switch (bytesDownloaded, totalBytesToDownload) {
                    case (512, 1024):
                        break
                    case (1024, 1024):
                        break
                    default:
                        XCTFail("unexpected progress")
                    }
                }
            )

            XCTAssertFileExists(destination)
            let bytes = ByteString(Array(repeating: 0xBE, count: 512) + Array(repeating: 0xEF, count: 512))
            XCTAssertEqual(try! localFileSystem.readFileContents(destination), bytes)
        }
    }

    func testAsyncDownloadClientError() async throws {
        #if !os(macOS)
        // URLSession Download tests can only run on macOS
        // as re-libs-foundation's URLSessionTask implementation which expects the temporaryFileURL property to be on the request.
        // and there is no way to set it in a mock
        // https://github.com/apple/swift-corelibs-foundation/pull/2593 tries to address the latter part
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = HTTPClient(implementation: urlSession.execute)

        try await testWithTemporaryDirectory { temporaryDirectory in
            let clientError = StringError("boom")
            let url = URL("https://async-downloader-tests.com/testClientError.zip")
            let request = HTTPClient.Request.download(
                url: url,
                fileSystem: localFileSystem,
                destination: temporaryDirectory.appending("download")
            )

            MockURLProtocol.onRequest(request) { request in
                MockURLProtocol.sendResponse(statusCode: 200, headers: ["Content-Length": "1024"], for: request)
                MockURLProtocol.sendData(Data(count: 512), for: request)
                MockURLProtocol.sendError(clientError, for: request)
            }

            do {
                _ = try await httpClient.execute(
                    request,
                    progress: { bytesDownloaded, totalBytesToDownload in
                        switch (bytesDownloaded, totalBytesToDownload) {
                        case (512, 1024):
                            break
                        default:
                            XCTFail("unexpected progress")
                        }
                    }
                )
                XCTFail("unexpected success")
            } catch {
                XCTAssertEqual(error as? HTTPClientError, HTTPClientError.downloadError(clientError.description))
            }
        }
    }

    func testAsyncDownloadServerError() async throws {
        #if !os(macOS)
        // URLSession Download tests can only run on macOS
        // as re-libs-foundation's URLSessionTask implementation which expects the temporaryFileURL property to be on the request.
        // and there is no way to set it in a mock
        // https://github.com/apple/swift-corelibs-foundation/pull/2593 tries to address the latter part
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSessionHTTPClient(configuration: configuration)
        let httpClient = HTTPClient(implementation: urlSession.execute)

        try await testWithTemporaryDirectory { temporaryDirectory in
            let url = URL("https://async-downloader-tests.com/testServerError.zip")
            var options = HTTPClientRequest.Options()
            options.validResponseCodes = [200]
            let request = HTTPClient.Request.download(
                url: url,
                options: options,
                fileSystem: localFileSystem,
                destination: temporaryDirectory.appending("download")
            )

            MockURLProtocol.onRequest(request) { request in
                MockURLProtocol.sendResponse(statusCode: 500, for: request)
                MockURLProtocol.sendCompletion(for: request)
            }

            do {
                _ = try await httpClient.execute(
                    request,
                    progress: { _, _ in
                        XCTFail("unexpected progress")
                    }
                )
                XCTFail("unexpected success")
            } catch {
                XCTAssertEqual(error as? HTTPClientError, HTTPClientError.badResponseStatusCode(500))
            }
        }
    }
}

private class MockURLProtocol: URLProtocol {
    typealias Action = (URLRequest) -> Void

    private static var observers = ThreadSafeKeyValueStore<Key, Action>()
    private static var requests = ThreadSafeKeyValueStore<Key, URLProtocol>()

    static func onRequest(_ request: LegacyHTTPClientRequest, completion: @escaping Action) {
        self.onRequest(request.method.string, request.url, completion: completion)
    }

    static func onRequest(_ request: HTTPClientRequest, completion: @escaping Action) {
        self.onRequest(request.method.string, request.url, completion: completion)
    }

    static func onRequest(_ method: String, _ url: URL, completion: @escaping Action) {
        let key = Key(method, url)
        guard !self.observers.contains(key) else {
            return XCTFail("does not support multiple observers for the same url")
        }
        self.observers[key] = completion
    }

    static func respond(_ request: URLRequest, statusCode: Int, headers: [String: String]? = nil, body: Data? = nil) {
        self.respond(request.httpMethod!, request.url!, statusCode: statusCode, headers: headers, body: body)
    }

    static func respond(_ method: String, _ url: URL, statusCode: Int, headers: [String: String]? = nil, body: Data? = nil) {
        let key = Key(method, url)
        self.sendResponse(statusCode: statusCode, headers: headers, for: key)
        if let data = body {
            self.sendData(data, for: key)
        }
        self.sendCompletion(for: key)
    }

    static func sendResponse(statusCode: Int, headers: [String: String]? = nil, for request: URLRequest) {
        self.sendResponse(request.httpMethod!, request.url!, statusCode: statusCode, headers: headers)
    }

    static func sendResponse(_ method: String, _ url: URL, statusCode: Int, headers: [String: String]? = nil) {
        let key = Key(method, url)
        self.sendResponse(statusCode: statusCode, headers: headers, for: key)
    }

    static func sendData(_ method: String, _ url: URL, _ data: Data) {
        let key = Key(method, url)
        self.sendData(data, for: key)
    }

    static func sendCompletion(_ method: String, _ url: URL) {
        let key = Key(method, url)
        self.sendCompletion(for: key)
    }

    static func sendError(_ method: String, _ url: URL, _ error: Error) {
        let key = Key(method, url)
        self.sendError(error, for: key)
    }

    private static func sendResponse(statusCode: Int, headers: [String: String]? = nil, for key: Key) {
        guard let request = self.requests[key] else {
            return XCTFail("url did not start loading")
        }
        let response = HTTPURLResponse(url: key.url, statusCode: statusCode, httpVersion: "1.1", headerFields: headers)!
        request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    static func sendData(_ data: Data, for request: URLRequest) {
        sendData(data, for: Key(request))
    }

    private static func sendData(_ data: Data, for key: Key) {
        guard let request = self.requests[key] else {
            return XCTFail("url did not start loading")
        }
        request.client?.urlProtocol(request, didLoad: data)
    }

    static func sendCompletion(for request: URLRequest) {
        sendCompletion(for: Key(request))
    }

    private static func sendCompletion(for key: Key) {
        guard let request = self.requests[key] else {
            return XCTFail("url did not start loading")
        }
        request.client?.urlProtocolDidFinishLoading(request)
    }

    static func sendError(_ error: Error, for request: URLRequest) {
        sendError(error, for: Key(request))
    }

    private static func sendError(_ error: Error, for key: Key) {
        guard let request = self.requests[key] else {
            return XCTFail("url did not start loading")
        }
        request.client?.urlProtocol(request, didFailWithError: error)
    }

    private struct Key: Hashable {
        let method: String
        let url: URL

        init(_ method: String, _ url: URL) {
            self.method = method
            self.url = url
        }

        init(_ request: URLRequest) {
            self.method = request.httpMethod!
            self.url = request.url!
        }
    }

    // MARK: - URLProtocol

    override class func canInit(with _: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        if let url = self.request.url, let method = self.request.httpMethod {
            let key = Key(method, url)
            Self.requests[key] = self

            guard let action = Self.observers[key] else {
                return
            }

            // read body if available
            var request = self.request
            if let bodyStream = self.request.httpBodyStream {
                bodyStream.open()
                defer { bodyStream.close() }
                let bufferSize: Int = 1024
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                var data = Data()
                while bodyStream.hasBytesAvailable {
                    let read = bodyStream.read(buffer, maxLength: bufferSize)
                    data.append(buffer, count: read)
                }
                buffer.deallocate()
                request.httpBody = data
            }

            DispatchQueue.main.async {
                action(request)
            }
        }
    }

    override func stopLoading() {
        if let url = self.request.url, let method = self.request.httpMethod {
            let key = Key(method, url)
            Self.requests[key] = nil
        }
    }
}

final class FailingFileSystem: FileSystem {
    var currentWorkingDirectory: TSCAbsolutePath? {
        fatalError("unexpected call")
    }

    var homeDirectory: TSCAbsolutePath {
        fatalError("unexpected call")
    }

    var cachesDirectory: TSCAbsolutePath? {
        fatalError("unexpected call")
    }

    var tempDirectory: TSCAbsolutePath {
        fatalError("unexpected call")
    }

    func changeCurrentWorkingDirectory(to path: TSCAbsolutePath) throws {
        fatalError("unexpected call")
    }

    func exists(_ path: TSCAbsolutePath, followSymlink: Bool) -> Bool {
        fatalError("unexpected call")
    }

    func isDirectory(_: TSCAbsolutePath) -> Bool {
        fatalError("unexpected call")
    }

    func isFile(_: TSCAbsolutePath) -> Bool {
        fatalError("unexpected call")
    }

    func isExecutableFile(_: TSCAbsolutePath) -> Bool {
        fatalError("unexpected call")
    }

    func isSymlink(_: TSCAbsolutePath) -> Bool {
        fatalError("unexpected call")
    }

    func isReadable(_ path: TSCAbsolutePath) -> Bool {
        fatalError("unexpected call")
    }

    func isWritable(_ path: TSCAbsolutePath) -> Bool {
        fatalError("unexpected call")
    }

    func getDirectoryContents(_: TSCAbsolutePath) throws -> [String] {
        fatalError("unexpected call")
    }

    func readFileContents(_: TSCAbsolutePath) throws -> ByteString {
        fatalError("unexpected call")
    }

    func removeFileTree(_: TSCAbsolutePath) throws {
        fatalError("unexpected call")
    }

    func chmod(_ mode: FileMode, path: TSCAbsolutePath, options: Set<FileMode.Option>) throws {
        fatalError("unexpected call")
    }

    func writeFileContents(_ path: TSCAbsolutePath, bytes: ByteString) throws {
        fatalError("unexpected call")
    }

    func createDirectory(_ path: TSCAbsolutePath, recursive: Bool) throws {
        fatalError("unexpected call")
    }

    func createSymbolicLink(_ path: TSCAbsolutePath, pointingAt destination: TSCAbsolutePath, relative: Bool) throws {
        fatalError("unexpected call")
    }

    func copy(from sourcePath: TSCAbsolutePath, to destinationPath: TSCAbsolutePath) throws {
        fatalError("unexpected call")
    }

    func move(from sourcePath: TSCAbsolutePath, to destinationPath: TSCAbsolutePath) throws {
        throw FileSystemError(.unsupported)
    }
}

fileprivate struct NetrcAuthorizationWrapper: AuthorizationProvider {
    let underlying: Netrc

    func authentication(for url: URL) -> (user: String, password: String)? {
        self.underlying.authorization(for: url).map{ (user: $0.login, password: $0.password) }
    }
}
