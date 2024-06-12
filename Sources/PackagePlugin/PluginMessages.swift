//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

/// A message that the host can send to the plugin, including definitions of the corresponding serializable data structures.
enum HostToPluginMessage: Codable {
    
    /// The host requests that the plugin create build commands (corresponding to a `.buildTool` capability) for a target in the package graph.
    case createBuildToolCommands(
        context: InputContext,
        rootPackageId: InputContext.Package.Id,
        targetId: InputContext.Target.Id,
        pluginGeneratedSources: [InputContext.URL.Id],
        pluginGeneratedResources: [InputContext.URL.Id]
    )

    /// The host requests that the plugin perform a user command (corresponding to a `.command` capability) on a package in the graph.
    case performCommand(context: InputContext, rootPackageId: InputContext.Package.Id, arguments: [String])

        struct InputContext: Codable {
            let paths: [URL]
            let targets: [Target]
            let products: [Product]
            let packages: [Package]
            let pluginWorkDirId: URL.Id
            let toolSearchDirIds: [URL.Id]
            let accessibleTools: [String: Tool]

            // Wrapper struct for encoding information about a tool that's accessible to the plugin.
            struct Tool: Codable {
                let path: URL.Id
                let triples: [String]?
            }

            /// A single absolute path in the wire structure, represented as a tuple
            /// consisting of the ID of the base path and subpath off of that path.
            /// This avoids repetition of path components in the wire representation.
            struct URL: Codable {
                typealias Id = Int
                let baseURLId: URL.Id?
                let subpath: String
            }

            /// A package in the wire structure. All references to other entities are
            /// their ID numbers.
            struct Package: Codable {
                typealias Id = Int
                let identity: String
                let displayName: String
                let directoryId: URL.Id
                let origin: Origin
                let toolsVersion: ToolsVersion
                let dependencies: [Dependency]
                let productIds: [Product.Id]
                let targetIds: [Target.Id]

                enum Origin: Codable {
                    case root
                    case local(
                        path: URL.Id)
                    case repository(
                        url: String,
                        displayVersion: String,
                        scmRevision: String)
                    case registry(
                        identity: String,
                        displayVersion: String)
                }
                
                struct ToolsVersion: Codable {
                    let major: Int
                    let minor: Int
                    let patch: Int
                }

                /// A dependency on a package in the wire structure. All references to
                /// other entities are ID numbers.
                struct Dependency: Codable {
                    let packageId: Package.Id
                }
            }

            /// A product in the wire structure. All references to other entities are
            /// their ID numbers.
            struct Product: Codable {
                typealias Id = Int
                let name: String
                let targetIds: [Target.Id]
                let info: ProductInfo

                /// Information for each type of product in the wire structure. All
                /// references to other entities are their ID numbers.
                enum ProductInfo: Codable {
                    case executable(
                        mainTargetId: Target.Id)
                    case library(
                        kind: LibraryKind)

                    enum LibraryKind: Codable {
                        case `static`
                        case `dynamic`
                        case automatic
                    }
                }
            }

            /// A target in the wire structure. All references to other entities are
            /// their ID numbers.
            struct Target: Codable {
                typealias Id = Int
                let name: String
                let directoryId: URL.Id
                let dependencies: [Dependency]
                let info: TargetInfo

                /// A dependency on either a target or a product in the wire structure.
                /// All references to other entities are ID their numbers.
                enum Dependency: Codable {
                    case target(
                        targetId: Target.Id)
                    case product(
                        productId: Product.Id)
                }
                
                /// Type-specific information for a target in the wire structure. All
                /// references to other entities are their ID numbers.
                enum TargetInfo: Codable {
                    case swiftSourceModuleInfo(
                        moduleName: String,
                        kind: SourceModuleKind,
                        sourceFiles: [File],
                        compilationConditions: [String],
                        linkedLibraries: [String],
                        linkedFrameworks: [String])
                    
                    case clangSourceModuleInfo(
                        moduleName: String,
                        kind: SourceModuleKind,
                        sourceFiles: [File],
                        preprocessorDefinitions: [String],
                        headerSearchPaths: [String],
                        publicHeadersDirId: URL.Id?,
                        linkedLibraries: [String],
                        linkedFrameworks: [String])
                    
                    case binaryArtifactInfo(
                        kind: BinaryArtifactKind,
                        origin: BinaryArtifactOrigin,
                        artifactId: URL.Id)

                    case systemLibraryInfo(
                        pkgConfig: String?,
                        compilerFlags: [String],
                        linkerFlags: [String])

