/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basics
import Dispatch
import PackageModel
import TSCBasic
import TSCUtility

/// An error in the structure or layout of a package.
public enum ModuleError: Swift.Error {

    /// Describes a way in which a package layout is invalid.
    public enum InvalidLayoutType {
        case multipleSourceRoots([AbsolutePath])
        case modulemapInSources(AbsolutePath)
        case modulemapMissing(AbsolutePath)
    }

    /// Indicates two targets with the same name and their corresponding packages.
    case duplicateModule(String, [String])

    /// The referenced target could not be found.
    case moduleNotFound(String, TargetDescription.TargetType)

    /// The artifact for the binary target could not be found.
    case artifactNotFound(String)

    /// Invalid custom path.
    case invalidCustomPath(target: String, path: String)

    /// Package layout is invalid.
    case invalidLayout(InvalidLayoutType)

    /// The manifest has invalid configuration wrt type of the target.
    case invalidManifestConfig(String, String)

    /// The target dependency declaration has cycle in it.
    case cycleDetected((path: [String], cycle: [String]))

    /// The public headers directory is at an invalid path.
    case invalidPublicHeadersDirectory(String)

    /// The sources of a target are overlapping with another target.
    case overlappingSources(target: String, sources: [AbsolutePath])

    /// We found multiple test manifest  files.
    case multipleTestManifestFilesFound(package: String, files: [AbsolutePath])

    /// The tools version in use is not compatible with target's sources.
    case incompatibleToolsVersions(package: String, required: [SwiftLanguageVersion], current: ToolsVersion)

    /// The target path is outside the package.
    case targetOutsidePackage(package: String, target: String)

    /// Unsupported target path
    case unsupportedTargetPath(String)

    /// Invalid header search path.
    case invalidHeaderSearchPath(String)

    /// Default localization not set in the presence of localized resources.
    case defaultLocalizationNotSet

    /// A plugin target was declared but the feature flag isn't enabled.
    case pluginTargetRequiresFeatureFlag(target: String)

    /// A plugin target didn't declare a capability.
    case pluginCapabilityNotDeclared(target: String)
}

extension ModuleError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .duplicateModule(let name, let packages):
            let packages = packages.joined(separator: "', '")
            return "multiple targets named '\(name)' in: '\(packages)'"
        case .moduleNotFound(let target, let type):
            let folderName = (type == .test) ? "Tests" : (type == .plugin) ? "Plugins" : "Sources"
            return "Source files for target \(target) should be located under '\(folderName)/\(target)', or a custom sources path can be set with the 'path' property in Package.swift"
        case .artifactNotFound(let target):
            return "artifact not found for target '\(target)'"
        case .invalidLayout(let type):
            return "package has unsupported layout; \(type)"
        case .invalidManifestConfig(let package, let message):
            return "configuration of package '\(package)' is invalid; \(message)"
        case .cycleDetected(let cycle):
            return "cyclic dependency declaration found: " +
                (cycle.path + cycle.cycle).joined(separator: " -> ") +
                " -> " + cycle.cycle[0]
        case .invalidPublicHeadersDirectory(let name):
            return "public headers (\"include\") directory path for '\(name)' is invalid or not contained in the target"
        case .overlappingSources(let target, let sources):
            return "target '\(target)' has sources overlapping sources: " +
                sources.map({ $0.description }).joined(separator: ", ")
        case .multipleTestManifestFilesFound(let package, let files):
            return "package '\(package)' has multiple test manifest files: " +
                files.map({ $0.description }).sorted().joined(separator: ", ")
        case .incompatibleToolsVersions(let package, let required, let current):
            if required.isEmpty {
                return "package '\(package)' supported Swift language versions is empty"
            }
            return "package '\(package)' requires minimum Swift language version \(required[0]) which is not supported by the current tools version (\(current))"
        case .targetOutsidePackage(let package, let target):
            return "target '\(target)' in package '\(package)' is outside the package root"
        case .unsupportedTargetPath(let targetPath):
            return "target path '\(targetPath)' is not supported; it should be relative to package root"
        case .invalidCustomPath(let target, let path):
            return "invalid custom path '\(path)' for target '\(target)'"
        case .invalidHeaderSearchPath(let path):
            return "invalid header search path '\(path)'; header search path should not be outside the package root"
        case .defaultLocalizationNotSet:
            return "manifest property 'defaultLocalization' not set; it is required in the presence of localized resources"
        case .pluginTargetRequiresFeatureFlag(let target):
            return "plugin target '\(target)' cannot be used because the feature isn't enabled (set SWIFTPM_ENABLE_PLUGINS=1 in environment)"
        case .pluginCapabilityNotDeclared(let target):
            return "plugin target '\(target)' doesn't have a 'capability' property"
        }
    }
}

extension ModuleError.InvalidLayoutType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .multipleSourceRoots(let paths):
          return "multiple source roots found: " + paths.map({ $0.description }).sorted().joined(separator: ", ")
        case .modulemapInSources(let path):
            return "modulemap '\(path)' should be inside the 'include' directory"
        case .modulemapMissing(let path):
            return "missing system target module map at '\(path)'"
        }
    }
}

extension Target {

    /// An error in the organization or configuration of an individual target.
    enum Error: Swift.Error {

        /// The target's name is invalid.
        case invalidName(path: RelativePath, problem: ModuleNameProblem)
        enum ModuleNameProblem {
            /// Empty target name.
            case emptyName
        }

        /// The target contains an invalid mix of languages (e.g. both Swift and C).
        case mixedSources(AbsolutePath)
    }
}

extension Target.Error: CustomStringConvertible {
    var description: String {
        switch self {
        case .invalidName(let path, let problem):
            return "invalid target name at '\(path)'; \(problem)"
        case .mixedSources(let path):
            return "target at '\(path)' contains mixed language source files; feature not supported"
        }
    }
}

extension Target.Error.ModuleNameProblem: CustomStringConvertible {
    var description: String {
        switch self {
          case .emptyName:
            return "target names can not be empty"
        }
    }
}

extension Product {
    /// An error in a product definition.
    enum Error: Swift.Error {
        case moduleEmpty(product: String, target: String)
    }
}

extension Product.Error: CustomStringConvertible {
    var description: String {
        switch self {
        case .moduleEmpty(let product, let target):
            return "target '\(target)' referenced in product '\(product)' is empty"
        }
    }
}

/// A structure representing the remote artifact information necessary to construct the package.
public struct BinaryArtifact {
    /// The kind of the artifact.
    public let kind: BinaryTarget.Kind

