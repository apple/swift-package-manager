/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest
import Foundation
import TSCBasic
import Build
import Commands
import SourceControl
import SPMTestSupport

final class APIDiffTests: XCTestCase {
    @discardableResult
    private func execute(
        _ args: [String],
        packagePath: AbsolutePath? = nil,
        env: [String: String]? = nil
    ) throws -> (stdout: String, stderr: String) {
        var environment = env ?? [:]
        // don't ignore local packages when caching
        environment["SWIFTPM_TESTS_PACKAGECACHE"] = "1"
        return try SwiftPMProduct.SwiftPackage.execute(args, packagePath: packagePath, env: environment)
    }

    func skipIfApiDigesterUnsupported() throws {
      // swift-api-digester is required to run tests.
      guard (try? Resources.default.toolchain.getSwiftAPIDigester()) != nil else {
        throw XCTSkip("swift-api-digester unavailable")
      }
      // SwiftPM's swift-api-digester integration relies on post-5.5 bugfixes and features,
      // not all of which can be tested for easily. Fortunately, we can test for the
      // `-disable-fail-on-error` option, and any version which supports this flag
      // will meet the other requirements.
      guard SwiftTargetBuildDescription.checkSupportedFrontendFlags(flags: ["disable-fail-on-error"], fs: localFileSystem) else {
        throw XCTSkip("swift-api-digester is too old")
      }
    }

    func testSimpleAPIDiff() throws {
        try skipIfApiDigesterUnsupported()
        fixture(name: "Miscellaneous/APIDiff/") { prefix in
            let packageRoot = prefix.appending(component: "Foo")
            // Overwrite the existing decl.
            try localFileSystem.writeFileContents(packageRoot.appending(component: "Foo.swift")) {
                $0 <<< "public let foo = 42"
            }
            XCTAssertThrowsError(try execute(["diagnose-api-breaking-changes", "1.2.3"], packagePath: packageRoot)) { error in
                guard case SwiftPMProductError.executionFailure(error: _, output: let output, stderr: _) = error else {
                    XCTFail("Unexpected error")
                    return
                }
                XCTAssertTrue(output.contains("1 breaking change detected in Foo"))
                XCTAssertTrue(output.contains("💔 API breakage: func foo() has been removed"))
            }
        }
    }

    func testMultiTargetAPIDiff() throws {
        try skipIfApiDigesterUnsupported()
        fixture(name: "Miscellaneous/APIDiff/") { prefix in
            let packageRoot = prefix.appending(component: "Bar")
            try localFileSystem.writeFileContents(packageRoot.appending(components: "Sources", "Baz", "Baz.swift")) {
                $0 <<< "public func baz() -> String { \"hello, world!\" }"
            }
            try localFileSystem.writeFileContents(packageRoot.appending(components: "Sources", "Qux", "Qux.swift")) {
                $0 <<< "public class Qux<T, U> { private let x = 1 }"
            }
            XCTAssertThrowsError(try execute(["diagnose-api-breaking-changes", "1.2.3", "-j", "2"], packagePath: packageRoot)) { error in
                guard case SwiftPMProductError.executionFailure(error: _, output: let output, stderr: _) = error else {
                    XCTFail("Unexpected error")
                    return
                }
                XCTAssertTrue(output.contains("2 breaking changes detected in Qux"))
                XCTAssertTrue(output.contains("💔 API breakage: class Qux has generic signature change from <T> to <T, U>"))
                XCTAssertTrue(output.contains("💔 API breakage: var Qux.x has been removed"))
                XCTAssertTrue(output.contains("1 breaking change detected in Baz"))
                XCTAssertTrue(output.contains("💔 API breakage: func bar() has been removed"))
            }
        }
    }

