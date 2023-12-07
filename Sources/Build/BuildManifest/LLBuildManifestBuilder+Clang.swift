//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2015-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct LLBuildManifest.Node
import struct Basics.AbsolutePath
import struct Basics.InternalError
import class PackageGraph.ResolvedTarget
import PackageModel

extension LLBuildManifestBuilder {
    /// Create a llbuild target for a Clang target description and returns the Clang target's outputs.
    @discardableResult
    func createClangCompileCommand(
        _ target: ClangTargetBuildDescription,
        addTargetCmd: Bool = true,
        inputs: [Node] = [],
        createResourceBundle: Bool = true
    ) throws -> [Node] {
        let standards = [
            (target.clangTarget.cxxLanguageStandard, SupportedLanguageExtension.cppExtensions),
            (target.clangTarget.cLanguageStandard, SupportedLanguageExtension.cExtensions),
        ]

        var inputs: [Node] = inputs

        if createResourceBundle {
            // Add resources node as the input to the target. This isn't great because we
            // don't need to block building of a module until its resources are assembled but
            // we don't currently have a good way to express that resources should be built
            // whenever a module is being built.
            if let resourcesNode = try self.createResourcesBundle(for: .clang(target)) {
                inputs.append(resourcesNode)
            }
        }

        func addStaticTargetInputs(_ target: ResolvedTarget) {
            if case .swift(let desc)? = self.plan.targetMap[target], target.type == .library {
                inputs.append(file: desc.moduleOutputPath)
            } else if case .mixed(let desc)? = plan.targetMap[target], target.type == .library {
                inputs.append(file: desc.swiftTargetBuildDescription.moduleOutputPath)
            }
        }

        for dependency in target.target.dependencies(satisfying: self.buildEnvironment) {
            switch dependency {
            case .target(let target, _):
                addStaticTargetInputs(target)

            case .product(let product, _):
                switch product.type {
                case .executable, .snippet, .library(.dynamic), .macro:
                    guard let planProduct = plan.productMap[product] else {
                        throw InternalError("unknown product \(product)")
                    }
                    // Establish a dependency on binary of the product.
                    let binary = try planProduct.binaryPath
                    inputs.append(file: binary)

                case .library(.automatic), .library(.static), .plugin:
                    for target in product.targets {
                        addStaticTargetInputs(target)
                    }
                case .test:
                    break
                }
            }
        }

        for binaryPath in target.libraryBinaryPaths {
            let path = destinationPath(forBinaryAt: binaryPath)
            if self.fileSystem.isDirectory(binaryPath) {
                inputs.append(directory: path)
            } else {
                inputs.append(file: path)
            }
        }

        var objectFileNodes: [Node] = []

        for path in try target.compilePaths() {
            let isCXX = path.source.extension.map { SupportedLanguageExtension.cppExtensions.contains($0) } ?? false
            let isC = path.source.extension.map { $0 == SupportedLanguageExtension.c.rawValue } ?? false

            var args = try target.basicArguments(isCXX: isCXX, isC: isC)

            args += ["-MD", "-MT", "dependencies", "-MF", path.deps.pathString]

            // Add language standard flag if needed.
            if let ext = path.source.extension {
                for (standard, validExtensions) in standards {
                    if let standard, validExtensions.contains(ext) {
                        args += ["-std=\(standard)"]
                    }
                }
            }

            args += ["-c", path.source.pathString, "-o", path.object.pathString]

            let clangCompiler = try buildParameters.toolchain.getClangCompiler().pathString
            args.insert(clangCompiler, at: 0)

            let objectFileNode: Node = .file(path.object)
            objectFileNodes.append(objectFileNode)

            self.manifest.addClangCmd(
                name: path.object.pathString,
                description: "Compiling \(target.target.name) \(path.filename)",
                inputs: inputs + [.file(path.source)],
                outputs: [objectFileNode],
                arguments: args,
                dependencies: path.deps.pathString
            )
        }

        try addBuildToolPlugins(.clang(target))

        if addTargetCmd {
            self.addTargetCmd(
                target: target.target,
                isTestTarget: target.isTestTarget,
                inputs: objectFileNodes
            )
        }

        return objectFileNodes
    }
}
