//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import LLBuildManifest

import protocol TSCBasic.OutputByteStream

/// Serializes an LLBuildManifest graph to a .dot file
public struct DOTManifestSerializer {
    var kindCounter = [String: Int]()
    var hasEmittedStyling = Set<String>()
    let manifest: LLBuildManifest

    /// Creates a serializer that will serialize the given manifest.
    public init(manifest: LLBuildManifest) {
        self.manifest = manifest
    }

    /// Gets a unique label for a job name
    mutating func label(for command: Command) -> String {
        let toolName = "\(type(of: command.tool).name)"
        var label = toolName
        if let count = kindCounter[label] {
            label += " \(count)"
        }
        kindCounter[toolName, default: 0] += 1
        return label
    }

    /// Quote the name and escape the quotes and backslashes
    func quoteName(_ name: String) -> String {
        return "\"" + name.replacing("\"", with: "\\\"")
                          .replacing("\\", with: "\\\\") + "\""
    }

    public mutating func writeDOT(to stream: OutputByteStream) {
        stream.write("digraph Jobs {\n")
        for (name, command) in manifest.commands {
            let jobName = quoteName(label(for: command))
            if !hasEmittedStyling.contains(jobName) {
                stream.write("  \(jobName) [style=bold];")
                stream.write("// \(name)\n")
            }
            for input in command.tool.inputs {
                let inputName = quoteName(input.name)
                if hasEmittedStyling.insert(inputName).inserted {
                    stream.write("  \(inputName) [fontsize=12];\n")
                }
                stream.write("  \(inputName) -> \(jobName) [color=blue];\n")
            }
            for output in command.tool.outputs {
                let outputName = quoteName(output.name)
                if hasEmittedStyling.insert(outputName).inserted {
                    stream.write("  \(outputName) [fontsize=12];\n")
                }
                stream.write("  \(jobName) -> \(outputName) [color=green];\n")
            }
        }
        stream.write("}\n")
    }
}
