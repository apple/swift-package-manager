//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Commands
import PackageModel
import _InternalTestSupport
import XCTest

final class TestCommandTests: CommandsTestCase {
    private func execute(_ args: [String], packagePath: AbsolutePath? = nil) async throws -> (stdout: String, stderr: String) {
        try await SwiftPM.Test.execute(args, packagePath: packagePath)
    }

    func testUsage() async throws {
        let stdout = try await execute(["-help"]).stdout
        XCTAssert(stdout.contains("USAGE: swift test"), "got stdout:\n" + stdout)
    }

    func testSeeAlso() async throws {
        let stdout = try await execute(["--help"]).stdout
        XCTAssert(stdout.contains("SEE ALSO: swift build, swift run, swift package"), "got stdout:\n" + stdout)
    }

    func testVersion() async throws {
        let stdout = try await execute(["--version"]).stdout
        XCTAssert(stdout.contains("Swift Package Manager"), "got stdout:\n" + stdout)
    }

    func testNumWorkersParallelRequirement() async throws {
        #if !os(macOS)
        // Running swift-test fixtures on linux is not yet possible.
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        try await fixture(name: "Miscellaneous/EchoExecutable") { fixturePath in
            await XCTAssertThrowsCommandExecutionError(try await execute(["--num-workers", "1"])) { error in
                XCTAssertMatch(error.stderr, .contains("error: --num-workers must be used with --parallel"))
            }
        }
    }

    func testNumWorkersValue() async throws {
        #if !os(macOS)
        // Running swift-test fixtures on linux is not yet possible.
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        try await fixture(name: "Miscellaneous/EchoExecutable") { fixturePath in
            await XCTAssertThrowsCommandExecutionError(try await execute(["--parallel", "--num-workers", "0"])) { error in
                XCTAssertMatch(error.stderr, .contains("error: '--num-workers' must be greater than zero"))
            }
        }
    }

    func testEnableDisableTestability() async throws {
        // default should run with testability
        try await fixture(name: "Miscellaneous/TestableExe") { fixturePath in
            do {
                let result = try await execute(["--vv"], packagePath: fixturePath)
                XCTAssertMatch(result.stderr, .contains("-enable-testing"))
            }
        }

        // disabled
        try await fixture(name: "Miscellaneous/TestableExe") { fixturePath in
            await XCTAssertThrowsCommandExecutionError(try await execute(["--disable-testable-imports", "--vv"], packagePath: fixturePath)) { error in
                XCTAssertMatch(error.stderr, .contains("was not compiled for testing"))
            }
        }

        // enabled
        try await fixture(name: "Miscellaneous/TestableExe") { fixturePath in
            do {
                let result = try await execute(["--enable-testable-imports", "--vv"], packagePath: fixturePath)
                XCTAssertMatch(result.stderr, .contains("-enable-testing"))
            }
        }
    }

    func testSwiftTestParallel() async throws {
        try await fixture(name: "Miscellaneous/ParallelTestsPkg") { fixturePath in
            // First try normal serial testing.
            await XCTAssertThrowsCommandExecutionError(try await SwiftPM.Test.execute(packagePath: fixturePath)) { error in
                // in "swift test" test output goes to stdout
                XCTAssertMatch(error.stdout, .contains("Executed 2 tests"))
                XCTAssertNoMatch(error.stdout, .contains("[3/3]"))
            }

            // Try --no-parallel.
            await XCTAssertThrowsCommandExecutionError(try await SwiftPM.Test.execute(["--no-parallel"], packagePath: fixturePath)) { error in
                // in "swift test" test output goes to stdout
                XCTAssertMatch(error.stdout, .contains("Executed 2 tests"))
                XCTAssertNoMatch(error.stdout, .contains("[3/3]"))
            }

            // Run tests in parallel.
            await XCTAssertThrowsCommandExecutionError(try await SwiftPM.Test.execute(["--parallel"], packagePath: fixturePath)) { error in
                // in "swift test" test output goes to stdout
                XCTAssertMatch(error.stdout, .contains("testExample1"))
                XCTAssertMatch(error.stdout, .contains("testExample2"))
                XCTAssertNoMatch(error.stdout, .contains("'ParallelTestsTests' passed"))
                XCTAssertMatch(error.stdout, .contains("'ParallelTestsFailureTests' failed"))
                XCTAssertMatch(error.stdout, .contains("[3/3]"))
            }

            do {
                let xUnitOutput = fixturePath.appending("result.xml")
                // Run tests in parallel with verbose output.
                await XCTAssertThrowsCommandExecutionError(
                    try await SwiftPM.Test.execute(["--parallel", "--verbose", "--xunit-output", xUnitOutput.pathString], packagePath: fixturePath)
                ) { error in
                    // in "swift test" test output goes to stdout
                    XCTAssertMatch(error.stdout, .contains("testExample1"))
                    XCTAssertMatch(error.stdout, .contains("testExample2"))
                    XCTAssertMatch(error.stdout, .contains("'ParallelTestsTests' passed"))
                    XCTAssertMatch(error.stdout, .contains("'ParallelTestsFailureTests' failed"))
                    XCTAssertMatch(error.stdout, .contains("[3/3]"))
                }

                // Check the xUnit output.
                XCTAssertFileExists(xUnitOutput)
                let contents: String = try localFileSystem.readFileContents(xUnitOutput)
                XCTAssertMatch(contents, .contains("tests=\"3\" failures=\"1\""))
                XCTAssertMatch(contents, .regex("time=\"[0-9]+\\.[0-9]+\""))
                XCTAssertNoMatch(contents, .contains("time=\"0.0\""))
            }
        }
    }

