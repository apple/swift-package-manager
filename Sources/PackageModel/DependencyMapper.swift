//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation
import enum TSCBasic.PathValidationError
import struct TSCUtility.Version

public protocol DependencyMapper {
    func mappedDependency(_ dependency: MappablePackageDependency, fileSystem: FileSystem) throws -> PackageDependency
}

/// a utility for applying mirrors base mapping
public struct DefaultDependencyMapper: DependencyMapper {
    let identityResolver: IdentityResolver

    public init(
        identityResolver: IdentityResolver
    ) {
        self.identityResolver = identityResolver
    }

    public func mappedDependency(_ dependency: MappablePackageDependency, fileSystem: FileSystem) throws -> PackageDependency {
        // clean up variants of path based dependencies
        let dependencyLocationString = try self.normalizeDependencyLocation(
            dependency: dependency,
            parentPackagePath: dependency.parentPackagePath,
            fileSystem: fileSystem
        ) ?? dependency.locationString

        // location mapping (aka mirrors) if any
        let mappedLocationString = self.identityResolver.mappedLocation(for: dependencyLocationString)

        if mappedLocationString == dependencyLocationString {
            // no mapping done, return based on the cleaned up location string
            return try .init(dependency, newLocationString: mappedLocationString)
        } else if PackageIdentity.plain(mappedLocationString).isRegistry {
            // mapped to registry
            return .registry(
                identity: .plain(mappedLocationString),
                requirement: try dependency.registryRequirement(for: mappedLocationString),
                productFilter: dependency.productFilter,
                traits: dependency.traits
            )
        } else if parseScheme(mappedLocationString) != nil {
            // mapped to a URL, we assume a remote SCM location
            let url = SourceControlURL(mappedLocationString)
            let identity = try self.identityResolver.resolveIdentity(for: url)
            return .remoteSourceControl(
                identity: identity,
                nameForTargetDependencyResolutionOnly: dependency.nameForTargetDependencyResolutionOnly,
                url: url,
                requirement: try dependency.sourceControlRequirement(for: mappedLocationString),
                productFilter: dependency.productFilter,
                traits: dependency.traits
            )

        } else {
            // mapped to a path, we assume a local SCM location
            let localPath = try AbsolutePath(validating: mappedLocationString)
            let identity = try self.identityResolver.resolveIdentity(for: localPath)
            return .localSourceControl(
                identity: identity,
                nameForTargetDependencyResolutionOnly: dependency.nameForTargetDependencyResolutionOnly,
                path: localPath,
                requirement: try dependency.sourceControlRequirement(for: mappedLocationString),
                productFilter: dependency.productFilter,
                traits: dependency.traits
            )
        }
    }

    private static let filePrefix = "file://"

    private func normalizeDependencyLocation(
        dependency: MappablePackageDependency,
        parentPackagePath: AbsolutePath,
        fileSystem: FileSystem
    ) throws -> String? {
        switch dependency.kind {
        // nothing to normalize
        case .registry:
            return .none
        // location may be a relative path so we need to normalize it
        case .fileSystem, .sourceControl:
            let dependencyLocation = dependency.locationString
            switch parseScheme(dependencyLocation) {
            // if the location has no scheme, we treat it as a path (either absolute or relative).
            case .none:
                // if the dependency URL starts with '~/', try to expand it.
                if dependencyLocation.hasPrefix("~/") {
                    return try AbsolutePath(validating: String(dependencyLocation.dropFirst(2)), relativeTo: fileSystem.homeDirectory).pathString
                }

                // check if already absolute path
                if let path = try? AbsolutePath(validating: dependencyLocation) {
                    return path.pathString
                }

                // otherwise treat as relative path to the parent package
                return try AbsolutePath(validating: dependencyLocation, relativeTo: parentPackagePath).pathString
            // SwiftPM can't handle file locations with file:// scheme so we need to
            // strip that. We need to design a Location data structure for SwiftPM.
            case .some("file"):
                let location = String(dependencyLocation.dropFirst(Self.filePrefix.count))
                let hostnameComponent = location.prefix(while: { $0 != "/" })
                guard hostnameComponent.isEmpty else {
                  if hostnameComponent == ".." {
                      throw DependencyMappingError.invalidFileURL("file:// URLs cannot be relative, did you mean to use '.package(path:)'?")
                  }
                  throw DependencyMappingError.invalidFileURL("file:// URLs with hostnames are not supported, are you missing a '/'?")
                }
                return try AbsolutePath(validating: location).pathString
            // if the location has a scheme, assume a URL and nothing to normalize
            case .some(_):
                return .none
            }
        }
    }
}

// trivial representation for mapping
public struct MappablePackageDependency {
    public let parentPackagePath: AbsolutePath
    public let kind: Kind
    public let productFilter: ProductFilter
    package let traits: Set<PackageDependency.Trait>?

    package init(
        parentPackagePath: AbsolutePath,
        kind: Kind,
        productFilter: ProductFilter,
        traits: Set<PackageDependency.Trait>?
    ) {
        self.parentPackagePath = parentPackagePath
        self.kind = kind
        self.productFilter = productFilter
        self.traits = traits
    }

    public init(
        parentPackagePath: AbsolutePath,
        kind: Kind,
        productFilter: ProductFilter
    ) {
        self.init(
            parentPackagePath: parentPackagePath,
            kind: kind,
            productFilter: productFilter,
            traits: nil
        )
    }

    public enum Kind {
        case fileSystem(name: String?, path: String)
        case sourceControl(name: String?, location: String, requirement: PackageDependency.SourceControl.Requirement)
        case registry(id: String, requirement: PackageDependency.Registry.Requirement)
    }

