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
import PackageGraph

import protocol TSCBasic.OutputByteStream
import enum TSCBasic.ProcessEnv

/// An enum representing what subset of the package to build.
public enum BuildSubset {
    /// Represents the subset of all products and non-test targets.
    case allExcludingTests

    /// Represents the subset of all products and targets.
    case allIncludingTests

    /// Represents a specific product.
    case product(String)

    /// Represents a specific target.
    case target(String)
}

/// A protocol that represents a build system used by SwiftPM for all build operations. This allows factoring out the
/// implementation details between SwiftPM's `BuildOperation` and the XCBuild backed `XCBuildSystem`.
package protocol BuildSystem: Cancellable {

    /// The delegate used by the build system.
    var delegate: BuildSystemDelegate? { get }

    /// The test products that this build system will build.
    var builtTestProducts: [BuiltTestProduct] { get }

    /// Returns the package graph used by the build system.
    func getPackageGraph() throws -> ModulesGraph

    /// Builds a subset of the package graph.
    /// - Parameters:
    ///   - subset: The subset of the package graph to build.
    func build(subset: BuildSubset) throws

    var buildPlan: BuildPlan { get throws }
}

extension BuildSystem {
    /// Builds the default subset: all targets excluding tests.
    public func build() throws {
        try build(subset: .allExcludingTests)
    }
}

public protocol ProductBuildDescription {
    /// The reference to the product.
    var package: ResolvedPackage { get }

    /// The reference to the product.
    var product: ResolvedProduct { get }

    /// The build parameters.
    var buildParameters: BuildParameters { get }
}

extension ProductBuildDescription {
    /// The path to the product binary produced.
    public var binaryPath: AbsolutePath {
        get throws {
            try self.buildParameters.binaryPath(for: product)
        }
    }
}

public protocol BuildPlan {
    /// Parameters used when building end products for the destination platform.
    var destinationBuildParameters: BuildParameters { get }

    /// Parameters used when building tools (macros and plugins).
    var toolsBuildParameters: BuildParameters { get }

    var buildProducts: AnySequence<ProductBuildDescription> { get }

    func createAPIToolCommonArgs(includeLibrarySearchPaths: Bool) throws -> [String]
    func createREPLArguments() throws -> [String]
}

extension BuildPlan {
    /// Parameters used for building a given target.
    public func buildParameters(for target: ResolvedTarget) -> BuildParameters {
        switch target.buildTriple {
        case .tools:
            return self.toolsBuildParameters
        case .destination:
            return self.destinationBuildParameters
        }
    }

    /// Parameters used for building a given product.
    public func buildParameters(for product: ResolvedProduct) -> BuildParameters {
        switch product.buildTriple {
        case .tools:
            return self.toolsBuildParameters
        case .destination:
            return self.destinationBuildParameters
        }
    }
}

package protocol BuildSystemFactory {
    func makeBuildSystem(
        explicitProduct: String?,
        cacheBuildManifest: Bool,
        productsBuildParameters: BuildParameters?,
        toolsBuildParameters: BuildParameters?,
        packageGraphLoader: (() throws -> ModulesGraph)?,
        outputStream: OutputByteStream?,
        logLevel: Diagnostic.Severity?,
        observabilityScope: ObservabilityScope?
    ) throws -> any BuildSystem
}

package struct BuildSystemProvider {
    // TODO: In the future, we may want this to be about specific capabilities of a build system rather than choosing a concrete one.
    public enum Kind: String, CaseIterable {
        case native
        case xcode
    }

    public let providers: [Kind: any BuildSystemFactory]

    public init(providers: [Kind: any BuildSystemFactory]) {
        self.providers = providers
    }

    public func createBuildSystem(
        kind: Kind,
        explicitProduct: String? = .none,
        cacheBuildManifest: Bool = true,
        productsBuildParameters: BuildParameters? = .none,
        toolsBuildParameters: BuildParameters? = .none,
        packageGraphLoader: (() throws -> ModulesGraph)? = .none,
        outputStream: OutputByteStream? = .none,
        logLevel: Diagnostic.Severity? = .none,
        observabilityScope: ObservabilityScope? = .none
    ) throws -> any BuildSystem {
        guard let buildSystemFactory = self.providers[kind] else {
            throw Errors.buildSystemProviderNotRegistered(kind: kind)
        }
        return try buildSystemFactory.makeBuildSystem(
            explicitProduct: explicitProduct,
            cacheBuildManifest: cacheBuildManifest,
            productsBuildParameters: productsBuildParameters,
            toolsBuildParameters: toolsBuildParameters,
            packageGraphLoader: packageGraphLoader,
            outputStream: outputStream,
            logLevel: logLevel,
            observabilityScope: observabilityScope
        )
    }
}

private enum Errors: Swift.Error {
    case buildSystemProviderNotRegistered(kind: BuildSystemProvider.Kind)
}

package enum BuildSystemUtilities {
    /// Returns the build path from the environment, if present.
    public static func getEnvBuildPath(workingDir: AbsolutePath) throws -> AbsolutePath? {
        // Don't rely on build path from env for SwiftPM's own tests.
        guard ProcessEnv.block["SWIFTPM_TESTS_MODULECACHE"] == nil else { return nil }
        guard let env = ProcessEnv.block["SWIFTPM_BUILD_DIR"] else { return nil }
        return try AbsolutePath(validating: env, relativeTo: workingDir)
    }
}
