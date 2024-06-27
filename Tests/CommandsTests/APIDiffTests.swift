//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Build
import Commands

@_spi(SwiftPMInternal)
import DriverSupport

import Foundation
import PackageModel
import SourceControl
import _InternalTestSupport
import Workspace
import XCTest

final class APIDiffTests: CommandsTestCase {
    @discardableResult
    private func execute(
        _ args: [String],
        packagePath: AbsolutePath? = nil,
        env: Environment? = nil
    ) async throws -> (stdout: String, stderr: String) {
        var environment = env ?? [:]
        // don't ignore local packages when caching
        environment["SWIFTPM_TESTS_PACKAGECACHE"] = "1"
        return try await SwiftPM.Package.execute(args, packagePath: packagePath, env: environment)
    }

    func skipIfApiDigesterUnsupportedOrUnset() throws {
        try skipIfApiDigesterUnsupported()
        // The following is added to separate out the integration point testing of the API
        // diff digester with SwiftPM from the functionality tests of the digester itself
        guard Environment.current["SWIFTPM_TEST_API_DIFF_OUTPUT"] == "1" else {
            throw XCTSkip("Env var SWIFTPM_TEST_API_DIFF_OUTPUT must be set to test the output")
        }
    }

    func skipIfApiDigesterUnsupported() throws {
      // swift-api-digester is required to run tests.
      guard (try? UserToolchain.default.getSwiftAPIDigester()) != nil else {
        throw XCTSkip("swift-api-digester unavailable")
      }
      // SwiftPM's swift-api-digester integration relies on post-5.5 bugfixes and features,
      // not all of which can be tested for easily. Fortunately, we can test for the
      // `-disable-fail-on-error` option, and any version which supports this flag
      // will meet the other requirements.
      guard DriverSupport.checkSupportedFrontendFlags(flags: ["disable-fail-on-error"], toolchain: try UserToolchain.default, fileSystem: localFileSystem) else {
        throw XCTSkip("swift-api-digester is too old")
      }
    }

