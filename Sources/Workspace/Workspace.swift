//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import _Concurrency
import Basics
import Foundation
import PackageFingerprint
import PackageGraph
import PackageLoading
import PackageModel
import PackageRegistry
import PackageSigning
import SourceControl

import func TSCBasic.findCycle
import protocol TSCBasic.HashAlgorithm
import class TSCBasic.InMemoryFileSystem
import struct TSCBasic.KeyedPair
import struct TSCBasic.SHA256
import var TSCBasic.stderrStream
import func TSCBasic.topologicalSort
import func TSCBasic.transitiveClosure

import enum TSCUtility.Diagnostics
import struct TSCUtility.Version

/// Enumeration of the different reasons for which the resolver needs to be run.
public enum WorkspaceResolveReason: Equatable {
    /// Resolution was forced.
    case forced

    /// Requirements were added for new packages.
    case newPackages(packages: [PackageReference])

    /// The requirement of a dependency has changed.
    case packageRequirementChange(
        package: PackageReference,
        state: Workspace.ManagedDependency.State?,
        requirement: PackageRequirement
    )

    /// An unknown reason.
    case other(String)

    /// Errors previously reported, e.g. during cloning. This will skip emitting additional unhelpful diagnostics.
    case errorsPreviouslyReported
}

public struct PackageFetchDetails {
    /// Indicates if the package was fetched from the cache or from the remote.
    public let fromCache: Bool
    /// Indicates whether the package was already present in the cache and updated or if a clean fetch was
    /// performed.
    public let updatedCache: Bool
}

/// A workspace represents the state of a working project directory.
///
/// The workspace is responsible for managing the persistent working state of a
/// project directory (e.g., the active set of checked out repositories) and for
/// coordinating the changes to that state.
///
/// This class glues together the basic facilities provided by the dependency
/// resolution, source control, and package graph loading subsystems into a
/// cohesive interface for exposing the high-level operations for the package
/// manager to maintain working package directories.
///
/// This class does *not* support concurrent operations.
public class Workspace {
    public typealias Delegate = WorkspaceDelegate

    /// The delegate interface.
    private(set) weak var delegate: Delegate?

    /// The workspace location.
    public let location: Location

    /// The mirrors config.
    let mirrors: DependencyMirrors

    /// The current persisted state of the workspace.
    // public visibility for testing
    public let state: WorkspaceState

    /// The Pins store. The pins file will be created when first pin is added to pins store.
    // public visibility for testing
    public let pinsStore: LoadableResult<PinsStore>

    /// The file system on which the workspace will operate.
    package let fileSystem: any FileSystem

    /// The host toolchain to use.
    private let hostToolchain: UserToolchain

    /// The manifest loader to use.
    let manifestLoader: ManifestLoaderProtocol

    /// The tools version currently in use.
    let currentToolsVersion: ToolsVersion

    /// Utility to resolve package identifiers
    // var for backwards compatibility with deprecated initializers, remove with them
    let identityResolver: IdentityResolver

    /// Utility to map dependencies
    let dependencyMapper: DependencyMapper

    /// The custom package container provider used by this workspace, if any.
    let customPackageContainerProvider: PackageContainerProvider?

    /// The package container provider used by this workspace.
    var packageContainerProvider: PackageContainerProvider {
        self.customPackageContainerProvider ?? self
    }

    /// Source control repository manager used for interacting with source control based dependencies
    let repositoryManager: RepositoryManager

    /// The registry manager.
    let registryClient: RegistryClient

    /// Registry based dependencies downloads manager used for interacting with registry based dependencies
    let registryDownloadsManager: RegistryDownloadsManager

    /// Binary artifacts manager used for downloading and extracting binary artifacts
    let binaryArtifactsManager: BinaryArtifactsManager

    /// The package fingerprints storage
    let fingerprints: PackageFingerprintStorage?

    /// The workspace configuration settings
    let configuration: WorkspaceConfiguration

    // MARK: State

    /// The active package resolver. This is set during a dependency resolution operation.
    var activeResolver: PubGrubDependencyResolver?

    var resolvedFileWatcher: ResolvedFileWatcher?

    /// Create a new package workspace.
    ///
    /// This initializer is designed for use cases when the workspace needs to be highly customized such as testing.
    /// In other cases, use the other, more straight forward, initializers
    ///
    /// This will automatically load the persisted state for the package, if
    /// present. If the state isn't present then a default state will be
    /// constructed.
    ///
    /// - Parameters:
    ///   - fileSystem: The file system to use.
    ///   - location: Workspace location configuration.
    ///   - authorizationProvider: Provider of authentication information for outbound network requests.
    ///   - registryAuthorizationProvider: Provider of authentication information for registry requests.
    ///   - configuration: Configuration to fine tune the dependency resolution behavior.
    ///   - cancellator: Cancellation handler
    ///   - initializationWarningHandler: Initialization warnings handler
    ///   - customHostToolchain: Custom host toolchain. Used to create a customized ManifestLoader, customizing how
    /// manifest are loaded.
    ///   - customManifestLoader: Custom manifest loader. Used to customize how manifest are loaded.
    ///   - customPackageContainerProvider: Custom package container provider. Used to provide specialized package
    /// providers.
    ///   - customRepositoryProvider: Custom repository provider. Used to customize source control access.
    ///   - delegate: Delegate for workspace events
    public convenience init(
        fileSystem: any FileSystem,
        environment: Environment = .current,
        location: Location,
        authorizationProvider: (any AuthorizationProvider)? = .none,
        registryAuthorizationProvider: (any AuthorizationProvider)? = .none,
        configuration: WorkspaceConfiguration? = .none,
        cancellator: Cancellator? = .none,
        initializationWarningHandler: ((String) -> Void)? = .none,
        // optional customization used for advanced integration situations
        customHostToolchain: UserToolchain? = .none,
        customManifestLoader: (any ManifestLoaderProtocol)? = .none,
        customPackageContainerProvider: (any PackageContainerProvider)? = .none,
        customRepositoryProvider: (any RepositoryProvider)? = .none,
        // delegate
        delegate: Delegate? = .none
    ) throws {
        try self.init(
            fileSystem: fileSystem,
            environment: environment,
            location: location,
            authorizationProvider: authorizationProvider,
            registryAuthorizationProvider: registryAuthorizationProvider,
            configuration: configuration,
            cancellator: cancellator,
            initializationWarningHandler: initializationWarningHandler,
            customRegistriesConfiguration: .none,
            customFingerprints: .none,
            customSigningEntities: .none,
            skipSignatureValidation: false,
            customMirrors: .none,
            customToolsVersion: .none,
            customHostToolchain: customHostToolchain,
            customManifestLoader: customManifestLoader,
            customPackageContainerProvider: customPackageContainerProvider,
            customRepositoryManager: .none,
            customRepositoryProvider: customRepositoryProvider,
            customRegistryClient: .none,
            customBinaryArtifactsManager: .none,
            customIdentityResolver: .none,
            customDependencyMapper: .none,
            customChecksumAlgorithm: .none,
            delegate: delegate
        )
    }

