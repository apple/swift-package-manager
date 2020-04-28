/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2019 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

/// A resource to bundle with the Swift package.
///
/// If a Swift package declares a Swift tools version of 5.3 or later, it can include resource files.
/// Similar to source code, Xcode scopes resources to a target. As a result,
/// you need to put them into the folder that corresponds to the target they belong to.
/// For example, any resources for the `MyLibrary` target need to reside in `Sources/MyLibrary`.
/// Use subdirectories to organize your resource files in a way that makes it easy to identify and manage them.
/// For example, put all resource files into a directory named `Resources`,
/// resulting in all of your resource files residing at `Sources/MyLibrary/Resources`.
///
/// Per default, Xcode handles common resources types for Apple platforms automatically.
/// You don’t need to declare XIB files, storyboards, CoreData file types, and asset catalogs
/// as resources in your package manifest. However, you must declare other file types as resources,
/// for example, image files, explicitly using the `process(_:localization:)` or `copy(_:) rules`.
/// Alternatively, you can exclude resource files from a target by using `exclude`.
public struct Resource: Encodable {

    /// Defines the explicit type of localization for resources.
    public enum Localization: String, Encodable {

        /// The package's default localization.
        case `default`

        /// Localization for base internationalization.
        case base
    }

    /// The rule for the resource.
    private let rule: String

    /// The path of the resource.
    private let path: String

    /// The explicit type of localization for the resource.
    private let localization: Localization?

    private init(rule: String, path: String, localization: Localization?) {
        self.rule = rule
        self.path = path
        self.localization = localization
    }

    /// Applies a platform-specific rule to the resource at the given path.
    ///
    /// Use the process rule to process resources at the given path
    /// according to the platform it builds the target for. For example, the
    /// Swift package manager may optimize image files for platforms that
    /// support such optimizations. If no optimization is available for a file
    /// type, the Swift package manager copies the file.
    ///
    /// If the given path represents a directory, the Swift package manager
    /// applies the process rule recursively to each file in the directory.
    ///
    /// If possible use this rule instead of `copy(_:)`.
    ///
    /// - Parameters:
    ///     - path: The path for a resource.
    ///     - localization: The explicit localization type for the resource.
    public static func process(_ path: String, localization: Localization? = nil) -> Resource {
        return Resource(rule: "process", path: path, localization: localization)
    }

    /// Applies the copy rule to a resource at the given path.
    ///
    /// If possible, use `process(_:localization:)`` to automatically apply optimizations
    /// to resources if applicable for the platform that you’re building the package for.
    ///
    /// However, you may need resources to remain untouched or retain to a specific folder structure.
    /// In this case, use the copy rule to copy resources at the given path as
    /// is to the top-level in the package’s resource bundle.
    /// If the path represents a directory, the Swift package manager preserves its structure.
    ///
    /// - Parameters:
    ///     - path: The path for a resource.
    public static func copy(_ path: String) -> Resource {
        return Resource(rule: "copy", path: path, localization: nil)
    }
}
