//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import PackageGraph
import PackageModel

public struct MockTarget {
    public enum `Type` {
        case regular, test, binary
    }

    public let name: String
    public let dependencies: [TargetDescription.Dependency]
    public let path: String?
    public let url: String?
    public let checksum: String?
    public let packageAccess: Bool
    public let settings: [TargetBuildSettingDescription.Setting]
    public let type: Type

    public init(
        name: String,
        dependencies: [TargetDescription.Dependency] = [],
        type: Type = .regular,
        path: String? = nil,
        url: String? = nil,
        packageAccess: Bool = true,
        settings: [TargetBuildSettingDescription.Setting] = [],
        checksum: String? = nil
    ) throws {
        self.name = name
        self.dependencies = dependencies
        self.type = type
        self.path = path
        self.url = url
        self.packageAccess = packageAccess
        self.settings = settings
        self.checksum = checksum
    }

    func convert(identityResolver: IdentityResolver) throws -> TargetDescription {
        switch self.type {
        case .regular:
            return try TargetDescription(
                name: self.name,
                dependencies: self.dependencies.map{ try $0.convert(identityResolver: identityResolver) },
                path: self.path,
                exclude: [],
                sources: nil,
                publicHeadersPath: nil,
                type: .regular,
                packageAccess: packageAccess,
                settings: self.settings
            )
        case .test:
            return try TargetDescription(
                name: self.name,
                dependencies: self.dependencies.map{ try $0.convert(identityResolver: identityResolver) },
                path: self.path,
                exclude: [],
                sources: nil,
                publicHeadersPath: nil,
                type: .test,
                packageAccess: packageAccess,
                settings: self.settings
            )
        case .binary:
            return try TargetDescription(
                name: self.name,
                dependencies: self.dependencies.map{ try $0.convert(identityResolver: identityResolver) },
                path: self.path,
                url: self.url,
                exclude: [],
                sources: nil,
                publicHeadersPath: nil,
                type: .binary,
                packageAccess: packageAccess,
                settings: [],
                checksum: self.checksum
            )
        }
    }
}

extension TargetDescription.Dependency {
    func convert(identityResolver: IdentityResolver) throws -> Self {
        switch self {
        case .product(let name, let package, let moduleAliases, let condition):
            return .product(
                name: name,
                package: try package.flatMap { try identityResolver.mappedIdentity(for: .plain($0)).description },
                moduleAliases: moduleAliases,
                condition: condition
            )
        default:
            return self
        }
    }
}
