//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import class PackageModel.BinaryTarget
import class PackageModel.ClangTarget
import class PackageModel.MixedTarget
import class PackageModel.SwiftTarget
import class PackageModel.SystemLibraryTarget

extension BuildPlan {
    /// Plan a Clang target.
    func plan(clangTarget: ClangTargetBuildDescription) throws {
        for case .target(let dependency, _) in try clangTarget.target.recursiveDependencies(satisfying: buildEnvironment) {
            switch dependency.underlyingTarget {
            case is SwiftTarget:
                if case let .swift(dependencyTargetDescription)? = targetMap[dependency] {
                    if let moduleMap = dependencyTargetDescription.moduleMap {
                        clangTarget.additionalFlags += ["-fmodule-map-file=\(moduleMap.pathString)"]
                    }
                }

            case let target as ClangTarget where target.type == .library:
                // Setup search paths for C dependencies:
                clangTarget.additionalFlags += ["-I", target.includeDir.pathString]

                // Add the modulemap of the dependency if it has one.
                if case let .clang(dependencyTargetDescription)? = targetMap[dependency] {
                    if let moduleMap = dependencyTargetDescription.moduleMap {
                        clangTarget.additionalFlags += ["-fmodule-map-file=\(moduleMap.pathString)"]
                    }
                }
            case let target as MixedTarget where target.type == .library:
                // Add the modulemap of the dependency.
                if case let .mixed(dependencyTargetDescription)? = targetMap[dependency] {
                    // Add the dependency's modulemap.
                    clangTarget.additionalFlags.append(
                        "-fmodule-map-file=\(dependencyTargetDescription.moduleMap.pathString)"
                    )

                    // Add the dependency's public headers.
                    clangTarget.additionalFlags += [ "-I", dependencyTargetDescription.publicHeadersDir.pathString ]

                    // Add the dependency's public VFS overlay.
                    clangTarget.additionalFlags += [
                        "-ivfsoverlay", dependencyTargetDescription.allProductHeadersOverlay.pathString
                    ]
                }
            case let target as SystemLibraryTarget:
                clangTarget.additionalFlags += ["-fmodule-map-file=\(target.moduleMapPath.pathString)"]
                clangTarget.additionalFlags += try pkgConfig(for: target).cFlags
            case let target as BinaryTarget:
                if case .xcframework = target.kind {
                    let libraries = try self.parseXCFramework(for: target)
                    for library in libraries {
                        library.headersPaths.forEach {
                            clangTarget.additionalFlags += ["-I", $0.pathString]
                        }
                        clangTarget.libraryBinaryPaths.insert(library.libraryPath)
                    }
                }
            default: continue
            }
        }
    }
}