    public enum Requirement {
        case exact(Version)
        case range(Range<Version>)
        case revision(String)
        case branch(String)
    }
}

extension MappablePackageDependency {
    public init(_ seed: PackageDependency, parentPackagePath: AbsolutePath) {
        switch seed {
        case .fileSystem(let settings):
            self.init(
                parentPackagePath: parentPackagePath,
                kind: .fileSystem(
                    name: settings.nameForTargetDependencyResolutionOnly,
                    path: settings.path.pathString
                ),
                productFilter: settings.productFilter,
                traits: settings.traits
            )
        case .sourceControl(let settings):
            let locationString: String
            switch settings.location {
            case .local(let path):
                locationString = path.pathString
            case .remote(let url):
                locationString = url.absoluteString
            }
            self.init(
                parentPackagePath: parentPackagePath,
                kind: .sourceControl(
                    name: settings.nameForTargetDependencyResolutionOnly,
                    location: locationString,
                    requirement: settings.requirement
                ),
                productFilter: settings.productFilter,
                traits: settings.traits
            )
        case .registry(let settings):
            self.init(
                parentPackagePath: parentPackagePath,
                kind: .registry(
                    id: settings.identity.description,
                    requirement: settings.requirement
                ),
                productFilter: settings.productFilter,
                traits: settings.traits
            )
        }
    }
}

extension MappablePackageDependency {
    fileprivate var locationString: String {
        switch self.kind {
        case .fileSystem(_, let path):
            return path
        case .sourceControl(_, let location, _):
            return location
        case .registry(let id, _):
            return id
        }
    }

    fileprivate var nameForTargetDependencyResolutionOnly: String? {
        switch self.kind {
        case .fileSystem(let name, _):
            return name
        case .sourceControl(let name, _, _):
            return name
        case .registry:
            return .none
        }
    }

    fileprivate func sourceControlRequirement(for location: String) throws -> PackageDependency.SourceControl.Requirement {
        switch self.kind {
        case .fileSystem(_, let path):
            throw DependencyMappingError.invalidMapping("mapping of file system dependency (\(path)) to source control (\(location)) is invalid")
        case .sourceControl(_, _, let requirement):
            return requirement
        case .registry(_, let requirement):
            return .init(requirement)
        }
    }

    fileprivate func registryRequirement(for identity: String) throws -> PackageDependency.Registry.Requirement {
        switch self.kind {
        case .fileSystem(_, let path):
            throw DependencyMappingError.invalidMapping("mapping of file system dependency (\(path)) to registry (\(identity)) is invalid")
        case .sourceControl(_, let location, let requirement):
            return try .init(requirement, from: location, to: identity)
        case .registry(_, let requirement):
            return requirement
        }
    }
}

fileprivate extension PackageDependency.Registry.Requirement {
    init(_ requirement: PackageDependency.SourceControl.Requirement, from location: String, to identity: String) throws {
        switch requirement {
        case .branch, .revision:
            throw DependencyMappingError.invalidMapping("mapping of source control (\(location)) to registry (\(identity)) is invalid due to requirement information mismatch: cannot map branch or revision based dependencies to registry.")
        case .exact(let value):
            self = .exact(value)
        case .range(let value):
            self = .range(value)
        }
    }
}

fileprivate extension PackageDependency.SourceControl.Requirement {
    init(_ requirement: PackageDependency.Registry.Requirement) {
        switch requirement {
        case .exact(let value):
            self = .exact(value)
        case .range(let value):
            self = .range(value)
        }
    }
}

extension PackageDependency {
    init(_ seed: MappablePackageDependency, newLocationString: String) throws {
        switch seed.kind {
        case .fileSystem(let name, _):
            let path = try AbsolutePath(validating: newLocationString)
            self = .fileSystem(
                identity: .init(path: path),
                nameForTargetDependencyResolutionOnly: name,
                path: path,
                productFilter: seed.productFilter,
                traits: seed.traits
            )
        case .sourceControl(let name, _, let requirement):
            let identity: PackageIdentity
            let location: SourceControl.Location
            if parseScheme(newLocationString) != nil {
                identity = .init(urlString: newLocationString)
                location = .remote(.init(newLocationString))
            } else {
                let path = try AbsolutePath(validating: newLocationString)
                identity = .init(path: path)
                location = .local(path)
            }
            self = .sourceControl(
                identity: identity,
                nameForTargetDependencyResolutionOnly: name,
                location: location,
                requirement: requirement,
                productFilter: seed.productFilter,
                traits: seed.traits
            )
        case .registry(let id, let requirement):
            self = .registry(
                identity: .plain(id),
                requirement: requirement,
                productFilter: seed.productFilter,
                traits: seed.traits
            )
        }
    }
}

private enum DependencyMappingError: Swift.Error, CustomStringConvertible {
    case invalidFileURL(_ message: String)
    case invalidMapping(_ message: String)

    var description: String {
        switch self {
        case .invalidFileURL(let message): return message
        case .invalidMapping(let message): return message
        }
    }
}

/// Parses the URL type of a git repository
/// e.g. https://github.com/apple/swift returns "https"
/// e.g. git@github.com:apple/swift returns "git"
///
/// This is *not* a generic URI scheme parser!
private func parseScheme(_ location: String) -> String? {
    func prefixOfSplitBy(_ delimiter: String) -> String? {
        let (head, tail) = location.spm_split(around: delimiter)
        if tail == nil {
            //not found
            return nil
        } else {
            //found, return head
            //lowercase the "scheme", as specified by the URI RFC (just in case)
            return head.lowercased()
        }
    }

    for delim in ["://", "@"] {
        if let found = prefixOfSplitBy(delim), !found.contains("/") {
            return found
        }
    }

    return nil
}
