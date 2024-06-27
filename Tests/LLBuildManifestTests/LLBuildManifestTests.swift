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

import struct Basics.AbsolutePath
import class Foundation.PropertyListDecoder
@testable import LLBuildManifest
import _InternalTestSupport
import class TSCBasic.InMemoryFileSystem
import XCTest


private let testEntitlement = "test-entitlement"

final class LLBuildManifestTests: XCTestCase {
    func testEntitlementsPlist() throws {
        let FileType = WriteAuxiliary.EntitlementPlist.self
        let inputs = FileType.computeInputs(entitlement: testEntitlement)
        XCTAssertEqual(inputs, [.virtual(FileType.name), .virtual(testEntitlement)])

        let contents = try FileType.getFileContents(inputs: inputs)
        let decoder = PropertyListDecoder()
        let decodedEntitlements = try decoder.decode([String: Bool].self, from: .init(contents.utf8))
        XCTAssertEqual(decodedEntitlements, [testEntitlement: true])

        var manifest = LLBuildManifest()
        let outputPath = AbsolutePath("/test.plist")
        manifest.addEntitlementPlistCommand(entitlement: testEntitlement, outputPath: outputPath)

        let commandName = outputPath.pathString
        XCTAssertEqual(manifest.commands.count, 1)
        
        let command = try XCTUnwrap(manifest.commands[commandName]?.tool as? WriteAuxiliaryFile)

        XCTAssertEqual(command, .init(inputs: inputs, outputFilePath: outputPath))
    }

    func testBasics() throws {
        var manifest = LLBuildManifest()

        let root: AbsolutePath = "/some"

        manifest.defaultTarget = "main"
        manifest.addPhonyCmd(
            name: "C.Foo",
            inputs: [
                .file(root.appending(components: "file.c")),
                .directory(root.appending(components: "dir")),
                .directoryStructure(root.appending(components: "dir", "structure")),
            ],
            outputs: [.virtual("Foo")]
        )

        manifest.addNode(.virtual("Foo"), toTarget: "main")

        let fs = InMemoryFileSystem()
        try LLBuildManifestWriter.write(manifest, at: "/manifest.yaml", fileSystem: fs)

        let contents: String = try fs.readFileContents("/manifest.yaml")

        // FIXME(#5475) - use the platform's preferred separator for directory
        // indicators
        XCTAssertEqual(contents.replacingOccurrences(of: "\\\\", with: "\\"), """
            client:
              name: basic
              file-system: device-agnostic
            tools: {}
            targets:
              "main": ["<Foo>"]
            default: "main"
            nodes:
              "\(root.appending(components: "dir", "structure"))/":
                is-directory-structure: true
                content-exclusion-patterns: [".git",".build"]
            commands:
              "C.Foo":
                tool: phony
                inputs: ["\(root.appending(components: "file.c"))","\(root.appending(components: "dir"))/","\(root.appending(components: "dir", "structure"))/"]
                outputs: ["<Foo>"]


            """)
    }

    func testShellCommands() throws {
        var manifest = LLBuildManifest()

        let root: AbsolutePath = .root

        manifest.defaultTarget = "main"
        manifest.addShellCmd(
            name: "shelley",
            description: "Shelley, Keats, and Byron",
            inputs: [
                .file(root.appending(components: "file.in"))
            ],
            outputs: [
                .file(root.appending(components: "file.out"))
            ],
            arguments: [
                "foo", "bar", "baz"
            ],
            environment: [
                "ABC": "DEF",
                "G H": "I J K",
            ],
            workingDirectory: "/wdir",
            allowMissingInputs: true
        )

        manifest.addNode(.file("/file.out"), toTarget: "main")

        let fs = InMemoryFileSystem()
        try LLBuildManifestWriter.write(manifest, at: "/manifest.yaml", fileSystem: fs)

        let contents: String = try fs.readFileContents("/manifest.yaml")

        XCTAssertEqual(contents.replacingOccurrences(of: "\\\\", with: "\\"), """
            client:
              name: basic
              file-system: device-agnostic
            tools: {}
            targets:
              "main": ["\(root.appending(components: "file.out"))"]
            default: "main"
            commands:
              "shelley":
                tool: shell
                inputs: ["\(root.appending(components: "file.in"))"]
                outputs: ["\(root.appending(components: "file.out"))"]
                description: "Shelley, Keats, and Byron"
                args: ["foo","bar","baz"]
                env:
                  "ABC": "DEF"
                  "G H": "I J K"
                working-directory: "/wdir"
                allow-missing-inputs: true


            """)
    }

    func testMutatedNodes() throws {
        var manifest = LLBuildManifest()

        let root: AbsolutePath = .root

        manifest.addNode(.virtual("C.mutate"), toTarget: "")
        let createTimestampNode = Node.virtual("C.create.timestamp", isCommandTimestamp: true)
        let mutatedNode = Node.file(root.appending(components: "file.out"), isMutated: true)

        manifest.addShellCmd(
            name: "C.create",
            description: "C.create",
            inputs: [
                .file(root.appending(components: "file.in"))
            ],
            outputs: [mutatedNode, createTimestampNode],
            arguments: [
                "cp", "file.in", "file.out"
            ]
        )

        manifest.addShellCmd(
            name: "C.mutate",
            description: "C.mutate",
            inputs: [
                createTimestampNode
            ],
            outputs: [
                .virtual("C.mutate")
            ],
            arguments: [
                "touch", "file.out"
            ]
        )

        let fs = InMemoryFileSystem()
        try LLBuildManifestWriter.write(manifest, at: "/manifest.yaml", fileSystem: fs)

        let contents: String = try fs.readFileContents("/manifest.yaml")

        XCTAssertEqual(contents.replacingOccurrences(of: "\\\\", with: "\\"), """
            client:
              name: basic
              file-system: device-agnostic
            tools: {}
            targets:
              "": ["<C.mutate>"]
            default: ""
            nodes:
              "<C.create.timestamp>":
                is-command-timestamp: true
              "\(AbsolutePath("/file.out"))":
                is-mutated: true
            commands:
              "C.create":
                tool: shell
                inputs: ["\(AbsolutePath("/file.in"))"]
                outputs: ["\(AbsolutePath("/file.out"))","<C.create.timestamp>"]
                description: "C.create"
                args: ["cp","file.in","file.out"]

              "C.mutate":
                tool: shell
                inputs: ["<C.create.timestamp>"]
                outputs: ["<C.mutate>"]
                description: "C.mutate"
                args: ["touch","file.out"]

            
            """)
    }
}
