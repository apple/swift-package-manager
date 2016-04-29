/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

public enum Verbosity: Int {
    case Concise
    case Verbose
    case Debug

    public init(rawValue: Int) {
        switch rawValue {
        case Int.min...0:
            self = .Concise
        case 1:
            self = .Verbose
        default:
            self = .Debug
        }
    }

    public var ccArgs: [String] {
        switch self {
        case .Concise:
            return []
        case .Verbose:
            // the first level of verbosity is passed to llbuild itself
            return []
        case .Debug:
            return ["-v"]
        }
    }
}

public var verbosity = Verbosity.Concise


import func libc.fputs
import var libc.stderr

public class StandardErrorOutputStream: OutputStream {
    public func write(_ string: String) {
        libc.fputs(string, libc.stderr)
    }
}

public var stderr = StandardErrorOutputStream()



import func POSIX.system
import func POSIX.popen
import func POSIX.prettyArguments

public func system(_ args: String...) throws {
    try Utility.system(args)
}

private let ESC = "\u{001B}"
private let CSI = "\(ESC)["

private func prettyArguments(_ arguments: [String]) -> String {
    guard arguments.count > 0 else { return "" }

    var arguments = arguments
    let arg0 = blue(which(arguments.removeFirst()))

    return arg0 + " " + POSIX.prettyArguments(arguments)
}

private func printArgumentsIfVerbose(_ arguments: [String]) {
    if verbosity != .Concise {
        print(prettyArguments(arguments))
    }
}

public func system(_ arguments: [String], environment: [String:String] = [:], echo: Bool = true) throws {
    if echo { printArgumentsIfVerbose(arguments) }
    try POSIX.system(arguments, environment: environment)
}

public func popen(_ arguments: [String], redirectStandardError: Bool = false, environment: [String: String] = [:], echo: Bool = true) throws -> String {
    if echo { printArgumentsIfVerbose(arguments) }
    return try POSIX.popen(arguments, redirectStandardError: redirectStandardError, environment: environment)
}

public func popen(_ arguments: [String], redirectStandardError: Bool = false, environment: [String: String] = [:], echo: Bool = true, body: String -> Void) throws {
    if echo { printArgumentsIfVerbose(arguments) }
    return try POSIX.popen(arguments, redirectStandardError: redirectStandardError, environment: environment, body: body)
}


import func libc.fflush
import var libc.stdout
import enum POSIX.Error

public func system(_ arguments: String..., environment: [String:String] = [:], message: String?) throws {
    var out = ""
    do {
        if Utility.verbosity == .Concise {
            if let message = message {
                print(message)
                fflush(stdout)  // ensure we display `message` before git asks for credentials
            }
            try POSIX.popen(arguments, redirectStandardError: true, environment: environment) { line in
                out += line
            }
        } else {
            try Utility.system(arguments, environment: environment)
        }
    } catch {
        if verbosity == .Concise {
            print(prettyArguments(arguments), to: &stderr)
            print(out, to: &stderr)
        }
        throw error
    }
}

private func which(_ arg0: String) -> String {
    if arg0.isAbsolute {
        return arg0
    } else if let fullpath = try? POSIX.popen(["which", arg0]) {
        return fullpath.chomp()
    } else {
        return arg0
    }
}

private func blue(_ input: String) -> String {
    return CSI + "34m" + input + CSI + "0m"
}
