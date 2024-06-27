//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageModel
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder
import struct TSCUtility.Version

/// Add a target to a manifest's source code.
public struct AddTarget {
    /// The set of argument labels that can occur after the "targets"
    /// argument in the Package initializers.
    ///
    /// TODO: Could we generate this from the the PackageDescription module, so
    /// we don't have keep it up-to-date manually?
    private static let argumentLabelsAfterTargets: Set<String> = [
        "swiftLanguageVersions",
        "cLanguageStandard",
        "cxxLanguageStandard"
    ]

    /// The kind of test harness to use. This isn't part of the manifest
    /// itself, but is used to guide the generation process.
    public enum TestHarness: String, Codable {
        /// Don't use any library
        case none

        /// Create a test using the XCTest library.
        case xctest

        /// Create a test using the swift-testing package.
        case swiftTesting = "swift-testing"

        /// The default testing library to use.
        public static var `default`: TestHarness = .xctest
    }

    /// Additional configuration information to guide the package editing
    /// process.
    public struct Configuration {
        /// The test harness to use.
        public var testHarness: TestHarness

        public init(testHarness: TestHarness = .default) {
            self.testHarness = testHarness
        }
    }

    /// Add the given target to the manifest, producing a set of edit results
    /// that updates the manifest and adds some source files to stub out the
    /// new target.
    public static func addTarget(
        _ target: TargetDescription,
        to manifest: SourceFileSyntax,
        configuration: Configuration = .init(),
        installedSwiftPMConfiguration: InstalledSwiftPMConfiguration = .default
    ) throws -> PackageEditResult {
        // Make sure we have a suitable tools version in the manifest.
        try manifest.checkEditManifestToolsVersion()

        guard let packageCall = manifest.findCall(calleeName: "Package") else {
            throw ManifestEditError.cannotFindPackage
        }

        // Create a mutable version of target to which we can add more
        // content when needed.
        var target = target

        // Add dependencies needed for various targets.
        switch target.type {
        case .macro:
            // Macro targets need to depend on a couple of libraries from
            // SwiftSyntax.
            target.dependencies.append(contentsOf: macroTargetDependencies)

        case .test where configuration.testHarness == .swiftTesting:
            // Testing targets using swift-testing need to depend on
            // SwiftTesting from the swift-testing package.
            target.dependencies.append(contentsOf: swiftTestingTestTargetDependencies)

        default:
            break;
        }

        var newPackageCall = try packageCall.appendingToArrayArgument(
            label: "targets",
            trailingLabels: Self.argumentLabelsAfterTargets,
            newElement: target.asSyntax()
        )

        let outerDirectory: String? = switch target.type {
        case .binary, .plugin, .system, .providedLibrary: nil
        case .executable, .regular, .macro: "Sources"
        case .test: "Tests"
        }

        guard let outerDirectory else {
            return PackageEditResult(
                manifestEdits: [
                    .replace(packageCall, with: newPackageCall.description)
                ]
            )
        }

        let outerPath = try RelativePath(validating: outerDirectory)

        /// The set of auxiliary files this refactoring will create.
        var auxiliaryFiles: AuxiliaryFiles = []

        // Add the primary source file. Every target type has this.
        addPrimarySourceFile(
            outerPath: outerPath,
            target: target,
            configuration: configuration,
            to: &auxiliaryFiles
        )

        // Perform any other actions that are needed for this target type.
        var extraManifestEdits: [SourceEdit] = []
        switch target.type {
        case .macro:
            addProvidedMacrosSourceFile(
                outerPath: outerPath,
                target: target,
                to: &auxiliaryFiles
            )

            if !manifest.description.contains("swift-syntax") {
                newPackageCall = try AddPackageDependency
                    .addPackageDependencyLocal(
                        .swiftSyntax(
                          configuration: installedSwiftPMConfiguration
                        ),
                        to: newPackageCall
                    )

                // Look for the first import declaration and insert an
                // import of `CompilerPluginSupport` there.
                let newImport = "import CompilerPluginSupport\n"
                for node in manifest.statements {
                    if let importDecl = node.item.as(ImportDeclSyntax.self) {
                        let insertPos = importDecl
                            .positionAfterSkippingLeadingTrivia
                        extraManifestEdits.append(
                            SourceEdit(
                                range: insertPos..<insertPos,
                                replacement: newImport
                            )
                        )
                        break
                    }
                }
            }

        case .test where configuration.testHarness == .swiftTesting:
            if !manifest.description.contains("swift-testing") {
                newPackageCall = try AddPackageDependency
                    .addPackageDependencyLocal(
                        .swiftTesting(
                          configuration: installedSwiftPMConfiguration
                        ),
                        to: newPackageCall
                    )
            }

        default: break;
        }

        return PackageEditResult(
            manifestEdits: [
                .replace(packageCall, with: newPackageCall.description)
            ] + extraManifestEdits,
            auxiliaryFiles: auxiliaryFiles
        )
    }