    func testSwiftTestXMLOutputWhenEmpty() async throws {
        try await fixture(name: "Miscellaneous/EmptyTestsPkg") { fixturePath in
            let xUnitOutput = fixturePath.appending("result.xml")
            // Run tests in parallel with verbose output.
            let stdout = try await SwiftPM.Test.execute(["--parallel", "--verbose", "--xunit-output", xUnitOutput.pathString], packagePath: fixturePath).stdout
            // in "swift test" test output goes to stdout
            XCTAssertNoMatch(stdout, .contains("passed"))
            XCTAssertNoMatch(stdout, .contains("failed"))

            // Check the xUnit output.
            XCTAssertFileExists(xUnitOutput)
            let contents: String = try localFileSystem.readFileContents(xUnitOutput)
            XCTAssertMatch(contents, .contains("tests=\"0\" failures=\"0\""))
        }
    }

    func testSwiftTestFilter() async throws {
        try await fixture(name: "Miscellaneous/SkipTests") { fixturePath in
            let (stdout, _) = try await SwiftPM.Test.execute(["--filter", ".*1"], packagePath: fixturePath)
            // in "swift test" test output goes to stdout
            XCTAssertMatch(stdout, .contains("testExample1"))
            XCTAssertNoMatch(stdout, .contains("testExample2"))
            XCTAssertNoMatch(stdout, .contains("testExample3"))
            XCTAssertNoMatch(stdout, .contains("testExample4"))
        }

        try await fixture(name: "Miscellaneous/SkipTests") { fixturePath in
            let (stdout, _) = try await SwiftPM.Test.execute(["--filter", "SomeTests", "--skip", ".*1", "--filter", "testExample3"], packagePath: fixturePath)
            // in "swift test" test output goes to stdout
            XCTAssertNoMatch(stdout, .contains("testExample1"))
            XCTAssertMatch(stdout, .contains("testExample2"))
            XCTAssertMatch(stdout, .contains("testExample3"))
            XCTAssertNoMatch(stdout, .contains("testExample4"))
        }
    }

    func testSwiftTestSkip() async throws {
        try await fixture(name: "Miscellaneous/SkipTests") { fixturePath in
            let (stdout, _) = try await SwiftPM.Test.execute(["--skip", "SomeTests"], packagePath: fixturePath)
            // in "swift test" test output goes to stdout
            XCTAssertNoMatch(stdout, .contains("testExample1"))
            XCTAssertNoMatch(stdout, .contains("testExample2"))
            XCTAssertMatch(stdout, .contains("testExample3"))
            XCTAssertMatch(stdout, .contains("testExample4"))
        }

        try await fixture(name: "Miscellaneous/SkipTests") { fixturePath in
            let (stdout, _) = try await SwiftPM.Test.execute(["--filter", "ExampleTests", "--skip", ".*2", "--filter", "MoreTests", "--skip", "testExample3"], packagePath: fixturePath)
            // in "swift test" test output goes to stdout
            XCTAssertMatch(stdout, .contains("testExample1"))
            XCTAssertNoMatch(stdout, .contains("testExample2"))
            XCTAssertNoMatch(stdout, .contains("testExample3"))
            XCTAssertMatch(stdout, .contains("testExample4"))
        }

        try await fixture(name: "Miscellaneous/SkipTests") { fixturePath in
            let (stdout, stderr) = try await SwiftPM.Test.execute(["--skip", "Tests"], packagePath: fixturePath)
            // in "swift test" test output goes to stdout
            XCTAssertNoMatch(stdout, .contains("testExample1"))
            XCTAssertNoMatch(stdout, .contains("testExample2"))
            XCTAssertNoMatch(stdout, .contains("testExample3"))
            XCTAssertNoMatch(stdout, .contains("testExample4"))
            XCTAssertMatch(stderr, .contains("No matching test cases were run"))
        }
    }

    func testEnableTestDiscoveryDeprecation() async throws {
        let compilerDiagnosticFlags = ["-Xswiftc", "-Xfrontend", "-Xswiftc", "-Rmodule-interface-rebuild"]
        #if canImport(Darwin)
        // should emit when LinuxMain is present
        try await fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            let (_, stderr) = try await SwiftPM.Test.execute(["--enable-test-discovery"] + compilerDiagnosticFlags, packagePath: fixturePath)
            XCTAssertMatch(stderr, .contains("warning: '--enable-test-discovery' option is deprecated"))
        }