    /// The URL the artifact was downloaded from.
    public let originURL: String?

    /// The path to the  artifact.
    public let path: AbsolutePath

    public init(kind: BinaryTarget.Kind, originURL: String?, path: AbsolutePath) {
        self.kind = kind
        self.originURL = originURL
        self.path = path
    }
}

/// Helper for constructing a package following the convention system.
///
/// The 'builder' here refers to the builder pattern and not any build system
/// related function.
public final class PackageBuilder {
    /// The identity for the package being constructed.
    private let identity: PackageIdentity

    /// The manifest for the package being constructed.
    private let manifest: Manifest

    /// The product filter to apply to the package.
    private let productFilter: ProductFilter

    /// The path of the package.
    private let packagePath: AbsolutePath

    /// Information concerning the different downloaded binary target artifacts.
    private let binaryArtifacts: [BinaryArtifact]

    /// The filesystem package builder will run on.
    private let fileSystem: FileSystem

    /// The diagnostics engine.
    private let diagnostics: DiagnosticsEngine

    /// Create multiple test products.
    ///
    /// If set to true, one test product will be created for each test target.
    private let shouldCreateMultipleTestProducts: Bool

    /// Temporary parameter controlling whether to warn about implicit executable targets when tools version is 5.4.
    private let warnAboutImplicitExecutableTargets: Bool

    /// Temporary parameter controlling whether to allow package plugin targets (during bring-up, before proposal is accepted).
    /// This is set if SWIFTPM_ENABLE_PLUGINS=1 or if the feature is enabled in the initializer (for use by unit tests).
    private let allowPluginTargets: Bool
    
    /// Create the special REPL product for this package.
    private let createREPLProduct: Bool

    /// The additionla file detection rules.
    private let additionalFileRules: [FileRuleDescription]

    /// Minimum deployment target of XCTest per platform.
    private let xcTestMinimumDeploymentTargets: [PackageModel.Platform:PlatformVersion]

    /// Create a builder for the given manifest and package `path`.
    ///
    /// - Parameters:
    ///   - identity: The identity of this package.
    ///   - manifest: The manifest of this package.
    ///   - path: The root path of the package.
    ///   - artifactPaths: Paths to the downloaded binary target artifacts.
    ///   - fileSystem: The file system on which the builder should be run.
    ///   - diagnostics: The diagnostics engine.
    ///   - createMultipleTestProducts: If enabled, create one test product for
    ///     each test target.
    public init(
        identity: PackageIdentity,
        manifest: Manifest,
        productFilter: ProductFilter,
        path: AbsolutePath,
        additionalFileRules: [FileRuleDescription] = [],
        binaryArtifacts: [BinaryArtifact] = [],
        xcTestMinimumDeploymentTargets: [PackageModel.Platform:PlatformVersion],
        fileSystem: FileSystem = localFileSystem,
        diagnostics: DiagnosticsEngine,
        shouldCreateMultipleTestProducts: Bool = false,
        warnAboutImplicitExecutableTargets: Bool = true,
        allowPluginTargets: Bool = false,
        createREPLProduct: Bool = false
    ) {
        self.identity = identity
        self.manifest = manifest
        self.productFilter = productFilter
        self.packagePath = path
        self.additionalFileRules = additionalFileRules
        self.binaryArtifacts = binaryArtifacts
        self.xcTestMinimumDeploymentTargets = xcTestMinimumDeploymentTargets
        self.fileSystem = fileSystem
        self.diagnostics = diagnostics
        self.shouldCreateMultipleTestProducts = shouldCreateMultipleTestProducts
        self.allowPluginTargets = allowPluginTargets || ProcessEnv.vars["SWIFTPM_ENABLE_PLUGINS"] == "1"
        self.createREPLProduct = createREPLProduct
        self.warnAboutImplicitExecutableTargets = warnAboutImplicitExecutableTargets
    }

    // deprecated 3/21, remove once clients migrated over
    @available(*, deprecated, message: "use loadRootPackage instead")
    public static func loadPackage(
        at path: AbsolutePath,
        kind: PackageReference.Kind = .root,
        swiftCompiler: AbsolutePath,
        swiftCompilerFlags: [String],
        xcTestMinimumDeploymentTargets: [PackageModel.Platform:PlatformVersion]
            = MinimumDeploymentTarget.default.xcTestMinimumDeploymentTargets,
        identityResolver: IdentityResolver,
        diagnostics: DiagnosticsEngine,
        on queue: DispatchQueue,
        completion: @escaping (Result<Package, Error>) -> Void
    ) {
        ManifestLoader.loadManifest(at: path,
                                    kind: kind,
                                    swiftCompiler: swiftCompiler,
                                    swiftCompilerFlags: swiftCompilerFlags,
                                    identityResolver: identityResolver,
                                    on: queue) { result in
            let result = result.tryMap { manifest -> Package in
                let identity = identityResolver.resolveIdentity(for: manifest.packageLocation)
                let builder = PackageBuilder(
                    identity: identity,
                    manifest: manifest,
                    productFilter: .everything,
                    path: path,
                    xcTestMinimumDeploymentTargets: xcTestMinimumDeploymentTargets,
                    diagnostics: diagnostics)
                return try builder.construct()
            }
            completion(result)
        }
    }

    /// Loads a root package from a path using the resources associated with a particular `swiftc` executable.
    ///
    /// - Parameters:
    ///   - at: The absolute path of the package root.
    ///   - swiftCompiler: The absolute path of a `swiftc` executable. Its associated resources will be used by the loader.
    ///   - identityResolver: A helper to resolve identities based on configuration
    ///   - diagnostics: Optional.  The diagnostics engine.
    ///   - on: The dispatch queue to perform asynchronous operations on.
    ///   - completion: The completion handler .
    public static func loadRootPackage(
        at path: AbsolutePath,
        swiftCompiler: AbsolutePath,
        swiftCompilerFlags: [String],
        xcTestMinimumDeploymentTargets: [PackageModel.Platform:PlatformVersion] = MinimumDeploymentTarget.default.xcTestMinimumDeploymentTargets,
        identityResolver: IdentityResolver,
        diagnostics: DiagnosticsEngine,
        on queue: DispatchQueue,
        completion: @escaping (Result<Package, Error>) -> Void
    ) {
        ManifestLoader.loadRootManifest(at: path,
                                        swiftCompiler: swiftCompiler,
                                        swiftCompilerFlags: swiftCompilerFlags,
                                        identityResolver: identityResolver,
                                        diagnostics: diagnostics,
                                        on: queue) { result in
            let result = result.tryMap { manifest -> Package in
                let identity = identityResolver.resolveIdentity(for: manifest.packageLocation)
                let builder = PackageBuilder(
                    identity: identity,
                    manifest: manifest,
                    productFilter: .everything,
                    path: path,
                    xcTestMinimumDeploymentTargets: xcTestMinimumDeploymentTargets,
                    diagnostics: diagnostics)
                return try builder.construct()
            }
            completion(result)
        }
    }

