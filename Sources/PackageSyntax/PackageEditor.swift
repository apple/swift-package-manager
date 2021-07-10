/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import TSCUtility
import TSCBasic
import SourceControl
import PackageLoading
import PackageModel
import Workspace
import Foundation

/// An editor for Swift packages.
///
/// This class provides high-level functionality for performing
/// editing operations a package.
public final class PackageEditor {

    /// Reference to the package editor context.
    let context: PackageEditorContext

    /// Create a package editor instance.
    public convenience init(manifestPath: AbsolutePath,
                            repositoryManager: RepositoryManager,
                            toolchain: UserToolchain,
                            diagnosticsEngine: DiagnosticsEngine) throws {
        self.init(context: try PackageEditorContext(manifestPath: manifestPath,
                                                    repositoryManager: repositoryManager,
                                                    toolchain: toolchain,
                                                    diagnosticsEngine: diagnosticsEngine))
    }

    /// Create a package editor instance.
    public init(context: PackageEditorContext) {
        self.context = context
    }

    /// The file system to perform disk operations on.
    var fs: FileSystem {
        return context.fs
    }

    /// Add a package dependency.
    public func addPackageDependency(url: String, requirement: PackageDependencyRequirement?) throws {
      var requirement = requirement
        let manifestPath = context.manifestPath
        // Validate that the package doesn't already contain this dependency.
        let loadedManifest = try context.loadManifest(at: context.manifestPath.parentDirectory)

        try diagnoseUnsupportedToolsVersions(manifest: loadedManifest)

        let containsDependency = loadedManifest.dependencies.contains {
            return PackageIdentity(url: url) == $0.identity
        }
        guard !containsDependency else {
            context.diagnosticsEngine.emit(.packageDependencyAlreadyExists(url: url,
                                                                           packageName: loadedManifest.name))
            throw Diagnostics.fatalError
        }

        // If the input URL is a path, force the requirement to be a local package.
        if TSCUtility.URL.scheme(url) == nil {
            guard requirement == nil || requirement == .localPackage else {
                context.diagnosticsEngine.emit(.nonLocalRequirementSpecifiedForLocalPath(path: url))
                throw Diagnostics.fatalError
            }
            requirement = .localPackage
        }

        // Load the dependency manifest depending on the inputs.
        let dependencyManifest: Manifest
        if requirement == .localPackage {
            let path = AbsolutePath(url, relativeTo: fs.currentWorkingDirectory!)
            dependencyManifest = try context.loadManifest(at: path)
            requirement = .localPackage
        } else {
            // Otherwise, first lookup the dependency.
            let spec = RepositorySpecifier(url: url)
            let handle = try tsc_await{
              context.repositoryManager.lookup(repository: spec,
                                               on: .global(qos: .userInitiated),
                                               completion: $0)
            }
            let repo = try handle.open()

            // Compute the requirement.
            if let inputRequirement = requirement {
                requirement = inputRequirement
            } else {
                // Use the latest version or the main/master branch.
                let versions = try repo.getTags().compactMap{ Version(string: $0) }
                let latestVersion = versions.filter({ $0.prereleaseIdentifiers.isEmpty }).max() ?? versions.max()
                let mainExists = (try? repo.resolveRevision(identifier: "main")) != nil
                requirement = latestVersion.map{ PackageDependencyRequirement.upToNextMajor($0.description) } ??
                    (mainExists ? PackageDependencyRequirement.branch("main") : PackageDependencyRequirement.branch("master"))
            }

            // Load the manifest.
            let revision = try repo.resolveRevision(identifier: requirement!.ref!)
            let repoFS = try repo.openFileView(revision: revision)
            dependencyManifest = try context.loadManifest(at: .root, fs: repoFS)
        }

        // Add the package dependency.
        let manifestContents = try fs.readFileContents(manifestPath).cString
        let editor = try ManifestRewriter(manifestContents, diagnosticsEngine: context.diagnosticsEngine)

        // Only tools-version 5.2, 5.3, & 5.4 should specify a package name.
        // At this point, we've already diagnosed tools-versions less than 5.2 as unsupported
        if loadedManifest.toolsVersion < .v5_5 {
            try editor.addPackageDependency(name: dependencyManifest.name,
                                            url: url,
                                            requirement: requirement!,
                                            branchAndRevisionConvenienceMethodsSupported: false)
        } else {
            try editor.addPackageDependency(name: nil,
                                            url: url,
                                            requirement: requirement!,
                                            branchAndRevisionConvenienceMethodsSupported: true)
        }

        try context.verifyEditedManifest(contents: editor.editedManifest)
        try fs.writeFileContents(manifestPath, bytes: ByteString(encodingAsUTF8: editor.editedManifest))
    }

