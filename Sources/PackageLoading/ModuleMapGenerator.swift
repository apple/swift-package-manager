//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation
import PackageModel

/// Name of the module map file recognized by the Clang and Swift compilers.
public let moduleMapFilename = "module.modulemap"

extension AbsolutePath {
  fileprivate var moduleEscapedPathString: String {
    return self.pathString.replacing("\\", with: "\\\\")
  }
}

/// A protocol for targets which might have a modulemap.
protocol ModuleMapProtocol {
    var moduleMapPath: AbsolutePath { get }

    var moduleMapDirectory: AbsolutePath { get }
}

extension SystemLibraryTarget: ModuleMapProtocol {
    var moduleMapDirectory: AbsolutePath {
        return path
    }

    public var moduleMapPath: AbsolutePath {
        return moduleMapDirectory.appending(component: moduleMapFilename)
    }
}

extension ClangTarget: ModuleMapProtocol {
    var moduleMapDirectory: AbsolutePath {
        return includeDir
    }

    public var moduleMapPath: AbsolutePath {
        return moduleMapDirectory.appending(component: moduleMapFilename)
    }
}

/// A module map generator for Clang targets.  Module map generation consists of two steps:
/// 1. Examining a target's public-headers directory to determine the appropriate module map type
/// 2. Generating a module map for any target that doesn't have a custom module map file
///
/// When a custom module map exists in the header directory, it is used as-is.  When a custom module map does not exist, a module map is generated based on the following rules:
///
/// *  If "include/foo/foo.h" exists and `foo` is the only directory under the "include" directory, and the "include" directory contains no header files:
///    Generates: `umbrella header "/path/to/include/foo/foo.h"`
/// *  If "include/foo.h" exists and "include" contains no other subdirectory:
///    Generates: `umbrella header "/path/to/include/foo.h"`
/// *  Otherwise, if the "include" directory only contains header files and no other subdirectory:
///    Generates: `umbrella "path/to/include"`
///
/// These rules are documented at https://github.com/apple/swift-package-manager/blob/master/Documentation/Usage.md#creating-c-language-targets.  To avoid breaking existing packages, do not change the semantics here without making any change conditional on the tools version of the package that defines the target.
///
/// Note that a module map generator doesn't require a target to already have been instantiated; it can operate on information that will later be used to instantiate a target.
public struct ModuleMapGenerator {

    /// The name of the Clang target (for diagnostics).
    private let targetName: String

    /// The module name of the target.
    private let moduleName: String

    /// The target's public-headers directory.
    private let publicHeadersDir: AbsolutePath

    /// The file system to be used.
    private let fileSystem: FileSystem

    public init(targetName: String, moduleName: String, publicHeadersDir: AbsolutePath, fileSystem: FileSystem) {
        self.targetName = targetName
        self.moduleName = moduleName
        self.publicHeadersDir = publicHeadersDir
        self.fileSystem = fileSystem
    }

