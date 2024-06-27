//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation
@testable import PackageCollections
import PackageModel
import _InternalTestSupport
import XCTest

import struct TSCUtility.Version

class PackageIndexAndCollectionsTests: XCTestCase {
    func testCollectionAddRemoveGetList() async throws {
        try PackageCollectionsTests_skipIfUnsupportedPlatform()
        
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }
        let mockCollections = makeMockCollections()
        let packageCollections = makePackageCollections(mockCollections: mockCollections, storage: storage)

        let packageIndex = MockPackageIndex()
        let indexAndCollections = PackageIndexAndCollections(index: packageIndex, collections: packageCollections, observabilityScope: ObservabilitySystem.NOOP)
        defer { XCTAssertNoThrow(try indexAndCollections.close()) }

        do {
            let list = try await indexAndCollections.listCollections()
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        do {
            for collection in mockCollections {
                _ = try await indexAndCollections.addCollection(collection.source, order: nil)
            }
            let list = try await indexAndCollections.listCollections()
            XCTAssertEqual(list, mockCollections, "list count should match")
        }
        
        do {
            let collection = try await indexAndCollections.getCollection(mockCollections.first!.source)
            XCTAssertEqual(collection, mockCollections.first, "collection should match")
        }
        
        do {
            try await indexAndCollections.removeCollection(mockCollections.first!.source)
            let list = try await indexAndCollections.listCollections()
            XCTAssertEqual(list.count, mockCollections.count - 1, "list count should match")
        }
    }
    
    func testRefreshCollections() async throws {
        try PackageCollectionsTests_skipIfUnsupportedPlatform()

        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }
        let mockCollections = makeMockCollections()
        let packageCollections = makePackageCollections(mockCollections: mockCollections, storage: storage)

        let packageIndex = MockPackageIndex()
        let indexAndCollections = PackageIndexAndCollections(index: packageIndex, collections: packageCollections, observabilityScope: ObservabilitySystem.NOOP)
        defer { XCTAssertNoThrow(try indexAndCollections.close()) }

        for collection in mockCollections {
            // save directly to storage to circumvent refresh on add
            try await storage.sources.add(source: collection.source, order: nil)
        }
        _ = try await indexAndCollections.refreshCollections()

