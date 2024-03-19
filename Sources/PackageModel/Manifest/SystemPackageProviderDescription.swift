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

/// Represents system package providers.
public enum SystemPackageProviderDescription: Hashable, Codable, Sendable {
    case brew([String])
    case macPort([String])
    case apt([String])
    case yum([String])
    case nuget([String])
}

extension SystemPackageProviderDescription {
    private enum CodingKeys: String, CodingKey {
        case brew, macPort, apt, yum, nuget
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .brew(a1):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .brew)
            try unkeyedContainer.encode(a1)
        case let .macPort(a1):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .macPort)
            try unkeyedContainer.encode(a1)
        case let .apt(a1):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .apt)
            try unkeyedContainer.encode(a1)
        case let .yum(a1):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .yum)
            try unkeyedContainer.encode(a1)
        case let .nuget(a1):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .nuget)
            try unkeyedContainer.encode(a1)
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = values.allKeys.first(where: values.contains) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Did not find a matching key"))
        }
        switch key {
        case .brew:
            var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
            let a1 = try unkeyedValues.decode([String].self)
            self = .brew(a1)
        case .macPort:
            var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
            let a1 = try unkeyedValues.decode([String].self)
            self = .macPort(a1)
        case .apt:
            var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
            let a1 = try unkeyedValues.decode([String].self)
            self = .apt(a1)
        case .yum:
            var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
            let a1 = try unkeyedValues.decode([String].self)
            self = .yum(a1)
        case .nuget:
            var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
            let a1 = try unkeyedValues.decode([String].self)
            self = .nuget(a1)
        }
    }
}
