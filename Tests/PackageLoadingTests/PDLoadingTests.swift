//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageLoading
import PackageModel
import _InternalTestSupport
import XCTest

import class TSCBasic.InMemoryFileSystem

class PackageDescriptionLoadingTests: XCTestCase, ManifestLoaderDelegate {
    lazy var manifestLoader = ManifestLoader(toolchain: try! UserToolchain.default, delegate: self)
    var parsedManifest = ThreadSafeBox<AbsolutePath>()

    func willLoad(packageIdentity: PackageModel.PackageIdentity, packageLocation: String, manifestPath: AbsolutePath) {
        // noop
    }

    func didLoad(packageIdentity: PackageIdentity, packageLocation: String, manifestPath: AbsolutePath, duration: DispatchTimeInterval) {
        // noop
    }

    func willParse(packageIdentity: PackageIdentity, packageLocation: String) {
        // noop
    }

    func didParse(packageIdentity: PackageIdentity, packageLocation: String, duration: DispatchTimeInterval) {
        // noop
    }

    func willCompile(packageIdentity: PackageIdentity, packageLocation: String, manifestPath: AbsolutePath) {
        // noop
    }

    func didCompile(packageIdentity: PackageIdentity, packageLocation: String, manifestPath: AbsolutePath, duration: DispatchTimeInterval) {
        // noop
    }

    func willEvaluate(packageIdentity: PackageIdentity, packageLocation: String, manifestPath: AbsolutePath) {
        // noop
    }

    func didEvaluate(packageIdentity: PackageModel.PackageIdentity, packageLocation: String, manifestPath: AbsolutePath, duration: DispatchTimeInterval) {
        parsedManifest.put(manifestPath)
    }

    var toolsVersion: ToolsVersion {
        fatalError("implement in subclass")
    }

    func loadAndValidateManifest(
        _ content: String,
        toolsVersion: ToolsVersion? = nil,
        packageKind: PackageReference.Kind? = nil,
        customManifestLoader: ManifestLoader? = nil,
        observabilityScope: ObservabilityScope,
        file: StaticString = #file,
        line: UInt = #line
    ) async throws -> (manifest: Manifest, diagnostics: [Basics.Diagnostic]) {
        try await Self.loadAndValidateManifest(
            content,
            toolsVersion: toolsVersion ?? self.toolsVersion,
            packageKind: packageKind ?? .fileSystem(.root),
            manifestLoader: customManifestLoader ?? self.manifestLoader,
            observabilityScope: observabilityScope,
            file: file,
            line: line
        )
    }

    static func loadAndValidateManifest(
        _ content: String,
        toolsVersion: ToolsVersion,
        packageKind: PackageReference.Kind,
        manifestLoader: ManifestLoader,
        observabilityScope: ObservabilityScope,
        file: StaticString = #file,
        line: UInt = #line
    ) async throws -> (manifest: Manifest, diagnostics: [Basics.Diagnostic]) {
        let packagePath: AbsolutePath
        switch packageKind {
        case .root(let path):
            packagePath = path
        case .fileSystem(let path):
            packagePath = path
        case .localSourceControl(let path):
            packagePath = path
        case .remoteSourceControl, .registry:
            packagePath = .root
        }

        let toolsVersion = toolsVersion
        let fileSystem = InMemoryFileSystem()
        let manifestPath = packagePath.appending(component: Manifest.filename)
        try fileSystem.writeFileContents(manifestPath, string: content)
        let manifest = try await manifestLoader.load(
            manifestPath: manifestPath,
            packageKind: packageKind,
            toolsVersion: toolsVersion,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )

        if manifest.toolsVersion != toolsVersion {
            throw StringError("Invalid manifest version")
        }

        let validator = ManifestValidator(manifest: manifest, sourceControlValidator: NOOPManifestSourceControlValidator(), fileSystem: fileSystem)
        let diagnostics = validator.validate()
        return (manifest: manifest, diagnostics: diagnostics)
    }
}

final class ManifestTestDelegate: ManifestLoaderDelegate {
    private let loaded = ThreadSafeArrayStore<AbsolutePath>()
    private let parsed = ThreadSafeArrayStore<AbsolutePath>()

    func willLoad(packageIdentity: PackageModel.PackageIdentity, packageLocation: String, manifestPath: AbsolutePath) {
        // noop
    }

    func didLoad(packageIdentity: PackageIdentity, packageLocation: String, manifestPath: AbsolutePath, duration: DispatchTimeInterval) {
        self.loaded.append(manifestPath)
    }

    func willParse(packageIdentity: PackageIdentity, packageLocation: String) {
        // noop
    }

    func didParse(packageIdentity: PackageIdentity, packageLocation: String, duration: DispatchTimeInterval) {
        // noop
    }

    func willCompile(packageIdentity: PackageIdentity, packageLocation: String, manifestPath: AbsolutePath) {
        // noop
    }

    func didCompile(packageIdentity: PackageIdentity, packageLocation: String, manifestPath: AbsolutePath, duration: DispatchTimeInterval) {
        // noop
    }

    func willEvaluate(packageIdentity: PackageIdentity, packageLocation: String, manifestPath: AbsolutePath) {
        // noop
    }

    func didEvaluate(packageIdentity: PackageIdentity, packageLocation: String, manifestPath: AbsolutePath, duration: DispatchTimeInterval) {
        self.parsed.append(manifestPath)
    }


    func clear() {
        self.loaded.clear()
        self.parsed.clear()
    }

    func loaded(timeout: Duration) async throws -> [AbsolutePath] {
        try await Task.sleep(for: timeout)
        return self.loaded.get()
    }

    func parsed(timeout: Duration) async throws -> [AbsolutePath] {
        try await Task.sleep(for: timeout)
        return self.parsed.get()
    }
}

fileprivate struct NOOPManifestSourceControlValidator: ManifestSourceControlValidator {
    func isValidDirectory(_ path: AbsolutePath) throws -> Bool {
        true
    }
}