    /// Build a new package following the conventions.
    public func construct() throws -> Package {
        let targets = try self.constructTargets()
        let products = try self.constructProducts(targets)
        // Find the special directory for targets.
        let targetSpecialDirs = findTargetSpecialDirs(targets)

        return Package(
            identity: self.identity,
            manifest: self.manifest,
            path: self.packagePath,
            targets: targets,
            products: products,
            targetSearchPath: self.packagePath.appending(component: targetSpecialDirs.targetDir),
            testTargetSearchPath: self.packagePath.appending(component: targetSpecialDirs.testTargetDir)
        )
    }

    private var diagnosticLocation: DiagnosticLocation {
        return PackageLocation.Local(name: self.manifest.name, packagePath: self.packagePath)
    }

    /// Computes the special directory where targets are present or should be placed in future.
    private func findTargetSpecialDirs(_ targets: [Target]) -> (targetDir: String, testTargetDir: String) {
        let predefinedDirs = findPredefinedTargetDirectory()

        // Select the preferred tests directory.
        var testTargetDir = PackageBuilder.predefinedTestDirectories[0]

        // If found predefined test directory is not same as preferred test directory,
        // check if any of the test target is actually inside the predefined test directory.
        if predefinedDirs.testTargetDir != testTargetDir {
            let expectedTestsDir = packagePath.appending(component: predefinedDirs.testTargetDir)
            for target in targets where target.type == .test {
                // If yes, use the predefined test directory as preferred test directory.
                if expectedTestsDir == target.sources.root.parentDirectory {
                    testTargetDir = predefinedDirs.testTargetDir
                    break
                }
            }
        }

        return (predefinedDirs.targetDir, testTargetDir)
    }

    // MARK: Utility Predicates

    private func isValidSource(_ path: AbsolutePath) -> Bool {
        // Ignore files which don't match the expected extensions.
        guard let ext = path.extension, SupportedLanguageExtension.validExtensions(toolsVersion: self.manifest.toolsVersion).contains(ext) else {
            return false
        }

        let basename = path.basename

        // Ignore dotfiles.
        if basename.hasPrefix(".") { return false }

        // Ignore test manifest.
        if SwiftTarget.testManifestNames.contains(basename) { return false }

        // Ignore paths which are not valid files.
        if !fileSystem.isFile(path) {

            // Diagnose broken symlinks.
            if fileSystem.isSymlink(path) {
                diagnostics.emit(.brokenSymlink(path), location: self.diagnosticLocation)
            }

            return false
        }

        // Ignore manifest files.
        if path.parentDirectory == packagePath {
            if basename == Manifest.filename { return false }

            // Ignore version-specific manifest files.
            if basename.hasPrefix(Manifest.basename + "@") && basename.hasSuffix(".swift") {
                return false
            }
        }

        // Otherwise, we have a valid source file.
        return true
    }

    private func shouldConsiderDirectory(_ path: AbsolutePath) -> Bool {
        let base = path.basename.lowercased()
        if base == "tests" { return false }
        if base == "include" { return false }
        if base.hasSuffix(".xcodeproj") { return false }
        if base.hasSuffix(".playground") { return false }
        if base.hasPrefix(".") { return false }  // eg .git
        if path == packagesDirectory { return false }
        if !fileSystem.isDirectory(path) { return false }
        return true
    }

    private var packagesDirectory: AbsolutePath {
        return packagePath.appending(component: "Packages")
    }

    /// Returns path to all the items in a directory.
    // FIXME: This is generic functionality, and should move to FileSystem.
    func directoryContents(_ path: AbsolutePath) throws -> [AbsolutePath] {
        return try fileSystem.getDirectoryContents(path).map({ path.appending(component: $0) })
    }

    /// Private function that creates and returns a list of targets defined by a package.
    private func constructTargets() throws -> [Target] {

        // Check for a modulemap file, which indicates a system target.
        let moduleMapPath = packagePath.appending(component: moduleMapFilename)
        if fileSystem.isFile(moduleMapPath) {

            // Warn about any declared targets.
            if !manifest.targets.isEmpty {
                diagnostics.emit(
                    .systemPackageDeclaresTargets(targets: Array(manifest.targets.map({ $0.name }))),
                    location: self.diagnosticLocation
                )
            }

            // Emit deprecation notice.
            if manifest.toolsVersion >= .v4_2 {
                diagnostics.emit(.systemPackageDeprecation, location: self.diagnosticLocation)
            }

            // Package contains a modulemap at the top level, so we assuming
            // it's a system library target.
            return [
                SystemLibraryTarget(
                    name: self.manifest.name,
                    platforms: self.platforms(),
                    path: self.packagePath,
                    isImplicit: true,
                    pkgConfig: self.manifest.pkgConfig,
                    providers: self.manifest.providers
                )
            ]
        }

        // At this point the target can't be a system target, make sure manifest doesn't contain
        // system target specific configuration.
        guard manifest.pkgConfig == nil else {
            throw ModuleError.invalidManifestConfig(
                self.manifest.name, "the 'pkgConfig' property can only be used with a System Module Package")
        }

        guard manifest.providers == nil else {
            throw ModuleError.invalidManifestConfig(
                self.manifest.name, "the 'providers' property can only be used with a System Module Package")
        }

        return try constructV4Targets()
    }

    /// Predefined source directories, in order of preference.
    public static let predefinedSourceDirectories = ["Sources", "Source", "src", "srcs"]

    /// Predefined test directories, in order of preference.
    public static let predefinedTestDirectories = ["Tests", "Sources", "Source", "src", "srcs"]
    
    /// Predefined plugin directories, in order of preference.
    public static let predefinedPluginDirectories = ["Plugins"]