    func testBreakageAllowlist() throws {
        try skipIfApiDigesterUnsupported()
        fixture(name: "Miscellaneous/APIDiff/") { prefix in
            let packageRoot = prefix.appending(component: "Bar")
            try localFileSystem.writeFileContents(packageRoot.appending(components: "Sources", "Baz", "Baz.swift")) {
                $0 <<< "public func baz() -> String { \"hello, world!\" }"
            }
            try localFileSystem.writeFileContents(packageRoot.appending(components: "Sources", "Qux", "Qux.swift")) {
                $0 <<< "public class Qux<T, U> { private let x = 1 }"
            }
            let customAllowlistPath = packageRoot.appending(components: "foo", "allowlist.txt")
            try localFileSystem.writeFileContents(customAllowlistPath) {
                $0 <<< "API breakage: class Qux has generic signature change from <T> to <T, U>\n"
            }
            XCTAssertThrowsError(try execute(["diagnose-api-breaking-changes", "1.2.3", "-j", "2",
                                              "--breakage-allowlist-path", customAllowlistPath.pathString],
                                             packagePath: packageRoot)) { error in
                guard case SwiftPMProductError.executionFailure(error: _, output: let output, stderr: _) = error else {
                    XCTFail("Unexpected error")
                    return
                }
                XCTAssertTrue(output.contains("1 breaking change detected in Qux"))
                XCTAssertFalse(output.contains("💔 API breakage: class Qux has generic signature change from <T> to <T, U>"))
                XCTAssertTrue(output.contains("💔 API breakage: var Qux.x has been removed"))
                XCTAssertTrue(output.contains("1 breaking change detected in Baz"))
                XCTAssertTrue(output.contains("💔 API breakage: func bar() has been removed"))
            }

        }
    }

    func testCheckVendedModulesOnly() throws {
        try skipIfApiDigesterUnsupported()
        fixture(name: "Miscellaneous/APIDiff/") { prefix in
            let packageRoot = prefix.appending(component: "NonAPILibraryTargets")
            try localFileSystem.writeFileContents(packageRoot.appending(components: "Sources", "Foo", "Foo.swift")) {
                $0 <<< "public func baz() -> String { \"hello, world!\" }"
            }
            try localFileSystem.writeFileContents(packageRoot.appending(components: "Sources", "Bar", "Bar.swift")) {
                $0 <<< "public class Qux<T, U> { private let x = 1 }"
            }
            try localFileSystem.writeFileContents(packageRoot.appending(components: "Sources", "Baz", "Baz.swift")) {
                $0 <<< "public enum Baz {case a, b, c }"
            }
            try localFileSystem.writeFileContents(packageRoot.appending(components: "Sources", "Qux", "Qux.swift")) {
                $0 <<< "public class Qux<T, U> { private let x = 1 }"
            }
            XCTAssertThrowsError(try execute(["diagnose-api-breaking-changes", "1.2.3"], packagePath: packageRoot)) { error in
                guard case SwiftPMProductError.executionFailure(error: _, output: let output, stderr: _) = error else {
                    XCTFail("Unexpected error")
                    return
                }
                XCTAssertTrue(output.contains("1 breaking change detected in Foo"))
                XCTAssertTrue(output.contains("💔 API breakage: struct Foo has been removed"))
                XCTAssertTrue(output.contains("1 breaking change detected in Bar"))
                XCTAssertTrue(output.contains("💔 API breakage: func bar() has been removed"))
                XCTAssertTrue(output.contains("1 breaking change detected in Baz"))
                XCTAssertTrue(output.contains("💔 API breakage: enumelement Baz.b has been added as a new enum case"))

                // Qux is not part of a library product, so any API changes should be ignored
                XCTAssertFalse(output.contains("2 breaking changes detected in Qux"))
                XCTAssertFalse(output.contains("💔 API breakage: class Qux has generic signature change from <T> to <T, U>"))
                XCTAssertFalse(output.contains("💔 API breakage: var Qux.x has been removed"))
            }
        }
    }

