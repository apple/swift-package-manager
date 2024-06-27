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

import _Concurrency
import Basics
import Dispatch
import Foundation
import PackageModel
import SourceControl

import class TSCBasic.BufferedOutputByteStream
import struct TSCBasic.ByteString
import class Basics.AsyncProcess
import struct Basics.AsyncProcessResult

import enum TSCUtility.Diagnostics
import struct TSCUtility.Version

#if os(Windows)
import WinSDK
#endif

extension AbsolutePath {
    /// Returns the `pathString` on non-Windows platforms.  On Windows
    /// platforms, this provides the path string normalized as per the Windows
    /// path normalization rules.  In the case that the path is a long path, the
    /// path will use the extended path syntax (UNC style, NT Path).
    internal var _normalized: String {
#if os(Windows)
        return self.pathString.withCString(encodedAs: UTF16.self) { pwszPath in
            let dwLength = GetFullPathNameW(pwszPath, 0, nil, nil)
            return withUnsafeTemporaryAllocation(of: WCHAR.self, capacity: Int(dwLength)) {
                _ = GetFullPathNameW(pwszPath, dwLength, $0.baseAddress, nil)
                return String(decodingCString: $0.baseAddress!, as: UTF16.self)
            }
        }
#else
        return self.pathString
#endif
    }
}

public enum ManifestParseError: Swift.Error, Equatable {
    /// The manifest is empty, or at least from SwiftPM's perspective it is.
    case emptyManifest(path: AbsolutePath)
    /// The manifest contains invalid format.
    case invalidManifestFormat(String, diagnosticFile: AbsolutePath?)
    // TODO: Test this error.
    case invalidManifestFormat(String, diagnosticFile: AbsolutePath?, compilerCommandLine: [String]?)

    /// The manifest was successfully loaded by swift interpreter but there were runtime issues.
    case runtimeManifestErrors([String])

    /// The manifest loader specified import restrictions that the given manifest violated.
    case importsRestrictedModules([String])

    /// The JSON payload received from executing the manifest has an unsupported version, usually indicating an invalid mix-and-match of SwiftPM and PackageDescription libraries.
    case unsupportedVersion(version: Int, underlyingError: String? = nil)
}

// used to output the errors via the observability system
extension ManifestParseError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .emptyManifest(let manifestPath):
            return "'\(manifestPath)' is empty"
        case .invalidManifestFormat(let error, _, let compilerCommandLine):
            let suffix: String
            if let compilerCommandLine {
                suffix = " (compiled with: \(compilerCommandLine))"
            } else {
                suffix = ""
            }
            return "Invalid manifest\(suffix)\n\(error)"
        case .runtimeManifestErrors(let errors):
            return "invalid manifest (evaluation failed)\n\(errors.joined(separator: "\n"))"
        case .importsRestrictedModules(let modules):
            return "invalid manifest, imports restricted modules: \(modules.joined(separator: ", "))"
        case .unsupportedVersion(let version, let underlyingError):
            let message = "serialized JSON uses unsupported version \(version), indicating use of a mismatched PackageDescription library"
            if let underlyingError {
                return "\(message), underlying error: \(underlyingError)"
            }
            return message
        }
    }
}

// MARK: - ManifestLoaderProtocol

/// Protocol for the manifest loader interface.
public protocol ManifestLoaderProtocol {
    /// Load the manifest for the package at `path`.
    ///
    /// - Parameters:
    ///   - manifestPath: The root path of the package.
    ///   - manifestToolsVersion: The version of the tools the manifest supports.
    ///   - packageIdentity: the identity of the package
    ///   - packageKind: The kind of package the manifest is from.
    ///   - packageLocation: The location the package the manifest was loaded from.
    ///   - packageVersion: Optional. The version and revision of the package.
    ///   - identityResolver: A helper to resolve identities based on configuration
    ///   - dependencyMapper: A helper to map dependencies.
    ///   - fileSystem: File system to load from.
    ///   - observabilityScope: Observability scope to emit diagnostics.
    ///   - callbackQueue: The dispatch queue to perform completion handler on.
    ///   - completion: The completion handler .
    func load(
        manifestPath: AbsolutePath,
        manifestToolsVersion: ToolsVersion,
        packageIdentity: PackageIdentity,
        packageKind: PackageReference.Kind,
        packageLocation: String,
        packageVersion: (version: Version?, revision: String?)?,
        identityResolver: IdentityResolver,
        dependencyMapper: DependencyMapper,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope,
        delegateQueue: DispatchQueue,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Manifest, Error>) -> Void
    )

    /// Reset any internal cache held by the manifest loader.
    func resetCache(observabilityScope: ObservabilityScope)

    /// Reset any internal cache held by the manifest loader and purge any entries in a shared cache
    func purgeCache(observabilityScope: ObservabilityScope)
}

public protocol ManifestLoaderDelegate {
    func willLoad(
        packageIdentity: PackageIdentity,
        packageLocation: String,
        manifestPath: AbsolutePath
    )
    func didLoad(
        packageIdentity: PackageIdentity,
        packageLocation: String,
        manifestPath: AbsolutePath,
        duration: DispatchTimeInterval
    )

    func willParse(
        packageIdentity: PackageIdentity,
        packageLocation: String
    )
    func didParse(
        packageIdentity: PackageIdentity,
        packageLocation: String,
        duration: DispatchTimeInterval
    )

    func willCompile(
        packageIdentity: PackageIdentity,
        packageLocation: String,
        manifestPath: AbsolutePath
    )
    func didCompile(
        packageIdentity: PackageIdentity,
        packageLocation: String,
        manifestPath: AbsolutePath,
        duration: DispatchTimeInterval
    )