    /// Add a new target.
    public func addTarget(_ newTarget: NewTarget, productPackageNameMapping: [String: String]) throws {
        let manifestPath = context.manifestPath

        // Validate that the package doesn't already contain a target with the same name.
        let loadedManifest = try context.loadManifest(at: manifestPath.parentDirectory)

        try diagnoseUnsupportedToolsVersions(manifest: loadedManifest)

        if loadedManifest.targets.contains(where: { $0.name == newTarget.name }) {
            context.diagnosticsEngine.emit(.targetAlreadyExists(name: newTarget.name,
                                                                packageName: loadedManifest.name))
            throw Diagnostics.fatalError
        }

        let manifestContents = try fs.readFileContents(manifestPath).cString
        let editor = try ManifestRewriter(manifestContents, diagnosticsEngine: context.diagnosticsEngine)

        switch newTarget {
        case .library(name: let name, includeTestTarget: _, dependencyNames: let dependencyNames),
             .executable(name: let name, dependencyNames: let dependencyNames),
             .test(name: let name, dependencyNames: let dependencyNames):
            try editor.addTarget(targetName: newTarget.name,
                                 factoryMethodName: newTarget.factoryMethodName(for: loadedManifest.toolsVersion))

            for dependency in dependencyNames {
                if loadedManifest.targets.map(\.name).contains(dependency) {
                    try editor.addByNameTargetDependency(target: name, dependency: dependency)
                } else if let productPackage = productPackageNameMapping[dependency] {
                    if productPackage == dependency {
                        try editor.addByNameTargetDependency(target: name, dependency: dependency)
                    } else {
                        try editor.addProductTargetDependency(target: name, product: dependency, package: productPackage)
                    }
                } else {
                    context.diagnosticsEngine.emit(.missingProductOrTarget(name: dependency))
                    throw Diagnostics.fatalError
                }
            }
        case .binary(name: let name, urlOrPath: let urlOrPath, checksum: let checksum):
            guard loadedManifest.toolsVersion >= .v5_3 else {
                context.diagnosticsEngine.emit(.unsupportedToolsVersionForBinaryTargets)
                throw Diagnostics.fatalError
            }
            try editor.addBinaryTarget(targetName: name, urlOrPath: urlOrPath, checksum: checksum)
        }

        try context.verifyEditedManifest(contents: editor.editedManifest)
        try fs.writeFileContents(manifestPath, bytes: ByteString(encodingAsUTF8: editor.editedManifest))

        // Write template files.
        try writeTemplateFilesForTarget(newTarget)

        if case .library(name: let name, includeTestTarget: true, dependencyNames: _) = newTarget {
            try self.addTarget(.test(name: "\(name)Tests", dependencyNames: [name]),
                               productPackageNameMapping: productPackageNameMapping)
        }
    }

    private func diagnoseUnsupportedToolsVersions(manifest: Manifest) throws {
        guard manifest.toolsVersion >= .v5_2 else {
            context.diagnosticsEngine.emit(.unsupportedToolsVersionForEditing)
            throw Diagnostics.fatalError
        }
    }

