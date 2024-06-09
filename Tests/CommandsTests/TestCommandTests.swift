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
import SPMTestSupport
import XCTest

final class TestCommandTests: CommandsTestCase {
    
    private func execute(_ args: [String], packagePath: AbsolutePath? = nil) throws -> (stdout: String, stderr: String) {
        return try SwiftPM.Test.execute(args, packagePath: packagePath)
    }
    
    func testUsage() throws {
        let stdout = try execute(["-help"]).stdout
        XCTAssert(stdout.contains("USAGE: swift test"), "got stdout:\n" + stdout)
    }

    func testSeeAlso() throws {
        let stdout = try execute(["--help"]).stdout
        XCTAssert(stdout.contains("SEE ALSO: swift build, swift run, swift package"), "got stdout:\n" + stdout)
    }

    func testVersion() throws {
        let stdout = try execute(["--version"]).stdout
        XCTAssert(stdout.contains("Swift Package Manager"), "got stdout:\n" + stdout)
    }

    func testNumWorkersParallelRequirement() throws {
        #if !os(macOS)
        // Running swift-test fixtures on linux is not yet possible.
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        try fixture(name: "Miscellaneous/EchoExecutable") { fixturePath in
            XCTAssertThrowsCommandExecutionError(try execute(["--num-workers", "1"])) { error in
                XCTAssertMatch(error.stderr, .contains("error: --num-workers must be used with --parallel"))
            }
        }
    }
    
    func testNumWorkersValue() throws {
        #if !os(macOS)
        // Running swift-test fixtures on linux is not yet possible.
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        try fixture(name: "Miscellaneous/EchoExecutable") { fixturePath in
            XCTAssertThrowsCommandExecutionError(try execute(["--parallel", "--num-workers", "0"])) { error in
                XCTAssertMatch(error.stderr, .contains("error: '--num-workers' must be greater than zero"))
            }
        }
    }

    func testEnableDisableTestability() throws {
        // default should run with testability
        try fixture(name: "Miscellaneous/TestableExe") { fixturePath in
            do {
                let result = try execute(["--vv"], packagePath: fixturePath)
                XCTAssertMatch(result.stderr, .contains("-enable-testing"))
            }
        }

        // disabled
        try fixture(name: "Miscellaneous/TestableExe") { fixturePath in
            XCTAssertThrowsCommandExecutionError( try execute(["--disable-testable-imports", "--vv"], packagePath: fixturePath)) { error in
                XCTAssertMatch(error.stderr, .contains("was not compiled for testing"))
            }
        }

        // enabled
        try fixture(name: "Miscellaneous/TestableExe") { fixturePath in
            do {
                let result = try execute(["--enable-testable-imports", "--vv"], packagePath: fixturePath)
                XCTAssertMatch(result.stderr, .contains("-enable-testing"))
            }
        }
    }

