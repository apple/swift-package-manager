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


import Basics
import PackageModel
import PackageLoading
import _InternalTestSupport
import XCTest

import class TSCBasic.InMemoryFileSystem

class ToolsVersionParserTests: XCTestCase {
    func parse(_ content: String, _ body: ((ToolsVersion) -> Void)? = nil) throws {
        let toolsVersion = try ToolsVersionParser.parse(utf8String: content)
        body?(toolsVersion)
    }

    /// Verifies correct parsing for valid version specifications, and that the parser isn't confused by contents following the version specification.
    func testValidVersions() throws {
        let manifestsSnippetWithValidVersionSpecification = [
            // No spacing surrounding the label for Swift ≥ 5.4:
            "//swift-tools-version:5.4.0"              : (5, 4, 0, "5.4.0"),
            "//swift-tools-version:5.4-dev"            : (5, 4, 0, "5.4.0"),
            "//swift-tools-version:5.8.0"              : (5, 8, 0, "5.8.0"),
            "//swift-tools-version:5.8.0-dev.al+sha.x" : (5, 8, 0, "5.8.0"),
            "//swift-tools-version:6.1.2"              : (6, 1, 2, "6.1.2"),
            "//swift-tools-version:6.1.2;"             : (6, 1, 2, "6.1.2"),
            "//swift-tools-vErsion:6.1.2;;;;;"         : (6, 1, 2, "6.1.2"),
            "//swift-tools-version:6.1.2;x;x;x;x;x;"   : (6, 1, 2, "6.1.2"),
            "//swift-toolS-version:5.5.2;hello"        : (5, 5, 2, "5.5.2"),
            "//sWiFt-tOoLs-vErSiOn:5.5.2\nkkk\n"       : (5, 5, 2, "5.5.2"),
            // No spacing before, and 1 space (U+0020) after the label for Swift ≥ 5.4:
            "//swift-tools-version: 5.4.0"              : (5, 4, 0, "5.4.0"),
            "//swift-tools-version: 5.4-dev"            : (5, 4, 0, "5.4.0"),
            "//swift-tools-version: 5.8.0"              : (5, 8, 0, "5.8.0"),
            "//swift-tools-version: 5.8.0-dev.al+sha.x" : (5, 8, 0, "5.8.0"),
            "//swift-tools-version: 6.1.2"              : (6, 1, 2, "6.1.2"),
            "//swift-tools-version: 6.1.2;"             : (6, 1, 2, "6.1.2"),
            "//swift-tools-vErsion: 6.1.2;;;;;"         : (6, 1, 2, "6.1.2"),
            "//swift-tools-version: 6.1.2;x;x;x;x;x;"   : (6, 1, 2, "6.1.2"),
            "//swift-toolS-version: 5.5.2;hello"        : (5, 5, 2, "5.5.2"),
            "//sWiFt-tOoLs-vErSiOn: 5.5.2\nkkk\n"       : (5, 5, 2, "5.5.2"),
            // 1 space (U+0020) before, and no spacing after the label:
            "// swift-tools-version:3.1"                : (3, 1, 0, "3.1.0"),
            "// swift-tools-version:3.1-dev"            : (3, 1, 0, "3.1.0"),
            "// swift-tools-version:5.8.0"              : (5, 8, 0, "5.8.0"),
            "// swift-tools-version:5.8.0-dev.al+sha.x" : (5, 8, 0, "5.8.0"),
            "// swift-tools-version:3.1.2"              : (3, 1, 2, "3.1.2"),
            "// swift-tools-version:3.1.2;"             : (3, 1, 2, "3.1.2"),
            "// swift-tools-vErsion:3.1.2;;;;;"         : (3, 1, 2, "3.1.2"),
            "// swift-tools-version:3.1.2;x;x;x;x;x;"   : (3, 1, 2, "3.1.2"),
            "// swift-toolS-version:3.5.2;hello"        : (3, 5, 2, "3.5.2"),
            "// sWiFt-tOoLs-vErSiOn:3.5.2\nkkk\n"       : (3, 5, 2, "3.5.2"),
            // leading line feeds (U+000A) before the specification, and 1 space (U+0020) before and no space after the label for Swift ≥ 5.4:
            "\n// swift-tools-version:6.1"                            : (6, 1, 0, "6.1.0"),
            "\n\n// swift-tools-version:6.2-dev"                      : (6, 2, 0, "6.2.0"),
            "\n\n\n// swift-tools-version:5.8.0"                      : (5, 8, 0, "5.8.0"),
            "\n\n\n\n// swift-tools-version:6.8.0-dev.al+sha.x"       : (6, 8, 0, "6.8.0"),
            "\n\n\n\n\n// swift-tools-version:7.1.2"                  : (7, 1, 2, "7.1.2"),
            "\n\n\n\n\n\n// swift-tools-version:8.1.2;"               : (8, 1, 2, "8.1.2"),
            "\n\n\n\n\n\n\n// swift-tools-vErsion:9.1.2;;;;;"         : (9, 1, 2, "9.1.2"),
            "\n\n\n\n\n\n\n\n// swift-tools-version:6.1.2;x;x;x;x;x;" : (6, 1, 2, "6.1.2"),
            "\n\n\n\n\n\n\n\n\n// swift-toolS-version:5.5.2;hello"    : (5, 5, 2, "5.5.2"),
            "\n\n\n\n\n\n\n\n\n\n// sWiFt-tOoLs-vErSiOn:6.5.2\nkkk\n" : (6, 5, 2, "6.5.2"),
            // An assortment of horizontal whitespace characters surrounding the label for Swift ≥ 5.4:
            "//swift-tools-version:\u{2002}\u{202F}\u{3000}\u{A0}\u{1680}\t\u{2000}\u{2001}5.4.0"              : (5, 4, 0, "5.4.0"),
            "//\u{2001}swift-tools-version:\u{2002}\u{202F}\u{3000}\u{A0}\u{1680}\t\u{2000}5.4-dev"            : (5, 4, 0, "5.4.0"),
            "//\t\u{2000}\u{2001}swift-tools-version:\u{2002}\u{202F}\u{3000}\u{A0}\u{1680}5.8.0"              : (5, 8, 0, "5.8.0"),
            "//\u{1680}\t\u{2000}\u{2001}swift-tools-version:\u{2002}\u{202F}\u{3000}\u{A0}5.8.0-dev.al+sha.x" : (5, 8, 0, "5.8.0"),
            "//\u{A0}\u{1680}\t\u{2000}\u{2001}swift-tools-version:\u{2002}\u{202F}\u{3000}6.1.2"              : (6, 1, 2, "6.1.2"),
            "//\u{3000}\u{A0}\u{1680}\t\u{2000}\u{2001}swift-tools-version:\u{2002}\u{202F}6.1.2;"             : (6, 1, 2, "6.1.2"),
            "//\u{202F}\u{3000}\u{A0}\u{1680}\t\u{2000}\u{2001}swift-tools-vErsion:\u{2002}6.1.2;;;;;"         : (6, 1, 2, "6.1.2"),
            "//\u{2002}\u{202F}\u{3000}\u{A0}\u{1680}\t\u{2000}\u{2001}swift-tools-version:6.1.2;x;x;x;x;x;"   : (6, 1, 2, "6.1.2"),
            "//\u{2000}\u{2002}\u{202F}\u{3000}\t\u{2001}swift-toolS-version:\u{A0}\u{1680}5.5.2;hello"        : (5, 5, 2, "5.5.2"),
            "//\u{2000}\u{2001}\u{2002}\u{202F}\u{3000}\tsWiFt-tOoLs-vErSiOn:\u{A0}\u{1680}5.5.2\nkkk\n"       : (5, 5, 2, "5.5.2"),
            // Some leading whitespace characters, and no spacing surrounding the label for Swift ≥ 5.4:
            "\u{A} //swift-tools-version:5.4.0"                             : (5, 4, 0, "5.4.0"),
            "\u{B}\t\u{A}//swift-tools-version:5.4-dev"                     : (5, 4, 0, "5.4.0"),
            "\u{3000}\u{A0}\u{C}//swift-tools-version:5.8.0"                : (5, 8, 0, "5.8.0"),
            "\u{2002}\u{D}\u{2001}//swift-tools-version:5.8.0-dev.al+sha.x" : (5, 8, 0, "5.8.0"),
            "\u{D}\u{A}\u{A0}\u{1680}//swift-tools-version:6.1.2"           : (6, 1, 2, "6.1.2"),
            "   \u{85}//swift-tools-version:6.1.2;"                         : (6, 1, 2, "6.1.2"),
            "\u{2028}//swift-tools-vErsion:6.1.2;;;;;"                      : (6, 1, 2, "6.1.2"),
            "\u{202F}\u{2029}//swift-tools-version:6.1.2;x;x;x;x;x;"        : (6, 1, 2, "6.1.2"),
            "\u{A}\u{B}\u{C}\u{D}\u{A}\u{D}\u{85}\u{202F}\u{2029}\u{2001}\u{2002}\u{205F}\u{85}\u{2028}//swift-toolS-version:5.5.2;hello" : (5, 5, 2, "5.5.2"),
            "\u{B}  \u{200A}\u{D}\u{A}\t\u{85}\u{85}\u{A}\u{2028}\u{2009}\u{2001}\u{C}//sWiFt-tOoLs-vErSiOn:5.5.2\nkkk\n"                 : (5, 5, 2, "5.5.2"),
            // Some leading whitespace characters, and an assortment of horizontal whitespace characters surrounding the label for Swift ≥ 5.4:
            "\u{2002}\u{202F}\u{A}//\u{A0}\u{1680}\t\u{2004}\u{2001} \u{2002}swift-tools-version:\u{3000}5.4.0"       : (5, 4, 0, "5.4.0"),
            "\u{B}//\u{A0}\u{1680}\t\u{2000}\u{2001} \u{2002}swift-tools-version:\u{202F}\u{3000}5.4-dev"             : (5, 4, 0, "5.4.0"),
            "\u{C}//\u{A0}\u{1680}\t\u{2000}\u{2001} swift-tools-version:\u{2002}\u{202F}\u{3000}5.8.0"               : (5, 8, 0, "5.8.0"),
            "\u{D}//\u{A0}\u{1680}\t\u{2005} \u{202F}\u{3000}swift-tools-version:\u{2001}5.8.0-dev.al+sha.x"          : (5, 8, 0, "5.8.0"),
            "\u{D}\u{A}//\u{A0}\u{2001} \u{2002}\u{202F}\u{3000}swift-tools-version:\u{1680}\t\u{2000}6.1.2"          : (6, 1, 2, "6.1.2"),
            "\u{85}//\u{2000}\u{2001} \u{2006}\u{202F}\u{3000}swift-tools-version:\u{A0}\u{1680}\t6.1.2;"             : (6, 1, 2, "6.1.2"),
            "\u{2028}//\u{2001} \u{2002}\u{2007}\u{3000}swift-tools-vErsion:\u{A0}\u{1680}\t\u{2000}6.1.2;;;;;"       : (6, 1, 2, "6.1.2"),
            "\u{2029}//\u{202F}\u{3000}swift-tools-version:\u{A0}\u{1680}\t\u{2000}\u{2001} \u{2002}6.1.2;x;x;x;x;x;" : (6, 1, 2, "6.1.2"),
            "\u{A}\u{D}\u{85}\u{202F}\u{2029}\u{A}\u{2028}//\u{2000}\u{2001}\u{9}swift-toolS-version:\u{A0}\u{1680}\t\u{2000}\u{2009} \u{2002}\u{202F}5.5.2;hello" : (5, 5, 2, "5.5.2"),
            "\u{D}\u{A}\t\u{85}\u{85}\u{A}\u{2028}\u{2029}//\u{2001}\u{2002}\u{202F}sWiFt-tOoLs-vErSiOn:\u{1680}\t\u{2000}\u{200A} \u{2002}\u{202F}5.5.2\nkkk\n"   : (5, 5, 2, "5.5.2"),
        ]

        for (snippet, result) in manifestsSnippetWithValidVersionSpecification {
            try self.parse(snippet) { toolsVersion in
                XCTAssertEqual(toolsVersion.major, result.0)
                XCTAssertEqual(toolsVersion.minor, result.1)
                XCTAssertEqual(toolsVersion.patch, result.2)
                XCTAssertEqual(toolsVersion.description, result.3)
            }
        }


        do {
            try self.parse(
                """
                // swift-tools-version:3.1.0



                let package = ..
                """
            ) { toolsVersion in
                XCTAssertEqual(toolsVersion.description, "3.1.0")
            }
        }

        do {
            try self.parse(
                """
                // swift-tools-version:3.1.0

                // swift-tools-version:4.1.0




                let package = ..
                """
            ) { toolsVersion in
                XCTAssertEqual(toolsVersion.description, "3.1.0")
            }
        }
    }

