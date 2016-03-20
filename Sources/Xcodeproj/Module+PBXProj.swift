/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors

 -----------------------------------------------------------------

 In an effort to provide:

  1. Unique reference identifiers
  2. Human readable reference identifiers
  3. Stable reference identifiers

 (as opposed to the generated UUIDs Xcode typically generates)

 We create identifiers with a constant-length unique prefix and
 a unique suffix where the suffix is the filename or module name
 and since we guarantee uniqueness at the PackageDescription
 layer for these properties we satisfy the above constraints.
*/

import struct Utility.Toolchain
import struct Utility.Path
import PackageType

let rootObjectReference =                           "__RootObject_"
let rootBuildConfigurationListReference =           "___RootConfs_"
let rootDebugBuildConfigurationReference =          "_______Debug_"
let rootReleaseBuildConfigurationReference =        "_____Release_"
let rootGroupReference =                            "___RootGroup_"
let productsGroupReference =                        "____Products_"
let testProductsGroupReference =                    "TestProducts_"
let sourcesGroupReference =                         "_____Sources_"
let testsGroupReference =                           "_______Tests_"
let linkPhaseFileRefPrefix =                        "_LinkFileRef_"
let sourceGroupFileRefPrefix =                      "__PBXFileRef_"
let compilePhaseFileRefPrefix =                     "__src_cc_ref_"

extension Module {
    var dependencyReference: String           { return "__Dependency_\(c99name)" }
    var productReference: String              { return "_____Product_\(c99name)" }
    var targetReference: String               { return "______Target_\(c99name)" }
    var groupReference: String                { return "_______Group_\(c99name)" }
    var configurationListReference: String    { return "_______Confs_\(c99name)" }
    var debugConfigurationReference: String   { return "___DebugConf_\(c99name)" }
    var releaseConfigurationReference: String { return "_ReleaseConf_\(c99name)" }
    var compilePhaseReference: String         { return "CompilePhase_\(c99name)" }
    var linkPhaseReference: String            { return "___LinkPhase_\(c99name)" }
}

func fileRef(forLinkPhaseChild module: Module) -> String {
    return linkPhaseFileRefPrefix + module.c99name
}

private func fileRef(suffixForModuleSourceFile path: String, srcroot: String) -> String {
    let path = Path(path).relative(to: srcroot)
    return path.characters.map{ c -> String in
        switch c {
        case "\\":
            return "\\\\"
        case "'":
            return "\'"
        default:
            return "\(c)"
        }
    }.joined(separator: "")
}

func fileRefs(forModuleSources module: XcodeModule, srcroot: String) -> [(String, String)] {
    return module.sources.relativePaths.map { relativePath in
        let path = Path.join(module.sources.root, relativePath)
        let suffix = fileRef(suffixForModuleSourceFile: path, srcroot: srcroot)
        return ("'\(sourceGroupFileRefPrefix)\(suffix)'", relativePath)
    }
}

func fileRefs(forCompilePhaseSourcesInModule module: XcodeModule, srcroot: String) -> [(String, String)] {
    return fileRefs(forModuleSources: module, srcroot: srcroot).map { ref1, relativePath in
        let path = Path.join(module.sources.root, relativePath)
        let suffix = fileRef(suffixForModuleSourceFile: path, srcroot: srcroot)
        return (ref1, "'\(compilePhaseFileRefPrefix)\(suffix)'")
    }
}

extension XcodeModule {
    private var isLibrary: Bool {
        return type == .Library
    }

    var type: String {
        if self is TestModule {
            return "com.apple.product-type.bundle.unit-test"
        } else if isLibrary {
            return "com.apple.product-type.framework"
        } else {
            return "com.apple.product-type.tool"
        }
    }

    var explicitFileType: String {
        func suffix() -> String {
            if self is TestModule {
                return "wrapper.cfbundle"
            } else if isLibrary {
                return "framework"
            } else {
                return "executable"
            }
        }
        return "compiled.mach-o.\(suffix())"
    }

    var productPath: String {
        if self is TestModule {
            return "\(c99name).xctest"
        } else if isLibrary {
            return "\(c99name).framework"
        } else {
            return name
        }
    }

    var linkPhaseFileRefs: String {
        return recursiveDependencies.map{ fileRef(forLinkPhaseChild: $0) }.joined(separator: ", ")
    }

    var nativeTargetDependencies: String {
        return dependencies.map{ $0.dependencyReference }.joined(separator: ", ")
    }

    var productName: String {    
       return "'$(TARGET_NAME)'"
    }

    var debugBuildSettings: String {
        var buildSettings = commonBuildSettings
        buildSettings["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone"

        return buildSettings.map{ "\($0) = \($1);" }.joined(separator: " ")
    }

    var releaseBuildSettings: String {
        let buildSettings = commonBuildSettings
        return buildSettings.map{ "\($0) = \($1);" }.joined(separator: " ")
    }

    private var commonBuildSettings: [String: String] {
        var buildSettings = ["PRODUCT_NAME": productName]
        buildSettings["PRODUCT_MODULE_NAME"] = c99name
        buildSettings["OTHER_SWIFT_FLAGS"] = "-DXcode"
        buildSettings["MACOSX_DEPLOYMENT_TARGET"] = "'10.10'"

        // prevents Xcode project upgrade warnings
        buildSettings["COMBINE_HIDPI_IMAGES"] = "YES"

        //FIXME xcode can't find local headers from modulemap
        buildSettings["USER_HEADER_SEARCH_PATHS"] = "'$(SRCROOT)/Packages/**'"

        if self is TestModule {
            buildSettings["EMBEDDED_CONTENT_CONTAINS_SWIFT"] = "YES"

            //FIXME this should not be required
            buildSettings["LD_RUNPATH_SEARCH_PATHS"] = "'@loader_path/../Frameworks'"

        } else {

            //FIXME we should not have to set this ourselves, and in fact
            // it is problematic because now you must regenerate the xcodeproj
            // whenever the toolchain changes :(
            // static linking would be better since that is what we are meant
            // to do while swift has no ABI compatability.
            // probably the real solution is to generate frameworks since then
            // Xcode will embed the swift runtime libs
            buildSettings["LD_RUNPATH_SEARCH_PATHS"] = "'\(Toolchain.prefix)/usr/lib/swift/macosx'"

            if isLibrary {
                buildSettings["ENABLE_TESTABILITY"] = "YES"
                buildSettings["DYLIB_INSTALL_NAME_BASE"] = "'$(CONFIGURATION_BUILD_DIR)'"
                if let modulemap = modulemap {
                    buildSettings["DEFINES_MODULE"] = "YES"
                    buildSettings["MODULEMAP_FILE"] = modulemap
                }
            } else {
                // override default behavior, instead link dynamically
                buildSettings["SWIFT_FORCE_STATIC_LINK_STDLIB"] = "NO"
                buildSettings["SWIFT_FORCE_DYNAMIC_LINK_STDLIB"] = "YES"
            }
        }

        return buildSettings
    }
}


extension XcodeModule {
    var blueprintIdentifier: String {
        return targetReference
    }

    var buildableName: String {
        if isLibrary && !(self is TestModule) {
            return "lib\(productPath)"
        } else {
            return productPath
        }
    }

    var blueprintName: String {
        return name
    }
}
