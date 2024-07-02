//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
@testable import PackageLoading
import _InternalTestSupport
import XCTest

import struct TSCBasic.ByteString

final class PkgConfigParserTests: XCTestCase {
    func testCircularPCFile() throws {
        let observability = ObservabilitySystem.makeForTesting()

        _ = try PkgConfig(
            name: "harfbuzz",
            additionalSearchPaths: [AbsolutePath(#file).parentDirectory.appending(components: "pkgconfigInputs")],
            fileSystem: localFileSystem,
            observabilityScope: observability.topScope
        )

        testDiagnostics(observability.diagnostics) { result in
            result.check(diagnostic: .equal("circular dependency detected while parsing harfbuzz: harfbuzz -> freetype2 -> harfbuzz"), severity: .warning)
        }
    }

    func testGTK3PCFile() {
        try! loadPCFile("gtk+-3.0.pc") { parser in
            XCTAssertEqual(parser.variables, [
                "libdir": "/usr/local/Cellar/gtk+3/3.18.9/lib",
                "gtk_host": "x86_64-apple-darwin15.3.0",
                "includedir": "/usr/local/Cellar/gtk+3/3.18.9/include",
                "prefix": "/usr/local/Cellar/gtk+3/3.18.9",
                "gtk_binary_version": "3.0.0",
                "exec_prefix": "/usr/local/Cellar/gtk+3/3.18.9",
                "targets": "quartz",
                "pcfiledir": parser.pcFile.parentDirectory.pathString,
                "pc_sysrootdir": AbsolutePath.root.pathString
            ])
            XCTAssertEqual(parser.dependencies, ["gdk-3.0", "atk", "cairo", "cairo-gobject", "gdk-pixbuf-2.0", "gio-2.0"])
            XCTAssertEqual(parser.privateDependencies, ["atk", "epoxy", "gio-unix-2.0"])
            XCTAssertEqual(parser.cFlags, ["-I/usr/local/Cellar/gtk+3/3.18.9/include/gtk-3.0"])
            XCTAssertEqual(parser.libs, ["-L/usr/local/Cellar/gtk+3/3.18.9/lib", "-lgtk-3"])
        }
    }

    func testEmptyCFlags() {
        try! loadPCFile("empty_cflags.pc") { parser in
            XCTAssertEqual(parser.variables, [
                "prefix": "/usr/local/bin",
                "exec_prefix": "/usr/local/bin",
                "pcfiledir": parser.pcFile.parentDirectory.pathString,
                "pc_sysrootdir": AbsolutePath.root.pathString
            ])
            XCTAssertEqual(parser.dependencies, ["gdk-3.0", "atk"])
            XCTAssertEqual(parser.cFlags, [])
            XCTAssertEqual(parser.libs, ["-L/usr/local/bin", "-lgtk-3"])
        }
    }

    func testCFlagsCaseInsensitveKeys() {
        try! loadPCFile("case_insensitive.pc") { parser in
            XCTAssertEqual(parser.cFlags, ["-I/usr/local/include"])
        }
    }

    func testVariableinDependency() {
        try! loadPCFile("deps_variable.pc") { parser in
            XCTAssertEqual(parser.variables, [
                "prefix": "/usr/local/bin",
                "exec_prefix": "/usr/local/bin",
                "my_dep": "atk",
                "pcfiledir": parser.pcFile.parentDirectory.pathString,
                "pc_sysrootdir": AbsolutePath.root.pathString
            ])
            XCTAssertEqual(parser.dependencies, ["gdk-3.0", "atk"])
            XCTAssertEqual(parser.cFlags, ["-I"])
            XCTAssertEqual(parser.libs, ["-L/usr/local/bin", "-lgtk-3"])
        }
    }

    func testUnresolvablePCFile() throws {
        do {
            try loadPCFile("failure_case.pc")
            XCTFail("Unexpected success")
        } catch PkgConfigError.parsingError(let desc) {
            XCTAssert(desc.hasPrefix("Expected a value for variable"))
        }
    }

    func testEscapedSpaces() {
        try! loadPCFile("escaped_spaces.pc") { parser in
            XCTAssertEqual(parser.variables, [
                "prefix": "/usr/local/bin",
                "exec_prefix": "/usr/local/bin",
                "my_dep": "atk",
                "pcfiledir": parser.pcFile.parentDirectory.pathString,
                "pc_sysrootdir": AbsolutePath.root.pathString
            ])
            XCTAssertEqual(parser.dependencies, ["gdk-3.0", "atk"])
            XCTAssertEqual(parser.cFlags, ["-I/usr/local/Wine Cellar/gtk+3/3.18.9/include/gtk-3.0", "-I/after/extra/spaces"])
            XCTAssertEqual(parser.libs, ["-L/usr/local/bin", "-lgtk 3", "-wantareal\\here", "-one\\", "-two"])
        }
    }

    func testDummyDependency() throws {
        try loadPCFile("dummy_dependency.pc") { parser in
            XCTAssertEqual(parser.variables, [
                "prefix": "/usr/local/bin",
                "exec_prefix": "/usr/local/bin",
                "pcfiledir": parser.pcFile.parentDirectory.pathString,
                "pc_sysrootdir": AbsolutePath.root.pathString
            ])
            XCTAssertEqual(parser.dependencies, ["pango", "fontconfig"])
            XCTAssertEqual(parser.cFlags, [])
            XCTAssertEqual(parser.libs, ["-L/usr/local/bin", "-lpangoft2-1.0"])
        }
    }

    /// Test custom search path get higher priority for locating pc files.
    func testCustomPcFileSearchPath() throws {
        let observability = ObservabilitySystem.makeForTesting()

        /// Temporary workaround for PCFileFinder's use of static variables.
        PCFileFinder.resetCachedPkgConfigPaths()

        let fs = InMemoryFileSystem(emptyFiles:
            "/usr/lib/pkgconfig/foo.pc",
            "/usr/local/opt/foo/lib/pkgconfig/foo.pc",
            "/custom/foo.pc")
        XCTAssertEqual(
            "/custom/foo.pc",
            try PCFileFinder().locatePCFile(name: "foo", customSearchPaths: ["/custom"], fileSystem: fs, observabilityScope: observability.topScope)
        )
        XCTAssertEqual(
            "/custom/foo.pc",
            try PkgConfig(name: "foo", additionalSearchPaths: ["/custom"], fileSystem: fs, observabilityScope: observability.topScope).pcFile
        )
        XCTAssertEqual(
            "/usr/lib/pkgconfig/foo.pc",
            try PCFileFinder().locatePCFile(name: "foo", customSearchPaths: [], fileSystem: fs, observabilityScope: observability.topScope)
        )
        try Environment.makeCustom(["PKG_CONFIG_PATH": "/usr/local/opt/foo/lib/pkgconfig"]) {
            XCTAssertEqual("/usr/local/opt/foo/lib/pkgconfig/foo.pc", try PkgConfig(name: "foo", fileSystem: fs, observabilityScope: observability.topScope).pcFile)
        }
#if os(Windows)
        let separator = ";"
#else
        let separator = ":"
#endif
        try Environment.makeCustom(["PKG_CONFIG_PATH": "/usr/local/opt/foo/lib/pkgconfig\(separator)/usr/lib/pkgconfig"]) {
            XCTAssertEqual("/usr/local/opt/foo/lib/pkgconfig/foo.pc", try PkgConfig(name: "foo", fileSystem: fs, observabilityScope: observability.topScope).pcFile)
        }
    }

    func testBrewPrefix() throws {
        /// Temporary workaround for PCFileFinder's use of static variables.
        PCFileFinder.resetCachedPkgConfigPaths()

        try testWithTemporaryDirectory { tmpdir in
#if os(Windows)
            let fakePkgConfig = tmpdir.appending(components: "bin", "pkg-config.cmd")
#else
            let fakePkgConfig = tmpdir.appending(components: "bin", "pkg-config")
#endif
            try localFileSystem.createDirectory(fakePkgConfig.parentDirectory)

#if os(Windows)
            let script = """
            @echo off
            echo /Volumes/BestDrive/pkgconfig
            """
#else
            let script = """
            #!/bin/sh
            echo "/Volumes/BestDrive/pkgconfig"
            """
#endif
            try localFileSystem.writeFileContents(fakePkgConfig, string: script)
            try localFileSystem.chmod(.executable, path: fakePkgConfig, options: [])

#if os(Windows)
            _ = PCFileFinder(pkgConfig: fakePkgConfig)
#else
            _ = PCFileFinder(brewPrefix: fakePkgConfig.parentDirectory.parentDirectory)
#endif
        }

        XCTAssertEqual(PCFileFinder.pkgConfigPaths, ["/Volumes/BestDrive/pkgconfig"])
    }

    func testAbsolutePathDependency() throws {

        let libffiPath = "/usr/local/opt/libffi/lib/pkgconfig/libffi.pc"

        try loadPCFile("gobject-2.0.pc") { parser in
            XCTAssert(parser.dependencies.isEmpty)
            XCTAssertEqual(parser.privateDependencies, [libffiPath])
        }

        try loadPCFile("libffi.pc") { parser in
            XCTAssert(parser.dependencies.isEmpty)
            XCTAssert(parser.privateDependencies.isEmpty)
        }

        let fileSystem = try InMemoryFileSystem(
            files: [
                "/usr/local/opt/glib/lib/pkgconfig/gobject-2.0.pc": pcFileByteString("gobject-2.0.pc"),
                libffiPath: pcFileByteString("libffi.pc")
            ]
        )

        let observability = ObservabilitySystem.makeForTesting()

        XCTAssertNoThrow(
            try PkgConfig(
                name: "gobject-2.0",
                additionalSearchPaths: ["/usr/local/opt/glib/lib/pkgconfig"],
                brewPrefix: "/usr/local",
                fileSystem: fileSystem,
                observabilityScope: observability.topScope
            )
        )
    }

    func testUnevenQuotes() throws {
        do {
            try loadPCFile("quotes_failure.pc")
            XCTFail("Unexpected success")
        } catch PkgConfigError.parsingError(let desc) {
            XCTAssert(desc.hasPrefix("Text ended before matching quote"))
        }
    }

    func testSysrootDir() throws {
        // sysroot should be prepended to all path variables, and should therefore appear in cflags and libs.
        try loadPCFile("gtk+-3.0.pc", sysrootDir: "/opt/sysroot/somewhere") { parser in
            XCTAssertEqual(parser.variables, [
                "libdir": "/opt/sysroot/somewhere/usr/local/Cellar/gtk+3/3.18.9/lib",
                "gtk_host": "x86_64-apple-darwin15.3.0",
                "includedir": "/opt/sysroot/somewhere/usr/local/Cellar/gtk+3/3.18.9/include",
                "prefix": "/opt/sysroot/somewhere/usr/local/Cellar/gtk+3/3.18.9",
                "gtk_binary_version": "3.0.0",
                "exec_prefix": "/opt/sysroot/somewhere/usr/local/Cellar/gtk+3/3.18.9",
                "targets": "quartz",
                "pcfiledir": parser.pcFile.parentDirectory.pathString,
                "pc_sysrootdir": "/opt/sysroot/somewhere"
            ])
            XCTAssertEqual(parser.dependencies, ["gdk-3.0", "atk", "cairo", "cairo-gobject", "gdk-pixbuf-2.0", "gio-2.0"])
            XCTAssertEqual(parser.privateDependencies, ["atk", "epoxy", "gio-unix-2.0"])
            XCTAssertEqual(parser.cFlags, ["-I/opt/sysroot/somewhere/usr/local/Cellar/gtk+3/3.18.9/include/gtk-3.0"])
            XCTAssertEqual(parser.libs, ["-L/opt/sysroot/somewhere/usr/local/Cellar/gtk+3/3.18.9/lib", "-lgtk-3"])
        }

        // sysroot should be not be prepended if it is already a prefix
        // - pkgconf makes this check, but pkg-config does not
        // - If the .pc file lies outside sysrootDir, pkgconf sets pc_sysrootdir to the empty string
        //      https://github.com/pkgconf/pkgconf/issues/213
        //   SwiftPM does not currently implement this special case.
        try loadPCFile("gtk+-3.0.pc", sysrootDir: "/usr/local/Cellar") { parser in
            XCTAssertEqual(parser.variables, [
                "libdir": "/usr/local/Cellar/gtk+3/3.18.9/lib",
                "gtk_host": "x86_64-apple-darwin15.3.0",
                "includedir": "/usr/local/Cellar/gtk+3/3.18.9/include",
                "prefix": "/usr/local/Cellar/gtk+3/3.18.9",
                "gtk_binary_version": "3.0.0",
                "exec_prefix": "/usr/local/Cellar/gtk+3/3.18.9",
                "targets": "quartz",
                "pcfiledir": parser.pcFile.parentDirectory.pathString,
                "pc_sysrootdir": "/usr/local/Cellar"
            ])
            XCTAssertEqual(parser.dependencies, ["gdk-3.0", "atk", "cairo", "cairo-gobject", "gdk-pixbuf-2.0", "gio-2.0"])
            XCTAssertEqual(parser.privateDependencies, ["atk", "epoxy", "gio-unix-2.0"])
            XCTAssertEqual(parser.cFlags, ["-I/usr/local/Cellar/gtk+3/3.18.9/include/gtk-3.0"])
            XCTAssertEqual(parser.libs, ["-L/usr/local/Cellar/gtk+3/3.18.9/lib", "-lgtk-3"])
        }

        // sysroot should be not be double-prepended if it is used explicitly by the .pc file
        // - pkgconf makes this check, but pkg-config does not
        try loadPCFile("double_sysroot.pc", sysrootDir: "/sysroot") { parser in
            XCTAssertEqual(parser.variables, [
                "prefix": "/sysroot/usr",
                "datarootdir": "/sysroot/usr/share",
                "pkgdatadir": "/sysroot/usr/share/pkgdata",
                "pcfiledir": parser.pcFile.parentDirectory.pathString,
                "pc_sysrootdir": "/sysroot"
            ])
        }

        // pkgconfig strips a leading sysroot prefix if sysroot appears anywhere else in the
        // expanded variable.   SwiftPM's implementation is faithful to pkgconfig, even
        // thought it might seem more logical not to strip the prefix in this case.
        try loadPCFile("not_double_sysroot.pc", sysrootDir: "/sysroot") { parser in
            XCTAssertEqual(parser.variables, [
                "prefix": "/sysroot/usr",
                "datarootdir": "/sysroot/usr/share",
                "pkgdatadir": "/filler/sysroot/usr/share/pkgdata",
                "pcfiledir": parser.pcFile.parentDirectory.pathString,
                "pc_sysrootdir": "/sysroot"
            ])
        }

        // pkgconfig does not strip sysroot if it is a relative path
        try loadPCFile("double_sysroot.pc", sysrootDir: "sysroot") { parser in
            XCTAssertEqual(parser.variables, [
                "prefix": "sysroot/usr",
                "datarootdir": "sysroot/usr/share",
                "pkgdatadir": "sysroot/sysroot/usr/share/pkgdata",
                "pcfiledir": parser.pcFile.parentDirectory.pathString,
                "pc_sysrootdir": "sysroot"
            ])
        }
    }

    private func pcFilePath(_ inputName: String) -> AbsolutePath {
        return AbsolutePath(#file).parentDirectory.appending(components: "pkgconfigInputs", inputName)
    }

    private func loadPCFile(_ inputName: String, sysrootDir: String? = nil, body: ((PkgConfigParser) -> Void)? = nil) throws {
        var parser = try PkgConfigParser(pcFile: pcFilePath(inputName), fileSystem: localFileSystem, sysrootDir: sysrootDir)
        try parser.parse()
        body?(parser)
    }

    private func pcFileByteString(_ inputName: String) throws -> ByteString {
        return try localFileSystem.readFileContents(pcFilePath(inputName))
    }
}
