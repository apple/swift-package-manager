//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation
import PackageModel
import PackageLoading
import _InternalTestSupport
import XCTest

import class TSCBasic.InMemoryFileSystem

class TargetSourcesBuilderTests: XCTestCase {
    func testBasicFileContentsComputation() throws {
        let target = try TargetDescription(
            name: "Foo",
            path: nil,
            exclude: ["some2"],
            sources: nil,
            resources: [
                .init(rule: .copy, path: "some/path/toBeCopied")
            ],
            publicHeadersPath: nil,
            type: .regular
        )

        let fs = InMemoryFileSystem()
        fs.createEmptyFiles(at: AbsolutePath.root, files: [
            "/Foo.swift",
            "/Bar.swift",
            "/some/path.swift",
            "/some2/path2.swift",
            "/.some2/hello.swift",
            "/Hello.something/hello.txt",
            "/file",
            "/path/to/file.xcodeproj/pbxproj",
            "/path/to/somefile.txt",
            "/some/path/toBeCopied/cool/hello.swift",
        ])

        let observability = ObservabilitySystem.makeForTesting()

        let builder = TargetSourcesBuilder(
            packageIdentity: .plain("test"),
            packageKind: .root(.root),
            packagePath: .root,
            target: target,
            path: .root,
            toolsVersion: .v5,
            fileSystem: fs,
            observabilityScope: observability.topScope
        )

        let contents = builder.computeContents().sorted()

        XCTAssertEqual(contents, [
            "/Bar.swift",
            "/Foo.swift",
            "/Hello.something/hello.txt",
            "/file",
            "/path/to/somefile.txt",
            "/some/path.swift",
            "/some/path/toBeCopied",
        ])

        XCTAssertNoDiagnostics(observability.diagnostics)
    }

    func testDirectoryWithExt_5_3() throws {
        let target = try TargetDescription(
            name: "Foo",
            path: nil,
            exclude: [],
            sources: nil,
            publicHeadersPath: nil,
            type: .regular
        )

        let fs = InMemoryFileSystem()
        fs.createEmptyFiles(at: AbsolutePath.root, files: [
            "/some/hello.swift",
            "/some.thing/hello.txt",
        ])

        let observability = ObservabilitySystem.makeForTesting()

        let builder = TargetSourcesBuilder(
            packageIdentity: .plain("test"),
            packageKind: .root(.root),
            packagePath: .root,
            target: target,
            path: .root,
            toolsVersion: .v5_3,
            fileSystem: fs,
            observabilityScope: observability.topScope
        )

        let contents = builder.computeContents().sorted()

        XCTAssertEqual(contents, [
            "/some.thing",
            "/some/hello.swift",
        ])

        XCTAssertNoDiagnostics(observability.diagnostics)
    }

    func testDirectoryWithExt_5_6() throws {
        let target = try TargetDescription(
            name: "Foo",
            path: nil,
            exclude: [],
            sources: nil,
            publicHeadersPath: nil,
            type: .regular
        )

        let fs = InMemoryFileSystem()
        fs.createEmptyFiles(at: AbsolutePath.root, files: [
            "/some/hello.swift",
            "/some.thing/hello.txt",
        ])

        let observability = ObservabilitySystem.makeForTesting()

        let builder = TargetSourcesBuilder(
            packageIdentity: .plain("test"),
            packageKind: .root(.root),
            packagePath: .root,
            target: target,
            path: .root,
            toolsVersion: .v5_6,
            fileSystem: fs,
            observabilityScope: observability.topScope
        )

        let contents = builder.computeContents().sorted()

        XCTAssertEqual(contents, [
            "/some.thing/hello.txt",
            "/some/hello.swift",
        ])

        XCTAssertNoDiagnostics(observability.diagnostics)
    }

    func testSpecialDirectoryWithExt_5_6() throws {
        let root = AbsolutePath.root

        let target = try TargetDescription(
            name: "Foo",
            path: nil,
            exclude: [],
            sources: nil,
            publicHeadersPath: nil,
            type: .regular
        )

        let fs = InMemoryFileSystem()
        fs.createEmptyFiles(at: AbsolutePath.root, files: [
            root.appending(components: "some.xcassets", "hello.txt").pathString,
            root.appending(components: "some", "hello.swift").pathString
        ])

        let observability = ObservabilitySystem.makeForTesting()

        let builder = TargetSourcesBuilder(
            packageIdentity: .plain("test"),
            packageKind: .root(.root),
            packagePath: .root,
            target: target,
            path: .root,
            toolsVersion: .v5_6,
            fileSystem: fs,
            observabilityScope: observability.topScope
        )

        let contents = builder.computeContents().sorted()

        XCTAssertEqual(contents, [
            root.appending(components: "some.xcassets"),
            root.appending(components: "some", "hello.swift"),
        ])

        XCTAssertNoDiagnostics(observability.diagnostics)
    }

