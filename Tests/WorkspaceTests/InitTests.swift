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

class InitTests: XCTestCase {

    // MARK: TSCBasic package creation for each package type.
    
    func testInitPackageEmpty() throws {
        try XCTSkipIf(InitPackage.createPackageMode == .new)
        try testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending(component: "Foo")
            let configPath = path.appending(components: "templates", "new-package")
            let name = path.basename
            try fs.createDirectory(path)
            
            // Create the package
            let initPackage = try InitPackage(fileSystem: fs,
                                              configPath: configPath,
                                              destinationPath: path,
                                              mode: .initialize,
                                              packageName: name,
                                              packageType: .empty,
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
			let version = InitPackage.newPackageToolsVersion
			let versionSpecifier = "\(version.major).\(version.minor)"
			XCTAssertTrue(manifestContents.hasPrefix("// swift-tools-version:\(version < .v5_4 ? "" : " ")\(versionSpecifier)\n"))
            XCTAssertTrue(manifestContents.contains(packageWithNameAndDependencies(with: name)))
            XCTAssert(fs.exists(path.appending(component: "README.md")))
            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Sources")), [])
            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Tests")), [])
        }
    }
    
    func testInitPackageExecutable() throws {
        try XCTSkipIf(InitPackage.createPackageMode == .new)
        try testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending(component: "Foo")
            let configPath = path.appending(components: "templates", "new-package")
            let name = path.basename
            try fs.createDirectory(path)

            // Create the package
            let initPackage = try InitPackage(fileSystem: fs,
                                              configPath: configPath,
                                              destinationPath: path,
                                              mode: .initialize,
                                              packageName: name,
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
			let version = InitPackage.newPackageToolsVersion
			let versionSpecifier = "\(version.major).\(version.minor)"
			XCTAssertTrue(manifestContents.hasPrefix("// swift-tools-version:\(version < .v5_4 ? "" : " ")\(versionSpecifier)\n"))
            
            let readme = path.appending(component: "README.md")
            XCTAssertTrue(fs.exists(readme))
            let readmeContents = try localFileSystem.readFileContents(readme).description
            XCTAssertTrue(readmeContents.hasPrefix("# Foo\n"))

            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Sources").appending(component: "Foo")), ["main.swift"])
            XCTAssertEqual(
                try fs.getDirectoryContents(path.appending(component: "Tests")).sorted(),
                ["FooTests"])
            
            // If we have a compiler that supports `-entry-point-function-name`, we try building it (we need that flag now).
            #if swift(>=5.5)
            XCTAssertBuilds(path)
            let triple = Resources.default.toolchain.triple
            let binPath = path.appending(components: ".build", triple.tripleString, "debug")
            XCTAssertFileExists(binPath.appending(component: "Foo"))
            XCTAssertFileExists(binPath.appending(components: "Foo.swiftmodule"))
            #endif
        }
    }

    func testInitPackageLibrary() throws {
        try XCTSkipIf(InitPackage.createPackageMode == .new)
        try testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending(component: "Foo")
            let configPath = path.appending(components: "templates", "new-package")
            let name = path.basename
            try fs.createDirectory(path)

            // Create the package
            let initPackage = try InitPackage(fileSystem: fs,
                                              configPath: configPath,
                                              destinationPath: path,
                                              mode: .initialize,
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
			let version = InitPackage.newPackageToolsVersion
			let versionSpecifier = "\(version.major).\(version.minor)"
			XCTAssertTrue(manifestContents.hasPrefix("// swift-tools-version:\(version < .v5_4 ? "" : " ")\(versionSpecifier)\n"))

            let readme = path.appending(component: "README.md")
            XCTAssertTrue(fs.exists(readme))
            let readmeContents = try localFileSystem.readFileContents(readme).description
            XCTAssertTrue(readmeContents.hasPrefix("# Foo\n"))

            XCTAssertEqual(try fs.getDirectoryContents(path.appending(component: "Sources").appending(component: "Foo")), ["Foo.swift"])

            let tests = path.appending(component: "Tests")
            XCTAssertEqual(
                try fs.getDirectoryContents(tests).sorted(),
                ["FooTests"])

            let testFile = tests.appending(component: "FooTests").appending(component: "FooTests.swift")
            let testFileContents = try localFileSystem.readFileContents(testFile).description
            XCTAssertTrue(testFileContents.hasPrefix("import XCTest"), """
                          Validates formatting of XCTest source file, in particular that it does not contain leading whitespace:
                          \(testFileContents)
                          """)
            XCTAssertTrue(testFileContents.contains("func testExample() throws"), "Contents:\n\(testFileContents)")

            // Try building it
            XCTAssertBuilds(path)
            let triple = Resources.default.toolchain.triple
            XCTAssertFileExists(path.appending(components: ".build", triple.tripleString, "debug", "Foo.swiftmodule"))
        }
    }
    
