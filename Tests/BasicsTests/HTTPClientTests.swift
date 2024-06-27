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
import _InternalTestSupport
import XCTest

final class HTTPClientTests: XCTestCase {
    func testHead() async throws {
        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let responseStatus = Int.random(in: 201 ..< 500)
        let responseHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let responseBody: Data? = nil

        let httpClient = HTTPClient { request, _ in
            XCTAssertEqual(request.url, url, "url should match")
            XCTAssertEqual(request.method, .head, "method should match")
            assertRequestHeaders(request.headers, expected: requestHeaders)
            return .init(statusCode: responseStatus, headers: responseHeaders, body: responseBody)
        }

        let response = try await httpClient.head(url, headers: requestHeaders)
        XCTAssertEqual(response.statusCode, responseStatus, "statusCode should match")
        assertResponseHeaders(response.headers, expected: responseHeaders)
        XCTAssertEqual(response.body, responseBody, "body should match")
    }

    func testGet() async throws {
        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let responseStatus = Int.random(in: 201 ..< 500)
        let responseHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let responseBody = Data(UUID().uuidString.utf8)

        let httpClient = HTTPClient { request, _ in
            XCTAssertEqual(request.url, url, "url should match")
            XCTAssertEqual(request.method, .get, "method should match")
            assertRequestHeaders(request.headers, expected: requestHeaders)
            return .init(statusCode: responseStatus, headers: responseHeaders, body: responseBody)
        }

        let response = try await httpClient.get(url, headers: requestHeaders)
        XCTAssertEqual(response.statusCode, responseStatus, "statusCode should match")
        assertResponseHeaders(response.headers, expected: responseHeaders)
        XCTAssertEqual(response.body, responseBody, "body should match")
    }

    func testPost() async throws {
        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let requestBody = Data(UUID().uuidString.utf8)
        let responseStatus = Int.random(in: 201 ..< 500)
        let responseHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let responseBody = Data(UUID().uuidString.utf8)

        let httpClient = HTTPClient { request, _ in
            XCTAssertEqual(request.url, url, "url should match")
            XCTAssertEqual(request.method, .post, "method should match")
            assertRequestHeaders(request.headers, expected: requestHeaders)
            XCTAssertEqual(request.body, requestBody, "body should match")
            return .init(statusCode: responseStatus, headers: responseHeaders, body: responseBody)
        }

        let response = try await httpClient.post(url, body: requestBody, headers: requestHeaders)
        XCTAssertEqual(response.statusCode, responseStatus, "statusCode should match")
        assertResponseHeaders(response.headers, expected: responseHeaders)
        XCTAssertEqual(response.body, responseBody, "body should match")
    }

    func testPut() async throws {
        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let requestBody = Data(UUID().uuidString.utf8)
        let responseStatus = Int.random(in: 201 ..< 500)
        let responseHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let responseBody = Data(UUID().uuidString.utf8)

        let httpClient = HTTPClient { request, _ in
            XCTAssertEqual(request.url, url, "url should match")
            XCTAssertEqual(request.method, .put, "method should match")
            assertRequestHeaders(request.headers, expected: requestHeaders)
            XCTAssertEqual(request.body, requestBody, "body should match")
            return .init(statusCode: responseStatus, headers: responseHeaders, body: responseBody)
        }

        let response = try await httpClient.put(url, body: requestBody, headers: requestHeaders)
        XCTAssertEqual(response.statusCode, responseStatus, "statusCode should match")
        assertResponseHeaders(response.headers, expected: responseHeaders)
        XCTAssertEqual(response.body, responseBody, "body should match")
    }