    func testToolsVersionAllowsComments() throws {
        try self.parse(
        """
        // comment 1
        // comment 2
        // swift-tools-version: 6.0
        // comment
        let package = ..
        """
        ) { toolsVersion in
            XCTAssertEqual(toolsVersion.description, "6.0.0")
        }

        do {
            try self.parse(
            """
            // comment 1
            // comment 2
            // swift-tools-version:5.0
            // comment
            let package = ..
            """
            ) { _ in
                XCTFail("expected an error to be thrown")
            }
        } catch ToolsVersionParser.Error.backwardIncompatiblePre6_0(let incompatibility, _) {
            XCTAssertEqual(incompatibility, .toolsVersionNeedsToBeFirstLine)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        do {
            try self.parse(
            """
            // comment 1
            // comment 2
            let package = ..
            """
            ) { _ in
                XCTFail("expected an error to be thrown")
            }
        } catch ToolsVersionParser.Error.malformedToolsVersionSpecification(.label(.isMisspelt(let label))) {
            XCTAssertEqual(label, "comment")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        try self.parse(
        """
        /*
        this is a multiline comment
        */
        // swift-tools-version: 6.0
        // comment
        let package = ..
        """
        ) { toolsVersion in
            XCTAssertEqual(toolsVersion.description, "6.0.0")
        }
    }

    /// Verifies that if a manifest appears empty to SwiftPM, a distinct error is thrown.
    func testEmptyManifest() throws {
        let fs = InMemoryFileSystem()

		let packageRoot = AbsolutePath("/lorem/ipsum/dolor")
		try fs.createDirectory(packageRoot, recursive: true)

		let manifestPath = packageRoot.appending("Package.swift")
        try fs.writeFileContents(manifestPath, bytes: "")

        XCTAssertThrowsError(
            try ToolsVersionParser.parse(manifestPath: manifestPath, fileSystem: fs),
            "empty manifest '\(manifestPath.pathString)'") { error in
                guard let error = error as? ManifestParseError, case .emptyManifest(let errorPath) = error else {
                    XCTFail("'ManifestParseError.emptyManifest' should've been thrown, but a different error is thrown")
                    return
                }

                guard errorPath == manifestPath else {
                    XCTFail("error is in '\(manifestPath)', but '\(errorPath)' is given for the error message")
                    return
                }

                XCTAssertEqual(error.description, "'\(manifestPath._nativePathString(escaped: false))' is empty")
            }
    }

    /// Verifies that the correct error is thrown for each non-empty manifest missing its Swift tools version specification.
    func testMissingSpecifications() throws {
        /// Leading snippets of manifest files that don't have Swift tools version specifications.
        let manifestSnippetsWithoutSpecification = [
            "\n",
            "\n\r\r\n",
            "ni",
            "\rimport PackageDescription",
            "let package = Package(\n",
        ]

        for manifestSnippet in manifestSnippetsWithoutSpecification {
            XCTAssertThrowsError(
                try self.parse(manifestSnippet),
                "a 'ToolsVersionLoader.Error' should've been thrown, because the Swift tools version specification is missing from the manifest snippet"
            ) { error in
                guard let error = error as? ToolsVersionParser.Error, case .malformedToolsVersionSpecification(.commentMarker(.isMissing)) = error else {
                    XCTFail("'ToolsVersionLoader.Error.malformedToolsVersionSpecification(.commentMarker(.isMissing))' should've been thrown, but a different error is thrown")
                    return
                }

                XCTAssertEqual(
                    error.description,
                    "the manifest is missing a Swift tools version specification; consider prepending to the manifest '// swift-tools-version:\(ToolsVersion.current < .v5_4 ? "" : " ")\(ToolsVersion.current.major).\(ToolsVersion.current.minor)\(ToolsVersion.current.patch == 0 ? "" : ".\(ToolsVersion.current.patch)")' to specify the current Swift toolchain version as the lowest Swift version supported by the project; if such a specification already exists, consider moving it to the top of the manifest, or prepending it with '//' to help Swift Package Manager find it"
                )
            }
        }
    }

    /// Verifies that the correct error is thrown for each Swift tools version specification missing its comment marker.
    func testMissingSpecificationCommentMarkers() throws {
        let manifestSnippetsWithoutSpecificationCommentMarker = [
            " swift-tools-version:4.0",
            // Missing comment markers are diagnosed before missing Labels.
            " 4.2",
            // Missing comment markers are diagnosed before missing version specifiers.
            " swift-tools-version:",
            " ",
            // Missing comment markers are diagnosed before misspelt labels.
            " Swift toolchain version 5.1",
            " shiny-tools-version",
            // Missing comment markers are diagnosed before misspelt version specifiers.
            " swift-tools-version:0",
            " The Answer to the Ultimate Question of Life, the Universe, and Everything is 42",
            " 9999999",
            // Missing comment markers are diagnosed before backward-compatibility checks.
            "\n\n\nswift-tools-version:3.1\r",
            "\r\n\r\ncontrafibularity",
            "\n\r\t3.14",
        ]

        for manifestSnippet in manifestSnippetsWithoutSpecificationCommentMarker {
            XCTAssertThrowsError(
                try self.parse(manifestSnippet),
                "a 'ToolsVersionLoader.Error' should've been thrown, because the comment marker is missing from the Swift tools version specification"
            ) { error in
                guard let error = error as? ToolsVersionParser.Error, case .malformedToolsVersionSpecification(.commentMarker(.isMissing)) = error else {
                    XCTFail("'ToolsVersionLoader.Error.malformedToolsVersionSpecification(.commentMarker(.isMissing))' should've been thrown, but a different error is thrown")
                    return
                }
                XCTAssertEqual(
                    error.description,
                    "the manifest is missing a Swift tools version specification; consider prepending to the manifest '// swift-tools-version:\(ToolsVersion.current < .v5_4 ? "" : " ")\(ToolsVersion.current.major).\(ToolsVersion.current.minor)\(ToolsVersion.current.patch == 0 ? "" : ".\(ToolsVersion.current.patch)")' to specify the current Swift toolchain version as the lowest Swift version supported by the project; if such a specification already exists, consider moving it to the top of the manifest, or prepending it with '//' to help Swift Package Manager find it"
                )
            }
        }
    }

    /// Verifies that the correct error is thrown for each Swift tools version specification missing its label.
    func testMissingSpecificationLabels() throws {
        let manifestSnippetsWithoutSpecificationLabel = [
            "// 5.3",
            // Missing labels are diagnosed before missing version specifiers.
            "// ",
            // Missing labels are diagnosed before misspelt comment markers.
            "/// ",
            "/* ",
            // Missing labels are diagnosed before misspelt version specifiers.
            "// 6 × 9 = 42",
            "/// 99 little bugs in the code",
            // Missing labels are diagnosed before backward-compatibility checks.
            "\r\n// ",
            "//",
            "\n\r///\t2.1\r",
        ]

        for manifestSnippet in manifestSnippetsWithoutSpecificationLabel {
            XCTAssertThrowsError(
                try self.parse(manifestSnippet),
                "a 'ToolsVersionLoader.Error' should've been thrown, because the label is missing from the Swift tools version specification"
            ) { error in
                guard let error = error as? ToolsVersionParser.Error, case .malformedToolsVersionSpecification(.label(.isMissing)) = error else {
                    XCTFail("'ToolsVersionLoader.Error.malformedToolsVersionSpecification(.label(.isMissing))' should've been thrown, but a different error is thrown")
                    return
                }
                XCTAssertEqual(
                    error.description,
                    "the Swift tools version specification is missing a label; consider inserting 'swift-tools-version:' between the comment marker and the version specifier"
                )
            }
        }
    }

    /// Verifies that the correct error is thrown for each Swift tools version specification missing its version specifier.
    func testMissingVersionSpecifiers() throws {
        let manifestSnippetsWithoutVersionSpecifier = [
            "// swift-tools-version:",
            // Missing version specifiers are diagnosed before misspelt comment markers.
            "/// swift-tools-version:",
            "/* swift-tools-version:",
            // Missing version specifiers are diagnosed before misspelt labels.
            "// swallow tools version:",
            "/// We are the knights who say 'Ni!'",
            // Missing version specifiers are diagnosed before backward-compatibility checks.
            "\r\n//\tswift-tools-version:",
            "\n\r///The swifts hung in the sky in much the same way that bricks don't.\u{85}",
        ]

        for manifestSnippet in manifestSnippetsWithoutVersionSpecifier {
            XCTAssertThrowsError(
                try self.parse(manifestSnippet),
                "a 'ToolsVersionLoader.Error' should've been thrown, because the version specifier is missing from the Swift tools version specification"
            ) { error in
                guard let error = error as? ToolsVersionParser.Error, case .malformedToolsVersionSpecification(.versionSpecifier(.isMissing)) = error else {
                    XCTFail("'ToolsVersionLoader.Error.malformedToolsVersionSpecification(.versionSpecifier(.isMissing))' should've been thrown, but a different error is thrown")
                    return
                }
                XCTAssertEqual(
                    error.description,
                    "the Swift tools version specification is possibly missing a version specifier; consider using '// swift-tools-version:\(ToolsVersion.current < .v5_4 ? "" : " ")\(ToolsVersion.current.major).\(ToolsVersion.current.minor)\(ToolsVersion.current.patch == 0 ? "" : ".\(ToolsVersion.current.patch)")' to specify the current Swift toolchain version as the lowest Swift version supported by the project"
                )
            }
        }
    }

    /// Verifies that the correct error is thrown for each misspelt comment marker in Swift tools version specification.
    func testMisspeltSpecificationCommentMarkers() throws {
        let manifestSnippetsWithMisspeltSpecificationCommentMarker = [
            "/// swift-tools-version:4.0",
            "/** swift-tools-version:4.1",
            // Misspelt comment markers are diagnosed before misspelt labels.
            "//// Shiny toolchain version 4.2",
            // Misspelt comment markers are diagnosed before misspelt version specifiers.
            "/* swift-tools-version:43",
            "/** Swift version 4.4 **/",
            // Misspelt comment markers are diagnosed before backward-compatibility checks.
            "\r\r\r*/swift-tools-version:4.5",
            "\n\n\n/*/*\t\tSwift5\r",
        ]

        for manifestSnippet in manifestSnippetsWithMisspeltSpecificationCommentMarker {
            XCTAssertThrowsError(
                try self.parse(manifestSnippet),
                "a 'ToolsVersionLoader.Error' should've been thrown, because the comment marker is misspelt in the Swift tools version specification"
            ) { error in
                guard let error = error as? ToolsVersionParser.Error, case .malformedToolsVersionSpecification(.commentMarker(.isMisspelt(let misspeltCommentMarker))) = error else {
                    XCTFail("'ToolsVersionLoader.Error.malformedToolsVersionSpecification(.commentMarker(.isMisspelt))' should've been thrown, but a different error is thrown")
                    return
                }
                XCTAssertEqual(
                    error.description,
                    "the comment marker '\(misspeltCommentMarker)' is misspelt for the Swift tools version specification; consider replacing it with '//'"
                )
            }
        }
    }

    /// Verifies that the correct error is thrown for each misspelt label in Swift tools version specification.
    func testMisspeltSpecificationLabels() throws {
        let manifestSnippetsWithMisspeltSpecificationLabel = [
            "// fast-tools-version:3.0",
            // Misspelt labels are diagnosed before misspelt version specifiers.
            "// rapid-tools-version:3",
            "// swift-too1s-version:3.0",
            // Misspelt labels are diagnosed before backward-compatibility checks.
            "\n\r//\t\u{A0}prompt-t00ls-version:3.0.0.0\r\n",
        ]

        for manifestSnippet in manifestSnippetsWithMisspeltSpecificationLabel {
            XCTAssertThrowsError(
                try self.parse(manifestSnippet),
                "a 'ToolsVersionLoader.Error' should've been thrown, because the label is misspelt in the Swift tools version specification"
            ) { error in
                guard let error = error as? ToolsVersionParser.Error, case .malformedToolsVersionSpecification(.label(.isMisspelt(let misspeltLabel))) = error else {
                    XCTFail("'ToolsVersionLoader.Error.malformedToolsVersionSpecification(.label(.isMisspelt))' should've been thrown, but a different error is thrown")
                    return
                }
                XCTAssertEqual(
                    error.description,
                    "the Swift tools version specification's label '\(misspeltLabel)' is misspelt; consider replacing it with 'swift-tools-version:'"
                )
            }
        }
    }

    /// Verifies that the correct error is thrown for each misspelt version specifier in Swift tools version specification.
    func testMisspeltVersionSpecifiers() throws {
        let manifestSnippetsWithMisspeltVersionSpecifier = [
            "// swift-tools-version:5²",
            "// swift-tools-version:5⃣️.2⃣️",
            "// swift-tools-version:5 ÷ 2 = 2.5",
            // If the label starts with exactly "swift-tools-version:" (case-insensitive), then all its misspellings are treated as the version specifier's.
            "// swift-tools-version::5.2",
            "// Swift-tOOls-versIon:-2.5",
            // Misspelt version specifiers are diagnosed before backward-compatibility checks.
            "\u{A}\u{B}\u{C}\u{D}//\u{3000}swift-tools-version:五.二\u{2028}",
        ]

        for manifestSnippet in manifestSnippetsWithMisspeltVersionSpecifier {
            XCTAssertThrowsError(
                try self.parse(manifestSnippet),
                "a 'ToolsVersionLoader.Error' should've been thrown, because the version specifier is misspelt in the Swift tools version specification"
            ) { error in
                guard let error = error as? ToolsVersionParser.Error, case .malformedToolsVersionSpecification(.versionSpecifier(.isMisspelt(let misspeltVersionSpecifier))) = error else {
                    XCTFail("'ToolsVersionLoader.Error.malformedToolsVersionSpecification(.versionSpecifier(.isMisspelt))' should've been thrown, but a different error is thrown")
                    return
                }
                XCTAssertEqual(
                    error.description,
                    "the Swift tools version '\(misspeltVersionSpecifier)' is misspelt or otherwise invalid; consider replacing it with '\(ToolsVersion.current.specification())' to specify the current Swift toolchain version as the lowest Swift version supported by the project"
                )
            }
        }
    }

    /// Verifies that a correct error is thrown, if the manifest is valid for Swift tools version ≥ 5.4, but invalid for version < 5.4.
    func testBackwardIncompatibilityPre5_4() throws {

        // The order of tests in this function:
        // 1. Test backward-incompatible leading whitespace for Swift < 5.4.
        // 2. Test that backward-incompatible leading whitespace is diagnosed before backward-incompatible spacings.
        // 3. Test spacings before the label.
        // 4. Test that backward-incompatible spacings before the label are diagnosed before those after the label.
        // 5. Test spacings after the label.

        // MARK: 1 leading u+000D

        let manifestSnippetWith1LeadingCarriageReturn = [
            "\u{D}//swift-tools-version:3.1"                : "3.1.0",
            "\u{D}//swift-tools-version:3.1-dev"            : "3.1.0",
            "\u{D}//swift-tools-version:5.3"                : "5.3.0",
            "\u{D}//swift-tools-version:5.3.0"              : "5.3.0",
            "\u{D}//swift-tools-version:5.3-dev"            : "5.3.0",
            "\u{D}//swift-tools-version:4.8.0"              : "4.8.0",
            "\u{D}//swift-tools-version:4.8.0-dev.al+sha.x" : "4.8.0",
            "\u{D}//swift-tools-version:3.1.2"              : "3.1.2",
            "\u{D}//swift-tools-version:3.1.2;"             : "3.1.2",
            "\u{D}//swift-tools-vErsion:3.1.2;;;;;"         : "3.1.2",
            "\u{D}//swift-tools-version:3.1.2;x;x;x;x;x;"   : "3.1.2",
            "\u{D}//swift-toolS-version:3.5.2;hello"        : "3.5.2",
            "\u{D}//sWiFt-tOoLs-vErSiOn:3.5.2\nkkk\n"       : "3.5.2",
        ]

        for (specification, toolsVersionString) in manifestSnippetWith1LeadingCarriageReturn {
            XCTAssertThrowsError(
                try self.parse(specification),
                "a 'ToolsVersionLoader.Error' should've been thrown, because the manifest starts with a U+000D, and the specified version \(toolsVersionString) (< 5.4) supports only leading line feeds (U+000A)."
            ) { error in
                guard let error = error as? ToolsVersionParser.Error, case .backwardIncompatiblePre5_4(.leadingWhitespace, _) = error else {
                    XCTFail("'ToolsVersionLoader.Error.backwardIncompatiblePre5_4(.leadingWhitespace, _)' should've been thrown, but a different error is thrown.")
                    return
                }
                XCTAssertEqual(
                    error.description,
                    "leading whitespace sequence [U+000D] in manifest is supported by only Swift ≥ 5.4; the specified version \(toolsVersionString) supports only line feeds (U+000A) preceding the Swift tools version specification; consider moving the Swift tools version specification to the first line of the manifest"
                )
            }
        }

        // MARK: 1 U+0020

        let manifestSnippetWith1LeadingSpace = [
            "\u{20}//swift-tools-version:3.1"                : "3.1.0",
            "\u{20}//swift-tools-version:3.1-dev"            : "3.1.0",
            "\u{20}//swift-tools-version:5.3"                : "5.3.0",
            "\u{20}//swift-tools-version:5.3.0"              : "5.3.0",
            "\u{20}//swift-tools-version:5.3-dev"            : "5.3.0",
            "\u{20}//swift-tools-version:4.8.0"              : "4.8.0",
            "\u{20}//swift-tools-version:4.8.0-dev.al+sha.x" : "4.8.0",
            "\u{20}//swift-tools-version:3.1.2"              : "3.1.2",
            "\u{20}//swift-tools-version:3.1.2;"             : "3.1.2",
            "\u{20}//swift-tools-vErsion:3.1.2;;;;;"         : "3.1.2",
            "\u{20}//swift-tools-version:3.1.2;x;x;x;x;x;"   : "3.1.2",
            "\u{20}//swift-toolS-version:3.5.2;hello"        : "3.5.2",
            "\u{20}//sWiFt-tOoLs-vErSiOn:3.5.2\nkkk\n"       : "3.5.2",
        ]

        for (specification, toolsVersionString) in manifestSnippetWith1LeadingSpace {
            XCTAssertThrowsError(
                try self.parse(specification),
                "a 'ToolsVersionLoader.Error' should've been thrown, because the manifest starts with a U+0020, and the specified version \(toolsVersionString) (< 5.4) supports only leading line feeds (U+000A)."
            ) { error in
                guard let error = error as? ToolsVersionParser.Error, case .backwardIncompatiblePre5_4(.leadingWhitespace, _) = error else {
                    XCTFail("'ToolsVersionLoader.Error.backwardIncompatiblePre5_4(.leadingWhitespace, _)' should've been thrown, but a different error is thrown.")
                    return
                }
                XCTAssertEqual(
                    error.description,
                    "leading whitespace sequence [U+0020] in manifest is supported by only Swift ≥ 5.4; the specified version \(toolsVersionString) supports only line feeds (U+000A) preceding the Swift tools version specification; consider moving the Swift tools version specification to the first line of the manifest"
                )
            }
        }

        // MARK: An assortment of leading whitespace characters

        let manifestSnippetWithAnAssortmentOfLeadingWhitespaceCharacters = [
            "\u{A}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}\u{D}\u{D}\u{A}\u{85}\u{2001}\u{2028}\u{2002}\u{202F}\u{2029}\u{3000}//swift-tools-version:3.1"                : "3.1.0",
            "\u{A}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}\u{D}\u{D}\u{A}\u{85}\u{2001}\u{2028}\u{2002}\u{202F}\u{2029}\u{3000}//swift-tools-version:3.1-dev"            : "3.1.0",
            "\u{A}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}\u{D}\u{D}\u{A}\u{85}\u{2001}\u{2028}\u{2002}\u{202F}\u{2029}\u{3000}//swift-tools-version:5.3"                : "5.3.0",
            "\u{A}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}\u{D}\u{D}\u{A}\u{85}\u{2001}\u{2028}\u{2002}\u{202F}\u{2029}\u{3000}//swift-tools-version:5.3.0"              : "5.3.0",
            "\u{A}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}\u{D}\u{D}\u{A}\u{85}\u{2001}\u{2028}\u{2002}\u{202F}\u{2029}\u{3000}//swift-tools-version:5.3-dev"            : "5.3.0",
            "\u{A}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}\u{D}\u{D}\u{A}\u{85}\u{2001}\u{2028}\u{2002}\u{202F}\u{2029}\u{3000}//swift-tools-version:4.8.0"              : "4.8.0",
            "\u{A}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}\u{D}\u{D}\u{A}\u{85}\u{2001}\u{2028}\u{2002}\u{202F}\u{2029}\u{3000}//swift-tools-version:4.8.0-dev.al+sha.x" : "4.8.0",
            "\u{A}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}\u{D}\u{D}\u{A}\u{85}\u{2001}\u{2028}\u{2002}\u{202F}\u{2029}\u{3000}//swift-tools-version:3.1.2"              : "3.1.2",
            "\u{A}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}\u{D}\u{D}\u{A}\u{85}\u{2001}\u{2028}\u{2002}\u{202F}\u{2029}\u{3000}//swift-tools-version:3.1.2;"             : "3.1.2",
            "\u{A}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}\u{D}\u{D}\u{A}\u{85}\u{2001}\u{2028}\u{2002}\u{202F}\u{2029}\u{3000}//swift-tools-vErsion:3.1.2;;;;;"         : "3.1.2",
            "\u{A}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}\u{D}\u{D}\u{A}\u{85}\u{2001}\u{2028}\u{2002}\u{202F}\u{2029}\u{3000}//swift-tools-version:3.1.2;x;x;x;x;x;"   : "3.1.2",
            "\u{A}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}\u{D}\u{D}\u{A}\u{85}\u{2001}\u{2028}\u{2002}\u{202F}\u{2029}\u{3000}//swift-toolS-version:3.5.2;hello"        : "3.5.2",
            "\u{A}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}\u{D}\u{D}\u{A}\u{85}\u{2001}\u{2028}\u{2002}\u{202F}\u{2029}\u{3000}//sWiFt-tOoLs-vErSiOn:3.5.2\nkkk\n"       : "3.5.2",
        ]

        for (specification, toolsVersionString) in manifestSnippetWithAnAssortmentOfLeadingWhitespaceCharacters {
            XCTAssertThrowsError(
                try self.parse(specification),
                "a 'ToolsVersionLoader.Error' should've been thrown, because the manifest starts with an assortment of whitespace characters, and the specified version \(toolsVersionString) (< 5.4) supports only leading line feeds (U+000A)."
            ) { error in
                guard let error = error as? ToolsVersionParser.Error, case .backwardIncompatiblePre5_4(.leadingWhitespace, _) = error else {
                    XCTFail("'ToolsVersionLoader.Error.backwardIncompatiblePre5_4(.leadingWhitespace, _)' should've been thrown, but a different error is thrown.")
                    return
                }
                XCTAssertEqual(
                    error.description,
                    "leading whitespace sequence [U+000A, U+00A0, U+000B, U+1680, U+000C, U+0009, U+2000, U+000D, U+000D, U+000A, U+0085, U+2001, U+2028, U+2002, U+202F, U+2029, U+3000] in manifest is supported by only Swift ≥ 5.4; the specified version \(toolsVersionString) supports only line feeds (U+000A) preceding the Swift tools version specification; consider moving the Swift tools version specification to the first line of the manifest"
                )
            }
        }

        // MARK: An assortment of leading whitespace characters and an assortment of horizontal whitespace characters surrounding the label

        let manifestSnippetWithAnAssortmentOfLeadingWhitespaceCharactersAndAnAssortmentOfWhitespacesSurroundingLabel = [
            "\u{D}\u{202F}\u{2029}\u{85}\u{2001}\u{2028}\u{3000}\u{A}\u{D}\u{A}\u{2002}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}3.1"                : "3.1.0",
            "\u{D}\u{202F}\u{2029}\u{85}\u{2001}\u{2028}\u{3000}\u{A}\u{D}\u{A}\u{2002}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}3.1-dev"            : "3.1.0",
            "\u{D}\u{202F}\u{2029}\u{85}\u{2001}\u{2028}\u{3000}\u{A}\u{D}\u{A}\u{2002}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}5.3"                : "5.3.0",
            "\u{D}\u{202F}\u{2029}\u{85}\u{2001}\u{2028}\u{3000}\u{A}\u{D}\u{A}\u{2002}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}5.3.0"              : "5.3.0",
            "\u{D}\u{202F}\u{2029}\u{85}\u{2001}\u{2028}\u{3000}\u{A}\u{D}\u{A}\u{2002}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}5.3-dev"            : "5.3.0",
            "\u{D}\u{202F}\u{2029}\u{85}\u{2001}\u{2028}\u{3000}\u{A}\u{D}\u{A}\u{2002}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}4.8.0"              : "4.8.0",
            "\u{D}\u{202F}\u{2029}\u{85}\u{2001}\u{2028}\u{3000}\u{A}\u{D}\u{A}\u{2002}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}4.8.0-dev.al+sha.x" : "4.8.0",
            "\u{D}\u{202F}\u{2029}\u{85}\u{2001}\u{2028}\u{3000}\u{A}\u{D}\u{A}\u{2002}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}3.1.2"              : "3.1.2",
            "\u{D}\u{202F}\u{2029}\u{85}\u{2001}\u{2028}\u{3000}\u{A}\u{D}\u{A}\u{2002}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}3.1.2;"             : "3.1.2",
            "\u{D}\u{202F}\u{2029}\u{85}\u{2001}\u{2028}\u{3000}\u{A}\u{D}\u{A}\u{2002}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-vErsion:\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}3.1.2;;;;;"         : "3.1.2",
            "\u{D}\u{202F}\u{2029}\u{85}\u{2001}\u{2028}\u{3000}\u{A}\u{D}\u{A}\u{2002}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}3.1.2;x;x;x;x;x;"   : "3.1.2",
            "\u{D}\u{202F}\u{2029}\u{85}\u{2001}\u{2028}\u{3000}\u{A}\u{D}\u{A}\u{2002}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-toolS-version:\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}3.5.2;hello"        : "3.5.2",
            "\u{D}\u{202F}\u{2029}\u{85}\u{2001}\u{2028}\u{3000}\u{A}\u{D}\u{A}\u{2002}\u{A0}\u{B}\u{1680}\u{C}\t\u{2000}//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}sWiFt-tOoLs-vErSiOn:\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}3.5.2\nkkk\n"       : "3.5.2",
        ]

        // Backward-incompatible leading whitespace is diagnosed before backward-incompatible spacings surrounding the label.
        // So the errors thrown here should be about invalid leading whitespace, although both the leading whitespace and the spacings here are backward-incompatible.
        for (specification, toolsVersionString) in manifestSnippetWithAnAssortmentOfLeadingWhitespaceCharactersAndAnAssortmentOfWhitespacesSurroundingLabel {
            XCTAssertThrowsError(
                try self.parse(specification),
                "a 'ToolsVersionLoader.Error' should've been thrown, because the manifest starts with an assortment of whitespace characters, and the specified version \(toolsVersionString) (< 5.4) supports only leading line feeds (U+000A)."
            ) { error in
                guard let error = error as? ToolsVersionParser.Error, case .backwardIncompatiblePre5_4(.leadingWhitespace, _) = error else {
                    XCTFail("'ToolsVersionLoader.Error.backwardIncompatiblePre5_4(.leadingWhitespace, _)' should've been thrown, but a different error is thrown.")
                    return
                }
                XCTAssertEqual(
                    error.description,
                    "leading whitespace sequence [U+000D, U+202F, U+2029, U+0085, U+2001, U+2028, U+3000, U+000A, U+000D, U+000A, U+2002, U+00A0, U+000B, U+1680, U+000C, U+0009, U+2000] in manifest is supported by only Swift ≥ 5.4; the specified version \(toolsVersionString) supports only line feeds (U+000A) preceding the Swift tools version specification; consider moving the Swift tools version specification to the first line of the manifest"
                )
            }
        }

        // MARK: No spacing surrounding the label

        let specificationsWithZeroSpacing = [
            "//swift-tools-version:3.1"                : "3.1.0",
            "//swift-tools-version:3.1-dev"            : "3.1.0",
            "//swift-tools-version:5.3"                : "5.3.0",
            "//swift-tools-version:5.3.0"              : "5.3.0",
            "//swift-tools-version:5.3-dev"            : "5.3.0",
            "//swift-tools-version:4.8.0"              : "4.8.0",
            "//swift-tools-version:4.8.0-dev.al+sha.x" : "4.8.0",
            "//swift-tools-version:3.1.2"              : "3.1.2",
            "//swift-tools-version:3.1.2;"             : "3.1.2",
            "//swift-tools-vErsion:3.1.2;;;;;"         : "3.1.2",
            "//swift-tools-version:3.1.2;x;x;x;x;x;"   : "3.1.2",
            "//swift-toolS-version:3.5.2;hello"        : "3.5.2",
            "//sWiFt-tOoLs-vErSiOn:3.5.2\nkkk\n"       : "3.5.2",
        ]

        for (specification, toolsVersionString) in specificationsWithZeroSpacing {
            XCTAssertThrowsError(
                try self.parse(specification),
                "a 'ToolsVersionLoader.Error' should've been thrown, because there is no spacing between '//' and 'swift-tools-version', and the specified version \(toolsVersionString) (< 5.4) supports exactly 1 space (U+0020) there"
            ) { error in
                guard let error = error as? ToolsVersionParser.Error, case .backwardIncompatiblePre5_4(.spacingAfterCommentMarker, _) = error else {
                    XCTFail("'ToolsVersionLoader.Error.backwardIncompatiblePre5_4(.spacingAfterCommentMarker, _)' should've been thrown, but a different error is thrown.")
                    return
                }
                XCTAssertEqual(
                    error.description,
                    "zero spacing between '//' and 'swift-tools-version' is supported by only Swift ≥ 5.4; consider replacing the sequence with a single space (U+0020) for Swift \(toolsVersionString)"
                )
            }
        }

        // MARK: An assortment of horizontal whitespace characters before the label

        let specificationsWithAnAssortmentOfWhitespacesBeforeLabel = [
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:3.1"                : "3.1.0",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:3.1-dev"            : "3.1.0",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:5.3"                : "5.3.0",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:5.3.0"              : "5.3.0",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:5.3-dev"            : "5.3.0",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:4.8.0"              : "4.8.0",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:4.8.0-dev.al+sha.x" : "4.8.0",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:3.1.2"              : "3.1.2",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:3.1.2;"             : "3.1.2",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-vErsion:3.1.2;;;;;"         : "3.1.2",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-tools-version:3.1.2;x;x;x;x;x;"   : "3.1.2",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}swift-toolS-version:3.5.2;hello"        : "3.5.2",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}sWiFt-tOoLs-vErSiOn:3.5.2\nkkk\n"       : "3.5.2",
        ]

        for (specification, toolsVersionString) in specificationsWithAnAssortmentOfWhitespacesBeforeLabel {
            XCTAssertThrowsError(
                try self.parse(specification),
                "a 'ToolsVersionLoader.Error' should've been thrown, because the spacing between '//' and 'swift-tools-version' is an assortment of horizontal whitespace characters, and the specified version \(toolsVersionString) (< 5.4) supports exactly 1 space (U+0020) there."
            ) { error in
                guard let error = error as? ToolsVersionParser.Error, case .backwardIncompatiblePre5_4(.spacingAfterCommentMarker, _) = error else {
                    XCTFail("'ToolsVersionLoader.Error.backwardIncompatiblePre5_4(.spacingAfterCommentMarker, _)' should've been thrown, but a different error is thrown.")
                    return
                }
                XCTAssertEqual(
                    error.description,
                    "horizontal whitespace sequence [U+0009, U+0020, U+00A0, U+1680, U+2000, U+2001, U+2002, U+2003, U+2004, U+2005, U+2006, U+2007, U+2008, U+2009, U+200A, U+202F, U+205F, U+3000] between '//' and 'swift-tools-version' is supported by only Swift ≥ 5.4; consider replacing the sequence with a single space (U+0020) for Swift \(toolsVersionString)"
                )
            }
        }

        // MARK: An assortment of horizontal whitespace characters surrounding the label

        let specificationsWithAnAssortmentOfWhitespacesBeforeAndAfterLabel = [
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}swift-tools-version:\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}3.1"                : "3.1.0",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}swift-tools-version:\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}3.1-dev"            : "3.1.0",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}swift-tools-version:\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}5.3"                : "5.3.0",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}swift-tools-version:\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}5.3.0"              : "5.3.0",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}swift-tools-version:\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}5.3-dev"            : "5.3.0",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}swift-tools-version:\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}4.8.0"              : "4.8.0",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}swift-tools-version:\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}4.8.0-dev.al+sha.x" : "4.8.0",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}swift-tools-version:\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}3.1.2"              : "3.1.2",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}swift-tools-version:\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}3.1.2;"             : "3.1.2",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}swift-tools-vErsion:\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}3.1.2;;;;;"         : "3.1.2",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}swift-tools-version:\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}3.1.2;x;x;x;x;x;"   : "3.1.2",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}swift-toolS-version:\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}3.5.2;hello"        : "3.5.2",
            "//\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}sWiFt-tOoLs-vErSiOn:\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}3.5.2\nkkk\n"       : "3.5.2",
        ]

        // Backward-incompatible spacings after the comment marker is diagnosed before backward-incompatible spacings after the label.
        // So the errors thrown here should be about invalid spacing after comment marker, although both the spacings here are backward-incompatible.
        for (specification, toolsVersionString) in specificationsWithAnAssortmentOfWhitespacesBeforeAndAfterLabel {
            XCTAssertThrowsError(
                try self.parse(specification),
                "a 'ToolsVersionLoader.Error' should've been thrown, because the spacing between '//' and 'swift-tools-version' is an assortment of horizontal whitespace characters, and the specified version \(toolsVersionString) (< 5.4) supports exactly 1 space (U+0020) there."
            ) { error in
                guard let error = error as? ToolsVersionParser.Error, case .backwardIncompatiblePre5_4(.spacingAfterCommentMarker, _) = error else {
                    XCTFail("'ToolsVersionLoader.Error.backwardIncompatiblePre5_4(.spacingAfterCommentMarker, _)' should've been thrown, but a different error is thrown.")
                    return
                }
                XCTAssertEqual(
                    error.description,
                    "horizontal whitespace sequence [U+0009, U+0020, U+00A0, U+1680, U+2000, U+2001, U+2002, U+2003, U+2004] between '//' and 'swift-tools-version' is supported by only Swift ≥ 5.4; consider replacing the sequence with a single space (U+0020) for Swift \(toolsVersionString)"
                )
            }
        }

        // MARK: 1 U+0020 before the label and an assortment of horizontal whitespace characters after the label

        let specificationsWithAnAssortmentOfWhitespacesAfterLabel = [
            "// swift-tools-version:\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}3.1"                : "3.1.0",
            "// swift-tools-version:\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}3.1-dev"            : "3.1.0",
            "// swift-tools-version:\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}5.3"                : "5.3.0",
            "// swift-tools-version:\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}5.3.0"              : "5.3.0",
            "// swift-tools-version:\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}5.3-dev"            : "5.3.0",
            "// swift-tools-version:\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}4.8.0"              : "4.8.0",
            "// swift-tools-version:\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}4.8.0-dev.al+sha.x" : "4.8.0",
            "// swift-tools-version:\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}3.1.2"              : "3.1.2",
            "// swift-tools-version:\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}3.1.2;"             : "3.1.2",
            "// swift-tools-vErsion:\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}3.1.2;;;;;"         : "3.1.2",
            "// swift-tools-version:\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}3.1.2;x;x;x;x;x;"   : "3.1.2",
            "// swift-toolS-version:\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}3.5.2;hello"        : "3.5.2",
            "// sWiFt-tOoLs-vErSiOn:\u{9}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}3.5.2\nkkk\n"       : "3.5.2",
        ]

        for (specification, toolsVersionString) in specificationsWithAnAssortmentOfWhitespacesAfterLabel {
            XCTAssertThrowsError(
                try self.parse(specification),
                "a 'ToolsVersionLoader.Error' should've been thrown, because the spacing between 'swift-tools-version' and the version specifier is an assortment of horizontal whitespace characters, and the specified version \(toolsVersionString) (< 5.4) supports no spacing there."
            ) { error in
                guard let error = error as? ToolsVersionParser.Error, case .backwardIncompatiblePre5_4(.spacingAfterLabel, _) = error else {
                    XCTFail("'ToolsVersionLoader.Error.backwardIncompatiblePre5_4(.spacingAfterLabel, _)' should've been thrown, but a different error is thrown.")
                    return
                }
                XCTAssertEqual(
                    error.description,
                    "horizontal whitespace sequence [U+0009, U+0020, U+00A0, U+1680, U+2000, U+2001, U+2002, U+2003, U+2004, U+2005, U+2006, U+2007, U+2008, U+2009, U+200A, U+202F, U+205F, U+3000] immediately preceding the version specifier is supported by only Swift ≥ 5.4; consider removing the sequence for Swift \(toolsVersionString)"
                )
            }
        }

    }

    func testVersionSpecificManifest() throws {
        let fs = InMemoryFileSystem()
        let root = AbsolutePath("/pkg")

        /// Loads the tools version of root pkg.
        func parse(_ body: (ToolsVersion) -> Void) throws {
            let manifestPath = try ManifestLoader.findManifest(packagePath: root, fileSystem: fs, currentToolsVersion: .current)
            body(try ToolsVersionParser.parse(manifestPath: manifestPath, fileSystem: fs))
        }

        // Test default manifest.
        try fs.writeFileContents(root.appending("Package.swift"), string: "// swift-tools-version:3.1.1\n")
        try parse { version in
            XCTAssertEqual(version.description, "3.1.1")
        }

        // Test version specific manifests.
        let keys = ToolsVersion.current.versionSpecificKeys

        // In case the count ever changes, we will need to modify this test.
        XCTAssertEqual(keys.count, 3)

        // Test the last key.
        try fs.writeFileContents(root.appending("Package\(keys[2]).swift"), string: "// swift-tools-version:3.4.1\n")
        try parse { version in
            XCTAssertEqual(version.description, "3.4.1")
        }

        // Test the second last key.
        try fs.writeFileContents(root.appending("Package\(keys[1]).swift"), string: "// swift-tools-version:3.4.0\n")
        try parse { version in
            XCTAssertEqual(version.description, "3.4.0")
        }

        // Test the first key.
        try fs.writeFileContents(root.appending("Package\(keys[0]).swift"), string: "// swift-tools-version:3.4.5\n")
        try parse { version in
            XCTAssertEqual(version.description, "3.4.5")
        }
    }

    func testVersionSpecificManifestFallbacks() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/pkg/foo"
        )
        let root = AbsolutePath("/pkg")

        func parse(currentToolsVersion: ToolsVersion, _ body: (ToolsVersion) -> Void) throws {
            let manifestPath = try ManifestLoader.findManifest(packagePath: root, fileSystem: fs, currentToolsVersion: currentToolsVersion)
            body(try ToolsVersionParser.parse(manifestPath: manifestPath, fileSystem: fs))
        }

        try fs.writeFileContents(root.appending("Package.swift"), string: "// swift-tools-version:1.0.0\n")
        try fs.writeFileContents(root.appending("Package@swift-4.2.swift"), string: "// swift-tools-version:3.4.5\n")
        try fs.writeFileContents(root.appending("Package@swift-15.1.swift"), string: "// swift-tools-version:3.4.6\n")
        try fs.writeFileContents(root.appending("Package@swift-15.2.swift"), string: "// swift-tools-version:3.4.7\n")
        try fs.writeFileContents(root.appending("Package@swift-15.3.swift"), string: "// swift-tools-version:3.4.8\n")

        try parse(currentToolsVersion: ToolsVersion(version: "15.1.1")) { version in
            XCTAssertEqual(version.description, "3.4.6")
        }

        try parse(currentToolsVersion: ToolsVersion(version: "15.2.5")) { version in
            XCTAssertEqual(version.description, "3.4.7")
        }

        try parse(currentToolsVersion: ToolsVersion(version: "3.0.0")) { version in
            XCTAssertEqual(version.description, "1.0.0")
        }

        try parse(currentToolsVersion: ToolsVersion(version: "15.3.0")) { version in
            XCTAssertEqual(version.description, "3.4.8")
        }
    }

    func testVersionSpecificManifestMostCompatibleIfLower() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/pkg/foo"
        )
        let root = AbsolutePath("/pkg")

        try fs.writeFileContents(root.appending("Package.swift"), string: "// swift-tools-version:6.0.0\n")
        try fs.writeFileContents(root.appending("Package@swift-5.0.swift"), string: "// swift-tools-version:5.0.0\n")

        let currentToolsVersion = ToolsVersion(version: "5.5.0")
        let manifestPath = try ManifestLoader.findManifest(packagePath: root, fileSystem: fs, currentToolsVersion: currentToolsVersion)
        let version = try ToolsVersionParser.parse(manifestPath: manifestPath, fileSystem: fs)
        try version.validateToolsVersion(currentToolsVersion, packageIdentity: .plain("lunch"))
        XCTAssertEqual(version.description, "5.0.0")
    }
}
