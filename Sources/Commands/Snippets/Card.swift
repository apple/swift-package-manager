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

/// A terminal menu that takes up the whole terminal, accepting input and
/// rendering in response.
protocol Card {
    /// Render the contents to be printed to the terminal.
    func render() -> String

    /// Accept a line of input from the user's terminal and provide
    /// an optional ``CardEvent`` which can alter the card stack.
    func acceptLineInput(_ line: some StringProtocol) async -> CardEvent?

    /// The input prompt to present to the user when accepting a line of input.
    var inputPrompt: String? { get }
}

extension Card {
    var defaultPrompt: String {
        return "Press enter to continue."
    }
}

extension Card {
    var inputPrompt: String? {
        return defaultPrompt
    }
}
