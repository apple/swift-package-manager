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

@_implementationOnly import Foundation

typealias WireInput = HostToPluginMessage.InputContext

/// Deserializer for constructing a plugin input from the wire representation
/// received from SwiftPM, which consists of a set of flat lists of entities,
/// referenced by array index in all cross-references. The deserialized data
/// structure forms a directed acyclic graph. This information is provided to
/// the plugin in the `PluginContext` struct.
internal struct PluginContextDeserializer {
    let wireInput: WireInput
    var pathsById: [WireInput.Path.Id: Path] = [:]
    var packagesById: [WireInput.Package.Id: Package] = [:]
    var productsById: [WireInput.Product.Id: Product] = [:]
    var targetsById: [WireInput.Target.Id: Target] = [:]
    
    /// Initializes the deserializer with the given wire input.
    init(_ input: WireInput) {
        self.wireInput = input
    }
    
    /// Returns the `Path` that corresponds to the given ID (a small integer),
    /// or throws an error if the ID is invalid. The path is deserialized on-
    /// demand if it hasn't already been deserialized.
    mutating func path(for id: WireInput.Path.Id) throws -> Path {
        if let path = pathsById[id] { return path }
        guard id < wireInput.paths.count else {
            throw PluginDeserializationError.malformedInputJSON("invalid path id (\(id))")
        }
        
        // Compose a path based on an optional base path and a subpath.
        let wirePath = wireInput.paths[id]
        let basePath = try wireInput.paths[id].basePathId.map{ try self.path(for: $0) } ?? Path("/")
        let path = basePath.appending(subpath: wirePath.subpath)
        
        // Store it for the next look up.
        pathsById[id] = path
        return path
    }

    /// Returns the `Target` that corresponds to the given ID (a small integer),
    /// or throws an error if the ID is invalid. The target is deserialized on-
    /// demand if it hasn't already been deserialized.
    mutating func target(for id: WireInput.Target.Id) throws -> Target {
        if let target = targetsById[id] { return target }
        guard id < wireInput.targets.count else {
            throw PluginDeserializationError.malformedInputJSON("invalid target id (\(id))")
        }

        let wireTarget = wireInput.targets[id]
        let dependencies: [TargetDependency] = try wireTarget.dependencies.map {
            switch $0 {
            case .target(let targetId):
                let target = try self.target(for: targetId)
                return .target(target)
            case .product(let productId):
                let product = try self.product(for: productId)
                return .product(product)
            }
        }
        let directory = try self.path(for: wireTarget.directoryId)
        let target: Target
        switch wireTarget.info {
        
        case let .swiftSourceModuleInfo(moduleName, kind, sourceFiles, compilationConditions, linkedLibraries, linkedFrameworks):
            let sourceFiles = FileList(try sourceFiles.map {
                let path = try self.path(for: $0.basePathId).appending($0.name)
                let type: FileType
                switch $0.type {
                case .source:
                    type = .source
                case .header:
                    type = .header
                case .resource:
                    type = .resource
                case .unknown:
                    type = .unknown
                }
                return File(path: path, type: type)
            })
            target = SwiftSourceModuleTarget(
                id: String(id),
                name: wireTarget.name,
                kind: .init(kind),
                directory: directory,
                dependencies: dependencies,
                moduleName: moduleName,
                sourceFiles: sourceFiles,
                compilationConditions: compilationConditions,
                linkedLibraries: linkedLibraries,
                linkedFrameworks: linkedFrameworks)

        case let .clangSourceModuleInfo(moduleName, kind, sourceFiles, preprocessorDefinitions, headerSearchPaths, publicHeadersDirId, linkedLibraries, linkedFrameworks):
            let publicHeadersDir = try publicHeadersDirId.map { try self.path(for: $0) }
            let sourceFiles = FileList(try sourceFiles.map {
                let path = try self.path(for: $0.basePathId).appending($0.name)
                let type: FileType
                switch $0.type {
                case .source:
                    type = .source
                case .header:
                    type = .header
                case .resource:
                    type = .resource
                case .unknown:
                    type = .unknown
                }
                return File(path: path, type: type)
            })
            target = ClangSourceModuleTarget(
                id: String(id),
                name: wireTarget.name,
                kind: .init(kind),
                directory: directory,
                dependencies: dependencies,
                moduleName: moduleName,
                sourceFiles: sourceFiles,
                preprocessorDefinitions: preprocessorDefinitions,
                headerSearchPaths: headerSearchPaths,
                publicHeadersDirectory: publicHeadersDir,
                linkedLibraries: linkedLibraries,
                linkedFrameworks: linkedFrameworks)


        case let .mixedSourceModuleInfo(moduleName, kind, sourceFiles, compilationConditions, preprocessorDefinitions, headerSearchPaths, publicHeadersDirId, linkedLibraries, linkedFrameworks):
            let publicHeadersDir = try publicHeadersDirId.map { try self.path(for: $0) }
            let sourceFiles = FileList(try sourceFiles.map {
                let path = try self.path(for: $0.basePathId).appending($0.name)
                let type: FileType
                switch $0.type {
                case .source:
                    type = .source
                case .header:
                    type = .header
                case .resource:
                    type = .resource
                case .unknown:
                    type = .unknown
                }
                return File(path: path, type: type)
            })
            target = MixedSourceModuleTarget(
                id: String(id),
                name: wireTarget.name,
                kind: .init(kind),
                directory: directory,
                dependencies: dependencies,
                moduleName: moduleName,
                sourceFiles: sourceFiles,
                swift: .init(compilationConditions: compilationConditions),
                clang: .init(
                    preprocessorDefinitions: preprocessorDefinitions,
                    headerSearchPaths: headerSearchPaths,
                    publicHeadersDirectory: publicHeadersDir),
                linkedLibraries: linkedLibraries,
                linkedFrameworks: linkedFrameworks
            )

        case let .binaryArtifactInfo(kind, origin, artifactId):
            let artifact = try self.path(for: artifactId)
            let artifactKind: BinaryArtifactTarget.Kind
            switch kind {
            case .artifactsArchive:
                artifactKind = .artifactsArchive
            case .xcframework:
                artifactKind = .xcframework
            }
            let artifactOrigin: BinaryArtifactTarget.Origin
            switch origin {
            case .local:
                artifactOrigin = .local
            case .remote(let url):
                artifactOrigin = .remote(url: url)
            }
            target = BinaryArtifactTarget(
                id: String(id),
                name: wireTarget.name,
                directory: directory,
                dependencies: dependencies,
                kind: artifactKind,
                origin: artifactOrigin,
                artifact: artifact)

        case let .systemLibraryInfo(pkgConfig, compilerFlags, linkerFlags):
            target = SystemLibraryTarget(
                id: String(id),
                name: wireTarget.name,
                directory: directory,
                dependencies: dependencies,
                pkgConfig: pkgConfig,
                compilerFlags: compilerFlags,
                linkerFlags: linkerFlags)
        }
        
        targetsById[id] = target
        return target
    }

