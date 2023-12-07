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

import struct Basics.InternalError
import class PackageModel.BinaryTarget
import class PackageModel.ClangTarget
import class PackageModel.MixedTarget
import class PackageModel.SystemLibraryTarget

extension BuildPlan {
    func plan(swiftTarget: SwiftTargetBuildDescription) throws {
        // We need to iterate recursive dependencies because Swift compiler needs to see all the targets a target
        // depends on.
        for case .target(let dependency, _) in try swiftTarget.target.recursiveDependencies(satisfying: buildEnvironment) {
            switch dependency.underlyingTarget {
            case let underlyingTarget as ClangTarget where underlyingTarget.type == .library:
                guard case let .clang(target)? = targetMap[dependency] else {
                    throw InternalError("unexpected clang target \(underlyingTarget)")
                }
                // Add the path to modulemap of the dependency. Currently we require that all Clang targets have a
                // modulemap but we may want to remove that requirement since it is valid for a target to exist without
                // one. However, in that case it will not be importable in Swift targets. We may want to emit a warning
                // in that case from here.
                guard let moduleMap = target.moduleMap else { break }
                swiftTarget.appendClangFlags(
                    "-fmodule-map-file=\(moduleMap.pathString)",
                    "-I", target.clangTarget.includeDir.pathString
                )
            case let target as SystemLibraryTarget:
                swiftTarget.additionalFlags += ["-Xcc", "-fmodule-map-file=\(target.moduleMapPath.pathString)"]
                swiftTarget.additionalFlags += try pkgConfig(for: target).cFlags
            case let target as BinaryTarget:
                if case .xcframework = target.kind {
                    let libraries = try self.parseXCFramework(for: target)
                    for library in libraries {
                        library.headersPaths.forEach {
                            swiftTarget.additionalFlags += ["-I", $0.pathString, "-Xcc", "-I", "-Xcc", $0.pathString]
                        }
                        swiftTarget.libraryBinaryPaths.insert(library.libraryPath)
                    }
                }
            case let underlyingTarget as MixedTarget where underlyingTarget.type == .library:
                guard case let .mixed(target)? = targetMap[dependency] else {
                    throw InternalError("unexpected mixed target \(underlyingTarget)")
                }

                // Add the dependency's modulemap.
                swiftTarget.appendClangFlags(
                    "-fmodule-map-file=\(target.moduleMap.pathString)"
                )

                // Add the dependency's public headers.
                swiftTarget.appendClangFlags("-I", target.publicHeadersDir.pathString)
            default:
                break
            }
        }
    }
}