    /// A convenience method for creating a workspace for the given root
    /// package path.
    ///
    /// The root package path is used to compute the build directory and other
    /// default paths.
    ///
    /// - Parameters:
    ///   - fileSystem: The file system to use, defaults to local file system.
    ///   - forRootPackage: The path for the root package.
    ///   - authorizationProvider: Provider of authentication information for outbound network requests.
    ///   - registryAuthorizationProvider: Provider of authentication information for registry requests.
    ///   - configuration: Configuration to fine tune the dependency resolution behavior.
    ///   - cancellator: Cancellation handler
    ///   - initializationWarningHandler: Initialization warnings handler
    ///   - customManifestLoader: Custom manifest loader. Used to customize how manifest are loaded.
    ///   - customPackageContainerProvider: Custom package container provider. Used to provide specialized package
    /// providers.
    ///   - customRepositoryProvider: Custom repository provider. Used to customize source control access.
    ///   - delegate: Delegate for workspace events
    public convenience init(
        fileSystem: FileSystem? = .none,
        environment: Environment = .current,
        forRootPackage packagePath: AbsolutePath,
        authorizationProvider: AuthorizationProvider? = .none,
        registryAuthorizationProvider: AuthorizationProvider? = .none,
        configuration: WorkspaceConfiguration? = .none,
        cancellator: Cancellator? = .none,
        initializationWarningHandler: ((String) -> Void)? = .none,
        // optional customization used for advanced integration situations
        customHostToolchain: UserToolchain? = .none,
        customManifestLoader: ManifestLoaderProtocol? = .none,
        customPackageContainerProvider: PackageContainerProvider? = .none,
        customRepositoryProvider: RepositoryProvider? = .none,
        // delegate
        delegate: Delegate? = .none
    ) throws {
        let fileSystem = fileSystem ?? localFileSystem
        let location = try Location(forRootPackage: packagePath, fileSystem: fileSystem)
        try self.init(
            fileSystem: fileSystem,
            environment: environment,
            location: location,
            authorizationProvider: authorizationProvider,
            registryAuthorizationProvider: registryAuthorizationProvider,
            configuration: configuration,
            cancellator: cancellator,
            initializationWarningHandler: initializationWarningHandler,
            customHostToolchain: customHostToolchain,
            customManifestLoader: customManifestLoader,
            customPackageContainerProvider: customPackageContainerProvider,
            customRepositoryProvider: customRepositoryProvider,
            delegate: delegate
        )
    }

    /// A convenience method for creating a workspace for the given root
    /// package path.
    ///
    /// The root package path is used to compute the build directory and other
    /// default paths.
    ///
    /// - Parameters:
    ///   - fileSystem: The file system to use, defaults to local file system.
    ///   - forRootPackage: The path for the root package.
    ///   - authorizationProvider: Provider of authentication information for outbound network requests.
    ///   - registryAuthorizationProvider: Provider of authentication information for registry requests.
    ///   - configuration: Configuration to fine tune the dependency resolution behavior.
    ///   - cancellator: Cancellation handler
    ///   - initializationWarningHandler: Initialization warnings handler
    ///   - customHostToolchain: Custom host toolchain. Used to create a customized ManifestLoader, customizing how
    /// manifest are loaded.
    ///   - customPackageContainerProvider: Custom package container provider. Used to provide specialized package
    /// providers.
    ///   - customRepositoryProvider: Custom repository provider. Used to customize source control access.
    ///   - delegate: Delegate for workspace events
    public convenience init(
        fileSystem: FileSystem? = .none,
        forRootPackage packagePath: AbsolutePath,
        authorizationProvider: AuthorizationProvider? = .none,
        registryAuthorizationProvider: AuthorizationProvider? = .none,
        configuration: WorkspaceConfiguration? = .none,
        cancellator: Cancellator? = .none,
        initializationWarningHandler: ((String) -> Void)? = .none,
        // optional customization used for advanced integration situations
        customHostToolchain: UserToolchain,
        customPackageContainerProvider: PackageContainerProvider? = .none,
        customRepositoryProvider: RepositoryProvider? = .none,
        // delegate
        delegate: Delegate? = .none
    ) throws {
        let fileSystem = fileSystem ?? localFileSystem
        let location = try Location(forRootPackage: packagePath, fileSystem: fileSystem)
        let manifestLoader = ManifestLoader(
            toolchain: customHostToolchain,
            cacheDir: location.sharedManifestsCacheDirectory,
            importRestrictions: configuration?.manifestImportRestrictions,
            delegate: delegate.map(WorkspaceManifestLoaderDelegate.init(workspaceDelegate:))
        )
        try self.init(
            fileSystem: fileSystem,
            location: location,
            authorizationProvider: authorizationProvider,
            registryAuthorizationProvider: registryAuthorizationProvider,
            configuration: configuration,
            cancellator: cancellator,
            initializationWarningHandler: initializationWarningHandler,
            customHostToolchain: customHostToolchain,
            customManifestLoader: manifestLoader,
            customPackageContainerProvider: customPackageContainerProvider,
            customRepositoryProvider: customRepositoryProvider,
            delegate: delegate
        )
    }

    /// Initializer for testing purposes only. Use non underscored initializers instead.
    // this initializer is only public because of cross module visibility (eg MockWorkspace)
    // as such it is by design an exact mirror of the private initializer below
    public static func _init(
        // core
        fileSystem: FileSystem,
        environment: Environment,
        location: Location,
        authorizationProvider: AuthorizationProvider? = .none,
        registryAuthorizationProvider: AuthorizationProvider? = .none,
        configuration: WorkspaceConfiguration? = .none,
        cancellator: Cancellator? = .none,
        initializationWarningHandler: ((String) -> Void)? = .none,
        // optional customization, primarily designed for testing but also used in some cases by libSwiftPM consumers
        customRegistriesConfiguration: RegistryConfiguration? = .none,
        customFingerprints: PackageFingerprintStorage? = .none,
        customSigningEntities: PackageSigningEntityStorage? = .none,
        skipSignatureValidation: Bool = false,
        customMirrors: DependencyMirrors? = .none,
        customToolsVersion: ToolsVersion? = .none,
        customHostToolchain: UserToolchain? = .none,
        customManifestLoader: ManifestLoaderProtocol? = .none,
        customPackageContainerProvider: PackageContainerProvider? = .none,
        customRepositoryManager: RepositoryManager? = .none,
        customRepositoryProvider: RepositoryProvider? = .none,
        customRegistryClient: RegistryClient? = .none,
        customBinaryArtifactsManager: CustomBinaryArtifactsManager? = .none,
        customIdentityResolver: IdentityResolver? = .none,
        customDependencyMapper: DependencyMapper? = .none,
        customChecksumAlgorithm: HashAlgorithm? = .none,
        // delegate
        delegate: Delegate? = .none
    ) throws -> Workspace {
        try .init(
            fileSystem: fileSystem,
            environment: environment,
            location: location,
            authorizationProvider: authorizationProvider,
            registryAuthorizationProvider: registryAuthorizationProvider,
            configuration: configuration,
            cancellator: cancellator,
            initializationWarningHandler: initializationWarningHandler,
            customRegistriesConfiguration: customRegistriesConfiguration,
            customFingerprints: customFingerprints,
            customSigningEntities: customSigningEntities,
            skipSignatureValidation: skipSignatureValidation,
            customMirrors: customMirrors,
            customToolsVersion: customToolsVersion,
            customHostToolchain: customHostToolchain,
            customManifestLoader: customManifestLoader,
            customPackageContainerProvider: customPackageContainerProvider,
            customRepositoryManager: customRepositoryManager,
            customRepositoryProvider: customRepositoryProvider,
            customRegistryClient: customRegistryClient,
            customBinaryArtifactsManager: customBinaryArtifactsManager,
            customIdentityResolver: customIdentityResolver,
            customDependencyMapper: customDependencyMapper,
            customChecksumAlgorithm: customChecksumAlgorithm,
            delegate: delegate
        )
    }

