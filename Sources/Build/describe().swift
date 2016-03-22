/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import func POSIX.getenv
import func POSIX.mkdir
import func POSIX.fopen
import func libc.fclose
import PackageType
import Utility

/**
  - Returns: path to generated YAML for consumption by the llbuild based swift-build-tool
*/
public func describe(prefix: String, _ conf: Configuration, _ modules: [Module], _ products: [Product], Xcc: [String], Xld: [String], Xswiftc: [String]) throws -> String {

    guard modules.count > 0 else {
        throw Error.NoModules
    }

    let Xcc = Xcc.flatMap{ ["-Xcc", $0] }
    let Xld = Xld.flatMap{ ["-Xlinker", $0] }
    let prefix = try mkdir(prefix, conf.dirname)
    
    var nonTests = [Command]()
    var tests = [Command]()

    /// Appends the command to appropriate array
    func append(command: Command, buildable: Buildable) {
        if buildable.isTest {
            tests.append(command)
        } else {
            nonTests.append(command)
        }
    }

    var mkdirs = Set<String>()
    let swiftcArgs = Xcc + Xswiftc + verbosity.ccArgs

    for case let module as SwiftModule in modules {

        let otherArgs = swiftcArgs + module.Xcc + platformArgs()

        switch conf {
        case .Debug:
            var args = ["-j8","-Onone","-g","-D","SWIFT_PACKAGE"]
            args.append("-enable-testing")

        #if os(OSX)
            if let platformPath = Toolchain.platformPath {
                let path = Path.join(platformPath, "Developer/Library/Frameworks")
                args += ["-F", path]
            } else {
                throw Error.InvalidPlatformPath
            }
        #endif

            let node = IncrementalNode(module: module, prefix: prefix)
            let swiftc = SwiftcTool(
                inputs: node.inputs,
                outputs: node.outputs,
                executable: Toolchain.swiftc,
                moduleName: module.c99name,
                moduleOutputPath:  node.moduleOutputPath,
                importPaths: prefix,
                tempsPath: node.tempsPath,
                objects: node.objectPaths,
                otherArgs: args + otherArgs,
                sources: module.sources.paths,
                isLibrary: module.type == .Library) /// this must be set or swiftc compiles single source
                                                    /// file modules with a main() for some reason

            let command = Command(name: module.targetName, tool: swiftc)
            append(command, buildable: module)

            for o in node.objectPaths {
                mkdirs.insert(o.parentDirectory)
            }

        case .Release:
            let inputs = module.dependencies.map{ $0.targetName } + module.sources.paths
            var args = ["-c", "-emit-module", "-D", "SWIFT_PACKAGE", "-O", "-whole-module-optimization", "-I", prefix] + swiftcArgs
            let productPath = Path.join(prefix, "\(module.c99name).o")

            if module.type == .Library {
                args += ["-parse-as-library"]
            }

            let shell = ShellTool(
                description: "Compiling \(module.name)",
                inputs: inputs,
                outputs: [productPath, module.targetName],
                args: [Toolchain.swiftc, "-o", productPath] + args + module.sources.paths + otherArgs)

            let command = Command(name: module.targetName, tool: shell)
            append(command, buildable: module)
        }
    }

    //For C language Modules
    //FIXME: Probably needs more compiler options for debug and release modes
    //FIXME: Incremental builds
    //FIXME: Add support for executables
    for case let module as ClangModule in modules {
        
        //FIXME: Generate modulemaps if possible
        //Since we're not generating modulemaps currently we'll just emit empty module map file
        //if it not present
        if !module.moduleMapPath.isFile {
            try mkdir(module.moduleMapPath.parentDirectory)
            try fopen(module.moduleMapPath, mode: .Write) { fp in
                try fputs("\n", fp)
            }
        }
        
        let inputs = module.dependencies.map{ $0.targetName } + module.sources.paths
        let productPath = Path.join(prefix, "lib\(module.c99name).so")
        let wd = Path.join(prefix, "\(module.c99name).build")
        mkdirs.insert(wd)
        
        var args: [String] = []
    #if os(Linux)
         args += ["-fPIC"]
    #endif
    #if os(OSX)
        if let sysroot = Toolchain.sysroot {
           args += ["-isysroot", "\(sysroot)"]
        }
    #endif
        args += ["-fmodules", "-fmodule-name=\(module.name)"]
        args += ["-L\(prefix)"]
        args += ["-rpath", "\(prefix)"]
        
        for case let dep as ClangModule in module.dependencies {
            let includeFlag: String
            //add `-iquote` argument to the include directory of every target in the package in the
            //transitive closure of the target being built allowing the use of `#include "..."`
            //add `-I` argument to the include directory of every target outside the package in the
            //transitive closure of the target being built allowing the use of `#include <...>`
            //FIXME: To detect external deps we're checking if their path's parent.parent directory 
            //is `Packages` as external deps will get copied to `Packages` dir. There should be a
            //better way to do this.
            if dep.path.parentDirectory.parentDirectory.basename == "Packages" {
                includeFlag = "-I"
            } else {
                includeFlag = "-iquote"
            }
            args += [includeFlag, dep.path]
            args += ["-l\(dep.c99name)"] //FIXME: giving path to other module's -fmodule-map-file is not linking that module
        }
        
        switch conf {
        case .Debug:
            args += ["-g", "-O0"]
        case .Release:
            args += ["-O2"]
        }
        
        args += module.sources.paths
        args += ["-shared", "-o", productPath]

        let clang = ShellTool(
            description: "Compiling \(module.name)",
            inputs: inputs,
            outputs: [productPath, module.targetName],
            args: [Toolchain.clang] + args)
        
        let command = Command(name: module.targetName, tool: clang)
        append(command, buildable: module)
    }
    
    // make eg .build/debug/foo.build/subdir for eg. Sources/foo/subdir/bar.swift
    // TODO swift-build-tool should do this
    for dir in mkdirs {
        try mkdir(dir)
    }

    for product in products {

        let outpath = Path.join(prefix, product.outname)

        let objects: [String]
        switch conf {
        case .Release:
            objects = product.buildables.map{ Path.join(prefix, "\($0.c99name).o") }
        case .Debug:
            objects = product.buildables.flatMap{ return IncrementalNode(module: $0, prefix: prefix).objectPaths }
        }

        var args = [Toolchain.swiftc] + swiftcArgs

        switch product.type {
        case .Library(.Static):
            fatalError("Unimplemented")
        case .Test:
            #if os(OSX)
                args += ["-Xlinker", "-bundle"]

                if let platformPath = Toolchain.platformPath {
                    let path = Path.join(platformPath, "Developer/Library/Frameworks")
                    args += ["-F", path]
                } else {
                    throw Error.InvalidPlatformPath
                }

                // TODO should be llbuild rules
                if conf == .Debug {
                    try mkdir(outpath.parentDirectory)
                    try fopen(outpath.parentDirectory.parentDirectory, "Info.plist", mode: .Write) { fp in
                        try fputs(infoPlist(product), fp)
                    }
                }
            #else
                // HACK: To get a path to LinuxMain.swift, we just grab the
                //       parent directory of the first test module we can find.
                let firstTestModule = product.modules.flatMap{ $0 as? TestModule }.first!
                let testDirectory = firstTestModule.sources.root.parentDirectory
                let main = Path.join(testDirectory, "LinuxMain.swift")
                args.append(main)
                for module in product.modules {
                    args += module.Xcc
                }
                args.append("-emit-executable")
                args += ["-I", prefix]
            #endif
        case .Library(.Dynamic):
            args.append("-emit-library")
        case .Executable:
            args.append("-emit-executable")
            if conf == .Release {
                 args += ["-Xlinker", "-dead_strip"]
            }
        }

        if conf == .Debug {
            args += ["-g"]
        }
        args += platformArgs() //TODO don't need all these here or above: split outname
        args += Xld
        args += ["-L\(prefix)"]
        args += ["-Xlinker", "-rpath", "-Xlinker", "\(prefix)"]
        args += ["-o", outpath]
        args += objects

        let inputs = product.modules.flatMap{ [$0.targetName] + IncrementalNode(module: $0, prefix: prefix).inputs }

        let shell = ShellTool(
            description: "Linking \(outpath.prettyPath)",
            inputs: inputs,
            outputs: [product.targetName, outpath],
            args: args)

        let command = Command(name: product.targetName, tool: shell)
        append(command, buildable: product)
    }

    //Create Targets
    let nontestTarget = Target(name: "default", commands: nonTests)
    let testTarget = Target(name: "test", commands: tests)

    //Generate YAML String for the targets
    let yamlString = llbuildYAML(targets: [nontestTarget, testTarget])

    //Write YAML to file
    let yamlPath = "\(prefix).yaml"
    let fp = try fopen(yamlPath, mode: .Write)
    defer { fclose(fp) }
    try fputs(yamlString, fp)

    return yamlPath
}


extension Product {
    private var buildables: [SwiftModule] {
        return recursiveDependencies(modules.map{$0}).flatMap{ $0 as? SwiftModule }
    }
}
