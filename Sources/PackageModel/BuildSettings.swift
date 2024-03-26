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
    public struct Declaration: Hashable, Codable {
        // Swift.
        public static let SWIFT_ACTIVE_COMPILATION_CONDITIONS: Declaration = .init("SWIFT_ACTIVE_COMPILATION_CONDITIONS")
        public static let OTHER_SWIFT_FLAGS: Declaration = .init("OTHER_SWIFT_FLAGS")

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
    public struct Assignment: Codable, Equatable, Hashable {
        /// The assignment value.
        public var values: [String]

        // FIXME: This should use `Set` but we need to investigate potential build failures on Linux caused by using it.
        /// The condition associated with this assignment.
        public var conditions: [PackageCondition] {
            get {
                return _conditions.map { $0.underlying }
            }
            set {
                _conditions = newValue.map { PackageConditionWrapper($0) }
            }
        }

        private var _conditions: [PackageConditionWrapper]

        public init(values: [String] = [], conditions: [PackageCondition] = []) {
            self._conditions = []
            self.values = values
            self.conditions = conditions
        }
    }

    /// Build setting assignment table which maps a build setting to a list of assignments.
    public struct AssignmentTable: Codable {
        public private(set) var assignments: [Declaration: [Assignment]]

        public init() {
            assignments = [:]
        }

        /// Add the given assignment to the table.
        mutating public func add(_ assignment: Assignment, for decl: Declaration) {
            // FIXME: We should check for duplicate assignments.
            assignments[decl, default: []].append(assignment)
        }
    }

    /// Provides a view onto assignment table with a given set of bound parameters.
    ///
    /// This class can be used to get the assignments matching the bound parameters.
    public final class Scope {
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
            let values = assignments
                .lazy
                .filter { $0.conditions.allSatisfy { $0.satisfies(self.environment) } }
                .flatMap { $0.values }

            return Array(values)
        }
    }
}
