//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@testable import Basics
import _InternalTestSupport
import XCTest

final class LegacyHTTPClientTests: XCTestCase {
    func testHead() {
        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let responseStatus = Int.random(in: 201 ..< 500)
        let responseHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let responseBody: Data? = nil

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            XCTAssertEqual(request.url, url, "url should match")
            XCTAssertEqual(request.method, .head, "method should match")
            self.assertRequestHeaders(request.headers, expected: requestHeaders)
            completion(.success(LegacyHTTPClient.Response(statusCode: responseStatus, headers: responseHeaders, body: responseBody)))
        }

        let httpClient = LegacyHTTPClient(handler: handler)

        let promise = XCTestExpectation(description: "completed")
        httpClient.head(url, headers: requestHeaders) { result in
            switch result {
            case .failure(let error):
                XCTFail("unexpected error \(error)")
            case .success(let response):
                XCTAssertEqual(response.statusCode, responseStatus, "statusCode should match")
                self.assertResponseHeaders(response.headers, expected: responseHeaders)
                XCTAssertEqual(response.body, responseBody, "body should match")
            }
            promise.fulfill()
        }

        wait(for: [promise], timeout: 1)
    }

    func testGet() {
        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let responseStatus = Int.random(in: 201 ..< 500)
        let responseHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let responseBody = Data(UUID().uuidString.utf8)

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            XCTAssertEqual(request.url, url, "url should match")
            XCTAssertEqual(request.method, .get, "method should match")
            self.assertRequestHeaders(request.headers, expected: requestHeaders)
            completion(.success(LegacyHTTPClient.Response(statusCode: responseStatus, headers: responseHeaders, body: responseBody)))
        }

        let httpClient = LegacyHTTPClient(handler: handler)

        let promise = XCTestExpectation(description: "completed")
        httpClient.get(url, headers: requestHeaders) { result in
            switch result {
            case .failure(let error):
                XCTFail("unexpected error \(error)")
            case .success(let response):
                XCTAssertEqual(response.statusCode, responseStatus, "statusCode should match")
                self.assertResponseHeaders(response.headers, expected: responseHeaders)
                XCTAssertEqual(response.body, responseBody, "body should match")
            }
            promise.fulfill()
        }

        wait(for: [promise], timeout: 1)
    }

    func testPost() {
        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let requestBody = Data(UUID().uuidString.utf8)
        let responseStatus = Int.random(in: 201 ..< 500)
        let responseHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let responseBody = Data(UUID().uuidString.utf8)

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            XCTAssertEqual(request.url, url, "url should match")
            XCTAssertEqual(request.method, .post, "method should match")
            self.assertRequestHeaders(request.headers, expected: requestHeaders)
            XCTAssertEqual(request.body, requestBody, "body should match")
            completion(.success(LegacyHTTPClient.Response(statusCode: responseStatus, headers: responseHeaders, body: responseBody)))
        }

        let httpClient = LegacyHTTPClient(handler: handler)

        let promise = XCTestExpectation(description: "completed")
        httpClient.post(url, body: requestBody, headers: requestHeaders) { result in
            switch result {
            case .failure(let error):
                XCTFail("unexpected error \(error)")
            case .success(let response):
                XCTAssertEqual(response.statusCode, responseStatus, "statusCode should match")
                self.assertResponseHeaders(response.headers, expected: responseHeaders)
                XCTAssertEqual(response.body, responseBody, "body should match")
            }
            promise.fulfill()
        }

        wait(for: [promise], timeout: 1)
    }

    func testPut() {
        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let requestBody = Data(UUID().uuidString.utf8)
        let responseStatus = Int.random(in: 201 ..< 500)
        let responseHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let responseBody = Data(UUID().uuidString.utf8)

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            XCTAssertEqual(request.url, url, "url should match")
            XCTAssertEqual(request.method, .put, "method should match")
            self.assertRequestHeaders(request.headers, expected: requestHeaders)
            XCTAssertEqual(request.body, requestBody, "body should match")
            completion(.success(LegacyHTTPClient.Response(statusCode: responseStatus, headers: responseHeaders, body: responseBody)))
        }

        let httpClient = LegacyHTTPClient(handler: handler)

        let promise = XCTestExpectation(description: "completed")
        httpClient.put(url, body: requestBody, headers: requestHeaders) { result in
            switch result {
            case .failure(let error):
                XCTFail("unexpected error \(error)")
            case .success(let response):
                XCTAssertEqual(response.statusCode, responseStatus, "statusCode should match")
                self.assertResponseHeaders(response.headers, expected: responseHeaders)
                XCTAssertEqual(response.body, responseBody, "body should match")
            }
            promise.fulfill()
        }

        wait(for: [promise], timeout: 1)
    }

    func testDelete() {
        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let responseStatus = Int.random(in: 201 ..< 500)
        let responseHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let responseBody = Data(UUID().uuidString.utf8)

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            XCTAssertEqual(request.url, url, "url should match")
            XCTAssertEqual(request.method, .delete, "method should match")
            self.assertRequestHeaders(request.headers, expected: requestHeaders)
            completion(.success(LegacyHTTPClient.Response(statusCode: responseStatus, headers: responseHeaders, body: responseBody)))
        }

        let httpClient = LegacyHTTPClient(handler: handler)

        let promise = XCTestExpectation(description: "completed")
        httpClient.delete(url, headers: requestHeaders) { result in
            switch result {
            case .failure(let error):
                XCTFail("unexpected error \(error)")
            case .success(let response):
                XCTAssertEqual(response.statusCode, responseStatus, "statusCode should match")
                self.assertResponseHeaders(response.headers, expected: responseHeaders)
                XCTAssertEqual(response.body, responseBody, "body should match")
            }
            promise.fulfill()
        }

        wait(for: [promise], timeout: 1)
    }

    func testExtraHeaders() {
        let url = URL("http://test")
        let globalHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            var expectedHeaders = globalHeaders
            expectedHeaders.merge(requestHeaders)
            self.assertRequestHeaders(request.headers, expected: expectedHeaders)
            completion(.success(LegacyHTTPClient.Response(statusCode: 200)))
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.requestHeaders = globalHeaders

        var request = LegacyHTTPClient.Request(method: .get, url: url, headers: requestHeaders)
        request.options.addUserAgent = true

        let promise = XCTestExpectation(description: "completed")
        httpClient.execute(request) { result in
            switch result {
            case .failure(let error):
                XCTFail("unexpected error \(error)")
            case .success(let response):
                XCTAssertEqual(response.statusCode, 200, "statusCode should match")
            }
            promise.fulfill()
        }

        wait(for: [promise], timeout: 1)
    }

    func testUserAgent() {
        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            XCTAssertTrue(request.headers.contains("User-Agent"), "expecting User-Agent")
            self.assertRequestHeaders(request.headers, expected: requestHeaders)
            completion(.success(LegacyHTTPClient.Response(statusCode: 200)))
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        var request = LegacyHTTPClient.Request(method: .get, url: url, headers: requestHeaders)
        request.options.addUserAgent = true

        let promise = XCTestExpectation(description: "completed")
        httpClient.execute(request) { result in
            switch result {
            case .failure(let error):
                XCTFail("unexpected error \(error)")
            case .success(let response):
                XCTAssertEqual(response.statusCode, 200, "statusCode should match")
            }
            promise.fulfill()
        }

        wait(for: [promise], timeout: 1)
    }

    func testNoUserAgent() {
        let url = URL("http://test")
        let requestHeaders = HTTPClientHeaders([HTTPClientHeaders.Item(name: UUID().uuidString, value: UUID().uuidString)])

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            XCTAssertFalse(request.headers.contains("User-Agent"), "expecting User-Agent")
            self.assertRequestHeaders(request.headers, expected: requestHeaders)
            completion(.success(LegacyHTTPClient.Response(statusCode: 200)))
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        var request = LegacyHTTPClient.Request(method: .get, url: url, headers: requestHeaders)
        request.options.addUserAgent = false

        let promise = XCTestExpectation(description: "completed")
        httpClient.execute(request) { result in
            switch result {
            case .failure(let error):
                XCTFail("unexpected error \(error)")
            case .success(let response):
                XCTAssertEqual(response.statusCode, 200, "statusCode should match")
            }
            promise.fulfill()
        }

        wait(for: [promise], timeout: 1)
    }

    func testAuthorization() {
        let url = URL("http://test")

        do {
            let authorization = UUID().uuidString

            let handler: LegacyHTTPClient.Handler = { request, _, completion in
                XCTAssertTrue(request.headers.contains("Authorization"), "expecting Authorization")
                XCTAssertEqual(request.headers.get("Authorization").first, authorization, "expecting Authorization to match")
                completion(.success(LegacyHTTPClient.Response(statusCode: 200)))
            }

            let httpClient = LegacyHTTPClient(handler: handler)
            var request = LegacyHTTPClient.Request(method: .get, url: url)

            request.options.authorizationProvider = { requestUrl in
                requestUrl == url ? authorization : nil
            }

            let promise = XCTestExpectation(description: "completed")
            httpClient.execute(request) { result in
                switch result {
                case .failure(let error):
                    XCTFail("unexpected error \(error)")
                case .success(let response):
                    XCTAssertEqual(response.statusCode, 200, "statusCode should match")
                }
                promise.fulfill()
            }

            wait(for: [promise], timeout: 1)
        }

        do {
            let handler: LegacyHTTPClient.Handler = { request, _, completion in
                XCTAssertFalse(request.headers.contains("Authorization"), "not expecting Authorization")
                completion(.success(LegacyHTTPClient.Response(statusCode: 200)))
            }

            let httpClient = LegacyHTTPClient(handler: handler)
            var request = LegacyHTTPClient.Request(method: .get, url: url)
            request.options.authorizationProvider = { _ in "" }

            let promise = XCTestExpectation(description: "completed")
            httpClient.execute(request) { result in
                switch result {
                case .failure(let error):
                    XCTFail("unexpected error \(error)")
                case .success(let response):
                    XCTAssertEqual(response.statusCode, 200, "statusCode should match")
                }
                promise.fulfill()
            }

            wait(for: [promise], timeout: 1)
        }
    }

    func testValidResponseCodes() {
        let statusCode = Int.random(in: 201 ..< 500)
        let brokenHandler: LegacyHTTPClient.Handler = { _, _, completion in
            completion(.failure(HTTPClientError.badResponseStatusCode(statusCode)))
        }

        let httpClient = LegacyHTTPClient(handler: brokenHandler)
        var request = LegacyHTTPClient.Request(method: .get, url: "http://test")
        request.options.validResponseCodes = [200]

        let promise = XCTestExpectation(description: "completed")
        httpClient.execute(request) { result in
            switch result {
            case .failure(let error):
                XCTAssertEqual(error as? HTTPClientError, .badResponseStatusCode(statusCode), "expected error to match")
            case .success(let response):
                XCTFail("unexpected success \(response)")
            }
            promise.fulfill()
        }

        wait(for: [promise], timeout: 1)
    }

    func testExponentialBackoff() {
        let count = ThreadSafeBox<Int>(0)
        let lastCall = ThreadSafeBox<Date>()
        let maxAttempts = 5
        let errorCode = Int.random(in: 500 ..< 600)
        let delay = SendableTimeInterval.milliseconds(100)

        let brokenHandler: LegacyHTTPClient.Handler = { _, _, completion in
            let expectedDelta = pow(2.0, Double(count.get(default: 0) - 1)) * delay.timeInterval()!
            let delta = lastCall.get().flatMap { Date().timeIntervalSince($0) } ?? 0
            XCTAssertEqual(delta, expectedDelta, accuracy: 0.1)

            count.increment()
            lastCall.put(Date())
            completion(.success(LegacyHTTPClient.Response(statusCode: errorCode)))
        }

        let httpClient = LegacyHTTPClient(handler: brokenHandler)
        var request = LegacyHTTPClient.Request(method: .get, url: "http://test")
        request.options.retryStrategy = .exponentialBackoff(maxAttempts: maxAttempts, baseDelay: delay)

        let promise = XCTestExpectation(description: "completed")
        httpClient.execute(request) { result in
            switch result {
            case .failure(let error):
                XCTFail("unexpected error \(error)")
            case .success(let response):
                XCTAssertEqual(response.statusCode, errorCode)
                XCTAssertEqual(count.get(), maxAttempts, "retries should match")
            }
            promise.fulfill()
        }

        let timeout = Double(Int(pow(2.0, Double(maxAttempts))) * delay.milliseconds()!) / 1000
        wait(for: [promise], timeout: 1.0 + timeout)
    }

    func testHostCircuitBreaker() {
        let maxErrors = 5
        let errorCode = Int.random(in: 500 ..< 600)
        let age = SendableTimeInterval.seconds(5)

        let host = "http://tes-\(UUID().uuidString).com"
        let httpClient = LegacyHTTPClient(handler: { _, _, completion in
            completion(.success(LegacyHTTPClient.Response(statusCode: errorCode)))
        })
        httpClient.configuration.circuitBreakerStrategy = .hostErrors(maxErrors: maxErrors, age: age)

        // make the initial errors
        do {
            let sync = DispatchGroup()
            let count = ThreadSafeBox<Int>(0)
            (0 ..< maxErrors).forEach { index in
                sync.enter()
                httpClient.get(URL("\(host)/\(index)/foo")) { result in
                    defer { sync.leave() }
                    count.increment()
                    switch result {
                    case .failure(let error):
                        XCTFail("unexpected failure \(error)")
                    case .success(let response):
                        XCTAssertEqual(response.statusCode, errorCode)
                    }
                }
            }
            XCTAssertEqual(sync.wait(timeout: .now() + .seconds(1)), .success, "should not timeout")
            XCTAssertEqual(count.get(), maxErrors, "expected results count to match")
        }

        // these should all circuit break
        let sync = DispatchGroup()
        let count = ThreadSafeBox<Int>(0)
        let total = Int.random(in: 10 ..< 20)
        (0 ..< total).forEach { index in
            sync.enter()
            httpClient.get(URL("\(host)/\(index)/foo")) { result in
                defer { sync.leave() }
                count.increment()
                switch result {
                case .failure(let error):
                    XCTAssertEqual(error as? HTTPClientError, .circuitBreakerTriggered, "expected error to match")
                case .success(let response):
                    XCTFail("unexpected success \(response)")
                }
            }
        }

        XCTAssertEqual(sync.wait(timeout: .now() + .seconds(1)), .success, "should not timeout")
        XCTAssertEqual(count.get(), total, "expected results count to match")
    }

    func testHostCircuitBreakerAging() {
        let maxErrors = 5
        let errorCode = Int.random(in: 500 ..< 600)
        let ageInMilliseconds = 100

        let host = "http://tes-\(UUID().uuidString).com"
        let httpClient = LegacyHTTPClient(handler: { request, _, completion in
            if request.url.lastPathComponent == "error" {
                completion(.success(LegacyHTTPClient.Response(statusCode: errorCode)))
            } else if request.url.lastPathComponent == "okay" {
                completion(.success(.okay()))
            } else {
                completion(.failure(StringError("unknown request \(request.url)")))
            }
        })
        httpClient.configuration.circuitBreakerStrategy = .hostErrors(
            maxErrors: maxErrors,
            age: .milliseconds(ageInMilliseconds)
        )


        // make the initial errors
        do {
            let sync = DispatchGroup()
            let count = ThreadSafeBox<Int>(0)
            (0 ..< maxErrors).forEach { index in
                sync.enter()
                httpClient.get(URL("\(host)/\(index)/error")) { result in
                    defer { sync.leave() }
                    count.increment()
                    switch result {
                    case .failure(let error):
                        XCTFail("unexpected failure \(error)")
                    case .success(let response):
                        XCTAssertEqual(response.statusCode, errorCode)
                    }
                }
            }
            XCTAssertEqual(sync.wait(timeout: .now() + .seconds(1)), .success, "should not timeout")
            XCTAssertEqual(count.get(), maxErrors, "expected results count to match")
        }

        // these should not circuit break since they are deliberately aged
        let sync = DispatchGroup()
        let total = Int.random(in: 10 ..< 20)
        let count = ThreadSafeBox<Int>(0)

        (0 ..< total).forEach { index in
            sync.enter()
            // age it
            DispatchQueue.sharedConcurrent.asyncAfter(deadline: .now() + .milliseconds(ageInMilliseconds)) {
                httpClient.get(URL("\(host)/\(index)/okay")) { result in
                    defer { sync.leave() }
                    count.increment()
                    switch result {
                    case .failure(let error):
                        XCTFail("unexpected error \(error)")
                    case .success(let response):
                        XCTAssertEqual(response.statusCode, 200, "expected status code to match")
                    }
                }
            }
        }

        let timeout = DispatchTime.now() + .seconds(1) + .milliseconds(ageInMilliseconds * maxErrors)
        XCTAssertEqual(sync.wait(timeout: timeout), .success, "should not timeout")
        XCTAssertEqual(count.get(), total, "expected results count to match")
    }

    func testExceedsDownloadSizeLimitProgress() throws {
        let maxSize: Int64 = 50

        let httpClient = LegacyHTTPClient(handler: { request, progress, completion in
            switch request.method {
            case .head:
                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([.init(name: "Content-Length", value: "0")])
                )))
            case .get:
                do {
                    try progress?(Int64(maxSize * 2), 0)
                } catch {
                    completion(.failure(error))
                }
            default:
                XCTFail("method should match")
            }
        })

        var request = LegacyHTTPClient.Request(url: "http://test")
        request.options.maximumResponseSizeInBytes = 10

        let promise = XCTestExpectation(description: "completed")
        httpClient.execute(request) { result in
            switch result {
            case .failure(let error):
                XCTAssertEqual(error as? HTTPClientError, .responseTooLarge(maxSize * 2), "expected error to match")
            case .success(let response):
                XCTFail("unexpected success \(response)")
            }
            promise.fulfill()
        }

        wait(for: [promise], timeout: 1)
    }

    func testMaxConcurrency() throws {
        let maxConcurrentRequests = 2
        var concurrentRequests = 0
        let concurrentRequestsLock = NSLock()

        var configuration = LegacyHTTPClient.Configuration()
        configuration.maxConcurrentRequests = maxConcurrentRequests
        let httpClient = LegacyHTTPClient(configuration: configuration, handler: { request, _, completion in
            defer {
                concurrentRequestsLock.withLock {
                    concurrentRequests -= 1
                }
            }

            concurrentRequestsLock.withLock {
                concurrentRequests += 1
                if concurrentRequests > maxConcurrentRequests {
                    XCTFail("too many concurrent requests \(concurrentRequests), expected \(maxConcurrentRequests)")
                }
            }

            completion(.success(.okay()))
        })

        let total = 1000
        let sync = DispatchGroup()
        let results = ThreadSafeArrayStore<Result<LegacyHTTPClient.Response, Error>>()
        for _ in 0 ..< total {
            sync.enter()
            httpClient.get(URL("http://localhost/test")) { result in
                defer { sync.leave() }
                results.append(result)
            }
        }

        if case .timedOut = sync.wait(timeout: .now() + .seconds(5)) {
            throw StringError("requests timed out")
        }

        XCTAssertEqual(results.count, total, "expected number of results to match")
        for result in results.get() {
            XCTAssertEqual(try? result.get().statusCode, 200, "expected '200 okay' response")
        }
    }

    func testCancel() throws {
        let observability = ObservabilitySystem.makeForTesting()
        let cancellator = Cancellator(observabilityScope: observability.topScope)

        let total = min(10, ProcessInfo.processInfo.activeProcessorCount / 2)
        // this DispatchGroup is used to wait for the requests to start before calling cancel
        let startGroup = DispatchGroup()
        // this DispatchGroup is used to park the delayed threads that would be cancelled
        let terminatedGroup = DispatchGroup()
        terminatedGroup.enter()
        // this DispatchGroup is used to monitor the outstanding threads that would be cancelled and completion handlers thrown away
        let outstandingGroup = DispatchGroup()

        let httpClient = LegacyHTTPClient(handler: { request, _, completion in
            print("handling \(request.url)")
            if Int(request.url.lastPathComponent)! < total / 2 {
                DispatchQueue.sharedConcurrent.async {
                    defer { startGroup.leave() }
                    print("\(request.url) okay")
                    completion(.success(.okay()))
                }
            } else {
                defer { startGroup.leave() }
                outstandingGroup.enter()
                print("\(request.url) waiting to be cancelled")
                DispatchQueue.sharedConcurrent.async {
                    defer { outstandingGroup.leave() }
                    XCTAssertEqual(.success, terminatedGroup.wait(timeout: .now() + 5), "timeout waiting on terminated signal")
                    completion(.failure(StringError("should be cancelled")))
                }
            }
        })

        cancellator.register(name: "http client", handler: httpClient)

        let finishGroup = DispatchGroup()
        let results = ThreadSafeKeyValueStore<URL, Result<LegacyHTTPClient.Response, Error>>()
        for index in 0 ..< total {
            startGroup.enter()
            finishGroup.enter()
            let url = URL("http://test/\(index)")
            httpClient.head(url) { result in
                defer { finishGroup.leave() }
                results[url] = result
            }
        }

        XCTAssertEqual(.success, startGroup.wait(timeout: .now() + 5), "timeout starting tasks")

        let cancelled = cancellator._cancel(deadline: .now() + .seconds(1))
        XCTAssertEqual(cancelled, 1, "expected to be terminated")
        XCTAssertNoDiagnostics(observability.diagnostics)
        // this releases the http handler threads that are waiting to test if the call was cancelled
        terminatedGroup.leave()

        XCTAssertEqual(.success, finishGroup.wait(timeout: .now() + 5), "timeout finishing tasks")

        XCTAssertEqual(results.count, total, "expected \(total) results")
        for (url, result) in results.get() {
            switch (Int(url.lastPathComponent)! < total / 2, result) {
            case (true, .success):
                break // as expected!
            case (true, .failure(let error)):
                XCTFail("expected success, but failed with \(type(of: error)) '\(error)'")
            case (false, .success):
                XCTFail("expected operation to be cancelled")
            case (false, .failure(let error)):
                XCTAssert(error is CancellationError, "expected error to be CancellationError, but was \(type(of: error)) '\(error)'")
            }
        }

        // wait for outstanding threads that would be cancelled and completion handlers thrown away
        XCTAssertEqual(.success, outstandingGroup.wait(timeout: .now() + .seconds(5)), "timeout waiting for outstanding tasks")
    }

    private func assertRequestHeaders(_ headers: HTTPClientHeaders, expected: HTTPClientHeaders) {
        let noAgent = HTTPClientHeaders(headers.filter { $0.name != "User-Agent" })
        XCTAssertEqual(noAgent, expected, "expected headers to match")
    }

    private func assertResponseHeaders(_ headers: HTTPClientHeaders, expected: HTTPClientHeaders) {
        XCTAssertEqual(headers, expected, "expected headers to match")
    }
}
