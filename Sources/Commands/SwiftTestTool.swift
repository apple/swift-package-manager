/*
This source file is part of the Swift.org open source project

Copyright 2015 - 2016 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import class Foundation.ProcessInfo

import Basic
import Utility

import func POSIX.chdir
import func POSIX.exit

private enum TestError: ErrorProtocol {
    case testsExecutableNotFound
    case invalidListTestJSONData
}

extension TestError: CustomStringConvertible {
    var description: String {
        switch self {
        case .testsExecutableNotFound:
            return "no tests found to execute, create a module in your `Tests' directory"
        case .invalidListTestJSONData:
            return "Invalid list test JSON structure."
        }
    }
}

private enum Mode: Argument, Equatable, CustomStringConvertible {
    case usage
    case listTests
    case run(String?)

    init?(argument: String, pop: () -> String?) throws {
        switch argument {
        case "--help", "-h":
            self = .usage
        case "-l", "--list-tests":
            self = .listTests
        case "-s", "--specifier":
            guard let specifier = pop() else { throw OptionParserError.expectedAssociatedValue(argument) }
            self = .run(specifier)
        default:
            return nil
        }
    }

    var description: String {
        switch self {
        case .usage:
            return "--help"
        case .listTests:
            return "--list-tests"
        case .run(let specifier):
            return specifier ?? ""
        }
    }
}

private func ==(lhs: Mode, rhs: Mode) -> Bool {
    return lhs.description == rhs.description
}

private enum TestToolFlag: Argument {
    case chdir(String)
    case skipBuild

    init?(argument: String, pop: () -> String?) throws {
        switch argument {
        case "--chdir", "-C":
            guard let path = pop() else { throw OptionParserError.expectedAssociatedValue(argument) }
            self = .chdir(path)
        case "--skip-build":
            self = .skipBuild
        default:
            return nil
        }
    }
}

private class TestToolOptions: Options {
    var buildTests: Bool = true
}

/// swift-test tool namespace
public struct SwiftTestTool: SwiftTool {
    let args: [String]

    public init(args: [String]) {
        self.args = args
    }
    
    public func run() {
        do {
            let (mode, opts) = try parseOptions(commandLineArguments: args)
        
            if let dir = opts.chdir {
                try chdir(dir)
            }
        
            switch mode {
            case .usage:
                usage()
        
            case .listTests:
                let testPath = try determineTestPath(opts: opts)
                let testSuites = try getTestSuites(path: testPath)
                // Print the tests.
                for testSuite in testSuites {
                    for testCase in testSuite.tests {
                        for test in testCase.tests {
                            print(testCase.name + "/" + test)
                        }
                    }
                }

            case .run(let specifier):
                let yamlPath = Path.join(opts.path.build, "\(configuration).yaml")
                if opts.buildTests {
                    try build(YAMLPath: yamlPath, target: "test")
                }
                let success = try test(path: determineTestPath(opts: opts), xctestArg: specifier)
                exit(success ? 0 : 1)
            }
        } catch Error.buildYAMLNotFound {
            print("error: you must run `swift build` first", to: &stderr)
            exit(1)
        } catch {
            handle(error: error, usage: usage)
        }
    }

    private let configuration = "debug"  //FIXME should swift-test support configuration option?

    /// Locates the XCTest bundle on OSX and XCTest executable on Linux.
    /// First check if <build_path>/debug/<PackageName>Tests.xctest is present, otherwise
    /// walk the build folder and look for folder/file ending with `.xctest`.
    ///
    /// - Parameters:
    ///     - opts: Options object created by parsing the commandline arguments.
    ///
    /// - Throws: TestError
    ///
    /// - Returns: Path to XCTest bundle (OSX) or executable (Linux).
    private func determineTestPath(opts: Options) throws -> String {

        //FIXME better, ideally without parsing manifest since
        // that makes us depend on the whole Manifest system

        let packageName = opts.path.root.basename  //FIXME probably not true
        let maybePath = Path.join(opts.path.build, configuration, "\(packageName)Tests.xctest")

        if maybePath.exists {
            return maybePath
        } else {
            let possiblePaths = walk(opts.path.build).filter {
                $0.basename != "Package.xctest" &&   // this was our hardcoded name, may still exist if no clean
                $0.hasSuffix(".xctest")
            }

            guard let path = possiblePaths.first else {
                throw TestError.testsExecutableNotFound
            }

            return path
        }
    }

    private func usage(_ print: (String) -> Void = { print($0) }) {
        //     .........10.........20.........30.........40.........50.........60.........70..
        print("OVERVIEW: Build and run tests")
        print("")
        print("USAGE: swift test [options]")
        print("")
        print("OPTIONS:")
        print("  -s, --specifier <test-module>.<test-case>         Run a test case subclass")
        print("  -s, --specifier <test-module>.<test-case>/<test>  Run a specific test method")
        print("  -l, --list-tests                                  Lists test methods in specifier format")
        print("  -C, --chdir <path>     Change working directory before any other operation")
        print("  --build-path <path>    Specify build directory")
        print("  --skip-build           Skip building the test target")
        print("")
        print("NOTE: Use `swift package` to perform other functions on packages")
    }

    private func parseOptions(commandLineArguments args: [String]) throws -> (Mode, TestToolOptions) {
        let (mode, flags): (Mode?, [TestToolFlag]) = try Basic.parseOptions(arguments: args)

        let opts = TestToolOptions()
        for flag in flags {
            switch flag {
            case .chdir(let path):
                opts.chdir = path
            case .skipBuild:
                opts.buildTests = false
            }
        }

        return (mode ?? .run(nil), opts)
    }

    private func test(path: String, xctestArg: String? = nil) throws -> Bool {
        guard path.isValidTest else {
            throw TestError.testsExecutableNotFound
        }

        var args: [String] = []
#if os(OSX)
        args = ["xcrun", "xctest"]
        if let xctestArg = xctestArg {
            args += ["-XCTest", xctestArg]
        }
        args += [path]
#else
        args += [path]
        if let xctestArg = xctestArg {
            args += [xctestArg]
        }
#endif

        // Execute the XCTest with inherited environment as it is convenient to pass senstive
        // information like username, password etc to test cases via enviornment variables.
        let result: Void? = try? system(args, environment: ProcessInfo.processInfo().environment)
        return result != nil
    }

    /// Locates XCTestHelper tool inside the libexec directory and bin directory.
    /// Note: It is a fatalError if we are not able to locate the tool.
    ///
    /// - Returns: Path to XCTestHelper tool.
    private func xctestHelperPath() -> String {
        let xctestHelperBin = "swiftpm-xctest-helper"
        let binDirectory = Process.arguments.first!.abspath.parentDirectory
        // XCTestHelper tool is installed in libexec.
        let maybePath = Path.join(binDirectory, "../libexec/swift/pm/", xctestHelperBin)
        if maybePath.isFile {
            return maybePath
        }
        // This will be true during swiftpm developement.
        // FIXME: Factor all of the development-time resource location stuff into a common place.
        let path = Path.join(binDirectory, xctestHelperBin)
        if path.isFile {
            return path 
        }
        fatalError("XCTestHelper binary not found.") 
    }

    /// Runs the corresponding tool to get tests JSON and create TestSuite array.
    /// On OSX, we use the swiftpm-xctest-helper tool bundled with swiftpm.
    /// On Linux, XCTest can dump the json using `--dump-tests-json` mode.
    ///
    /// - Parameters:
    ///     - path: Path to the XCTest bundle(OSX) or executable(Linux).
    ///
    /// - Throws: TestError, SystemError, Utility.Errror
    ///
    /// - Returns: Array of TestSuite
    private func getTestSuites(path: String) throws -> [TestSuite] {
        // Make sure tests are present.
        guard path.isValidTest else { throw TestError.testsExecutableNotFound }

        // Run the correct tool.
      #if os(OSX)
        let tempFile = try TemporaryFile()
        let args = [xctestHelperPath(), path, String(tempFile.path)]
        try system(args, environment: ["DYLD_FRAMEWORK_PATH": try platformFrameworksPath()])
        // Read the temporary file's content.
        let data = try fopen(String(tempFile.path)).readFileContents()
      #else
        let args = [path, "--dump-tests-json"]
        let data = try popen(args)
      #endif
        // Parse json and return TestSuites.
        return try TestSuite.parse(jsonString: data)
    }
}

private extension String {
    var isValidTest: Bool {
        #if os(OSX)
            return isDirectory  // ${foo}.xctest is dir on OSX
        #else
            return isFile       // otherwise ${foo}.xctest is executable file
        #endif
    }
}

/// A struct to hold the XCTestSuite data.
struct TestSuite {

    /// A struct to hold a XCTestCase data.
    struct TestCase {
        /// Name of the test case.
        let name: String

        /// Array of test methods in this test case.
        let tests: [String]
    }

    /// The name of the test suite.
    let name: String

    /// Array of test cases in this test suite.
    let tests: [TestCase]

    /// Parses a JSON String to array of TestSuite.
    ///
    /// - Parameters:
    ///     - jsonString: JSON string to be parsed.
    ///
    /// - Throws: JSONDecodingError, TestError
    ///
    /// - Returns: Array of TestSuite.
    static func parse(jsonString: String) throws -> [TestSuite] {
        let json = try JSON(string: jsonString)
        return try TestSuite.parse(json: json)
    }

    /// Parses the JSON object into array of TestSuite.
    ///
    /// - Parameters:
    ///     - json: An object of JSON.
    ///
    /// - Throws: TestError
    ///
    /// - Returns: Array of TestSuite.
    static func parse(json: JSON) throws -> [TestSuite] {
        guard case let .dictionary(contents) = json,
              case let .array(testSuites)? = contents["tests"] else {
            throw TestError.invalidListTestJSONData
        }

        return try testSuites.map { testSuite in
            guard case let .dictionary(testSuiteData) = testSuite,
                  case let .string(name)? = testSuiteData["name"],
                  case let .array(allTestsData)? = testSuiteData["tests"] else {
                throw TestError.invalidListTestJSONData
            }

            let testCases: [TestSuite.TestCase] = try allTestsData.map { testCase in
                guard case let .dictionary(testCaseData) = testCase,
                      case let .string(name)? = testCaseData["name"],
                      case let .array(tests)? = testCaseData["tests"] else {
                    throw TestError.invalidListTestJSONData
                }
                let testMethods: [String] = try tests.map { test in
                    guard case let .dictionary(testData) = test,
                          case let .string(testMethod)? = testData["name"] else {
                        throw TestError.invalidListTestJSONData
                    }
                    return testMethod
                }
                return TestSuite.TestCase(name: name, tests: testMethods)
            }
            return TestSuite(name: name, tests: testCases)
        }
    }
}
