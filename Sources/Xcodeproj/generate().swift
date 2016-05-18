/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basic
import POSIX
import PackageModel
import Utility

public protocol XcodeprojOptions {
    /// The list of additional arguments to pass to the compiler.
    var Xcc: [String] { get }

    /// The list of additional arguments to pass to the linker.
    var Xld: [String] { get }

    /// The list of additional arguments to pass to `swiftc`.
    var Xswiftc: [String] { get }

    /// If provided, a path to an xcconfig file to be included by the project.
    ///
    /// This allows the client to override settings defined in the project itself.
    var xcconfigOverrides: String? { get }
}

/**
 Generates an xcodeproj at the specified path.
 - Returns: the path to the generated project
*/
public func generate(dstdir: String, projectName: String, srcroot: String, modules: [XcodeModuleProtocol], externalModules: [XcodeModuleProtocol], products: [Product], options: XcodeprojOptions) throws -> String {

    let xcodeprojName = "\(projectName).xcodeproj"
    let xcodeprojPath = try mkdir(dstdir, xcodeprojName)
    let schemesDirectory = try mkdir(xcodeprojPath, "xcshareddata/xcschemes")
    let schemeName = "\(projectName).xcscheme"

////// the pbxproj file describes the project and its targets
    try open(xcodeprojPath, "project.pbxproj") { stream in
        try pbxproj(srcroot: srcroot, projectRoot: dstdir, xcodeprojPath: xcodeprojPath, modules: modules, externalModules: externalModules, products: products, options: options, printer: stream)
    }

////// the scheme acts like an aggregate target for all our targets
   /// it has all tests associated so CMD+U works
    try open(schemesDirectory, schemeName) { stream in
        xcscheme(container: xcodeprojName, modules: modules, printer: stream)
    }

////// we generate this file to ensure our main scheme is listed
   /// before any inferred schemes Xcode may autocreate
    try open(schemesDirectory, "xcschememanagement.plist") { print in
        print("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        print("<plist version=\"1.0\">")
        print("<dict>")
        print("  <key>SchemeUserState</key>")
        print("  <dict>")
        print("    <key>\(schemeName)</key>")
        print("    <dict></dict>")
        print("  </dict>")
        print("  <key>SuppressBuildableAutocreation</key>")
        print("  <dict></dict>")
        print("</dict>")
        print("</plist>")
    }

    return xcodeprojPath
}

import class Foundation.NSData

/// Writes the contents to the file specified.
/// Doesn't re-writes the file in case the new and old contents of file are same.
func open(_ path: String..., body: ((String) -> Void) throws -> Void) throws {
    let path = Path.join(path)
    let stream = OutputByteStream()
    try body { line in
        stream <<< line
        stream <<< "\n"
    }
    // If file is already present compare its content with our stream
    // and re-write only if its new.
    if path.isFile, let data = NSData(contentsOfFile: path) {
        var contents = [UInt8](repeating: 0, count: data.length / sizeof(UInt8))
        data.getBytes(&contents, length: data.length)
        // If contents are same then no need to re-write.
        if contents == stream.bytes.bytes { 
            return 
        }
    }
    // Write the real file.
    try fopen(path, mode: .Write) { fp in
        try fputs(stream.bytes.bytes, fp)
    }
}