    private init(
        // core
        fileSystem: FileSystem,
        environment: Environment,
        location: Location,
        authorizationProvider: AuthorizationProvider?,
        registryAuthorizationProvider: AuthorizationProvider?,
        configuration: WorkspaceConfiguration?,
        cancellator: Cancellator?,
        initializationWarningHandler: ((String) -> Void)?,
        // optional customization, primarily designed for testing but also used in some cases by libSwiftPM consumers
        customRegistriesConfiguration: RegistryConfiguration?,
        customFingerprints: PackageFingerprintStorage?,
        customSigningEntities: PackageSigningEntityStorage?,
        skipSignatureValidation: Bool,
        customMirrors: DependencyMirrors?,
        customToolsVersion: ToolsVersion?,
        customHostToolchain: UserToolchain?,
        customManifestLoader: ManifestLoaderProtocol?,
        customPackageContainerProvider: PackageContainerProvider?,
        customRepositoryManager: RepositoryManager?,
        customRepositoryProvider: RepositoryProvider?,
        customRegistryClient: RegistryClient?,
        customBinaryArtifactsManager: CustomBinaryArtifactsManager?,
        customIdentityResolver: IdentityResolver?,
        customDependencyMapper: DependencyMapper?,
        customChecksumAlgorithm: HashAlgorithm?,
        // delegate
        delegate: Delegate?
    ) throws {
        // we do not store an observabilityScope in the workspace initializer as the workspace is designed to be long
        // lived.
        // instead, observabilityScope is passed into the individual workspace methods which are short lived.
        let initializationWarningHandler = initializationWarningHandler ?? warnToStderr
        // validate locations, returning a potentially modified one to deal with non-accessible or non-writable shared
        // locations
        let location = try location.validatingSharedLocations(
            fileSystem: fileSystem,
            warningHandler: initializationWarningHandler
        )

        let currentToolsVersion = customToolsVersion ?? ToolsVersion.current
        let hostToolchain = try customHostToolchain ?? UserToolchain(
            swiftSDK: .hostSwiftSDK(
                environment: environment
            ),
            environment: environment,
            fileSystem: fileSystem
        )
        var manifestLoader = customManifestLoader ?? ManifestLoader(
            toolchain: hostToolchain,
            cacheDir: location.sharedManifestsCacheDirectory,
            importRestrictions: configuration?.manifestImportRestrictions
        )
        // set delegate if not set
        if let manifestLoader = manifestLoader as? ManifestLoader, manifestLoader.delegate == nil {
            manifestLoader.delegate = delegate.map(WorkspaceManifestLoaderDelegate.init(workspaceDelegate:))
        }

        let configuration = configuration ?? .default

        let mirrors = try customMirrors ?? Workspace.Configuration.Mirrors(
            fileSystem: fileSystem,
            localMirrorsFile: location.localMirrorsConfigurationFile,
            sharedMirrorsFile: location.sharedMirrorsConfigurationFile
        ).mirrors

        let identityResolver = customIdentityResolver ?? DefaultIdentityResolver(
            locationMapper: mirrors.effective(for:),
            identityMapper: mirrors.effectiveIdentity(for:)
        )
        let dependencyMapper = customDependencyMapper ?? DefaultDependencyMapper(identityResolver: identityResolver)
        let checksumAlgorithm = customChecksumAlgorithm ?? SHA256()

        let repositoryProvider = customRepositoryProvider ?? GitRepositoryProvider()
        let repositoryManager = customRepositoryManager ?? RepositoryManager(
            fileSystem: fileSystem,
            path: location.repositoriesDirectory,
            provider: repositoryProvider,
            cachePath: configuration.sharedDependenciesCacheEnabled ? location.sharedRepositoriesCacheDirectory : .none,
            initializationWarningHandler: initializationWarningHandler,
            delegate: delegate.map(WorkspaceRepositoryManagerDelegate.init(workspaceDelegate:))
        )
        // register the source control dependencies fetcher with the cancellation handler
        cancellator?.register(name: "repository fetching", handler: repositoryManager)

        let fingerprints = customFingerprints ?? location.sharedFingerprintsDirectory.map {
            FilePackageFingerprintStorage(
                fileSystem: fileSystem,
                directoryPath: $0
            )
        }

        let signingEntities = customSigningEntities ?? location.sharedSigningEntitiesDirectory.map {
            FilePackageSigningEntityStorage(
                fileSystem: fileSystem,
                directoryPath: $0
            )
        }

        let registriesConfiguration = try customRegistriesConfiguration ?? Workspace.Configuration.Registries(
            fileSystem: fileSystem,
            localRegistriesFile: location.localRegistriesConfigurationFile,
            sharedRegistriesFile: location.sharedRegistriesConfigurationFile
        ).configuration

        let registryClient = customRegistryClient ?? RegistryClient(
            configuration: registriesConfiguration,
            fingerprintStorage: fingerprints,
            fingerprintCheckingMode: FingerprintCheckingMode.map(configuration.fingerprintCheckingMode),
            skipSignatureValidation: skipSignatureValidation,
            signingEntityStorage: signingEntities,
            signingEntityCheckingMode: SigningEntityCheckingMode.map(configuration.signingEntityCheckingMode),
            authorizationProvider: registryAuthorizationProvider,
            delegate: WorkspaceRegistryClientDelegate(workspaceDelegate: delegate),
            checksumAlgorithm: checksumAlgorithm
        )

        // set default registry if not already set by configuration
        if registryClient.defaultRegistry == nil, let defaultRegistry = configuration.defaultRegistry {
            registryClient.defaultRegistry = defaultRegistry
        }

        let registryDownloadsManager = RegistryDownloadsManager(
            fileSystem: fileSystem,
            path: location.registryDownloadDirectory,
            cachePath: configuration.sharedDependenciesCacheEnabled ? location
                .sharedRegistryDownloadsCacheDirectory : .none,
            registryClient: registryClient,
            delegate: delegate.map(WorkspaceRegistryDownloadsManagerDelegate.init(workspaceDelegate:))
        )
        // register the registry dependencies downloader with the cancellation handler
        cancellator?.register(name: "registry downloads", handler: registryDownloadsManager)

        if let transformationMode = RegistryAwareManifestLoader
            .TransformationMode(configuration.sourceControlToRegistryDependencyTransformation)
        {
            manifestLoader = RegistryAwareManifestLoader(
                underlying: manifestLoader,
                registryClient: registryClient,
                transformationMode: transformationMode
            )
        }

        let binaryArtifactsManager = BinaryArtifactsManager(
            fileSystem: fileSystem,
            authorizationProvider: authorizationProvider,
            hostToolchain: hostToolchain,
            checksumAlgorithm: checksumAlgorithm,
            cachePath:  customBinaryArtifactsManager?.useCache == false || !configuration.sharedDependenciesCacheEnabled ? .none : location.sharedBinaryArtifactsCacheDirectory,
            customHTTPClient: customBinaryArtifactsManager?.httpClient,
            customArchiver: customBinaryArtifactsManager?.archiver,
            delegate: delegate.map(WorkspaceBinaryArtifactsManagerDelegate.init(workspaceDelegate:))
        )
        // register the binary artifacts downloader with the cancellation handler
        cancellator?.register(name: "binary artifacts downloads", handler: binaryArtifactsManager)

        // initialize
        self.fileSystem = fileSystem
        self.configuration = configuration
        self.location = location
        self.delegate = delegate
        self.mirrors = mirrors

        self.hostToolchain = hostToolchain
        self.manifestLoader = manifestLoader
        self.currentToolsVersion = currentToolsVersion

        self.customPackageContainerProvider = customPackageContainerProvider
        self.repositoryManager = repositoryManager
        self.registryClient = registryClient
        self.registryDownloadsManager = registryDownloadsManager
        self.binaryArtifactsManager = binaryArtifactsManager

        self.identityResolver = identityResolver
        self.dependencyMapper = dependencyMapper
        self.fingerprints = fingerprints

        self.pinsStore = LoadableResult {
            try PinsStore(
                pinsFile: location.resolvedVersionsFile,
                workingDirectory: location.scratchDirectory,
                fileSystem: fileSystem,
                mirrors: mirrors
            )
        }

        self.state = WorkspaceState(
            fileSystem: fileSystem,
            storageDirectory: self.location.scratchDirectory,
            initializationWarningHandler: initializationWarningHandler
        )
    }