    /// Finds the predefined directories for regular targets, test targets, and plugin targets.
    private func findPredefinedTargetDirectory() -> (targetDir: String, testTargetDir: String, pluginTargetDir: String) {
        let targetDir = PackageBuilder.predefinedSourceDirectories.first(where: {
            fileSystem.isDirectory(packagePath.appending(component: $0))
        }) ?? PackageBuilder.predefinedSourceDirectories[0]

        let testTargetDir = PackageBuilder.predefinedTestDirectories.first(where: {
            fileSystem.isDirectory(packagePath.appending(component: $0))
        }) ?? PackageBuilder.predefinedTestDirectories[0]

        let pluginTargetDir = PackageBuilder.predefinedPluginDirectories.first(where: {
            fileSystem.isDirectory(packagePath.appending(component: $0))
        }) ?? PackageBuilder.predefinedPluginDirectories[0]

        return (targetDir, testTargetDir, pluginTargetDir)
    }

    struct PredefinedTargetDirectory {
        let path: AbsolutePath
        let contents: [String]

        init(fs: FileSystem, path: AbsolutePath) {
            self.path = path
            self.contents = (try? fs.getDirectoryContents(path)) ?? []
        }
    }

    /// Construct targets according to PackageDescription 4 conventions.
    fileprivate func constructV4Targets() throws -> [Target] {
        // Select the correct predefined directory list.
        let predefinedDirs = findPredefinedTargetDirectory()

        let predefinedTargetDirectory = PredefinedTargetDirectory(fs: fileSystem, path: packagePath.appending(component: predefinedDirs.targetDir))
        let predefinedTestTargetDirectory = PredefinedTargetDirectory(fs: fileSystem, path: packagePath.appending(component: predefinedDirs.testTargetDir))
        let predefinedPluginTargetDirectory = PredefinedTargetDirectory(fs: fileSystem, path: packagePath.appending(component: predefinedDirs.pluginTargetDir))

        /// Returns the path of the given target.
        func findPath(for target: TargetDescription) throws -> AbsolutePath {
            // If there is a custom path defined, use that.
            if let subpath = target.path {
                if subpath == "" || subpath == "." {
                    return packagePath
                }

                // Make sure target is not referenced by absolute path
                guard let relativeSubPath = try? RelativePath(validating: subpath) else {
                    throw ModuleError.unsupportedTargetPath(subpath)
                }

                let path = packagePath.appending(relativeSubPath)
                // Make sure the target is inside the package root.
                guard path.contains(packagePath) else {
                    throw ModuleError.targetOutsidePackage(package: self.manifest.name, target: target.name)
                }
                if fileSystem.isDirectory(path) {
                    return path
                }
                throw ModuleError.invalidCustomPath(target: target.name, path: subpath)
            } else if target.type == .binary {
                if let artifact = self.binaryArtifacts.first(where: { $0.path.basenameWithoutExt == target.name }) {
                    return artifact.path
                } else {
                    throw ModuleError.artifactNotFound(target.name)
                }
            }

            // Check if target is present in the predefined directory.
            let predefinedDir: PredefinedTargetDirectory
            switch target.type {
            case .test:
                predefinedDir = predefinedTestTargetDirectory
            case .plugin:
                predefinedDir = predefinedPluginTargetDirectory
            default:
                predefinedDir = predefinedTargetDirectory
            }
            let path = predefinedDir.path.appending(component: target.name)

            // Return the path if the predefined directory contains it.
            if predefinedDir.contents.contains(target.name) {
                return path
            }

            // Otherwise, if the path "exists" then the case in manifest differs from the case on the file system.
            if fileSystem.isDirectory(path) {
                diagnostics.emit(.targetNameHasIncorrectCase(target: target.name), location: self.diagnosticLocation)
                return path
            }
            throw ModuleError.moduleNotFound(target.name, target.type)
        }

        // Create potential targets.
        let potentialTargets: [PotentialModule]
        potentialTargets = try manifest.targetsRequired(for: productFilter).map({ target in
            let path = try findPath(for: target)
            return PotentialModule(name: target.name, path: path, type: target.type)
        })
        return try createModules(potentialTargets)
    }

    // Create targets from the provided potential targets.
    private func createModules(_ potentialModules: [PotentialModule]) throws -> [Target] {
        // Find if manifest references a target which isn't present on disk.
        let allVisibleModuleNames = manifest.visibleModuleNames(for: productFilter)
        let potentialModulesName = Set(potentialModules.map({ $0.name }))
        let missingModuleNames = allVisibleModuleNames.subtracting(potentialModulesName)
        if let missingModuleName = missingModuleNames.first {
            let type = potentialModules.first(where: { $0.name == missingModuleName })?.type ?? .regular
            throw ModuleError.moduleNotFound(missingModuleName, type)
        }

        let potentialModuleMap = Dictionary(potentialModules.map({ ($0.name, $0) }), uniquingKeysWith: { $1 })
        let successors: (PotentialModule) -> [PotentialModule] = {
            // No reference of this target in manifest, i.e. it has no dependencies.
            guard let target = self.manifest.targetMap[$0.name] else { return [] }
            // Collect the successors from declared dependencies.
            var successors: [PotentialModule] = target.dependencies.compactMap({
                switch $0 {
                case .target(let name, _):
                    // Since we already checked above that all referenced targets
                    // has to present, we always expect this target to be present in
                    // potentialModules dictionary.
                    return potentialModuleMap[name]!
                case .product:
                    return nil
                case .byName(let name, _):
                    // By name dependency may or may not be a target dependency.
                    return potentialModuleMap[name]
                }
            })
            // If there are plugin usages, consider them to be dependencies too.
            if let pluginUsages = target.pluginUsages {
                successors += pluginUsages.compactMap({
                    switch $0 {
                    case .plugin(let name, let package):
                        return (package == nil) ? potentialModuleMap[name] : nil
                    }
                })
            }
            return successors
        }
        // Look for any cycle in the dependencies.
        if let cycle = findCycle(potentialModules.sorted(by: { $0.name < $1.name }), successors: successors) {
            throw ModuleError.cycleDetected((cycle.path.map({ $0.name }), cycle.cycle.map({ $0.name })))
        }
        // There was no cycle so we sort the targets topologically.
        let potentialModules = try topologicalSort(potentialModules, successors: successors)

        // The created targets mapped to their name.
        var targets = [String: Target]()
        // If a direcotry is empty, we don't create a target object for them.
        var emptyModules = Set<String>()

        // Start iterating the potential targets.
        for potentialModule in potentialModules.lazy.reversed() {
            // Validate the target name.  This function will throw an error if it detects a problem.
            try validateModuleName(potentialModule.path, potentialModule.name, isTest: potentialModule.isTest)

            // Get the target from the manifest.
            let manifestTarget = manifest.targetMap[potentialModule.name]

            // Get the dependencies of this target.
            let dependencies: [Target.Dependency] = manifestTarget.map {
                $0.dependencies.compactMap { dependency in
                    switch dependency {
                    case .target(let name, let condition):
                        // We don't create an object for targets which have no sources.
                        if emptyModules.contains(name) { return nil }
                        guard let target = targets[name] else { return nil }
                        return .target(target, conditions: buildConditions(from: condition))

                    case .product(let name, let package, let condition):
                        return .product(
                            .init(name: name, package: package),
                            conditions: buildConditions(from: condition)
                        )

                    case .byName(let name, let condition):
                        // We don't create an object for targets which have no sources.
                        if emptyModules.contains(name) { return nil }
                        if let target = targets[name] {
                            return .target(target, conditions: buildConditions(from: condition))
                        } else if potentialModuleMap[name] == nil {
                            return .product(
                                .init(name: name, package: nil),
                                conditions: buildConditions(from: condition)
                            )
                        } else {
                            return nil
                        }
                    }
                }
            } ?? []
            
            // Get dependencies from the plugin usages of this target.
            let pluginUsages: [Target.PluginUsage] = manifestTarget?.pluginUsages.map {
                $0.compactMap{ usage in
                    switch usage {
                    case .plugin(let name, let package):
                        if let package = package {
                            return .product(Target.ProductReference(name: name, package: package), conditions: [])
                        }
                        else {
                            guard let target = targets[name] else { return nil }
                            return .target(target, conditions: [])
                        }
                    }
                }
            } ?? []
            
            // Create the target, adding the inferred dependencies from plugin usages to the declared dependencies.
            let target = try createTarget(
                potentialModule: potentialModule,
                manifestTarget: manifestTarget,
                dependencies: dependencies + pluginUsages
            )
            // Add the created target to the map or print no sources warning.
            if let createdTarget = target {
                targets[createdTarget.name] = createdTarget
            } else {
                emptyModules.insert(potentialModule.name)
                diagnostics.emit(.targetHasNoSources(targetPath: potentialModule.path.pathString, target: potentialModule.name))
            }
        }
        return targets.values.map{ $0 }.sorted{ $0.name > $1.name  }
    }

