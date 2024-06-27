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
import struct Basics.RelativePath

extension LLBuildManifestBuilder {
    /// Adds command for creating the resources bundle of the given target.
    ///
    /// Returns the virtual node that will build the entire bundle.
    func createResourcesBundle(
        for target: ModuleBuildDescription
    ) throws -> Node? {
        guard let bundlePath = target.bundlePath else { return nil }

        var outputs: [Node] = []

        let infoPlistDestination = try RelativePath(validating: "Info.plist")

        // Create a copy command for each resource file.
        for resource in target.resources {
            switch resource.rule {
            case .copy, .process:
                let destination = try bundlePath.appending(resource.destination)
                let (_, output) = addCopyCommand(from: resource.path, to: destination)
                outputs.append(output)
            case .embedInCode:
                break
            }
        }

        // Create a copy command for the Info.plist if a resource with the same name doesn't exist yet.
        if let infoPlistPath = target.resourceBundleInfoPlistPath {
            let destination = bundlePath.appending(infoPlistDestination)
            let (_, output) = addCopyCommand(from: infoPlistPath, to: destination)
            outputs.append(output)
        }

        let cmdName = target.llbuildResourcesCmdName
        self.manifest.addPhonyCmd(name: cmdName, inputs: outputs, outputs: [.virtual(cmdName)])

        return .virtual(cmdName)
    }
}