    func testFilters() throws {
        try skipIfApiDigesterUnsupported()
        fixture(name: "Miscellaneous/APIDiff/") { prefix in
            let packageRoot = prefix.appending(component: "NonAPILibraryTargets")
            try localFileSystem.writeFileContents(packageRoot.appending(components: "Sources", "Foo", "Foo.swift")) {
                $0 <<< "public func baz() -> String { \"hello, world!\" }"
            }
            try localFileSystem.writeFileContents(packageRoot.appending(components: "Sources", "Bar", "Bar.swift")) {
                $0 <<< "public class Qux<T, U> { private let x = 1 }"
            }
            try localFileSystem.writeFileContents(packageRoot.appending(components: "Sources", "Baz", "Baz.swift")) {
                $0 <<< "public enum Baz {case a, b, c }"
            }
            try localFileSystem.writeFileContents(packageRoot.appending(components: "Sources", "Qux", "Qux.swift")) {
                $0 <<< "public class Qux<T, U> { private let x = 1 }"
            }
            XCTAssertThrowsError(try execute(["diagnose-api-breaking-changes", "1.2.3", "--products", "One", "--targets", "Bar"],
                                             packagePath: packageRoot)) { error in
                guard case SwiftPMProductError.executionFailure(error: _, output: let output, stderr: _) = error else {
                    XCTFail("Unexpected error")
                    return
                }

                XCTAssertTrue(output.contains("1 breaking change detected in Foo"))
                XCTAssertTrue(output.contains("💔 API breakage: struct Foo has been removed"))
                XCTAssertTrue(output.contains("1 breaking change detected in Bar"))
                XCTAssertTrue(output.contains("💔 API breakage: func bar() has been removed"))

                XCTAssertFalse(output.contains("1 breaking change detected in Baz"))
                XCTAssertFalse(output.contains("💔 API breakage: enumelement Baz.b has been added as a new enum case"))
                XCTAssertFalse(output.contains("2 breaking changes detected in Qux"))
                XCTAssertFalse(output.contains("💔 API breakage: class Qux has generic signature change from <T> to <T, U>"))
                XCTAssertFalse(output.contains("💔 API breakage: var Qux.x has been removed"))
            }

            // Diff a target which didn't have a baseline generated as part of the first invocation
            XCTAssertThrowsError(try execute(["diagnose-api-breaking-changes", "1.2.3", "--targets", "Baz"],
                                             packagePath: packageRoot)) { error in
                guard case SwiftPMProductError.executionFailure(error: _, output: let output, stderr: _) = error else {
                    XCTFail("Unexpected error")
                    return
                }

                XCTAssertTrue(output.contains("1 breaking change detected in Baz"))
                XCTAssertTrue(output.contains("💔 API breakage: enumelement Baz.b has been added as a new enum case"))

                XCTAssertFalse(output.contains("1 breaking change detected in Foo"))
                XCTAssertFalse(output.contains("💔 API breakage: struct Foo has been removed"))
                XCTAssertFalse(output.contains("1 breaking change detected in Bar"))
                XCTAssertFalse(output.contains("💔 API breakage: func bar() has been removed"))
                XCTAssertFalse(output.contains("2 breaking changes detected in Qux"))
                XCTAssertFalse(output.contains("💔 API breakage: class Qux has generic signature change from <T> to <T, U>"))
                XCTAssertFalse(output.contains("💔 API breakage: var Qux.x has been removed"))
            }

            // Test diagnostics
            XCTAssertThrowsError(try execute(["diagnose-api-breaking-changes", "1.2.3", "--targets", "NotATarget", "Exec",
                                              "--products", "NotAProduct", "Exec"],
                                             packagePath: packageRoot)) { error in
                guard case SwiftPMProductError.executionFailure(error: _, output: _, stderr: let stderr) = error else {
                    XCTFail("Unexpected error")
                    return
                }

                XCTAssertTrue(stderr.contains("error: no such product 'NotAProduct'"))
                XCTAssertTrue(stderr.contains("error: no such target 'NotATarget'"))
                XCTAssertTrue(stderr.contains("'Exec' is not a library product"))
                XCTAssertTrue(stderr.contains("'Exec' is not a library target"))
            }
        }
    }