    func willEvaluate(
        packageIdentity: PackageIdentity,
        packageLocation: String,
        manifestPath: AbsolutePath
    )
    func didEvaluate(
        packageIdentity: PackageIdentity,
        packageLocation: String,
        manifestPath: AbsolutePath,
        duration: DispatchTimeInterval
    )
}

// loads a manifest given a package root path
// this will first find the most appropriate manifest file in the package directory
// bases on the toolchain's tools-version and proceed to load that manifest
extension ManifestLoaderProtocol {
    public func load(
        packagePath: AbsolutePath,
        packageIdentity: PackageIdentity,
        packageKind: PackageReference.Kind,
        packageLocation: String,
        packageVersion: (version: Version?, revision: String?)?,
        currentToolsVersion: ToolsVersion,
        identityResolver: IdentityResolver,
        dependencyMapper: DependencyMapper,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope,
        delegateQueue: DispatchQueue,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Manifest, Error>) -> Void
    ) {
        do {
            // find the manifest path and parse it's tools-version
            let manifestPath = try ManifestLoader.findManifest(packagePath: packagePath, fileSystem: fileSystem, currentToolsVersion: currentToolsVersion)
            let manifestToolsVersion = try ToolsVersionParser.parse(manifestPath: manifestPath, fileSystem: fileSystem)
            // validate the manifest tools-version against the toolchain tools-version
            try manifestToolsVersion.validateToolsVersion(currentToolsVersion, packageIdentity: packageIdentity, packageVersion: packageVersion?.version?.description ?? packageVersion?.revision)

            self.load(
                manifestPath: manifestPath,
                manifestToolsVersion: manifestToolsVersion,
                packageIdentity: packageIdentity,
                packageKind: packageKind,
                packageLocation: packageLocation,
                packageVersion: packageVersion,
                identityResolver: identityResolver,
                dependencyMapper: dependencyMapper,
                fileSystem: fileSystem,
                observabilityScope: observabilityScope,
                delegateQueue: delegateQueue,
                callbackQueue: callbackQueue,
                completion: completion
            )
        } catch {
            callbackQueue.async {
                completion(.failure(error))
            }
        }
    }    

    public func load(
        packagePath: AbsolutePath,
        packageIdentity: PackageIdentity,
        packageKind: PackageReference.Kind,
        packageLocation: String,
        packageVersion: (version: Version?, revision: String?)?,
        currentToolsVersion: ToolsVersion,
        identityResolver: IdentityResolver,
        dependencyMapper: DependencyMapper,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope,
        delegateQueue: DispatchQueue,
        callbackQueue: DispatchQueue
    ) async throws -> Manifest {
        try await withCheckedThrowingContinuation {
            self.load(
                packagePath: packagePath,
                packageIdentity: packageIdentity,
                packageKind: packageKind,
                packageLocation: packageLocation,
                packageVersion: packageVersion,
                currentToolsVersion: currentToolsVersion,
                identityResolver: identityResolver,
                dependencyMapper: dependencyMapper,
                fileSystem: fileSystem,
                observabilityScope: observabilityScope,
                delegateQueue: delegateQueue,
                callbackQueue: callbackQueue,
                completion: $0.resume(with:)
            )
        }
    }
}

// MARK: - ManifestLoader

/// Utility class for loading manifest files.
///
/// This class is responsible for reading the manifest data and produce a
/// properly formed `PackageModel.Manifest` object. It currently does so by
/// interpreting the manifest source using Swift -- that produces a JSON
/// serialized form of the manifest (as implemented by `PackageDescription`'s
/// `atexit()` handler) which is then deserialized and loaded.
public final class ManifestLoader: ManifestLoaderProtocol {
    public typealias Delegate = ManifestLoaderDelegate
    
    private let toolchain: UserToolchain
    private let serializedDiagnostics: Bool
    private let isManifestSandboxEnabled: Bool
    private let extraManifestFlags: [String]
    private let importRestrictions: (startingToolsVersion: ToolsVersion, allowedImports: [String])?

    // not thread safe
    public var delegate: Delegate?

    private let databaseCacheDir: AbsolutePath?
    private let sdkRootCache = ThreadSafeBox<AbsolutePath>()

    private let useInMemoryCache: Bool
    private let memoryCache = ThreadSafeKeyValueStore<CacheKey, ManifestJSONParser.Result>()

    /// DispatchSemaphore to restrict concurrent manifest evaluations
    private let concurrencySemaphore: DispatchSemaphore
    /// OperationQueue to park pending lookups
    private let evaluationQueue: OperationQueue

    public init(
        toolchain: UserToolchain,
        serializedDiagnostics: Bool = false,
        isManifestSandboxEnabled: Bool = true,
        useInMemoryCache: Bool = true,
        cacheDir: AbsolutePath? = .none,
        extraManifestFlags: [String]? = .none,
        importRestrictions: (startingToolsVersion: ToolsVersion, allowedImports: [String])? = .none,
        delegate: Delegate? = .none
    ) {
        self.toolchain = toolchain
        self.serializedDiagnostics = serializedDiagnostics
        self.isManifestSandboxEnabled = isManifestSandboxEnabled
        self.extraManifestFlags = extraManifestFlags ?? []
        self.importRestrictions = importRestrictions

        self.delegate = delegate

        self.useInMemoryCache = useInMemoryCache
        self.databaseCacheDir = try? cacheDir.map(resolveSymlinks)

        // this queue and semaphore is used to limit the amount of concurrent manifest loading taking place
        self.evaluationQueue = OperationQueue()
        self.evaluationQueue.name = "org.swift.swiftpm.manifest-loader"
        self.evaluationQueue.maxConcurrentOperationCount = Concurrency.maxOperations
        self.concurrencySemaphore = DispatchSemaphore(value: Concurrency.maxOperations)
    }
    
