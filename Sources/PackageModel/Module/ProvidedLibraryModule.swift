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

import struct Basics.AbsolutePath

@available(*, deprecated, renamed: "ProvidedLibraryModule")
public typealias ProvidedLibraryTarget = ProvidedLibraryModule

/// Represents a library module that comes from a toolchain in prebuilt form.
public final class ProvidedLibraryModule: Module {
    public init(
        name: String,
        path: AbsolutePath
    ) {
        let sources = Sources(paths: [], root: path)
        super.init(
            name: name,
            type: .providedLibrary,
            path: sources.root,
            sources: sources,
            dependencies: [],
            packageAccess: false,
            buildSettings: .init(),
            buildSettingsDescription: [],
            pluginUsages: [],
            usesUnsafeFlags: false
        )
    }
}
