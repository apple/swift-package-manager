//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

/// Representation of Netrc configuration
public struct Netrc {
    /// Representation of `machine` connection settings & `default` connection settings.
    /// If `default` connection settings present, they will be last element.
    public let machines: [Machine]

    fileprivate init(machines: [Machine]) {
        self.machines = machines
    }

    /// Returns auth information
    ///
    /// - Parameters:
    ///   - url: The url to retrieve authorization information for.
    public func authorization(for url: URL) -> Authorization? {
        guard let index = machines.firstIndex(where: { $0.name == url.host }) ?? machines
            .firstIndex(where: { $0.isDefault })
        else {
            return .none
        }
        let machine = self.machines[index]
        return Authorization(login: machine.login, password: machine.password)
    }

    /// Representation of connection settings
    public struct Machine: Equatable {
        public let name: String
        public let login: String
        public let password: String

        public var isDefault: Bool {
            self.name == "default"
        }

        public init(name: String, login: String, password: String) {
            self.name = name
            self.login = login
            self.password = password
        }

        init?(for match: NSTextCheckingResult, string: String, variant: String = "") {
            guard let name = RegexUtil.Token.machine.capture(in: match, string: string) ?? RegexUtil.Token.default
                .capture(in: match, string: string),
                let login = RegexUtil.Token.login.capture(prefix: variant, in: match, string: string),
                let password = RegexUtil.Token.password.capture(prefix: variant, in: match, string: string)
            else {
                return nil
            }
            self = Machine(name: name, login: login, password: password)
        }
    }

    /// Representation of authorization information
    public struct Authorization: Equatable {
        public let login: String
        public let password: String

        public init(login: String, password: String) {
            self.login = login
            self.password = password
        }
    }
}

public struct NetrcParser {
    /// Parses a netrc file at the give location
    ///
    /// - Parameters:
    ///   - fileSystem: The file system to use.
    ///   - path: The file to parse
    public static func parse(fileSystem: FileSystem, path: AbsolutePath) throws -> Netrc {
        guard fileSystem.exists(path) else {
            throw NetrcError.fileNotFound(path)
        }
        guard fileSystem.isReadable(path) else {
            throw NetrcError.unreadableFile(path)
        }
        let content: String = try fileSystem.readFileContents(path)
        return try Self.parse(content)
    }

    /// Parses stringified netrc content
    ///
    /// - Parameters:
    ///   - content: The content to parse
    public static func parse(_ content: String) throws -> Netrc {
        let content = self.trimComments(from: content)
        let regex = try! NSRegularExpression(pattern: RegexUtil.netrcPattern, options: [])
        let matches = regex.matches(
            in: content,
            options: [],
            range: NSRange(content.startIndex ..< content.endIndex, in: content)
        )

        let machines: [Netrc.Machine] = matches.compactMap {
            Netrc.Machine(for: $0, string: content, variant: "lp") ?? Netrc
                .Machine(for: $0, string: content, variant: "pl")
        }

        if let defIndex = machines.firstIndex(where: { $0.isDefault }) {
            guard defIndex == machines.index(before: machines.endIndex) else {
                throw NetrcError.invalidDefaultMachinePosition
            }
        }
        guard machines.count > 0 else {
            throw NetrcError.machineNotFound
        }
        return Netrc(machines: machines)
    }

    /// Utility method to trim comments from netrc content
    /// - Parameter text: String text of netrc file
    /// - Returns: String text of netrc file *sans* comments
    private static func trimComments(from text: String) -> String {
        let regex = try! NSRegularExpression(pattern: RegexUtil.comments, options: .anchorsMatchLines)
        let nsString = text as NSString
        let range = NSRange(location: 0, length: nsString.length)
        let matches = regex.matches(in: text, range: range)
        var trimmedCommentsText = text
        matches.forEach {
            trimmedCommentsText = trimmedCommentsText
                .replacing(nsString.substring(with: $0.range), with: "")
        }
        return trimmedCommentsText
    }
}

public enum NetrcError: Error, Equatable {
    case fileNotFound(AbsolutePath)
    case unreadableFile(AbsolutePath)
    case machineNotFound
    case invalidDefaultMachinePosition
}

private enum RegexUtil {
    @frozen
    fileprivate enum Token: String, CaseIterable {
        case machine, login, password, account, macdef, `default`

        func capture(prefix: String = "", in match: NSTextCheckingResult, string: String) -> String? {
            guard let range = Range(match.range(withName: prefix + rawValue), in: string) else { return nil }
            return String(string[range])
        }
    }

    static let comments: String = "\\#[\\s\\S]*?.*$"
    static let `default`: String = #"(?:\s*(?<default>default))"#
    static let accountOptional: String = #"(?:\s*account\s+\S++)?"#
    static let loginPassword: String =
        #"\#(namedTrailingCapture("login", prefix: "lp"))\#(accountOptional)\#(namedTrailingCapture("password", prefix: "lp"))"#
    static let passwordLogin: String =
        #"\#(namedTrailingCapture("password", prefix: "pl"))\#(accountOptional)\#(namedTrailingCapture("login", prefix: "pl"))"#
    static let netrcPattern =
        #"(?:(?:(\#(namedTrailingCapture("machine"))|\#(namedMatch("default"))))(?:\#(loginPassword)|\#(passwordLogin)))"#

    static func namedMatch(_ string: String) -> String {
        #"(?:\s*(?<\#(string)>\#(string)))"#
    }

    static func namedTrailingCapture(_ string: String, prefix: String = "") -> String {
        #"\s*\#(string)\s+(?<\#(prefix + string)>\S++)"#
    }
}
