//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2015-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import class Basics.ObservabilityScope
import protocol Basics.FileSystem
import class Basics.ThreadSafeBox
import typealias Basics.TSCAbsolutePath
import struct SPMBuildCore.BuildParameters
import class TSCUtility.IndexStoreAPI

/// The context available during build execution.
public final class BuildExecutionContext {
    /// Build parameters for products.
    let productsBuildParameters: BuildParameters

    /// Build parameters for build tools.
    let toolsBuildParameters: BuildParameters

    /// The build description.
    ///
    /// This is optional because we might not have a valid build description when performing the
    /// build for PackageStructure target.
    let buildDescription: BuildDescription?

    /// The package structure delegate.
    let packageStructureDelegate: PackageStructureDelegate

    /// Optional provider of build error resolution advice.
    let buildErrorAdviceProvider: BuildErrorAdviceProvider?

    let fileSystem: Basics.FileSystem

    let observabilityScope: ObservabilityScope

    public init(
        productsBuildParameters: BuildParameters,
        toolsBuildParameters: BuildParameters,
        buildDescription: BuildDescription? = nil,
        fileSystem: Basics.FileSystem,
        observabilityScope: ObservabilityScope,
        packageStructureDelegate: PackageStructureDelegate,
        buildErrorAdviceProvider: BuildErrorAdviceProvider? = nil
    ) {
        self.productsBuildParameters = productsBuildParameters
        self.toolsBuildParameters = toolsBuildParameters
        self.buildDescription = buildDescription
        self.fileSystem = fileSystem
        self.observabilityScope = observabilityScope
        self.packageStructureDelegate = packageStructureDelegate
        self.buildErrorAdviceProvider = buildErrorAdviceProvider
    }

    // MARK: - Private

    private var indexStoreAPICache = ThreadSafeBox<Result<IndexStoreAPI, Error>>()

    /// Reference to the index store API.
    var indexStoreAPI: Result<IndexStoreAPI, Error> {
        self.indexStoreAPICache.memoize {
            do {
                #if os(Windows)
                // The library's runtime component is in the `bin` directory on
                // Windows rather than the `lib` directory as on Unix.  The `lib`
                // directory contains the import library (and possibly static
                // archives) which are used for linking.  The runtime component is
                // not (necessarily) part of the SDK distributions.
                //
                // NOTE: the library name here `libIndexStore.dll` is technically
                // incorrect as per the Windows naming convention.  However, the
                // library is currently installed as `libIndexStore.dll` rather than
                // `IndexStore.dll`.  In the future, this may require a fallback
                // search, preferring `IndexStore.dll` over `libIndexStore.dll`.
                let indexStoreLib = toolsBuildParameters.toolchain.swiftCompilerPath
                    .parentDirectory
                    .appending("libIndexStore.dll")
                #else
                let ext = toolsBuildParameters.triple.dynamicLibraryExtension
                let indexStoreLib = try toolsBuildParameters.toolchain.toolchainLibDir
                    .appending("libIndexStore" + ext)
                #endif
                return try .success(IndexStoreAPI(dylib: TSCAbsolutePath(indexStoreLib)))
            } catch {
                return .failure(error)
            }
        }
    }
}