    var providedLibraries: [ProvidedLibrary] {
        // Note: Eventually, we should get these from the individual SDKs, but the first step is providing the metadata centrally in the toolchain.
        self.hostToolchain.providedLibraries
    }
}

// MARK: - Public API

extension Workspace {
    /// Puts a dependency in edit mode creating a checkout in editables directory.
    ///
    /// - Parameters:
    ///     - packageName: The name of the package to edit.
    ///     - path: If provided, creates or uses the checkout at this location.
    ///     - revision: If provided, the revision at which the dependency
    ///       should be checked out to otherwise current revision.
    ///     - checkoutBranch: If provided, a new branch with this name will be
    ///       created from the revision provided.
    ///     - observabilityScope: The observability scope that reports errors, warnings, etc
    public func edit(
        packageName: String,
        path: AbsolutePath? = nil,
        revision: Revision? = nil,
        checkoutBranch: String? = nil,
        observabilityScope: ObservabilityScope
    ) {
        do {
            try self._edit(
                packageName: packageName,
                path: path,
                revision: revision,
                checkoutBranch: checkoutBranch,
                observabilityScope: observabilityScope
            )
        } catch {
            observabilityScope.emit(error)
        }
    }

    /// Ends the edit mode of an edited dependency.
    ///
    /// This will re-resolve the dependencies after ending edit as the original
    /// checkout may be outdated.
    ///
    /// - Parameters:
    ///     - packageName: The name of the package to edit.
    ///     - forceRemove: If true, the dependency will be unedited even if has unpushed
    ///           or uncommitted changes. Otherwise will throw respective errors.
    ///     - root: The workspace root. This is used to resolve the dependencies post unediting.
    ///     - observabilityScope: The observability scope that reports errors, warnings, etc
    public func unedit(
        packageName: String,
        forceRemove: Bool,
        root: PackageGraphRootInput,
        observabilityScope: ObservabilityScope
    ) throws {
        guard let dependency = self.state.dependencies[.plain(packageName)] else {
            observabilityScope.emit(.dependencyNotFound(packageName: packageName))
            return
        }

        let observabilityScope = observabilityScope.makeChildScope(
            description: "editing package",
            metadata: dependency.packageRef.diagnosticsMetadata
        )

        try self.unedit(
            dependency: dependency,
            forceRemove: forceRemove,
            root: root,
            observabilityScope: observabilityScope
        )
    }

    /// Perform dependency resolution if needed.
    ///
    /// This method will perform dependency resolution based on the root
    /// manifests and pins file.  Pins are respected as long as they are
    /// satisfied by the root manifest closure requirements.  Any outdated
    /// checkout will be restored according to its pin.
    public func resolve(
        root: PackageGraphRootInput,
        explicitProduct: String? = .none,
        forceResolution: Bool = false,
        forceResolvedVersions: Bool = false,
        observabilityScope: ObservabilityScope
    ) throws {
        try self._resolve(
            root: root,
            explicitProduct: explicitProduct,
            resolvedFileStrategy: forceResolvedVersions ? .lockFile : forceResolution ? .update(forceResolution: true) :
                .bestEffort,
            observabilityScope: observabilityScope
        )
    }

