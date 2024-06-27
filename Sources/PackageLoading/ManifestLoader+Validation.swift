//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation
import PackageModel

public struct ManifestValidator {
    static var supportedLocalBinaryDependencyExtensions: [String] {
        ["zip"] + BinaryModule.Kind.allCases.filter{ $0 != .unknown }.map { $0.fileExtension }
    }
    static var supportedRemoteBinaryDependencyExtensions: [String] {
        ["zip", "artifactbundleindex"]
    }

    private let manifest: Manifest
    private let sourceControlValidator: ManifestSourceControlValidator
    private let fileSystem: FileSystem

    public init(manifest: Manifest, sourceControlValidator: ManifestSourceControlValidator, fileSystem: FileSystem) {
        self.manifest = manifest
        self.sourceControlValidator = sourceControlValidator
        self.fileSystem = fileSystem
    }

    /// Validate the provided manifest.
    public func validate() -> [Basics.Diagnostic] {
        var diagnostics = [Basics.Diagnostic]()

        diagnostics += self.validateTargets()
        diagnostics += self.validateProducts()
        diagnostics += self.validateDependencies()
        diagnostics += self.validateTraits()

        // Checks reserved for tools version 5.2 features
        if self.manifest.toolsVersion >= .v5_2 {
            diagnostics += self.validateTargetDependencyReferences()
            diagnostics += self.validateBinaryTargets()
        }

        return diagnostics
    }

    private func validateTargets() -> [Basics.Diagnostic] {
        var diagnostics = [Basics.Diagnostic]()

        let duplicateTargetNames = self.manifest.targets.map({ $0.name }).spm_findDuplicates()
        for name in duplicateTargetNames {
            diagnostics.append(.duplicateTargetName(targetName: name))
        }

        return diagnostics
    }

    private func validateProducts()  -> [Basics.Diagnostic] {
        var diagnostics = [Basics.Diagnostic]()
        
        for product in self.manifest.products {
            // Check that the product contains targets.
            guard !product.targets.isEmpty else {
                diagnostics.append(.emptyProductTargets(productName: product.name))
                continue
            }

            // Check that the product references existing targets.
            for target in product.targets {
                if !self.manifest.targetMap.keys.contains(target) {
                    diagnostics.append(.productTargetNotFound(productName: product.name, targetName: target, validTargets: self.manifest.targetMap.keys.sorted()))
                }
            }

            // Check that products that reference only binary targets don't define an explicit library type.
            if product.targets.allSatisfy({ self.manifest.targetMap[$0]?.type == .binary }) {
                switch product.type {
                case .library(.automatic), .executable:
                    break
                default:
                    diagnostics.append(.invalidBinaryProductType(productName: product.name))
                }
            }
        }

        return diagnostics
    }

    private func validateTraits() -> [Basics.Diagnostic] {
        var diagnostics = [Basics.Diagnostic]()

        if self.manifest.traits.count > 300 {
            // We limit the number of traits to 300 for now
            diagnostics.append(.tooManyTraits())
        }

        for trait in self.manifest.traits {
            let traitName = trait.name
            guard traitName.count > 0 else {
                diagnostics.append(.emptyTraitName())
                continue
            }

            for (index, unicodeScalar) in traitName.unicodeScalars.enumerated() {
                let properties = unicodeScalar.properties

                if index == 0 {
                    if !(properties.isIDStart || properties.isASCIIHexDigit || unicodeScalar == "_") {
                        diagnostics.append(.invalidFirstCharacterInTrait(firstCharater: unicodeScalar, trait: trait.name))
                    }
                } else {
                    if !(properties.isXIDContinue || unicodeScalar == "_" || unicodeScalar == "+") {
                        diagnostics.append(.invalidCharacterInTrait(character: unicodeScalar, trait: trait.name))
                    }
                }
            }
        }

        let traitKeys = Set(self.manifest.traits.map { $0.name })

        for trait in self.manifest.traits {
            for otherTrait in trait.enabledTraits {
                if !traitKeys.contains(otherTrait) {
                    // The trait is not contained in the other trait.
                    // This means they reference a trait that this package doesn't define.
                    diagnostics.append(.invalidEnabledTrait(trait: otherTrait, enabledBy: trait.name))
                }
            }
        }

        return diagnostics
    }

    private func validateDependencies() -> [Basics.Diagnostic] {
        var diagnostics = [Basics.Diagnostic]()

        // validate dependency requirements
        for dependency in self.manifest.dependencies {
            switch dependency {
            case .sourceControl(let sourceControl):
                diagnostics += validateSourceControlDependency(sourceControl)
            default:
                break
            }
        }

        return diagnostics
    }