    /// Inspects the file system at the public-headers directory with which the module map generator was instantiated, and returns the type of module map that applies to that directory.  This function contains all of the heuristics that implement module map policy for package targets; other functions just use the results of this determination.
    public func determineModuleMapType(observabilityScope: ObservabilityScope) -> ModuleMapType {
        // The following rules are documented at https://github.com/apple/swift-package-manager/blob/master/Documentation/Usage.md#creating-c-language-targets.  To avoid breaking existing packages, do not change the semantics here without making any change conditional on the tools version of the package that defines the target.

        let diagnosticsEmitter = observabilityScope.makeDiagnosticsEmitter {
            var metadata = ObservabilityMetadata()
            metadata.targetName = self.targetName
            return metadata
        }

        // First check for a custom module map.
        let customModuleMapFile = publicHeadersDir.appending(component: moduleMapFilename)
        if fileSystem.isFile(customModuleMapFile) {
            return .custom(customModuleMapFile)
        }

        // Warn if the public-headers directory is missing.  For backward compatibility reasons, this is not an error, we just won't generate a module map in that case.
        guard fileSystem.exists(publicHeadersDir) else {
            diagnosticsEmitter.emit(.missingPublicHeadersDirectory(targetName: targetName, publicHeadersDir: publicHeadersDir))
            return .none
        }

        // Next try to get the entries in the public-headers directory.
        let entries: Set<AbsolutePath>
        do {
            entries = try Set(fileSystem.getDirectoryContents(publicHeadersDir).map({ publicHeadersDir.appending(component: $0) }))
        }
        catch {
            // This might fail because of a file system error, etc.
            diagnosticsEmitter.emit(.inaccessiblePublicHeadersDirectory(targetName: targetName, publicHeadersDir: publicHeadersDir, fileSystemError: error))
            return .none
        }

        // Filter out headers and directories at the top level of the public-headers directory.
        // FIXME: What about .hh files, or .hpp, etc?  We should centralize the detection of file types based on names (and ideally share with SwiftDriver).
        let headers = entries.filter({ fileSystem.isFile($0) && $0.suffix == ".h" })
        let directories = entries.filter({ fileSystem.isDirectory($0) })

        // If 'PublicHeadersDir/ModuleName.h' exists, then use it as the umbrella header.
        let umbrellaHeader = publicHeadersDir.appending(component: moduleName + ".h")
        if fileSystem.isFile(umbrellaHeader) {
            // In this case, 'PublicHeadersDir' is expected to contain no subdirectories.
            if directories.count != 0 {
                diagnosticsEmitter.emit(.umbrellaHeaderHasSiblingDirectories(targetName: targetName, umbrellaHeader: umbrellaHeader, siblingDirs: directories))
                return .none
            }
            return .umbrellaHeader(umbrellaHeader)
        }

        /// Check for the common mistake of naming the umbrella header 'TargetName.h' instead of 'ModuleName.h'.
        let misnamedUmbrellaHeader = publicHeadersDir.appending(component: targetName + ".h")
        if fileSystem.isFile(misnamedUmbrellaHeader) {
            diagnosticsEmitter.emit(.misnamedUmbrellaHeader(misnamedUmbrellaHeader: misnamedUmbrellaHeader, umbrellaHeader: umbrellaHeader))
        }

        // If 'PublicHeadersDir/ModuleName/ModuleName.h' exists, then use it as the umbrella header.
        let nestedUmbrellaHeader = publicHeadersDir.appending(components: moduleName, moduleName + ".h")
        if fileSystem.isFile(nestedUmbrellaHeader) {
            // In this case, 'PublicHeadersDir' is expected to contain no subdirectories other than 'ModuleName'.
            if directories.count != 1 {
                diagnosticsEmitter.emit(.umbrellaHeaderParentDirHasSiblingDirectories(targetName: targetName, umbrellaHeader: nestedUmbrellaHeader, siblingDirs: directories.filter{ $0.basename != moduleName }))
                return .none
            }
            // In this case, 'PublicHeadersDir' is also expected to contain no header files.
            if headers.count != 0 {
                diagnosticsEmitter.emit(.umbrellaHeaderParentDirHasSiblingHeaders(targetName: targetName, umbrellaHeader: nestedUmbrellaHeader, siblingHeaders: headers))
                return .none
            }
            return .umbrellaHeader(nestedUmbrellaHeader)
        }

        /// Check for the common mistake of naming the nested umbrella header 'TargetName.h' instead of 'ModuleName.h'.
        let misnamedNestedUmbrellaHeader = publicHeadersDir.appending(components: moduleName, targetName + ".h")
        if fileSystem.isFile(misnamedNestedUmbrellaHeader) {
            diagnosticsEmitter.emit(.misnamedUmbrellaHeader(misnamedUmbrellaHeader: misnamedNestedUmbrellaHeader, umbrellaHeader: nestedUmbrellaHeader))
        }

        // Otherwise, if 'PublicHeadersDir' contains only header files and no subdirectories, use it as the umbrella directory.
        if headers.count == entries.count {
            return .umbrellaDirectory(publicHeadersDir)
        }

        // Otherwise, the target's public headers are considered to be incompatible with modules.  Per the original design, though, an umbrella directory is still created for them.  This will lead to build failures if those headers are included and they are not compatible with modules.  A future evolution proposal should revisit these semantics, especially to make it easier to existing wrap C source bases that are incompatible with modules.
        return .umbrellaDirectory(publicHeadersDir)
    }

