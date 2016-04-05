/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import func POSIX.isatty
import var Utility.stderr
import PackageType
import libc

public enum CommandLineError: ErrorProtocol {
    public enum UsageMode {
        case Print, ImplySwiftBuild, ImplySwiftTest
    }
    case InvalidUsage(String, UsageMode)
}

public enum Error: ErrorProtocol {
    case NoManifestFound
    case InvalidToolchain
    case InvalidInstallation(String)
    case InvalidSwiftExec(String)
    case BuildYAMLNotFound(String)
}

extension Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .NoManifestFound:
            return "no \(Manifest.filename) file found"
        case .InvalidToolchain:
            return "invalid inferred toolchain"
        case .InvalidInstallation(let prefix):
            return "invalid or incomplete Swift toolchain:\n    \(prefix)"
        case .InvalidSwiftExec(let value):
            return "invalid SWIFT_EXEC value: \(value)"
        case BuildYAMLNotFound(let value):
            return "no build YAML found: \(value)"
        }
    }
}

@noreturn public func handleError(_ msg: Any, usage: ((String) -> Void) -> Void) {
    switch msg {
    case CommandLineError.InvalidUsage(let hint, let mode):
        print(error: "invalid usage: \(hint)")

        if isatty(fileno(libc.stdin)) {
            switch mode {
            case .ImplySwiftBuild:
                print("enter `swift build --help' for usage information", to: &stderr)
            case .ImplySwiftTest:
                print("enter `swift test --help' for usage information", to: &stderr)
            case .Print:
                print("", to: &stderr)
                usage { print($0, to: &stderr) }
            }
        }
    default:
        print(error: msg)
    }

    exit(1)
}

private func red(_ input: Any) -> String {
    let input = "\(input)"
    let ESC = "\u{001B}"
    let CSI = "\(ESC)["
    return CSI + "31m" + input + CSI + "0m"
}

private func print(error: Any) {
    if !isatty(fileno(libc.stderr)) {
        let cmd = Process.arguments.first?.basename ?? "SwiftPM"
        print("\(cmd): error:", error, to: &stderr)
    } else {
        print(red("error:"), error, to: &stderr)
    }
}