    private func validateBinaryTargets() -> [Basics.Diagnostic] {
        var diagnostics = [Basics.Diagnostic]()

        // Check that binary targets point to the right file type.
        for target in self.manifest.targets where target.type == .binary {
            if target.isLocal {
                guard let path = target.path else {
                    diagnostics.append(.invalidBinaryLocation(targetName: target.name))
                    continue
                }

                guard let path = path.spm_chuzzle(), !path.isEmpty else {
                    diagnostics.append(.invalidLocalBinaryPath(path: path, targetName: target.name))
                    continue
                }

                guard let relativePath = try? RelativePath(validating: path) else {
                    diagnostics.append(.invalidLocalBinaryPath(path: path, targetName: target.name))
                    continue
                }

                let validExtensions = Self.supportedLocalBinaryDependencyExtensions
                guard let fileExtension = relativePath.extension, validExtensions.contains(fileExtension) else {
                    diagnostics.append(.unsupportedBinaryLocationExtension(
                        targetName: target.name,
                        validExtensions: validExtensions
                    ))
                    continue
                }
            } else if target.isRemote {
                guard let url = target.url else {
                    diagnostics.append(.invalidBinaryLocation(targetName: target.name))
                    continue
                }

                guard let url = url.spm_chuzzle(), !url.isEmpty else {
                    diagnostics.append(.invalidBinaryURL(url: url, targetName: target.name))
                    continue
                }

                guard let url = URL(string: url) else {
                    diagnostics.append(.invalidBinaryURL(url: url, targetName: target.name))
                    continue
                }

                let validSchemes = ["https"]
                guard url.scheme.map({ validSchemes.contains($0) }) ?? false else {
                    diagnostics.append(.invalidBinaryURLScheme(
                        targetName: target.name,
                        validSchemes: validSchemes
                    ))
                    continue
                }

                guard Self.supportedRemoteBinaryDependencyExtensions.contains(url.pathExtension) else {
                    diagnostics.append(.unsupportedBinaryLocationExtension(
                        targetName: target.name,
                        validExtensions: Self.supportedRemoteBinaryDependencyExtensions
                    ))
                    continue
                }

            } else {
                diagnostics.append(.invalidBinaryLocation(targetName: target.name))
                continue
            }
        }

        return diagnostics
    }

    /// Validates that product target dependencies reference an existing package.
    private func validateTargetDependencyReferences() -> [Basics.Diagnostic] {
        var diagnostics = [Basics.Diagnostic]()

        for target in self.manifest.targets {
            for targetDependency in target.dependencies {
                switch targetDependency {
                case .target:
                    // If this is a target dependency, we don't need to check anything.
                    break
                case .product(_, let packageName, _, _):
                    if self.manifest.packageDependency(referencedBy: targetDependency) == nil {
                        diagnostics.append(.unknownTargetPackageDependency(
                            packageName: packageName,
                            targetName: target.name,
                            validPackages: self.manifest.dependencies
                        ))
                    }
                case .byName(let name, _):
                    // Don't diagnose root manifests so we can emit a better diagnostic during package loading.
                    if !self.manifest.packageKind.isRoot &&
                        !self.manifest.targetMap.keys.contains(name) &&
                        self.manifest.packageDependency(referencedBy: targetDependency) == nil
                    {
                        diagnostics.append(.unknownTargetDependency(
                            dependency: name,
                            targetName: target.name,
                            validDependencies: self.manifest.dependencies
                        ))
                    }
                }
            }
        }

        return diagnostics
    }

    func validateSourceControlDependency(_ dependency: PackageDependency.SourceControl) -> [Basics.Diagnostic] {
        var diagnostics = [Basics.Diagnostic]()
        // if a location is on file system, validate it is in fact a git repo
        // there is a case to be made to throw early (here) if the path does not exists
        // but many of our tests assume they can pass a non existent path
        if case .local(let localPath) = dependency.location, self.fileSystem.exists(localPath) {
            do {
                if try !self.sourceControlValidator.isValidDirectory(localPath) {
                    // Provides better feedback when mistakenly using url: for a dependency that
                    // is a local package. Still allows for using url with a local package that has
                    // also been initialized by git
                    diagnostics.append(.invalidSourceControlDirectory(localPath))
                }
            } catch {
                diagnostics.append(.invalidSourceControlDirectory(localPath, underlyingError: error))
            }
        }
        return diagnostics
    }
}

public protocol ManifestSourceControlValidator {
    func isValidDirectory(_ path: AbsolutePath) throws -> Bool
}

extension Basics.Diagnostic {
    static func duplicateTargetName(targetName: String) -> Self {
        .error("duplicate target named '\(targetName)'")
    }