    func testBasicRuleApplication() throws {
        let target = try TargetDescription(
            name: "Foo",
            path: nil,
            exclude: ["some2"],
            sources: nil,
            resources: [
                .init(rule: .process(localization: .none), path: "path"),
                .init(rule: .copy, path: "some/path/toBeCopied"),
            ],
            publicHeadersPath: nil,
            type: .regular
        )

        let fs = InMemoryFileSystem()
        fs.createEmptyFiles(at: AbsolutePath.root, files: [
            "/Foo.swift",
            "/Bar.swift",
            "/some/path.swift",
            "/some2/path2.swift",
            "/.some2/hello.swift",
            "/Hello.something/hello.txt",
            "/file",
            "/path/to/file.xcodeproj/pbxproj",
            "/path/to/somefile.txt",
            "/path/to/somefile2.txt",
            "/some/path/toBeCopied/cool/hello.swift",
        ])

        let somethingRule = FileRuleDescription(
            rule: .processResource(localization: .none),
            toolsVersion: .minimumRequired,
            fileTypes: ["something"])

        build(target: target, additionalFileRules: [somethingRule], toolsVersion: .v5, fs: fs) { _, _, _, _, _, _, _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
    }

    func testDoesNotErrorWithAdditionalFileRules() throws {
        let target = try TargetDescription(
            name: "Foo",
            path: nil,
            exclude: [],
            sources: nil,
            resources: [],
            publicHeadersPath: nil,
            type: .regular
        )

        let files: [AbsolutePath] = [
            "/Foo.swift",
            "/Bar.swift",
            "/Baz.something",
        ]

        let fs = InMemoryFileSystem()
        fs.createEmptyFiles(at: AbsolutePath.root, files: files.map(\.pathString))

        let somethingRule = FileRuleDescription(
            rule: .compile,
            toolsVersion: .v5_5,
            fileTypes: ["something"]
        )

        build(target: target, additionalFileRules: [somethingRule], toolsVersion: .v5_5, fs: fs) { sources, _, _, _, _, _, _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
            XCTAssertEqual(
                sources.paths.sorted(),
                files.sorted()
            )
        }
    }

    func testResourceConflicts() throws {
        // Conflict between processed resources.

        do {
            let target = try TargetDescription(name: "Foo", resources: [
                .init(rule: .process(localization: .none), path: "Resources")
            ])

            let fs = InMemoryFileSystem(emptyFiles:
                "/Resources/foo.txt",
                "/Resources/Sub/foo.txt"
            )

            build(target: target, toolsVersion: .v5_3, fs: fs) { _, _, _, _, identity, kind, path, diagnostics in
                testDiagnostics(diagnostics, problemsOnly: false) { result in
                    var diagnosticsFound = [Basics.Diagnostic?]()
                    diagnosticsFound.append(result.check(diagnostic: "multiple resources named 'foo.txt' in target 'Foo'", severity: .error))
                    diagnosticsFound.append(result.checkUnordered(diagnostic: "found '\(RelativePath("Resources").appending(components: "foo.txt"))'", severity: .info))
                    diagnosticsFound.append(result.checkUnordered(diagnostic: "found '\(RelativePath("Resources").appending(components: "Sub", "foo.txt"))'", severity: .info))

                    for diagnostic in diagnosticsFound {
                        XCTAssertEqual(diagnostic?.metadata?.packageIdentity, identity)
                        XCTAssertEqual(diagnostic?.metadata?.packageKind, kind)
                        XCTAssertEqual(diagnostic?.metadata?.moduleName, target.name)
                    }
                }
            }
        }

        // Conflict between processed and copied resources.

        do {
            let target = try TargetDescription(name: "Foo", resources: [
                .init(rule: .process(localization: .none), path: "Processed"),
                .init(rule: .copy, path: "Copied/foo.txt"),
            ])

            let fs = InMemoryFileSystem(emptyFiles:
                "/Processed/foo.txt",
                "/Copied/foo.txt"
            )

            build(target: target, toolsVersion: .v5_3, fs: fs) { _, _, _, _, identity, kind, path, diagnostics in
                testDiagnostics(diagnostics, problemsOnly: false) { result in
                    var diagnosticsFound = [Basics.Diagnostic?]()
                    diagnosticsFound.append(result.check(diagnostic: "multiple resources named 'foo.txt' in target 'Foo'", severity: .error))
                    diagnosticsFound.append(result.checkUnordered(diagnostic: "found '\(RelativePath("Processed").appending(components: "foo.txt"))'", severity: .info))
                    diagnosticsFound.append(result.checkUnordered(diagnostic: "found '\(RelativePath("Copied").appending(components: "foo.txt"))'", severity: .info))

                    for diagnostic in diagnosticsFound {
                        XCTAssertEqual(diagnostic?.metadata?.packageIdentity, identity)
                        XCTAssertEqual(diagnostic?.metadata?.packageKind, kind)
                        XCTAssertEqual(diagnostic?.metadata?.moduleName, target.name)
                    }
                }
            }
        }

        // No conflict between processed and copied in sub-path resources.

        do {
            let target = try TargetDescription(name: "Foo", resources: [
                .init(rule: .process(localization: .none), path: "Processed"),
                .init(rule: .copy, path: "Copied"),
            ])

            let fs = InMemoryFileSystem(emptyFiles:
                "/Processed/foo.txt",
                "/Copied/foo.txt"
            )

            build(target: target, toolsVersion: .v5_3, fs: fs) { _, _, _, _, _, _, _, diagnostics in
                XCTAssertNoDiagnostics(diagnostics)
            }
        }

        // Conflict between copied directory resources.

        do {
            let target = try TargetDescription(name: "Foo", resources: [
                .init(rule: .copy, path: "A/Copy"),
                .init(rule: .copy, path: "B/Copy"),
            ])

            let fs = InMemoryFileSystem(emptyFiles:
                "/A/Copy/foo.txt",
                "/B/Copy/foo.txt"
            )

            build(target: target, toolsVersion: .v5_3, fs: fs) { _, _, _, _, identity, kind, path, diagnostics in
                testDiagnostics(diagnostics, problemsOnly: false) { result in
                    var diagnosticsFound = [Basics.Diagnostic?]()
                    diagnosticsFound.append(result.check(diagnostic: "multiple resources named 'Copy' in target 'Foo'", severity: .error))
                    diagnosticsFound.append(result.checkUnordered(diagnostic: "found '\(RelativePath("A").appending(components: "Copy"))'", severity: .info))
                    diagnosticsFound.append(result.checkUnordered(diagnostic: "found '\(RelativePath("B").appending(components: "Copy"))'", severity: .info))

                    for diagnostic in diagnosticsFound {
                        XCTAssertEqual(diagnostic?.metadata?.packageIdentity, identity)
                        XCTAssertEqual(diagnostic?.metadata?.packageKind, kind)
                        XCTAssertEqual(diagnostic?.metadata?.moduleName, target.name)
                    }
                }
            }
        }

        // Conflict between processed localizations.

        do {
            let target = try TargetDescription(name: "Foo", resources: [
                .init(rule: .process(localization: .none), path: "A"),
                .init(rule: .process(localization: .none), path: "B"),
            ])

            let fs = InMemoryFileSystem(emptyFiles:
                "/A/en.lproj/foo.txt",
                "/B/EN.lproj/foo.txt"
            )

            build(target: target, toolsVersion: .v5_3, fs: fs) { _, _, _, _, identity, kind, path, diagnostics in
                testDiagnostics(diagnostics, problemsOnly: false) { result in
                    var diagnosticsFound = [Basics.Diagnostic?]()
                    diagnosticsFound.append(result.check(diagnostic: "multiple resources named '\(RelativePath("en.lproj").appending(components: "foo.txt"))' in target 'Foo'", severity: .error))
                    diagnosticsFound.append(result.checkUnordered(diagnostic: "found '\(RelativePath("A").appending(components: "en.lproj", "foo.txt"))'", severity: .info))
                    diagnosticsFound.append(result.checkUnordered(diagnostic: "found '\(RelativePath("B").appending(components: "EN.lproj", "foo.txt"))'", severity: .info))

                    for diagnostic in diagnosticsFound {
                        XCTAssertEqual(diagnostic?.metadata?.packageIdentity, identity)
                        XCTAssertEqual(diagnostic?.metadata?.packageKind, kind)
                        XCTAssertEqual(diagnostic?.metadata?.moduleName, target.name)
                    }
                }
            }
        }

        // Conflict between processed localizations and copied resources.

        do {
            let target = try TargetDescription(name: "Foo", resources: [
                .init(rule: .process(localization: .none), path: "A"),
                .init(rule: .copy, path: "B/en.lproj"),
            ])

            let fs = InMemoryFileSystem(emptyFiles:
                "/A/EN.lproj/foo.txt",
                "/B/en.lproj/foo.txt"
            )

            build(target: target, toolsVersion: .v5_3, fs: fs) { _, _, _, _, identity, kind, path, diagnostics in
                testDiagnostics(diagnostics) { result in
                    let diagnostic = result.check(
                        diagnostic: "resource '\(RelativePath("B").appending(components: "en.lproj"))' in target 'Foo' conflicts with other localization directories",
                        severity: .error
                    )
                    XCTAssertEqual(diagnostic?.metadata?.packageIdentity, identity)
                    XCTAssertEqual(diagnostic?.metadata?.packageKind, kind)
                    XCTAssertEqual(diagnostic?.metadata?.moduleName, target.name)
                }
            }
        }
    }

    func testLocalizationDirectoryIgnoredOn5_2() throws {
        let target = try TargetDescription(name: "Foo")

        let fs = InMemoryFileSystem(emptyFiles:
            "/en.lproj/Localizable.strings"
        )

        build(target: target, toolsVersion: .v5_2, fs: fs) { _, resources, _, _, _, _, _, diagnostics in
            XCTAssert(resources.isEmpty)
            XCTAssertNoDiagnostics(diagnostics)
        }
    }

    func testLocalizationDirectorySubDirectory() throws {
        let target = try TargetDescription(name: "Foo", resources: [
            .init(rule: .process(localization: .none), path: "Processed"),
            .init(rule: .copy, path: "Copied")
        ])

        let fs = InMemoryFileSystem(emptyFiles:
            "/Processed/en.lproj/sub/Localizable.strings",
            "/Copied/en.lproj/sub/Localizable.strings"
        )

        build(target: target, toolsVersion: .v5_3, fs: fs) { _, _, _, _, identity, kind, path, diagnostics in
            testDiagnostics(diagnostics) { result in
                let diagnostic = result.check(
                    diagnostic: "localization directory '\(RelativePath("Processed").appending(components: "en.lproj"))' in target 'Foo' contains sub-directories, which is forbidden",
                    severity: .error
                )
                XCTAssertEqual(diagnostic?.metadata?.packageIdentity, identity)
                XCTAssertEqual(diagnostic?.metadata?.packageKind, kind)
                XCTAssertEqual(diagnostic?.metadata?.moduleName, target.name)
            }
        }
    }

    func testExplicitLocalizationInLocalizationDirectory() throws {
        let target = try TargetDescription(name: "Foo", resources: [
            .init(rule: .process(localization: .base), path: "Resources"),
        ])

        let fs = InMemoryFileSystem(emptyFiles:
            "/Resources/en.lproj/Localizable.strings"
        )

        build(target: target, toolsVersion: .v5_3, fs: fs) { _, _, _, _, identity, kind, path, diagnostics in
            testDiagnostics(diagnostics) { result in
                let diagnostic = result.check(
                    diagnostic: .contains("""
                        resource '\(RelativePath("Resources").appending(components: "en.lproj", "Localizable.strings"))' in target 'Foo' is in a localization directory \
                        and has an explicit localization declaration
                        """),
                    severity: .error
                )
                XCTAssertEqual(diagnostic?.metadata?.packageIdentity, identity)
                XCTAssertEqual(diagnostic?.metadata?.packageKind, kind)
                XCTAssertEqual(diagnostic?.metadata?.moduleName, target.name)
            }
        }
    }

    // rdar://86297221
    // There is no need to validate localization exists for default localization
    func testMissingDefaultLocalization() throws {
        let target = try TargetDescription(name: "Foo", resources: [
            .init(rule: .process(localization: .none), path: "Resources"),
            .init(rule: .process(localization: .default), path: "Image.png"),
            .init(rule: .process(localization: .base), path: "Icon.png"),
        ])

        let fs = InMemoryFileSystem(emptyFiles:
            "/Resources/en.lproj/Localizable.strings",
            "/Resources/en.lproj/Icon.png",
            "/Resources/fr.lproj/Localizable.strings",
            "/Resources/fr.lproj/Sign.png",
            "/Resources/Base.lproj/Storyboard.storyboard",
            "/Image.png",
            "/Icon.png"
        )

        do {
            build(target: target, defaultLocalization: "fr", toolsVersion: .v5_3, fs: fs) { _, _, _, _, identity, kind, path, diagnostics in
                XCTAssertNoDiagnostics(diagnostics)
            }
        }

        do {
            build(target: target, defaultLocalization: "en", toolsVersion: .v5_3, fs: fs) { _, _, _, _, identity, kind, path, diagnostics in
                XCTAssertNoDiagnostics(diagnostics)
            }
        }
    }

    func testLocalizedAndUnlocalizedResources() throws {
        let target = try TargetDescription(name: "Foo", resources: [
            .init(rule: .process(localization: .none), path: "Resources"),
            .init(rule: .process(localization: .default), path: "Image.png"),
            .init(rule: .process(localization: .base), path: "Icon.png"),
        ])

        let fs = InMemoryFileSystem(emptyFiles:
            "/Resources/en.lproj/Localizable.strings",
            "/Resources/Localizable.strings",
            "/Resources/Base.lproj/Storyboard.storyboard",
            "/Resources/Storyboard.storyboard",
            "/Resources/Image.png",
            "/Resources/Icon.png",
            "/Image.png",
            "/Icon.png"
        )

        build(target: target, toolsVersion: .v5_3, fs: fs) { _, _, _, _, identity, kind, path, diagnostics in
            testDiagnostics(diagnostics) { result in
                var diagnosticsFound = [Basics.Diagnostic?]()
                diagnosticsFound.append(result.checkUnordered(
                    diagnostic: .contains("resource 'Localizable.strings' in target 'Foo' has both localized and un-localized variants"),
                    severity: .warning
                ))
                diagnosticsFound.append(result.checkUnordered(
                    diagnostic: .contains("resource 'Storyboard.storyboard' in target 'Foo' has both localized and un-localized variants"),
                    severity: .warning
                ))
                diagnosticsFound.append(result.checkUnordered(
                    diagnostic: .contains("resource 'Image.png' in target 'Foo' has both localized and un-localized variants"),
                    severity: .warning
                ))
                diagnosticsFound.append(result.checkUnordered(
                    diagnostic: .contains("resource 'Icon.png' in target 'Foo' has both localized and un-localized variants"),
                    severity: .warning
                ))

                for diagnostic in diagnosticsFound {
                    XCTAssertEqual(diagnostic?.metadata?.packageIdentity, identity)
                    XCTAssertEqual(diagnostic?.metadata?.packageKind, kind)
                    XCTAssertEqual(diagnostic?.metadata?.moduleName, target.name)
                }
            }
        }
    }

    func testLocalizedResources() throws {
        let target = try TargetDescription(name: "Foo", resources: [
            .init(rule: .process(localization: .none), path: "Processed"),
            .init(rule: .copy, path: "Copied"),
            .init(rule: .process(localization: .base), path: "Other/Launch.storyboard"),
            .init(rule: .process(localization: .default), path: "Other/Image.png"),
        ])

        let fs = InMemoryFileSystem(emptyFiles:
            "/Processed/foo.txt",
            "/Processed/En-uS.lproj/Localizable.stringsdict",
            "/Processed/en-US.lproj/Localizable.strings",
            "/Processed/fr.lproj/Localizable.strings",
            "/Processed/fr.lproj/Localizable.stringsdict",
            "/Processed/Base.lproj/Storyboard.storyboard",
            "/Copied/en.lproj/Localizable.strings",
            "/Other/Launch.storyboard",
            "/Other/Image.png"
        )

        build(target: target, defaultLocalization: "fr", toolsVersion: .v5_3, fs: fs) { _, resources, _,  _, _, _, _, diagnostics in
            XCTAssertEqual(resources.sorted(by: { $0.path < $1.path }), [
                Resource(rule: .process(localization: .none), path: "/Processed/foo.txt"),
                Resource(rule: .process(localization: "en-us"), path: "/Processed/En-uS.lproj/Localizable.stringsdict"),
                Resource(rule: .process(localization: "en-us"), path: "/Processed/en-US.lproj/Localizable.strings"),
                Resource(rule: .process(localization: "fr"), path: "/Processed/fr.lproj/Localizable.strings"),
                Resource(rule: .process(localization: "fr"), path: "/Processed/fr.lproj/Localizable.stringsdict"),
                Resource(rule: .process(localization: "Base"), path: "/Processed/Base.lproj/Storyboard.storyboard"),
                Resource(rule: .copy, path: "/Copied"),
                Resource(rule: .process(localization: "Base"), path: "/Other/Launch.storyboard"),
                Resource(rule: .process(localization: "fr"), path: "/Other/Image.png"),
            ].sorted(by: { $0.path < $1.path }))
        }
    }

    func testLocalizedImage() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Foo/fr.lproj/Image.png",
            "/Foo/es.lproj/Image.png"
        )