    /// Private function that checks whether a target name is valid.  This method doesn't return anything, but rather,
    /// if there's a problem, it throws an error describing what the problem is.
    private func validateModuleName(_ path: AbsolutePath, _ name: String, isTest: Bool) throws {
        if name.isEmpty {
            throw Target.Error.invalidName(
                path: path.relative(to: packagePath),
                problem: .emptyName)
        }
    }

    /// Private function that constructs a single Target object for the potential target.
    private func createTarget(
        potentialModule: PotentialModule,
        manifestTarget: TargetDescription?,
        dependencies: [Target.Dependency]
    ) throws -> Target? {
        guard let manifestTarget = manifestTarget else { return nil }

        // Create system library target.
        if potentialModule.type == .system {
            let moduleMapPath = potentialModule.path.appending(component: moduleMapFilename)
            guard fileSystem.isFile(moduleMapPath) else {
                throw ModuleError.invalidLayout(.modulemapMissing(moduleMapPath))
            }

            return SystemLibraryTarget(
                name: potentialModule.name,
                platforms: self.platforms(),
                path: potentialModule.path, isImplicit: false,
                pkgConfig: manifestTarget.pkgConfig,
                providers: manifestTarget.providers
            )
        } else if potentialModule.type == .binary {
            guard let artifact = self.binaryArtifacts.first(where: { $0.path == potentialModule.path }) else {
                throw InternalError("unknown binary artifact for '\(potentialModule.name)'")
            }
            let artifactOrigin: BinaryTarget.Origin = artifact.originURL.flatMap{ .remote(url: $0) } ?? .local
            return BinaryTarget(
                name: potentialModule.name,
                kind: artifact.kind,
                platforms: self.platforms(),
                path: potentialModule.path,
                origin: artifactOrigin
            )
        }

        // Check for duplicate target dependencies by name
        let combinedDependencyNames = dependencies.map { $0.target?.name ?? $0.product!.name }
        combinedDependencyNames.spm_findDuplicates().forEach {
            diagnostics.emit(.duplicateTargetDependency(dependency: $0, target: potentialModule.name, package: self.manifest.name))
        }

        // Create the build setting assignment table for this target.
        let buildSettings = try self.buildSettings(for: manifestTarget, targetRoot: potentialModule.path)

        // Compute the path to public headers directory.
        let publicHeaderComponent = manifestTarget.publicHeadersPath ?? ClangTarget.defaultPublicHeadersComponent
        let publicHeadersPath = potentialModule.path.appending(try RelativePath(validating: publicHeaderComponent))
        guard publicHeadersPath.contains(potentialModule.path) else {
            throw ModuleError.invalidPublicHeadersDirectory(potentialModule.name)
        }

        let sourcesBuilder = TargetSourcesBuilder(
            packageName: self.manifest.name,
            packagePath: self.packagePath,
            target: manifestTarget,
            path: potentialModule.path,
            defaultLocalization: self.manifest.defaultLocalization,
            additionalFileRules: self.additionalFileRules,
            toolsVersion: self.manifest.toolsVersion,
            fs: self.fileSystem,
            diags: self.diagnostics
        )
        let (sources, resources, headers, others) = try sourcesBuilder.run()

        // Make sure defaultLocalization is set if the target has localized resources.
        let hasLocalizedResources = resources.contains(where: { $0.localization != nil })
        if hasLocalizedResources && manifest.defaultLocalization == nil {
            throw ModuleError.defaultLocalizationNotSet
        }

        // The name of the bundle, if one is being generated.
        let bundleName = resources.isEmpty ? nil : self.manifest.name + "_" + potentialModule.name

        if sources.relativePaths.isEmpty && resources.isEmpty {
            return nil
        }
        try validateSourcesOverlapping(forTarget: potentialModule.name, sources: sources.paths)
        
        // Deal with package plugin targets.
        if potentialModule.type == .plugin {
            guard allowPluginTargets else {
                throw ModuleError.pluginTargetRequiresFeatureFlag(target: manifestTarget.name)
            }
            guard let declaredCapability = manifestTarget.pluginCapability else {
                throw ModuleError.pluginCapabilityNotDeclared(target: manifestTarget.name)
            }
            
            // Translate the capability from the target description form coming in from the manifest
            // to the package model form.
            let capability: PluginCapability
            switch declaredCapability {
            case .buildTool:
                capability = .buildTool
            }
            
            // Crate and return an PluginTarget configured with the information from the manifest.
            return PluginTarget(
                name: potentialModule.name,
                platforms: self.platforms(),  // FIXME: this should be host platform
                sources: sources,
                pluginCapability: capability,
                dependencies: dependencies)
        }
        
        /// Determine the target's type, or leave nil to check the source directory.
        let targetType: Target.Kind
        switch potentialModule.type {
        case .test:
            targetType = .test
        case .executable:
            targetType = .executable
        default:
            targetType = sources.computeTargetType()
            if targetType == .executable && manifest.toolsVersion >= .v5_4 && warnAboutImplicitExecutableTargets {
                diagnostics.emit(warning: "'\(potentialModule.name)' was identified as an executable target given the presence of a 'main.swift' file. Starting with tools version \(ToolsVersion.v5_4) executable targets should be declared as 'executableTarget()'")
            }
        }
        
        // Create and return the right kind of target depending on what kind of sources we found.
        if sources.hasSwiftSources {
            return SwiftTarget(
                name: potentialModule.name,
                bundleName: bundleName,
                defaultLocalization: manifest.defaultLocalization,
                platforms: self.platforms(isTest: potentialModule.isTest),
                type: targetType,
                sources: sources,
                resources: resources,
                others: others,
                dependencies: dependencies,
                swiftVersion: try swiftVersion(),
                buildSettings: buildSettings
            )
        } else {
            // It's not a Swift target, so it's a Clang target (those are the only two types of source target currently supported).
            
            // First determine the type of module map that will be appropriate for the target based on its header layout.
            let moduleMapType: ModuleMapType
            
            if fileSystem.exists(publicHeadersPath) {
                let moduleMapGenerator = ModuleMapGenerator(targetName: potentialModule.name, moduleName: potentialModule.name.spm_mangledToC99ExtendedIdentifier(), publicHeadersDir: publicHeadersPath, fileSystem: fileSystem)
                moduleMapType = moduleMapGenerator.determineModuleMapType(diagnostics: diagnostics)
            } else if targetType == .library, manifest.toolsVersion >= .v5_5 {
                // If this clang target is a library, it must contain "include" directory.
                throw ModuleError.invalidPublicHeadersDirectory(potentialModule.name)
            } else {
                moduleMapType = .none
            }

            return ClangTarget(
                name: potentialModule.name,
                bundleName: bundleName,
                defaultLocalization: manifest.defaultLocalization,
                platforms: self.platforms(isTest: potentialModule.isTest),
                cLanguageStandard: manifest.cLanguageStandard,
                cxxLanguageStandard: manifest.cxxLanguageStandard,
                includeDir: publicHeadersPath,
                moduleMapType: moduleMapType,
                headers: headers,
                type: targetType,
                sources: sources,
                resources: resources,
                dependencies: dependencies,
                buildSettings: buildSettings
            )
        }
    }