    func testInvokeAPIDiffDigester() async throws {
        try skipIfApiDigesterUnsupported()
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Foo")
            // Overwrite the existing decl.
            try localFileSystem.writeFileContents(
                packageRoot.appending("Foo.swift"),
                string: "public let foo = 42"
            )
            await XCTAssertThrowsCommandExecutionError(try await execute(["diagnose-api-breaking-changes", "1.2.3"], packagePath: packageRoot)) { error in
                XCTAssertFalse(error.stdout.isEmpty)
            }
        }
    }

    func testSimpleAPIDiff() async throws {
        try skipIfApiDigesterUnsupportedOrUnset()
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Foo")
            // Overwrite the existing decl.
            try localFileSystem.writeFileContents(
                packageRoot.appending("Foo.swift"),
                string: "public let foo = 42"
            )
            await XCTAssertThrowsCommandExecutionError(try await execute(["diagnose-api-breaking-changes", "1.2.3"], packagePath: packageRoot)) { error in
                XCTAssertMatch(error.stdout, .contains("1 breaking change detected in Foo"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: func foo() has been removed"))
            }
        }
    }

    func testMultiTargetAPIDiff() async throws {
        try skipIfApiDigesterUnsupportedOrUnset()
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")
            try localFileSystem.writeFileContents(
                packageRoot.appending(components: "Sources", "Baz", "Baz.swift"),
                string: #"public func baz() -> String { "hello, world!" }"#
            )
            try localFileSystem.writeFileContents(
                packageRoot.appending(components: "Sources", "Qux", "Qux.swift"),
                string: "public class Qux<T, U> { private let x = 1 }"
            )
            await XCTAssertThrowsCommandExecutionError(try await execute(["diagnose-api-breaking-changes", "1.2.3"], packagePath: packageRoot)) { error in
                XCTAssertMatch(error.stdout, .contains("2 breaking changes detected in Qux"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: class Qux has generic signature change from <T> to <T, U>"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: var Qux.x has been removed"))
                XCTAssertMatch(error.stdout, .contains("1 breaking change detected in Baz"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: func bar() has been removed"))
            }
        }
    }

    func testBreakageAllowlist() async throws {
        try skipIfApiDigesterUnsupportedOrUnset()
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")
            try localFileSystem.writeFileContents(
                packageRoot.appending(components: "Sources", "Baz", "Baz.swift"),
                string: #"public func baz() -> String { "hello, world!" }"#
            )
            try localFileSystem.writeFileContents(
                packageRoot.appending(components: "Sources", "Qux", "Qux.swift"),
                string: "public class Qux<T, U> { private let x = 1 }"
            )
            let customAllowlistPath = packageRoot.appending(components: "foo", "allowlist.txt")
            try localFileSystem.writeFileContents(
                customAllowlistPath,
                string: "API breakage: class Qux has generic signature change from <T> to <T, U>\n"
            )
            await XCTAssertThrowsCommandExecutionError(
                try await execute(["diagnose-api-breaking-changes", "1.2.3", "--breakage-allowlist-path", customAllowlistPath.pathString],
                            packagePath: packageRoot)
            ) { error in
                XCTAssertMatch(error.stdout, .contains("1 breaking change detected in Qux"))
                XCTAssertNoMatch(error.stdout, .contains("💔 API breakage: class Qux has generic signature change from <T> to <T, U>"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: var Qux.x has been removed"))
                XCTAssertMatch(error.stdout, .contains("1 breaking change detected in Baz"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: func bar() has been removed"))
            }

        }
    }

    func testCheckVendedModulesOnly() async throws {
        try skipIfApiDigesterUnsupportedOrUnset()
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("NonAPILibraryTargets")
            try localFileSystem.writeFileContents(
                packageRoot.appending(components: "Sources", "Foo", "Foo.swift"),
                string: #"public func baz() -> String { "hello, world!" }"#
            )
            try localFileSystem.writeFileContents(
                packageRoot.appending(components: "Sources", "Bar", "Bar.swift"),
                string: "public class Qux<T, U> { private let x = 1 }"
            )
            try localFileSystem.writeFileContents(
                packageRoot.appending(components: "Sources", "Baz", "Baz.swift"),
                string: "public enum Baz {case a, b, c }"
            )
            try localFileSystem.writeFileContents(
                packageRoot.appending(components: "Sources", "Qux", "Qux.swift"),
                string: "public class Qux<T, U> { private let x = 1 }"
            )
            await XCTAssertThrowsCommandExecutionError(try await execute(["diagnose-api-breaking-changes", "1.2.3"], packagePath: packageRoot)) { error in
                XCTAssertMatch(error.stdout, .contains("1 breaking change detected in Foo"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: struct Foo has been removed"))
                XCTAssertMatch(error.stdout, .contains("2 breaking changes detected in Bar"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: import Baz has been removed"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: func bar() has been removed"))
                XCTAssertMatch(error.stdout, .contains("1 breaking change detected in Baz"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: enumelement Baz.b has been added as a new enum case"))

                // Qux is not part of a library product, so any API changes should be ignored
                XCTAssertNoMatch(error.stdout, .contains("2 breaking changes detected in Qux"))
                XCTAssertNoMatch(error.stdout, .contains("💔 API breakage: class Qux has generic signature change from <T> to <T, U>"))
                XCTAssertNoMatch(error.stdout, .contains("💔 API breakage: var Qux.x has been removed"))
            }
        }
    }

    func testFilters() async throws {
        try skipIfApiDigesterUnsupportedOrUnset()
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("NonAPILibraryTargets")
            try localFileSystem.writeFileContents(
                packageRoot.appending(components: "Sources", "Foo", "Foo.swift"),
                string: #"public func baz() -> String { "hello, world!" }"#
            )
            try localFileSystem.writeFileContents(
                packageRoot.appending(components: "Sources", "Bar", "Bar.swift"),
                string: "public class Qux<T, U> { private let x = 1 }"
            )
            try localFileSystem.writeFileContents(
                packageRoot.appending(components: "Sources", "Baz", "Baz.swift"),
                string: "public enum Baz {case a, b, c }"
            )
            try localFileSystem.writeFileContents(
                packageRoot.appending(components: "Sources", "Qux", "Qux.swift"),
                string: "public class Qux<T, U> { private let x = 1 }"
            )
            await XCTAssertThrowsCommandExecutionError(
                try await execute(["diagnose-api-breaking-changes", "1.2.3", "--products", "One", "--targets", "Bar"], packagePath: packageRoot)
            ) { error in
                XCTAssertMatch(error.stdout, .contains("1 breaking change detected in Foo"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: struct Foo has been removed"))
                XCTAssertMatch(error.stdout, .contains("2 breaking changes detected in Bar"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: import Baz has been removed"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: func bar() has been removed"))

                XCTAssertNoMatch(error.stdout, .contains("1 breaking change detected in Baz"))
                XCTAssertNoMatch(error.stdout, .contains("💔 API breakage: enumelement Baz.b has been added as a new enum case"))
                XCTAssertNoMatch(error.stdout, .contains("2 breaking changes detected in Qux"))
                XCTAssertNoMatch(error.stdout, .contains("💔 API breakage: class Qux has generic signature change from <T> to <T, U>"))
                XCTAssertNoMatch(error.stdout, .contains("💔 API breakage: var Qux.x has been removed"))
            }

            // Diff a target which didn't have a baseline generated as part of the first invocation
            await XCTAssertThrowsCommandExecutionError(
                try await execute(["diagnose-api-breaking-changes", "1.2.3", "--targets", "Baz"], packagePath: packageRoot)
            ) { error in
                XCTAssertMatch(error.stdout, .contains("1 breaking change detected in Baz"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: enumelement Baz.b has been added as a new enum case"))

                XCTAssertNoMatch(error.stdout, .contains("1 breaking change detected in Foo"))
                XCTAssertNoMatch(error.stdout, .contains("💔 API breakage: struct Foo has been removed"))
                XCTAssertNoMatch(error.stdout, .contains("1 breaking change detected in Bar"))
                XCTAssertNoMatch(error.stdout, .contains("💔 API breakage: func bar() has been removed"))
                XCTAssertNoMatch(error.stdout, .contains("2 breaking changes detected in Qux"))
                XCTAssertNoMatch(error.stdout, .contains("💔 API breakage: class Qux has generic signature change from <T> to <T, U>"))
                XCTAssertNoMatch(error.stdout, .contains("💔 API breakage: var Qux.x has been removed"))
            }

            // Test diagnostics
            await XCTAssertThrowsCommandExecutionError(
                try await execute(["diagnose-api-breaking-changes", "1.2.3", "--targets", "NotATarget", "Exec", "--products", "NotAProduct", "Exec"],
                            packagePath: packageRoot)
            ) { error in
                XCTAssertMatch(error.stderr, .contains("error: no such product 'NotAProduct'"))
                XCTAssertMatch(error.stderr, .contains("error: no such target 'NotATarget'"))
                XCTAssertMatch(error.stderr, .contains("'Exec' is not a library product"))
                XCTAssertMatch(error.stderr, .contains("'Exec' is not a library target"))
            }
        }
    }

    func testAPIDiffOfModuleWithCDependency() async throws {
        try skipIfApiDigesterUnsupportedOrUnset()
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("CTargetDep")
            // Overwrite the existing decl.
            try localFileSystem.writeFileContents(packageRoot.appending(components: "Sources", "Bar", "Bar.swift"), string:
                """
                import Foo

                public func bar() -> String {
                    foo()
                    return "hello, world!"
                }
                """
            )
            await XCTAssertThrowsCommandExecutionError(try await execute(["diagnose-api-breaking-changes", "1.2.3"], packagePath: packageRoot)) { error in
                XCTAssertMatch(error.stdout, .contains("1 breaking change detected in Bar"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: func bar() has return type change from Swift.Int to Swift.String"))
            }

            // Report an error if we explicitly ask to diff a C-family target
            await XCTAssertThrowsCommandExecutionError(try await execute(["diagnose-api-breaking-changes", "1.2.3", "--targets", "Foo"], packagePath: packageRoot)) { error in
                XCTAssertMatch(error.stderr, .contains("error: 'Foo' is not a Swift language target"))
            }
        }
    }

    func testNoBreakingChanges() async throws {
        try skipIfApiDigesterUnsupportedOrUnset()
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")
            // Introduce an API-compatible change
            try localFileSystem.writeFileContents(
                packageRoot.appending(components: "Sources", "Baz", "Baz.swift"),
                string: "public func bar() -> Int { 100 }"
            )
            let (output, _) = try await execute(["diagnose-api-breaking-changes", "1.2.3"], packagePath: packageRoot)
            XCTAssertMatch(output, .contains("No breaking changes detected in Baz"))
            XCTAssertMatch(output, .contains("No breaking changes detected in Qux"))
        }
    }

    func testAPIDiffAfterAddingNewTarget() async throws {
        try skipIfApiDigesterUnsupportedOrUnset()
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Bar")
            try localFileSystem.createDirectory(packageRoot.appending(components: "Sources", "Foo"))
            try localFileSystem.writeFileContents(
                packageRoot.appending(components: "Sources", "Foo", "Foo.swift"),
                string: #"public let foo = "All new module!""#
            )
            try localFileSystem.writeFileContents(packageRoot.appending("Package.swift"), string:
                """
                // swift-tools-version:4.2
                import PackageDescription

                let package = Package(
                    name: "Bar",
                    products: [
                        .library(name: "Baz", targets: ["Baz"]),
                        .library(name: "Qux", targets: ["Qux", "Foo"]),
                    ],
                    targets: [
                        .target(name: "Baz"),
                        .target(name: "Qux"),
                        .target(name: "Foo")
                    ]
                )
                """
            )
            let (output, _) = try await execute(["diagnose-api-breaking-changes", "1.2.3"], packagePath: packageRoot)
            XCTAssertMatch(output, .contains("No breaking changes detected in Baz"))
            XCTAssertMatch(output, .contains("No breaking changes detected in Qux"))
            XCTAssertMatch(output, .contains("Skipping Foo because it does not exist in the baseline"))
        }
    }

    func testBadTreeish() async throws {
        try skipIfApiDigesterUnsupportedOrUnset()
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Foo")
            await XCTAssertThrowsCommandExecutionError(try await execute(["diagnose-api-breaking-changes", "7.8.9"], packagePath: packageRoot)) { error in
                XCTAssertMatch(error.stderr, .contains("error: Couldn’t get revision"))
            }
        }
    }

    func testBranchUpdate() async throws {
        try skipIfApiDigesterUnsupportedOrUnset()
        try await withTemporaryDirectory { baselineDir in
            try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
                let packageRoot = fixturePath.appending("Foo")
                let repo = GitRepository(path: packageRoot)
                try repo.checkout(newBranch: "feature")
                // Overwrite the existing decl.
                try localFileSystem.writeFileContents(
                    packageRoot.appending("Foo.swift"),
                    string: "public let foo = 42"
                )
                try repo.stage(file: "Foo.swift")
                try repo.commit(message: "Add foo")
                await XCTAssertThrowsCommandExecutionError(
                    try await execute(["diagnose-api-breaking-changes", "main", "--baseline-dir",
                                 baselineDir.pathString],
                                packagePath: packageRoot)
                ) { error in
                    XCTAssertMatch(error.stdout, .contains("1 breaking change detected in Foo"))
                    XCTAssertMatch(error.stdout, .contains("💔 API breakage: func foo() has been removed"))
                }

                // Update `main` and ensure the baseline is regenerated.
                try repo.checkout(revision: .init(identifier: "main"))
                try localFileSystem.writeFileContents(
                    packageRoot.appending("Foo.swift"),
                    string: "public let foo = 42"
                )
                try repo.stage(file: "Foo.swift")
                try repo.commit(message: "Add foo")
                try repo.checkout(revision: .init(identifier: "feature"))
                let (output, _) = try await execute(["diagnose-api-breaking-changes", "main", "--baseline-dir", baselineDir.pathString],
                                              packagePath: packageRoot)
                XCTAssertMatch(output, .contains("No breaking changes detected in Foo"))
            }
        }
    }

    func testBaselineDirOverride() async throws {
        try skipIfApiDigesterUnsupportedOrUnset()
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Foo")
            // Overwrite the existing decl.
            try localFileSystem.writeFileContents(
                packageRoot.appending("Foo.swift"),
                string: "public let foo = 42"
            )

            let baselineDir = fixturePath.appending("Baselines")
            let repo = GitRepository(path: packageRoot)
            let revision = try repo.resolveRevision(identifier: "1.2.3")

            await XCTAssertThrowsCommandExecutionError(
                try await execute(["diagnose-api-breaking-changes", "1.2.3", "--baseline-dir", baselineDir.pathString], packagePath: packageRoot)
            ) { error in
                XCTAssertMatch(error.stdout, .contains("1 breaking change detected in Foo"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: func foo() has been removed"))
                XCTAssertFileExists(baselineDir.appending(components: revision.identifier, "Foo.json"))
            }
        }
    }

    func testRegenerateBaseline() async throws {
       try skipIfApiDigesterUnsupportedOrUnset()
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("Foo")
            // Overwrite the existing decl.
            try localFileSystem.writeFileContents(
                packageRoot.appending("Foo.swift"),
                string: "public let foo = 42"
            )

            let repo = GitRepository(path: packageRoot)
            let revision = try repo.resolveRevision(identifier: "1.2.3")

            let baselineDir = fixturePath.appending("Baselines")
            let fooBaselinePath = baselineDir.appending(components: revision.identifier, "Foo.json")

            try localFileSystem.createDirectory(fooBaselinePath.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(
                fooBaselinePath,
                string: "Old Baseline"
            )

            await XCTAssertThrowsCommandExecutionError(
                try await execute(["diagnose-api-breaking-changes", "1.2.3",
                             "--baseline-dir", baselineDir.pathString,
                             "--regenerate-baseline"],
                            packagePath: packageRoot)
            ) { error in
                XCTAssertMatch(error.stdout, .contains("1 breaking change detected in Foo"))
                XCTAssertMatch(error.stdout, .contains("💔 API breakage: func foo() has been removed"))
                XCTAssertFileExists(fooBaselinePath)
                let content: String = try! localFileSystem.readFileContents(fooBaselinePath)
                XCTAssertNotEqual(content, "Old Baseline")
            }
        }
    }

    func testOldName() async throws {
        await XCTAssertThrowsCommandExecutionError(try await execute(["experimental-api-diff", "1.2.3", "--regenerate-baseline"], packagePath: nil)) { error in
            XCTAssertMatch(error.stdout, .contains("`swift package experimental-api-diff` has been renamed to `swift package diagnose-api-breaking-changes`"))
        }
    }

    func testBrokenAPIDiff() async throws {
        try skipIfApiDigesterUnsupportedOrUnset()
        try await fixture(name: "Miscellaneous/APIDiff/") { fixturePath in
            let packageRoot = fixturePath.appending("BrokenPkg")
            await XCTAssertThrowsCommandExecutionError(try await execute(["diagnose-api-breaking-changes", "1.2.3"], packagePath: packageRoot)) { error in
                XCTAssertMatch(error.stderr, .contains("baseline for Swift2 contains no symbols, swift-api-digester output"))
            }
        }
    }
}