    private func writeTemplateFilesForTarget(_ newTarget: NewTarget) throws {
        switch newTarget {
        case .library:
            let targetPath = context.manifestPath.parentDirectory.appending(components: "Sources", newTarget.name)
            if !localFileSystem.exists(targetPath) {
                let file = targetPath.appending(component: "\(newTarget.name).swift")
                try fs.createDirectory(targetPath, recursive: true)
                try fs.writeFileContents(file, bytes: "")
            }
        case .executable:
            let targetPath = context.manifestPath.parentDirectory.appending(components: "Sources", newTarget.name)
            if !localFileSystem.exists(targetPath) {
                let file = targetPath.appending(component: "main.swift")
                try fs.createDirectory(targetPath, recursive: true)
                try fs.writeFileContents(file, bytes: "")
            }
        case .test:
            let testTargetPath = context.manifestPath.parentDirectory.appending(components: "Tests", newTarget.name)
            if !fs.exists(testTargetPath) {
                let file = testTargetPath.appending(components: newTarget.name + ".swift")
                try fs.createDirectory(testTargetPath, recursive: true)
                try fs.writeFileContents(file) {
                    $0 <<< """
                    import XCTest
                    @testable import <#Module#>

                    final class <#TestCase#>: XCTestCase {
                        func testExample() {

                        }
                    }
                    """
                }
            }
        case .binary:
            break
        }
    }

    public func addProduct(name: String, type: ProductType, targets: [String]) throws {
        let manifestPath = context.manifestPath

        // Validate that the package doesn't already contain a product with the same name.
        let loadedManifest = try context.loadManifest(at: manifestPath.parentDirectory)

        try diagnoseUnsupportedToolsVersions(manifest: loadedManifest)

        guard !loadedManifest.products.contains(where: { $0.name == name }) else {
            context.diagnosticsEngine.emit(.productAlreadyExists(name: name,
                                                                 packageName: loadedManifest.name))
            throw Diagnostics.fatalError
        }

        let manifestContents = try fs.readFileContents(manifestPath).cString
        let editor = try ManifestRewriter(manifestContents, diagnosticsEngine: context.diagnosticsEngine)
        try editor.addProduct(name: name, type: type)


        for target in targets {
            guard loadedManifest.targets.map(\.name).contains(target) else {
                context.diagnosticsEngine.emit(.noTarget(name: target, packageName: loadedManifest.name))
                throw Diagnostics.fatalError
            }
            try editor.addProductTarget(product: name, target: target)
        }

        try context.verifyEditedManifest(contents: editor.editedManifest)
        try fs.writeFileContents(manifestPath, bytes: ByteString(encodingAsUTF8: editor.editedManifest))
    }
}

extension Array where Element == TargetDescription.Dependency {
    func containsDependency(_ other: String) -> Bool {
        return self.contains {
            switch $0 {
            case .target(name: let name, condition: _),
                 .product(name: let name, package: _, condition: _),
                 .byName(name: let name, condition: _):
                return name == other
            }
        }
    }
}

/// The types of target.
public enum NewTarget {
    case library(name: String, includeTestTarget: Bool, dependencyNames: [String])
    case executable(name: String, dependencyNames: [String])
    case test(name: String, dependencyNames: [String])
    case binary(name: String, urlOrPath: String, checksum: String?)

    /// The name of the factory method for a target type.
    func factoryMethodName(for toolsVersion: ToolsVersion) -> String {
        switch self {
        case .executable:
          if toolsVersion >= .v5_4 {
            return "executableTarget"
          } else {
            return "target"
          }
        case .library: return "target"
        case .test: return "testTarget"
        case .binary: return "binaryTarget"
        }
    }

    /// The name of the new target.
    var name: String {
        switch self {
        case .library(name: let name, includeTestTarget: _, dependencyNames: _),
             .executable(name: let name, dependencyNames: _),
             .test(name: let name, dependencyNames: _),
             .binary(name: let name, urlOrPath: _, checksum: _):
            return name
        }
    }
}

public enum PackageDependencyRequirement: Equatable {
    case exact(String)
    case revision(String)
    case branch(String)
    case upToNextMajor(String)
    case upToNextMinor(String)
    case range(String, String)
    case closedRange(String, String)
    case localPackage