    func testSwiftTestParallel() throws {
        try fixture(name: "Miscellaneous/ParallelTestsPkg") { fixturePath in
            // First try normal serial testing.
            XCTAssertThrowsCommandExecutionError(try SwiftPM.Test.execute(packagePath: fixturePath)) { error in
                // in "swift test" test output goes to stdout
                XCTAssertMatch(error.stdout, .contains("Executed 2 tests"))
                XCTAssertNoMatch(error.stdout, .contains("[3/3]"))
            }

            // Try --no-parallel.
            XCTAssertThrowsCommandExecutionError(try SwiftPM.Test.execute(["--no-parallel"], packagePath: fixturePath)) { error in
                // in "swift test" test output goes to stdout
                XCTAssertMatch(error.stdout, .contains("Executed 2 tests"))
                XCTAssertNoMatch(error.stdout, .contains("[3/3]"))
            }

            // Run tests in parallel.
            XCTAssertThrowsCommandExecutionError(try SwiftPM.Test.execute(["--parallel"], packagePath: fixturePath)) { error in
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
                XCTAssertThrowsCommandExecutionError(
                    try SwiftPM.Test.execute(["--parallel", "--verbose", "--xunit-output", xUnitOutput.pathString], packagePath: fixturePath)
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

    func testSwiftTestXMLOutputWhenEmpty() throws {
        try fixture(name: "Miscellaneous/EmptyTestsPkg") { fixturePath in
            let xUnitOutput = fixturePath.appending("result.xml")
            // Run tests in parallel with verbose output.
            let stdout = try SwiftPM.Test.execute(["--parallel", "--verbose", "--xunit-output", xUnitOutput.pathString], packagePath: fixturePath).stdout
            // in "swift test" test output goes to stdout
            XCTAssertNoMatch(stdout, .contains("passed"))
            XCTAssertNoMatch(stdout, .contains("failed"))

            // Check the xUnit output.
            XCTAssertFileExists(xUnitOutput)
            let contents: String = try localFileSystem.readFileContents(xUnitOutput)
            XCTAssertMatch(contents, .contains("tests=\"0\" failures=\"0\""))
        }
    }

    func testSwiftTestFilter() throws {
        try fixture(name: "Miscellaneous/SkipTests") { fixturePath in
            let (stdout, _) = try SwiftPM.Test.execute(["--filter", ".*1"], packagePath: fixturePath)
            // in "swift test" test output goes to stdout
            XCTAssertMatch(stdout, .contains("testExample1"))
            XCTAssertNoMatch(stdout, .contains("testExample2"))
            XCTAssertNoMatch(stdout, .contains("testExample3"))
            XCTAssertNoMatch(stdout, .contains("testExample4"))
        }

        try fixture(name: "Miscellaneous/SkipTests") { fixturePath in
            let (stdout, _) = try SwiftPM.Test.execute(["--filter", "SomeTests", "--skip", ".*1", "--filter", "testExample3"], packagePath: fixturePath)
            // in "swift test" test output goes to stdout
            XCTAssertNoMatch(stdout, .contains("testExample1"))
            XCTAssertMatch(stdout, .contains("testExample2"))
            XCTAssertMatch(stdout, .contains("testExample3"))
            XCTAssertNoMatch(stdout, .contains("testExample4"))
        }
    }

    func testSwiftTestSkip() throws {
        try fixture(name: "Miscellaneous/SkipTests") { fixturePath in
            let (stdout, _) = try SwiftPM.Test.execute(["--skip", "SomeTests"], packagePath: fixturePath)
            // in "swift test" test output goes to stdout
            XCTAssertNoMatch(stdout, .contains("testExample1"))
            XCTAssertNoMatch(stdout, .contains("testExample2"))
            XCTAssertMatch(stdout, .contains("testExample3"))
            XCTAssertMatch(stdout, .contains("testExample4"))
        }

        try fixture(name: "Miscellaneous/SkipTests") { fixturePath in
            let (stdout, _) = try SwiftPM.Test.execute(["--filter", "ExampleTests", "--skip", ".*2", "--filter", "MoreTests", "--skip", "testExample3"], packagePath: fixturePath)
            // in "swift test" test output goes to stdout
            XCTAssertMatch(stdout, .contains("testExample1"))
            XCTAssertNoMatch(stdout, .contains("testExample2"))
            XCTAssertNoMatch(stdout, .contains("testExample3"))
            XCTAssertMatch(stdout, .contains("testExample4"))
        }

        try fixture(name: "Miscellaneous/SkipTests") { fixturePath in
            let (stdout, stderr) = try SwiftPM.Test.execute(["--skip", "Tests"], packagePath: fixturePath)
            // in "swift test" test output goes to stdout
            XCTAssertNoMatch(stdout, .contains("testExample1"))
            XCTAssertNoMatch(stdout, .contains("testExample2"))
            XCTAssertNoMatch(stdout, .contains("testExample3"))
            XCTAssertNoMatch(stdout, .contains("testExample4"))
            XCTAssertMatch(stderr, .contains("No matching test cases were run"))
        }
    }

    func testEnableTestDiscoveryDeprecation() throws {
        let compilerDiagnosticFlags = ["-Xswiftc", "-Xfrontend", "-Xswiftc", "-Rmodule-interface-rebuild"]
        #if canImport(Darwin)
        // should emit when LinuxMain is present
        try fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            let (_, stderr) = try SwiftPM.Test.execute(["--enable-test-discovery"] + compilerDiagnosticFlags, packagePath: fixturePath)
            XCTAssertMatch(stderr, .contains("warning: '--enable-test-discovery' option is deprecated"))
        }

        // should emit when LinuxMain is not present
        try fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            try localFileSystem.writeFileContents(fixturePath.appending(components: "Tests", SwiftTarget.defaultTestEntryPointName), bytes: "fatalError(\"boom\")")
            let (_, stderr) = try SwiftPM.Test.execute(["--enable-test-discovery"] + compilerDiagnosticFlags, packagePath: fixturePath)
            XCTAssertMatch(stderr, .contains("warning: '--enable-test-discovery' option is deprecated"))
        }
        #else
        // should emit when LinuxMain is present
        try fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            let (_, stderr) = try SwiftPM.Test.execute(["--enable-test-discovery"] + compilerDiagnosticFlags, packagePath: fixturePath)
            XCTAssertMatch(stderr, .contains("warning: '--enable-test-discovery' option is deprecated"))
        }
        // should not emit when LinuxMain is present
        try fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            try localFileSystem.writeFileContents(fixturePath.appending(components: "Tests", SwiftTarget.defaultTestEntryPointName), bytes: "fatalError(\"boom\")")
            let (_, stderr) = try SwiftPM.Test.execute(["--enable-test-discovery"] + compilerDiagnosticFlags, packagePath: fixturePath)
            XCTAssertNoMatch(stderr, .contains("warning: '--enable-test-discovery' option is deprecated"))
        }
        #endif
    }

