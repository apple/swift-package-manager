//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import _Concurrency
import struct PackageGraph.ModulesGraph

/// A async-first protocol that represents a build system used by SwiftPM for all build operations.
/// This allows factoring out the implementation details between SwiftPM's `BuildOperation` and the XCBuild
/// backed `XCBuildSystem`.
@_spi(SwiftPMInternal)
public protocol AsyncBuildSystem {
    /// The test products that this build system will build.
    var builtTestProducts: [BuiltTestProduct] { get }

    /// Returns the modules graph used by the build system.
    var modulesGraph: ModulesGraph { get throws }

    /// Builds a subset of the modules graph.
    /// - Parameters:
    ///   - subset: The subset of the modules graph to build.
    func build(subset: BuildSubset) async throws

    var buildPlan: any BuildPlan { get throws }
}

extension AsyncBuildSystem {
    /// Builds the default subset: all targets excluding tests.
    public func build() async throws {
        try await build(subset: .allExcludingTests)
    }
}