    /// Creates build setting assignment table for the given target.
    func buildSettings(for target: TargetDescription?, targetRoot: AbsolutePath) throws -> BuildSettings.AssignmentTable {
        var table = BuildSettings.AssignmentTable()
        guard let target = target else { return table }

        // Process each setting.
        for setting in target.settings {
            let decl: BuildSettings.Declaration

            // Compute appropriate declaration for the setting.
            switch setting.name {
            case .headerSearchPath:

                switch setting.tool {
                case .c, .cxx:
                    decl = .HEADER_SEARCH_PATHS
                case .swift, .linker:
                    throw InternalError("unexpected tool for setting type \(setting)")
                }

                // Ensure that the search path is contained within the package.
                let subpath = try RelativePath(validating: setting.value[0])
                guard targetRoot.appending(subpath).contains(packagePath) else {
                    throw ModuleError.invalidHeaderSearchPath(subpath.pathString)
                }

            case .define:
                switch setting.tool {
                case .c, .cxx:
                    decl = .GCC_PREPROCESSOR_DEFINITIONS
                case .swift:
                    decl = .SWIFT_ACTIVE_COMPILATION_CONDITIONS
                case .linker:
                    throw InternalError("unexpected tool for setting type \(setting)")
                }

            case .linkedLibrary:
                switch setting.tool {
                case .c, .cxx, .swift:
                    throw InternalError("unexpected tool for setting type \(setting)")
                case .linker:
                    decl = .LINK_LIBRARIES
                }

            case .linkedFramework:
                switch setting.tool {
                case .c, .cxx, .swift:
                    throw InternalError("unexpected tool for setting type \(setting)")
                case .linker:
                    decl = .LINK_FRAMEWORKS
                }

            case .unsafeFlags:
                switch setting.tool {
                case .c:
                    decl = .OTHER_CFLAGS
                case .cxx:
                    decl = .OTHER_CPLUSPLUSFLAGS
                case .swift:
                    decl = .OTHER_SWIFT_FLAGS
                case .linker:
                    decl = .OTHER_LDFLAGS
                }
            }

            // Create an assignment for this setting.
            var assignment = BuildSettings.Assignment()
            assignment.value = setting.value
            assignment.conditions = buildConditions(from: setting.condition)

            // Finally, add the assignment to the assignment table.
            table.add(assignment, for: decl)
        }

        return table
    }

    func buildConditions(from condition: PackageConditionDescription?) -> [PackageConditionProtocol] {
        var conditions: [PackageConditionProtocol] = []

        if let config = condition?.config.flatMap({ BuildConfiguration(rawValue: $0) }) {
            let condition = ConfigurationCondition(configuration: config)
            conditions.append(condition)
        }

        if let platforms = condition?.platformNames.compactMap({ platformRegistry.platformByName[$0] }), !platforms.isEmpty {
            let condition = PlatformsCondition(platforms: platforms)
            conditions.append(condition)
        }

        return conditions
    }

