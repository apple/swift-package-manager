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

class TemplateTests: XCTestCase {
    func testAddTemplate() throws {
        try XCTSkipIf(InitPackage.createPackageMode == .legacy)
        fixture(name: "Templates/AddTemplate") { prefix in
            try testWithTemporaryDirectory { tmpPath in
                let fs = localFileSystem
                let absolutePathToTemplate = prefix.appending(component: "GoodTemplate")
                
                let templatePath = tmpPath.appending(components: "templates", "new-package")
                try fs.createDirectory(templatePath, recursive: true)
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["add-template", absolutePathToTemplate.pathString, "--config-path", tmpPath.pathString], packagePath: tmpPath)
                
                let errorMessage = try result.utf8stderrOutput()
                XCTAssert(fs.exists(templatePath.appending(component: "goodTemplate")), errorMessage)
            }
        }
    }
    
    func testAddTemplateBadInputs() throws {
        try XCTSkipIf(InitPackage.createPackageMode == .legacy)
        fixture(name: "Templates/AddTemplateErrors") { prefix in
            try testWithTemporaryDirectory { tmpPath in
                let fs = localFileSystem
                
                // When 'add-template' is given a local path it expects that path to be an absolute path to a template directroy
                let missingTemplate = tmpPath.appending(component: "MissingTemplate").pathString
                let invalidPathToTemplate = try SwiftPMProduct.SwiftPackage.executeProcess(["add-template", missingTemplate], packagePath: tmpPath)
                let invalidPathError = try invalidPathToTemplate.utf8stderrOutput()
                
                XCTAssert(invalidPathError.contains("Could not find template: \(missingTemplate)"), invalidPathError)
                
                // Must always have a directroy when using 'add-template'
                let fileTemplate = prefix.appending(component: "Package.swift").pathString
                let noDirSupplied = try SwiftPMProduct.SwiftPackage.executeProcess(["add-template", fileTemplate], packagePath: tmpPath)
                let noDirError = try noDirSupplied.utf8stderrOutput()
                
                XCTAssert(noDirError.contains("\(fileTemplate) is not a valid directory"), noDirError)
                
                // For a template to be valid it must contain 'Package.swift'
                let templatePath = tmpPath.appending(components: "templates", "new-package")
                let absolutePathToTemplate = prefix.appending(component: "MissingManifest")
                try fs.createDirectory(templatePath, recursive: true)
                
                let missingManifest = try SwiftPMProduct.SwiftPackage.executeProcess(["add-template", absolutePathToTemplate.pathString, "--config-path", tmpPath.pathString], packagePath: tmpPath)
                let missingManifestError = try missingManifest.utf8stderrOutput()
                
                XCTAssert(missingManifestError.contains("is not a valid template directory, missing 'Package.swift'"), missingManifestError)
            }
        }
    }
    
    func testInitWithTemplate() throws {
        try XCTSkipIf(InitPackage.createPackageMode == .legacy)
        fixture(name: "Templates/MakePackageWithTemplate") { prefix in
            try testWithTemporaryDirectory { tmpPath in
                let fs = localFileSystem
                let path = tmpPath.appending(component: "Bar")
                try fs.createDirectory(path)
                
                let result = try SwiftPMProduct.SwiftPackage.executeProcess(["init", "--template", "TestTemplate", "--config-path", prefix.pathString], packagePath: path)
                let stderr = try result.utf8stderrOutput()
                
                XCTAssert(fs.exists(path.appending(component: "Package.swift")), stderr)
                
                if let manifest = try fs.readFileContents(path.appending(component: "Package.swift")).validDescription {
                    XCTAssert(manifest == transformedManifest(with: "Bar"))
                }
                
                if let readMe = try fs.readFileContents(path.appending(component: "README.md")).validDescription {
                    XCTAssert(readMe == transformedREADME(with: "Bar"))
                }
                
                if let swiftFile = try fs.readFileContents(path.appending(components: "Sources", "Bar.swift")).validDescription {
                    XCTAssert(swiftFile == transformedSwiftFile(with: "Bar"))
                }
                
                XCTAssertBuilds(path)
            }
        }
    }
    
    func testCreateWithTemplate() throws {
        try XCTSkipIf(InitPackage.createPackageMode == .legacy)
        fixture(name: "Templates/MakePackageWithTemplate") { prefix in
            try testWithTemporaryDirectory { tmpPath in
                let fs = localFileSystem
                let path = tmpPath.appending(component: "Foo")
                
                let _ = try SwiftPMProduct.SwiftPackage.executeProcess(["create", "Foo", "--template", "ExeTemplate", "--config-path", prefix.pathString], packagePath: tmpPath)
                
                XCTAssertBuilds(path)
                
                if let readMe = try fs.readFileContents(path.appending(component: "README.md")).validDescription {
                    XCTAssert(readMe == transformedREADME(with: "Foo"))
                }
            }
        }
    }
    
    func testInitWithDefaultTemplate() throws {
        try XCTSkipIf(InitPackage.createPackageMode == .legacy)
        fixture(name: "Templates/MakePackageWithTemplate") { prefix in
            try testWithTemporaryDirectory { tmpPath in
                let fs = localFileSystem
                let path = tmpPath.appending(component: "Bar")
                try fs.createDirectory(path)
                
                let _ = try SwiftPMProduct.SwiftPackage.executeProcess(["init", "--config-path", prefix.pathString], packagePath: path)
                
                XCTAssert(fs.exists(path.appending(component: "Package.swift")))
                XCTAssert(fs.exists(path.appending(components: "src", "main.swift")))
            }
        }
    }
    
    func testCreateWithDefaultTemplate() throws {
        try XCTSkipIf(InitPackage.createPackageMode == .legacy)
        fixture(name: "Templates/MakePackageWithTemplate") { prefix in
            try testWithTemporaryDirectory { tmpPath in
                let fs = localFileSystem
                let path = tmpPath.appending(component: "Foo")
                
                let _ = try SwiftPMProduct.SwiftPackage.executeProcess(["create", "Foo", "--config-path", prefix.pathString], packagePath: tmpPath)
                
                XCTAssert(fs.exists(path.appending(component: "Package.swift")))
                XCTAssert(fs.exists(path.appending(components: "src", "main.swift")))
            }
        }
    }
    
    func testCreateTemplateFunnyName() throws {
        try XCTSkipIf(InitPackage.createPackageMode == .legacy)
        fixture(name: "Templates/MakePackageWithTemplate") { prefix in
            try testWithTemporaryDirectory { tmpPath in
                let fs = localFileSystem
                let path = tmpPath.appending(component: "Foo Bar")
                
                let _ = try SwiftPMProduct.SwiftPackage.executeProcess(["create", "Foo Bar", "--template", "TestTemplate", "--config-path", prefix.pathString], packagePath: tmpPath)
                
                XCTAssert(fs.exists(path.appending(component: "Package.swift")))
                XCTAssert(fs.exists(path.appending(components: "Sources", "Foo Bar.swift")))
                
                XCTAssertBuilds(path)
            }
        }
    }
    
    func testInitTemplateFunnyName() throws {
        try XCTSkipIf(InitPackage.createPackageMode == .legacy)
        fixture(name: "Templates/MakePackageWithTemplate") { prefix in
            try testWithTemporaryDirectory { tmpPath in
                let fs = localFileSystem
                let path = tmpPath.appending(component: "Foo Bar")
                try fs.createDirectory(path)
                
                let _ = try SwiftPMProduct.SwiftPackage.executeProcess(["init", "--template", "LibTemplate","--config-path", prefix.pathString], packagePath: path)
                
                XCTAssert(fs.exists(path.appending(component: "Package.swift")))
                XCTAssert(fs.exists(path.appending(components: "Sources", "Foo Bar.swift")))
            
                if let manifest = try fs.readFileContents(path.appending(component: "Package.swift")).validDescription {
                    XCTAssert(manifest == transformedManifest(with: "Foo Bar"))
                }
                
                if let swiftFile = try fs.readFileContents(path.appending(components: "Sources", "Foo Bar.swift")).validDescription {
                    XCTAssert(swiftFile == transformedSwiftFile(with: "Foo Bar"))
                }
                
                XCTAssertBuilds(path)
            }
        }
    }
    
    private func transformedManifest(with name: String) -> String {
        // Currently the manifest will drop the patch version if it's zero
        // the description of Version always returns the patch version even if zero
        // this is just to drop the patch version
        var toolsVersion = "\(ToolsVersion.currentToolsVersion.major).\(ToolsVersion.currentToolsVersion.minor)"
        if ToolsVersion.currentToolsVersion.patch != 0 {
            toolsVersion += ".\(ToolsVersion.currentToolsVersion.patch)"
        }
        
        return """
// swift-tools-version:\(toolsVersion)
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "\(name)",
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "\(name)",
            targets: ["\(name)"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "\(name)",
            dependencies: [],
            path: "Sources"),
    ]
)
"""
    }
    
    private func transformedREADME(with name: String) -> String {
        return """
# \(name)

A description of this package.
"""
    }
    
    private func transformedSwiftFile(with name: String) -> String {
        return """
public struct \(name.spm_mangledToC99ExtendedIdentifier()) {
    public private(set) var text = "Hello, World!"

    public init() {
    }
}
"""
    }
}
