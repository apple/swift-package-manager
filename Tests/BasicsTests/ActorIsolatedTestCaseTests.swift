//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import XCTest

// The tests in this file are used to check that test cases with actor isolation
// are correctly seen and ingested during testing.

@globalActor
final actor TestActor {
    static let shared = TestActor()
}

@TestActor
class ActorIsolatedTestCaseTests: XCTestCase {
    func test_actorIsolatedByClass() { }
    func test_actorIsolatedByClassAndAsync() async { }
}

class IndividuallyActorIsolatedTestCaseTests: XCTestCase {
    @TestActor
    func test_actorIsolatedByClass() { }

    @TestActor
    func test_actorIsolatedByClassAndAsync() async { }
}

class MainActorIsolatedTestCaseTests: XCTestCase {
    @MainActor
    func test_actorIsolatedToMain() { }
}
