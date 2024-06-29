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

/// A namespace for target-specific build settings.
public enum TargetBuildSettingDescription {
    /// The tool for which a build setting is declared.
    public enum Tool: String, Codable, Hashable, CaseIterable, Sendable {
        case c
        case cxx
        case swift
        case linker
    }

    public enum InteroperabilityMode: String, Codable, Hashable, Sendable {
        case C
        case Cxx
    }

    /// The kind of the build setting, with associate configuration
    public enum Kind: Codable, Hashable, Sendable {
        case headerSearchPath(String)
        case define(String)
        case linkedLibrary(String)
        case linkedFramework(String)

        case interoperabilityMode(InteroperabilityMode)

        case enableUpcomingFeature(String)
        case enableExperimentalFeature(String)

        case unsafeFlags([String])

        case swiftLanguageMode(SwiftLanguageVersion)

        public var isUnsafeFlags: Bool {
            switch self {
            case .unsafeFlags(let flags):
                // If `.unsafeFlags` is used, but doesn't specify any flags, we treat it the same way as not specifying it.
                return !flags.isEmpty
            case .headerSearchPath, .define, .linkedLibrary, .linkedFramework, .interoperabilityMode,
                 .enableUpcomingFeature, .enableExperimentalFeature, .swiftLanguageMode:
                return false
            }
        }
    }

    /// An individual build setting.
    public struct Setting: Codable, Hashable, Sendable {
        /// The tool associated with this setting.
        public let tool: Tool

        /// The kind of the setting.
        public let kind: Kind

        /// The condition at which the setting should be applied.
        public let condition: PackageConditionDescription?

        public init(
            tool: Tool,
            kind: Kind,
            condition: PackageConditionDescription? = .none
        ) {
            self.tool = tool
            self.kind = kind
            self.condition = condition
        }
    }
}
