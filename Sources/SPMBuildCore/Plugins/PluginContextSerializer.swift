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

import Basics
import Foundation
import PackageGraph
import PackageLoading
import PackageModel

typealias WireInput = HostToPluginMessage.InputContext

/// Creates the serialized input structure for the plugin script based on all
/// the input information to a plugin.
internal struct PluginContextSerializer {
    let fileSystem: FileSystem
    let modulesGraph: ModulesGraph
    let buildEnvironment: BuildEnvironment
    let pkgConfigDirectories: [AbsolutePath]
    let sdkRootPath: AbsolutePath?
    var paths: [WireInput.URL] = []
    var pathsToIds: [AbsolutePath: WireInput.URL.Id] = [:]
    var targets: [WireInput.Target] = []
    var targetsToWireIDs: [ResolvedModule.ID: WireInput.Target.Id] = [:]
    var products: [WireInput.Product] = []
    var productsToWireIDs: [ResolvedProduct.ID: WireInput.Product.Id] = [:]
    var packages: [WireInput.Package] = []
    var packagesToWireIDs: [ResolvedPackage.ID: WireInput.Package.Id] = [:]

    /// Adds a path to the serialized structure, if it isn't already there.
    /// Either way, this function returns the path's wire ID.
    mutating func serialize(path: AbsolutePath) throws -> WireInput.URL.Id {
        // If we've already seen the path, just return the wire ID we already assigned to it.
        if let id = pathsToIds[path] { return id }
        
        // Split up the path into a base path and a subpath (currently always with the last path component as the
        // subpath, but this can be optimized where there are sequences of path components with a valence of one).
        let basePathId = (path.parentDirectory.isRoot ? nil : try serialize(path: path.parentDirectory))
        let subpathString = path.basename
        
        // Finally assign the next wire ID to the path, and append a serialized Path record.
        let id = paths.count
        paths.append(.init(baseURLId: basePathId, subpath: subpathString))
        pathsToIds[path] = id
        return id
    }

    // Adds a target to the serialized structure, if it isn't already there and
    // if it is of a kind that should be passed to the plugin. If so, this func-
    // tion returns the target's wire ID. If not, it returns nil.
    mutating func serialize(target: ResolvedModule) throws -> WireInput.Target.Id? {
        // If we've already seen the target, just return the wire ID we already assigned to it.
        if let id = targetsToWireIDs[target.id] { return id }

        // Construct the FileList
        var targetFiles: [WireInput.Target.TargetInfo.File] = []
        targetFiles.append(contentsOf: try target.underlying.sources.paths.map {
            .init(basePathId: try serialize(path: $0.parentDirectory), name: $0.basename, type: .source)
        })
        targetFiles.append(contentsOf: try target.underlying.resources.map {
            .init(basePathId: try serialize(path: $0.path.parentDirectory), name: $0.path.basename, type: .resource)
        })
        targetFiles.append(contentsOf: try target.underlying.ignored.map {
            .init(basePathId: try serialize(path: $0.parentDirectory), name: $0.basename, type: .unknown)
        })
        targetFiles.append(contentsOf: try target.underlying.others.map {
            .init(basePathId: try serialize(path: $0.parentDirectory), name: $0.basename, type: .unknown)
        })
        
        // Create a scope for evaluating build settings.
        let scope = BuildSettings.Scope(target.underlying.buildSettings, environment: buildEnvironment)
        
        // Look at the target and decide what to serialize. At this point we may decide to not serialize it at all.
        let targetInfo: WireInput.Target.TargetInfo
        switch target.underlying {
        case let target as SwiftModule:
            targetInfo = .swiftSourceModuleInfo(
                moduleName: target.c99name,
                kind: try .init(target.type),
                sourceFiles: targetFiles,
                compilationConditions: scope.evaluate(.SWIFT_ACTIVE_COMPILATION_CONDITIONS),
                linkedLibraries: scope.evaluate(.LINK_LIBRARIES),
                linkedFrameworks: scope.evaluate(.LINK_FRAMEWORKS))

        case let target as ClangModule:
            targetInfo = .clangSourceModuleInfo(
                moduleName: target.c99name,
                kind: try .init(target.type),
                sourceFiles: targetFiles,
                preprocessorDefinitions: scope.evaluate(.GCC_PREPROCESSOR_DEFINITIONS),
                headerSearchPaths: scope.evaluate(.HEADER_SEARCH_PATHS),
                publicHeadersDirId: try serialize(path: target.includeDir),
                linkedLibraries: scope.evaluate(.LINK_LIBRARIES),
                linkedFrameworks: scope.evaluate(.LINK_FRAMEWORKS))

        case let target as SystemLibraryModule:
            var cFlags: [String] = []
            var ldFlags: [String] = []
            // FIXME: What do we do with any diagnostics here?
            let observabilityScope = ObservabilitySystem({ _, _ in }).topScope
            for result in try pkgConfigArgs(
                for: target,
                pkgConfigDirectories: pkgConfigDirectories,
                sdkRootPath: sdkRootPath,
                fileSystem: fileSystem,
                observabilityScope: observabilityScope
            ) {
                if let error = result.error {
                    observabilityScope.emit(
                        warning: "\(error.interpolationDescription)",
                        metadata: .pkgConfig(pcFile: result.pkgConfigName, targetName: target.name)
                    )
                }
                else {
                    cFlags += result.cFlags
                    ldFlags += result.libs
                }
            }

            targetInfo = .systemLibraryInfo(
                pkgConfig: target.pkgConfig,
                compilerFlags: cFlags,
                linkerFlags: ldFlags)
            
        case let target as BinaryModule:
            let artifactKind: WireInput.Target.TargetInfo.BinaryArtifactKind
            switch target.kind {
            case .artifactsArchive:
                artifactKind = .artifactsArchive
            case .xcframework:
                artifactKind = .xcframework
            case .unknown:
                // Skip unknown binary targets.
                return nil
            }
            let artifactOrigin: WireInput.Target.TargetInfo.BinaryArtifactOrigin
            switch target.origin {
            case .local:
                artifactOrigin = .local
            case .remote(let url):
                artifactOrigin = .remote(url: url)
            }
            targetInfo = .binaryArtifactInfo(
                kind: artifactKind,
                origin: artifactOrigin,
                artifactId: try serialize(path: target.artifactPath))
            
        default:
            // It's not a type of target that we pass through to the plugin.
            return nil
        }
        
        // We only get this far if we are serializing the target. If so we also serialize its dependencies. This needs to be done before assigning the next wire ID for the target we're serializing, to make sure we end up with the correct one.
        let dependencies: [WireInput.Target.Dependency] = try target.dependencies(satisfying: buildEnvironment).compactMap {
            switch $0 {
            case .module(let target, _):
                return try serialize(target: target).map { .target(targetId: $0) }
            case .product(let product, _):
                return try serialize(product: product).map { .product(productId: $0) }
            }
        }

        // Finally assign the next wire ID to the target, and append a serialized Target record.
        let id = targets.count
        targets.append(.init(
            name: target.name,
            directoryId: try serialize(path: target.sources.root),
            dependencies: dependencies,
            info: targetInfo))
        targetsToWireIDs[target.id] = id
        return id
    }