    /// Generates a module map based of the specified type, throwing an error if anything goes wrong.  Any diagnostics are added to the receiver's diagnostics engine.
    public func generateModuleMap(type: GeneratedModuleMapType, at path: AbsolutePath) throws {
        var moduleMap = "module \(moduleName) {\n"
        switch type {
        case .umbrellaHeader(let hdr):
            moduleMap.append("    umbrella header \"\(hdr.moduleEscapedPathString)\"\n")
        case .umbrellaDirectory(let dir):
            moduleMap.append("    umbrella \"\(dir.moduleEscapedPathString)\"\n")
        }
        moduleMap.append(
            """
                export *
            }

            """
        )

        // FIXME: This doesn't belong here.
        try fileSystem.createDirectory(path.parentDirectory, recursive: true)

        // If the file exists with the identical contents, we don't need to rewrite it.
        // Otherwise, compiler will recompile even if nothing else has changed.
        if let contents = try? fileSystem.readFileContents(path).validDescription, contents == moduleMap {
            return
        }
        try fileSystem.writeFileContents(path, string: moduleMap)
    }
}


/// A type of module map to generate.
public enum GeneratedModuleMapType {
    case umbrellaHeader(AbsolutePath)
    case umbrellaDirectory(AbsolutePath)
}

public extension ModuleMapType {
    /// Returns the type of module map to generate for this kind of module map, or nil to not generate one at all.
    var generatedModuleMapType: GeneratedModuleMapType? {
        switch self {
        case .umbrellaHeader(let path): return .umbrellaHeader(path)
        case .umbrellaDirectory(let path): return .umbrellaDirectory(path)
        case .none, .custom(_): return nil
        }
    }
}

private extension Basics.Diagnostic {

    /// Warning emitted if the public-headers directory is missing.
    static func missingPublicHeadersDirectory(targetName: String, publicHeadersDir: AbsolutePath) -> Self {
        .warning("no include directory found for target '\(targetName)'; libraries cannot be imported without public headers")
    }

    /// Error emitted if the public-headers directory is inaccessible.
    static func inaccessiblePublicHeadersDirectory(targetName: String, publicHeadersDir: AbsolutePath, fileSystemError: Error) -> Self {
        .error("cannot access public-headers directory for target '\(targetName)': \(String(describing: fileSystemError))")
    }

    /// Warning emitted if a misnamed umbrella header was found.
    static func misnamedUmbrellaHeader(misnamedUmbrellaHeader: AbsolutePath, umbrellaHeader: AbsolutePath) -> Self {
        .warning("\(misnamedUmbrellaHeader) should be renamed to \(umbrellaHeader) to be used as an umbrella header")
    }

    /// Error emitted if there are directories next to a top-level umbrella header.
    static func umbrellaHeaderHasSiblingDirectories(targetName: String, umbrellaHeader: AbsolutePath, siblingDirs: Set<AbsolutePath>) -> Self {
        .error("target '\(targetName)' has invalid header layout: umbrella header found at '\(umbrellaHeader)', but directories exist next to it: \(siblingDirs.map({ String(describing: $0) }).sorted().joined(separator: ", ")); consider removing them")
    }

    /// Error emitted if there are other directories next to the parent directory of a nested umbrella header.
    static func umbrellaHeaderParentDirHasSiblingDirectories(targetName: String, umbrellaHeader: AbsolutePath, siblingDirs: Set<AbsolutePath>) -> Self {
        .error("target '\(targetName)' has invalid header layout: umbrella header found at '\(umbrellaHeader)', but more than one directory exists next to its parent directory: \(siblingDirs.map({ String(describing: $0) }).sorted().joined(separator: ", ")); consider reducing them to one")
    }

    /// Error emitted if there are other headers next to the parent directory of a nested umbrella header.
    static func umbrellaHeaderParentDirHasSiblingHeaders(targetName: String, umbrellaHeader: AbsolutePath, siblingHeaders: Set<AbsolutePath>) -> Self {
        .error("target '\(targetName)' has invalid header layout: umbrella header found at '\(umbrellaHeader)', but additional header files exist: \((siblingHeaders.map({ String(describing: $0) }).sorted().joined(separator: ", "))); consider reducing them to one")
    }
}