        build(target: try TargetDescription(name: "Foo"), defaultLocalization: "fr", toolsVersion: .v5_3, fs: fs) { _, resources, _, _, _, _, _, diagnostics in
            XCTAssertEqual(resources.sorted(by: { $0.path < $1.path }), [
                Resource(rule: .process(localization: "fr"), path: "/Foo/fr.lproj/Image.png"),
                Resource(rule: .process(localization: "es"), path: "/Foo/es.lproj/Image.png"),
            ].sorted(by: { $0.path < $1.path }))
        }
    }

    func testInfoPlistResource() throws {
        do {
            let target = try TargetDescription(name: "Foo", resources: [
                .init(rule: .process(localization: .none), path: "Resources"),
            ])

            let fs = InMemoryFileSystem(emptyFiles:
                "/Resources/Processed/Info.plist"
            )

            build(target: target, toolsVersion: .v5_3, fs: fs) { _, _, _, _, identity, kind, path, diagnostics in
                testDiagnostics(diagnostics) { result in
                    let diagnostic = result.check(
                        diagnostic: .contains("resource '\(RelativePath("Resources").appending(components: "Processed", "Info.plist"))' in target 'Foo' is forbidden"),
                        severity: .error
                    )
                    XCTAssertEqual(diagnostic?.metadata?.packageIdentity, identity)
                    XCTAssertEqual(diagnostic?.metadata?.packageKind, kind)
                    XCTAssertEqual(diagnostic?.metadata?.moduleName, target.name)
                }
            }
        }

        do {
            let target = try TargetDescription(name: "Foo", resources: [
                .init(rule: .copy, path: "Resources/Copied/Info.plist"),
            ])

            let fs = InMemoryFileSystem(emptyFiles:
                "/Resources/Copied/Info.plist"
            )

            build(target: target, toolsVersion: .v5_3, fs: fs) { _, _, _, _, identity, kind, path, diagnostics in
                testDiagnostics(diagnostics) { result in
                    let diagnostic = result.check(
                        diagnostic: .contains("resource '\(RelativePath("Resources").appending(components: "Copied", "Info.plist"))' in target 'Foo' is forbidden"),
                        severity: .error
                    )
                    XCTAssertEqual(diagnostic?.metadata?.packageIdentity, identity)
                    XCTAssertEqual(diagnostic?.metadata?.packageKind, kind)
                    XCTAssertEqual(diagnostic?.metadata?.moduleName, target.name)
                }
            }
        }
    }

    func testMissingExclude() throws {
        let target = try TargetDescription(
            name: "Foo",
            path: nil,
            exclude: ["fakeDir", "../../fileOutsideRoot.py"],
            sources: nil,
            resources: [],
            publicHeadersPath: nil,
            type: .regular
        )

        let fs = InMemoryFileSystem()
        fs.createEmptyFiles(at: AbsolutePath.root, files: [
            "/Foo.swift",
            "/Bar.swift"
        ])


        do {
            let observability = ObservabilitySystem.makeForTesting()

            let builder = TargetSourcesBuilder(
                packageIdentity: .plain("test"),
                packageKind: .root("/test"),
                packagePath: "/test",
                target: target,
                path: .root,
                toolsVersion: .v5,
                fileSystem: fs,
                observabilityScope: observability.topScope
            )
            _ = try builder.run()

            testDiagnostics(observability.diagnostics) { result in
                var diagnosticsFound = [Basics.Diagnostic?]()
                diagnosticsFound.append(result.checkUnordered(diagnostic: "Invalid Exclude '\(AbsolutePath("/fileOutsideRoot.py"))': File not found.", severity: .warning))
                diagnosticsFound.append(result.checkUnordered(diagnostic: "Invalid Exclude '\(AbsolutePath("/fakeDir"))': File not found.", severity: .warning))

                for diagnostic in diagnosticsFound {
                    XCTAssertEqual(diagnostic?.metadata?.packageIdentity, builder.packageIdentity)
                    XCTAssertEqual(diagnostic?.metadata?.packageKind, builder.packageKind)
                    XCTAssertEqual(diagnostic?.metadata?.moduleName, target.name)
                }
            }
        }

        // should not emit for "remote" packages

        do {
            let observability = ObservabilitySystem.makeForTesting()

            let builder = TargetSourcesBuilder(
                packageIdentity: .plain("test"),
                packageKind: .remoteSourceControl(SourceControlURL("https://some.where/foo/bar")),
                packagePath: "/test",
                target: target,
                path: .root,
                toolsVersion: .v5,
                fileSystem: fs,
                observabilityScope: observability.topScope
            )
            _ = try builder.run()

            XCTAssertNoDiagnostics(observability.diagnostics)
        }
    }
    
    func testMissingResource() throws {
        let target = try TargetDescription(
            name: "Foo",
            path: nil,
            exclude: [],
            sources: nil,
            resources: [.init(rule: .copy, path: "../../../Fake.txt"),
                        .init(rule: .process(localization: .none), path: "NotReal")],
            publicHeadersPath: nil,
            type: .regular
        )

        let fs = InMemoryFileSystem()
        fs.createEmptyFiles(at: AbsolutePath.root, files: [
            "/Foo.swift",
            "/Bar.swift"
        ])

        do {
            let observability = ObservabilitySystem.makeForTesting()

            let builder = TargetSourcesBuilder(
                packageIdentity: .plain("test"),
                packageKind: .root(.root),
                packagePath: .root,
                target: target,
                path: .root,
                toolsVersion: .v5,
                fileSystem: fs,
                observabilityScope: observability.topScope
            )
            _ = try builder.run()

            testDiagnostics(observability.diagnostics) { result in
                var diagnosticsFound = [Basics.Diagnostic?]()
                diagnosticsFound.append(result.checkUnordered(diagnostic: "Invalid Resource '../../../Fake.txt': File not found.", severity: .warning))
                diagnosticsFound.append(result.checkUnordered(diagnostic: "Invalid Resource 'NotReal': File not found.", severity: .warning))

                for diagnostic in diagnosticsFound {
                    XCTAssertEqual(diagnostic?.metadata?.packageIdentity, builder.packageIdentity)
                    XCTAssertEqual(diagnostic?.metadata?.packageKind, builder.packageKind)
                    XCTAssertEqual(diagnostic?.metadata?.moduleName, target.name)
                }
            }
        }

        // should not emit for "remote" packages

        do {
            let observability = ObservabilitySystem.makeForTesting()

            let builder = TargetSourcesBuilder(
                packageIdentity: .plain("test"),
                packageKind: .remoteSourceControl(SourceControlURL("https://some.where/foo/bar")),
                packagePath: .root,
                target: target,
                path: .root,
                toolsVersion: .v5,
                fileSystem: fs,
                observabilityScope: observability.topScope
            )
            _ = try builder.run()

            XCTAssertNoDiagnostics(observability.diagnostics)
        }
    }

    
    func testMissingSource() throws {
        let target = try TargetDescription(
            name: "Foo",
            path: nil,
            exclude: [],
            sources: ["InvalidPackage.swift",
                      "DoesNotExist.swift",
                      "../../Tests/InvalidPackageTests/InvalidPackageTests.swift"],
            resources: [],
            publicHeadersPath: nil,
            type: .regular
        )

        let fs = InMemoryFileSystem()
        fs.createEmptyFiles(at: AbsolutePath.root, files: [
            "/Foo.swift",
            "/Bar.swift"
        ])

        let observability = ObservabilitySystem.makeForTesting()

        let builder = TargetSourcesBuilder(
            packageIdentity: .plain("test"),
            packageKind: .root("/test"),
            packagePath: .root,
            target: target,
            path: .root,
            toolsVersion: .v5,
            fileSystem: fs,
            observabilityScope: observability.topScope
        )

        testDiagnostics(observability.diagnostics) { result in
            var diagnosticsFound = [Basics.Diagnostic?]()
            diagnosticsFound.append(result.checkUnordered(diagnostic: "Invalid Source '\(AbsolutePath("/InvalidPackage.swift"))': File not found.", severity: .warning))
            diagnosticsFound.append(result.checkUnordered(diagnostic: "Invalid Source '\(AbsolutePath("/DoesNotExist.swift"))': File not found.", severity: .warning))
            diagnosticsFound.append(result.checkUnordered(diagnostic: "Invalid Source '\(AbsolutePath("/Tests/InvalidPackageTests/InvalidPackageTests.swift"))': File not found.", severity: .warning))

            for diagnostic in diagnosticsFound {
                XCTAssertEqual(diagnostic?.metadata?.packageIdentity, builder.packageIdentity)
                XCTAssertEqual(diagnostic?.metadata?.packageKind, builder.packageKind)
                XCTAssertEqual(diagnostic?.metadata?.moduleName, target.name)
            }
        }
    }

    func testXcodeSpecificResourcesAreNotIncludedByDefault() throws {
        let target = try TargetDescription(
            name: "Foo",
            path: nil,
            exclude: [],
            sources: ["File.swift"],
            resources: [],
            publicHeadersPath: nil,
            type: .regular
        )

        let fs = InMemoryFileSystem()
        fs.createEmptyFiles(at: AbsolutePath.root, files: [
            "/File.swift",
            "/Foo.xcdatamodel"
        ])

        let observability = ObservabilitySystem.makeForTesting()

        let builder = TargetSourcesBuilder(
            packageIdentity: .plain("test"),
            packageKind: .root( "/test"),
            packagePath: .root,
            target: target,
            path: .root,
            toolsVersion: .v5_5,
            fileSystem: fs,
            observabilityScope: observability.topScope
        )
        let outputs = try builder.run()
        XCTAssertEqual(outputs.sources.paths, ["/File.swift"])
        XCTAssertEqual(outputs.resources, [])
        XCTAssertEqual(outputs.ignored, [])
        XCTAssertEqual(outputs.others, ["/Foo.xcdatamodel"])

        XCTAssertFalse(observability.hasWarningDiagnostics)
        XCTAssertFalse(observability.hasErrorDiagnostics)
    }

    func testUnhandledResources() throws {
        let target = try TargetDescription(
            name: "Foo",
            path: nil,
            exclude: [],
            sources: ["File.swift"],
            resources: [],
            publicHeadersPath: nil,
            type: .regular
        )

        let fs = InMemoryFileSystem()
        fs.createEmptyFiles(at: AbsolutePath.root, files: [
            "/File.swift",
            "/foo.bar"
        ])

        do {
            let observability = ObservabilitySystem.makeForTesting()

            let builder = TargetSourcesBuilder(
                packageIdentity: .plain("test"),
                packageKind: .root("/test"),
                packagePath: .root,
                target: target,
                path: .root,
                toolsVersion: .v5_5,
                fileSystem: fs,
                observabilityScope: observability.topScope
            )
            let outputs = try builder.run()
            XCTAssertEqual(outputs.sources.paths, ["/File.swift"])
            XCTAssertEqual(outputs.resources, [])
            XCTAssertEqual(outputs.ignored, [])
            XCTAssertEqual(outputs.others, ["/foo.bar"])

            XCTAssertFalse(observability.hasWarningDiagnostics)
            XCTAssertFalse(observability.hasErrorDiagnostics)
        }

        // should not emit for "remote" packages

        do {
            let observability = ObservabilitySystem.makeForTesting()

            let builder = TargetSourcesBuilder(
                packageIdentity: .plain("test"),
                packageKind: .remoteSourceControl(SourceControlURL("https://some.where/foo/bar")),
                packagePath: .root,
                target: target,
                path: .root,
                toolsVersion: .v5_5,
                fileSystem: fs,
                observabilityScope: observability.topScope
            )
            _ = try builder.run()

            XCTAssertNoDiagnostics(observability.diagnostics)
        }
    }

    func testDocCFilesDoNotCauseWarningOutsideXCBuild() throws {
        let target = try TargetDescription(
            name: "Foo",
            path: nil,
            exclude: [],
            sources: ["File.swift"],
            resources: [],
            publicHeadersPath: nil,
            type: .regular
        )

        let fs = InMemoryFileSystem()
        fs.createEmptyFiles(at: AbsolutePath.root, files: [
            "/File.swift",
            "/Foo.docc"
        ])

        let observability = ObservabilitySystem.makeForTesting()

        let builder = TargetSourcesBuilder(
            packageIdentity: .plain("test"),
            packageKind: .root(.root),
            packagePath: .root,
            target: target,
            path: .root,
            defaultLocalization: nil,
            additionalFileRules: FileRuleDescription.swiftpmFileTypes,
            toolsVersion: .v5_5,
            fileSystem: fs,
            observabilityScope: observability.topScope
        )
        let outputs = try builder.run()
        XCTAssertEqual(outputs.sources.paths, ["/File.swift"])
        XCTAssertEqual(outputs.resources, [])
        XCTAssertEqual(outputs.ignored, ["/Foo.docc"])
        XCTAssertEqual(outputs.others, [])

        XCTAssertNoDiagnostics(observability.diagnostics)
    }

    func testResourcesAreSorted() throws {
        let target = try TargetDescription(
            name: "Foo",
            path: nil,
            exclude: [],
            sources: ["File.swift"],
            resources: [
                .init(rule: .copy, path: "a.txt"),
                .init(rule: .copy, path: "c.txt"),
                .init(rule: .copy, path: "b.txt"),
            ],
            publicHeadersPath: nil,
            type: .regular
        )

        let fs = InMemoryFileSystem()
        fs.createEmptyFiles(at: AbsolutePath.root, files: [
            "/File.swift",
            "/a.txt",
            "/b.txt",
            "/c.txt",
        ])

        let observability = ObservabilitySystem.makeForTesting()

        let builder = TargetSourcesBuilder(
            packageIdentity: .plain("test"),
            packageKind: .root(.root),
            packagePath: .root,
            target: target,
            path: .root,
            defaultLocalization: nil,
            additionalFileRules: FileRuleDescription.swiftpmFileTypes,
            toolsVersion: .v5_5,
            fileSystem: fs,
            observabilityScope: observability.topScope
        )
        let outputs = try builder.run()
        XCTAssertEqual(outputs.sources.paths, ["/File.swift"])
        XCTAssertEqual(outputs.resources, [
            .init(rule: .copy, path: try .init(validating: "/a.txt")),
            .init(rule: .copy, path: try .init(validating: "/b.txt")),
            .init(rule: .copy, path: try .init(validating: "/c.txt")),
        ])
        XCTAssertEqual(outputs.ignored, [])
        XCTAssertEqual(outputs.others, [])

        XCTAssertNoDiagnostics(observability.diagnostics)
    }

    // MARK: -  Utilities

    private func build(
        target: TargetDescription,
        defaultLocalization: String? = nil,
        additionalFileRules: [FileRuleDescription] = [],
        toolsVersion: ToolsVersion,
        fs: FileSystem,
        file: StaticString = #file,
        line: UInt = #line,
        checker: (Sources, [Resource], [AbsolutePath], [AbsolutePath], PackageIdentity, PackageReference.Kind, AbsolutePath, [Basics.Diagnostic]) throws -> Void
    ) {
        let observability = ObservabilitySystem.makeForTesting()
        let builder = TargetSourcesBuilder(
            packageIdentity: .plain("test"),
            packageKind: .root(.root),
            packagePath: .root,
            target: target,
            path: .root,
            defaultLocalization: defaultLocalization,
            additionalFileRules: additionalFileRules,
            toolsVersion: toolsVersion,
            fileSystem: fs,
            observabilityScope: observability.topScope
        )

        do {
            let (sources, resources, headers, _, others) = try builder.run()
            try checker(sources, resources, headers, others, builder.packageIdentity, builder.packageKind, builder.packagePath, observability.diagnostics)
        } catch {
            XCTFail(error.localizedDescription, file: file, line: line)
        }
    }
}

extension TargetSourcesBuilder {
    public init(
        packageIdentity: PackageIdentity,
        packageKind: PackageReference.Kind,
        packagePath: AbsolutePath,
        target: TargetDescription,
        path: AbsolutePath,
        toolsVersion: ToolsVersion,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) {
        self.init(
            packageIdentity: packageIdentity,
            packageKind: packageKind,
            packagePath: packagePath,
            target: target,
            path: path,
            defaultLocalization: .none,
            additionalFileRules: [],
            toolsVersion: toolsVersion,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )
    }
}