        let list = try await indexAndCollections.listCollections()
        XCTAssertEqual(list.count, mockCollections.count, "list count should match")
    }
    
    func testRefreshCollection() async throws {
        try PackageCollectionsTests_skipIfUnsupportedPlatform()

        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }
        let mockCollections = makeMockCollections()
        let packageCollections = makePackageCollections(mockCollections: mockCollections, storage: storage)

        let packageIndex = MockPackageIndex()
        let indexAndCollections = PackageIndexAndCollections(index: packageIndex, collections: packageCollections, observabilityScope: ObservabilitySystem.NOOP)
        defer { XCTAssertNoThrow(try indexAndCollections.close()) }

        for collection in mockCollections {
            // save directly to storage to circumvent refresh on add
            try await storage.sources.add(source: collection.source, order: nil)
        }
        _ = try await indexAndCollections.refreshCollection(mockCollections.first!.source)

        let collection = try await indexAndCollections.getCollection(mockCollections.first!.source)
        XCTAssertEqual(collection, mockCollections.first, "collection should match")
    }

    func testListPackages() async throws {
        try PackageCollectionsTests_skipIfUnsupportedPlatform()

        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        var mockCollections = makeMockCollections(count: 5)

        let mockTargets = [UUID().uuidString, UUID().uuidString].map {
            PackageCollectionsModel.Target(name: $0, moduleName: $0)
        }

        let mockProducts = [PackageCollectionsModel.Product(name: UUID().uuidString, type: .executable, targets: [mockTargets.first!]),
                            PackageCollectionsModel.Product(name: UUID().uuidString, type: .executable, targets: mockTargets)]
        let toolsVersion = ToolsVersion(string: "5.2")!
        let mockManifest = PackageCollectionsModel.Package.Version.Manifest(
            toolsVersion: toolsVersion,
            packageName: UUID().uuidString,
            targets: mockTargets,
            products: mockProducts,
            minimumPlatformVersions: nil
        )

        let mockVersion = PackageCollectionsModel.Package.Version(version: TSCUtility.Version(1, 0, 0),
                                                                  title: nil,
                                                                  summary: nil,
                                                                  manifests: [toolsVersion: mockManifest],
                                                                  defaultToolsVersion: toolsVersion,
                                                                  verifiedCompatibility: nil,
                                                                  license: nil,
                                                                  author: nil,
                                                                  signer: nil,
                                                                  createdAt: nil)

        let mockPackageURL = "https://packages.mock/\(UUID().uuidString)"
        let mockPackage = PackageCollectionsModel.Package(identity: .init(urlString: mockPackageURL),
                                                          location: mockPackageURL,
                                                          summary: UUID().uuidString,
                                                          keywords: [UUID().uuidString, UUID().uuidString],
                                                          versions: [mockVersion],
                                                          watchersCount: nil,
                                                          readmeURL: nil,
                                                          license: nil,
                                                          authors: nil,
                                                          languages: nil)

        let mockCollection = PackageCollectionsModel.Collection(source: .init(type: .json, url: "https://feed.mock/\(UUID().uuidString)"),
                                                                name: UUID().uuidString,
                                                                overview: UUID().uuidString,
                                                                keywords: [UUID().uuidString, UUID().uuidString],
                                                                packages: [mockPackage],
                                                                createdAt: Date(),
                                                                createdBy: nil,
                                                                signature: nil)

        let mockCollection2 = PackageCollectionsModel.Collection(source: .init(type: .json, url: "https://feed.mock/\(UUID().uuidString)"),
                                                                 name: UUID().uuidString,
                                                                 overview: UUID().uuidString,
                                                                 keywords: [UUID().uuidString, UUID().uuidString],
                                                                 packages: [mockPackage],
                                                                 createdAt: Date(),
                                                                 createdBy: nil,
                                                                 signature: nil)

        mockCollections.append(mockCollection)
        mockCollections.append(mockCollection2)

        let packageCollections = makePackageCollections(mockCollections: mockCollections, storage: storage)
        
        let packageIndex = MockPackageIndex()
        let indexAndCollections = PackageIndexAndCollections(index: packageIndex, collections: packageCollections, observabilityScope: ObservabilitySystem.NOOP)
        defer { XCTAssertNoThrow(try indexAndCollections.close()) }

        for collection in mockCollections {
            _ = try await indexAndCollections.addCollection(collection.source, trustConfirmationProvider: { _, cb in cb(true) })
        }

        do {
            let fetchCollections = Set(mockCollections.map { $0.identifier } + [mockCollection.identifier, mockCollection2.identifier])
            let expectedPackages = Set(mockCollections.flatMap { $0.packages.map { $0.identity } } + [mockPackage.identity])
            let expectedCollections = Set([mockCollection.identifier, mockCollection2.identifier])

            let searchResult = try await indexAndCollections.listPackages(collections: fetchCollections)
            XCTAssertEqual(searchResult.items.count, expectedPackages.count, "list count should match")
            XCTAssertEqual(Set(searchResult.items.map { $0.package.identity }), expectedPackages, "items should match")
            XCTAssertEqual(Set(searchResult.items.first(where: { $0.package.identity == mockPackage.identity })?.collections ?? []), expectedCollections, "collections should match")
        }

        // Call API for specific collections
        do {
            let fetchCollections = Set([mockCollections[0].identifier, mockCollection.identifier, mockCollection2.identifier])
            let expectedPackages = Set(mockCollections[0].packages.map { $0.identity } + [mockPackage.identity])
            let expectedCollections = Set([mockCollection.identifier, mockCollection2.identifier])

            let searchResult = try await indexAndCollections.listPackages(collections: fetchCollections)
            XCTAssertEqual(searchResult.items.count, expectedPackages.count, "list count should match")
            XCTAssertEqual(Set(searchResult.items.map { $0.package.identity }), expectedPackages, "items should match")
            XCTAssertEqual(Set(searchResult.items.first(where: { $0.package.identity == mockPackage.identity })?.collections ?? []), expectedCollections, "collections should match")
        }
    }

    func testListTargets() async throws {
        try PackageCollectionsTests_skipIfUnsupportedPlatform()

        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }
        let mockCollections = makeMockCollections()
        let packageCollections = makePackageCollections(mockCollections: mockCollections, storage: storage)

        let packageIndex = MockPackageIndex()
        let indexAndCollections = PackageIndexAndCollections(index: packageIndex, collections: packageCollections, observabilityScope: ObservabilitySystem.NOOP)
        defer { XCTAssertNoThrow(try indexAndCollections.close()) }

        do {
            let list = try await indexAndCollections.listCollections()
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        do {
            for collection in mockCollections {
                _ = try await indexAndCollections.addCollection(collection.source, order: nil)
            }
            let list = try await indexAndCollections.listCollections()
            XCTAssertEqual(list.count, mockCollections.count, "list count should match")
        }

        let targetsList = try await indexAndCollections.listTargets()
        let expectedTargets = Set(mockCollections.flatMap { $0.packages.flatMap { $0.versions.flatMap { $0.defaultManifest!.targets.map { $0.name } } } })
        XCTAssertEqual(Set(targetsList.map { $0.target.name }), expectedTargets, "targets should match")

        let targetsPackagesList = Set(targetsList.flatMap { $0.packages })
        let expectedPackages = Set(mockCollections.flatMap { $0.packages.filter { !$0.versions.filter { !expectedTargets.isDisjoint(with: $0.defaultManifest!.targets.map { $0.name }) }.isEmpty } }.map { $0.identity })
        XCTAssertEqual(targetsPackagesList.count, expectedPackages.count, "packages should match")

        let targetsCollectionsList = Set(targetsList.flatMap { $0.packages.flatMap { $0.collections } })
        let expectedCollections = Set(mockCollections.filter { !$0.packages.filter { expectedPackages.contains($0.identity) }.isEmpty }.map { $0.identifier })
        XCTAssertEqual(targetsCollectionsList, expectedCollections, "collections should match")
    }
    
    func testFindTargets() async throws {
        try PackageCollectionsTests_skipIfUnsupportedPlatform()

        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        var mockCollections = makeMockCollections()

        let mockTargets = [UUID().uuidString, UUID().uuidString].map {
            PackageCollectionsModel.Target(name: $0, moduleName: $0)
        }

        let mockProducts = [PackageCollectionsModel.Product(name: UUID().uuidString, type: .executable, targets: [mockTargets.first!]),
                            PackageCollectionsModel.Product(name: UUID().uuidString, type: .executable, targets: mockTargets)]
        let toolsVersion = ToolsVersion(string: "5.2")!
        let mockManifest = PackageCollectionsModel.Package.Version.Manifest(
            toolsVersion: toolsVersion,
            packageName: UUID().uuidString,
            targets: mockTargets,
            products: mockProducts,
            minimumPlatformVersions: nil
        )

        let mockVersion = PackageCollectionsModel.Package.Version(version: TSCUtility.Version(1, 0, 0),
                                                                  title: nil,
                                                                  summary: nil,
                                                                  manifests: [toolsVersion: mockManifest],
                                                                  defaultToolsVersion: toolsVersion,
                                                                  verifiedCompatibility: nil,
                                                                  license: nil,
                                                                  author: nil,
                                                                  signer: nil,
                                                                  createdAt: nil)

        let mockPackageURL = "https://packages.mock/\(UUID().uuidString)"
        let mockPackage = PackageCollectionsModel.Package(identity: .init(urlString: mockPackageURL),
                                                          location: mockPackageURL,
                                                          summary: UUID().uuidString,
                                                          keywords: [UUID().uuidString, UUID().uuidString],
                                                          versions: [mockVersion],
                                                          watchersCount: nil,
                                                          readmeURL: nil,
                                                          license: nil,
                                                          authors: nil,
                                                          languages: nil)

        let mockCollection = PackageCollectionsModel.Collection(source: .init(type: .json, url: "https://feed.mock/\(UUID().uuidString)"),
                                                                name: UUID().uuidString,
                                                                overview: UUID().uuidString,
                                                                keywords: [UUID().uuidString, UUID().uuidString],
                                                                packages: [mockPackage],
                                                                createdAt: Date(),
                                                                createdBy: nil,
                                                                signature: nil)

        let mockCollection2 = PackageCollectionsModel.Collection(source: .init(type: .json, url: "https://feed.mock/\(UUID().uuidString)"),
                                                                 name: UUID().uuidString,
                                                                 overview: UUID().uuidString,
                                                                 keywords: [UUID().uuidString, UUID().uuidString],
                                                                 packages: [mockPackage],
                                                                 createdAt: Date(),
                                                                 createdBy: nil,
                                                                 signature: nil)

        let expectedCollections = [mockCollection, mockCollection2]
        let expectedCollectionsIdentifiers = expectedCollections.map { $0.identifier }.sorted()

        mockCollections.append(contentsOf: expectedCollections)

        let packageCollections = makePackageCollections(mockCollections: mockCollections, storage: storage)

        let packageIndex = MockPackageIndex()
        let indexAndCollections = PackageIndexAndCollections(index: packageIndex, collections: packageCollections, observabilityScope: ObservabilitySystem.NOOP)
        defer { XCTAssertNoThrow(try indexAndCollections.close()) }

        for collection in mockCollections {
            _ = try await indexAndCollections.addCollection(collection.source, trustConfirmationProvider: { _, cb in cb(true) })
        }

        do {
            // search by exact target name
            let searchResult = try await indexAndCollections.findTargets(mockTargets.first!.name, searchType: .exactMatch)
            XCTAssertEqual(searchResult.items.count, 1, "list count should match")
            XCTAssertEqual(searchResult.items.first?.packages.map { $0.identity }, [mockPackage.identity], "packages should match")
            XCTAssertEqual(searchResult.items.first?.packages.flatMap { $0.collections }.sorted(), expectedCollectionsIdentifiers, "collections should match")
        }

        do {
            // search by prefix target name
            let searchResult = try await indexAndCollections.findTargets(String(mockTargets.first!.name.prefix(mockTargets.first!.name.count - 1)), searchType: .prefix)
            XCTAssertEqual(searchResult.items.count, 1, "list count should match")
            XCTAssertEqual(searchResult.items.first?.packages.map { $0.identity }, [mockPackage.identity], "packages should match")
            XCTAssertEqual(searchResult.items.first?.packages.flatMap { $0.collections }.sorted(), expectedCollectionsIdentifiers, "collections should match")
        }

        do {
            // empty search
            let searchResult = try await indexAndCollections.findTargets(UUID().uuidString, searchType: .exactMatch)
            XCTAssertEqual(searchResult.items.count, 0, "list count should match")
        }
    }
        
    func testListPackagesInIndex() async throws {
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }
        let packageCollections = makePackageCollections(mockCollections: [], storage: storage)
        
        let mockPackages = (0..<10).map { packageIndex -> PackageCollectionsModel.Package in
            makeMockPackage(id: "package-\(packageIndex)")
        }
        let packageIndex = MockPackageIndex(packages: mockPackages)
        let indexAndCollections = PackageIndexAndCollections(index: packageIndex, collections: packageCollections, observabilityScope: ObservabilitySystem.NOOP)
        defer { XCTAssertNoThrow(try indexAndCollections.close()) }

        let result = try await indexAndCollections.listPackagesInIndex(offset: 1, limit: 5)
        XCTAssertFalse(result.items.isEmpty)
    }
    
    func testGetPackageMetadata() async throws {
        try PackageCollectionsTests_skipIfUnsupportedPlatform()
        
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }
        let mockCollections = makeMockCollections(count: 3)
        let mockPackage = mockCollections.last!.packages.last!
        let mockMetadata = makeMockPackageBasicMetadata()
        let metadataProvider = MockMetadataProvider([mockPackage.identity: mockMetadata])
        let packageCollections = makePackageCollections(mockCollections: mockCollections, metadataProvider: metadataProvider, storage: storage)

        let packageIndex = MockPackageIndex(packages: mockCollections.last!.packages)
        let indexAndCollections = PackageIndexAndCollections(index: packageIndex, collections: packageCollections, observabilityScope: ObservabilitySystem.NOOP)
        defer { XCTAssertNoThrow(try indexAndCollections.close()) }
        
        do {
            let list = try await indexAndCollections.listCollections()
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        do {
            for collection in mockCollections {
                _ = try await indexAndCollections.addCollection(collection.source, order: nil)
            }
            let list = try await indexAndCollections.listCollections()
            XCTAssertEqual(list.count, mockCollections.count, "list count should match")
        }
        
        let metadata = try await indexAndCollections.getPackageMetadata(identity: mockPackage.identity, location: mockPackage.location)
        
        let expectedCollections = Set(mockCollections.filter { $0.packages.map { $0.identity }.contains(mockPackage.identity) }.map { $0.identifier })
        XCTAssertEqual(Set(metadata.collections), expectedCollections, "collections should match")
        
        // Metadata comes from package index - package returned as-is, no merging
        XCTAssertEqual(metadata.package, mockPackage)
        XCTAssertNotNil(metadata.provider)
        XCTAssertEqual(metadata.provider?.name, "package index")
    }
    
    func testGetPackageMetadata_brokenIndex() async throws {
        try PackageCollectionsTests_skipIfUnsupportedPlatform()
        
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }
        let mockCollections = makeMockCollections(count: 3)
        let mockPackage = mockCollections.last!.packages.last!
        let mockMetadata = makeMockPackageBasicMetadata()
        let metadataProvider = MockMetadataProvider([mockPackage.identity: mockMetadata])
        let packageCollections = makePackageCollections(mockCollections: mockCollections, metadataProvider: metadataProvider, storage: storage)

        let packageIndex = BrokenPackageIndex()
        let indexAndCollections = PackageIndexAndCollections(index: packageIndex, collections: packageCollections, observabilityScope: ObservabilitySystem.NOOP)
        defer { XCTAssertNoThrow(try indexAndCollections.close()) }
        
        do {
            let list = try await indexAndCollections.listCollections()
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        do {
            for collection in mockCollections {
                _ = try await indexAndCollections.addCollection(collection.source, order: nil)
            }
            let list = try await indexAndCollections.listCollections()
            XCTAssertEqual(list.count, mockCollections.count, "list count should match")
        }
        
        let metadata = try await indexAndCollections.getPackageMetadata(identity: mockPackage.identity, location: mockPackage.location)

        let expectedCollections = Set(mockCollections.filter { $0.packages.map { $0.identity }.contains(mockPackage.identity) }.map { $0.identifier })
        XCTAssertEqual(Set(metadata.collections), expectedCollections, "collections should match")
        
        // Metadata comes from collections - merged with basic metadata
        let expectedMetadata = PackageCollections.mergedPackageMetadata(package: mockPackage, basicMetadata: mockMetadata)
        XCTAssertEqual(metadata.package, expectedMetadata, "package should match")

        XCTAssertNil(metadata.provider)
    }
    
    func testGetPackageMetadata_indexAndCollectionError() async throws {
        try PackageCollectionsTests_skipIfUnsupportedPlatform()
        
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }
        let packageCollections = makePackageCollections(mockCollections: [], storage: storage)

        let packageIndex = BrokenPackageIndex()
        let indexAndCollections = PackageIndexAndCollections(index: packageIndex, collections: packageCollections, observabilityScope: ObservabilitySystem.NOOP)
        defer { XCTAssertNoThrow(try indexAndCollections.close()) }
        
        let mockPackage = makeMockPackage(id: "test-package")
        // Package not found in collections; index is broken
        await XCTAssertAsyncThrowsError(try await indexAndCollections.getPackageMetadata(identity: mockPackage.identity, location: mockPackage.location)) { error in
            // Index error is returned
            guard let _ = error as? BrokenPackageIndex.TerribleThing else {
                return XCTFail("Expected BrokenPackageIndex.TerribleThing")
            }
        }
    }
    
    func testFindPackages() async throws {
        try PackageCollectionsTests_skipIfUnsupportedPlatform()
        
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        var mockCollections = makeMockCollections()

        let mockTargets = [UUID().uuidString, UUID().uuidString].map {
            PackageCollectionsModel.Target(name: $0, moduleName: $0)
        }

        let mockProducts = [PackageCollectionsModel.Product(name: UUID().uuidString, type: .executable, targets: [mockTargets.first!]),
                            PackageCollectionsModel.Product(name: UUID().uuidString, type: .executable, targets: mockTargets)]
        let toolsVersion = ToolsVersion(string: "5.2")!
        let mockManifest = PackageCollectionsModel.Package.Version.Manifest(
            toolsVersion: toolsVersion,
            packageName: UUID().uuidString,
            targets: mockTargets,
            products: mockProducts,
            minimumPlatformVersions: nil
        )

        let mockVersion = PackageCollectionsModel.Package.Version(version: TSCUtility.Version(1, 0, 0),
                                                                  title: nil,
                                                                  summary: nil,
                                                                  manifests: [toolsVersion: mockManifest],
                                                                  defaultToolsVersion: toolsVersion,
                                                                  verifiedCompatibility: nil,
                                                                  license: nil,
                                                                  author: nil,
                                                                  signer: nil,
                                                                  createdAt: nil)

        let url = "https://packages.mock/\(UUID().uuidString)"
        let mockPackage = PackageCollectionsModel.Package(identity: .init(urlString: url),
                                                          location: url,
                                                          summary: UUID().uuidString,
                                                          keywords: [UUID().uuidString, UUID().uuidString],
                                                          versions: [mockVersion],
                                                          watchersCount: nil,
                                                          readmeURL: nil,
                                                          license: nil,
                                                          authors: nil,
                                                          languages: nil)

        let mockCollection = PackageCollectionsModel.Collection(source: .init(type: .json, url: "https://feed.mock/\(UUID().uuidString)"),
                                                                name: UUID().uuidString,
                                                                overview: UUID().uuidString,
                                                                keywords: [UUID().uuidString, UUID().uuidString],
                                                                packages: [mockPackage],
                                                                createdAt: Date(),
                                                                createdBy: nil,
                                                                signature: nil)

        let mockCollection2 = PackageCollectionsModel.Collection(source: .init(type: .json, url: "https://feed.mock/\(UUID().uuidString)"),
                                                                 name: UUID().uuidString,
                                                                 overview: UUID().uuidString,
                                                                 keywords: [UUID().uuidString, UUID().uuidString],
                                                                 packages: [mockPackage],
                                                                 createdAt: Date(),
                                                                 createdBy: nil,
                                                                 signature: nil)

        let expectedCollections = [mockCollection, mockCollection2]
        let expectedCollectionsIdentifiers = expectedCollections.map { $0.identifier }.sorted()

        mockCollections.append(contentsOf: expectedCollections)
        let packageCollections = makePackageCollections(mockCollections: mockCollections, storage: storage)

        let packageIndex = MockPackageIndex(packages: [mockPackage])
        let indexAndCollections = PackageIndexAndCollections(index: packageIndex, collections: packageCollections, observabilityScope: ObservabilitySystem.NOOP)
        defer { XCTAssertNoThrow(try indexAndCollections.close()) }
        
        for collection in mockCollections {
            _ = try await indexAndCollections.addCollection(collection.source, trustConfirmationProvider: { _, cb in cb(true) })
        }
        
        // both index and collections
        do {
            let searchResult = try await indexAndCollections.findPackages(mockPackage.identity.description, in: .both(collections: nil))
            XCTAssertEqual(searchResult.items.count, 1, "list count should match")
            XCTAssertEqual(searchResult.items.first?.collections.sorted(), expectedCollectionsIdentifiers, "collections should match")
            XCTAssertEqual(searchResult.items.first?.indexes, [packageIndex.url], "indexes should match")
        }
        
        // index only
        do {
            let searchResult = try await indexAndCollections.findPackages(mockPackage.identity.description, in: .index)
            XCTAssertEqual(searchResult.items.count, 1, "list count should match")
            XCTAssertTrue(searchResult.items.first?.collections.isEmpty ?? true, "collections should match")
            XCTAssertEqual(searchResult.items.first?.indexes, [packageIndex.url], "indexes should match")
        }
        
        // collections only
        do {
            let searchResult = try await indexAndCollections.findPackages(mockPackage.identity.description, in: .collections(nil))
            XCTAssertEqual(searchResult.items.count, 1, "list count should match")
            XCTAssertEqual(searchResult.items.first?.collections.sorted(), expectedCollectionsIdentifiers, "collections should match")
            XCTAssertTrue(searchResult.items.first?.indexes.isEmpty ?? true, "indexes should match")
        }
    }
    
    func testFindPackages_brokenIndex() async throws {
        try PackageCollectionsTests_skipIfUnsupportedPlatform()
        
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        var mockCollections = makeMockCollections()

        let mockTargets = [UUID().uuidString, UUID().uuidString].map {
            PackageCollectionsModel.Target(name: $0, moduleName: $0)
        }

        let mockProducts = [PackageCollectionsModel.Product(name: UUID().uuidString, type: .executable, targets: [mockTargets.first!]),
                            PackageCollectionsModel.Product(name: UUID().uuidString, type: .executable, targets: mockTargets)]
        let toolsVersion = ToolsVersion(string: "5.2")!
        let mockManifest = PackageCollectionsModel.Package.Version.Manifest(
            toolsVersion: toolsVersion,
            packageName: UUID().uuidString,
            targets: mockTargets,
            products: mockProducts,
            minimumPlatformVersions: nil
        )

        let mockVersion = PackageCollectionsModel.Package.Version(version: TSCUtility.Version(1, 0, 0),
                                                                  title: nil,
                                                                  summary: nil,
                                                                  manifests: [toolsVersion: mockManifest],
                                                                  defaultToolsVersion: toolsVersion,
                                                                  verifiedCompatibility: nil,
                                                                  license: nil,
                                                                  author: nil,
                                                                  signer: nil,
                                                                  createdAt: nil)

        let url = "https://packages.mock/\(UUID().uuidString)"
        let mockPackage = PackageCollectionsModel.Package(identity: .init(urlString: url),
                                                          location: url,
                                                          summary: UUID().uuidString,
                                                          keywords: [UUID().uuidString, UUID().uuidString],
                                                          versions: [mockVersion],
                                                          watchersCount: nil,
                                                          readmeURL: nil,
                                                          license: nil,
                                                          authors: nil,
                                                          languages: nil)

        let mockCollection = PackageCollectionsModel.Collection(source: .init(type: .json, url: "https://feed.mock/\(UUID().uuidString)"),
                                                                name: UUID().uuidString,
                                                                overview: UUID().uuidString,
                                                                keywords: [UUID().uuidString, UUID().uuidString],
                                                                packages: [mockPackage],
                                                                createdAt: Date(),
                                                                createdBy: nil,
                                                                signature: nil)

        let mockCollection2 = PackageCollectionsModel.Collection(source: .init(type: .json, url: "https://feed.mock/\(UUID().uuidString)"),
                                                                 name: UUID().uuidString,
                                                                 overview: UUID().uuidString,
                                                                 keywords: [UUID().uuidString, UUID().uuidString],
                                                                 packages: [mockPackage],
                                                                 createdAt: Date(),
                                                                 createdBy: nil,
                                                                 signature: nil)

        let expectedCollections = [mockCollection, mockCollection2]
        let expectedCollectionsIdentifiers = expectedCollections.map { $0.identifier }.sorted()

        mockCollections.append(contentsOf: expectedCollections)
        let packageCollections = makePackageCollections(mockCollections: mockCollections, storage: storage)

        let packageIndex = BrokenPackageIndex()
        let indexAndCollections = PackageIndexAndCollections(index: packageIndex, collections: packageCollections, observabilityScope: ObservabilitySystem.NOOP)
        defer { XCTAssertNoThrow(try indexAndCollections.close()) }
        
        for collection in mockCollections {
            _ = try await indexAndCollections.addCollection(collection.source, trustConfirmationProvider: { _, cb in cb(true) })
        }
        
        // both index and collections
        do {
            let searchResult = try await indexAndCollections.findPackages(mockPackage.identity.description, in: .both(collections: nil))
            XCTAssertEqual(searchResult.items.count, 1, "list count should match")
            XCTAssertEqual(searchResult.items.first?.collections.sorted(), expectedCollectionsIdentifiers, "collections should match")
            // Results come from collections since index is broken
            XCTAssertEqual(searchResult.items.first?.indexes, [], "indexes should match")
        }
        
        // index only
        do {
            await XCTAssertAsyncThrowsError(try await indexAndCollections.findPackages(mockPackage.identity.description, in: .index)) { error in
                guard error is BrokenPackageIndex.TerribleThing else {
                    return XCTFail("invalid error \(error)")
                }
            }
        }
        
        // collections only
        do {
            let searchResult = try await indexAndCollections.findPackages(mockPackage.identity.description, in: .collections(nil))
            XCTAssertEqual(searchResult.items.count, 1, "list count should match")
            XCTAssertEqual(searchResult.items.first?.collections.sorted(), expectedCollectionsIdentifiers, "collections should match")
            // Not searching in index so should not be impacted by its error
            XCTAssertTrue(searchResult.items.first?.indexes.isEmpty ?? true, "indexes should match")
        }
    }
}