    func testList() throws {
        try fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            let (stdout, stderr) = try SwiftPM.Test.execute(["list"], packagePath: fixturePath)
            // build was run
            XCTAssertMatch(stderr, .contains("Build complete!"))
            // getting the lists
            XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/testExample1"))
            XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/test_Example2"))
            XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/testThrowing"))
        }

        try fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            // build first
            do {
                let (stdout, _) = try SwiftPM.Build.execute(["--build-tests"], packagePath: fixturePath)
                XCTAssertMatch(stdout, .contains("Build complete!"))
            }
            // list
            do {
                let (stdout, stderr) = try SwiftPM.Test.execute(["list"], packagePath: fixturePath)
                // build was run
                XCTAssertMatch(stderr, .contains("Build complete!"))
                // getting the lists
                XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/testExample1"))
                XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/test_Example2"))
                XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/testThrowing"))
            }
        }

        try fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            // build first
            do {
                let (stdout, _) = try SwiftPM.Build.execute(["--build-tests"], packagePath: fixturePath)
                XCTAssertMatch(stdout, .contains("Build complete!"))
            }
            // list while skipping build
            do {
                let (stdout, stderr) = try SwiftPM.Test.execute(["list", "--skip-build"], packagePath: fixturePath)
                // build was not run
                XCTAssertNoMatch(stderr, .contains("Build complete!"))
                // getting the lists
                XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/testExample1"))
                XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/test_Example2"))
                XCTAssertMatch(stdout, .contains("SimpleTests.SimpleTests/testThrowing"))
            }
        }
    }

    func testBasicSwiftTestingIntegration() throws {
        try XCTSkipUnless(
            nil != ProcessInfo.processInfo.environment["SWIFT_PM_SWIFT_TESTING_TESTS_ENABLED"],
            "Skipping \(#function) because swift-testing tests are not explicitly enabled"
        )

        try fixture(name: "Miscellaneous/TestDiscovery/SwiftTesting") { fixturePath in
            do {
                let (stdout, _) = try SwiftPM.Test.execute(["--enable-swift-testing", "--disable-xctest"], packagePath: fixturePath)
                XCTAssertMatch(stdout, .contains(#"Test "SOME TEST FUNCTION" started"#))
            }
        }
    }

    func testBasicSwiftTestingIntegration_ExperimentalFlag() throws {
        try XCTSkipUnless(
            nil != ProcessInfo.processInfo.environment["SWIFT_PM_SWIFT_TESTING_TESTS_ENABLED"],
            "Skipping \(#function) because swift-testing tests are not explicitly enabled"
        )
        
        try fixture(name: "Miscellaneous/TestDiscovery/SwiftTesting") { fixturePath in
            do {
                let (stdout, _) = try SwiftPM.Test.execute(["--enable-experimental-swift-testing", "--disable-xctest"], packagePath: fixturePath)
                XCTAssertMatch(stdout, .contains(#"Test "SOME TEST FUNCTION" started"#))
            }
        }
    }

#if !canImport(Darwin)
    func testGeneratedMainIsConcurrencySafe_XCTest() throws {
        let strictConcurrencyFlags = ["-Xswiftc", "-strict-concurrency=complete"]
        try fixture(name: "Miscellaneous/TestDiscovery/Simple") { fixturePath in
            let (_, stderr) = try SwiftPM.Test.execute(strictConcurrencyFlags, packagePath: fixturePath)
            XCTAssertNoMatch(stderr, .contains("is not concurrency-safe"))
        }
    }
#endif

    func testLibraryEnvironmentVariable() throws {
      try fixture(name: "Miscellaneous/CheckTestLibraryEnvironmentVariable") { fixturePath in
        XCTAssertNoThrow(try SwiftPM.Test.execute(packagePath: fixturePath))
      }
    }
}