    /// Add the primary source file for a target to the list of auxiliary
    /// source files.
    fileprivate static func addPrimarySourceFile(
        outerPath: RelativePath,
        target: TargetDescription,
        configuration: Configuration,
        to auxiliaryFiles: inout AuxiliaryFiles
    ) {
        let sourceFilePath = outerPath.appending(
            components: [target.name, "\(target.name).swift"]
        )

        // Introduce imports for each of the dependencies that were specified.
        var importModuleNames = target.dependencies.map {
            $0.name
        }

        // Add appropriate test module dependencies.
        if target.type == .test {
            switch configuration.testHarness {
            case .none: 
                break

            case .xctest:
                importModuleNames.append("XCTest")

            case .swiftTesting: 
                // Import is handled by the added dependency.
                break
            }
        }

        let importDecls = importModuleNames.lazy.sorted().map { name in
            DeclSyntax("import \(raw: name)").with(\.trailingTrivia, .newline)
        }

        let imports = CodeBlockItemListSyntax {
            for importDecl in importDecls {
                importDecl
            }
        }

        let sourceFileText: SourceFileSyntax = switch target.type {
        case .binary, .plugin, .system, .providedLibrary:
            fatalError("should have exited above")

        case .macro:
            """
            \(imports)
            struct \(raw: target.name): Macro {
                /// TODO: Implement one or more of the protocols that inherit
                /// from Macro. The appropriate macro protocol is determined
                /// by the "macro" declaration that \(raw: target.name) implements.
                /// Examples include:
                ///     @freestanding(expression) macro --> ExpressionMacro
                ///     @attached(member) macro         --> MemberMacro
            }
            """

        case .test:
            switch configuration.testHarness {
            case .none:
                """
                \(imports)
                // Test code here
                """

            case .xctest:
                """
                \(imports)
                class \(raw: target.name): XCTestCase {
                    func test\(raw: target.name)() {
                        XCTAssertEqual(42, 17 + 25)
                    }
                }
                """

            case .swiftTesting:
                """
                \(imports)
                @Suite
                struct \(raw: target.name)Tests {
                    @Test("\(raw: target.name) tests")
                    func example() {
                        #expect(42 == 17 + 25)
                    }
                }
                """
            }

        case .regular:
            """
            \(imports)
            """

        case .executable:
            """
            \(imports)
            @main
            struct \(raw: target.name)Main {
                static func main() {
                    print("Hello, world")
                }
            }
            """
        }

        auxiliaryFiles.addSourceFile(
            path: sourceFilePath,
            sourceCode: sourceFileText
        )
    }

    /// Add a file that introduces the main entrypoint and provided macros
    /// for a macro target.
    fileprivate static func addProvidedMacrosSourceFile(
        outerPath: RelativePath,
        target: TargetDescription,
        to auxiliaryFiles: inout AuxiliaryFiles
    ) {
        auxiliaryFiles.addSourceFile(
            path: outerPath.appending(
                components: [target.name, "ProvidedMacros.swift"]
            ),
            sourceCode: """
            import SwiftCompilerPlugin

            @main
            struct \(raw: target.name)Macros: CompilerPlugin {
                let providingMacros: [Macro.Type] = [
                    \(raw: target.name).self,
                ]
            }
            """
        )
    }
}

fileprivate extension TargetDescription.Dependency {
    /// Retrieve the name of the dependency
    var name: String {
        switch self {
        case .target(name: let name, condition: _),
            .byName(name: let name, condition: _),
            .product(name: let name, package: _, moduleAliases: _, condition: _):
            name
        }
    }
}

/// The array of auxiliary files that can be added by a package editing
/// operation.
fileprivate typealias AuxiliaryFiles = [(RelativePath, SourceFileSyntax)]

fileprivate extension AuxiliaryFiles {
    /// Add a source file to the list of auxiliary files.
    mutating func addSourceFile(
        path: RelativePath,
        sourceCode: SourceFileSyntax
    ) {
        self.append((path, sourceCode))
    }
}

/// The set of dependencies we need to introduce to a newly-created macro
/// target.
fileprivate let macroTargetDependencies: [TargetDescription.Dependency] = [
    .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
    .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
]

/// The package dependency for swift-syntax, for use in macros.
fileprivate extension PackageDependency {
    /// Source control URL for the swift-syntax package.
    static var swiftSyntaxURL: SourceControlURL {
        "https://github.com/swiftlang/swift-syntax.git"
    }

    /// Package dependency on the swift-syntax package.
    static func swiftSyntax(
      configuration: InstalledSwiftPMConfiguration
    ) -> PackageDependency {
        let swiftSyntaxVersionDefault = configuration
            .swiftSyntaxVersionForMacroTemplate
        let swiftSyntaxVersion = Version(swiftSyntaxVersionDefault.description)!

        return .sourceControl(
            identity: PackageIdentity(url: swiftSyntaxURL),
            nameForTargetDependencyResolutionOnly: nil,
            location: .remote(swiftSyntaxURL),
            requirement: .range(.upToNextMajor(from: swiftSyntaxVersion)),
            productFilter: .everything,
            traits: []
        )
    }
}

/// The set of dependencies we need to introduce to a newly-created macro
/// target.
fileprivate let swiftTestingTestTargetDependencies: [TargetDescription.Dependency] = [
    .product(name: "Testing", package: "swift-testing"),
]


/// The package dependency for swift-testing, for use in test files.
fileprivate extension PackageDependency {
    /// Source control URL for the swift-syntax package.
    static var swiftTestingURL: SourceControlURL {
        "https://github.com/apple/swift-testing.git"
    }

    /// Package dependency on the swift-testing package.
    static func swiftTesting(
      configuration: InstalledSwiftPMConfiguration
    ) -> PackageDependency {
        let swiftTestingVersionDefault =
            configuration.swiftTestingVersionForTestTemplate
        let swiftTestingVersion = Version(swiftTestingVersionDefault.description)!

        return .sourceControl(
            identity: PackageIdentity(url: swiftTestingURL),
            nameForTargetDependencyResolutionOnly: nil,
            location: .remote(swiftTestingURL),
            requirement: .range(.upToNextMajor(from: swiftTestingVersion)),
            productFilter: .everything,
            traits: []
        )
    }
}