private func makePackageCollections(
    mockCollections: [PackageCollectionsModel.Collection],
    metadataProvider: PackageMetadataProvider = MockMetadataProvider([:]),
    storage: PackageCollections.Storage
) -> PackageCollections {
    let configuration = PackageCollections.Configuration()
    let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
    let metadataProvider = metadataProvider
    
    return PackageCollections(
        configuration: configuration,
        fileSystem: localFileSystem,
        observabilityScope: ObservabilitySystem.NOOP,
        storage: storage,
        collectionProviders: collectionProviders,
        metadataProvider: metadataProvider
    )
}

private struct MockPackageIndex: PackageIndexProtocol {
    let isEnabled = true
    let url: URL

    private let packages: [PackageCollectionsModel.Package]
    
    init(
        url: URL = "https://mock-package-index",
        packages: [PackageCollectionsModel.Package] = []
    ) {
        self.url = url
        self.packages = packages
    }
    
    func getPackageMetadata(
        identity: PackageIdentity,
        location: String?,
        callback: @escaping (Result<PackageCollectionsModel.PackageMetadata, Error>) -> Void
    ) {
        guard let package = self.packages.first(where: { $0.identity == identity }) else {
            return callback(.failure(NotFoundError("Package \(identity) not found")))
        }
        callback(.success((package: package, collections: [], provider: .init(name: "package index", authTokenType: nil, isAuthTokenConfigured: true))))
    }

