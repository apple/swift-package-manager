/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2019 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

struct Resource: Encodable {

    /// The rule for the resource.
    private let rule: String

    /// The path of the resource.
    private let path: String

    private init(rule: String, path: String) {
        self.rule = rule
        self.path = path
    }

    /// Apply the platform-specific rule to the given path.
    ///
    /// Matching paths will be processed according to the platform for which this
    /// target is being built. For example, image files might get optimized when
    /// building for platforms that support such optimizations.
    ///
    /// By default, a file will be copied if there is no specialized processing
    /// for its file type.
    ///
    /// If path is a directory, the rule is applied recursively to each file in the
    /// directory. 
    public static func process(_ path: String) -> Resource {
        return Resource(rule: "process", path: path)
    }

    /// Apply the copy rule to the given path.
    ///
    /// Matching paths will be copied as-is and will be at the top-level
    /// in the bundle. The structure is retained if path is a directory.
    public static func copy(_ path: String) -> Resource {
        return Resource(rule: "copy", path: path)
    }
}
