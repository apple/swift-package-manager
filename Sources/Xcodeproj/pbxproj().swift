/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/


//TODO escaping


import POSIX
import PackageType
import Utility

public func pbxproj(srcroot: String, projectRoot: String, xcodeprojPath: String, modules: [XcodeModuleProtocol], externalModules: [XcodeModuleProtocol], products _: [Product], options: XcodeprojOptions, printer print: (String) -> Void) throws {

    // let rootModulesSet = Set(modules).subtract(Set(externalModules))
    let rootModulesSet = modules
    let nonTestRootModules = rootModulesSet.filter{ !($0 is TestModule) }
    let (tests, nonTests) = modules.partition{ $0 is TestModule }

    print("// !$*UTF8*$!")
    print("{")
    print("    archiveVersion = 1;")
    print("    classes = {};")
    print("    objectVersion = 46;")
    print("    rootObject = \(rootObjectReference);")

    print("    objects = {")

////// root object, ie. the Project itself
    print("        \(rootObjectReference) = {")
    print("            isa = PBXProject;")
    print("            attributes = {LastUpgradeCheck = 9999;};")   // we're generated: don’t upgrade check
    print("            buildConfigurationList = \(rootBuildConfigurationListReference);")
    print("            compatibilityVersion = 'Xcode 3.2';")
    print("            developmentRegion = English;")
    print("            hasScannedForEncodings = 0;")
    print("            knownRegions = (en);")
    print("            mainGroup = \(rootGroupReference);")
    print("            productRefGroup = \(productsGroupReference);")
    print("            projectDirPath = '';")
    print("            projectRoot = '';")
    print("            targets = (" + modules.map{ $0.targetReference }.joined(separator: ", ") + ");")
    print("        };")

////// Package.swift file
    let packageSwift = fileRef(inProjectRoot: "Package.swift", srcroot: srcroot)
    print("        \(packageSwift.0) = {")
    print("            isa = PBXFileReference;")
    print("            lastKnownFileType = sourcecode.swift;")
    print("            name = '\(packageSwift.1)';")
    print("            path = '\(Path(packageSwift.2).relative(to: projectRoot))';")
    print("            sourceTree = '<group>';")
    print("        };")

////// root group
    print("        \(rootGroupReference) = {")
    print("            isa = PBXGroup;")
    print("            children = (\(packageSwift.0), \(configsGroupReference), \(sourcesGroupReference), \(dependenciesGroupReference), \(testsGroupReference), \(productsGroupReference));")
    print("            sourceTree = '<group>';")
    print("        };")

////// modules group
    for module in modules {

        // the “Project Navigator” group for this module
        print("        \(module.groupReference) = {")
        print("            isa = PBXGroup;")
        print("            name = \(module.name);")
        print("            path = '\(Path(module.sources.root).relative(to: projectRoot))';")
        print("            sourceTree = '<group>';")
        print("            children = (" + fileRefs(forModuleSources: module, srcroot: srcroot).map{$0.0}.joined(separator: ", ") + ");")
        print("        };")

        // the contents of the “Project Navigator” group for this module
        for (ref, path) in fileRefs(forModuleSources: module, srcroot: srcroot) {
            print("        \(ref) = {")
            print("            isa = PBXFileReference;")
            print("            lastKnownFileType = \(module.fileType);")
            print("            name = '\(Path(path).relative(to: module.sources.root))';")
            print("            sourceTree = '<group>';")
            print("        };")
        }

        // the target reference for this module’s product
        print("        \(module.targetReference) = {")
        print("            isa = PBXNativeTarget;")
        print("            buildConfigurationList = \(module.configurationListReference);")
        print("            buildPhases = (\(module.compilePhaseReference), \(module.linkPhaseReference));")
        print("            buildRules = ();")
        print("            dependencies = (\(module.nativeTargetDependencies));")
        print("            name = \(module.name);")
        print("            productName = \(module.productName);")
        print("            productReference = \(module.productReference);")
        print("            productType = '\(module.productType)';")
        print("        };")

        // the product file reference
        print("        \(module.productReference) = {")
        print("            isa = PBXFileReference;")
        print("            explicitFileType = '\(module.explicitFileType)';")
        print("            path = '\(module.productPath)';")
        print("            sourceTree = BUILT_PRODUCTS_DIR;")
        print("        };")

        // sources build phase
        print("        \(module.compilePhaseReference) = {")
        print("            isa = PBXSourcesBuildPhase;")
        print("            files = (\(fileRefs(forCompilePhaseSourcesInModule: module, srcroot: srcroot).map{$1}.joined(separator: ", ")));")
        print("            runOnlyForDeploymentPostprocessing = 0;")
        print("        };")

        // link build phase
        print("        \(module.linkPhaseReference) = {")
        print("            isa = PBXFrameworksBuildPhase;")
        print("            files = (\(module.linkPhaseFileRefs));")
        print("            runOnlyForDeploymentPostprocessing = 0;")
        print("        };")

        // the fileRefs for the children in the build phases
        for (ref1, ref2) in fileRefs(forCompilePhaseSourcesInModule: module, srcroot: srcroot) + [(module.productReference, fileRef(forLinkPhaseChild: module))] {
            print("        \(ref2) = {")
            print("            isa = PBXBuildFile;")
            print("            fileRef = \(ref1);")
            print("        };")
        }

        // the target build configuration
        print("        \(module.configurationListReference) = {")
        print("            isa = XCConfigurationList;")
        print("            buildConfigurations = (\(module.debugConfigurationReference), \(module.releaseConfigurationReference));")
        print("            defaultConfigurationIsVisible = 0;")
        print("            defaultConfigurationName = Debug;")
        print("        };")
        print("        \(module.debugConfigurationReference) = {")
        print("            isa = XCBuildConfiguration;")
        print("            buildSettings = { \(module.getDebugBuildSettings(options)) };")
        print("            name = Debug;")
        print("        };")
        print("        \(module.releaseConfigurationReference) = {")
        print("            isa = XCBuildConfiguration;")
        print("            buildSettings = { \(module.getReleaseBuildSettings(options)) };")
        print("            name = Release;")
        print("        };")

        //TODO ^^ probably can consolidate this into the three kinds
        //TODO we use rather than have one per module

        // targets that depend on this target use these
        print("        \(module.dependencyReference) = {")
        print("            isa = PBXTargetDependency;")
        print("            target = \(module.targetReference);")
        print("        };")
    }

////// “Configs” group
    
    // The project-level xcconfig files.
    //
    // FIXME: Generate these into a sane path.
    let projectXCConfig = fileRef(inProjectRoot: Path.join(xcodeprojPath.basename, "Configs", "Project.xcconfig"), srcroot: Path.join(srcroot, projectRoot))
    try mkdir(projectXCConfig.2.parentDirectory)
    try Utility.fopen(projectXCConfig.2, mode: .Write) { fp in
        // Set the standard PRODUCT_NAME.
        try fputs("PRODUCT_NAME = $(TARGET_NAME)\n", fp)
        
        // Set SUPPORTED_PLATFORMS to all platforms.
        //
        // The goal here is to define targets which *can be* built for any
        // platform (although some might not work correctly). It is then up to
        // the integrating project to only set these targets up as dependencies
        // where appropriate.
        let supportedPlatforms = [
            "macosx",
            "iphoneos", "iphonesimulator",
            "tvos", "tvsimulator",
            "watchos", "watchsimulator"]
        try fputs("SUPPORTED_PLATFORMS = \(supportedPlatforms.joined(separator: " "))\n", fp)

        // Set a conservative default deployment target.
        //
        // We currently *must* do this for SwiftPM to be able to self-host in
        // Xcode (otherwise, the PackageDescription library will be incompatible
        // with the default deployment target we pass when building).
        //
        // FIXME: Eventually there should be a way for the project using Xcode
        // generation to have control over this.
        try fputs("MACOSX_DEPLOYMENT_TARGET = 10.10\n", fp)
        
        // Default to @rpath-based install names.
        //
        // The expectation is that the application or executable consuming these
        // products will need to establish the appropriate runpath search paths
        // so that all the products can be found in a relative manner.
        try fputs("DYLIB_INSTALL_NAME_BASE = @rpath\n", fp)

        // Propagate any user provided build flag overrides.
        //
        // FIXME: Need to get quoting correct here.
        if !options.Xcc.isEmpty {
            try fputs("OTHER_CFLAGS = \(options.Xcc.joined(separator: " "))\n", fp)
        }
        if !options.Xld.isEmpty {
            try fputs("OTHER_LDFLAGS = \(options.Xld.joined(separator: " "))\n", fp)
        }
        try fputs("OTHER_SWIFT_FLAGS = \((options.Xswiftc+["-DXcode"]).joined(separator: " "))\n", fp)
        
        // Prevents Xcode project upgrade warnings.
        try fputs("COMBINE_HIDPI_IMAGES = YES\n", fp)

        // Always disable use of headermaps.
        //
        // The semantics of the build should be explicitly defined by the
        // project structure, we don't want any additional behaviors not shared
        // with `swift build`.
        try fputs("USE_HEADERMAP = NO\n", fp)

        // If the user provided an overriding xcconfig path, include it here.
        if let path = options.xcconfigOverrides {
            try fputs("\n#include \"\(path)\"\n", fp)
        }
    }
    let configs = [projectXCConfig]
    for configInfo in configs {
        print("        \(configInfo.0) = {")
        print("            isa = PBXFileReference;")
        print("            lastKnownFileType = text.xcconfig;")
        print("            name = '\(configInfo.1.basename)';")
        print("            path = '\(Path(configInfo.2).relative(to: projectRoot))';")
        print("            sourceTree = '<group>';")
        print("        };")
    }
    
    print("        \(configsGroupReference) = {")
    print("            isa = PBXGroup;")
    print("            children = (" + configs.map{ $0.0 }.joined(separator: ", ") + ");")
    print("            name = Configs;")
    print("            sourceTree = '<group>';")
    print("        };")

////// “Sources” group
    print("        \(sourcesGroupReference) = {")
    print("            isa = PBXGroup;")
    print("            children = (" + nonTestRootModules.map{ $0.groupReference }.joined(separator: ", ") + ");")
    print("            name = Sources;")
    print("            sourceTree = '<group>';")
    print("        };")

    if !externalModules.isEmpty {
        ////// “Dependencies” group
        print("        \(dependenciesGroupReference) = {")
        print("            isa = PBXGroup;")
        print("            children = (" + externalModules.map{ $0.groupReference }.joined(separator: ", ") + ");")
        print("            name = Dependencies;")
        print("            sourceTree = '<group>';")
        print("        };")
    }

////// “Tests” group
    if !tests.isEmpty {
        print("        \(testsGroupReference) = {")
        print("            isa = PBXGroup;")
        print("            children = (" + tests.map{ $0.groupReference }.joined(separator: ", ") + ");")
        print("            name = Tests;")
        print("            sourceTree = '<group>';")
        print("        };")
    }

    var productReferences: [String] = []
    
    if !tests.isEmpty {
        ////// “Product/Tests” group
        print("       \(testProductsGroupReference) = {")
        print("            isa = PBXGroup;")
        print("            children = (" + tests.map{ $0.productReference }.joined(separator: ", ") + ");")
        print("            name = Tests;")
        print("            sourceTree = '<group>';")
        print("        };")

        productReferences = [testProductsGroupReference]
    }

////// “Products” group
    productReferences += nonTests.map { $0.productReference }

    print("        \(productsGroupReference) = {")
    print("            isa = PBXGroup;")
    print("            children = (" + productReferences.joined(separator: ", ") + ");")
    print("            name = Products;")
    print("            sourceTree = '<group>';")
    print("        };")

////// primary build configurations
    print("        \(rootDebugBuildConfigurationReference) = {")
    print("            isa = XCBuildConfiguration;")
    print("            baseConfigurationReference = \(projectXCConfig.0);")
    print("            buildSettings = {};")
    print("            name = Debug;")
    print("        };")
    print("        \(rootReleaseBuildConfigurationReference) = {")
    print("            isa = XCBuildConfiguration;")
    print("            baseConfigurationReference = \(projectXCConfig.0);")
    print("            buildSettings = {};")
    print("            name = Release;")
    print("        };")
    print("        \(rootBuildConfigurationListReference) = {")
    print("            isa = XCConfigurationList;")
    print("            buildConfigurations = (\(rootDebugBuildConfigurationReference), \(rootReleaseBuildConfigurationReference));")
    print("            defaultConfigurationIsVisible = 0;")
    print("            defaultConfigurationName = Debug;")
    print("        };")
    print("    };")

////// done!
    print("}")
}
