/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import PackageModel
import PackageLoading
import Utility

extension Command {
    static func linkClangModule(_ product: Product, configuration conf: Configuration, prefix: String, otherArgs: [String], CC: String) throws -> Command {
        precondition(prefix.isAbsolute)
        precondition(product.containsOnlyClangModules)

        let clangModules = product.modules.flatMap { $0 as? ClangModule }
        var args = [String]()

        // Collect all the objects.
        var objects = [String]()
        var inputs = [String]()
        var linkFlags = [String]()
        for module in clangModules {
            let buildMeta = ClangModuleBuildMetadata(module: module, prefix: prefix, otherArgs: [])
            objects += buildMeta.objects
            inputs += buildMeta.inputs
            linkFlags += buildMeta.linkDependenciesFlags
        }

        args += try ClangModuleBuildMetadata.basicArgs() + otherArgs
        args += ["-L\(prefix)"]
        // Linux doesn't search executable directory for shared libs so embed runtime search path.
      #if os(Linux)
        args += ["-Xlinker", "-rpath=$ORIGIN"]
      #endif
        args += linkFlags
        args += objects

        switch product.type {
        case .Executable: break
        case .Library(.Dynamic):
            args += ["-shared"]
        case .Test, .Library(.Static):
            fatalError("Can't build \(product.name), \(product.type) is not yet supported.")
        }

        let productPath = Path.join(prefix, product.outname)
        args += ["-o", productPath]
        
        let shell = ShellTool(description: "Linking \(product.name)",
                              inputs: objects + inputs,
                              outputs: [productPath, product.targetName],
                              args: [CC] + args)
        
        return Command(node: product.targetName, tool: shell)
    }
}
