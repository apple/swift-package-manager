//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageGraph
import PackageLoading
import PackageModel
import SourceControl
import _InternalTestSupport
import XCTest

import enum TSCBasic.JSON
import protocol TSCBasic.JSONMappable
import protocol TSCBasic.JSONSerializable

import func TSCUtility.measure
import struct TSCUtility.Version

import class TSCTestSupport.XCTestCasePerf

private let v1: Version = "1.0.0"
private let v1Range: VersionSetSpecifier = .range("1.0.0" ..< "2.0.0")

class DependencyResolverRealWorldPerfTests: XCTestCasePerf {
    func testKituraPubGrub_X100() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        try runPackageTestPubGrub(name: "kitura.json", N: 100)
    }

    func testZewoPubGrub_X100() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        try runPackageTestPubGrub(name: "ZewoHTTPServer.json", N: 100)
    }

    func testPerfectPubGrub_X100() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        try runPackageTestPubGrub(name: "PerfectHTTPServer.json", N: 100)
    }

    func testSourceKittenPubGrub_X100() throws {
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif
        try runPackageTestPubGrub(name: "SourceKitten.json", N: 100)
    }

    func runPackageTestPubGrub(name: String, N: Int = 1) throws {
        let graph = try mockGraph(for: name)
        let provider = MockPackageContainerProvider(containers: graph.containers)

        measure {
            for _ in 0 ..< N {
                let resolver = PubGrubDependencyResolver(provider: provider, observabilityScope: ObservabilitySystem.NOOP)
                switch resolver.solve(constraints: graph.constraints) {
                case .success(let result):
                    let result: [(container: PackageReference, version: Version)] = result.compactMap {
                        guard case .version(let version, _) = $0.boundVersion else {
                            XCTFail("Unexpected result")
                            return nil
                        }
                        return ($0.package, version)
                    }
                    graph.checkResult(result)
                case .failure:
                    XCTFail("Unexpected result")
                    return
                }
            }
        }
    }

    func mockGraph(for name: String) throws -> MockDependencyGraph {
        let input = AbsolutePath(#file).parentDirectory.appending("Inputs").appending(component: name)
        let jsonString: Data = try localFileSystem.readFileContents(input)
        let json = try JSON(data: jsonString)
        return MockDependencyGraph(json)
    }
}


// MARK: - JSON

public extension MockDependencyGraph {
    init(_ json: JSON) {
        guard case .dictionary(let dict) = json else { fatalError() }
        guard case .string(let name)? = dict["name"] else { fatalError() }
        guard case .array(let constraints)? = dict["constraints"] else { fatalError() }
        guard case .array(let containers)? = dict["containers"] else { fatalError() }
        guard case .dictionary(let result)? = dict["result"] else { fatalError() }

        self.init(
            name: name,
            constraints: constraints.map(PackageContainerConstraint.init(json:)),
            containers: containers.map(MockPackageContainer.init(json:)),
            result: Dictionary(uniqueKeysWithValues: try! result.map { value in
                let (container, version) = value
                guard case .string(let str) = version else { fatalError() }
                let package = PackageReference.localSourceControl(identity: .plain(container.lowercased()), path: try .init(validating: "/\(container)"))
                return (package, Version(str)!)
            })
        )
    }
}

private extension MockPackageContainer {
    convenience init(json: JSON) {
        guard case .dictionary(let dict) = json else { fatalError() }
        guard case .string(let identifier)? = dict["identifier"] else { fatalError() }
        guard case .dictionary(let versions)? = dict["versions"] else { fatalError() }

        var depByVersion: [Version: [(container: String, versionRequirement: VersionSetSpecifier)]] = [:]
        for (version, deps) in versions {
            guard case .array(let depArray) = deps else { fatalError() }
            depByVersion[Version(version)!] = depArray
                .map(PackageContainerConstraint.init(json:))
                .map { constraint in
                    switch constraint.requirement {
                    case .versionSet(let versionSet):
                        return (constraint.package.identity.description, versionSet)
                    case .unversioned:
                        fatalError()
                    case .revision:
                        fatalError()
                    }
                }
        }

        try! self.init(name: identifier, dependenciesByVersion: depByVersion)
    }
}

private extension MockPackageContainer.Constraint {
    init(json: JSON) {
        guard case .dictionary(let dict) = json else { fatalError() }
        guard case .string(let identifier)? = dict["identifier"] else { fatalError() }
        guard let requirement = dict["requirement"] else { fatalError() }
        let products: ProductFilter = try! JSON(dict).get("products")
        let ref = PackageReference.localSourceControl(identity: .plain(identifier), path: .root)
        self.init(package: ref, versionRequirement: VersionSetSpecifier(requirement), products: products)
    }
}

private extension VersionSetSpecifier {
    init(_ json: JSON) {
        switch json {
        case .string(let str):
            switch str {
            case "any": self = .any
            case "empty": self = .empty
            default: fatalError()
            }
        case .array(let arr):
            switch arr.count {
            case 1:
                guard case .string(let str) = arr[0] else { fatalError() }
                self = .exact(Version(str)!)
            case 2:
                let versions = arr.map { json -> Version in
                    guard case .string(let str) = json else { fatalError() }
                    return Version(str)!
                }
                self = .range(versions[0] ..< versions[1])
            default: fatalError()
            }
        default: fatalError()
        }
    }
}

extension ProductFilter {
    public func toJSON() -> JSON {
        switch self {
        case .everything:
            return "all".toJSON()
        case .specific(let products):
            return products.sorted().toJSON()
        }
    }

    public init(json: JSON) throws {
        if let products = try? [String](json: json) {
            self = .specific(Set(products))
        } else {
            self = .everything
        }
    }
}

#if compiler(<6.0)
extension ProductFilter: JSONSerializable, JSONMappable {}
#else
extension ProductFilter: @retroactive JSONSerializable, @retroactive JSONMappable {}
#endif