    /// Returns the `Product` that corresponds to the given ID (a small integer),
    /// or throws an error if the ID is invalid. The product is deserialized on-
    /// demand if it hasn't already been deserialized.
    mutating func product(for id: WireInput.Product.Id) throws -> Product {
        if let product = productsById[id] { return product }
        guard id < wireInput.products.count else {
            throw PluginDeserializationError.malformedInputJSON("invalid product id (\(id))")
        }

        let wireProduct = wireInput.products[id]
        let targets: [Target] = try wireProduct.targetIds.map{ try self.target(for: $0) }
        let product: Product
        switch wireProduct.info {

        case .executable(let mainTargetId):
            let mainTarget = try self.target(for: mainTargetId)
            product = ExecutableProduct(
                id: String(id),
                name: wireProduct.name,
                targets: targets,
                mainTarget: mainTarget)

        case .library(let type):
            let libraryKind: LibraryProduct.Kind
            switch type {
            case .static:
                libraryKind = .static
            case .dynamic:
                libraryKind = .dynamic
            case .automatic:
                libraryKind = .automatic
            }
            product = LibraryProduct(
                id: String(id),
                name: wireProduct.name,
                targets: targets,
                kind: libraryKind)
        }
        
        productsById[id] = product
        return product
    }

    /// Returns the `Package` that corresponds to the given ID (a small integer),
    /// or throws an error if the ID is invalid. The package is deserialized on-
    /// demand if it hasn't already been deserialized.
    mutating func package(for id: WireInput.Product.Id) throws -> Package {
        if let package = packagesById[id] { return package }
        guard id < wireInput.packages.count else {
            throw PluginDeserializationError.malformedInputJSON("invalid package id (\(id))") }
        
        let wirePackage = wireInput.packages[id]
        let directory = try self.path(for: wirePackage.directoryId)
        let toolsVersion = ToolsVersion(
            major: wirePackage.toolsVersion.major,
            minor: wirePackage.toolsVersion.minor,
            patch: wirePackage.toolsVersion.patch)
        let dependencies: [PackageDependency] = try wirePackage.dependencies.map {
            .init(package: try self.package(for: $0.packageId))
        }
        let products = try wirePackage.productIds.map { try self.product(for: $0) }
        let targets = try wirePackage.targetIds.map { try self.target(for: $0) }
        let package = Package(
            id: wirePackage.identity,
            displayName: wirePackage.displayName,
            directory: directory,
            origin: .root,
            toolsVersion: toolsVersion,
            dependencies: dependencies,
            products: products,
            targets: targets)
        
        packagesById[id] = package
        return package
    }
}

fileprivate extension ModuleKind {
    init(_ kind: WireInput.Target.TargetInfo.SourceModuleKind) {
        switch kind {
        case .generic:
            self = .generic
        case .executable:
            self = .executable
        case .snippet:
            self = .snippet
        case .test:
            self = .test
        case .macro:
            self = .macro
        }
    }
}