    var ref: String? {
        switch self {
        case .exact(let ref): return ref
        case .revision(let ref): return ref
        case .branch(let ref): return ref
        case .upToNextMajor(let ref): return ref
        case .upToNextMinor(let ref): return ref
        case .range(let start, _): return start
        case .closedRange(let start, _): return start
        case .localPackage: return nil
        }
    }
}

extension ProductType {
    var isLibrary: Bool {
        switch self {
        case .library:
            return true
        case .executable, .test, .plugin:
            return false
        }
    }
}

/// The global context for package editor.
public final class PackageEditorContext {
    /// Path to the package manifest.
    let manifestPath: AbsolutePath

    /// The manifest loader.
    let manifestLoader: ManifestLoaderProtocol

    /// The repository manager.
    let repositoryManager: RepositoryManager

    /// The file system in use.
    let fs: FileSystem

    /// The diagnostics engine used to report errors.
    let diagnosticsEngine: DiagnosticsEngine

    public init(manifestPath: AbsolutePath,
                repositoryManager: RepositoryManager,
                toolchain: UserToolchain,
                diagnosticsEngine: DiagnosticsEngine,
                fs: FileSystem = localFileSystem) throws {
        self.manifestPath = manifestPath
        self.repositoryManager = repositoryManager
        self.diagnosticsEngine = diagnosticsEngine
        self.fs = fs

        self.manifestLoader = ManifestLoader(manifestResources: toolchain.manifestResources)
    }

    func verifyEditedManifest(contents: String) throws {
        do {
            try withTemporaryDirectory {
                let path = $0
                try localFileSystem.writeFileContents(path.appending(component: "Package.swift"),
                                                      bytes: ByteString(encodingAsUTF8: contents))
                _ = try loadManifest(at: path, fs: localFileSystem)
            }
        } catch {
            diagnosticsEngine.emit(.failedToLoadEditedManifest(error: error))
            throw Diagnostics.fatalError
        }
    }

    /// Load the manifest at the given path.
    func loadManifest(
        at path: AbsolutePath,
        fs: FileSystem? = nil
    ) throws -> Manifest {
        let fs = fs ?? self.fs

        let toolsVersion = try ToolsVersionLoader().load(
            at: path, fileSystem: fs)
        return try tsc_await {
            manifestLoader.load(
                at: path,
                packageIdentity: .plain("<synthesized-root>"),
                packageKind: .local,
                packageLocation: path.pathString,
                version: nil,
                revision: nil,
                toolsVersion: toolsVersion,
                identityResolver: DefaultIdentityResolver(),
                fileSystem: fs,
                diagnostics: .init(),
                on: .global(),
                completion: $0
            )
        }
    }
}

private extension Diagnostic.Message {
    static func failedToLoadEditedManifest(error: Error) -> Diagnostic.Message {
        .error("discarding changes because the edited manifest could not be loaded: \(error)")
    }
    static var unsupportedToolsVersionForEditing: Diagnostic.Message =
        .error("command line editing of manifests is only supported for packages with a swift-tools-version of 5.2 and later")
    static var unsupportedToolsVersionForBinaryTargets: Diagnostic.Message =
        .error("binary targets are only supported in packages with a swift-tools-version of 5.3 and later")
    static func productAlreadyExists(name: String, packageName: String) -> Diagnostic.Message {
        .error("a product named '\(name)' already exists in '\(packageName)'")
    }
    static func packageDependencyAlreadyExists(url: String, packageName: String) -> Diagnostic.Message {
        .error("'\(packageName)' already has a dependency on '\(url)'")
    }
    static func noTarget(name: String, packageName: String) -> Diagnostic.Message {
        .error("no target named '\(name)' in '\(packageName)'")
    }
    static func targetAlreadyExists(name: String, packageName: String) -> Diagnostic.Message {
        .error("a target named '\(name)' already exists in '\(packageName)'")
    }
    static func nonLocalRequirementSpecifiedForLocalPath(path: String) -> Diagnostic.Message {
        .error("'\(path)' is a local package, but a non-local requirement was specified")
    }
    static func missingProductOrTarget(name: String) -> Diagnostic.Message {
        .error("could not find a product or target named '\(name)'")
    }
}