    /// Returns the list of platforms supported by the manifest.
    func platforms(isTest: Bool = false) -> [SupportedPlatform] {
        if let platforms = _platforms[isTest] {
            return platforms
        }

        var supportedPlatforms: [SupportedPlatform] = []

        /// Add each declared platform to the supported platforms list.
        for platform in manifest.platforms {
            let declaredPlatform = platformRegistry.platformByName[platform.platformName]!
            var version = PlatformVersion(platform.version)

            if let xcTestMinimumDeploymentTarget = xcTestMinimumDeploymentTargets[declaredPlatform], isTest, version < xcTestMinimumDeploymentTarget {
                version = xcTestMinimumDeploymentTarget
            }

            let supportedPlatform = SupportedPlatform(
                platform: declaredPlatform,
                version: version,
                options: platform.options
            )

            supportedPlatforms.append(supportedPlatform)
        }

        // Find the undeclared platforms.
        let remainingPlatforms = Set(platformRegistry.platformByName.keys).subtracting(supportedPlatforms.map({ $0.platform.name }))

        /// Start synthesizing for each undeclared platform.
        for platformName in remainingPlatforms.sorted() {
            let platform = platformRegistry.platformByName[platformName]!

            let oldestSupportedVersion: PlatformVersion
            if let xcTestMinimumDeploymentTarget = xcTestMinimumDeploymentTargets[platform], isTest {
                oldestSupportedVersion = xcTestMinimumDeploymentTarget
            } else if platform == .macCatalyst, let iOS = supportedPlatforms.first(where: { $0.platform == .iOS }) {
                // If there was no deployment target specified for Mac Catalyst, fall back to the iOS deployment target.
                oldestSupportedVersion = max(platform.oldestSupportedVersion, iOS.version)
            } else {
                oldestSupportedVersion = platform.oldestSupportedVersion
            }

            let supportedPlatform = SupportedPlatform(
                platform: platform,
                version: oldestSupportedVersion,
                options: []
            )

            supportedPlatforms.append(supportedPlatform)
        }

        _platforms[isTest] = supportedPlatforms
        return supportedPlatforms
    }
    // Keep two sets of supported platforms, based on the `isTest` parameter.
    private var _platforms = [Bool:[SupportedPlatform]]()

    /// The platform registry instance.
    private var platformRegistry: PlatformRegistry {
        return PlatformRegistry.default
    }

    /// Computes the swift version to use for this manifest.
    private func swiftVersion() throws -> SwiftLanguageVersion {
        if let swiftVersion = _swiftVersion {
            return swiftVersion
        }

        let computedSwiftVersion: SwiftLanguageVersion

        // Figure out the swift version from declared list in the manifest.
        if let swiftLanguageVersions = manifest.swiftLanguageVersions {
            guard let swiftVersion = swiftLanguageVersions.sorted(by: >).first(where: { $0 <= ToolsVersion.currentToolsVersion }) else {
                throw ModuleError.incompatibleToolsVersions(
                    package: manifest.name, required: swiftLanguageVersions, current: .currentToolsVersion)
            }
            computedSwiftVersion = swiftVersion
        } else {
            // Otherwise, use the version depending on the manifest version.
            computedSwiftVersion = manifest.toolsVersion.swiftLanguageVersion
        }
        _swiftVersion = computedSwiftVersion
        return computedSwiftVersion
    }
    private var _swiftVersion: SwiftLanguageVersion? = nil

    /// The set of the sources computed so far.
    private var allSources = Set<AbsolutePath>()

    /// Validates that the sources of a target are not already present in another target.
    private func validateSourcesOverlapping(forTarget target: String, sources: [AbsolutePath]) throws {
        // Compute the sources which overlap with already computed targets.
        var overlappingSources: Set<AbsolutePath> = []
        for source in sources {
            if !allSources.insert(source).inserted {
                overlappingSources.insert(source)
            }
        }

        // Throw if we found any overlapping sources.
        if !overlappingSources.isEmpty {
            throw ModuleError.overlappingSources(target: target, sources: Array(overlappingSources))
        }
    }

    /// Find the test manifest file for the package.
    private func findTestManifest(in testTargets: [Target]) throws -> AbsolutePath? {
        var testManifestFiles = Set<AbsolutePath>()
        var pathsSearched = Set<AbsolutePath>()

        // Look for linux main file adjacent to each test target root, iterating upto package root.
        for target in testTargets {

            // Form the initial search path.
            //
            // If the target root's parent directory is inside the package, start
            // search there. Otherwise, we start search from the target root.
            var searchPath = target.sources.root.parentDirectory
            if !searchPath.contains(packagePath) {
                searchPath = target.sources.root
            }

            while true {
                assert(searchPath.contains(packagePath), "search path \(searchPath) is outside the package \(packagePath)")
                // If we have already searched this path, skip.
                if !pathsSearched.contains(searchPath) {
                    SwiftTarget.testManifestNames.forEach { name in
                        let path = searchPath.appending(component: name)
                        if fileSystem.isFile(path) {
                            testManifestFiles.insert(path)
                        }
                    }
                    pathsSearched.insert(searchPath)
                }
                // Break if we reached all the way to package root.
                if searchPath == packagePath { break }
                // Go one level up.
                searchPath = searchPath.parentDirectory
            }
        }

        // It is an error if there are multiple linux main files.
        if testManifestFiles.count > 1 {
            throw ModuleError.multipleTestManifestFilesFound(
                package: self.manifest.name, files: testManifestFiles.map({ $0 }))
        }
        return testManifestFiles.first
    }