    func testAPIDiffOfModuleWithCDependency() throws {
        try skipIfApiDigesterUnsupported()
        fixture(name: "Miscellaneous/APIDiff/") { prefix in
            let packageRoot = prefix.appending(component: "CTargetDep")
            // Overwrite the existing decl.
            try localFileSystem.writeFileContents(packageRoot.appending(components: "Sources", "Bar", "Bar.swift")) {
                $0 <<< """
                import Foo

                public func bar() -> String {
                    foo()
                    return "hello, world!"
                }
                """
            }
            XCTAssertThrowsError(try execute(["diagnose-api-breaking-changes", "1.2.3"], packagePath: packageRoot)) { error in
                guard case SwiftPMProductError.executionFailure(error: _, output: let output, stderr: _) = error else {
                    XCTFail("Unexpected error")
                    return
                }
                XCTAssertTrue(output.contains("1 breaking change detected in Bar"))
                XCTAssertTrue(output.contains("💔 API breakage: func bar() has return type change from Swift.Int to Swift.String"))
            }

            // Report an error if we explicitly ask to diff a C-family target
            XCTAssertThrowsError(try execute(["diagnose-api-breaking-changes", "1.2.3", "--targets", "Foo"], packagePath: packageRoot)) { error in
                guard case SwiftPMProductError.executionFailure(error: _, output: _, stderr: let stderr) = error else {
                    XCTFail("Unexpected error")
                    return
                }

                XCTAssertTrue(stderr.contains("error: 'Foo' is not a Swift language target"))
            }
        }
    }

    func testNoBreakingChanges() throws {
        try skipIfApiDigesterUnsupported()
        fixture(name: "Miscellaneous/APIDiff/") { prefix in
            let packageRoot = prefix.appending(component: "Bar")
            // Introduce an API-compatible change
            try localFileSystem.writeFileContents(packageRoot.appending(components: "Sources", "Baz", "Baz.swift")) {
                $0 <<< "public func bar() -> Int { 100 }"
            }
            let (output, _) = try execute(["diagnose-api-breaking-changes", "1.2.3"], packagePath: packageRoot)
            XCTAssertTrue(output.contains("No breaking changes detected in Baz"))
            XCTAssertTrue(output.contains("No breaking changes detected in Qux"))
        }
    }

