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

import struct Basics.AbsolutePath
import struct LLBuildManifest.Node

extension LLBuildManifestBuilder {
    func createProductCommand(_ buildProduct: ProductBuildDescription) throws {
        let cmdName = try buildProduct.product.getCommandName(config: self.buildConfig)

        // Add dependency on Info.plist generation on Darwin platforms.
        let testInputs: [AbsolutePath]
        if buildProduct.product.type == .test
            && buildProduct.buildParameters.targetTriple.isDarwin()
            && buildProduct.buildParameters.testingParameters.experimentalTestOutput {
            let testBundleInfoPlistPath = try buildProduct.binaryPath.parentDirectory.parentDirectory.appending(component: "Info.plist")
            testInputs = [testBundleInfoPlistPath]

            self.manifest.addWriteInfoPlistCommand(
                principalClass: "\(buildProduct.product.targets[0].c99name).SwiftPMXCTestObserver",
                outputPath: testBundleInfoPlistPath
            )
        } else {
            testInputs = []
        }

        // Create a phony node to represent the entire target.
        let targetName = try buildProduct.product.getLLBuildTargetName(config: self.buildConfig)
        let output: Node = .virtual(targetName)

        switch buildProduct.product.type {
        case .library(.static):
            try self.manifest.addShellCmd(
                name: cmdName,
                description: "Archiving \(buildProduct.binaryPath.prettyPath())",
                inputs: (buildProduct.objects + [buildProduct.linkFileListPath]).map(Node.file),
                outputs: [.file(buildProduct.binaryPath)],
                arguments: try buildProduct.archiveArguments()
            )

        default:
            let inputs = try buildProduct.objects
                + buildProduct.dylibs.map { try $0.binaryPath }
                + [buildProduct.linkFileListPath]
                + testInputs

            let shouldCodeSign: Bool
            if case .executable = buildProduct.product.type,
               buildParameters.debuggingParameters.shouldEnableDebuggingEntitlement {
                shouldCodeSign = true
            } else {
                shouldCodeSign = false
            }

            let linkedBinarySuffix = shouldCodeSign ? "-unsigned" : ""
            let linkedBinaryPath = try AbsolutePath(validating: buildProduct.binaryPath.pathString + linkedBinarySuffix)

            try self.manifest.addShellCmd(
                name: cmdName,
                description: "Linking \(buildProduct.binaryPath.prettyPath())",
                inputs: inputs.map(Node.file),
                outputs: [.file(linkedBinaryPath)],
                arguments: try buildProduct.linkArguments(outputPathSuffix: linkedBinarySuffix)
            )

            if shouldCodeSign {
                let basename = try buildProduct.binaryPath.basename
                let plistPath = try buildProduct.binaryPath.parentDirectory
                    .appending(component: "\(basename)-entitlement.plist")
                self.manifest.addEntitlementPlistCommand(
                    entitlement: "com.apple.security.get-task-allow",
                    outputPath: plistPath
                )

                let cmdName = try buildProduct.product.getCommandName(config: self.buildConfig)
                let codeSigningOutput = Node.virtual(targetName + "-CodeSigning")
                try self.manifest.addShellCmd(
                    name: "\(cmdName)-entitlements",
                    description: "Applying debug entitlements to \(buildProduct.binaryPath.prettyPath())",
                    inputs: [linkedBinaryPath, plistPath].map(Node.file),
                    outputs: [codeSigningOutput],
                    arguments: buildProduct.codeSigningArguments(plistPath: plistPath, binaryPath: linkedBinaryPath)
                )

                try self.manifest.addShellCmd(
                    name: "\(cmdName)-codesigning",
                    description: "Applying debug entitlements to \(buildProduct.binaryPath.prettyPath())",
                    inputs: [codeSigningOutput],
                    outputs: [.file(buildProduct.binaryPath)],
                    arguments: ["mv", linkedBinaryPath.pathString, buildProduct.binaryPath.pathString]
                )
            }
        }

        self.manifest.addNode(output, toTarget: targetName)
        try self.manifest.addPhonyCmd(
            name: output.name,
            inputs: [.file(buildProduct.binaryPath)],
            outputs: [output]
        )

        if self.plan.graph.reachableProducts.contains(buildProduct.product) {
            if buildProduct.product.type != .test {
                self.addNode(output, toTarget: .main)
            }
            self.addNode(output, toTarget: .test)
        }

        self.manifest.addWriteLinkFileListCommand(
            objects: Array(buildProduct.objects),
            linkFileListPath: buildProduct.linkFileListPath
        )
    }
}
