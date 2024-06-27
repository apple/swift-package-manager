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
import class PackageModel.BinaryModule
import class PackageModel.ClangModule
import class PackageModel.SystemLibraryModule
import class PackageModel.ProvidedLibraryModule

extension BuildPlan {
    func plan(swiftTarget: SwiftModuleBuildDescription) throws {
        // We need to iterate recursive dependencies because Swift compiler needs to see all the targets a target
        // depends on.
        let environment = swiftTarget.buildParameters.buildEnvironment
        for case .module(let dependency, _) in try swiftTarget.target.recursiveDependencies(satisfying: environment) {
            switch dependency.underlying {
            case let underlyingTarget as ClangModule where underlyingTarget.type == .library:
                guard case let .clang(target)? = targetMap[dependency.id] else {
                    throw InternalError("unexpected clang target \(underlyingTarget)")
                }
                // Add the path to modulemap of the dependency. Currently we require that all Clang targets have a
                // modulemap but we may want to remove that requirement since it is valid for a target to exist without
                // one. However, in that case it will not be importable in Swift targets. We may want to emit a warning
                // in that case from here.
                guard let moduleMap = target.moduleMap else { break }
                swiftTarget.additionalFlags += [
                    "-Xcc", "-fmodule-map-file=\(moduleMap.pathString)",
                    "-Xcc", "-I", "-Xcc", target.clangTarget.includeDir.pathString,
                ]
            case let target as SystemLibraryModule:
                swiftTarget.additionalFlags += ["-Xcc", "-fmodule-map-file=\(target.moduleMapPath.pathString)"]
                swiftTarget.additionalFlags += try pkgConfig(for: target).cFlags
            case let target as BinaryModule:
                if case .xcframework = target.kind {
                    let libraries = try self.parseXCFramework(for: target, triple: swiftTarget.buildParameters.triple)
                    for library in libraries {
                        library.headersPaths.forEach {
                            swiftTarget.additionalFlags += ["-I", $0.pathString, "-Xcc", "-I", "-Xcc", $0.pathString]
                        }
                        swiftTarget.libraryBinaryPaths.insert(library.libraryPath)
                    }
                }
            case let target as ProvidedLibraryModule:
                swiftTarget.additionalFlags += [
                    "-I", target.path.pathString
                ]
            default:
                break
            }
        }
    }

}
