/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest
import Foundation

import Commands
import SPMTestSupport
import TSCBasic
import TSCUtility

let defaultRegistryBaseURL = URL(string: "https://packages.example.com")!
let customRegistryBaseURL = URL(string: "https://custom.packages.example.com")!

final class PackageRegistryToolTests: XCTestCase {
    @discardableResult
    private func execute(
        _ args: [String],
        packagePath: AbsolutePath? = nil,
        env: [String: String]? = nil
    ) throws -> (exitStatus: ProcessResult.ExitStatus, stdout: String, stderr: String) {
        var environment = env ?? [:]
        // don't ignore local packages when caching
        environment["SWIFTPM_TESTS_PACKAGECACHE"] = "1"
        let result = try SwiftPMProduct.SwiftPackageRegistry.executeProcess(args, packagePath: packagePath, env: environment)
        return try (result.exitStatus, result.utf8Output(), result.utf8stderrOutput())
    }

    func testUsage() throws {
        let stdout = try execute(["-help"]).stdout
        XCTAssert(stdout.contains("USAGE: swift package-registry"), "got stdout:\n" + stdout)
    }

    func testSeeAlso() throws {
        let stdout = try execute(["--help"]).stdout
        XCTAssert(stdout.contains("SEE ALSO: swift package"), "got stdout:\n" + stdout)
    }

    func testVersion() throws {
        let stdout = try execute(["--version"]).stdout
        XCTAssert(stdout.contains("Swift Package Manager"), "got stdout:\n" + stdout)
    }

    func testLocalConfiguration() throws {
        fixture(name: "DependencyResolution/External/Simple") { prefix in
            let packageRoot = prefix.appending(component: "Bar")
            let configurationFilePath = packageRoot.appending(RelativePath(".swiftpm/config/registries.json"))

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))

            // Set default registry
            do {
                let result = try execute(["set", "\(defaultRegistryBaseURL)"], packagePath: packageRoot)
                XCTAssertEqual(result.exitStatus, .terminated(code: 0))

                let json = try JSON(bytes: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 1)
                XCTAssertEqual(json["registries"]?.dictionary?["[default]"]?.dictionary?["url"]?.string, "\(defaultRegistryBaseURL)")
                XCTAssertEqual(json["version"], .int(1))
            }

            // Set new default registry
            do {
                let result = try execute(["set", "\(customRegistryBaseURL)"], packagePath: packageRoot)
                XCTAssertEqual(result.exitStatus, .terminated(code: 0))

                let json = try JSON(bytes: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 1)
                XCTAssertEqual(json["registries"]?.dictionary?["[default]"]?.dictionary?["url"]?.string, "\(customRegistryBaseURL)")
                XCTAssertEqual(json["version"], .int(1))
            }

            // Unset default registry
            do {
                let result = try execute(["unset"], packagePath: packageRoot)
                XCTAssertEqual(result.exitStatus, .terminated(code: 0))

                let json = try JSON(bytes: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 0)
                XCTAssertEqual(json["version"], .int(1))
            }

            // Set registry for "foo" scope
            do {
                let result = try execute(["set", "\(customRegistryBaseURL)", "--scope", "foo"], packagePath: packageRoot)
                XCTAssertEqual(result.exitStatus, .terminated(code: 0))

                let json = try JSON(bytes: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 1)
                XCTAssertEqual(json["registries"]?.dictionary?["foo"]?.dictionary?["url"]?.string, "\(customRegistryBaseURL)")
                XCTAssertEqual(json["version"], .int(1))
            }

            // Set registry for "bar" scope
            do {
                let result = try execute(["set", "\(customRegistryBaseURL)", "--scope", "bar"], packagePath: packageRoot)
                XCTAssertEqual(result.exitStatus, .terminated(code: 0))

                let json = try JSON(bytes: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 2)
                XCTAssertEqual(json["registries"]?.dictionary?["foo"]?.dictionary?["url"]?.string, "\(customRegistryBaseURL)")
                XCTAssertEqual(json["registries"]?.dictionary?["bar"]?.dictionary?["url"]?.string, "\(customRegistryBaseURL)")
                XCTAssertEqual(json["version"], .int(1))
            }

            // Unset registry for "foo" scope
            do {
                let result = try execute(["unset", "--scope", "foo"], packagePath: packageRoot)
                XCTAssertEqual(result.exitStatus, .terminated(code: 0))

                let json = try JSON(bytes: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 1)
                XCTAssertEqual(json["registries"]?.dictionary?["bar"]?.dictionary?["url"]?.string, "\(customRegistryBaseURL)")
                XCTAssertEqual(json["version"], .int(1))
            }

            XCTAssertTrue(localFileSystem.exists(configurationFilePath))
        }
    }

    // TODO: Test global configuration

    func testSetMissingURL() throws {
        fixture(name: "DependencyResolution/External/Simple") { prefix in
            let packageRoot = prefix.appending(component: "Bar")
            let configurationFilePath = packageRoot.appending(RelativePath(".swiftpm/config/registries.json"))

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))

            // Set default registry
            do {
                let result = try execute(["set", "--scope", "foo"], packagePath: packageRoot)
                XCTAssertNotEqual(result.exitStatus, .terminated(code: 0))
            }

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))
        }
    }

    func testSetInvalidURL() throws {
        fixture(name: "DependencyResolution/External/Simple") { prefix in
            let packageRoot = prefix.appending(component: "Bar")
            let configurationFilePath = packageRoot.appending(RelativePath(".swiftpm/config/registries.json"))

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))

            // Set default registry
            do {
                let result = try execute(["set", "invalid"], packagePath: packageRoot)
                XCTAssertNotEqual(result.exitStatus, .terminated(code: 0))
            }

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))
        }
    }

    func testUnsetMissingEntry() throws {
        fixture(name: "DependencyResolution/External/Simple") { prefix in
            let packageRoot = prefix.appending(component: "Bar")
            let configurationFilePath = packageRoot.appending(RelativePath(".swiftpm/config/registries.json"))

            XCTAssertFalse(localFileSystem.exists(configurationFilePath))

            // Set default registry
            do {
                let result = try execute(["set", "\(defaultRegistryBaseURL)"], packagePath: packageRoot)
                XCTAssertEqual(result.exitStatus, .terminated(code: 0))

                let json = try JSON(bytes: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 1)
                XCTAssertEqual(json["registries"]?.dictionary?["[default]"]?.dictionary?["url"]?.string, "\(defaultRegistryBaseURL)")
                XCTAssertEqual(json["version"], .int(1))
            }

            // Unset registry for missing "baz" scope
            do {
                let result = try execute(["unset", "--scope", "baz"], packagePath: packageRoot)
                XCTAssertNotEqual(result.exitStatus, .terminated(code: 0))

                let json = try JSON(bytes: localFileSystem.readFileContents(configurationFilePath))
                XCTAssertEqual(json["registries"]?.dictionary?.count, 1)
                XCTAssertEqual(json["registries"]?.dictionary?["[default]"]?.dictionary?["url"]?.string, "\(defaultRegistryBaseURL)")
                XCTAssertEqual(json["version"], .int(1))
            }

            XCTAssertTrue(localFileSystem.exists(configurationFilePath))
        }
    }

    // TODO: Test example with login and password
}
