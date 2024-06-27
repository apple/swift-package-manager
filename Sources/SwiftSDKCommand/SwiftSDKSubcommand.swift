//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import Basics
import CoreCommands
import Dispatch
import PackageModel

import var TSCBasic.stdoutStream

/// A protocol for functions and properties common to all Swift SDK subcommands.
protocol SwiftSDKSubcommand: AsyncParsableCommand {
    /// Common locations options provided by ArgumentParser.
    var locations: LocationOptions { get }

    /// Run a command operating on Swift SDKs, passing it required configuration values.
    /// - Parameters:
    ///   - hostTriple: triple of the machine this command is running on.
    ///   - swiftSDKsDirectory: directory containing Swift SDK artifact bundles and their configuration.
    ///   - observabilityScope: observability scope used for logging.
    func run(
        hostTriple: Triple,
        _ swiftSDKsDirectory: AbsolutePath,
        _ observabilityScope: ObservabilityScope
    ) async throws
}

extension SwiftSDKSubcommand {
    /// The file system used by default by this command.
    var fileSystem: FileSystem { localFileSystem }

    /// Parses Swift SDKs directory option if provided or uses the default path for Swift SDKs
    /// on the file system. A new directory at this path is created if one doesn't exist already.
    /// - Returns: existing or a newly created directory at the computed location.
    func getOrCreateSwiftSDKsDirectory() throws -> AbsolutePath {
        var swiftSDKsDirectory = try fileSystem.getSharedSwiftSDKsDirectory(
            explicitDirectory: locations.swiftSDKsDirectory
        )

        if !self.fileSystem.exists(swiftSDKsDirectory) {
            swiftSDKsDirectory = try self.fileSystem.getOrCreateSwiftPMSwiftSDKsDirectory()
        }

        return swiftSDKsDirectory
    }

    public func run() async throws {
        let observabilityHandler = SwiftCommandObservabilityHandler(outputStream: stdoutStream, logLevel: .info)
        let observabilitySystem = ObservabilitySystem(observabilityHandler)
        let observabilityScope = observabilitySystem.topScope
        let swiftSDKsDirectory = try self.getOrCreateSwiftSDKsDirectory()

        let environment = Environment.current
        let hostToolchain = try UserToolchain(
            swiftSDK: SwiftSDK.hostSwiftSDK(
                environment: environment
            ),
            environment: environment
        )
        let triple = try Triple.getHostTriple(usingSwiftCompiler: hostToolchain.swiftCompilerPath)

        var commandError: Error? = nil
        do {
            try await self.run(hostTriple: triple, swiftSDKsDirectory, observabilityScope)
            if observabilityScope.errorsReported {
                throw ExitCode.failure
            }
        } catch {
            commandError = error
        }

        // wait for all observability items to process
        observabilityHandler.wait(timeout: .now() + 5)

        if let commandError {
            throw commandError
        }
    }
}