    func testInitPackageSystemModule() throws {
        try testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending(component: "Foo")
            let configPath = path.appending(components: "templates", "new-package")
            let name = path.basename
            try fs.createDirectory(path)
            
            // Create the package
            let initPackage = try InitPackage(fileSystem: fs,
                                              configPath: configPath,
                                              destinationPath: path,
                                              mode: .initialize,
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
			let version = InitPackage.newPackageToolsVersion
			let versionSpecifier = "\(version.major).\(version.minor)"
			XCTAssertTrue(manifestContents.hasPrefix("// swift-tools-version:\(version < .v5_4 ? "" : " ")\(versionSpecifier)\n"))
            XCTAssertTrue(manifestContents.contains(packageWithNameAndDependencies(with: name)))
            XCTAssert(fs.exists(path.appending(component: "README.md")))
            XCTAssert(fs.exists(path.appending(component: "module.modulemap")))
        }
    }

    func testInitManifest() throws {
        try testWithTemporaryDirectory { tmpPath in
            let fs = localFileSystem
            let path = tmpPath.appending(component: "Foo")
            let configPath = path.appending(components: "templates", "new-package")
            let name = path.basename
            try fs.createDirectory(path)

            // Create the package
            let initPackage = try InitPackage(fileSystem: fs,
                                              configPath: configPath,
                                              destinationPath: path,
                                              mode: .initialize,
                                              packageName: name,
                                              packageType: .manifest,
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
			let version = InitPackage.newPackageToolsVersion
			let versionSpecifier = "\(version.major).\(version.minor)"
			XCTAssertTrue(manifestContents.hasPrefix("// swift-tools-version:\(version < .v5_4 ? "" : " ")\(versionSpecifier)\n"))
        }
    }
    
    // MARK: Special case testing
    
    func testInitPackageNonc99Directory() throws {
        try withTemporaryDirectory(removeTreeOnDeinit: true) { tempDirPath in
            XCTAssertTrue(localFileSystem.isDirectory(tempDirPath))
            
            // Create a directory with non c99name.
            let packageRoot = tempDirPath.appending(component: "some-package")
            let packageName = packageRoot.basename
            try localFileSystem.createDirectory(packageRoot)
            XCTAssertTrue(localFileSystem.isDirectory(packageRoot))
            
            // Create the package
            let initPackage = try InitPackage(fileSystem: localFileSystem,
                                              configPath: tempDirPath.appending(components: "templates", "new-package"),
                                              destinationPath: packageRoot,
                                              mode: .initialize,
                                              packageName: packageName,
                                              packageType: .library,
                                              packageTemplateName: nil)
            
            initPackage.progressReporter = { _ in }
            try initPackage.makePackage()

            // Try building it.
            XCTAssertBuilds(packageRoot)
            let triple = Resources.default.toolchain.triple
            XCTAssertFileExists(packageRoot.appending(components: ".build", triple.tripleString, "debug", "some_package.swiftmodule"))
        }
    }
    
    func testNonC99NameExecutablePackage() throws {
        // <rdar://problem/70382477> Fix and re-enable tests which run `swift test` on newly created packages
        try XCTSkipIf(true)

        try withTemporaryDirectory(removeTreeOnDeinit: true) { tempDirPath in
            XCTAssertTrue(localFileSystem.isDirectory(tempDirPath))
            
            let packageRoot = tempDirPath.appending(component: "Foo")
            try localFileSystem.createDirectory(packageRoot)
            XCTAssertTrue(localFileSystem.isDirectory(packageRoot))
            
            // Create package with non c99name.
            let initPackage = try InitPackage(fileSystem: localFileSystem,
                                              configPath: tempDirPath.appending(components: "templates", "new-package"),
                                              destinationPath: tempDirPath,
                                              mode: .initialize,
                                              packageName: packageRoot.basename,
                                              packageType: .executable,
                                              packageTemplateName: nil)
            try initPackage.makePackage()
            
            #if os(macOS)
              XCTAssertSwiftTest(packageRoot)
            #else
              XCTAssertBuilds(packageRoot)
            #endif
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