    // Adds a product to the serialized structure, if it isn't already there and
    // if it is of a kind that should be passed to the plugin. If so, this func-
    // tion returns the product's wire ID. If not, it returns nil.
    mutating func serialize(product: ResolvedProduct) throws -> WireInput.Product.Id? {
        // If we've already seen the product, just return the wire ID we already assigned to it.
        if let id = productsToWireIDs[product.id] { return id }

        // Look at the product and decide what to serialize. At this point we may decide to not serialize it at all.
        let productInfo: WireInput.Product.ProductInfo
        switch product.type {
            
        case .executable:
            let mainExecTarget = try product.executableModule
            guard let mainExecTargetId = try serialize(target: mainExecTarget) else {
                throw InternalError("unable to serialize main executable target \(mainExecTarget) for product \(product)")
            }
            productInfo = .executable(mainTargetId: mainExecTargetId)

        case .library(let kind):
            switch kind {
            case .static:
                productInfo = .library(kind: .static)
            case .dynamic:
                productInfo = .library(kind: .dynamic)
            case .automatic:
                productInfo = .library(kind: .automatic)
            }

        default:
            // It's not a type of product that we pass through to the plugin.
            return nil
        }
        
        // Finally assign the next wire ID to the product, and append a serialized Product record.
        let id = products.count
        products.append(.init(
            name: product.name,
            targetIds: try product.modules.compactMap{ try serialize(target: $0) },
            info: productInfo))
        productsToWireIDs[product.id] = id
        return id
    }

    // Adds a package to the serialized structure, if it isn't already there.
    // Either way, this function returns the package's wire ID.
    mutating func serialize(package: ResolvedPackage) throws -> WireInput.Package.Id {
        // If we've already seen the package, just return the wire ID we already assigned to it.
        if let id = packagesToWireIDs[package.id] { return id }

        // Determine how we should represent the origin of the package to the plugin.
        func origin(for package: ResolvedPackage) throws -> WireInput.Package.Origin {
            switch package.manifest.packageKind {
            case .root(_):
                return .root
            case .fileSystem(let path):
                return .local(path: try serialize(path: path))
            case .localSourceControl(let path):
                return .repository(url: path.asURL.absoluteString, displayVersion: String(describing: package.manifest.version), scmRevision: String(describing: package.manifest.revision))
            case .remoteSourceControl(let url):
                return .repository(url: url.absoluteString, displayVersion: String(describing: package.manifest.version), scmRevision: String(describing: package.manifest.revision))
            case .registry(let identity):
                return .registry(identity: identity.description, displayVersion: String(describing: package.manifest.version))
            }
        }

        // Serialize the dependencies. It is important to do this before the `let id = package.count` below so the correct wire ID gets assigned.
        let dependencies = try modulesGraph.directDependencies(for: package).map {
            WireInput.Package.Dependency(packageId: try serialize(package: $0))
        }

        // Assign the next wire ID to the package, and append a serialized Package record.
        let id = packages.count
        packages.append(.init(
            identity: package.identity.description,
            displayName: package.manifest.displayName,
            directoryId: try serialize(path: package.path),
            origin: try origin(for: package),
            toolsVersion: .init(
                major: package.manifest.toolsVersion.major,
                minor: package.manifest.toolsVersion.minor,
                patch: package.manifest.toolsVersion.patch),
            dependencies: dependencies,
            productIds: try package.products.compactMap{ try serialize(product: $0) },
            targetIds: try package.modules.compactMap{ try serialize(target: $0) }))
        packagesToWireIDs[package.id] = id
        return id
    }
}

fileprivate extension WireInput.Target.TargetInfo.SourceModuleKind {
    init(_ kind: Module.Kind) throws {
        switch kind {
        case .library:
            self = .generic
        case .executable:
            self = .executable
        case .snippet:
            self = .snippet
        case .test:
            self = .test
        case .macro:
            self = .macro
        case .binary, .plugin, .systemModule, .providedLibrary:
            throw StringError("unexpected target kind \(kind) for source module")
        }
    }
}