                    struct File: Codable {
                        let basePathId: URL.Id
                        let name: String
                        let type: FileType

                        enum FileType: String, Codable {
                            case source
                            case header
                            case resource
                            case unknown
                        }
                    }

                    enum SourceModuleKind: String, Codable {
                        case generic
                        case executable
                        case snippet
                        case test
                        case macro
                    }

                    enum BinaryArtifactKind: Codable {
                        case xcframework
                        case artifactsArchive
                    }

                    enum BinaryArtifactOrigin: Codable {
                        case local
                        case remote(url: String)
                    }
                }
            }
        }
    
    /// A response to a request to run a build operation.
    case buildOperationResponse(result: BuildResult)

        struct BuildResult: Codable {
            var succeeded: Bool
            var logText: String
            var builtArtifacts: [BuiltArtifact]
            
            struct BuiltArtifact: Codable {
                var path: URL
                var kind: Kind
                
                enum Kind: String, Codable {
                    case executable
                    case dynamicLibrary
                    case staticLibrary
                }
            }
        }

    /// A response to a request to run a test operation.
    case testOperationResponse(result: TestResult)

        struct TestResult: Codable {
            var succeeded: Bool
            var testTargets: [TestTarget]
            var codeCoverageDataFile: String?

            struct TestTarget: Codable {
                var name: String
                var testCases: [TestCase]
                
                struct TestCase: Codable {
                    var name: String
                    var tests: [Test]
                                       
                    struct Test: Codable {
                        var name: String
                        var result: Result
                        var duration: Double
                        
                        enum Result: String, Codable {
                            case succeeded
                            case skipped
                            case failed
                        }
                    }
                }
            }
        }
    
    /// A response to a request for symbol graph information for a target.
    case symbolGraphResponse(result: SymbolGraphResult)
    
        struct SymbolGraphResult: Codable {
            var directoryPath: URL
        }

    /// A response to a request for authorization info
    case authorizationInfoResponse(result: AuthorizationInfo?)
        struct AuthorizationInfo: Codable {
            var username: String
            var password: String
        }

    /// A response of an error while trying to complete a request.
    case errorResponse(error: String)
}


/// A message that the plugin can send to the host.
enum PluginToHostMessage: Codable {
    
    /// The plugin emits a diagnostic.
    case emitDiagnostic(severity: DiagnosticSeverity, message: String, file: String?, line: Int?)

        enum DiagnosticSeverity: String, Codable {
            case error, warning, remark
        }

    /// The plugin emits a progress message.
    case emitProgress(message: String)

    /// The plugin defines a build command.
    case defineBuildCommand(configuration: CommandConfiguration, inputFiles: [URL], outputFiles: [URL])

    /// The plugin defines a prebuild command.
    case definePrebuildCommand(configuration: CommandConfiguration, outputFilesDirectory: URL)
    
        struct CommandConfiguration: Codable {
            var version = 2
            var displayName: String?
            var executable: URL
            var arguments: [String]
            var environment: [String: String]
            var workingDirectory: URL?
        }
    
    /// The plugin is requesting that a build operation be run.
    case buildOperationRequest(subset: BuildSubset, parameters: BuildParameters)
    
        enum BuildSubset: Codable {
            case all(includingTests: Bool)
            case product(String)
            case target(String)
        }

        struct BuildParameters: Codable {
            var configuration: Configuration
            enum Configuration: String, Codable {
                case debug, release, inherit
            }
            var logging: LogVerbosity
            enum LogVerbosity: String, Codable {
                case concise, verbose, debug
            }
            var echoLogs: Bool
            var otherCFlags: [String]
            var otherCxxFlags: [String]
            var otherSwiftcFlags: [String]
            var otherLinkerFlags: [String]
        }

    /// The plugin is requesting that a test operation be run.
    case testOperationRequest(subset: TestSubset, parameters: TestParameters)

        enum TestSubset: Codable {
            case all
            case filtered([String])
        }

        struct TestParameters: Codable {
            var enableCodeCoverage: Bool
        }

    /// The plugin is requesting symbol graph information for a given target and set of options.
    case symbolGraphRequest(targetName: String, options: SymbolGraphOptions)

        struct SymbolGraphOptions: Codable {
            var minimumAccessLevel: AccessLevel
            enum AccessLevel: String, Codable {
                case `private`, `fileprivate`, `internal`, `public`, `open`
            }
            var includeSynthesized: Bool
            var includeSPI: Bool
            var emitExtensionBlocks: Bool
        }

    /// the plugin requesting authorization information
    case authorizationInfoRequest(url: String)
}
