/*
 This source file is part of the Swift.org open source project
 
 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception
 
 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import XCTest
import SPMTestSupport
import TSCBasic
import PackageModel
import Workspace

class CreateTests: XCTestCase {
    
    func testCreatePackageExecutable() throws {
        try XCTSkipIf(InitPackage.createPackageMode == .legacy)
        try testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending(component: "Foo")
            let configPath = path.appending(components: "templates", "new-package")

            // Create the package
            let initPackage = try InitPackage(fileSystem: fs,
                                              configPath: configPath,
                                              destinationPath: path,
                                              mode: .create,
                                              packageName: path.basename,
                                              packageType: .executable,
                                              packageTemplateName: nil)
            
            var progressMessages = [String]()
            initPackage.progressReporter = { message in
                progressMessages.append(message)
            }
            try initPackage.makePackage()

            // Not picky about the specific progress messages, just checking that we got some.
            XCTAssert(progressMessages.count > 0)

            // Verify basic file system content that we expect in the package
            let manifest = path.appending(component: "Package.swift")
            XCTAssertTrue(fs.exists(manifest))
            let manifestContents = try localFileSystem.readFileContents(manifest).description
            let version = "\(InitPackage.newPackageToolsVersion.major).\(InitPackage.newPackageToolsVersion.minor)"
            XCTAssertTrue(manifestContents.hasPrefix("// swift-tools-version:\(version)\n"))
            
            let readme = path.appending(component: "README.md")
            XCTAssertTrue(fs.exists(readme))
            let readmeContents = try localFileSystem.readFileContents(readme).description
            XCTAssertTrue(readmeContents.hasPrefix("# Foo\n"))

            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Sources")), ["main.swift"])
        }
    }
    
    func testCreatePackageLibrary() throws {
        try XCTSkipIf(InitPackage.createPackageMode == .legacy)
        try testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending(component: "Foo")
            let configPath = path.appending(components: "templates", "new-package")
            let name = path.basename

            // Create the package
            let initPackage = try InitPackage(fileSystem: fs,
                                              configPath: configPath,
                                              destinationPath: path,
                                              mode: .create,
                                              packageName: name,
                                              packageType: .library,
                                              packageTemplateName: nil)
            
            var progressMessages = [String]()
            initPackage.progressReporter = { message in
                progressMessages.append(message)
            }
            try initPackage.makePackage()

            // Not picky about the specific progress messages, just checking that we got some.
            XCTAssert(progressMessages.count > 0)

            // Verify basic file system content that we expect in the package
            let manifest = path.appending(component: "Package.swift")
            XCTAssertTrue(fs.exists(manifest))
            let manifestContents = try localFileSystem.readFileContents(manifest).description
            let version = "\(InitPackage.newPackageToolsVersion.major).\(InitPackage.newPackageToolsVersion.minor)"
            XCTAssertTrue(manifestContents.hasPrefix("// swift-tools-version:\(version)\n"))

            let readme = path.appending(component: "README.md")
            XCTAssertTrue(fs.exists(readme))
            let readmeContents = try localFileSystem.readFileContents(readme).description
            XCTAssertTrue(readmeContents.hasPrefix("# Foo\n"))

            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Sources")), ["Foo.swift"])

            // Try building it
            XCTAssertBuilds(path)
            let triple = Resources.default.toolchain.triple
            XCTAssertFileExists(path.appending(components: ".build", triple.tripleString, "debug", "Foo.swiftmodule"))
        }
    }
    
    func testCreatePackageSystemModule() throws {
        try XCTSkipIf(InitPackage.createPackageMode == .legacy)
        try testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending(component: "Foo")
            let configPath = path.appending(components: "templates", "new-package")
            let name = path.basename
            
            
            // Create the package
            let initPackage = try InitPackage(fileSystem: fs,
                                              configPath: configPath,
                                              destinationPath: path,
                                              mode: .create,
                                              packageName: name,
                                              packageType: .systemModule,
                                              packageTemplateName: nil)
            
            var progressMessages = [String]()
            initPackage.progressReporter = { message in
                progressMessages.append(message)
            }
            try initPackage.makePackage()
            
            // Not picky about the specific progress messages, just checking that we got some.
            XCTAssert(progressMessages.count > 0)

            // Verify basic file system content that we expect in the package
            let manifest = path.appending(component: "Package.swift")
            XCTAssertTrue(fs.exists(manifest))
            let manifestContents = try localFileSystem.readFileContents(manifest).description
            let version = "\(InitPackage.newPackageToolsVersion.major).\(InitPackage.newPackageToolsVersion.minor)"
            XCTAssertTrue(manifestContents.hasPrefix("// swift-tools-version:\(version)\n"))
            XCTAssertTrue(manifestContents.contains(packageWithNameAndDependencies(with: name)))
            XCTAssert(fs.exists(path.appending(component: "README.md")))
            XCTAssert(fs.exists(path.appending(component: "module.modulemap")))
        }
    }
    
    private func packageWithNameAndDependencies(with name: String) -> String {
        return """
let package = Package(
    name: "\(name)",
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
    ]
)
"""
    }
    
}
