//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// The context information for a Swift package.
///
/// The context encapsulates states that are known when Swift Package Manager interprets the package manifest,
/// for example the location in the file system where the current package resides.
@available(_PackageDescription, introduced: 5.6)
public struct Context: Sendable {
    private static let model = try! ContextModel.decode()

    /// The directory that contains `Package.swift`.
    public static var packageDirectory : String {
        model.packageDirectory
    }

    /// Information about the git status of a given package, if available.
    @available(_PackageDescription, introduced: 6.0)
    public static var gitInformation: GitInformation? {
        model.gitInformation.map {
            GitInformation(
                currentTag: $0.currentTag,
                currentCommit: $0.currentCommit,
                hasUncommittedChanges: $0.hasUncommittedChanges
            )
        }
    }

    /// Snapshot of the system environment variables.
    public static var environment : [String : String] {
        model.environment
    }
    
    private init() {
    }
}

/// Information about the git status of a given package, if available.
@available(_PackageDescription, introduced: 6.0)
public struct GitInformation: Sendable {
    /// The version tag currently checked out, if available.
    public let currentTag: String?
    /// The commit currently checked out.
    public let currentCommit: String
    /// Whether or not there are uncommitted changes in the current repository.
    public let hasUncommittedChanges: Bool
}
