/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Build
import Utility
import Basic

/// swift-build tool namespace
public class SwiftBuildTool: SwiftTool<BuildToolOptions> {

   public convenience init(args: [String]) {
       self.init(
            toolName: "build",
            usage: "[options]",
            overview: "Build sources into binary products",
            args: args
        )
    }

    override func runImpl() throws {
        switch try options.mode() {
        case .build:
          #if os(Linux)
            // Emit warning if clang is older than version 3.6 on Linux.
            // See: <rdar://problem/28108951> SR-2299 Swift isn't using Gold by default on stock 14.04.
            checkClangVersion()
          #endif

            try build(includingTests: options.buildTests)

        case .binPath:
            try print(buildParameters().buildPath.asString)

        case .version:
            print(Versioning.currentVersion.completeDisplayString)
        }
    }

    override class func defineArguments(parser: ArgumentParser, binder: ArgumentBinder<BuildToolOptions>) {
        binder.bind(
            option: parser.add(option: "--build-tests", kind: Bool.self,
                usage: "Build the both source and test targets"),
            to: { $0.buildTests = $1 })

        binder.bind(
            option: parser.add(option: "--show-bin-path", kind: Bool.self,
               usage: "Print the binary output path"),
            to: { $0.shouldPrintBinPath = $1 })
    }

    private func checkClangVersion() {
        // We only care about this on Ubuntu 14.04
        guard let uname = try? Process.checkNonZeroExit(args: "lsb_release", "-r").chomp(),
              uname.hasSuffix("14.04"),
              let clangVersionOutput = try? Process.checkNonZeroExit(args: "clang", "--version").chomp(),
              let clang = getClangVersion(versionOutput: clangVersionOutput) else {
            return
        }

        if clang.major <= 3 && clang.minor < 6 {
            print("warning: minimum recommended clang is version 3.6, otherwise you may encounter linker errors.")
        }
    }
}

public class BuildToolOptions: ToolOptions {
    /// Returns the mode in which the build tool should run.
    func mode() throws -> BuildToolMode {
        if shouldPrintVersion {
            return .version
        }
        if shouldPrintBinPath {
            return .binPath
        }
        // Get the build configuration or assume debug.
        return .build
    }

    /// If the test should be built.
    var buildTests = false

    /// If the binary output path should be printed.
    var shouldPrintBinPath = false
}

public enum BuildToolMode {
    /// Build the package.
    case build

    /// Print the binary output path.
    case binPath

    /// Print the version.
    case version
}
