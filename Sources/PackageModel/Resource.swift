/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import TSCBasic

/// An individual resource file and its corresponding rule.
public struct Resource {
    public typealias Rule = TargetDescription.Resource.Rule

    /// The rule associated with this resource.
    public let rule: Rule

    /// The path of the resource file.
    public let path: AbsolutePath

    public init(rule: Rule, path: AbsolutePath) {
        self.rule = rule
        self.path = path
    }
}