    /// Resolve a package at the given state.
    ///
    /// Only one of version, branch and revision will be used and in the same
    /// order. If none of these is provided, the dependency will be pinned at
    /// the current checkout state.
    ///
    /// - Parameters:
    ///   - packageName: The name of the package which is being resolved.
    ///   - root: The workspace's root input.
    ///   - version: The version to pin at.
    ///   - branch: The branch to pin at.
    ///   - revision: The revision to pin at.
    ///   - observabilityScope: The observability scope that reports errors, warnings, etc
    public func resolve(
        packageName: String,
        root: PackageGraphRootInput,
        version: Version? = nil,
        branch: String? = nil,
        revision: String? = nil,
        observabilityScope: ObservabilityScope
    ) throws {
        // Look up the dependency and check if we can pin it.
        guard let dependency = self.state.dependencies[.plain(packageName)] else {
            throw StringError("dependency '\(packageName)' was not found")
        }

        let observabilityScope = observabilityScope.makeChildScope(
            description: "editing package",
            metadata: dependency.packageRef.diagnosticsMetadata
        )

        let defaultRequirement: PackageRequirement
        switch dependency.state {
        case .sourceControlCheckout(let checkoutState):
            defaultRequirement = checkoutState.requirement
        case .registryDownload(let version), .custom(let version, _):
            defaultRequirement = .versionSet(.exact(version))
        case .providedLibrary(_, version: let version):
            defaultRequirement = .versionSet(.exact(version))
        case .fileSystem:
            throw StringError("local dependency '\(dependency.packageRef.identity)' can't be resolved")
        case .edited:
            throw StringError("edited dependency '\(dependency.packageRef.identity)' can't be resolved")
        }

        // Compute the custom or extra constraint we need to impose.
        let requirement: PackageRequirement
        if let version {
            requirement = .versionSet(.exact(version))
        } else if let branch {
            requirement = .revision(branch)
        } else if let revision {
            requirement = .revision(revision)
        } else {
            requirement = defaultRequirement
        }

        // If any products are required, the rest of the package graph will supply those constraints.
        let constraint = PackageContainerConstraint(
            package: dependency.packageRef,
            requirement: requirement,
            products: .nothing
        )

        // Run the resolution.
        try self.resolveAndUpdateResolvedFile(
            root: root,
            forceResolution: false,
            constraints: [constraint],
            observabilityScope: observabilityScope
        )
    }

    /// Resolves the dependencies according to the entries present in the Package.resolved file.
    ///
    /// This method bypasses the dependency resolution and resolves dependencies
    /// according to the information in the resolved file.
    public func resolveBasedOnResolvedVersionsFile(
        root: PackageGraphRootInput,
        observabilityScope: ObservabilityScope
    ) throws {
        try self._resolveBasedOnResolvedVersionsFile(
            root: root,
            explicitProduct: .none,
            observabilityScope: observabilityScope
        )
    }

    /// Cleans the build artifacts from workspace data.
    ///
    /// - Parameters:
    ///     - observabilityScope: The observability scope that reports errors, warnings, etc
    public func clean(observabilityScope: ObservabilityScope) {
        // These are the things we don't want to remove while cleaning.
        let protectedAssets = [
            self.repositoryManager.path,
            self.location.repositoriesCheckoutsDirectory,
            self.location.artifactsDirectory,
            self.state.storagePath,
        ].map { path -> String in
            // Assert that these are present inside data directory.
            assert(path.parentDirectory == self.location.scratchDirectory)
            return path.basename
        }

        // If we have no data yet, we're done.
        guard self.fileSystem.exists(self.location.scratchDirectory) else {
            return
        }

        guard let contents = observabilityScope
            .trap({ try fileSystem.getDirectoryContents(self.location.scratchDirectory) })
        else {
            return
        }

        // Remove all but protected paths.
        let contentsToRemove = Set(contents).subtracting(protectedAssets)
        for name in contentsToRemove {
            try? self.fileSystem.removeFileTree(AbsolutePath(
                validating: name,
                relativeTo: self.location.scratchDirectory
            ))
        }
    }

    /// Cleans the build artifacts from workspace data.
    ///
    /// - Parameters:
    ///     - observabilityScope: The observability scope that reports errors, warnings, etc
    public func purgeCache(observabilityScope: ObservabilityScope) {
        self.repositoryManager.purgeCache(observabilityScope: observabilityScope)
        self.registryDownloadsManager.purgeCache(observabilityScope: observabilityScope)
        self.manifestLoader.purgeCache(observabilityScope: observabilityScope)
    }

    /// Resets the entire workspace by removing the data directory.
    ///
    /// - Parameters:
    ///     - observabilityScope: The observability scope that reports errors, warnings, etc
    public func reset(observabilityScope: ObservabilityScope) {
        let removed = observabilityScope.trap { () -> Bool in
            try self.fileSystem.chmod(
                .userWritable,
                path: self.location.repositoriesCheckoutsDirectory,
                options: [.recursive, .onlyFiles]
            )
            // Reset state.
            try self.resetState()
            return true
        }

        guard removed ?? false else {
            return
        }

        self.repositoryManager.reset(observabilityScope: observabilityScope)
        self.registryDownloadsManager.reset(observabilityScope: observabilityScope)
        self.manifestLoader.resetCache(observabilityScope: observabilityScope)
        do {
            try self.fileSystem.removeFileTree(self.location.scratchDirectory)
        } catch {
            observabilityScope.emit(
                error: "Error removing scratch directory at '\(self.location.scratchDirectory)'",
                underlyingError: error
            )
        }
    }

    // FIXME: @testable internal
    public func resetState() throws {
        try self.state.reset()
    }

    /// Cancel the active dependency resolution operation.
    public func cancelActiveResolverOperation() {
        // FIXME: Need to add cancel support.
    }

    /// Updates the current dependencies.
    ///
    /// - Parameters:
    ///     - observabilityScope: The observability scope that reports errors, warnings, etc
    @discardableResult
    public func updateDependencies(
        root: PackageGraphRootInput,
        packages: [String] = [],
        dryRun: Bool = false,
        observabilityScope: ObservabilityScope
    ) throws -> [(PackageReference, Workspace.PackageStateChange)]? {
        try self._updateDependencies(
            root: root,
            packages: packages,
            dryRun: dryRun,
            observabilityScope: observabilityScope
        )
    }

    @discardableResult
    public func loadPackageGraph(
        rootInput root: PackageGraphRootInput,
        explicitProduct: String? = nil,
        forceResolvedVersions: Bool = false,
        customXCTestMinimumDeploymentTargets: [PackageModel.Platform: PlatformVersion]? = .none,
        testEntryPointPath: AbsolutePath? = nil,
        expectedSigningEntities: [PackageIdentity: RegistryReleaseMetadata.SigningEntity] = [:],
        observabilityScope: ObservabilityScope
    ) throws -> ModulesGraph {
        try self.loadPackageGraph(
            rootInput: root,
            explicitProduct: explicitProduct,
            traitConfiguration: nil,
            forceResolvedVersions: forceResolvedVersions,
            customXCTestMinimumDeploymentTargets: customXCTestMinimumDeploymentTargets,
            testEntryPointPath: testEntryPointPath,
            expectedSigningEntities: expectedSigningEntities,
            observabilityScope: observabilityScope
        )
    }

