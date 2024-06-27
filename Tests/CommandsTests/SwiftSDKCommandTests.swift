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
import Commands
import _InternalTestSupport
import XCTest

import class Basics.AsyncProcess

private let sdkCommandDeprecationWarning = """
    warning: `swift experimental-sdk` command is deprecated and will be removed in a future version of SwiftPM. Use \
    `swift sdk` instead.

    """


final class SwiftSDKCommandTests: CommandsTestCase {
    func testUsage() async throws {
        for command in [SwiftPM.sdk, SwiftPM.experimentalSDK] {
            let stdout = try await command.execute(["-help"]).stdout
            XCTAssert(stdout.contains("USAGE: swift sdk <subcommand>") || stdout.contains("USAGE: swift sdk [<subcommand>]"), "got stdout:\n" + stdout)
        }
    }

    func testVersion() async throws {
        for command in [SwiftPM.sdk, SwiftPM.experimentalSDK] {
            let stdout = try await command.execute(["--version"]).stdout
            XCTAssert(stdout.contains("Swift Package Manager"), "got stdout:\n" + stdout)
        }
    }

    func testInstallSubcommand() async throws {
        for command in [SwiftPM.sdk, SwiftPM.experimentalSDK] {
            try await fixture(name: "SwiftSDKs") { fixturePath in
                for bundle in ["test-sdk.artifactbundle.tar.gz", "test-sdk.artifactbundle.zip"] {
                    var (stdout, stderr) = try await command.execute(
                        [
                            "install",
                            "--swift-sdks-path", fixturePath.pathString,
                            fixturePath.appending(bundle).pathString
                        ]
                    )

                    if command == .experimentalSDK {
                        XCTAssertMatch(stderr, .contains(sdkCommandDeprecationWarning))
                        XCTAssertNoMatch(stdout, .contains(sdkCommandDeprecationWarning))
                    }

                    // We only expect tool's output on the stdout stream.
                    XCTAssertMatch(
                        stdout,
                        .contains("\(bundle)` successfully installed as test-sdk.artifactbundle.")
                    )

                    (stdout, stderr) = try await command.execute(
                        ["list", "--swift-sdks-path", fixturePath.pathString])

                    if command == .experimentalSDK {
                        XCTAssertMatch(stderr, .contains(sdkCommandDeprecationWarning))
                        XCTAssertNoMatch(stdout, .contains(sdkCommandDeprecationWarning))
                    }

                    // We only expect tool's output on the stdout stream.
                    XCTAssertMatch(stdout, .contains("test-artifact"))

                    await XCTAssertAsyncThrowsError(try await command.execute(
                        [
                            "install",
                            "--swift-sdks-path", fixturePath.pathString,
                            fixturePath.appending(bundle).pathString
                        ]
                    )) { error in
                        guard case SwiftPMError.executionFailure(_, _, let stderr) = error else {
                            XCTFail()
                            return
                        }

                        XCTAssertTrue(
                            stderr.contains(
                                "Error: Swift SDK bundle with name `test-sdk.artifactbundle` is already installed. Can't install a new bundle with the same name."
                            ),
                            "got stderr: \(stderr)"
                        )
                    }

                    if command == .experimentalSDK {
                        XCTAssertMatch(stderr, .contains(sdkCommandDeprecationWarning))
                    }

                    (stdout, stderr) = try await command.execute(
                        ["remove", "--swift-sdks-path", fixturePath.pathString, "test-artifact"])

                    if command == .experimentalSDK {
                        XCTAssertMatch(stderr, .contains(sdkCommandDeprecationWarning))
                        XCTAssertNoMatch(stdout, .contains(sdkCommandDeprecationWarning))
                    }

                    // We only expect tool's output on the stdout stream.
                    XCTAssertMatch(stdout, .contains("test-sdk.artifactbundle` was successfully removed from the file system."))

                    (stdout, stderr) = try await command.execute(
                        ["list", "--swift-sdks-path", fixturePath.pathString])

                    if command == .experimentalSDK {
                        XCTAssertMatch(stderr, .contains(sdkCommandDeprecationWarning))
                        XCTAssertNoMatch(stdout, .contains(sdkCommandDeprecationWarning))
                    }

                    // We only expect tool's output on the stdout stream.
                    XCTAssertNoMatch(stdout, .contains("test-artifact"))
                }
            }
        }
    }

