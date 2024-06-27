//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import Basics
import PackageGraph
import PackageModel
import SPMBuildCore

#if USE_IMPL_ONLY_IMPORTS
@_implementationOnly import DriverSupport
#else
import DriverSupport
#endif

import class Basics.AsyncProcess
import struct Basics.AsyncProcessResult

/// A wrapper for swift-symbolgraph-extract tool.
package struct SymbolGraphExtract {
    let fileSystem: FileSystem
    let tool: AbsolutePath
    let observabilityScope: ObservabilityScope
    
    var skipSynthesizedMembers = false
    var minimumAccessLevel = AccessLevel.public
    var skipInheritedDocs = false
    var includeSPISymbols = false
    var emitExtensionBlockSymbols = false
    var outputFormat = OutputFormat.json(pretty: false)

    /// Access control levels.
    public enum AccessLevel: String, RawRepresentable, CaseIterable, ExpressibleByArgument {
        // The cases reflect those found in `include/swift/AST/AttrKind.h` of the swift compiler (at commit 03f55d7bb4204ca54841218eb7cc175ae798e3bd)
        case `private`, `fileprivate`, `internal`, `public`, `open`
    }

    /// Output format of the generated symbol graph.
    public enum OutputFormat {
        /// JSON format, optionally "pretty-printed" be more human-readable.
        case json(pretty: Bool)
    }
    
    /// Creates a symbol graph for `module` in `outputDirectory` using the build information from `buildPlan`.
    /// The `outputDirection` determines how the output from the tool subprocess is handled, and `verbosity` specifies
    /// how much console output to ask the tool to emit.
    package func extractSymbolGraph(
        module: ResolvedModule,
        buildPlan: BuildPlan,
        buildParameters: BuildParameters,
        outputRedirection: AsyncProcess.OutputRedirection = .none,
        outputDirectory: AbsolutePath,
        verboseOutput: Bool
    ) throws -> AsyncProcessResult {
        try self.fileSystem.createDirectory(outputDirectory, recursive: true)

        // Construct arguments for extracting symbols for a single target.
        var commandLine = [self.tool.pathString]
        commandLine += try buildPlan.symbolGraphExtractArguments(for: module)

        // FIXME: everything here should be in symbolGraphExtractArguments
        commandLine += ["-module-name", module.c99name]
        commandLine += try buildParameters.tripleArgs(for: module)
        commandLine += ["-module-cache-path", try buildParameters.moduleCache.pathString]
        if verboseOutput {
            commandLine += ["-v"]
        }
        commandLine += ["-minimum-access-level", minimumAccessLevel.rawValue]
        if skipSynthesizedMembers {
            commandLine += ["-skip-synthesized-members"]
        }
        if skipInheritedDocs {
            commandLine += ["-skip-inherited-docs"]
        }
        if includeSPISymbols {
            commandLine += ["-include-spi-symbols"]
        }
        
        let extensionBlockSymbolsFlag = emitExtensionBlockSymbols ? "-emit-extension-block-symbols" : "-omit-extension-block-symbols"
        if DriverSupport.checkSupportedFrontendFlags(flags: [extensionBlockSymbolsFlag.trimmingCharacters(in: ["-"])], toolchain: buildParameters.toolchain, fileSystem: fileSystem) {
            commandLine += [extensionBlockSymbolsFlag]
        } else {
            observabilityScope.emit(warning: "dropped \(extensionBlockSymbolsFlag) flag because it is not supported by this compiler version")
        }
        
        switch outputFormat {
        case .json(let pretty):
            if pretty {
                commandLine += ["-pretty-print"]
            }
        }
        commandLine += ["-output-dir", outputDirectory.pathString]

        // Run the extraction.
        let process = AsyncProcess(
            arguments: commandLine,
            outputRedirection: outputRedirection
        )
        try process.launch()
        return try process.waitUntilExit()
    }
}