    func findPackages(
        _ query: String,
        callback: @escaping (Result<PackageCollectionsModel.PackageSearchResult, Error>) -> Void
    ) {
        let items = self.packages.filter { $0.identity.description.contains(query) }
        callback(.success(.init(items: items.map { .init(package: $0, collections: [], indexes: [self.url]) })))
    }
    
    func listPackages(
        offset: Int,
        limit: Int,
        callback: @escaping (Result<PackageCollectionsModel.PaginatedPackageList, Error>) -> Void
    ) {
        guard !self.packages.isEmpty, offset < self.packages.count, limit > 0 else {
            return callback(.success(.init(items: [], offset: offset, limit: limit, total: self.packages.count)))
        }

        callback(.success(.init(
            items: Array(self.packages[offset..<min(self.packages.count, offset + limit)]),
            offset: offset,
            limit: limit,
            total: self.packages.count
        )))
    }
}

private struct BrokenPackageIndex: PackageIndexProtocol {
    let isEnabled = true
    
    func getPackageMetadata(
        identity: PackageIdentity,
        location: String?,
        callback: @escaping (Result<PackageCollectionsModel.PackageMetadata, Error>) -> Void
    ) {
        callback(.failure(TerribleThing()))
    }

    func findPackages(
        _ query: String,
        callback: @escaping (Result<PackageCollectionsModel.PackageSearchResult, Error>) -> Void
    ) {
        callback(.failure(TerribleThing()))
    }
    
    func listPackages(
        offset: Int,
        limit: Int,
        callback: @escaping (Result<PackageCollectionsModel.PaginatedPackageList, Error>) -> Void
    ) {
        callback(.failure(TerribleThing()))
    }
    
    struct TerribleThing: Error {}
}