    static func emptyProductTargets(productName: String) -> Self {
        .error("product '\(productName)' doesn't reference any targets")
    }

    static func productTargetNotFound(productName: String, targetName: String, validTargets: [String]) -> Self {
        .error("target '\(targetName)' referenced in product '\(productName)' could not be found; valid targets are: '\(validTargets.joined(separator: "', '"))'")
    }

    static func invalidBinaryProductType(productName: String) -> Self {
        .error("invalid type for binary product '\(productName)'; products referencing only binary targets must be executable or automatic library products")
    }

    static func unknownTargetDependency(dependency: String, targetName: String, validDependencies: [PackageDependency]) -> Self {

        .error("unknown dependency '\(dependency)' in target '\(targetName)'; valid dependencies are: \(validDependencies.map{ "\($0.descriptionForValidation)" }.joined(separator: ", "))")
    }

    static func unknownTargetPackageDependency(packageName: String?, targetName: String, validPackages: [PackageDependency]) -> Self {
        let messagePrefix: String
        if let packageName {
            messagePrefix = "unknown package '\(packageName)'"
        } else {
            messagePrefix = "undeclared package"
        }
        return .error("\(messagePrefix) in dependencies of target '\(targetName)'; valid packages are: \(validPackages.map{ "\($0.descriptionForValidation)" }.joined(separator: ", "))")
    }

    static func invalidBinaryLocation(targetName: String) -> Self {
        .error("invalid location for binary target '\(targetName)'")
    }

    static func invalidBinaryURL(url: String, targetName: String) -> Self {
        .error("invalid URL '\(url)' for binary target '\(targetName)'")
    }

    static func invalidLocalBinaryPath(path: String, targetName: String) -> Self {
        .error("invalid local path '\(path)' for binary target '\(targetName)', path expected to be relative to package root.")
    }

    static func invalidBinaryURLScheme(targetName: String, validSchemes: [String]) -> Self {
        .error("invalid URL scheme for binary target '\(targetName)'; valid schemes are: '\(validSchemes.joined(separator: "', '"))'")
    }

    static func unsupportedBinaryLocationExtension(targetName: String, validExtensions: [String]) -> Self {
        .error("unsupported extension for binary target '\(targetName)'; valid extensions are: '\(validExtensions.joined(separator: "', '"))'")
    }

    static func invalidLanguageTag(_ languageTag: String) -> Self {
        .error("""
            invalid language tag '\(languageTag)'; the pattern for language tags is groups of latin characters and \
            digits separated by hyphens
            """)
    }

    static func errorSuffix(_ error: Error?) -> String {
        if let error {
            return ": \(error.interpolationDescription)"
        } else {
            return ""
        }
    }

    static func invalidSourceControlDirectory(_ path: AbsolutePath, underlyingError: Error? = nil) -> Self {
        .error("cannot clone from local directory \(path)\nPlease git init or use \"path:\" for \(path)\(errorSuffix(underlyingError))")
    }

    static func tooManyTraits() -> Self {
        .error("A package can define a maximum of 300 traits")
    }

    static func emptyTraitName() -> Self {
        .error("Empty strings are not allowed as trait names")
    }

    static func invalidFirstCharacterInTrait(firstCharater: UnicodeScalar, trait: String) -> Self {
        .error("Invalid first character (\(firstCharater)) in trait \(trait). The first character must be a Unicode XID start character (most letters), a digit, or _.")
    }

    static func invalidCharacterInTrait(character: UnicodeScalar, trait: String) -> Self {
        .error("Invalid character \(character) in trait \(trait). Characters must be a Unicode XID continue character (a digit, _, or most letters), -, or +")
    }

    static func invalidEnabledTrait(trait: String, enabledBy enablerTrait: String) -> Self {
        .error("Trait \(enablerTrait) enables \(trait) which is not defined in the package")
    }

    static func invalidDefaultTrait(defaultTrait: String) -> Self {
        .error("Default trait \(defaultTrait) is not defined in the package")
    }
}

extension TargetDescription {
    fileprivate var isRemote: Bool { url != nil }
    fileprivate var isLocal: Bool { path != nil }
}

extension PackageDependency {
    fileprivate var descriptionForValidation: String {
        var description = "'\(self.nameForModuleDependencyResolutionOnly)'"

        if let locationsString = {
            switch self {
            case .fileSystem(let settings):
                return "at '\(settings.path.pathString)'"
            case .sourceControl(let settings):
                switch settings.location {
                case .local(let path):
                    return "at '\(path.pathString)'"
                case .remote(let url):
                    return "from '\(url.absoluteString)'"
                }
            case .registry:
                return .none
            }
        }() {
            description += " (\(locationsString))"
        }

        return description
    }
}