        // should emit when LinuxMain is not present
        try await fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            try localFileSystem.writeFileContents(fixturePath.appending(components: "Tests", SwiftModule.defaultTestEntryPointName), bytes: "fatalError(\"boom\")")
            let (_, stderr) = try await SwiftPM.Test.execute(["--enable-test-discovery"] + compilerDiagnosticFlags, packagePath: fixturePath)
            XCTAssertMatch(stderr, .contains("warning: '--enable-test-discovery' option is deprecated"))
        }
        #else
        // should emit when LinuxMain is present
        try await fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            let (_, stderr) = try await SwiftPM.Test.execute(["--enable-test-discovery"] + compilerDiagnosticFlags, packagePath: fixturePath)
            XCTAssertMatch(stderr, .contains("warning: '--enable-test-discovery' option is deprecated"))
        }
        // should not emit when LinuxMain is present
        try await fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            try localFileSystem.writeFileContents(fixturePath.appending(components: "Tests", SwiftModule.defaultTestEntryPointName), bytes: "fatalError(\"boom\")")
            let (_, stderr) = try await SwiftPM.Test.execute(["--enable-test-discovery"] + compilerDiagnosticFlags, packagePath: fixturePath)
            XCTAssertNoMatch(stderr, .contains("warning: '--enable-test-discovery' option is deprecated"))
        }
        #endif
    }

    func testList() async throws {
        try await fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            let (stdout, stderr) = try await SwiftPM.Test.execute(["list"], packagePath: fixturePath)
            // build was run
            XCTAssertMatch(stderr, .contains("Build complete!"))
            // getting the lists
            XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/testExample1"))
            XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/test_Example2"))
            XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/testThrowing"))
        }

        try await fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            // build first
            do {
                let (stdout, _) = try await SwiftPM.Build.execute(["--build-tests"], packagePath: fixturePath)
                XCTAssertMatch(stdout, .contains("Build complete!"))
            }
            // list
            do {
                let (stdout, stderr) = try await SwiftPM.Test.execute(["list"], packagePath: fixturePath)
                // build was run
                XCTAssertMatch(stderr, .contains("Build complete!"))
                // getting the lists
                XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/testExample1"))
                XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/test_Example2"))
                XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/testThrowing"))
            }
        }

        try await fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            // build first
            do {
                let (stdout, _) = try await SwiftPM.Build.execute(["--build-tests"], packagePath: fixturePath)
                XCTAssertMatch(stdout, .contains("Build complete!"))
            }
            // list while skipping build
            do {
                let (stdout, stderr) = try await SwiftPM.Test.execute(["list", "--skip-build"], packagePath: fixturePath)
                // build was not run
                XCTAssertNoMatch(stderr, .contains("Build complete!"))
                // getting the lists
                XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/testExample1"))
                XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/test_Example2"))
                XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/testThrowing"))
            }
        }
    }

    func testBasicSwiftTestingIntegration() async throws {
        try XCTSkipUnless(
            nil != Environment.current["SWIFT_PM_SWIFT_TESTING_TESTS_ENABLED"],
            "Skipping \(#function) because swift-testing tests are not explicitly enabled"
        )

        try await fixture(name: "Miscellaneous/TestDiscovery/SwiftTesting") { fixturePath in
            do {
                let (stdout, _) = try await SwiftPM.Test.execute(["--enable-experimental-swift-testing", "--disable-xctest"], packagePath: fixturePath)
                XCTAssertMatch(stdout, .contains(#"Test "SOME TEST FUNCTION" started"#))
            }
        }
    }

#if !canImport(Darwin)
    func testGeneratedMainIsConcurrencySafe_XCTest() async throws {
        let strictConcurrencyFlags = ["-Xswiftc", "-strict-concurrency=complete"]
        try await fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            let (_, stderr) = try await SwiftPM.Test.execute(strictConcurrencyFlags, packagePath: fixturePath)
            XCTAssertNoMatch(stderr, .contains("is not concurrency-safe"))
        }
    }
#endif

#if !canImport(Darwin)
    func testGeneratedMainIsExistentialAnyClean() async throws {
        let existentialAnyFlags = ["-Xswiftc", "-enable-upcoming-feature", "-Xswiftc", "ExistentialAny"]
        try await fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            let (_, stderr) = try await SwiftPM.Test.execute(existentialAnyFlags, packagePath: fixturePath)
            XCTAssertNoMatch(stderr, .contains("error: use of protocol"))
        }
    }
#endif

    func testLibraryEnvironmentVariable() async throws {
        try await fixture(name: "Miscellaneous/CheckTestLibraryEnvironmentVariable") { fixturePath in
            await XCTAssertAsyncNoThrow(try await SwiftPM.Test.execute(packagePath: fixturePath))
        }
    }
}
