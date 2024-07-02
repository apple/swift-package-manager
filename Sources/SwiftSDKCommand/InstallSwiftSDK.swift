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
@_spi(SwiftPMInternal)
import Basics
import CoreCommands
import Foundation
import PackageModel

import class Workspace.Workspace
import var TSCBasic.stdoutStream

struct InstallSwiftSDK: SwiftSDKSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: """
        Installs a given Swift SDK bundle to a location discoverable by SwiftPM. If the artifact bundle \
        is at a remote location, it's downloaded to local filesystem first.
        """
    )

    @OptionGroup(visibility: .hidden)
    var locations: LocationOptions

    @Argument(help: "A local filesystem path or a URL of a Swift SDK bundle to install.")
    var bundlePathOrURL: String

    @Option(help: "The checksum of the bundle generated with `swift package compute-checksum`.")
    var checksum: String? = nil

    func run(
        hostTriple: Triple,
        _ swiftSDKsDirectory: AbsolutePath,
        _ observabilityScope: ObservabilityScope
    ) async throws {
        let cancellator = Cancellator(observabilityScope: observabilityScope)
        cancellator.installSignalHandlers()

        let store = SwiftSDKBundleStore(
            swiftSDKsDirectory: swiftSDKsDirectory,
            fileSystem: self.fileSystem,
            observabilityScope: observabilityScope,
            outputHandler: { print($0.description) },
            downloadProgressAnimation: ProgressAnimation
                .percent(stream: stdoutStream, verbose: false, header: "Downloading")
                .throttled(interval: .milliseconds(300))
        )

        try await store.install(
            bundlePathOrURL: bundlePathOrURL,
            checksum: self.checksum,
            UniversalArchiver(self.fileSystem, cancellator),
            HTTPClient(),
            hasher: {
                try Workspace.BinaryArtifactsManager.checksum(
                    forBinaryArtifactAt: $0,
                    fileSystem: self.fileSystem
                )
            }
        )
    }
}
