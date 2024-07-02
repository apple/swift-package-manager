//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import Basics

import Build

@_spi(SwiftPMInternal)
import CoreCommands

import PackageGraph

import SPMBuildCore
import XCBuildSupport

import class Basics.AsyncProcess
import var TSCBasic.stdoutStream

import enum TSCUtility.Diagnostics
import func TSCUtility.getClangVersion
import struct TSCUtility.Version

extension BuildSubset {
    var argumentName: String {
        switch self {
        case .allExcludingTests:
            fatalError("no corresponding argument")
        case .allIncludingTests:
            return "--build-tests"
        case .product:
            return "--product"
        case .target:
            return "--target"
        }
    }
}

struct BuildCommandOptions: ParsableArguments {
    /// Returns the build subset specified with the options.
    func buildSubset(observabilityScope: ObservabilityScope) -> BuildSubset? {
        var allSubsets: [BuildSubset] = []

        if let product {
            allSubsets.append(.product(product))
        }

        if let target {
            allSubsets.append(.target(target))
        }

        if buildTests {
            allSubsets.append(.allIncludingTests)
        }

        guard allSubsets.count < 2 else {
            observabilityScope.emit(.mutuallyExclusiveArgumentsError(arguments: allSubsets.map{ $0.argumentName }))
            return nil
        }

        return allSubsets.first ?? .allExcludingTests
    }

    /// If the test should be built.
    @Flag(help: "Build both source and test targets")
    var buildTests: Bool = false

    /// Whether to enable code coverage.
    @Flag(name: .customLong("code-coverage"),
          inversion: .prefixedEnableDisable,
          help: "Enable code coverage")
    var enableCodeCoverage: Bool = false

    /// If the binary output path should be printed.
    @Flag(name: .customLong("show-bin-path"), help: "Print the binary output path")
    var shouldPrintBinPath: Bool = false

    /// Whether to output a graphviz file visualization of the combined job graph for all targets
    @Flag(name: .customLong("print-manifest-job-graph"),
          help: "Write the command graph for the build manifest as a graphviz file")
    var printManifestGraphviz: Bool = false

    /// Specific target to build.
    @Option(help: "Build the specified target")
    var target: String?

    /// Specific product to build.
    @Option(help: "Build the specified product")
    var product: String?

    /// Specifies the traits to build.
    @OptionGroup(visibility: .hidden)
    package var traits: TraitOptions

    /// If should link the Swift stdlib statically.
    @Flag(name: .customLong("static-swift-stdlib"), inversion: .prefixedNo, help: "Link Swift stdlib statically")
    public var shouldLinkStaticSwiftStdlib: Bool = false

    /// Which testing libraries to use (and any related options.)
    @OptionGroup()
    var testLibraryOptions: TestLibraryOptions

    func validate() throws {
        // If --build-tests was not specified, it does not make sense to enable
        // or disable either testing library.
        if !buildTests {
            if testLibraryOptions.explicitlyEnableXCTestSupport != nil
                || testLibraryOptions.explicitlyEnableSwiftTestingLibrarySupport != nil {
                throw StringError("pass --build-tests to build test targets")
            }
        }
    }
}

/// swift-build command namespace
public struct SwiftBuildCommand: AsyncSwiftCommand {
    public static var configuration = CommandConfiguration(
        commandName: "build",
        _superCommandName: "swift",
        abstract: "Build sources into binary products",
        discussion: "SEE ALSO: swift run, swift package, swift test",
        version: SwiftVersion.current.completeDisplayString,
        helpNames: [.short, .long, .customLong("help", withSingleDash: true)])

    @OptionGroup()
    public var globalOptions: GlobalOptions

    @OptionGroup()
    var options: BuildCommandOptions

    public func run(_ swiftCommandState: SwiftCommandState) async throws {
        if options.shouldPrintBinPath {
            return try print(swiftCommandState.productsBuildParameters.buildPath.description)
        }

        if options.printManifestGraphviz {
            // FIXME: Doesn't seem ideal that we need an explicit build operation, but this concretely uses the `LLBuildManifest`.
            guard let buildOperation = try swiftCommandState.createBuildSystem(
                explicitBuildSystem: .native,
                traitConfiguration: .init(traitOptions: self.options.traits)
            ) as? BuildOperation else {
                throw StringError("asked for native build system but did not get it")
            }
            let buildManifest = try await buildOperation.getBuildManifest()
            var serializer = DOTManifestSerializer(manifest: buildManifest)
            // print to stdout
            let outputStream = stdoutStream
            serializer.writeDOT(to: outputStream)
            outputStream.flush()
            return
        }

        guard let subset = options.buildSubset(observabilityScope: swiftCommandState.observabilityScope) else {
            throw ExitCode.failure
        }

        var productsBuildParameters = try swiftCommandState.productsBuildParameters
        var toolsBuildParameters = try swiftCommandState.toolsBuildParameters

        // Clean out the code coverage directory that may contain stale
        // profraw files from a previous run of the code coverage tool.
        if self.options.enableCodeCoverage {
            try swiftCommandState.fileSystem.removeFileTree(swiftCommandState.productsBuildParameters.codeCovPath)
            productsBuildParameters.testingParameters.enableCodeCoverage = true
            toolsBuildParameters.testingParameters.enableCodeCoverage = true
        }

        if case .allIncludingTests = subset {
            func updateTestingParameters(of buildParameters: inout BuildParameters, library: BuildParameters.Testing.Library) {
                buildParameters.testingParameters = .init(
                    configuration: buildParameters.configuration,
                    targetTriple: buildParameters.triple,
                    enableCodeCoverage: buildParameters.testingParameters.enableCodeCoverage,
                    enableTestability: buildParameters.testingParameters.enableTestability,
                    experimentalTestOutput: buildParameters.testingParameters.experimentalTestOutput,
                    forceTestDiscovery: globalOptions.build.enableTestDiscovery,
                    testEntryPointPath: globalOptions.build.testEntryPointPath,
                    library: library
                )
            }
            for library in try options.testLibraryOptions.enabledTestingLibraries(swiftCommandState: swiftCommandState) {
                updateTestingParameters(of: &productsBuildParameters, library: library)
                updateTestingParameters(of: &toolsBuildParameters, library: library)
                try await build(swiftCommandState, subset: subset, productsBuildParameters: productsBuildParameters, toolsBuildParameters: toolsBuildParameters)
            }
        } else {
            try await build(swiftCommandState, subset: subset, productsBuildParameters: productsBuildParameters, toolsBuildParameters: toolsBuildParameters)
        }
    }

    private func build(
        _ swiftCommandState: SwiftCommandState,
        subset: BuildSubset,
        productsBuildParameters: BuildParameters,
        toolsBuildParameters: BuildParameters
    ) async throws {
        let buildSystem = try swiftCommandState.createBuildSystem(
            explicitProduct: options.product,
            traitConfiguration: .init(traitOptions: self.options.traits),
            shouldLinkStaticSwiftStdlib: options.shouldLinkStaticSwiftStdlib,
            productsBuildParameters: productsBuildParameters,
            toolsBuildParameters: toolsBuildParameters,
            // command result output goes on stdout
            // ie "swift build" should output to stdout
            outputStream: TSCBasic.stdoutStream
        )
        do {
            try await buildSystem.build(subset: subset)
        } catch _ as Diagnostics {
            throw ExitCode.failure
        }
    }

    public init() {}
}

public extension _SwiftCommand {
    func buildSystemProvider(_ swiftCommandState: SwiftCommandState) throws -> BuildSystemProvider {
        swiftCommandState.defaultBuildSystemProvider
    }
}