    /// Collects the products defined by a package.
    private func constructProducts(_ targets: [Target]) throws -> [Product] {
        var products = Basics.OrderedSet<KeyedPair<Product, String>>()

        /// Helper method to append to products array.
        func append(_ product: Product) {
            let inserted = products.append(KeyedPair(product, key: product.name)).inserted
            if !inserted {
                diagnostics.emit(
                    .duplicateProduct(product: product),
                    location: self.diagnosticLocation
                )
            }
        }

        // Collect all test targets.
        let testModules = targets.filter({ target in
            guard target.type == .test else { return false }
          #if os(Linux)
            // FIXME: Ignore C language test targets on linux for now.
            if target is ClangTarget {
                diagnostics.emit(.unsupportedCTestTarget(
                    package: manifest.name, target: target.name))
                return false
            }
          #endif
            return true
        })

        // If enabled, create one test product for each test target.
        if self.shouldCreateMultipleTestProducts {
            for testTarget in testModules {
                let product = Product(name: testTarget.name, type: .test, targets: [testTarget])
                append(product)
            }
        } else if !testModules.isEmpty {
            // Otherwise we only need to create one test product for all of the
            // test targets.
            //
            // Add suffix 'PackageTests' to test product name so the target name
            // of linux executable don't collide with main package, if present.
            let productName = self.manifest.name + "PackageTests"
            let testManifest = try self.findTestManifest(in: testModules)

            let product = Product(name: productName, type: .test, targets: testModules, testManifest: testManifest)
            append(product)
        }

        // Map containing targets mapped to their names.
        let modulesMap = Dictionary(targets.map{ ($0.name, $0) }, uniquingKeysWith: { $1 })

        /// Helper method to get targets from target names.
        func modulesFrom(targetNames names: [String], product: String) throws -> [Target] {
            // Get targets from target names.
            return try names.map({ targetName in
                // Ensure we have this target.
                guard let target = modulesMap[targetName] else {
                    throw Product.Error.moduleEmpty(product: product, target: targetName)
                }
                return target
            })
        }

        // First add explicit products.

        let filteredProducts: [ProductDescription]
        switch productFilter {
        case .everything:
            filteredProducts = self.manifest.products
        case .specific(let set):
            filteredProducts = self.manifest.products.filter { set.contains($0.name) }
        }
        for product in filteredProducts {
            let targets = try modulesFrom(targetNames: product.targets, product: product.name)
            // Perform special validations if this product is exporting
            // a system library target.
            if targets.contains(where: { $0 is SystemLibraryTarget }) {
                if product.type != .library(.automatic) || targets.count != 1 {
                    self.diagnostics.emit(
                        .systemPackageProductValidation(product: product.name),
                        location: self.diagnosticLocation
                    )
                    continue
                }
            }

            // Do some validation for executable products.
            switch product.type {
            case .library, .test:
                break
            case .executable:
                guard self.validateExecutableProduct(product, with: targets) else {
                    continue
                }
            case .plugin:
                guard self.validatePluginProduct(product, with: targets) else {
                    continue
                }
            }

            append(Product(name: product.name, type: product.type, targets: targets))
        }

        // Add implicit executables - for root packages only.

        if self.manifest.packageKind == .root {
            // Compute the list of targets which are being used in an
            // executable product so we don't create implicit executables
            // for them.
            let explicitProductsTargets = Set(self.manifest.products.flatMap{ product -> [String] in
                switch product.type {
                case .library, .plugin, .test:
                    return []
                case .executable:
                    return product.targets
                }
            })

            let productMap = products.reduce(into: [String: Product]()) { partial, iterator in
                partial[iterator.key] = iterator.item
            }

            for target in targets where target.type == .executable {
                if explicitProductsTargets.contains(target.name) {
                    // If there is already an executable target with this name, skip generating a product for it
                    continue
                } else if let product = productMap[target.name] {
                    // If there is already a product with this name skip generating a product for it,
                    // but warn if that product is not executable
                    if product.type != .executable {
                        self.diagnostics.emit(.warning("The target named '\(target.name)' was identified as an executable target but a non-executable product with this name already exists."))
                    }
                    continue
                } else {
                    // Generate an implicit product for the executable target
                    let product = Product(name: target.name, type: .executable, targets: [target])
                    append(product)
                }
            }
        }

        // Create a special REPL product that contains all the library targets.

        if self.createREPLProduct {
            let libraryTargets = targets.filter{ $0.type == .library }
            if libraryTargets.isEmpty {
                self.diagnostics.emit(
                    .noLibraryTargetsForREPL,
                    location: self.diagnosticLocation
                )
            } else {
                let replProduct = Product(
                    name: self.manifest.name + Product.replProductSuffix,
                    type: .library(.dynamic),
                    targets: libraryTargets
                )
                append(replProduct)
            }
        }

        return products.map{ $0.item }
    }

    private func validateExecutableProduct(_ product: ProductDescription, with targets: [Target]) -> Bool {
        let executableTargetCount = targets.filter { $0.type == .executable }.count
        guard executableTargetCount == 1 else {
            if executableTargetCount == 0 {
                if let target = targets.spm_only {
                    diagnostics.emit(
                        .executableProductTargetNotExecutable(product: product.name, target: target.name),
                        location: self.diagnosticLocation
                    )
                } else {
                    diagnostics.emit(
                        .executableProductWithoutExecutableTarget(product: product.name),
                        location: self.diagnosticLocation
                    )
                }
            } else {
                diagnostics.emit(
                    .executableProductWithMoreThanOneExecutableTarget(product: product.name),
                    location: self.diagnosticLocation
                )
            }

            return false
        }

        return true
    }

    private func validatePluginProduct(_ product: ProductDescription, with targets: [Target]) -> Bool {
        let nonPluginTargets = targets.filter{ $0.type != .plugin }
        guard nonPluginTargets.isEmpty else {
            diagnostics.emit(
                .pluginProductWithNonPluginTargets(product: product.name, otherTargets: nonPluginTargets.map{ $0.name }),
                location: self.diagnosticLocation
            )
            return false
        }
        guard !targets.isEmpty else {
            diagnostics.emit(
                .pluginProductWithNoTargets(product: product.name),
                location: self.diagnosticLocation
            )
            return false
        }
        return true
    }
}

/// We create this structure after scanning the filesystem for potential targets.
private struct PotentialModule: Hashable {

    /// Name of the target.
    let name: String

    /// The path of the target.
    let path: AbsolutePath

    /// If this should be a test target.
    var isTest: Bool {
        return type == .test
    }

    /// The target type.
    let type: TargetDescription.TargetType

    /// The base prefix for the test target, used to associate with the target it tests.
    public var basename: String {
        guard isTest else {
            fatalError("\(Swift.type(of: self)) should be a test target to access basename.")
        }
        precondition(name.hasSuffix(Target.testModuleNameSuffix))
        let endIndex = name.index(name.endIndex, offsetBy: -Target.testModuleNameSuffix.count)
        return String(name[name.startIndex..<endIndex])
    }
}

private extension Manifest {
    /// Returns the names of all the visible targets in the manifest.
    func visibleModuleNames(for productFilter: ProductFilter) -> Set<String> {
        let names = targetsRequired(for: productFilter).flatMap({ target in
            [target.name] + target.dependencies.compactMap({
                switch $0 {
                case .target(let name, _):
                    return name
                case .byName, .product:
                    return nil
                }
            })
        })
        return Set(names)
    }
}

extension Sources {
    var hasSwiftSources: Bool {
        return paths.contains { path in
            guard let ext = path.extension else { return false }

            return FileRuleDescription.swift.fileTypes.contains(ext)
        }
    }

    var hasClangSources: Bool {
        let supportedClangFileExtensions = FileRuleDescription.clang.fileTypes.union(FileRuleDescription.asm.fileTypes)

        return paths.contains { path in
            guard let ext = path.extension else { return false }

            return supportedClangFileExtensions.contains(ext)
        }
    }

    var containsMixedLanguage: Bool {
        return hasSwiftSources && hasClangSources
    }
    
    /// Determine target type based on the sources.
    fileprivate func computeTargetType() -> Target.Kind {
        let isLibrary = !relativePaths.contains { path in
            let file = path.basename.lowercased()
            // Look for a main.xxx file avoiding cases like main.xxx.xxx
            return file.hasPrefix("main.") && String(file.filter({$0 == "."})).count == 1
        }
        return isLibrary ? .library : .executable
    }
}