    @discardableResult
    package func loadPackageGraph(
        rootInput root: PackageGraphRootInput,
        explicitProduct: String? = nil,
        traitConfiguration: TraitConfiguration? = nil,
        forceResolvedVersions: Bool = false,
        customXCTestMinimumDeploymentTargets: [PackageModel.Platform: PlatformVersion]? = .none,
        testEntryPointPath: AbsolutePath? = nil,
        expectedSigningEntities: [PackageIdentity: RegistryReleaseMetadata.SigningEntity] = [:],
        observabilityScope: ObservabilityScope
    ) throws -> ModulesGraph {
        let start = DispatchTime.now()
        self.delegate?.willLoadGraph()
        defer {
            self.delegate?.didLoadGraph(duration: start.distance(to: .now()))
        }

        // reload state in case it was modified externally (eg by another process) before reloading the graph
        // long running host processes (ie IDEs) need this in case other SwiftPM processes (ie CLI) made changes to the
        // state
        // such hosts processes call loadPackageGraph to make sure the workspace state is correct
        try self.state.reload()

        // Perform dependency resolution, if required.
        let manifests = try self._resolve(
            root: root,
            explicitProduct: explicitProduct,
            resolvedFileStrategy: forceResolvedVersions ? .lockFile : .bestEffort,
            observabilityScope: observabilityScope
        )

        let binaryArtifacts = self.state.artifacts
            .reduce(into: [PackageIdentity: [String: BinaryArtifact]]()) { partial, artifact in
                partial[artifact.packageRef.identity, default: [:]][artifact.targetName] = BinaryArtifact(
                    kind: artifact.kind,
                    originURL: artifact.originURL,
                    path: artifact.path
                )
            }

        // Load the graph.
        let packageGraph = try ModulesGraph.load(
            root: manifests.root,
            identityResolver: self.identityResolver,
            additionalFileRules: self.configuration.additionalFileRules,
            externalManifests: manifests.allDependencyManifests,
            requiredDependencies: manifests.requiredPackages,
            unsafeAllowedPackages: manifests.unsafeAllowedPackages,
            binaryArtifacts: binaryArtifacts,
            shouldCreateMultipleTestProducts: self.configuration.shouldCreateMultipleTestProducts,
            createREPLProduct: self.configuration.createREPLProduct,
            traitConfiguration: traitConfiguration,
            customXCTestMinimumDeploymentTargets: customXCTestMinimumDeploymentTargets,
            testEntryPointPath: testEntryPointPath,
            fileSystem: self.fileSystem,
            observabilityScope: observabilityScope
        )

        try self.validateSignatures(
            packageGraph: packageGraph,
            expectedSigningEntities: expectedSigningEntities
        )

        return packageGraph
    }

    @discardableResult
    public func loadPackageGraph(
        rootPath: AbsolutePath,
        explicitProduct: String? = nil,
        observabilityScope: ObservabilityScope
    ) throws -> ModulesGraph {
        try self.loadPackageGraph(
            rootPath: rootPath,
            explicitProduct: explicitProduct,
            traitConfiguration: nil,
            observabilityScope: observabilityScope
        )
    }

    @discardableResult
    package func loadPackageGraph(
        rootPath: AbsolutePath,
        explicitProduct: String? = nil,
        traitConfiguration: TraitConfiguration? = nil,
        observabilityScope: ObservabilityScope
    ) throws -> ModulesGraph {
        try self.loadPackageGraph(
            rootInput: PackageGraphRootInput(packages: [rootPath]),
            explicitProduct: explicitProduct,
            traitConfiguration: traitConfiguration,
            observabilityScope: observabilityScope
        )
    }

