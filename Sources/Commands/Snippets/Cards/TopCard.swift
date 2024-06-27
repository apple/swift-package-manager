//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import CoreCommands
import Foundation
import PackageModel
import PackageGraph

/// The top menu card for a package's help contents, including snippets.
struct TopCard: Card {
    /// The root package that hosts the snippets.
    let package: ResolvedPackage

    /// The top-level snippet groups residing in the `Snippets` subdirectory.
    let snippetGroups: [SnippetGroup]

    /// The tool used for eventually building and running a chosen snippet.
    let swiftCommandState: SwiftCommandState

    init(package: ResolvedPackage, snippetGroups: [SnippetGroup], swiftCommandState: SwiftCommandState) {
        self.package = package
        self.snippetGroups = snippetGroups
        self.swiftCommandState = swiftCommandState
    }

    var inputPrompt: String? {
        return """
            Choose a group by name or number.
            To exit, enter 'q'.
            """
    }

    func renderProducts() -> String {
        let libraries = package.products
            .filter {
                guard case .library = $0.type else {
                    return false
                }
                return true
            }
            .sorted { $0.name < $1.name }
            .map { "- \($0.name) (library)" }

        let executables = package.products
            .filter { $0.type == .executable }
            .sorted { $0.name < $1.name }
            .map { "- \($0.name) (executable)" }

        guard !(libraries.isEmpty && executables.isEmpty) else {
            return ""
        }

        var rendered = brightCyan {
            "\n## Products"
            "\n\n"
        }.terminalString()

        rendered += (libraries + executables).joined(separator: "\n")

        return rendered
    }

    func renderSnippets() -> String {
        guard !snippetGroups.isEmpty else {
            return ""
        }
        let snippetPreviews = snippetGroups.enumerated().map { pair -> String in
            let (number, snippetGroup) = pair
            let snippetNoun = snippetGroup.snippets.count > 1 ? "snippets" : "snippet"
            let heading = "\(number). \(snippetGroup.name) (\(snippetGroup.snippets.count) \(snippetNoun))"
            return colorized {
                cyan {
                    heading
                    "\n"
                }
                if !snippetGroup.explanation.isEmpty {
                    """
                    \(snippetGroup.explanation.spm_multilineIndent(count: 3))
                    """
                }
            }.terminalString()
        }

        return colorized {
            brightCyan {
                "\n## Snippets"
            }
            "\n\n"
            snippetPreviews.joined(separator: "\n\n")
          "\n"
        }.terminalString()
    }

    func render() -> String {
        let heading = brightYellow {
            "# "
            package.identity.description
        }
        return """
        \(heading)
        \(renderProducts())
        \(renderSnippets())
        """
    }

    func acceptLineInput<S>(_ line: S) -> CardEvent? where S : StringProtocol {
        guard !line.isEmpty else {
            print("\u{0007}")
            return nil
        }
        if line.prefix(while: { !$0.isWhitespace }).lowercased() == "q" {
            return .quit()
        }
        if let index = Int(line),
           snippetGroups.indices.contains(index) {
            return .push(SnippetGroupCard(snippetGroup: snippetGroups[index], swiftCommandState: swiftCommandState))
        } else if let groupByName = snippetGroups.first(where: { $0.name == line }) {
            return .push(SnippetGroupCard(snippetGroup: groupByName, swiftCommandState: swiftCommandState))
        } else {
            print(red { "There is not a group by that name or index." })
            return nil
        }
    }
}

fileprivate extension Module.Kind {
    var pluralDescription: String {
        switch self {
        case .executable:
            return "executables"
        case .library:
            return "libraries"
        case .systemModule:
            return "system modules"
        case .test:
            return "tests"
        case .binary:
            return "binaries"
        case .plugin:
            return "plugins"
        case .snippet:
            return "snippets"
        case .macro:
            return "macros"
        case .providedLibrary:
            return "provided libraries"
        }
    }
}
