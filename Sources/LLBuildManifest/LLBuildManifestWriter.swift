//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics

private let namesToExclude = [".git", ".build"]

public struct LLBuildManifestWriter {
    private let manifest: LLBuildManifest
    // FIXME: since JSON is a superset of YAML and we don't need to parse these manifests,
    // we should just use `JSONEncoder` instead.
    private var buffer = """
    client:
      name: basic
      file-system: device-agnostic
    tools: {}

    """

    private init(manifest: LLBuildManifest) {
        self.manifest = manifest

        self.render(targets: manifest.targets)

        self.buffer += "default: \(manifest.defaultTarget.asJSON)\n"

        self.render(nodes: manifest.commands.values.flatMap { $0.tool.inputs + $0.tool.outputs })

        self.render(commands: manifest.commands)
    }

    public static func write(_ manifest: LLBuildManifest, at path: AbsolutePath, fileSystem: FileSystem) throws {
        let writer = LLBuildManifestWriter(manifest: manifest)

        try fileSystem.writeFileContents(path, string: writer.buffer)
    }

    private mutating func render(targets: [LLBuildManifest.TargetName: Target]) {
        self.buffer += "targets:\n"
        for (_, target) in targets.sorted(by: { $0.key < $1.key }) {
            self.buffer += "  \(target.name.asJSON): \(target.nodes.map(\.name).sorted().asJSON)\n"
        }
    }

    private mutating func render(nodes: [Node]) {
        // We need to explicitly configure certain kinds of nodes.
        let directoryStructureNodes = Set(nodes.filter { $0.kind == .directoryStructure })
            .sorted(by: { $0.name < $1.name })
        let commandTimestampNodes = Set(nodes.filter { $0.attributes?.isCommandTimestamp == true })
            .sorted(by: { $0.name < $1.name })
        let mutatedNodes = Set(nodes.filter { $0.attributes?.isMutated == true })
            .sorted(by: { $0.name < $1.name })

        if !directoryStructureNodes.isEmpty || !mutatedNodes.isEmpty || !commandTimestampNodes.isEmpty {
            self.buffer += "nodes:\n"
        }

        for node in directoryStructureNodes {
            self.render(directoryStructure: node)
        }

        for node in commandTimestampNodes {
            self.render(isCommandTimestamp: node)
        }

        for node in mutatedNodes {
            self.render(isMutated: node)
        }
    }

    private mutating func render(directoryStructure node: Node) {
        self.buffer += """
          \(node.asJSON):
            is-directory-structure: true
            content-exclusion-patterns: \(namesToExclude.asJSON)

        """
    }

    private mutating func render(isCommandTimestamp node: Node) {
        self.buffer += """
          \(node.asJSON):
            is-command-timestamp: true

        """
    }

    private mutating func render(isMutated node: Node) {
        self.buffer += """
          \(node.asJSON):
            is-mutated: true

        """
    }

    private mutating func render(commands: [LLBuildManifest.CmdName: Command]) {
        self.buffer += "commands:\n"
        for (_, command) in commands.sorted(by: { $0.key < $1.key }) {
            self.buffer += "  \(command.name.asJSON):\n"

            let tool = command.tool

            var manifestToolWriter = ManifestToolStream()
            manifestToolWriter["tool"] = tool
            manifestToolWriter["inputs"] = tool.inputs
            manifestToolWriter["outputs"] = tool.outputs

            if tool.alwaysOutOfDate {
                manifestToolWriter["always-out-of-date"] = "true"
            }

            tool.write(to: &manifestToolWriter)

            self.buffer += "\(manifestToolWriter.buffer)\n"
        }
    }
}

public struct ManifestToolStream {
    fileprivate var buffer = ""

    public subscript(key: String) -> Int {
        get { fatalError() }
        set {
            self.buffer += "    \(key): \(newValue.description.asJSON)\n"
        }
    }

    public subscript(key: String) -> String {
        get { fatalError() }
        set {
            self.buffer += "    \(key): \(newValue.asJSON)\n"
        }
    }