    func testDelete() async throws {
        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let responseStatus = Int.random(in: 201 ..< 500)
        let responseHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let responseBody = Data(UUID().uuidString.utf8)

        let httpClient = HTTPClient { request, _ in
            XCTAssertEqual(request.url, url, "url should match")
            XCTAssertEqual(request.method, .delete, "method should match")
            assertRequestHeaders(request.headers, expected: requestHeaders)
            return .init(statusCode: responseStatus, headers: responseHeaders, body: responseBody)
        }

        let response = try await httpClient.delete(url, headers: requestHeaders)
        XCTAssertEqual(response.statusCode, responseStatus, "statusCode should match")
        assertResponseHeaders(response.headers, expected: responseHeaders)
        XCTAssertEqual(response.body, responseBody, "body should match")
    }

    func testExtraHeaders() async throws {
        let url = URL("http://test")
        let globalHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])

        let httpClient = HTTPClient(configuration: .init(requestHeaders: globalHeaders)) { request, _ in
            var expectedHeaders = globalHeaders
            expectedHeaders.merge(requestHeaders)
            assertRequestHeaders(request.headers, expected: expectedHeaders)
            return .init(statusCode: 200)
        }

        var request = HTTPClient.Request(method: .get, url: url, headers: requestHeaders)
        request.options.addUserAgent = true

        let response = try await httpClient.execute(request)
        XCTAssertEqual(response.statusCode, 200, "statusCode should match")
    }

    func testUserAgent() async throws {
        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])

        let httpClient = HTTPClient { request, _ in
            XCTAssertTrue(request.headers.contains("User-Agent"), "expecting User-Agent")
            assertRequestHeaders(request.headers, expected: requestHeaders)
            return .init(statusCode: 200)
        }
        var request = HTTPClient.Request(method: .get, url: url, headers: requestHeaders)
        request.options.addUserAgent = true

        let response = try await httpClient.execute(request)
        XCTAssertEqual(response.statusCode, 200, "statusCode should match")
    }

    func testNoUserAgent() async throws {
        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])

        let httpClient = HTTPClient { request, _ in
            XCTAssertFalse(request.headers.contains("User-Agent"), "expecting User-Agent")
            assertRequestHeaders(request.headers, expected: requestHeaders)
            return .init(statusCode: 200)
        }

        var request = HTTPClient.Request(method: .get, url: url, headers: requestHeaders)
        request.options.addUserAgent = false

        let response = try await httpClient.execute(request)
        XCTAssertEqual(response.statusCode, 200, "statusCode should match")
    }

    func testAuthorization() async throws {
        let url = URL("http://test")

        do {
            let authorization = UUID().uuidString

            let httpClient = HTTPClient { request, _ in
                XCTAssertTrue(request.headers.contains("Authorization"), "expecting Authorization")
                XCTAssertEqual(request.headers.get("Authorization").first, authorization, "expecting Authorization to match")
                return .init(statusCode: 200)
            }

            var request = HTTPClient.Request(method: .get, url: url)
            request.options.authorizationProvider = { requestUrl in
                requestUrl == url ? authorization : nil
            }

            let response = try await httpClient.execute(request)
            XCTAssertEqual(response.statusCode, 200, "statusCode should match")
        }

        do {
            let httpClient = HTTPClient { request, _ in
                XCTAssertFalse(request.headers.contains("Authorization"), "not expecting Authorization")
                return .init(statusCode: 200)
            }

            var request = HTTPClient.Request(method: .get, url: url)
            request.options.authorizationProvider = { _ in "" }

            let response = try await httpClient.execute(request)
            XCTAssertEqual(response.statusCode, 200, "statusCode should match")
        }
    }

    func testValidResponseCodes() async throws {
        let statusCode = Int.random(in: 201 ..< 500)

        let httpClient = HTTPClient { _, _ in
            throw HTTPClientError.badResponseStatusCode(statusCode)
        }

        var request = HTTPClient.Request(method: .get, url: "http://test")
        request.options.validResponseCodes = [200]

        do {
            let response = try await httpClient.execute(request)
            XCTFail("unexpected success \(response)")
        } catch {
            XCTAssertEqual(error as? HTTPClientError, .badResponseStatusCode(statusCode), "expected error to match")
        }
    }

    func testExponentialBackoff() async throws {
        let counter = SendableBox(0)
        let lastCall = SendableBox<Date>()
        let maxAttempts = 5
        let errorCode = Int.random(in: 500 ..< 600)
        let delay = SendableTimeInterval.milliseconds(100)

        let httpClient = HTTPClient { _, _ in
            let count = await counter.value!
            let expectedDelta = pow(2.0, Double(count - 1)) * delay.timeInterval()!
            let delta = await lastCall.value.flatMap { Date().timeIntervalSince($0) } ?? 0
            XCTAssertEqual(delta, expectedDelta, accuracy: 0.1)

            await counter.increment()
            await lastCall.resetDate()
            return .init(statusCode: errorCode)
        }
        var request = HTTPClient.Request(method: .get, url: "http://test")
        request.options.retryStrategy = .exponentialBackoff(maxAttempts: maxAttempts, baseDelay: delay)

        let response = try await httpClient.execute(request)
        XCTAssertEqual(response.statusCode, errorCode)
        let count = await counter.value
        XCTAssertEqual(count, maxAttempts, "retries should match")
    }

    func testHostCircuitBreaker() async throws {
        let maxErrors = 5
        let errorCode = Int.random(in: 500 ..< 600)
        let age = SendableTimeInterval.seconds(5)

        let host = "http://tes-\(UUID().uuidString).com"
        let configuration = HTTPClientConfiguration(circuitBreakerStrategy: .hostErrors(maxErrors: maxErrors, age: age))
        let httpClient = HTTPClient(configuration: configuration) { _, _ in
            .init(statusCode: errorCode)
        }

        // make the initial errors
        do {
            let counter = SendableBox(0)
            for index in (0 ..< maxErrors) {
                let response = try await httpClient.get(URL("\(host)/\(index)/foo"))
                await counter.increment()
                XCTAssertEqual(response.statusCode, errorCode)
            }
            let count = await counter.value
            XCTAssertEqual(count, maxErrors, "expected results count to match")
        }

        // these should all circuit break
        let counter = SendableBox(0)
        let total = Int.random(in: 10 ..< 20)
        for index in (0 ..< total) {
            do {
                let response = try await httpClient.get(URL("\(host)/\(index)/foo"))
                XCTFail("unexpected success \(response)")
            } catch {
                XCTAssertEqual(error as? HTTPClientError, .circuitBreakerTriggered, "expected error to match")
            }

            await counter.increment()
        }

        let count = await counter.value
        XCTAssertEqual(count, total, "expected results count to match")
    }

    func testHostCircuitBreakerAging() async throws {
        let maxErrors = 5
        let errorCode = Int.random(in: 500 ..< 600)
        let ageInMilliseconds = 100

        let host = "http://tes-\(UUID().uuidString).com"
        let configuration = HTTPClientConfiguration(
            circuitBreakerStrategy: .hostErrors(
                maxErrors: maxErrors,
                age: .milliseconds(ageInMilliseconds)
            )
        )
        let httpClient = HTTPClient(configuration: configuration) { request, _ in
            if request.url.lastPathComponent == "error" {
                return .init(statusCode: errorCode)
            } else if request.url.lastPathComponent == "okay" {
                return .okay()
            } else {
                throw StringError("unknown request \(request.url)")
            }
        }

        // make the initial errors
        do {
            let counter = SendableBox(0)
            for index in (0 ..< maxErrors) {
                let response = try await httpClient.get(URL("\(host)/\(index)/error"))
                await counter.increment()
                XCTAssertEqual(response.statusCode, errorCode)
            }
            let count = await counter.value
            XCTAssertEqual(count, maxErrors, "expected results count to match")
        }

        // these should not circuit break since they are deliberately aged
        let total = Int.random(in: 10 ..< 20)
        let count = ThreadSafeBox<Int>(0)

        for index in (0 ..< total) {
            // age it
            let sleepInterval = SendableTimeInterval.milliseconds(ageInMilliseconds)
            try await Task.sleep(nanoseconds: UInt64(sleepInterval.nanoseconds()!))
            let response = try await httpClient.get("\(host)/\(index)/okay")
            count.increment()
            XCTAssertEqual(response.statusCode, 200, "expected status code to match")
        }

        XCTAssertEqual(count.get(), total, "expected results count to match")
    }

    func testHTTPClientHeaders() async throws {
        var headers = HTTPClientHeaders()

        let items = (1 ... Int.random(in: 10 ... 20)).map { index in HTTPClientHeaders.Item(name: "header-\(index)", value: UUID().uuidString) }
        headers.add(items)

        XCTAssertEqual(headers.count, items.count, "headers count should match")
        items.forEach { item in
            XCTAssertEqual(headers.get(item.name).first, item.value, "headers value should match")
        }

        headers.add(items.first!)
        XCTAssertEqual(headers.count, items.count, "headers count should match (no duplicates)")

        let name = UUID().uuidString
        let values = (1 ... Int.random(in: 10 ... 20)).map { "value-\($0)" }
        values.forEach { value in
            headers.add(name: name, value: value)
        }
        XCTAssertEqual(headers.count, items.count + 1, "headers count should match (no duplicates)")
        XCTAssertEqual(values, headers.get(name), "multiple headers value should match")
    }

    func testExceedsDownloadSizeLimitProgress() async throws {
        let maxSize: Int64 = 50

        let httpClient = HTTPClient { request, progress in
            switch request.method {
            case .head:
                return .init(
                    statusCode: 200,
                    headers: .init([.init(name: "Content-Length", value: "0")])
                )
            case .get:
                try progress?(Int64(maxSize * 2), 0)
            default:
                XCTFail("method should match")
            }

            fatalError("unreachable")
        }

        var request = HTTPClient.Request(url: "http://test")
        request.options.maximumResponseSizeInBytes = 10

        do {
            let response = try await httpClient.execute(request)
            XCTFail("unexpected success \(response)")
        } catch {
            XCTAssertEqual(error as? HTTPClientError, .responseTooLarge(maxSize * 2), "expected error to match")
        }
    }

    func testMaxConcurrency() async throws {
        let maxConcurrentRequests = 2
        let concurrentRequests = SendableBox(0)

        var configuration = HTTPClient.Configuration()
        configuration.maxConcurrentRequests = maxConcurrentRequests
        let httpClient = HTTPClient(configuration: configuration) { request, _ in
            await concurrentRequests.increment()

            if await concurrentRequests.value! > maxConcurrentRequests {
                XCTFail("too many concurrent requests \(concurrentRequests), expected \(maxConcurrentRequests)")
            }

            await concurrentRequests.decrement()

            return .okay()
        }

        let total = 1000
        try await withThrowingTaskGroup(of: HTTPClient.Response.self) { group in
            for _ in 0..<total {
                group.addTask {
                    try await httpClient.get("http://localhost/test")
                }
            }

            var results = [HTTPClient.Response]()
            for try await result in group {
                results.append(result)
            }

            XCTAssertEqual(results.count, total, "expected number of results to match")

            for result in results {
                XCTAssertEqual(result.statusCode, 200, "expected '200 okay' response")
            }
        }
    }
}

private func assertRequestHeaders(_ headers: HTTPClientHeaders, expected: HTTPClientHeaders) {
    let noAgent = HTTPClientHeaders(headers.filter { $0.name != "User-Agent" })
    XCTAssertEqual(noAgent, expected, "expected headers to match")
}

private func assertResponseHeaders(_ headers: HTTPClientHeaders, expected: HTTPClientHeaders) {
    XCTAssertEqual(headers, expected, "expected headers to match")
}
