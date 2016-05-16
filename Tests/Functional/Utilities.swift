/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import struct Utility.Path
import func Utility.walk
import func XCTest.XCTFail
import func POSIX.getenv
import func POSIX.popen
import func Utility.realpath
import enum POSIX.Error
import func Utility.mkdtemp

#if os(OSX)
    import class Foundation.NSBundle
#endif


func fixture(name fixtureName: String, tags: [String] = [], file: StaticString = #file, line: UInt = #line, body: @noescape(String) throws -> Void) {

    func gsub(_ input: String) -> String {
        return input.characters.split(separator: "/").map(String.init).joined(separator: "_")
    }

    do {
        try Utility.mkdtemp(gsub(fixtureName)) { prefix in
            let rootd = Path.join(#file, "../../../Fixtures", fixtureName).normpath

            guard rootd.isDirectory else {
                XCTFail("No such fixture: \(rootd)", file: file, line: line)
                return
            }

            if Path.join(rootd, "Package.swift").isFile {
                let dstdir = Path.join(prefix, rootd.basename).normpath
                try system("cp", "-R", rootd, dstdir)
                try body(dstdir)
            } else {
                var versions = tags
                func popVersion() -> String {
                    if versions.isEmpty {
                        return "1.2.3"
                    } else if versions.count == 1 {
                        return versions.first!
                    } else {
                        return versions.removeFirst()
                    }
                }

                for d in walk(rootd, recursively: false).sorted() {
                    guard d.isDirectory else { continue }
                    let dstdir = Path.join(prefix, d.basename).normpath
                    try system("cp", "-R", try realpath(d), dstdir)
                    try popen(["git", "-C", dstdir, "init"])
                    try popen(["git", "-C", dstdir, "config", "user.email", "example@example.com"])
                    try popen(["git", "-C", dstdir, "config", "user.name", "Example Example"])
                    try popen(["git", "-C", dstdir, "add", "."])
                    try popen(["git", "-C", dstdir, "commit", "-m", "msg"])
                    try popen(["git", "-C", dstdir, "tag", popVersion()])
                }
                try body(prefix)
            }
        }
    } catch {
        XCTFail("\(error)", file: file, line: line)
    }
}

func initGitRepo(_ dstdir: String, tag: String? = nil, file: StaticString = #file, line: UInt = #line) {
    do {
        let file = Path.join(dstdir, "file.swift")
        try popen(["touch", file])
        try popen(["git", "-C", dstdir, "init"])
        try popen(["git", "-C", dstdir, "config", "user.email", "example@example.com"])
        try popen(["git", "-C", dstdir, "config", "user.name", "Example Example"])
        try popen(["git", "-C", dstdir, "add", "."])
        try popen(["git", "-C", dstdir, "commit", "-m", "msg"])
        if let tag = tag {
            try popen(["git", "-C", dstdir, "tag", tag])
        }
    }
    catch {
        XCTFail("\(error)", file: file, line: line)
    }
}

enum Configuration {
    case Debug
    case Release
}

private var globalSymbolInMainBinary = 0


func swiftBuildPath() -> String {
#if os(OSX)
    for bundle in NSBundle.allBundles() where bundle.bundlePath.hasSuffix(".xctest") {
        return Path.join(bundle.bundlePath.parentDirectory, "swift-build")
    }
    fatalError()
#else
    return Path.join(Process.arguments.first!.abspath.parentDirectory, "swift-build")
#endif
}

func executeSwiftBuild(_ args: [String], chdir: String, env: [String: String] = [:], printIfError: Bool = false) throws -> String {
    let args = [swiftBuildPath(), "--chdir", chdir] + args
    var env = env

    // FIXME: We use this private enviroment variable hack to be able to
    // create special conditions in swift-build for swiftpm tests.
    env["IS_SWIFTPM_TEST"] = "1"
#if Xcode
    switch getenv("SWIFT_EXEC") {
    case "swiftc"?, nil:
        //FIXME Xcode should set this during tests
        // rdar://problem/24134324
        let swiftc: String
        if let base = getenv("XCODE_DEFAULT_TOOLCHAIN_OVERRIDE")?.chuzzle() {
            swiftc = Path.join(base, "usr/bin/swiftc")
        } else {
            swiftc = try popen(["xcrun", "--find", "swiftc"]).chuzzle() ?? "BADPATH"
        }
        precondition(swiftc != "/usr/bin/swiftc")
        env["SWIFT_EXEC"] = swiftc
    default:
        fatalError("HURRAY! This is fixed")
    }
#endif
    var out = ""
    do {
        try popen(args, redirectStandardError: true, environment: env) {
            out += $0
        }
        return out
    } catch {
        if printIfError {
            print("output:", out)
            print("SWIFT_EXEC:", env["SWIFT_EXEC"] ?? "nil")
            print("swift-build:", swiftBuildPath())
        }
        throw error
    }
}

func executeSwiftBuild(_ chdir: String, configuration: Configuration = .Debug, printIfError: Bool = false, Xld: [String] = [], env: [String: String] = [:]) throws -> String {
    var args = ["--configuration"]
    switch configuration {
    case .Debug:
        args.append("debug")
    case .Release:
        args.append("release")
    }
    args += Xld.flatMap{ ["-Xlinker", $0] }
    return try executeSwiftBuild(args, chdir: chdir, env: env, printIfError: printIfError)
}

func mktmpdir(_ file: StaticString = #file, line: UInt = #line, body: @noescape(String) throws -> Void) {
    do {
        try Utility.mkdtemp("spm-tests", body: body)
    } catch {
        XCTFail("\(error)", file: file, line: line)
    }
}

func XCTAssertBuilds(_ paths: String..., configurations: Set<Configuration> = [.Debug, .Release], file: StaticString = #file, line: UInt = #line, Xld: [String] = [], env: [String: String] = [:]) {
    let prefix = Path.join(paths)

    for conf in configurations {
        do {
            print("    Building \(conf)")
            try executeSwiftBuild(prefix, configuration: conf, printIfError: true, Xld: Xld, env: env)
        } catch {
            XCTFail("`swift build -c \(conf)' failed:\n\n\(error)\n", file: file, line: line)
        }
    }
}

func XCTAssertBuildFails(_ paths: String..., file: StaticString = #file, line: UInt = #line) {
    let prefix = Path.join(paths)
    do {
        try executeSwiftBuild(prefix)

        XCTFail("`swift build' succeeded but should have failed", file: file, line: line)

    } catch POSIX.Error.ExitStatus(let status, _) where status == 1{
        // noop
    } catch {
        XCTFail("`swift build' failed in an unexpected manner")
    }
}

func XCTAssertFileExists(_ paths: String..., file: StaticString = #file, line: UInt = #line) {
    let path = Path.join(paths)
    if !path.isFile {
        XCTFail("Expected file doesn’t exist: \(path)", file: file, line: line)
    }
}

func XCTAssertDirectoryExists(_ paths: String..., file: StaticString = #file, line: UInt = #line) {
    let path = Path.join(paths)
    if !path.isDirectory {
        XCTFail("Expected directory doesn’t exist: \(path)", file: file, line: line)
    }
}

func XCTAssertNoSuchPath(_ paths: String..., file: StaticString = #file, line: UInt = #line) {
    let path = Path.join(paths)
    if path.exists {
        XCTFail("path exists but should not: \(path)", file: file, line: line)
    }
}

func system(_ args: String...) throws {
    try popen(args, redirectStandardError: true)
}
