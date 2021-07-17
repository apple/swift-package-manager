/*
 This source file is part of the Swift.org open source project
 
 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception
 
 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
import TSCBasic
import PackageModel

/// Create an initial template package.
public final class InitPackage {
    /// The tool version to be used for new packages.
    public static let newPackageToolsVersion = ToolsVersion.currentToolsVersion

    /// Represents a package type for the purposes of initialization.
    public enum PackageType: String, CustomStringConvertible {
        case empty = "empty"
        case library = "library"
        case executable = "executable"
        case systemModule = "system-module"
        case manifest = "manifest"
        case `extension` = "extension"

        public var description: String {
            return rawValue
        }
    }
    
    public struct PackageTemplate {
        let sourcesDirectory: RelativePath
        let testsDirectory: RelativePath?
        let createSubDirectoryForModule: Bool
        let packageType: PackageType
        
        public init(sourcesDirectory: RelativePath,
                    testsDirectory: RelativePath?,
                    createSubDirectoryForModule: Bool,
                    packageType: InitPackage.PackageType) {
            self.sourcesDirectory = sourcesDirectory
            self.testsDirectory = testsDirectory
            self.createSubDirectoryForModule = createSubDirectoryForModule
            self.packageType = packageType
        }
    }
    
    public enum MakePackageMode {
        case `initialize`
        case create
    }

    /// A block that will be called to report progress during package creation
    public var progressReporter: ((String) -> Void)?

    /// Where to create the new package
    let destinationPath: AbsolutePath
    
    /// Filesystem used for writing and or copying the package structure
    let fileSystem: FileSystem
    
    /// Configuration path for templates
    let configPath: AbsolutePath
    
    /// Name for the package
    let packageName: String
    
    /// If being called from `init` or `create`
    let mode: MakePackageMode
    
    /// Type of package
    let packageType: InitPackage.PackageType
    
    /// Name of the template to create the new package from
    let packageTemplateName: String?
    
    let suppliedPackageType: Bool
    
    private var moduleName: String {
        get {
            packageName.spm_mangledToC99ExtendedIdentifier()
        }
    }
    
    private var typeName: String {
        get {
            moduleName
        }
    }

    /// Create an instance that can create a package with given arguments.
    public init(fileSystem: FileSystem,
                configPath: AbsolutePath,
                destinationPath: AbsolutePath,
                mode: MakePackageMode,
                packageName: String,
                packageType: InitPackage.PackageType?,
                packageTemplateName: String?
    ) throws {
        self.fileSystem = fileSystem
        self.configPath = configPath
        self.destinationPath = destinationPath
        self.mode = mode
        self.packageName = packageName
        
        // These are only needed in the event that --type was not used when creating a package
        // otherwise if --type is used packageType will not be nill
        switch (packageType, mode){
        case (.some(let type), _):
            self.packageType = type
            self.suppliedPackageType = true
        case (.none, .initialize):
            self.packageType = .library
            self.suppliedPackageType = false
        case (.none, .create):
            self.packageType = .executable
            self.suppliedPackageType = false
        }
    
        self.packageTemplateName = packageTemplateName
    }

    public func makePackage() throws {
        switch Self.createPackageMode {
        case .new:
            try makePackageNew()
        case .legacy:
            try makePackageLegacy()
        }
    }
    
    private func makePackageNew() throws {
        var templateName: String?
        
        if let template = packageTemplateName {
            guard fileSystem.exists(configPath.withTemplate(template: template)) else {
                throw InternalError("Could not find template folder: \(configPath.withTemplate(template: template))")
            }
            
            templateName = template
        } else {
            // Checking if a default template is present
            if fileSystem.exists(configPath.withTemplate(template: "default")) {
                templateName = "default"
                // There is a guard preventing '--type' to be used in conjunction with '--template'
                // In the event that the defualt template is present and '--type' was used we'll infrom
                // the user that the package type is coming from the template and not their supplied type.
                guard !suppliedPackageType else {
                    throw StringError("Can't use '--type' when the 'default' template is defined")
                }
            }
        }
        
        if let template = templateName {
            try fileSystem.getDirectoryContents(configPath.withTemplate(template: template)).forEach {
                progressReporter?("Copying \($0)")
                try copyTemplate(fileSystem: fileSystem,
                                 sourcePath: configPath.withTemplate(template: template).appending(component: $0),
                                 destinationPath: destinationPath,
                                 name: packageName)
            }
        } else {
            let packageTemplate = PackageTemplate(sourcesDirectory: RelativePath("./Sources"),
                                                  testsDirectory: nil,
                                                  createSubDirectoryForModule: false,
                                                  packageType: packageType)
           
            try writePackageStructure(template: packageTemplate)
        }
    }
    
    private func makePackageLegacy() throws {
        let template = PackageTemplate(sourcesDirectory: RelativePath("./Sources"),
                                       testsDirectory: RelativePath("./Tests"),
                                       createSubDirectoryForModule: true,
                                       packageType: packageType)
        
        try writePackageStructure(template: template)
    }

    private func copyTemplate(fileSystem: FileSystem, sourcePath: AbsolutePath, destinationPath: AbsolutePath, name: String) throws {
        // Recursively copy the template package
        // Currently only replaces the string literal "___NAME___", and "___NAME_AS_C99___"
        let replaceName = "___NAME___"
        let replaceNameC99 = "___NAME_AS_C99___"
        
        if fileSystem.isDirectory(sourcePath) {
            if let dirName = sourcePath.pathString.split(separator: "/").last {
                
                let newDirName = dirName.replacingOccurrences(of: replaceName, with: packageName)
                if !fileSystem.exists(destinationPath.appending(component: newDirName)) {
                    try fileSystem.createDirectory(destinationPath.appending(component: newDirName))
                }
                
                try fileSystem.getDirectoryContents(sourcePath).forEach {
                    try copyTemplate(fileSystem: fileSystem,
                                     sourcePath: sourcePath.appending(component: $0),
                                     destinationPath: destinationPath.appending(components: newDirName),
                                     name: name)
                }
            }
        } else {
            let fileContents = try fileSystem.readFileContents(sourcePath)
            
            if let validDescription = fileContents.validDescription {
                if let fileName = sourcePath.pathString.split(separator: "/").last {
                    
                    let newFileName = fileName.replacingOccurrences(of: replaceName, with: packageName)
                    if !fileSystem.exists(destinationPath.appending(component: newFileName)) {
                        var renamed = validDescription.replacingOccurrences(of: replaceName, with: name)
                        renamed = renamed.replacingOccurrences(of: replaceNameC99, with: name.spm_mangledToC99ExtendedIdentifier())
                        
                        try fileSystem.writeFileContents(destinationPath.appending(component: newFileName)) { $0 <<< renamed }
                    }
                }
            } else {
                // This else takes care of things such as images
                if let fileName = sourcePath.pathString.split(separator: "/").last {
                    let newFileName = fileName.replacingOccurrences(of: replaceName, with: packageName)
                    if !fileSystem.exists(destinationPath.appending(component: newFileName)) {
                        try fileSystem.copy(from: sourcePath, to: destinationPath.appending(component: newFileName))
                    }
                }
            }
        }
    }
    
    /// Actually creates the new package at the destinationPath
    private func writePackageStructure(template: PackageTemplate) throws {
        progressReporter?("Creating \(template.packageType) package: \(packageName)")

        // FIXME: We should form everything we want to write, then validate that
        // none of it exists, and then act.
        try writeManifestFile(template: template)

        if template.packageType == .manifest {
            return
        }

        try writeGitIgnore()
        try writeREADMEFile()
        try writeSources(template: template)
        try writeModuleMap(template: template)
        try writeTests(template: template)
    }

    private func writePackageFile(_ path: AbsolutePath, body: (OutputByteStream) -> Void) throws {
        progressReporter?("Creating \(path.relative(to: destinationPath))")
        try localFileSystem.writeFileContents(path, body: body)
    }

    private func writeManifestFile(template: PackageTemplate) throws {
        let manifest = destinationPath.appending(component: Manifest.filename)
        guard localFileSystem.exists(manifest) == false else {
            throw InitError.manifestAlreadyExists
        }

        try writePackageFile(manifest) { stream in
            stream <<< """
                // The swift-tools-version declares the minimum version of Swift required to build this package.

                import PackageDescription

                let package = Package(

                """

            var pkgParams = [String]()
            pkgParams.append("""
                    name: "\(packageName)"
                """)

            if template.packageType == .library || template.packageType == .manifest {
                pkgParams.append("""
                    products: [
                        // Products define the executables and libraries a package produces, and make them visible to other packages.
                        .library(
                            name: "\(packageName)",
                            targets: ["\(packageName)"]),
                    ]
                """)
            }

            pkgParams.append("""
                    dependencies: [
                        // Dependencies declare other packages that this package depends on.
                        // .package(url: /* package url */, from: "1.0.0"),
                    ]
                """)

            if template.packageType == .library || template.packageType == .executable || template.packageType == .manifest {
                var param = ""

                param += """
                    targets: [
                        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
                        // Targets can depend on other targets in this package, and on products in packages this package depends on.

                """
                if template.packageType == .executable {
                    param += """
                            .executableTarget(
                    """
                } else {
                    param += """
                            .target(
                    """
                }
                
                let targetPath = template.createSubDirectoryForModule ? template.sourcesDirectory.appending(component: packageName) : template.sourcesDirectory
                param += """

                            name: "\(packageName)",
                            dependencies: [],
                            path: "\(targetPath)"),
                """
                
                if let testsDir = template.testsDirectory {
                    let testPath = template.createSubDirectoryForModule ? testsDir.appending(component: "\(packageName)Tests") : testsDir
                    param += """
                    
                            .testTarget(
                                name: "\(packageName)Tests",
                                dependencies: ["\(packageName)"],
                                path: "\(testPath)"),
                        ]
                    """
                } else {
                    param += """
                    
                        ]
                    """
                }

                pkgParams.append(param)
            }

            stream <<< pkgParams.joined(separator: ",\n") <<< "\n)\n"
        }

        // Create a tools version with current version but with patch set to zero.
        // We do this to avoid adding unnecessary constraints to patch versions, if
        // the package really needs it, they should add it manually.
        let version = InitPackage.newPackageToolsVersion.zeroedPatch

        // Write the current tools version.
        try rewriteToolsVersionSpecification(
            toDefaultManifestIn: manifest.parentDirectory, specifying: version, fileSystem: localFileSystem)
    }
    
    private func writeREADMEFile() throws {
        let readme = destinationPath.appending(component: "README.md")
        guard !localFileSystem.exists(readme) else {
            return
        }

        try writePackageFile(readme) { stream in
            stream <<< """
                # \(packageName)

                A description of this package.
                """
        }
    }

    private func writeGitIgnore() throws {
        let gitignore = destinationPath.appending(component: ".gitignore")
        guard localFileSystem.exists(gitignore) == false else {
            return
        }

        try writePackageFile(gitignore) { stream in
            stream <<< """
                .DS_Store
                /.build
                /Packages
                /*.xcodeproj
                xcuserdata/
                DerivedData/
                .swiftpm/config/registries.json
                .swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata

                """
        }
    }
    
    private func writeSources(template: PackageTemplate) throws {
        if template.packageType == .systemModule || template.packageType == .manifest {
            return
        }
        
        let sources = destinationPath.appending(template.sourcesDirectory)
        guard localFileSystem.exists(sources) == false else {
            return
        }
        
        progressReporter?("Creating \(sources.relative(to: destinationPath))/")
        try makeDirectories(sources)

        if template.packageType == .empty {
            return
        }
        
        let moduleDir: AbsolutePath
        if template.createSubDirectoryForModule {
            moduleDir = sources.appending(component: "\(packageName)")
            try makeDirectories(moduleDir)
        } else {
            moduleDir = sources
        }
        
        let sourceFileName = template.packageType == .executable ? "main.swift" : "\(typeName).swift"
        let sourceFile = moduleDir.appending(RelativePath(sourceFileName))

        let content: String
        switch template.packageType {
        case .library:
            content = """
                public struct \(typeName) {
                    public private(set) var text = "Hello, World!"

                    public init() {
                    }
                }

                """
        case .executable:
            content = """
                print("Hello, world!")

                """
        case .systemModule, .empty, .manifest, .`extension`:
            throw InternalError("invalid packageType \(template.packageType)")
        }

        try writePackageFile(sourceFile) { stream in
            stream.write(content)
        }
    }

    private func writeModuleMap(template: PackageTemplate) throws {
        if template.packageType != .systemModule {
            return
        }
        
        let modulemap = destinationPath.appending(component: "module.modulemap")
        guard localFileSystem.exists(modulemap) == false else {
            return
        }
        
        try writePackageFile(modulemap) { stream in
            stream <<< """
                module \(moduleName) [system] {
                  header "/usr/include/\(moduleName).h"
                  link "\(moduleName)"
                  export *
                }

                """
        }
    }

    private func writeTests(template: PackageTemplate) throws {
        if template.packageType == .systemModule {
            return
        }
        
        if let testDir = template.testsDirectory {
            let tests = destinationPath.appending(testDir)
            guard localFileSystem.exists(tests) == false else {
                return
            }
            
            progressReporter?("Creating \(tests.relative(to: destinationPath))/")
            try makeDirectories(tests)

            switch template.packageType {
            case .systemModule, .empty, .manifest, .`extension`: break
            case .library, .executable:
                try writeTestFileStubs(template: template, testsPath: tests)
            }
        }
    }

    private func writeLibraryTestsFile(_ path: AbsolutePath) throws {
        try writePackageFile(path) { stream in
            stream <<< """
                import XCTest
                @testable import \(moduleName)

                final class \(moduleName)Tests: XCTestCase {
                    func testExample() throws {
                        // This is an example of a functional test case.
                        // Use XCTAssert and related functions to verify your tests produce the correct
                        // results.
                        XCTAssertEqual(\(typeName)().text, "Hello, World!")
                    }
                }

                """
        }
    }

    private func writeExecutableTestsFile(_ path: AbsolutePath) throws {
        try writePackageFile(path) { stream in
            stream <<< """
                import XCTest
                import class Foundation.Bundle

                final class \(moduleName)Tests: XCTestCase {
                    func testExample() throws {
                        // This is an example of a functional test case.
                        // Use XCTAssert and related functions to verify your tests produce the correct
                        // results.

                        // Some of the APIs that we use below are available in macOS 10.13 and above.
                        guard #available(macOS 10.13, *) else {
                            return
                        }

                        // Mac Catalyst won't have `Process`, but it is supported for executables.
                        #if !targetEnvironment(macCatalyst)

                        let fooBinary = productsDirectory.appendingPathComponent("\(packageName)")

                        let process = Process()
                        process.executableURL = fooBinary

                        let pipe = Pipe()
                        process.standardOutput = pipe

                        try process.run()
                        process.waitUntilExit()

                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let output = String(data: data, encoding: .utf8)

                        XCTAssertEqual(output, "Hello, world!\\n")
                        #endif
                    }

                    /// Returns path to the built products directory.
                    var productsDirectory: URL {
                      #if os(macOS)
                        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
                            return bundle.bundleURL.deletingLastPathComponent()
                        }
                        fatalError("couldn't find the products directory")
                      #else
                        return Bundle.main.bundleURL
                      #endif
                    }
                }

                """
        }
    }

    private func writeTestFileStubs(template: PackageTemplate, testsPath: AbsolutePath) throws {
        let testModule = testsPath.appending(RelativePath(packageName + Target.testModuleNameSuffix))
        progressReporter?("Creating \(testModule.relative(to: destinationPath))/")
        try makeDirectories(testModule)

        let testClassFile = testModule.appending(RelativePath("\(moduleName)Tests.swift"))
        switch template.packageType {
        case .systemModule, .empty, .manifest, .`extension`: break
        case .library:
            try writeLibraryTestsFile(testClassFile)
        case .executable:
            try writeExecutableTestsFile(testClassFile)
        }
    }
    
    // TEMP 
    public enum Mode {
        case new
        case legacy
    }
    
    public static var createPackageMode: Mode {
        get {
            switch (ProcessEnv.vars["SWIFTPM_ENABLE_PACKAGE_CREATE"].map { $0.lowercased() }) {
            case "true":
                return .new
            default:
                return .legacy
            }
        }
    }
}

extension AbsolutePath {
    public func withTemplate(template: String) -> AbsolutePath {
        return appending(components: "templates", "new-package", template)
    }
}

// Private helpers

private enum InitError: Swift.Error {
    case manifestAlreadyExists
}

extension InitError: CustomStringConvertible {
    var description: String {
        switch self {
        case .manifestAlreadyExists:
            return "a manifest file already exists in this directory"
        }
    }
}

extension PackageModel.Platform {
    var manifestName: String {
        switch self {
        case .macOS:
            return "macOS"
        case .macCatalyst:
            return "macCatalyst"
        case .iOS:
            return "iOS"
        case .tvOS:
            return "tvOS"
        case .watchOS:
            return "watchOS"
        case .driverKit:
            return "DriverKit"
        default:
            fatalError("unexpected manifest name call for platform \(self)")
        }
    }
}

extension SupportedPlatform {
    var isManifestAPIAvailable: Bool {
        if platform == .macOS && self.version.major == 10 {
            guard self.version.patch == 0 else {
                return false
            }
        } else if [Platform.macOS, .macCatalyst, .iOS, .watchOS, .tvOS, .driverKit].contains(platform) {
            guard self.version.minor == 0, self.version.patch == 0 else {
                return false
            }
        } else {
            return false
        }

        switch platform {
        case .macOS where version.major == 10:
            return (10...15).contains(version.minor)
        case .macOS:
            return (11...11).contains(version.major)
        case .macCatalyst:
            return (13...14).contains(version.major)
        case .iOS:
            return (8...14).contains(version.major)
        case .tvOS:
            return (9...14).contains(version.major)
        case .watchOS:
            return (2...7).contains(version.major)
        case .driverKit:
            return (19...20).contains(version.major)

        default:
            return false
        }
    }
}
