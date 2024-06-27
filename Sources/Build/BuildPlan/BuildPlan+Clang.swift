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

import class PackageModel.BinaryModule
import class PackageModel.ClangModule
import class PackageModel.SwiftModule
import class PackageModel.SystemLibraryModule

extension BuildPlan {
    /// Plan a Clang target.
    func plan(clangTarget: ClangModuleBuildDescription) throws {
        let dependencies = try clangTarget.target.recursiveDependencies(satisfying: clangTarget.buildEnvironment)

        for case .module(let dependency, _) in dependencies {
            switch dependency.underlying {
            case is SwiftModule:
                if case let .swift(dependencyTargetDescription)? = targetMap[dependency.id] {
                    if let moduleMap = dependencyTargetDescription.moduleMap {
                        clangTarget.additionalFlags += ["-fmodule-map-file=\(moduleMap.pathString)"]
                    }
                }

            case let target as ClangModule where target.type == .library:
                // Setup search paths for C dependencies:
                clangTarget.additionalFlags += ["-I", target.includeDir.pathString]

                // Add the modulemap of the dependency if it has one.
                if case let .clang(dependencyTargetDescription)? = targetMap[dependency.id] {
                    if let moduleMap = dependencyTargetDescription.moduleMap {
                        clangTarget.additionalFlags += ["-fmodule-map-file=\(moduleMap.pathString)"]
                    }
                }
            case let target as SystemLibraryModule:
                clangTarget.additionalFlags += ["-fmodule-map-file=\(target.moduleMapPath.pathString)"]
                clangTarget.additionalFlags += try pkgConfig(for: target).cFlags
            case let target as BinaryModule:
                if case .xcframework = target.kind {
                    let libraries = try self.parseXCFramework(for: target, triple: clangTarget.buildParameters.triple)
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