    func testAPIDiffAfterAddingNewTarget() throws {
        try skipIfApiDigesterUnsupported()
        fixture(name: "Miscellaneous/APIDiff/") { prefix in
            let packageRoot = prefix.appending(component: "Bar")
            try localFileSystem.createDirectory(packageRoot.appending(components: "Sources", "Foo"))
            try localFileSystem.writeFileContents(packageRoot.appending(components: "Sources", "Foo", "Foo.swift")) {
                $0 <<< "public let foo = \"All new module!\""
            }
            try localFileSystem.writeFileContents(packageRoot.appending(component: "Package.swift")) {
                $0 <<< """
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
            }
            let (output, _) = try execute(["diagnose-api-breaking-changes", "1.2.3"], packagePath: packageRoot)
            XCTAssertTrue(output.contains("No breaking changes detected in Baz"))
            XCTAssertTrue(output.contains("No breaking changes detected in Qux"))
            XCTAssertTrue(output.contains("Skipping Foo because it does not exist in the baseline"))
        }
    }

    func testBadTreeish() throws {
        try skipIfApiDigesterUnsupported()
        fixture(name: "Miscellaneous/APIDiff/") { prefix in
            let packageRoot = prefix.appending(component: "Foo")
            XCTAssertThrowsError(try execute(["diagnose-api-breaking-changes", "7.8.9"], packagePath: packageRoot)) { error in
                guard case SwiftPMProductError.executionFailure(error: _, output: _, stderr: let stderr) = error else {
                    XCTFail("Unexpected error")
                    return
                }
                XCTAssertTrue(stderr.contains("error: Couldn’t get revision"))
            }
        }
    }

    func testBranchUpdate() throws {
        try skipIfApiDigesterUnsupported()
        try withTemporaryDirectory { baselineDir in
            fixture(name: "Miscellaneous/APIDiff/") { prefix in
                let packageRoot = prefix.appending(component: "Foo")
                let repo = GitRepository(path: packageRoot)
                try repo.checkout(newBranch: "feature")
                // Overwrite the existing decl.
                try localFileSystem.writeFileContents(packageRoot.appending(component: "Foo.swift")) {
                    $0 <<< "public let foo = 42"
                }
                try repo.stage(file: "Foo.swift")
                try repo.commit(message: "Add foo")
                XCTAssertThrowsError(try execute(["diagnose-api-breaking-changes", "main", "--baseline-dir", baselineDir.pathString],
                                                 packagePath: packageRoot)) { error in
                    guard case SwiftPMProductError.executionFailure(error: _, output: let output, stderr: _) = error else {
                        XCTFail("Unexpected error")
                        return
                    }
                    XCTAssertTrue(output.contains("1 breaking change detected in Foo"))
                    XCTAssertTrue(output.contains("💔 API breakage: func foo() has been removed"))
                }

                // Update `main` and ensure the baseline is regenerated.
                try repo.checkout(revision: .init(identifier: "main"))
                try localFileSystem.writeFileContents(packageRoot.appending(component: "Foo.swift")) {
                    $0 <<< "public let foo = 42"
                }
                try repo.stage(file: "Foo.swift")
                try repo.commit(message: "Add foo")
                try repo.checkout(revision: .init(identifier: "feature"))
                let (output, _) = try execute(["diagnose-api-breaking-changes", "main", "--baseline-dir", baselineDir.pathString],
                                              packagePath: packageRoot)
                XCTAssertTrue(output.contains("No breaking changes detected in Foo"))
            }
        }
    }

    func testBaselineDirOverride() throws {
        try skipIfApiDigesterUnsupported()
        fixture(name: "Miscellaneous/APIDiff/") { prefix in
            let packageRoot = prefix.appending(component: "Foo")
            // Overwrite the existing decl.
            try localFileSystem.writeFileContents(packageRoot.appending(component: "Foo.swift")) {
                $0 <<< "public let foo = 42"
            }

            let baselineDir = prefix.appending(component: "Baselines")
            let repo = GitRepository(path: packageRoot)
            let revision = try repo.resolveRevision(identifier: "1.2.3")

            XCTAssertThrowsError(try execute(["diagnose-api-breaking-changes", "1.2.3",
                                              "--baseline-dir", baselineDir.pathString],
                                             packagePath: packageRoot)) { error in
                guard case SwiftPMProductError.executionFailure(error: _, output: let output, stderr: _) = error else {
                    XCTFail("Unexpected error")
                    return
                }
                XCTAssertTrue(output.contains("1 breaking change detected in Foo"))
                XCTAssertTrue(output.contains("💔 API breakage: func foo() has been removed"))
                XCTAssertTrue(localFileSystem.exists(baselineDir.appending(components: revision.identifier, "Foo.json")))
            }
        }
    }

    func testRegenerateBaseline() throws {
       try skipIfApiDigesterUnsupported()
        fixture(name: "Miscellaneous/APIDiff/") { prefix in
            let packageRoot = prefix.appending(component: "Foo")
            // Overwrite the existing decl.
            try localFileSystem.writeFileContents(packageRoot.appending(component: "Foo.swift")) {
                $0 <<< "public let foo = 42"
            }

            let repo = GitRepository(path: packageRoot)
            let revision = try repo.resolveRevision(identifier: "1.2.3")

            let baselineDir = prefix.appending(component: "Baselines")
            let fooBaselinePath = baselineDir.appending(components: revision.identifier, "Foo.json")

            try localFileSystem.createDirectory(fooBaselinePath.parentDirectory, recursive: true)
            try localFileSystem.writeFileContents(fooBaselinePath) {
                $0 <<< "Old Baseline"
            }

            XCTAssertThrowsError(try execute(["diagnose-api-breaking-changes", "1.2.3",
                                              "--baseline-dir", baselineDir.pathString,
                                              "--regenerate-baseline"],
                                             packagePath: packageRoot)) { error in
                guard case SwiftPMProductError.executionFailure(error: _, output: let output, stderr: _) = error else {
                    XCTFail("Unexpected error")
                    return
                }
                XCTAssertTrue(output.contains("1 breaking change detected in Foo"))
                XCTAssertTrue(output.contains("💔 API breakage: func foo() has been removed"))
                XCTAssertTrue(localFileSystem.exists(fooBaselinePath))
                XCTAssertNotEqual((try! localFileSystem.readFileContents(fooBaselinePath)).description, "Old Baseline")
            }
        }
    }

    func testOldName() throws {
        XCTAssertThrowsError(try execute(["experimental-api-diff", "1.2.3", "--regenerate-baseline"],
                                         packagePath: nil)) { error in
            guard case SwiftPMProductError.executionFailure(error: _, output: let output, stderr: _) = error else {
                XCTFail("Unexpected error")
                return
            }
            XCTAssertTrue(output.contains("`swift package experimental-api-diff` has been renamed to `swift package diagnose-api-breaking-changes`"))
        }
    }
}
