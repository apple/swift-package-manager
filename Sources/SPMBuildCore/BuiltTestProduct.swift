//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics

/// Represents a test product which is built and is present on disk.
public struct BuiltTestProduct: Codable {
    /// The test product name.
    public let productName: String

    /// The path of the test binary.
    public let binaryPath: AbsolutePath

    /// The path to the package this product was declared in.
    public let packagePath: AbsolutePath

    /// The path of the test bundle.
    ///
    /// When the test product is not bundled (for instance, when using XCTest on
    /// non-Darwin targets), this path is equal to ``binaryPath``.
    public var bundlePath: AbsolutePath {
        // Go up the folder hierarchy until we find the .xctest or
        // .swift-testing bundle.
        let pathExtension: String
        switch library {
        case .xctest:
            pathExtension = ".xctest"
        case .swiftTesting:
            pathExtension = ".swift-testing"
        }
        let hierarchySequence = sequence(first: binaryPath, next: { $0.isRoot ? nil : $0.parentDirectory })
        guard let bundlePath = hierarchySequence.first(where: { $0.basename.hasSuffix(pathExtension) }) else {
            fatalError("could not find test bundle path from '\(binaryPath)'")
        }

        return bundlePath
    }

    /// The library used to build this test product.
    public var library: BuildParameters.Testing.Library

    /// Creates a new instance.
    /// - Parameters:
    ///   - productName: The test product name.
    ///   - binaryPath: The path of the test binary.
    ///   - packagePath: The path to the package this product was declared in.
    public init(productName: String, binaryPath: AbsolutePath, packagePath: AbsolutePath, library: BuildParameters.Testing.Library) {
        self.productName = productName
        self.binaryPath = binaryPath
        self.packagePath = packagePath
        self.library = library
    }
}