    /// Loads and returns manifests at the given paths.
    public func loadRootManifests(
        packages: [AbsolutePath],
        observabilityScope: ObservabilityScope
    ) async throws -> [AbsolutePath: Manifest] {
        try await withCheckedThrowingContinuation { continuation in
            self.loadRootManifests(packages: packages, observabilityScope: observabilityScope) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Loads and returns manifests at the given paths.
    @available(*, noasync, message: "Use the async alternative")
    public func loadRootManifests(
        packages: [AbsolutePath],
        observabilityScope: ObservabilityScope,
        completion: @escaping (Result<[AbsolutePath: Manifest], Error>) -> Void
    ) {
        let lock = NSLock()
        let sync = DispatchGroup()
        var rootManifests = [AbsolutePath: Manifest]()
        Set(packages).forEach { package in
            sync.enter()
            // TODO: this does not use the identity resolver which is probably fine since its the root packages
            self.loadManifest(
                packageIdentity: PackageIdentity(path: package),
                packageKind: .root(package),
                packagePath: package,
                packageLocation: package.pathString,
                observabilityScope: observabilityScope
            ) { result in
                defer { sync.leave() }
                if case .success(let manifest) = result {
                    lock.withLock {
                        rootManifests[package] = manifest
                    }
                }
            }
        }

        sync.notify(queue: .sharedConcurrent) {
            // Check for duplicate root packages.
            let duplicateRoots = rootManifests.values.spm_findDuplicateElements(by: \.displayName)
            if !duplicateRoots.isEmpty {
                let name = duplicateRoots[0][0].displayName
                observabilityScope.emit(error: "found multiple top-level packages named '\(name)'")
                return completion(.success([:]))
            }

            completion(.success(rootManifests))
        }
    }

    /// Loads and returns manifest at the given path.
    public func loadRootManifest(
        at path: AbsolutePath,
        observabilityScope: ObservabilityScope
    ) async throws -> Manifest {
        try await withCheckedThrowingContinuation { continuation in
            self.loadRootManifest(at: path, observabilityScope: observabilityScope) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Loads and returns manifest at the given path.
    public func loadRootManifest(
        at path: AbsolutePath,
        observabilityScope: ObservabilityScope,
        completion: @escaping (Result<Manifest, Error>) -> Void
    ) {
        self.loadRootManifests(packages: [path], observabilityScope: observabilityScope) { result in
            completion(result.tryMap {
                // normally, we call loadRootManifests which attempts to load any manifest it can and report errors via
                // diagnostics
                // in this case, we want to load a specific manifest, so if the diagnostics contains an error we want to
                // throw
                guard !observabilityScope.errorsReported else {
                    throw Diagnostics.fatalError
                }
                guard let manifest = $0[path] else {
                    throw InternalError("Unknown manifest for '\(path)'")
                }
                return manifest
            })
        }
    }

    /// Loads root package
    public func loadRootPackage(at path: AbsolutePath, observabilityScope: ObservabilityScope) async throws -> Package {
        try await withCheckedThrowingContinuation { continuation in
            self.loadRootPackage(at: path, observabilityScope: observabilityScope) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Loads root package
    public func loadRootPackage(
        at path: AbsolutePath,
        observabilityScope: ObservabilityScope,
        completion: @escaping (Result<Package, Error>) -> Void
    ) {
        self.loadRootManifest(at: path, observabilityScope: observabilityScope) { result in
            let result = result.tryMap { manifest -> Package in
                let identity = try self.identityResolver.resolveIdentity(for: manifest.packageKind)

                // radar/82263304
                // compute binary artifacts for the sake of constructing a project model
                // note this does not actually download remote artifacts and as such does not have the artifact's type
                // or path
                let binaryArtifacts = try manifest.targets.filter { $0.type == .binary }
                    .reduce(into: [String: BinaryArtifact]()) { partial, target in
                        if let path = target.path {
                            let artifactPath = try manifest.path.parentDirectory
                                .appending(RelativePath(validating: path))
                            guard let (_, artifactKind) = try BinaryArtifactsManager.deriveBinaryArtifact(
                                fileSystem: self.fileSystem,
                                path: artifactPath,
                                observabilityScope: observabilityScope
                            ) else {
                                throw StringError("\(artifactPath) does not contain binary artifact")
                            }
                            partial[target.name] = BinaryArtifact(
                                kind: artifactKind,
                                originURL: .none,
                                path: artifactPath
                            )
                        } else if let url = target.url.flatMap(URL.init(string:)) {
                            let fakePath = try manifest.path.parentDirectory.appending(components: "remote", "archive")
                                .appending(RelativePath(validating: url.lastPathComponent))
                            partial[target.name] = BinaryArtifact(
                                kind: .unknown,
                                originURL: url.absoluteString,
                                path: fakePath
                            )
                        } else {
                            throw InternalError("a binary target should have either a path or a URL and a checksum")
                        }
                    }

                let builder = PackageBuilder(
                    identity: identity,
                    manifest: manifest,
                    productFilter: .everything,
                    path: path,
                    additionalFileRules: [],
                    binaryArtifacts: binaryArtifacts,
                    fileSystem: self.fileSystem,
                    observabilityScope: observabilityScope,
                    // For now we enable all traits
                    enabledTraits: Set(manifest.traits.map { $0.name })
                )
                return try builder.construct()
            }
            completion(result)
        }
    }

    public func loadPluginImports(
        packageGraph: ModulesGraph
    ) async throws -> [PackageIdentity: [String: [String]]] {
        let pluginTargets = packageGraph.allModules.filter { $0.type == .plugin }
        let scanner = SwiftcImportScanner(
            swiftCompilerEnvironment: hostToolchain.swiftCompilerEnvironment,
            swiftCompilerFlags: self.hostToolchain
                .swiftCompilerFlags + ["-I", self.hostToolchain.swiftPMLibrariesLocation.pluginLibraryPath.pathString],
            swiftCompilerPath: self.hostToolchain.swiftCompilerPath
        )
        var importList = [PackageIdentity: [String: [String]]]()

        for pluginTarget in pluginTargets {
            let paths = pluginTarget.sources.paths
            guard let pkgId = packageGraph.package(for: pluginTarget)?.identity else { continue }

            if importList[pkgId] == nil {
                importList[pkgId] = [pluginTarget.name: []]
            } else if importList[pkgId]?[pluginTarget.name] == nil {
                importList[pkgId]?[pluginTarget.name] = []
            }

            for path in paths {
                let result = try await scanner.scanImports(path)
                importList[pkgId]?[pluginTarget.name]?.append(contentsOf: result)
            }
        }
        return importList
    }
    
    public func loadPackage(
        with identity: PackageIdentity,
        packageGraph: ModulesGraph,
        observabilityScope: ObservabilityScope
    ) async throws -> Package {
        try await safe_async {
            self.loadPackage(with: identity, packageGraph: packageGraph, observabilityScope: observabilityScope, completion: $0)
        }
    }

    /// Loads a single package in the context of a previously loaded graph. This can be useful for incremental loading
    /// in a longer-lived program, like an IDE.
    @available(*, noasync, message: "Use the async alternative")
    public func loadPackage(
        with identity: PackageIdentity,
        packageGraph: ModulesGraph,
        observabilityScope: ObservabilityScope,
        completion: @escaping (Result<Package, Error>) -> Void
    ) {
        guard let previousPackage = packageGraph.package(for: identity) else {
            return completion(.failure(StringError("could not find package with identity \(identity)")))
        }

        self.loadManifest(
            packageIdentity: identity,
            packageKind: previousPackage.underlying.manifest.packageKind,
            packagePath: previousPackage.path,
            packageLocation: previousPackage.underlying.manifest.packageLocation,
            observabilityScope: observabilityScope
        ) { result in
            let result = result.tryMap { manifest -> Package in
                let builder = PackageBuilder(
                    identity: identity,
                    manifest: manifest,
                    productFilter: .everything,
                    // TODO: this will not be correct when reloading a transitive dependencies if `ENABLE_TARGET_BASED_DEPENDENCY_RESOLUTION` is enabled
                    path: previousPackage.path,
                    additionalFileRules: self.configuration.additionalFileRules,
                    binaryArtifacts: packageGraph.binaryArtifacts[identity] ?? [:],
                    shouldCreateMultipleTestProducts: self.configuration.shouldCreateMultipleTestProducts,
                    createREPLProduct: self.configuration.createREPLProduct,
                    fileSystem: self.fileSystem,
                    observabilityScope: observabilityScope,
                    // For now we enable all traits
                    enabledTraits: Set(manifest.traits.map { $0.name })
                )
                return try builder.construct()
            }
            completion(result)
        }
    }

    public func acceptIdentityChange(
        package: PackageIdentity,
        version: Version,
        signingEntity: SigningEntity,
        origin: SigningEntity.Origin,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        self.registryClient.changeSigningEntityFromVersion(
            package: package,
            version: version,
            signingEntity: signingEntity,
            origin: origin,
            observabilityScope: observabilityScope,
            callbackQueue: callbackQueue,
            completion: completion
        )
    }
}

extension Workspace {
    /// Removes the clone and checkout of the provided specifier.
    ///
    /// - Parameters:
    ///   - package: The package to remove
    func remove(package: PackageReference) throws {
        guard let dependency = self.state.dependencies[package.identity] else {
            throw InternalError("trying to remove \(package.identity) which isn't in workspace")
        }

        // We only need to update the managed dependency structure to "remove"
        // a local package.
        //
        // Note that we don't actually remove a local package from disk.
        if case .fileSystem = dependency.state {
            self.state.dependencies.remove(package.identity)
            try self.state.save()
            return
        }

        // Inform the delegate.
        let repository = try? dependency.packageRef.makeRepositorySpecifier()
        self.delegate?.removing(package: package.identity, packageLocation: repository?.location.description)

        // Compute the dependency which we need to remove.
        let dependencyToRemove: ManagedDependency

        if case .edited(let _basedOn, let unmanagedPath) = dependency.state, let basedOn = _basedOn {
            // Remove the underlying dependency for edited packages.
            dependencyToRemove = basedOn
            let updatedDependency = Workspace.ManagedDependency.edited(
                packageRef: dependency.packageRef,
                subpath: dependency.subpath,
                basedOn: .none,
                unmanagedPath: unmanagedPath
            )
            self.state.dependencies.add(updatedDependency)
        } else {
            dependencyToRemove = dependency
            self.state.dependencies.remove(dependencyToRemove.packageRef.identity)
        }

        switch package.kind {
        case .root, .fileSystem:
            break // NOOP
        case .localSourceControl:
            break // NOOP
        case .remoteSourceControl:
            try self.removeRepository(dependency: dependencyToRemove)
        case .registry:
            try self.removeRegistryArchive(for: dependencyToRemove)
        }

        // Save the state.
        try self.state.save()
    }
}

// MARK: - Utility extensions

extension Workspace.ManagedArtifact {
    fileprivate var originURL: String? {
        switch self.source {
        case .remote(let url, _):
            return url
        case .local:
            return nil
        }
    }
}

extension PackageReference {
    func makeRepositorySpecifier() throws -> RepositorySpecifier {
        switch self.kind {
        case .localSourceControl(let path):
            return .init(path: path)
        case .remoteSourceControl(let url):
            return .init(url: url)
        default:
            throw StringError("invalid dependency kind \(self.kind)")
        }
    }
}

// FIXME: remove this when remove the single call site that uses it
extension PackageDependency {
    private var isLocal: Bool {
        switch self {
        case .fileSystem:
            return true
        case .sourceControl:
            return false
        case .registry:
            return false
        }
    }
}

extension Workspace {
    public static func format(workspaceResolveReason reason: WorkspaceResolveReason) -> String {
        guard reason != .errorsPreviouslyReported else {
            return ""
        }

        var result = "Running resolver because "

        switch reason {
        case .forced:
            result.append("it was forced")
        case .newPackages(let packages):
            let dependencies = packages.lazy.map { "'\($0.identity)' (\($0.kind.locationString))" }
                .joined(separator: ", ")
            result.append("the following dependencies were added: \(dependencies)")
        case .packageRequirementChange(let package, let state, let requirement):
            result.append("dependency '\(package.identity)' (\(package.kind.locationString)) was ")

            switch state {
            case .sourceControlCheckout(let checkoutState)?:
                switch checkoutState.requirement {
                case .versionSet(.exact(let version)):
                    result.append("resolved to '\(version)'")
                case .versionSet:
                    // Impossible
                    break
                case .revision(let revision):
                    result.append("resolved to '\(revision)'")
                case .unversioned:
                    result.append("unversioned")
                }
            case .registryDownload(let version)?, .custom(let version, _):
                result.append("resolved to '\(version)'")
            case .providedLibrary(_, version: let version):
                result.append("resolved to '\(version)'")
            case .edited?:
                result.append("edited")
            case .fileSystem?:
                result.append("versioned")
            case nil:
                result.append("root")
            }

            result.append(" but now has a ")

            switch requirement {
            case .versionSet:
                result.append("different version-based")
            case .revision:
                result.append("different revision-based")
            case .unversioned:
                result.append("unversioned")
            }

            result.append(" requirement.")
        default:
            result.append("requirements have changed.")
        }

        return result
    }
}

extension Workspace.Location {
    /// Returns the path to the dependency's repository checkout directory.
    func repositoriesCheckoutSubdirectory(for dependency: Workspace.ManagedDependency) -> AbsolutePath {
        self.repositoriesCheckoutsDirectory.appending(dependency.subpath)
    }

    /// Returns the path to the  dependency's download directory.
    func registryDownloadSubdirectory(for dependency: Workspace.ManagedDependency) -> AbsolutePath {
        self.registryDownloadDirectory.appending(dependency.subpath)
    }

    /// Returns the path to the dependency's edit directory.
    func editSubdirectory(for dependency: Workspace.ManagedDependency) -> AbsolutePath {
        self.editsDirectory.appending(dependency.subpath)
    }
}

extension Workspace.Location {
    func validatingSharedLocations(
        fileSystem: FileSystem,
        warningHandler: @escaping (String) -> Void
    ) throws -> Self {
        var location = self

        try location.validate(
            keyPath: \.sharedConfigurationDirectory,
            fileSystem: fileSystem,
            getOrCreateHandler: {
                try fileSystem.getOrCreateSwiftPMConfigurationDirectory(
                    warningHandler: self.emitDeprecatedConfigurationWarning ? warningHandler : { _ in }
                )
            },
            warningHandler: warningHandler
        )

        try location.validate(
            keyPath: \.sharedSecurityDirectory,
            fileSystem: fileSystem,
            getOrCreateHandler: fileSystem.getOrCreateSwiftPMSecurityDirectory,
            warningHandler: warningHandler
        )

        try location.validate(
            keyPath: \.sharedCacheDirectory,
            fileSystem: fileSystem,
            getOrCreateHandler: fileSystem.getOrCreateSwiftPMCacheDirectory,
            warningHandler: warningHandler
        )

        try location.validate(
            keyPath: \.sharedSwiftSDKsDirectory,
            fileSystem: fileSystem,
            getOrCreateHandler: fileSystem.getOrCreateSwiftPMSwiftSDKsDirectory,
            warningHandler: warningHandler
        )

        return location
    }

    mutating func validate(
        keyPath: WritableKeyPath<Workspace.Location, AbsolutePath?>,
        fileSystem: FileSystem,
        getOrCreateHandler: () throws -> AbsolutePath,
        warningHandler: @escaping (String) -> Void
    ) throws {
        // check that shared configuration directory is accessible, or warn + reset if not
        if let sharedDirectory = self[keyPath: keyPath] {
            // It may not always be possible to create default location (for example de to restricted sandbox),
            // in which case defaultDirectory would be nil.
            let defaultDirectory = try? getOrCreateHandler()
            if defaultDirectory != nil, sharedDirectory != defaultDirectory {
                // custom location _must_ be writable, throw if we cannot access it
                guard fileSystem.isWritable(sharedDirectory) else {
                    throw StringError("\(sharedDirectory) is not accessible or not writable")
                }
            } else {
                if !fileSystem.isWritable(sharedDirectory) {
                    self[keyPath: keyPath] = nil
                    warningHandler(
                        "\(sharedDirectory) is not accessible or not writable, disabling user-level cache features."
                    )
                }
            }
        }
    }
}

private func warnToStderr(_ message: String) {
    TSCBasic.stderrStream.write("warning: \(message)\n")
    TSCBasic.stderrStream.flush()
}

// used for manifest validation
#if compiler(<6.0)
extension RepositoryManager: ManifestSourceControlValidator {}
#else
extension RepositoryManager: @retroactive ManifestSourceControlValidator {}
#endif

extension ContainerUpdateStrategy {
    var repositoryUpdateStrategy: RepositoryUpdateStrategy {
        switch self {
        case .always:
            return .always
        case .never:
            return .never
        case .ifNeeded(let revision):
            return .ifNeeded(revision: .init(identifier: revision))
        }
    }
}