    public func load(
        manifestPath: AbsolutePath,
        manifestToolsVersion: ToolsVersion,
        packageIdentity: PackageIdentity,
        packageKind: PackageReference.Kind,
        packageLocation: String,
        packageVersion: (version: Version?, revision: String?)?,
        identityResolver: IdentityResolver,
        dependencyMapper: DependencyMapper,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope,
        delegateQueue: DispatchQueue,
        callbackQueue: DispatchQueue
    ) async throws -> Manifest {
        try await safe_async {
            self.load(
                manifestPath: manifestPath,
                manifestToolsVersion: manifestToolsVersion,
                packageIdentity: packageIdentity,
                packageKind: packageKind,
                packageLocation: packageLocation,
                packageVersion: packageVersion,
                identityResolver: identityResolver,
                dependencyMapper: dependencyMapper,
                fileSystem: fileSystem,
                observabilityScope: observabilityScope,
                delegateQueue: delegateQueue, 
                callbackQueue: callbackQueue,
                completion: $0
            )
        }
    }
    
    @available(*, noasync, message: "Use the async alternative")
    public func load(
        manifestPath: AbsolutePath,
        manifestToolsVersion: ToolsVersion,
        packageIdentity: PackageIdentity,
        packageKind: PackageReference.Kind,
        packageLocation: String,
        packageVersion: (version: Version?, revision: String?)?,
        identityResolver: IdentityResolver,
        dependencyMapper: DependencyMapper,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope,
        delegateQueue: DispatchQueue,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Manifest, Error>) -> Void
    ) {
        // Inform the delegate.
        let start = DispatchTime.now()
        delegateQueue.async {
            self.delegate?.willLoad(
                packageIdentity: packageIdentity,
                packageLocation: packageLocation,
                manifestPath: manifestPath
            )
        }

        // Validate that the file exists.
        guard fileSystem.isFile(manifestPath) else {
            return callbackQueue.async {
                completion(.failure(PackageModel.Package.Error.noManifest(at: manifestPath, version: packageVersion?.version)))
            }
        }

        self.loadAndCacheManifest(
            at: manifestPath,
            toolsVersion: manifestToolsVersion,
            packageIdentity: packageIdentity,
            packageKind: packageKind,
            packageLocation: packageLocation,
            packageVersion: packageVersion?.version,
            identityResolver: identityResolver,
            dependencyMapper: dependencyMapper,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope,
            delegate: delegate,
            delegateQueue: delegateQueue,
            callbackQueue: callbackQueue
        ) { parseResult in
            do {
                dispatchPrecondition(condition: .onQueue(callbackQueue))

                let parsedManifest = try parseResult.get()
                // Convert legacy system packages to the current target‐based model.
                var products = parsedManifest.products
                var targets = parsedManifest.targets
                if products.isEmpty, targets.isEmpty,
                   fileSystem.isFile(manifestPath.parentDirectory.appending(component: moduleMapFilename)) {
                    try products.append(ProductDescription(
                        name: parsedManifest.name,
                        type: .library(.automatic),
                        targets: [parsedManifest.name])
                    )
                    targets.append(try TargetDescription(
                        name: parsedManifest.name,
                        path: "",
                        type: .system,
                        packageAccess: false,
                        pkgConfig: parsedManifest.pkgConfig,
                        providers: parsedManifest.providers
                    ))
                }

                let manifest = Manifest(
                    displayName: parsedManifest.name,
                    path: manifestPath,
                    packageKind: packageKind,
                    packageLocation: packageLocation,
                    defaultLocalization: parsedManifest.defaultLocalization,
                    platforms: parsedManifest.platforms,
                    version: packageVersion?.version,
                    revision: packageVersion?.revision,
                    toolsVersion: manifestToolsVersion,
                    pkgConfig: parsedManifest.pkgConfig,
                    providers: parsedManifest.providers,
                    cLanguageStandard: parsedManifest.cLanguageStandard,
                    cxxLanguageStandard: parsedManifest.cxxLanguageStandard,
                    swiftLanguageVersions: parsedManifest.swiftLanguageVersions,
                    dependencies: parsedManifest.dependencies,
                    products: products,
                    targets: targets,
                    traits: parsedManifest.traits
                )

                // Inform the delegate.
                delegateQueue.async {
                    self.delegate?.didLoad(
                        packageIdentity: packageIdentity,
                        packageLocation: packageLocation,
                        manifestPath: manifestPath,
                        duration: start.distance(to: .now())
                    )
                }

                completion(.success(manifest))
            } catch {
                callbackQueue.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Load the JSON string for the given manifest.
    private func parseManifest(
        _ result: EvaluationResult,
        packageIdentity: PackageIdentity,
        packageKind: PackageReference.Kind,
        packagePath: AbsolutePath,
        packageLocation: String,
        toolsVersion: ToolsVersion,
        identityResolver: IdentityResolver,
        dependencyMapper: DependencyMapper,
        fileSystem: FileSystem,
        emitCompilerOutput: Bool,
        observabilityScope: ObservabilityScope,
        delegate: Delegate?,
        delegateQueue: DispatchQueue?
    ) throws -> ManifestJSONParser.Result {
        // Throw now if we weren't able to parse the manifest.
        guard let manifestJSON = result.manifestJSON, !manifestJSON.isEmpty else {
            let errors = result.errorOutput ?? result.compilerOutput ?? "Missing or empty JSON output from manifest compilation for \(packageIdentity)"
            throw ManifestParseError.invalidManifestFormat(errors, diagnosticFile: result.diagnosticFile, compilerCommandLine: result.compilerCommandLine)
        }

        // We should not have any fatal error at this point.
        guard result.errorOutput == nil else {
            throw InternalError("unexpected error output: \(result.errorOutput!)")
        }

        // We might have some non-fatal output (warnings/notes) from the compiler even when
        // we were able to parse the manifest successfully.
        if emitCompilerOutput, let compilerOutput = result.compilerOutput {
            let metadata = result.diagnosticFile.map { diagnosticFile -> ObservabilityMetadata in
                var metadata = ObservabilityMetadata()
                metadata.manifestLoadingDiagnosticFile = diagnosticFile
                return metadata
            }
            observabilityScope.emit(warning: compilerOutput, metadata: metadata)
        }

        let start = DispatchTime.now()
        delegateQueue?.async {
            delegate?.willParse(
                packageIdentity: packageIdentity,
                packageLocation: packageLocation
            )
        }

        let result = try ManifestJSONParser.parse(
            v4: manifestJSON,
            toolsVersion: toolsVersion,
            packageKind: packageKind,
            packagePath: packagePath,
            identityResolver: identityResolver,
            dependencyMapper: dependencyMapper,
            fileSystem: fileSystem
        )
        delegateQueue?.async {
            delegate?.didParse(
                packageIdentity: packageIdentity,
                packageLocation: packageLocation,
                duration: start.distance(to: .now())
            )
        }
        return result
    }

    private func loadAndCacheManifest(
        at path: AbsolutePath,
        toolsVersion: ToolsVersion,
        packageIdentity: PackageIdentity,
        packageKind: PackageReference.Kind,
        packageLocation: String,
        packageVersion: Version?,
        identityResolver: IdentityResolver,
        dependencyMapper: DependencyMapper,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope,
        delegate: Delegate?,
        delegateQueue: DispatchQueue?,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<ManifestJSONParser.Result, Error>) -> Void
    ) {
        // put callback on right queue
        var completion = completion
        do {
            let previousCompletion = completion
            completion = { result in callbackQueue.async { previousCompletion(result) } }
        }

        let key : CacheKey
        do {
            key = try CacheKey(
                packageIdentity: packageIdentity,
                packageLocation: packageLocation,
                manifestPath: path,
                toolsVersion: toolsVersion,
                env: Environment.current.cachable,
                swiftpmVersion: SwiftVersion.current.displayString,
                fileSystem: fileSystem
            )
        } catch {
            return completion(.failure(error))
        }

        // try from in-memory cache
        if self.useInMemoryCache, let parsedManifest = self.memoryCache[key] {
            observabilityScope.emit(debug: "loading manifest for '\(packageIdentity)' v. \(packageVersion?.description ?? "unknown") from memory cache")
            return completion(.success(parsedManifest))
        }

        // make sure callback record results in-memory
        do {
            let previousCompletion = completion
            completion = { result in
                if self.useInMemoryCache, case .success(let parsedManifest) = result {
                    self.memoryCache[key] = parsedManifest
                }
                previousCompletion(result)
            }
        }

        // initialize db cache
        let dbCache = self.databaseCacheDir.map { cacheDir in
            let path = Self.manifestCacheDBPath(cacheDir)
            var configuration = SQLiteBackedCacheConfiguration()
            // FIXME: expose as user-facing configuration
            configuration.maxSizeInMegabytes = 100
            configuration.truncateWhenFull = true
            return SQLiteBackedCache<EvaluationResult>(
                tableName: "MANIFEST_CACHE",
                location: .path(path),
                configuration: configuration
            )
        }

        // make sure callback closes db cache
        do {
            let previousCompletion = completion
            completion = { result in
                do {
                    try dbCache?.close()
                } catch {
                    observabilityScope.emit(
                        warning: "failed closing manifest db cache",
                        underlyingError: error
                    )
                }
                previousCompletion(result)
            }
        }

        do {
            // try to get it from the cache
            if let evaluationResult = try dbCache?.get(key: key.sha256Checksum), let manifestJSON = evaluationResult.manifestJSON, !manifestJSON.isEmpty {
                observabilityScope.emit(debug: "loading manifest for '\(packageIdentity)' v. \(packageVersion?.description ?? "unknown") from db cache")
                let parsedManifest = try self.parseManifest(
                    evaluationResult,
                    packageIdentity: packageIdentity,
                    packageKind: packageKind,
                    packagePath: path.parentDirectory,
                    packageLocation: packageLocation,
                    toolsVersion: toolsVersion,
                    identityResolver: identityResolver,
                    dependencyMapper: dependencyMapper,
                    fileSystem: fileSystem,
                    emitCompilerOutput: false,
                    observabilityScope: observabilityScope,
                    delegate: delegate,
                    delegateQueue: delegateQueue
                )
                return completion(.success(parsedManifest))
            }
        } catch {
            observabilityScope.emit(
                warning: "failed loading cached manifest for '\(key.packageIdentity)'",
                underlyingError: error
            )
        }

        // shells out and compiles the manifest, finally output a JSON
        observabilityScope.emit(debug: "evaluating manifest for '\(packageIdentity)' v. \(packageVersion?.description ?? "unknown")")
        do {
            try self.evaluateManifest(
                packageIdentity: key.packageIdentity,
                packageLocation: packageLocation,
                manifestPath: key.manifestPath,
                manifestContents: key.manifestContents,
                toolsVersion: key.toolsVersion,
                observabilityScope: observabilityScope,
                delegate: delegate,
                delegateQueue: delegateQueue,
                callbackQueue: callbackQueue
            ) { result in
                dispatchPrecondition(condition: .onQueue(callbackQueue))

                do {
                    let evaluationResult = try result.get()
                    // only cache successfully parsed manifests
                    let parsedManifest = try self.parseManifest(
                        evaluationResult,
                        packageIdentity: packageIdentity,
                        packageKind: packageKind,
                        packagePath: path.parentDirectory,
                        packageLocation: packageLocation,
                        toolsVersion: toolsVersion,
                        identityResolver: identityResolver,
                        dependencyMapper: dependencyMapper,
                        fileSystem: fileSystem,
                        emitCompilerOutput: true,
                        observabilityScope: observabilityScope,
                        delegate: delegate,
                        delegateQueue: delegateQueue
                    )

                    do {
                        self.memoryCache[key] = parsedManifest
                        try dbCache?.put(key: key.sha256Checksum, value: evaluationResult, observabilityScope: observabilityScope)
                    } catch {
                        observabilityScope.emit(
                            warning: "failed storing manifest for '\(key.packageIdentity)' in cache",
                            underlyingError: error
                        )
                    }

                    return completion(.success(parsedManifest))
                } catch {
                    return completion(.failure(error))
                }
            }
        } catch {
            return completion(.failure(error))
        }
    }

    private func validateImports(
        manifestPath: AbsolutePath,
        toolsVersion: ToolsVersion,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Void, Error>) -> Void) {
            // If there are no import restrictions, we do not need to validate.
            guard let importRestrictions = self.importRestrictions, toolsVersion >= importRestrictions.startingToolsVersion else {
                return callbackQueue.async {
                    completion(.success(()))
                }
            }

            // Allowed are the expected defaults, plus anything allowed by the configured restrictions.
            let allowedImports = ["PackageDescription", "Swift",
                                  "SwiftOnoneSupport", "_SwiftConcurrencyShims"] + importRestrictions.allowedImports

            // wrap the completion to free concurrency control semaphore
            let completion: (Result<Void, Error>) -> Void = { result in
                self.concurrencySemaphore.signal()
                callbackQueue.async {
                    completion(result)
                }
            }

            // we must not block the calling thread (for concurrency control) so nesting this in a queue
            self.evaluationQueue.addOperation {
                // park the evaluation thread based on the max concurrency allowed
                self.concurrencySemaphore.wait()

                let importScanner = SwiftcImportScanner(swiftCompilerEnvironment: self.toolchain.swiftCompilerEnvironment,
                                                        swiftCompilerFlags: self.extraManifestFlags,
                                                        swiftCompilerPath: self.toolchain.swiftCompilerPathForManifests)

                Task {
                    let result = try await importScanner.scanImports(manifestPath)
                    let imports = result.filter { !allowedImports.contains($0) }
                    guard imports.isEmpty else {
                        callbackQueue.async {
                            completion(.failure(ManifestParseError.importsRestrictedModules(imports)))
                        }
                        return
                    }
                }
            }
        }

    /// Compiler the manifest at the given path and retrieve the JSON.
    fileprivate func evaluateManifest(
        packageIdentity: PackageIdentity,
        packageLocation: String,
        manifestPath: AbsolutePath,
        manifestContents: [UInt8],
        toolsVersion: ToolsVersion,
        observabilityScope: ObservabilityScope,
        delegate: Delegate?,
        delegateQueue: DispatchQueue?,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<EvaluationResult, Error>) -> Void
    ) throws {
        let manifestPreamble: ByteString
        if toolsVersion >= .v5_8 {
            manifestPreamble = ByteString()
        } else {
            manifestPreamble = ByteString("import Foundation\n")
        }

        do {
            try withTemporaryDirectory { tempDir, cleanupTempDir in
                let manifestTempFilePath = tempDir.appending("manifest.swift")
                try localFileSystem.writeFileContents(manifestTempFilePath, bytes: ByteString(manifestPreamble.contents + manifestContents))

                let vfsOverlayTempFilePath = tempDir.appending("vfs.yaml")
                try VFSOverlay(roots: [
                    VFSOverlay.File(
                        name: manifestPath._normalized.replacingOccurrences(of: #"\"#, with: #"\\"#),
                        externalContents: manifestTempFilePath._nativePathString(escaped: true)
                    )
                ]).write(to: vfsOverlayTempFilePath, fileSystem: localFileSystem)

                validateImports(
                    manifestPath: manifestTempFilePath,
                    toolsVersion: toolsVersion,
                    callbackQueue: callbackQueue
                ) { result in
                    dispatchPrecondition(condition: .onQueue(callbackQueue))

                    do {
                        try result.get()

                        try self.evaluateManifest(
                            at: manifestPath,
                            vfsOverlayPath: vfsOverlayTempFilePath,
                            packageIdentity: packageIdentity,
                            packageLocation: packageLocation,
                            toolsVersion: toolsVersion,
                            observabilityScope: observabilityScope,
                            delegate: delegate,
                            delegateQueue: delegateQueue,
                            callbackQueue: callbackQueue
                        ) { result in
                            dispatchPrecondition(condition: .onQueue(callbackQueue))
                            cleanupTempDir(tempDir)
                            completion(result)
                        }
                    } catch {
                        cleanupTempDir(tempDir)
                        callbackQueue.async {
                            completion(.failure(error))
                        }
                    }
                }
            }
        } catch {
            callbackQueue.async {
                completion(.failure(error))
            }
        }
    }

    /// Helper method for evaluating the manifest.
    func evaluateManifest(
        at manifestPath: AbsolutePath,
        vfsOverlayPath: AbsolutePath? = nil,
        packageIdentity: PackageIdentity,
        packageLocation: String,
        toolsVersion: ToolsVersion,
        observabilityScope: ObservabilityScope,
        delegate: Delegate?,
        delegateQueue: DispatchQueue?,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<EvaluationResult, Error>) -> Void
    ) throws {
        // The compiler has special meaning for files with extensions like .ll, .bc etc.
        // Assert that we only try to load files with extension .swift to avoid unexpected loading behavior.
        guard manifestPath.extension == "swift" else {
            return callbackQueue.async {
                completion(.failure(InternalError("Manifest files must contain .swift suffix in their name, given: \(manifestPath).")))
            }
        }

        var evaluationResult = EvaluationResult()

        // For now, we load the manifest by having Swift interpret it directly.
        // Eventually, we should have two loading processes, one that loads only
        // the declarative package specification using the Swift compiler directly
        // and validates it.

        // Compute the path to runtime we need to load.
        let runtimePath = self.toolchain.swiftPMLibrariesLocation.manifestLibraryPath

        // FIXME: Workaround for the module cache bug that's been haunting Swift CI
        // <rdar://problem/48443680>
        let moduleCachePath = try (
            Environment.current["SWIFTPM_MODULECACHE_OVERRIDE"] ??
            Environment.current["SWIFTPM_TESTS_MODULECACHE"]).flatMap { try AbsolutePath(validating: $0) }

        var cmd: [String] = []
        cmd += [self.toolchain.swiftCompilerPathForManifests.pathString]

        if let vfsOverlayPath {
            cmd += ["-vfsoverlay", vfsOverlayPath.pathString]
        }

        // if runtimePath is set to "PackageFrameworks" that means we could be developing SwiftPM in Xcode
        // which produces a framework for dynamic package products.
        if runtimePath.extension == "framework" {
            cmd += [
                "-F", runtimePath.parentDirectory.pathString,
                "-framework", "PackageDescription",
                "-Xlinker", "-rpath", "-Xlinker", runtimePath.parentDirectory.pathString,
            ]
        } else {
            cmd += [
                "-L", runtimePath.pathString,
                "-lPackageDescription",
            ]
#if !os(Windows)
            // -rpath argument is not supported on Windows,
            // so we add runtimePath to PATH when executing the manifest instead
            cmd += ["-Xlinker", "-rpath", "-Xlinker", runtimePath.pathString]
#endif
        }

        // Use the same minimum deployment target as the PackageDescription library (with a fallback to the default host triple).
#if os(macOS)
        if let version = self.toolchain.swiftPMLibrariesLocation.manifestLibraryMinimumDeploymentTarget?.versionString {
            cmd += ["-target", "\(self.toolchain.targetTriple.tripleString(forPlatformVersion: version))"]
        } else {
            cmd += ["-target", self.toolchain.targetTriple.tripleString]
        }
#endif

        // Add any extra flags required as indicated by the ManifestLoader.
        cmd += self.toolchain.swiftCompilerFlags

        cmd += self.interpreterFlags(for: toolsVersion)
        if let moduleCachePath {
            cmd += ["-module-cache-path", moduleCachePath.pathString]
        }

        // Add the arguments for emitting serialized diagnostics, if requested.
        if self.serializedDiagnostics, let databaseCacheDir = self.databaseCacheDir {
            let diaDir = databaseCacheDir.appending("ManifestLoading")
            let diagnosticFile = diaDir.appending("\(packageIdentity).dia")
            do {
                try localFileSystem.createDirectory(diaDir, recursive: true)
                cmd += ["-Xfrontend", "-serialize-diagnostics-path", "-Xfrontend", diagnosticFile.pathString]
                evaluationResult.diagnosticFile = diagnosticFile
            } catch {
                return callbackQueue.async {
                    completion(.failure(error))
                }
            }
        }

        cmd += [manifestPath._normalized]

        cmd += self.extraManifestFlags

        // wrap the completion to free concurrency control semaphore
        let completion: (Result<EvaluationResult, Error>) -> Void = { result in
            self.concurrencySemaphore.signal()
            completion(result)
        }

        // we must not block the calling thread (for concurrency control) so nesting this in a queue
        self.evaluationQueue.addOperation {
            do {
                // park the evaluation thread based on the max concurrency allowed
                self.concurrencySemaphore.wait()
                // run the evaluation
                let compileStart = DispatchTime.now()
                delegateQueue?.async {
                    delegate?.willCompile(
                        packageIdentity: packageIdentity,
                        packageLocation: packageLocation,
                        manifestPath: manifestPath
                    )
                }
                try withTemporaryDirectory { tmpDir, cleanupTmpDir in
                    // Set path to compiled manifest executable.
                    #if os(Windows)
                    let executableSuffix = ".exe"
                    #else
                    let executableSuffix = ""
                    #endif
                    let compiledManifestFile = tmpDir.appending("\(packageIdentity)-manifest\(executableSuffix)")
                    cmd += ["-o", compiledManifestFile.pathString]

                    evaluationResult.compilerCommandLine = cmd

                    // Compile the manifest.
                    AsyncProcess.popen(
                        arguments: cmd,
                        environment: self.toolchain.swiftCompilerEnvironment,
                        queue: callbackQueue
                    ) { result in
                        dispatchPrecondition(condition: .onQueue(callbackQueue))

                        var cleanupIfError = DelayableAction(target: tmpDir, action: cleanupTmpDir)
                        defer { cleanupIfError.perform() }

                        let compilerResult: AsyncProcessResult
                        do {
                            compilerResult = try result.get()
                            evaluationResult.compilerOutput = try (compilerResult.utf8Output() + compilerResult.utf8stderrOutput()).spm_chuzzle()
                        } catch {
                            return completion(.failure(error))
                        }

                        // Return now if there was an error.
                        if compilerResult.exitStatus != .terminated(code: 0) {
                            return completion(.success(evaluationResult))
                        }

                        // Pass an open file descriptor of a file to which the JSON representation of the manifest will be written.
                        let jsonOutputFile = tmpDir.appending("\(packageIdentity)-output.json")
                        guard let jsonOutputFileDesc = fopen(jsonOutputFile.pathString, "w") else {
                            return completion(.failure(StringError("couldn't create the manifest's JSON output file")))
                        }

                        cmd = [compiledManifestFile.pathString]
                        #if os(Windows)
                        // NOTE: `_get_osfhandle` returns a non-owning, unsafe,
                        // unretained HANDLE.  DO NOT invoke `CloseHandle` on `hFile`.
                        let hFile: Int = _get_osfhandle(_fileno(jsonOutputFileDesc))
                        cmd += ["-handle", "\(String(hFile, radix: 16))"]
                        #else
                        cmd += ["-fileno", "\(fileno(jsonOutputFileDesc))"]
                        #endif

                        do {
                            let packageDirectory = manifestPath.parentDirectory.pathString

                            let gitInformation: ContextModel.GitInformation?
                            do {
                                let repo = GitRepository(path: manifestPath.parentDirectory)
                                gitInformation = ContextModel.GitInformation(
                                    currentTag: repo.getCurrentTag(),
                                    currentCommit: try repo.getCurrentRevision().identifier,
                                    hasUncommittedChanges: repo.hasUncommittedChanges()
                                )
                            } catch {
                                gitInformation = nil
                            }

                            let contextModel = ContextModel(
                                packageDirectory: packageDirectory,
                                gitInformation: gitInformation
                            )
                            cmd += ["-context", try contextModel.encode()]
                        } catch {
                            return completion(.failure(error))
                        }

                        // If enabled, run command in a sandbox.
                        // This provides some safety against arbitrary code execution when parsing manifest files.
                        // We only allow the permissions which are absolutely necessary.
                        if self.isManifestSandboxEnabled {
                            let cacheDirectories = [self.databaseCacheDir?.appending("ManifestLoading"), moduleCachePath].compactMap{ $0 }
                            let strictness: Sandbox.Strictness = toolsVersion < .v5_3 ? .manifest_pre_53 : .default
                            do {
                                cmd = try Sandbox.apply(command: cmd, fileSystem: localFileSystem, strictness: strictness, writableDirectories: cacheDirectories)
                            } catch {
                                return completion(.failure(error))
                            }
                        }

                        delegateQueue?.async {
                            delegate?.didCompile(
                                packageIdentity: packageIdentity,
                                packageLocation: packageLocation,
                                manifestPath: manifestPath,
                                duration: compileStart.distance(to: .now())
                            )
                        }

                        // Run the compiled manifest.

                        let evaluationStart = DispatchTime.now()
                        delegateQueue?.async {
                            delegate?.willEvaluate(
                                packageIdentity: packageIdentity,
                                packageLocation: packageLocation,
                                manifestPath: manifestPath
                            )
                        }

                        var environment = Environment.current
                        #if os(Windows)
                        let windowsPathComponent = runtimePath.pathString.replacingOccurrences(of: "/", with: "\\")
                        environment["Path"] = "\(windowsPathComponent);\(environment["Path"] ?? "")"
                        #endif

                        let cleanupAfterRunning = cleanupIfError.delay()
                        AsyncProcess.popen(
                            arguments: cmd,
                            environment: environment,
                            queue: callbackQueue
                        ) { result in
                            dispatchPrecondition(condition: .onQueue(callbackQueue))

                            defer { cleanupAfterRunning.perform() }
                            fclose(jsonOutputFileDesc)

                            do {
                                let runResult = try result.get()
                                if let runOutput = try (runResult.utf8Output() + runResult.utf8stderrOutput()).spm_chuzzle() {
                                    // Append the runtime output to any compiler output we've received.
                                    evaluationResult.compilerOutput = (evaluationResult.compilerOutput ?? "") + runOutput
                                }

                                // Return now if there was an error.
                                if runResult.exitStatus != .terminated(code: 0) {
                                    // TODO: should this simply be an error?
                                    // return completion(.failure(AsyncProcessResult.Error.nonZeroExit(runResult)))
                                    evaluationResult.errorOutput = evaluationResult.compilerOutput
                                    return completion(.success(evaluationResult))
                                }

                                // Read the JSON output that was emitted by libPackageDescription.
                                let jsonOutput: String = try localFileSystem.readFileContents(jsonOutputFile)
                                evaluationResult.manifestJSON = jsonOutput

                                delegateQueue?.async {
                                    delegate?.didEvaluate(
                                        packageIdentity: packageIdentity,
                                        packageLocation: packageLocation,
                                        manifestPath: manifestPath,
                                        duration: evaluationStart.distance(to: .now())
                                    )
                                }

                                completion(.success(evaluationResult))
                            } catch {
                                completion(.failure(error))
                            }
                        }
                    }
                }
            } catch {
                return callbackQueue.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Returns path to the sdk, if possible.
    private func sdkRoot() -> AbsolutePath? {
        if let sdkRoot = self.sdkRootCache.get() {
            return sdkRoot
        }

        var sdkRootPath: AbsolutePath? = nil
        // Find SDKROOT on macOS using xcrun.
        #if os(macOS)
        let foundPath = try? AsyncProcess.checkNonZeroExit(
            args: "/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path")
        guard let sdkRoot = foundPath?.spm_chomp(), !sdkRoot.isEmpty else {
            return nil
        }
        if let path = try? AbsolutePath(validating: sdkRoot) {
            sdkRootPath = path
            self.sdkRootCache.put(path)
        }
        #endif

        return sdkRootPath
    }

    /// Returns the interpreter flags for a manifest.
    public func interpreterFlags(
        for toolsVersion: ToolsVersion
    ) -> [String] {
        var cmd = [String]()
        let modulesPath = self.toolchain.swiftPMLibrariesLocation.manifestModulesPath
        cmd += ["-swift-version", toolsVersion.swiftLanguageVersion.rawValue]
        // if runtimePath is set to "PackageFrameworks" that means we could be developing SwiftPM in Xcode
        // which produces a framework for dynamic package products.
        if modulesPath.extension == "framework" {
            cmd += ["-I", modulesPath.parentDirectory.parentDirectory.pathString]
        } else {
            cmd += ["-I", modulesPath.pathString]
        }
      #if os(macOS)
        if let sdkRoot = self.toolchain.sdkRootPath ?? self.sdkRoot() {
            cmd += ["-sdk", sdkRoot.pathString]
        }
      #endif
        cmd += ["-package-description-version", toolsVersion.description]
        return cmd
    }

    /// Returns path to the manifest database inside the given cache directory.
    private static func manifestCacheDBPath(_ cacheDir: AbsolutePath) -> AbsolutePath {
        return cacheDir.appending("manifest.db")
    }

    /// reset internal cache
    public func resetCache(observabilityScope: ObservabilityScope) {
        self.memoryCache.clear()
    }

    /// reset internal state and purge shared cache
    public func purgeCache(observabilityScope: ObservabilityScope) {
        self.resetCache(observabilityScope: observabilityScope)

        guard let manifestCacheDBPath = self.databaseCacheDir.flatMap({ Self.manifestCacheDBPath($0) }) else {
            return
        }

        guard localFileSystem.exists(manifestCacheDBPath) else {
            return
        }

        do {
            try localFileSystem.removeFileTree(manifestCacheDBPath)
        } catch {
            observabilityScope.emit(
                error: "Error purging manifests cache at '\(manifestCacheDBPath)'",
                underlyingError: error
            )
        }
    }
}

extension ManifestLoader {
    struct CacheKey: Hashable {
        let packageIdentity: PackageIdentity
        let manifestPath: AbsolutePath
        let manifestContents: [UInt8]
        let toolsVersion: ToolsVersion
        let env: Environment
        let swiftpmVersion: String
        let sha256Checksum: String

        init (packageIdentity: PackageIdentity,
              packageLocation: String,
              manifestPath: AbsolutePath,
              toolsVersion: ToolsVersion,
              env: Environment,
              swiftpmVersion: String,
              fileSystem: FileSystem
        ) throws {
            let manifestContents = try fileSystem.readFileContents(manifestPath).contents
            let sha256Checksum = try Self.computeSHA256Checksum(
                packageIdentity: packageIdentity,
                packageLocation: packageLocation,
                manifestContents: manifestContents,
                toolsVersion: toolsVersion,
                env: env,
                swiftpmVersion: swiftpmVersion
            )

            self.packageIdentity = packageIdentity
            self.manifestPath = manifestPath
            self.manifestContents = manifestContents
            self.toolsVersion = toolsVersion
            self.env = env
            self.swiftpmVersion = swiftpmVersion
            self.sha256Checksum = sha256Checksum
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(self.sha256Checksum)
        }

        private static func computeSHA256Checksum(
            packageIdentity: PackageIdentity,
            packageLocation: String,
            manifestContents: [UInt8],
            toolsVersion: ToolsVersion,
            env: Environment,
            swiftpmVersion: String
        ) throws -> String {
            let stream = BufferedOutputByteStream()
            stream.send(packageIdentity)
            stream.send(packageLocation)
            stream.send(manifestContents)
            stream.send(toolsVersion.description)
            for (key, value) in env.sorted(by: { $0.key > $1.key }) {
                stream.send(key.rawValue).send(value)
            }
            stream.send(swiftpmVersion)
            return stream.bytes.sha256Checksum
        }
    }
}

extension ManifestLoader {
    struct EvaluationResult: Codable {
        /// The path to the diagnostics file (.dia).
        ///
        /// This is only present if serialized diagnostics are enabled.
        var diagnosticFile: AbsolutePath?

        /// The output from compiler, if any.
        ///
        /// This would contain the errors and warnings produced when loading the manifest file.
        var compilerOutput: String?

        /// The manifest in JSON format.
        var manifestJSON: String?

        /// The command line used to compile the manifest
        var compilerCommandLine: [String]?

        /// Any non-compiler error that might have occurred during manifest loading.
        ///
        /// For e.g., we could have failed to spawn the process or create temporary file.
        var errorOutput: String? {
            didSet {
                assert(self.manifestJSON == nil)
            }
        }

        var hasErrors: Bool {
            return self.manifestJSON == nil
        }
    }
}

extension ManifestLoader {
    /// Represents behavior that can be deferred until a more appropriate time.
    struct DelayableAction<T> {
        var target: T?
        var action: ((T) -> Void)?

        func perform() {
            if let value = target, let cleanup = action {
                cleanup(value)
            }
        }

        mutating func delay() -> DelayableAction {
            let next = DelayableAction(target: target, action: action)
            target = nil
            action = nil
            return next
        }
    }
}
