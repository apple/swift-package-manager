//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// Namespace for build settings.
public enum BuildSettings {
    /// Build settings declarations.
    public struct Declaration: Hashable {
        // Swift.
        public static let SWIFT_ACTIVE_COMPILATION_CONDITIONS: Declaration =
            .init("SWIFT_ACTIVE_COMPILATION_CONDITIONS")
        public static let OTHER_SWIFT_FLAGS: Declaration = .init("OTHER_SWIFT_FLAGS")
        public static let SWIFT_VERSION: Declaration = .init("SWIFT_VERSION")

        // C family.
        public static let GCC_PREPROCESSOR_DEFINITIONS: Declaration = .init("GCC_PREPROCESSOR_DEFINITIONS")
        public static let HEADER_SEARCH_PATHS: Declaration = .init("HEADER_SEARCH_PATHS")
        public static let OTHER_CFLAGS: Declaration = .init("OTHER_CFLAGS")
        public static let OTHER_CPLUSPLUSFLAGS: Declaration = .init("OTHER_CPLUSPLUSFLAGS")

        // Linker.
        public static let OTHER_LDFLAGS: Declaration = .init("OTHER_LDFLAGS")
        public static let LINK_LIBRARIES: Declaration = .init("LINK_LIBRARIES")
        public static let LINK_FRAMEWORKS: Declaration = .init("LINK_FRAMEWORKS")

        /// The declaration name.
        public let name: String

        private init(_ name: String) {
            self.name = name
        }
    }

    /// An individual build setting assignment.
    public struct Assignment: Equatable, Hashable {
        /// The assignment value.
        public var values: [String]

        public var conditions: [PackageCondition]

        /// Indicates whether this assignment represents a default
        /// that should be used only if no other assignments match.
        public let `default`: Bool

        public init(default: Bool = false) {
            self.conditions = []
            self.values = []
            self.default = `default`
        }

        public init(values: [String] = [], conditions: [PackageCondition] = []) {
            self.values = values
            self.default = false // TODO(franz): Check again
            self.conditions = conditions
        }
    }

    /// Build setting assignment table which maps a build setting to a list of assignments.
    public struct AssignmentTable {
        public private(set) var assignments: [Declaration: [Assignment]]

        public init() {
            self.assignments = [:]
        }

        /// Add the given assignment to the table.
        public mutating func add(_ assignment: Assignment, for decl: Declaration) {
            // FIXME: We should check for duplicate assignments.
            self.assignments[decl, default: []].append(assignment)
        }
    }

    /// Provides a view onto assignment table with a given set of bound parameters.
    ///
    /// This class can be used to get the assignments matching the bound parameters.
    public struct Scope {
        /// The assignment table.
        public let table: AssignmentTable

        /// The build environment.
        public let environment: BuildEnvironment

        public init(_ table: AssignmentTable, environment: BuildEnvironment) {
            self.table = table
            self.environment = environment
        }

        /// Evaluate the given declaration and return the values matching the bound parameters.
        public func evaluate(_ decl: Declaration) -> [String] {
            // Return nil if there is no entry for this declaration.
            guard let assignments = table.assignments[decl] else {
                return []
            }

            // Add values from each assignment if it satisfies the build environment.
            let allViableAssignments = assignments
                .lazy
                .filter { $0.conditions.allSatisfy { $0.satisfies(self.environment) } }

            let nonDefaultAssignments = allViableAssignments.filter { !$0.default }

            // If there are no non-default assignments, let's fallback to defaults.
            if nonDefaultAssignments.isEmpty {
                return allViableAssignments.filter(\.default).flatMap(\.values)
            }

            return nonDefaultAssignments.flatMap(\.values)
        }
    }
}