    public subscript(key: String) -> ToolProtocol {
        get { fatalError() }
        set {
            self.buffer += "    \(key): \(type(of: newValue).name)\n"
        }
    }

    public subscript(key: String) -> AbsolutePath {
        get { fatalError() }
        set {
            self.buffer += "    \(key): \(newValue.pathString.asJSON)\n"
        }
    }

    public subscript(key: String) -> [AbsolutePath] {
        get { fatalError() }
        set {
            self.buffer += "    \(key): \(newValue.map(\.pathString).asJSON)\n"
        }
    }

    public subscript(key: String) -> [Node] {
        get { fatalError() }
        set {
            self.buffer += "    \(key): \(newValue.map(\.encodingName).asJSON)\n"
        }
    }

    public subscript(key: String) -> Bool {
        get { fatalError() }
        set {
            self.buffer += "    \(key): \(newValue.description)\n"
        }
    }

    public subscript(key: String) -> [String] {
        get { fatalError() }
        set {
            self.buffer += "    \(key): \(newValue.asJSON)\n"
        }
    }

    public subscript(key: String) -> [String: String] {
        get { fatalError() }
        set {
            self.buffer += "    \(key):\n"
            for (key, value) in newValue.sorted(by: { $0.key < $1.key }) {
                self.buffer += "      \(key.asJSON): \(value.asJSON)\n"
            }
        }
    }

    package subscript(key: String) -> Environment {
        get { fatalError() }
        set {
            self.buffer += "    \(key):\n"
            for (key, value) in newValue.sorted(by: { $0.key < $1.key }) {
                self.buffer += "      \(key.rawValue.asJSON): \(value.asJSON)\n"
            }
        }
    }
}

extension [String] {
    fileprivate var asJSON: String {
        """
        [\(self.map(\.asJSON).joined(separator: ","))]
        """
    }
}

extension Node {
    fileprivate var asJSON: String {
        self.encodingName.asJSON
    }
}

extension Node {
    fileprivate var encodingName: String {
        switch kind {
        case .virtual, .file:
            return name
        case .directory, .directoryStructure:
            return name + "/"
        }
    }
}

extension String {
    fileprivate var asJSON: String {
        "\"\(self.jsonEscaped)\""
    }

    private var jsonEscaped: String {
        // See RFC7159 for reference: https://tools.ietf.org/html/rfc7159
        String(decoding: self.utf8.flatMap { character -> [UInt8] in
            // Handle string escapes; we use constants here to directly match the RFC.
            switch character {
            // Literal characters.
            case 0x20 ... 0x21, 0x23 ... 0x5B, 0x5D ... 0xFF:
                return [character]

            // Single-character escaped characters.
            case 0x22: // '"'
                return [
                    0x5C, // '\'
                    0x22, // '"'
                ]
            case 0x5C: // '\\'
                return [
                    0x5C, // '\'
                    0x5C, // '\'
                ]
            case 0x08: // '\b'
                return [
                    0x5C, // '\'
                    0x62, // 'b'
                ]
            case 0x0C: // '\f'
                return [
                    0x5C, // '\'
                    0x66, // 'b'
                ]
            case 0x0A: // '\n'
                return [
                    0x5C, // '\'
                    0x6E, // 'n'
                ]
            case 0x0D: // '\r'
                return [
                    0x5C, // '\'
                    0x72, // 'r'
                ]
            case 0x09: // '\t'
                return [
                    0x5C, // '\'
                    0x74, // 't'
                ]

            // Multi-character escaped characters.
            default:
                return [
                    0x5C, // '\'
                    0x75, // 'u'
                    hexdigit(0),
                    hexdigit(0),
                    hexdigit(character >> 4),
                    hexdigit(character & 0xF),
                ]
            }
        }, as: UTF8.self)
    }
}

/// Convert an integer in 0..<16 to its hexadecimal ASCII character.
private func hexdigit(_ value: UInt8) -> UInt8 {
    value < 10 ? (0x30 + value) : (0x41 + value - 10)
}