    func testConfigureSubcommand() async throws {
        let deprecationWarning = """
            warning: `swift sdk configuration` command is deprecated and will be removed in a future version of \
            SwiftPM. Use `swift sdk configure` instead.

            """

        for command in [SwiftPM.sdk, SwiftPM.experimentalSDK] {
            try await fixture(name: "SwiftSDKs") { fixturePath in
                let bundle = "test-sdk.artifactbundle.zip"

                var (stdout, stderr) = try await command.execute([
                    "install",
                    "--swift-sdks-path", fixturePath.pathString,
                    fixturePath.appending(bundle).pathString
                ])

                // We only expect tool's output on the stdout stream.
                XCTAssertMatch(
                    stdout,
                    .contains("\(bundle)` successfully installed as test-sdk.artifactbundle.")
                )

                let deprecatedShowSubcommand = ["configuration", "show"]

                for showSubcommand in [deprecatedShowSubcommand, ["configure", "--show-configuration"]] {
                    let invocation = showSubcommand + [
                        "--swift-sdks-path", fixturePath.pathString,
                        "test-artifact",
                        "aarch64-unknown-linux-gnu",
                    ]
                    (stdout, stderr) = try await command.execute(invocation)

                    if command == .experimentalSDK {
                        XCTAssertMatch(stderr, .contains(sdkCommandDeprecationWarning))
                    }

                    if showSubcommand == deprecatedShowSubcommand {
                        XCTAssertMatch(stderr, .contains(deprecationWarning))
                    }

                    let sdkSubpath = "test-sdk.artifactbundle/sdk/sdk"

                    XCTAssertEqual(stdout,
                        """
                        sdkRootPath: \(fixturePath.pathString)/\(sdkSubpath)
                        swiftResourcesPath: not set
                        swiftStaticResourcesPath: not set
                        includeSearchPaths: not set
                        librarySearchPaths: not set
                        toolsetPaths: not set

                        """,
                        invocation.joined(separator: " ")
                    )

                    let deprecatedSetSubcommand = ["configuration", "set"]
                    let deprecatedResetSubcommand = ["configuration", "reset"]
                    for setSubcommand in [deprecatedSetSubcommand, ["configure"]] {
                        for resetSubcommand in [deprecatedResetSubcommand, ["configure", "--reset"]] {
                            var invocation = setSubcommand + [
                                "--swift-resources-path", fixturePath.appending("foo").pathString,
                                "--swift-sdks-path", fixturePath.pathString,
                                "test-artifact",
                                "aarch64-unknown-linux-gnu",
                            ]
                            (stdout, stderr) = try await command.execute(invocation)

                            XCTAssertEqual(stdout, """
                                info: These properties of Swift SDK `test-artifact` for target triple `aarch64-unknown-linux-gnu` \
                                were successfully updated: swiftResourcesPath.

                                """,
                                invocation.joined(separator: " ")
                            )

                            if command == .experimentalSDK {
                                XCTAssertMatch(stderr, .contains(sdkCommandDeprecationWarning))
                            }

                            if setSubcommand == deprecatedSetSubcommand {
                                XCTAssertMatch(stderr, .contains(deprecationWarning))
                            }

                            invocation = showSubcommand + [
                                "--swift-sdks-path", fixturePath.pathString,
                                "test-artifact",
                                "aarch64-unknown-linux-gnu",
                            ]
                            (stdout, stderr) = try await command.execute(invocation)

                            XCTAssertEqual(stdout,
                                """
                                sdkRootPath: \(fixturePath.pathString)/\(sdkSubpath)
                                swiftResourcesPath: \(fixturePath.pathString)/foo
                                swiftStaticResourcesPath: not set
                                includeSearchPaths: not set
                                librarySearchPaths: not set
                                toolsetPaths: not set

                                """,
                                invocation.joined(separator: " ")
                            )

                            invocation = resetSubcommand + [
                                "--swift-sdks-path", fixturePath.pathString,
                                "test-artifact",
                                "aarch64-unknown-linux-gnu",
                            ]
                            (stdout, stderr) = try await command.execute(invocation)

                            if command == .experimentalSDK {
                                XCTAssertMatch(stderr, .contains(sdkCommandDeprecationWarning))
                            }

                            if resetSubcommand == deprecatedResetSubcommand {
                                XCTAssertMatch(stderr, .contains(deprecationWarning))
                            }

                            XCTAssertEqual(stdout,
                                """
                                info: All configuration properties of Swift SDK `test-artifact` for target triple `aarch64-unknown-linux-gnu` were successfully reset.

                                """,
                                invocation.joined(separator: " ")
                            )
                        }
                    }
                }

                (stdout, stderr) = try await command.execute(
                    ["remove", "--swift-sdks-path", fixturePath.pathString, "test-artifact"])

                // We only expect tool's output on the stdout stream.
                XCTAssertMatch(stdout, .contains("test-sdk.artifactbundle` was successfully removed from the file system."))
            }
        }
    }
}
