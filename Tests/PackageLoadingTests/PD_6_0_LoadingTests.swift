//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageModel
import SourceControl
import _InternalTestSupport
import XCTest

final class PackageDescription6_0LoadingTests: PackageDescriptionLoadingTests {
    override var toolsVersion: ToolsVersion {
        .v6_0
    }

    func testPackageContextGitStatus() async throws {
        try await UserToolchain.default.skipUnlessAtLeastSwift6()

        let content = """
                import PackageDescription
                let package = Package(name: "\\(Context.gitInformation?.hasUncommittedChanges == true)")
                """

        try await loadRootManifestWithBasicGitRepository(manifestContent: content) { manifest, observability in
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssertEqual(manifest.displayName, "true")
        }
    }

    func testPackageContextGitTag() async throws {
        try await UserToolchain.default.skipUnlessAtLeastSwift6()

        let content = """
                import PackageDescription
                let package = Package(name: "\\(Context.gitInformation?.currentTag ?? "")")
                """

        try await loadRootManifestWithBasicGitRepository(manifestContent: content) { manifest, observability in
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssertEqual(manifest.displayName, "lunch")
        }
    }

    func testPackageContextGitCommit() async throws {
        try await UserToolchain.default.skipUnlessAtLeastSwift6()

        let content = """
                import PackageDescription
                let package = Package(name: "\\(Context.gitInformation?.currentCommit ?? "")")
                """

        try await loadRootManifestWithBasicGitRepository(manifestContent: content) { manifest, observability in
            XCTAssertNoDiagnostics(observability.diagnostics)

            let repo = GitRepository(path: manifest.path.parentDirectory)
            let currentRevision = try repo.getCurrentRevision()
            XCTAssertEqual(manifest.displayName, currentRevision.identifier)
        }
    }

    private func loadRootManifestWithBasicGitRepository(
        manifestContent: String, 
        validator: (Manifest, TestingObservability) throws -> ()
    ) async throws {
        let observability = ObservabilitySystem.makeForTesting()

        try await testWithTemporaryDirectory { tmpdir in
            let manifestPath = tmpdir.appending(component: Manifest.filename)
            try localFileSystem.writeFileContents(manifestPath, string: manifestContent)
            try localFileSystem.writeFileContents(tmpdir.appending("best.txt"), string: "best")

            let repo = GitRepository(path: tmpdir)
            try repo.create()
            try repo.stage(file: manifestPath.pathString)
            try repo.commit(message: "best")
            try repo.tag(name: "lunch")

            let manifest = try await manifestLoader.load(
                manifestPath: manifestPath,
                packageKind: .root(tmpdir),
                toolsVersion: self.toolsVersion,
                fileSystem: localFileSystem,
                observabilityScope: observability.topScope
            )

            try validator(manifest, observability)
        }
    }
}
