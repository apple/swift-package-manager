/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import XCTest

import PackageGraph
import PackageLoading
import PackageModel
import SourceControl
import SPMBuildCore
import TSCBasic
import TSCUtility
import Workspace
import Basics

import SPMTestSupport

final class WorkspaceTests: XCTestCase {
    func testBasics() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Bar"]),
                        MockTarget(name: "Bar", dependencies: ["Baz"]),
                        MockTarget(name: "BarTests", dependencies: ["Bar"], type: .test),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo", "Bar"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Baz", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Baz",
                    targets: [
                        MockTarget(name: "Baz"),
                    ],
                    products: [
                        MockProduct(name: "Baz", targets: ["Baz"]),
                    ],
                    versions: ["1.0.0", "1.5.0"]
                ),
                MockPackage(
                    name: "Quix",
                    targets: [
                        MockTarget(name: "Quix"),
                    ],
                    products: [
                        MockProduct(name: "Quix", targets: ["Quix"]),
                    ],
                    versions: ["1.0.0", "1.2.0"]
                ),
            ]
        )

        let deps: [MockDependency] = [
            .init(name: "Quix", requirement: .upToNextMajor(from: "1.0.0"), products: .specific(["Quix"])),
            .init(name: "Baz", requirement: .exact("1.0.0"), products: .specific(["Baz"])),
        ]
        workspace.checkPackageGraph(roots: ["Foo"], deps: deps) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Foo")
                result.check(packages: "Baz", "Foo", "Quix")
                result.check(targets: "Bar", "Baz", "Foo", "Quix")
                result.check(testModules: "BarTests")
                result.checkTarget("Foo") { result in result.check(dependencies: "Bar") }
                result.checkTarget("Bar") { result in result.check(dependencies: "Baz") }
                result.checkTarget("BarTests") { result in result.check(dependencies: "Bar") }
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "baz", at: .checkout(.version("1.0.0")))
            result.check(dependency: "quix", at: .checkout(.version("1.2.0")))
        }

        // Check the load-package callbacks.
        XCTAssertTrue(workspace.delegate.events.contains("will load manifest for root package: /tmp/ws/roots/Foo"))
        XCTAssertTrue(workspace.delegate.events.contains("did load manifest for root package: /tmp/ws/roots/Foo"))

        XCTAssertTrue(workspace.delegate.events.contains("will load manifest for remote package: /tmp/ws/pkgs/Quix"))
        XCTAssertTrue(workspace.delegate.events.contains("did load manifest for remote package: /tmp/ws/pkgs/Quix"))
        XCTAssertTrue(workspace.delegate.events.contains("will load manifest for remote package: /tmp/ws/pkgs/Baz"))
        XCTAssertTrue(workspace.delegate.events.contains("did load manifest for remote package: /tmp/ws/pkgs/Baz"))

        // Close and reopen workspace.
        workspace.closeWorkspace()
        workspace.checkManagedDependencies { result in
            result.check(dependency: "baz", at: .checkout(.version("1.0.0")))
            result.check(dependency: "quix", at: .checkout(.version("1.2.0")))
        }

        let stateFile = workspace.createWorkspace().state.path

        // Remove state file and check we can get the state back automatically.
        try fs.removeFileTree(stateFile)

        workspace.checkPackageGraph(roots: ["Foo"], deps: deps) { _, _ in }
        XCTAssertTrue(fs.exists(stateFile))

        // Remove state file and check we get back to a clean state.
        try fs.removeFileTree(workspace.createWorkspace().state.path)
        workspace.closeWorkspace()
        workspace.checkManagedDependencies { result in
            result.checkEmpty()
        }
    }

    func testInterpreterFlags() throws {
        let fs = localFileSystem
        try testWithTemporaryDirectory { path in
            let foo = path.appending(component: "foo")

            func createWorkspace(withManifest manifest: (OutputByteStream) -> Void) throws -> Workspace {
                try fs.writeFileContents(foo.appending(component: "Package.swift")) {
                    manifest($0)
                }

                let manifestLoader = ManifestLoader(manifestResources: Resources.default)

                let sandbox = path.appending(component: "ws")
                return Workspace(
                    dataPath: sandbox.appending(component: ".build"),
                    editablesPath: sandbox.appending(component: "edits"),
                    pinsFile: sandbox.appending(component: "Package.resolved"),
                    manifestLoader: manifestLoader,
                    delegate: MockWorkspaceDelegate(),
                    cachePath: fs.swiftPMCacheDirectory.appending(component: "repositories"),
                    verbosity: TSCUtility.verbosity
                )
            }

            do {
                let ws = try createWorkspace {
                    $0 <<<
                        """
                        // swift-tools-version:4.0
                        import PackageDescription
                        let package = Package(
                            name: "foo"
                        )
                        """
                }

                XCTAssertMatch(ws.interpreterFlags(for: foo), [.equal("-swift-version"), .equal("4")])
            }

            do {
                let ws = try createWorkspace {
                    $0 <<<
                        """
                        // swift-tools-version:3.1
                        import PackageDescription
                        let package = Package(
                            name: "foo"
                        )
                        """
                }

                XCTAssertEqual(ws.interpreterFlags(for: foo), [])
            }
        }
    }

    func testMultipleRootPackages() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Baz"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Baz", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar", dependencies: ["Baz"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Baz", requirement: .exact("1.0.1")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Baz",
                    targets: [
                        MockTarget(name: "Baz"),
                    ],
                    products: [
                        MockProduct(name: "Baz", targets: ["Baz"]),
                    ],
                    versions: ["1.0.0", "1.0.1", "1.0.3", "1.0.5", "1.0.8"]
                ),
            ]
        )

        workspace.checkPackageGraph(roots: ["Foo", "Bar"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Bar", "Foo")
                result.check(packages: "Bar", "Baz", "Foo")
                result.checkTarget("Foo") { result in result.check(dependencies: "Baz") }
                result.checkTarget("Bar") { result in result.check(dependencies: "Baz") }
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "baz", at: .checkout(.version("1.0.1")))
        }
    }

    func testRootPackagesOverride() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Baz"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: nil, path: "bazzz", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    toolsVersion: .v5
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: []
                ),
                MockPackage(
                    name: "Baz",
                    path: "Overridden/bazzz",
                    targets: [
                        MockTarget(name: "Baz"),
                    ],
                    products: [
                        MockProduct(name: "Baz", targets: ["Baz"]),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Baz",
                    path: "bazzz",
                    targets: [
                        MockTarget(name: "Baz"),
                    ],
                    products: [
                        MockProduct(name: "Baz", targets: ["Baz"]),
                    ],
                    versions: ["1.0.0", "1.0.1", "1.0.3", "1.0.5", "1.0.8"]
                ),
            ]
        )

        workspace.checkPackageGraph(roots: ["Foo", "Bar", "Overridden/bazzz"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Bar", "Foo", "Baz")
                result.check(packages: "Bar", "Baz", "Foo")
                result.checkTarget("Foo") { result in result.check(dependencies: "Baz") }
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
    }

    func testDependencyRefsAreIteratedInStableOrder() throws {
        // This graph has two references to Bar, one with .git suffix and one without.
        // The test ensures that we use the URL which appears first (i.e. the one with .git suffix).

        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Bar"]),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0"]
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        let dependencies: [PackageDependencyDescription] = [
            .init(
                name: nil,
                url: workspace.packagesDir.appending(component: "Foo").pathString,
                requirement: .upToNextMajor(from: "1.0.0"),
                productFilter: .specific(["Foo"])
            ),
            .init(
                name: nil,
                url: workspace.packagesDir.appending(component: "Bar").pathString + ".git",
                requirement: .upToNextMajor(from: "1.0.0"),
                productFilter: .specific(["Bar"])
            ),
        ]

        // Add entry for the Bar.git package.
        do {
            let barKey = MockManifestLoader.Key(url: "/tmp/ws/pkgs/Bar", version: "1.0.0")
            let barGitKey = MockManifestLoader.Key(url: "/tmp/ws/pkgs/Bar.git", version: "1.0.0")
            let manifest = workspace.manifestLoader.manifests[barKey]!
            workspace.manifestLoader.manifests[barGitKey] = manifest.with(url: "/tmp/ws/pkgs/Bar.git")
        }

        workspace.checkPackageGraph(dependencies: dependencies) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(packages: "Bar", "Foo")
                result.check(targets: "Bar", "Foo")
                result.checkTarget("Foo") { result in result.check(dependencies: "Bar") }
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }
        workspace.checkResolved { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", url: "/tmp/ws/pkgs/Bar.git")
        }
    }

    func testDuplicateRootPackages() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: []),
                    ],
                    products: [],
                    dependencies: []
                ),
                MockPackage(
                    name: "Foo",
                    path: "Nested/Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: []),
                    ],
                    products: [],
                    dependencies: []
                ),
            ],
            packages: []
        )

        workspace.checkPackageGraph(roots: ["Foo", "Nested/Foo"]) { _, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .equal("found multiple top-level packages named 'Foo'"), behavior: .error)
            }
        }
    }

    /// Test that the explicit name given to a package is not used as its identity.
    func testExplicitPackageNameIsNotUsedAsPackageIdentity() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "FooPackage",
                    path: "foo-package",
                    targets: [
                        MockTarget(name: "FooTarget", dependencies: [.product(name: "BarProduct", package: "BarPackage")]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "BarPackage", path: "bar-package", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    toolsVersion: .v5
                ),
                MockPackage(
                    name: "BarPackage",
                    path: "bar-package",
                    targets: [
                        MockTarget(name: "BarTarget"),
                    ],
                    products: [
                        MockProduct(name: "BarProduct", targets: ["BarTarget"]),
                    ],
                    versions: ["1.0.0", "1.0.1"]
                ),
            ],
            packages: [
                MockPackage(
                    name: "BarPackage",
                    path: "bar-package",
                    targets: [
                        MockTarget(name: "BarTarget"),
                    ],
                    products: [
                        MockProduct(name: "BarProduct", targets: ["BarTarget"]),
                    ],
                    versions: ["1.0.0", "1.0.1"]
                ),
            ]
        )

        workspace.checkPackageGraph(roots: ["foo-package", "bar-package"], dependencies: [PackageDependencyDescription(url: "/tmp/ws/pkgs/bar-package", requirement: .upToNextMajor(from: "1.0.0"), productFilter: .everything)]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "FooPackage", "BarPackage")
                result.check(packages: "FooPackage", "BarPackage")
                result.checkTarget("FooTarget") { result in result.check(dependencies: "BarProduct") }
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
    }

    /// Test that the remote repository is not resolved when a root package with same name is already present.
    func testRootAsDependency1() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["BazAB"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Baz", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    toolsVersion: .v5
                ),
                MockPackage(
                    name: "Baz",
                    targets: [
                        MockTarget(name: "BazA"),
                        MockTarget(name: "BazB"),
                    ],
                    products: [
                        MockProduct(name: "BazAB", targets: ["BazA", "BazB"]),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Baz",
                    targets: [
                        MockTarget(name: "Baz"),
                    ],
                    products: [
                        MockProduct(name: "Baz", targets: ["Baz"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        workspace.checkPackageGraph(roots: ["Foo", "Baz"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Baz", "Foo")
                result.check(packages: "Baz", "Foo")
                result.check(targets: "BazA", "BazB", "Foo")
                result.checkTarget("Foo") { result in result.check(dependencies: "BazAB") }
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(notPresent: "baz")
        }
        XCTAssertNoMatch(workspace.delegate.events, [.equal("fetching repo: /tmp/ws/pkgs/Baz")])
        XCTAssertNoMatch(workspace.delegate.events, [.equal("will resolve dependencies")])
    }

    /// Test that a root package can be used as a dependency when the remote version was resolved previously.
    func testRootAsDependency2() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Baz"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Baz", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
                MockPackage(
                    name: "Baz",
                    targets: [
                        MockTarget(name: "BazA"),
                        MockTarget(name: "BazB"),
                    ],
                    products: [
                        MockProduct(name: "Baz", targets: ["BazA", "BazB"]),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Baz",
                    targets: [
                        MockTarget(name: "Baz"),
                    ],
                    products: [
                        MockProduct(name: "Baz", targets: ["Baz"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        // Load only Foo right now so Baz is loaded from remote.
        workspace.checkPackageGraph(roots: ["Foo"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Foo")
                result.check(packages: "Baz", "Foo")
                result.check(targets: "Baz", "Foo")
                result.checkTarget("Foo") { result in result.check(dependencies: "Baz") }
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "baz", at: .checkout(.version("1.0.0")))
        }
        XCTAssertMatch(workspace.delegate.events, [.equal("fetching repo: /tmp/ws/pkgs/Baz")])
        XCTAssertMatch(workspace.delegate.events, [.equal("will resolve dependencies")])

        // Now load with Baz as a root package.
        workspace.delegate.clear()
        workspace.checkPackageGraph(roots: ["Foo", "Baz"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Baz", "Foo")
                result.check(packages: "Baz", "Foo")
                result.check(targets: "BazA", "BazB", "Foo")
                result.checkTarget("Foo") { result in result.check(dependencies: "Baz") }
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(notPresent: "baz")
        }
        XCTAssertNoMatch(workspace.delegate.events, [.equal("fetching repo: /tmp/ws/pkgs/Baz")])
        XCTAssertNoMatch(workspace.delegate.events, [.equal("will resolve dependencies")])
        XCTAssertMatch(workspace.delegate.events, [.equal("removing repo: /tmp/ws/pkgs/Baz")])
    }

    func testGraphRootDependencies() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Bar"]),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0"]
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        let dependencies: [PackageDependencyDescription] = [
            .init(
                url: workspace.packagesDir.appending(component: "Bar").pathString,
                requirement: .upToNextMajor(from: "1.0.0"),
                productFilter: .specific(["Bar"])
            ),
            .init(
                url: "file://\(workspace.packagesDir.appending(component: "Foo").pathString)/",
                requirement: .upToNextMajor(from: "1.0.0"),
                productFilter: .specific(["Foo"])
            ),
        ]

        workspace.checkPackageGraph(dependencies: dependencies) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(packages: "Bar", "Foo")
                result.check(targets: "Bar", "Foo")
                result.checkTarget("Foo") { result in result.check(dependencies: "Bar") }
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }
    }

    func testCanResolveWithIncompatiblePins() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [],
            packages: [
                MockPackage(
                    name: "A",
                    targets: [
                        MockTarget(name: "A", dependencies: ["AA"]),
                    ],
                    products: [
                        MockProduct(name: "A", targets: ["A"]),
                    ],
                    dependencies: [
                        MockDependency(name: "AA", requirement: .exact("1.0.0")),
                    ],
                    versions: ["1.0.0"]
                ),
                MockPackage(
                    name: "A",
                    targets: [
                        MockTarget(name: "A", dependencies: ["AA"]),
                    ],
                    products: [
                        MockProduct(name: "A", targets: ["A"]),
                    ],
                    dependencies: [
                        MockDependency(name: "AA", requirement: .exact("2.0.0")),
                    ],
                    versions: ["1.0.1"]
                ),
                MockPackage(
                    name: "AA",
                    targets: [
                        MockTarget(name: "AA"),
                    ],
                    products: [
                        MockProduct(name: "AA", targets: ["AA"]),
                    ],
                    versions: ["1.0.0", "2.0.0"]
                ),
            ]
        )

        // Resolve when A = 1.0.0.
        do {
            let deps: [MockDependency] = [
                .init(name: "A", requirement: .exact("1.0.0"), products: .specific(["A"])),
            ]
            workspace.checkPackageGraph(deps: deps) { graph, diagnostics in
                PackageGraphTester(graph) { result in
                    result.check(packages: "A", "AA")
                    result.check(targets: "A", "AA")
                    result.checkTarget("A") { result in result.check(dependencies: "AA") }
                }
                XCTAssertNoDiagnostics(diagnostics)
            }
            workspace.checkManagedDependencies { result in
                result.check(dependency: "a", at: .checkout(.version("1.0.0")))
                result.check(dependency: "aa", at: .checkout(.version("1.0.0")))
            }
            workspace.checkResolved { result in
                result.check(dependency: "a", at: .checkout(.version("1.0.0")))
                result.check(dependency: "aa", at: .checkout(.version("1.0.0")))
            }
        }

        // Resolve when A = 1.0.1.
        do {
            let deps: [MockDependency] = [
                .init(name: "A", requirement: .exact("1.0.1"), products: .specific(["A"])),
            ]
            workspace.checkPackageGraph(deps: deps) { graph, diagnostics in
                PackageGraphTester(graph) { result in
                    result.checkTarget("A") { result in result.check(dependencies: "AA") }
                }
                XCTAssertNoDiagnostics(diagnostics)
            }
            workspace.checkManagedDependencies { result in
                result.check(dependency: "a", at: .checkout(.version("1.0.1")))
                result.check(dependency: "aa", at: .checkout(.version("2.0.0")))
            }
            workspace.checkResolved { result in
                result.check(dependency: "a", at: .checkout(.version("1.0.1")))
                result.check(dependency: "aa", at: .checkout(.version("2.0.0")))
            }
            XCTAssertMatch(workspace.delegate.events, [.equal("updating repo: /tmp/ws/pkgs/A")])
            XCTAssertMatch(workspace.delegate.events, [.equal("updating repo: /tmp/ws/pkgs/AA")])
            XCTAssertEqual(workspace.delegate.events.filter { $0.hasPrefix("updating repo") }.count, 2)
        }
    }

    func testResolverCanHaveError() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [],
            packages: [
                MockPackage(
                    name: "A",
                    targets: [
                        MockTarget(name: "A", dependencies: ["AA"]),
                    ],
                    products: [
                        MockProduct(name: "A", targets: ["A"]),
                    ],
                    dependencies: [
                        MockDependency(name: "AA", requirement: .exact("1.0.0")),
                    ],
                    versions: ["1.0.0"]
                ),
                MockPackage(
                    name: "B",
                    targets: [
                        MockTarget(name: "B", dependencies: ["AA"]),
                    ],
                    products: [
                        MockProduct(name: "B", targets: ["B"]),
                    ],
                    dependencies: [
                        MockDependency(name: "AA", requirement: .exact("2.0.0")),
                    ],
                    versions: ["1.0.0"]
                ),
                MockPackage(
                    name: "AA",
                    targets: [
                        MockTarget(name: "AA"),
                    ],
                    products: [
                        MockProduct(name: "AA", targets: ["AA"]),
                    ],
                    versions: ["1.0.0", "2.0.0"]
                ),
            ]
        )

        let deps: [MockDependency] = [
            .init(name: "A", requirement: .exact("1.0.0"), products: .specific(["A"])),
            .init(name: "B", requirement: .exact("1.0.0"), products: .specific(["B"])),
        ]
        workspace.checkPackageGraph(deps: deps) { _, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .contains("Dependencies could not be resolved"), behavior: .error)
            }
        }
        // There should be no extra fetches.
        XCTAssertNoMatch(workspace.delegate.events, [.contains("updating repo")])
    }

    func testPrecomputeResolution_empty() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()
        let bPath = RelativePath("B")
        let v1_5 = CheckoutState(revision: Revision(identifier: "hello"), version: "1.0.5")
        let v2 = CheckoutState(revision: Revision(identifier: "hello"), version: "2.0.0")

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "A",
                    targets: [MockTarget(name: "A")],
                    products: []
                ),
            ],
            packages: []
        )

        let bRepo = RepositorySpecifier(url: workspace.urlForPackage(withName: "B"))
        let cRepo = RepositorySpecifier(url: workspace.urlForPackage(withName: "C"))
        let bRef = PackageReference(identity: PackageIdentity(url: bRepo.url), path: bRepo.url)
        let cRef = PackageReference(identity: PackageIdentity(url: cRepo.url), path: cRepo.url)

        try workspace.set(
            pins: [bRef: v1_5, cRef: v2],
            managedDependencies: [
                ManagedDependency(packageRef: bRef, subpath: bPath, checkoutState: v1_5)
                    .editedDependency(subpath: bPath, unmanagedPath: nil),
            ]
        )

        try workspace.checkPrecomputeResolution { result in
            XCTAssertEqual(result.diagnostics.hasErrors, false)
            XCTAssertEqual(result.result.isRequired, false)
        }
    }

    func testPrecomputeResolution_newPackages() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()
        let bPath = RelativePath("B")
        let v1Requirement: MockDependency.Requirement = .range("1.0.0" ..< "2.0.0")
        let v1 = CheckoutState(revision: Revision(identifier: "hello"), version: "1.0.0")

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "A",
                    targets: [MockTarget(name: "A")],
                    products: [],
                    dependencies: [
                        MockDependency(name: "B", requirement: v1Requirement),
                        MockDependency(name: "C", requirement: v1Requirement),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "B",
                    targets: [MockTarget(name: "B")],
                    products: [MockProduct(name: "B", targets: ["B"])],
                    versions: ["1.0.0"]
                ),
                MockPackage(
                    name: "C",
                    targets: [MockTarget(name: "C")],
                    products: [MockProduct(name: "C", targets: ["C"])],
                    versions: ["1.0.0"]
                ),
            ]
        )

        let bRepo = RepositorySpecifier(url: workspace.urlForPackage(withName: "B"))
        let cRepo = RepositorySpecifier(url: workspace.urlForPackage(withName: "C"))
        let bRef = PackageReference(identity: PackageIdentity(url: bRepo.url), path: bRepo.url)
        let cRef = PackageReference(identity: PackageIdentity(url: cRepo.url), path: cRepo.url)

        try workspace.set(
            pins: [bRef: v1],
            managedDependencies: [
                ManagedDependency(packageRef: bRef, subpath: bPath, checkoutState: v1),
            ]
        )

        try workspace.checkPrecomputeResolution { result in
            XCTAssertEqual(result.diagnostics.hasErrors, false)
            XCTAssertEqual(result.result, .required(reason: .newPackages(packages: [cRef])))
        }
    }

    func testPrecomputeResolution_requirementChange_versionToBranch() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()
        let bPath = RelativePath("B")
        let cPath = RelativePath("C")
        let v1Requirement: MockDependency.Requirement = .range("1.0.0" ..< "2.0.0")
        let branchRequirement: MockDependency.Requirement = .branch("master")
        let v1_5 = CheckoutState(revision: Revision(identifier: "hello"), version: "1.0.5")

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "A",
                    targets: [MockTarget(name: "A")],
                    products: [],
                    dependencies: [
                        MockDependency(name: "B", requirement: v1Requirement),
                        MockDependency(name: "C", requirement: branchRequirement),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "B",
                    targets: [MockTarget(name: "B")],
                    products: [MockProduct(name: "B", targets: ["B"])],
                    versions: [nil, "1.0.0", "1.0.5", "2.0.0"]
                ),
                MockPackage(
                    name: "C",
                    targets: [MockTarget(name: "C")],
                    products: [MockProduct(name: "C", targets: ["C"])],
                    versions: [nil, "1.0.0", "1.0.5", "2.0.0"]
                ),
            ]
        )

        let bRepo = RepositorySpecifier(url: workspace.urlForPackage(withName: "B"))
        let cRepo = RepositorySpecifier(url: workspace.urlForPackage(withName: "C"))
        let bRef = PackageReference(identity: PackageIdentity(url: bRepo.url), path: bRepo.url)
        let cRef = PackageReference(identity: PackageIdentity(url: cRepo.url), path: cRepo.url)

        try workspace.set(
            pins: [bRef: v1_5, cRef: v1_5],
            managedDependencies: [
                ManagedDependency(packageRef: bRef, subpath: bPath, checkoutState: v1_5),
                ManagedDependency(packageRef: cRef, subpath: cPath, checkoutState: v1_5),
            ]
        )

        try workspace.checkPrecomputeResolution { result in
            XCTAssertEqual(result.diagnostics.hasErrors, false)
            XCTAssertEqual(result.result, .required(reason: .packageRequirementChange(
                package: cRef,
                state: .checkout(v1_5),
                requirement: .revision("master")
            )))
        }
    }

    func testPrecomputeResolution_requirementChange_versionToRevision() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()
        let cPath = RelativePath("C")
        let v1_5 = CheckoutState(revision: Revision(identifier: "hello"), version: "1.0.5")

        let testWorkspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "A",
                    targets: [MockTarget(name: "A")],
                    products: [],
                    dependencies: [
                        MockDependency(name: "C", requirement: .revision("hello")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "C",
                    targets: [MockTarget(name: "C")],
                    products: [MockProduct(name: "C", targets: ["C"])],
                    versions: [nil, "1.0.0", "1.0.5", "2.0.0"]
                ),
            ]
        )

        let cRepo = RepositorySpecifier(url: testWorkspace.urlForPackage(withName: "C"))
        let cRef = PackageReference(identity: PackageIdentity(url: cRepo.url), path: cRepo.url)

        try testWorkspace.set(
            pins: [cRef: v1_5],
            managedDependencies: [
                ManagedDependency(packageRef: cRef, subpath: cPath, checkoutState: v1_5),
            ]
        )

        try testWorkspace.checkPrecomputeResolution { result in
            XCTAssertEqual(result.diagnostics.hasErrors, false)
            XCTAssertEqual(result.result, .required(reason: .packageRequirementChange(
                package: cRef,
                state: .checkout(v1_5),
                requirement: .revision("hello")
            )))
        }
    }

    func testPrecomputeResolution_requirementChange_localToBranch() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()
        let bPath = RelativePath("B")
        let v1Requirement: MockDependency.Requirement = .range("1.0.0" ..< "2.0.0")
        let masterRequirement: MockDependency.Requirement = .branch("master")
        let v1_5 = CheckoutState(revision: Revision(identifier: "hello"), version: "1.0.5")

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "A",
                    targets: [MockTarget(name: "A")],
                    products: [],
                    dependencies: [
                        MockDependency(name: "B", requirement: v1Requirement),
                        MockDependency(name: "C", requirement: masterRequirement),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "B",
                    targets: [MockTarget(name: "B")],
                    products: [MockProduct(name: "B", targets: ["B"])],
                    versions: [nil, "1.0.0", "1.0.5", "2.0.0"]
                ),
                MockPackage(
                    name: "C",
                    targets: [MockTarget(name: "C")],
                    products: [MockProduct(name: "C", targets: ["C"])],
                    versions: [nil, "1.0.0", "1.0.5", "2.0.0"]
                ),
            ]
        )

        let bRepo = RepositorySpecifier(url: workspace.urlForPackage(withName: "B"))
        let cRepo = RepositorySpecifier(url: workspace.urlForPackage(withName: "C"))
        let bRef = PackageReference(identity: PackageIdentity(url: bRepo.url), path: bRepo.url)
        let cRef = PackageReference(identity: PackageIdentity(url: cRepo.url), path: cRepo.url)

        try workspace.set(
            pins: [bRef: v1_5],
            managedDependencies: [
                ManagedDependency(packageRef: bRef, subpath: bPath, checkoutState: v1_5),
                ManagedDependency.local(packageRef: cRef),
            ]
        )

        try workspace.checkPrecomputeResolution { result in
            XCTAssertEqual(result.diagnostics.hasErrors, false)
            XCTAssertEqual(result.result, .required(reason: .packageRequirementChange(
                package: cRef,
                state: .local,
                requirement: .revision("master")
            )))
        }
    }

    func testPrecomputeResolution_requirementChange_versionToLocal() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()
        let bPath = RelativePath("B")
        let cPath = RelativePath("C")
        let v1Requirement: MockDependency.Requirement = .range("1.0.0" ..< "2.0.0")
        let localRequirement: MockDependency.Requirement = .localPackage
        let v1_5 = CheckoutState(revision: Revision(identifier: "hello"), version: "1.0.5")

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "A",
                    targets: [MockTarget(name: "A")],
                    products: [],
                    dependencies: [
                        MockDependency(name: "B", requirement: v1Requirement),
                        MockDependency(name: "C", requirement: localRequirement),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "B",
                    targets: [MockTarget(name: "B")],
                    products: [MockProduct(name: "B", targets: ["B"])],
                    versions: [nil, "1.0.0", "1.0.5", "2.0.0"]
                ),
                MockPackage(
                    name: "C",
                    targets: [MockTarget(name: "C")],
                    products: [MockProduct(name: "C", targets: ["C"])],
                    versions: [nil, "1.0.0", "1.0.5", "2.0.0"]
                ),
            ]
        )

        let bRepo = RepositorySpecifier(url: workspace.urlForPackage(withName: "B"))
        let cRepo = RepositorySpecifier(url: workspace.urlForPackage(withName: "C"))
        let bRef = PackageReference(identity: PackageIdentity(url: bRepo.url), path: bRepo.url)
        let cRef = PackageReference(identity: PackageIdentity(url: cRepo.url), path: cRepo.url)

        try workspace.set(
            pins: [bRef: v1_5, cRef: v1_5],
            managedDependencies: [
                ManagedDependency(packageRef: bRef, subpath: bPath, checkoutState: v1_5),
                ManagedDependency(packageRef: cRef, subpath: cPath, checkoutState: v1_5),
            ]
        )

        try workspace.checkPrecomputeResolution { result in
            XCTAssertEqual(result.diagnostics.hasErrors, false)
            XCTAssertEqual(result.result, .required(reason: .packageRequirementChange(
                package: cRef,
                state: .checkout(v1_5),
                requirement: .unversioned
            )))
        }
    }

    func testPrecomputeResolution_requirementChange_branchToLocal() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()
        let bPath = RelativePath("B")
        let cPath = RelativePath("C")
        let v1Requirement: MockDependency.Requirement = .range("1.0.0" ..< "2.0.0")
        let localRequirement: MockDependency.Requirement = .localPackage
        let v1_5 = CheckoutState(revision: Revision(identifier: "hello"), version: "1.0.5")
        let master = CheckoutState(revision: Revision(identifier: "master"), branch: "master")

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "A",
                    targets: [MockTarget(name: "A")],
                    products: [],
                    dependencies: [
                        MockDependency(name: "B", requirement: v1Requirement),
                        MockDependency(name: "C", requirement: localRequirement),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "B",
                    targets: [MockTarget(name: "B")],
                    products: [MockProduct(name: "B", targets: ["B"])],
                    versions: [nil, "1.0.0", "1.0.5", "2.0.0"]
                ),
                MockPackage(
                    name: "C",
                    targets: [MockTarget(name: "C")],
                    products: [MockProduct(name: "C", targets: ["C"])],
                    versions: [nil, "1.0.0", "1.0.5", "2.0.0"]
                ),
            ]
        )

        let bRepo = RepositorySpecifier(url: workspace.urlForPackage(withName: "B"))
        let cRepo = RepositorySpecifier(url: workspace.urlForPackage(withName: "C"))
        let bRef = PackageReference(identity: PackageIdentity(url: bRepo.url), path: bRepo.url)
        let cRef = PackageReference(identity: PackageIdentity(url: cRepo.url), path: cRepo.url)

        try workspace.set(
            pins: [bRef: v1_5, cRef: master],
            managedDependencies: [
                ManagedDependency(packageRef: bRef, subpath: bPath, checkoutState: v1_5),
                ManagedDependency(packageRef: cRef, subpath: cPath, checkoutState: master),
            ]
        )

        try workspace.checkPrecomputeResolution { result in
            XCTAssertEqual(result.diagnostics.hasErrors, false)
            XCTAssertEqual(result.result, .required(reason: .packageRequirementChange(
                package: cRef,
                state: .checkout(master),
                requirement: .unversioned
            )))
        }
    }

    func testPrecomputeResolution_other() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()
        let bPath = RelativePath("B")
        let cPath = RelativePath("C")
        let v1Requirement: MockDependency.Requirement = .range("1.0.0" ..< "2.0.0")
        let v2Requirement: MockDependency.Requirement = .range("2.0.0" ..< "3.0.0")
        let v1_5 = CheckoutState(revision: Revision(identifier: "hello"), version: "1.0.5")

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "A",
                    targets: [MockTarget(name: "A")],
                    products: [],
                    dependencies: [
                        MockDependency(name: "B", requirement: v1Requirement),
                        MockDependency(name: "C", requirement: v2Requirement),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "B",
                    targets: [MockTarget(name: "B")],
                    products: [MockProduct(name: "B", targets: ["B"])],
                    versions: [nil, "1.0.0", "1.0.5", "2.0.0"]
                ),
                MockPackage(
                    name: "C",
                    targets: [MockTarget(name: "C")],
                    products: [MockProduct(name: "C", targets: ["C"])],
                    versions: [nil, "1.0.0", "1.0.5", "2.0.0"]
                ),
            ]
        )

        let bRepo = RepositorySpecifier(url: workspace.urlForPackage(withName: "B"))
        let cRepo = RepositorySpecifier(url: workspace.urlForPackage(withName: "C"))
        let bRef = PackageReference(identity: PackageIdentity(url: bRepo.url), path: bRepo.url)
        let cRef = PackageReference(identity: PackageIdentity(url: cRepo.url), path: cRepo.url)

        try workspace.set(
            pins: [bRef: v1_5, cRef: v1_5],
            managedDependencies: [
                ManagedDependency(packageRef: bRef, subpath: bPath, checkoutState: v1_5),
                ManagedDependency(packageRef: cRef, subpath: cPath, checkoutState: v1_5),
            ]
        )

        try workspace.checkPrecomputeResolution { result in
            XCTAssertEqual(result.diagnostics.hasErrors, false)
            XCTAssertEqual(result.result, .required(reason: .other))
        }
    }

    func testPrecomputeResolution_notRequired() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()
        let bPath = RelativePath("B")
        let cPath = RelativePath("C")
        let v1Requirement: MockDependency.Requirement = .range("1.0.0" ..< "2.0.0")
        let v2Requirement: MockDependency.Requirement = .range("2.0.0" ..< "3.0.0")
        let v1_5 = CheckoutState(revision: Revision(identifier: "hello"), version: "1.0.5")
        let v2 = CheckoutState(revision: Revision(identifier: "hello"), version: "2.0.0")

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "A",
                    targets: [MockTarget(name: "A")],
                    products: [],
                    dependencies: [
                        MockDependency(name: "B", requirement: v1Requirement),
                        MockDependency(name: "C", requirement: v2Requirement),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "B",
                    targets: [MockTarget(name: "B")],
                    products: [MockProduct(name: "B", targets: ["B"])],
                    versions: [nil, "1.0.0", "1.0.5", "2.0.0"]
                ),
                MockPackage(
                    name: "C",
                    targets: [MockTarget(name: "C")],
                    products: [MockProduct(name: "C", targets: ["C"])],
                    versions: [nil, "1.0.0", "1.0.5", "2.0.0"]
                ),
            ]
        )

        let bRepo = RepositorySpecifier(url: workspace.urlForPackage(withName: "B"))
        let cRepo = RepositorySpecifier(url: workspace.urlForPackage(withName: "C"))
        let bRef = PackageReference(identity: PackageIdentity(url: bRepo.url), path: bRepo.url)
        let cRef = PackageReference(identity: PackageIdentity(url: cRepo.url), path: cRepo.url)

        try workspace.set(
            pins: [bRef: v1_5, cRef: v2],
            managedDependencies: [
                ManagedDependency(packageRef: bRef, subpath: bPath, checkoutState: v1_5),
                ManagedDependency(packageRef: cRef, subpath: cPath, checkoutState: v2),
            ]
        )

        try workspace.checkPrecomputeResolution { result in
            XCTAssertEqual(result.diagnostics.hasErrors, false)
            XCTAssertEqual(result.result.isRequired, false)
        }
    }

    func testLoadingRootManifests() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                .genericPackage1(named: "A"),
                .genericPackage1(named: "B"),
                .genericPackage1(named: "C"),
            ],
            packages: []
        )

        workspace.checkPackageGraph(roots: ["A", "B", "C"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(packages: "A", "B", "C")
                result.check(targets: "A", "B", "C")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
    }

    func testUpdate() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo"]),
                    ],
                    products: [
                        MockProduct(name: "Root", targets: ["Root"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Bar"]),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0"]
                ),
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.5.0"]
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        // Do an intial run, capping at Foo at 1.0.0.
        let deps: [MockDependency] = [
            .init(name: "Foo", requirement: .exact("1.0.0"), products: .specific(["Foo"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Bar", "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }

        // Run update.
        workspace.checkUpdate(roots: ["Root"]) { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkPackageGraph(roots: ["Root"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.5.0")))
        }
        XCTAssertMatch(workspace.delegate.events, [.equal("removing repo: /tmp/ws/pkgs/Bar")])

        // Run update again.
        // Ensure that up-to-date delegate is called when there is nothing to update.
        workspace.checkUpdate(roots: ["Root"]) { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        XCTAssertMatch(workspace.delegate.events, [.equal("Everything is already up-to-date")])
    }

    func testUpdateDryRun() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo"]),
                    ],
                    products: [
                        MockProduct(name: "Root", targets: ["Root"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.0.0"]
                ),
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.5.0"]
                ),
            ]
        )

        // Do an intial run, capping at Foo at 1.0.0.
        let deps: [MockDependency] = [
            .init(name: "Foo", requirement: .exact("1.0.0"), products: .specific(["Foo"])),
        ]

        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
        }

        // Run update.
        workspace.checkUpdateDryRun(roots: ["Root"]) { changes, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
            #if ENABLE_TARGET_BASED_DEPENDENCY_RESOLUTION
            let stateChange = Workspace.PackageStateChange.updated(.init(requirement: .version(Version("1.5.0")), products: .specific(["Foo"])))
            #else
            let stateChange = Workspace.PackageStateChange.updated(.init(requirement: .version(Version("1.5.0")), products: .everything))
            #endif

            let path = AbsolutePath("/tmp/ws/pkgs/Foo")
            let expectedChange = (
                PackageReference(identity: PackageIdentity(path: path), path: path.pathString),
                stateChange
            )
            guard let change = changes?.first, changes?.count == 1 else {
                XCTFail()
                return
            }
            XCTAssertEqual(expectedChange, change)
        }
        workspace.checkPackageGraph(roots: ["Root"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
        }
    }

    func testPartialUpdate() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo"]),
                    ],
                    products: [
                        MockProduct(name: "Root", targets: ["Root"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Bar"]),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.5.0"]
                ),
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Bar"]),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .upToNextMinor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0"]
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["1.0.0", "1.2.0"]
                ),
            ]
        )

        // Do an intial run, capping at Foo at 1.0.0.
        let deps: [MockDependency] = [
            .init(name: "Foo", requirement: .exact("1.0.0"), products: .specific(["Foo"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }

        // Run partial updates.
        //
        // Try to update just Bar. This shouldn't do anything because Bar can't be updated due
        // to Foo's requirements.
        workspace.checkUpdate(roots: ["Root"], packages: ["Bar"]) { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }

        // Try to update just Foo. This should update Foo but not Bar.
        workspace.checkUpdate(roots: ["Root"], packages: ["Foo"]) { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.5.0")))
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }

        // Run full update.
        workspace.checkUpdate(roots: ["Root"]) { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.5.0")))
            result.check(dependency: "bar", at: .checkout(.version("1.2.0")))
        }
    }

    func testCleanAndReset() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo"]),
                    ],
                    products: [
                        MockProduct(name: "Root", targets: ["Root"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        // Load package graph.
        workspace.checkPackageGraph(roots: ["Root"]) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }

        // Drop a build artifact in data directory.
        let ws = workspace.createWorkspace()
        let buildArtifact = ws.dataPath.appending(component: "test.o")
        try fs.writeFileContents(buildArtifact, bytes: "Hi")

        // Sanity checks.
        XCTAssert(fs.exists(buildArtifact))
        XCTAssert(fs.exists(ws.checkoutsPath))

        // Check clean.
        workspace.checkClean { diagnostics in
            // Only the build artifact should be removed.
            XCTAssertFalse(fs.exists(buildArtifact))
            XCTAssert(fs.exists(ws.checkoutsPath))
            XCTAssert(fs.exists(ws.dataPath))

            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
        }

        // Add the build artifact again.
        try fs.writeFileContents(buildArtifact, bytes: "Hi")

        // Check reset.
        workspace.checkReset { diagnostics in
            // Only the build artifact should be removed.
            XCTAssertFalse(fs.exists(buildArtifact))
            XCTAssertFalse(fs.exists(ws.checkoutsPath))
            XCTAssertFalse(fs.exists(ws.dataPath))

            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.checkEmpty()
        }
    }

    func testDependencyManifestLoading() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root1",
                    targets: [
                        MockTarget(name: "Root1", dependencies: ["Foo"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
                MockPackage(
                    name: "Root2",
                    targets: [
                        MockTarget(name: "Root2", dependencies: ["Bar"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                .genericPackage1(named: "Foo"),
                .genericPackage1(named: "Bar"),
            ]
        )

        // Check that we can compute missing dependencies.
        try workspace.loadDependencyManifests(roots: ["Root1", "Root2"]) { manifests, diagnostics in
            XCTAssertEqual(manifests.missingPackageURLs().map { $0.path }.sorted(), ["/tmp/ws/pkgs/Bar", "/tmp/ws/pkgs/Foo"])
            XCTAssertNoDiagnostics(diagnostics)
        }

        // Load the graph with one root.
        workspace.checkPackageGraph(roots: ["Root1"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(packages: "Foo", "Root1")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }

        // Check that we compute the correct missing dependencies.
        try workspace.loadDependencyManifests(roots: ["Root1", "Root2"]) { manifests, diagnostics in
            XCTAssertEqual(manifests.missingPackageURLs().map { $0.path }.sorted(), ["/tmp/ws/pkgs/Bar"])
            XCTAssertNoDiagnostics(diagnostics)
        }

        // Load the graph with both roots.
        workspace.checkPackageGraph(roots: ["Root1", "Root2"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(packages: "Bar", "Foo", "Root1", "Root2")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }

        // Check that we compute the correct missing dependencies.
        try workspace.loadDependencyManifests(roots: ["Root1", "Root2"]) { manifests, diagnostics in
            XCTAssertEqual(manifests.missingPackageURLs().map { $0.path }.sorted(), [])
            XCTAssertNoDiagnostics(diagnostics)
        }
    }

    func testDependencyManifestsOrder() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root1",
                    targets: [
                        MockTarget(name: "Root1", dependencies: ["Foo", "Bar", "Baz", "Bam"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                        MockDependency(name: "Baz", requirement: .upToNextMajor(from: "1.0.0")),
                        MockDependency(name: "Bam", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Bar", "Baz"]),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                        MockDependency(name: "Baz", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0"]
                ),
                .genericPackage1(named: "Bar"),
                MockPackage(
                    name: "Baz",
                    targets: [
                        MockTarget(name: "Baz", dependencies: ["Bam"]),
                    ],
                    products: [
                        MockProduct(name: "Baz", targets: ["Baz"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Bam", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0"]
                ),
                .genericPackage1(named: "Bam"),
            ]
        )

        workspace.checkPackageGraph(roots: ["Root1"]) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }

        try workspace.loadDependencyManifests(roots: ["Root1"]) { manifests, diagnostics in
            // Ensure that the order of the manifests is stable.
            XCTAssertEqual(manifests.allDependencyManifests().map { $0.name }, ["Foo", "Baz", "Bam", "Bar"])
            XCTAssertNoDiagnostics(diagnostics)
        }
    }

    func testBranchAndRevision() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .branch("develop")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["develop"]
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["boo"]
                ),
            ]
        )

        // Get some revision identifier of Bar.
        let bar = RepositorySpecifier(url: "/tmp/ws/pkgs/Bar")
        let barRevision = workspace.repoProvider.specifierMap[bar]!.revisions[0]

        // We request Bar via revision.
        let deps: [MockDependency] = [
            .init(name: "Bar", requirement: .revision(barRevision), products: .specific(["Bar"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Bar", "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.branch("develop")))
            result.check(dependency: "bar", at: .checkout(.revision(barRevision)))
        }
    }

    func testResolve() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.0.0", "1.2.3"]
                ),
            ]
        )

        // Load initial version.
        workspace.checkPackageGraph(roots: ["Root"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.2.3")))
        }
        workspace.checkResolved { result in
            result.check(dependency: "foo", at: .checkout(.version("1.2.3")))
        }

        // Resolve to an older version.
        workspace.checkResolve(pkg: "Foo", roots: ["Root"], version: "1.0.0") { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
        }
        workspace.checkResolved { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
        }

        // Check failure.
        workspace.checkResolve(pkg: "Foo", roots: ["Root"], version: "1.3.0") { diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .contains("'Foo' 1.3.0"), behavior: .error)
            }
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
        }
        workspace.checkResolved { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
        }
    }

    func testDeletedCheckoutDirectory() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                .genericPackage1(named: "Foo"),
            ]
        )

        // Load the graph.
        workspace.checkPackageGraph(roots: ["Root"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }

        try fs.removeFileTree(workspace.createWorkspace().checkoutsPath)

        workspace.checkPackageGraph(roots: ["Root"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Foo", "Root")
            }
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .contains("dependency 'Foo' is missing; cloning again"), behavior: .warning)
            }
        }
    }

    func testMinimumRequiredToolsVersionInDependencyResolution() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.0.0"],
                    toolsVersion: .v3
                ),
            ]
        )

        #if ENABLE_TARGET_BASED_DEPENDENCY_RESOLUTION
        workspace.checkPackageGraph(roots: ["Root"]) { _, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .contains("Foo[Foo] 1.0.0..<2.0.0"), behavior: .error)
            }
        }
        #endif
    }

    func testToolsVersionRootPackages() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: []
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: []
                ),
                MockPackage(
                    name: "Baz",
                    targets: [
                        MockTarget(name: "Baz"),
                    ],
                    products: []
                ),
            ],
            packages: [],
            toolsVersion: .v4
        )

        let roots = workspace.rootPaths(for: ["Foo", "Bar", "Baz"]).map { $0.appending(component: "Package.swift") }

        try fs.writeFileContents(roots[0], bytes: "// swift-tools-version:4.0")
        try fs.writeFileContents(roots[1], bytes: "// swift-tools-version:4.1.0")
        try fs.writeFileContents(roots[2], bytes: "// swift-tools-version:3.1")

        workspace.checkPackageGraph(roots: ["Foo"]) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkPackageGraph(roots: ["Bar"]) { _, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .equal("package at '/tmp/ws/roots/Bar' is using Swift tools version 4.1.0 but the installed version is 4.0.0"), behavior: .error, location: "/tmp/ws/roots/Bar")
            }
        }
        workspace.checkPackageGraph(roots: ["Foo", "Bar"]) { _, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .equal("package at '/tmp/ws/roots/Bar' is using Swift tools version 4.1.0 but the installed version is 4.0.0"), behavior: .error, location: "/tmp/ws/roots/Bar")
            }
        }
        workspace.checkPackageGraph(roots: ["Baz"]) { _, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .equal("package at '/tmp/ws/roots/Baz' is using Swift tools version 3.1.0 which is no longer supported; consider using '// swift-tools-version:4.0' to specify the current tools version"), behavior: .error, location: "/tmp/ws/roots/Baz")
            }
        }
    }

    func testEditDependency() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo", "Bar"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.0.0", nil]
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["1.0.0", nil]
                ),
            ]
        )

        // Load the graph.
        workspace.checkPackageGraph(roots: ["Root"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Bar", "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }

        // Edit foo.
        let fooPath = workspace.createWorkspace().editablesPath.appending(component: "Foo")
        workspace.checkEdit(packageName: "Foo") { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .edited(nil))
        }
        XCTAssertTrue(fs.exists(fooPath))

        try workspace.loadDependencyManifests(roots: ["Root"]) { manifests, diagnostics in
            let editedPackages = manifests.editedPackagesConstraints()
            XCTAssertEqual(editedPackages.map { $0.identifier.path }, [fooPath.pathString])
            XCTAssertNoDiagnostics(diagnostics)
        }

        // Try re-editing foo.
        workspace.checkEdit(packageName: "Foo") { diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .equal("dependency 'Foo' already in edit mode"), behavior: .error)
            }
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .edited(nil))
        }

        // Try editing bar at bad revision.
        workspace.checkEdit(packageName: "Bar", revision: Revision(identifier: "dev")) { diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .equal("revision 'dev' does not exist"), behavior: .error)
            }
        }

        // Edit bar at a custom path and branch (ToT).
        let barPath = AbsolutePath("/tmp/ws/custom/bar")
        workspace.checkEdit(packageName: "Bar", path: barPath, checkoutBranch: "dev") { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "bar", at: .edited(barPath))
        }
        let barRepo = try workspace.repoProvider.openCheckout(at: barPath) as! InMemoryGitRepository
        XCTAssert(barRepo.revisions.contains("dev"))

        // Test unediting.
        workspace.checkUnedit(packageName: "Foo", roots: ["Root"]) { diagnostics in
            XCTAssertFalse(fs.exists(fooPath))
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkUnedit(packageName: "Bar", roots: ["Root"]) { diagnostics in
            XCTAssert(fs.exists(barPath))
            XCTAssertNoDiagnostics(diagnostics)
        }
    }

    func testMissingEditCanRestoreOriginalCheckout() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.0.0", nil]
                ),
            ]
        )

        // Load the graph.
        workspace.checkPackageGraph(roots: ["Root"]) { _, _ in }

        // Edit foo.
        let fooPath = workspace.createWorkspace().editablesPath.appending(component: "Foo")
        workspace.checkEdit(packageName: "Foo") { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .edited(nil))
        }
        XCTAssertTrue(fs.exists(fooPath))

        // Remove the edited package.
        try fs.removeFileTree(fooPath)
        workspace.checkPackageGraph(roots: ["Root"]) { _, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .equal("dependency 'Foo' was being edited but is missing; falling back to original checkout"), behavior: .warning)
            }
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
        }
    }

    func testCanUneditRemovedDependencies() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.0.0", nil]
                ),
            ]
        )

        let deps: [MockDependency] = [
            .init(name: "Foo", requirement: .upToNextMajor(from: "1.0.0"), products: .specific(["Foo"])),
        ]
        let ws = workspace.createWorkspace()

        // Load the graph and edit foo.
        workspace.checkPackageGraph(deps: deps) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(packages: "Foo")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkEdit(packageName: "Foo") { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .edited(nil))
        }

        // Remove foo.
        workspace.checkUpdate { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        XCTAssertMatch(workspace.delegate.events, [.equal("removing repo: /tmp/ws/pkgs/Foo")])
        workspace.checkPackageGraph(deps: []) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }

        // There should still be an entry for `foo`, which we can unedit.
        let editedDependency = ws.state.dependencies[forNameOrIdentity: "foo"]!
        XCTAssertNil(editedDependency.basedOn)
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .edited(nil))
        }

        // Unedit foo.
        workspace.checkUnedit(packageName: "Foo", roots: []) { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.checkEmpty()
        }
    }

    func testDependencyResolutionWithEdit() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo", "Bar"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.0.0", "1.2.0", "1.3.2"]
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["1.0.0", nil]
                ),
            ]
        )

        let deps: [MockDependency] = [
            .init(name: "Foo", requirement: .exact("1.0.0"), products: .specific(["Foo"])),
        ]
        // Load the graph.
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Bar", "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }

        // Edit bar.
        workspace.checkEdit(packageName: "Bar") { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .edited(nil))
        }
        workspace.checkResolved { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }

        // Add entry for the edited package.
        do {
            let barKey = MockManifestLoader.Key(url: "/tmp/ws/pkgs/Bar")
            let editedBarKey = MockManifestLoader.Key(url: "/tmp/ws/edits/Bar")
            let manifest = workspace.manifestLoader.manifests[barKey]!
            workspace.manifestLoader.manifests[editedBarKey] = manifest
        }

        // Now, resolve foo at a different version.
        workspace.checkResolve(pkg: "Foo", roots: ["Root"], version: "1.2.0") { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.2.0")))
            result.check(dependency: "bar", at: .edited(nil))
        }
        workspace.checkResolved { result in
            result.check(dependency: "foo", at: .checkout(.version("1.2.0")))
            result.check(notPresent: "bar")
        }

        // Try package update.
        workspace.checkUpdate(roots: ["Root"]) { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.3.2")))
            result.check(dependency: "bar", at: .edited(nil))
        }
        workspace.checkResolved { result in
            result.check(dependency: "foo", at: .checkout(.version("1.3.2")))
            result.check(notPresent: "bar")
        }

        // Unedit should get the Package.resolved entry back.
        workspace.checkUnedit(packageName: "bar", roots: ["Root"]) { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.3.2")))
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }
        workspace.checkResolved { result in
            result.check(dependency: "foo", at: .checkout(.version("1.3.2")))
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }
    }

    func testPrefetchingWithOverridenPackage() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.0.0"]
                ),
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Bar"]),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: [nil]
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        // Load the graph.
        workspace.checkPackageGraph(roots: ["Root"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
        }

        let deps: [MockDependency] = [
            .init(name: "Foo", requirement: .localPackage, products: .specific(["Foo"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Foo", "Bar", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .local)
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }
    }

    // Test that changing a particular dependency re-resolves the graph.
    func testChangeOneDependency() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Bar"]),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .exact("1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["1.0.0", "1.5.0"]
                ),
            ]
        )

        // Initial resolution.
        workspace.checkPackageGraph(roots: ["Foo"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Foo")
                result.check(packages: "Bar", "Foo")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }

        // Check that changing the requirement to 1.5.0 triggers re-resolution.
        //
        // FIXME: Find a cleaner way to change a dependency requirement.
        let fooKey = MockManifestLoader.Key(url: "/tmp/ws/roots/Foo")
        let manifest = workspace.manifestLoader.manifests[fooKey]!
        workspace.manifestLoader.manifests[fooKey] = Manifest(
            name: manifest.name,
            platforms: [],
            path: manifest.path,
            url: manifest.url,
            version: manifest.version,
            toolsVersion: manifest.toolsVersion,
            packageKind: .root,
            dependencies: [PackageDependencyDescription(url: manifest.dependencies[0].url, requirement: .exact("1.5.0"))],
            targets: manifest.targets
        )

        workspace.checkPackageGraph(roots: ["Foo"]) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "bar", at: .checkout(.version("1.5.0")))
        }
    }

    func testResolutionFailureWithEditedDependency() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.0.0", nil]
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["1.0.0", nil]
                ),
            ]
        )

        // Load the graph.
        workspace.checkPackageGraph(roots: ["Root"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkEdit(packageName: "Foo") { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .edited(nil))
        }
        workspace.checkResolved { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
        }

        // Add entry for the edited package.
        do {
            let fooKey = MockManifestLoader.Key(url: "/tmp/ws/pkgs/Foo")
            let editedFooKey = MockManifestLoader.Key(url: "/tmp/ws/edits/Foo")
            let manifest = workspace.manifestLoader.manifests[fooKey]!
            workspace.manifestLoader.manifests[editedFooKey] = manifest
        }

        // Try resolving a bad graph.
        let deps: [MockDependency] = [
            .init(name: "Bar", requirement: .exact("1.1.0"), products: .specific(["Bar"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { _, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .contains("'Bar' 1.1.0"), behavior: .error)
            }
        }
    }

    func testSkipUpdate() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo"]),
                    ],
                    products: [
                        MockProduct(name: "Root", targets: ["Root"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.5.0"]
                ),
            ],
            skipUpdate: true
        )

        // Run update and remove all events.
        workspace.checkUpdate(roots: ["Root"]) { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.delegate.clear()

        // Check we don't have updating Foo event.
        workspace.checkUpdate(roots: ["Root"]) { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
            XCTAssertMatch(workspace.delegate.events, ["Everything is already up-to-date"])
        }
    }

    func testLocalDependencyBasics() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Bar", "Baz"]),
                        MockTarget(name: "FooTests", dependencies: ["Foo"], type: .test),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .localPackage),
                        MockDependency(name: "Baz", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["1.0.0", "1.5.0", nil]
                ),
                MockPackage(
                    name: "Baz",
                    targets: [
                        MockTarget(name: "Baz", dependencies: ["Bar"]),
                    ],
                    products: [
                        MockProduct(name: "Baz", targets: ["Baz"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0", "1.5.0"]
                ),
            ]
        )

        workspace.checkPackageGraph(roots: ["Foo"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Foo")
                result.check(packages: "Bar", "Baz", "Foo")
                result.check(targets: "Bar", "Baz", "Foo")
                result.check(testModules: "FooTests")
                result.checkTarget("Baz") { result in result.check(dependencies: "Bar") }
                result.checkTarget("Foo") { result in result.check(dependencies: "Baz", "Bar") }
                result.checkTarget("FooTests") { result in result.check(dependencies: "Foo") }
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "baz", at: .checkout(.version("1.5.0")))
            result.check(dependency: "bar", at: .local)
        }

        // Test that its not possible to edit or resolve this package.
        workspace.checkEdit(packageName: "Bar") { diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .contains("local dependency 'Bar' can't be edited"), behavior: .error)
            }
        }
        workspace.checkResolve(pkg: "Bar", roots: ["Foo"], version: "1.0.0") { diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .contains("local dependency 'Bar' can't be edited"), behavior: .error)
            }
        }
    }

    func testLocalDependencyTransitive() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Bar"]),
                        MockTarget(name: "FooTests", dependencies: ["Foo"], type: .test),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar", dependencies: ["Baz"]),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Baz", requirement: .localPackage),
                    ],
                    versions: ["1.0.0", "1.5.0", nil]
                ),
                MockPackage(
                    name: "Baz",
                    targets: [
                        MockTarget(name: "Baz"),
                    ],
                    products: [
                        MockProduct(name: "Baz", targets: ["Baz"]),
                    ],
                    versions: ["1.0.0", "1.5.0", nil]
                ),
            ]
        )

        workspace.checkPackageGraph(roots: ["Foo"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Foo")
                result.check(packages: "Foo")
                result.check(targets: "Foo")
            }
            #if ENABLE_TARGET_BASED_DEPENDENCY_RESOLUTION
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .contains("Bar[Bar] {1.0.0..<1.5.0, 1.5.1..<2.0.0} is forbidden"), behavior: .error)
            }
            #endif
        }
    }

    func testLocalDependencyWithPackageUpdate() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Bar"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["1.0.0", "1.5.0", nil]
                ),
            ]
        )

        workspace.checkPackageGraph(roots: ["Foo"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Foo")
                result.check(packages: "Bar", "Foo")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "bar", at: .checkout(.version("1.5.0")))
        }

        // Override with local package and run update.
        let deps: [MockDependency] = [
            .init(name: "Bar", requirement: .localPackage, products: .specific(["Bar"])),
        ]
        workspace.checkUpdate(roots: ["Foo"], deps: deps) { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "bar", at: .local)
        }

        // Go back to the versioned state.
        workspace.checkUpdate(roots: ["Foo"]) { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "bar", at: .checkout(.version("1.5.0")))
        }
    }

    func testMissingLocalDependencyDiagnostic() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: []),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: nil, path: "Bar", requirement: .localPackage),
                    ]
                ),
            ],
            packages: [
            ]
        )

        workspace.checkPackageGraph(roots: ["Foo"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Foo")
                result.check(packages: "Foo")
                result.check(targets: "Foo")
            }
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .contains("the package at '/tmp/ws/pkgs/Bar' cannot be accessed (/tmp/ws/pkgs/Bar doesn't exist in file system"), behavior: .error)
            }
        }
    }

    func testRevisionVersionSwitch() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: []),
                    ],
                    products: [],
                    dependencies: []
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["develop", "1.0.0"]
                ),
            ]
        )

        // Test that switching between revision and version requirement works
        // without running swift package update.

        var deps: [MockDependency] = [
            .init(name: "Foo", requirement: .branch("develop"), products: .specific(["Foo"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.branch("develop")))
        }

        deps = [
            .init(name: "Foo", requirement: .upToNextMajor(from: "1.0.0"), products: .specific(["Foo"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
        }

        deps = [
            .init(name: "Foo", requirement: .branch("develop"), products: .specific(["Foo"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.branch("develop")))
        }
    }

    func testLocalVersionSwitch() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: []),
                    ],
                    products: [],
                    dependencies: []
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["develop", "1.0.0", nil]
                ),
            ]
        )

        // Test that switching between local and version requirement works
        // without running swift package update.

        var deps: [MockDependency] = [
            .init(name: "Foo", requirement: .localPackage, products: .specific(["Foo"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .local)
        }

        deps = [
            .init(name: "Foo", requirement: .upToNextMajor(from: "1.0.0"), products: .specific(["Foo"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
        }

        deps = [
            .init(name: "Foo", requirement: .localPackage, products: .specific(["Foo"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .local)
        }
    }

    func testLocalLocalSwitch() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: []),
                    ],
                    products: [],
                    dependencies: []
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: [nil]
                ),
                MockPackage(
                    name: "Foo",
                    path: "Foo2",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: [nil]
                ),
            ]
        )

        // Test that switching between two same local packages placed at
        // different locations works correctly.

        var deps: [MockDependency] = [
            .init(name: "Foo", requirement: .localPackage, products: .specific(["Foo"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .local)
        }

        deps = [
            .init(name: "Foo2", requirement: .localPackage, products: .specific(["Foo"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo2", at: .local)
        }
    }

    func testDependencySwitchWithSameIdentity() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: []),
                    ],
                    products: [],
                    dependencies: []
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: [nil]
                ),
                MockPackage(
                    name: "Foo",
                    path: "Nested/Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: [nil]
                ),
            ]
        )

        // Test that switching between two same local packages placed at
        // different locations works correctly.

        var deps: [MockDependency] = [
            .init(name: "Foo", requirement: .localPackage, products: .specific(["Foo"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .local)
        }
        do {
            let ws = workspace.createWorkspace()
            XCTAssertNotNil(ws.state.dependencies[forURL: "/tmp/ws/pkgs/Foo"])
        }

        deps = [
            .init(name: "Nested/Foo", requirement: .localPackage, products: .specific(["Foo"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .local)
        }
        do {
            let ws = workspace.createWorkspace()
            XCTAssertNotNil(ws.state.dependencies[forURL: "/tmp/ws/pkgs/Nested/Foo"])
        }
    }

    func testResolvedFileUpdate() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: []),
                    ],
                    products: [],
                    dependencies: []
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        let deps: [MockDependency] = [
            .init(name: "Foo", requirement: .upToNextMajor(from: "1.0.0"), products: .specific(["Foo"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
        }
        workspace.checkResolved { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
        }

        workspace.checkPackageGraph(roots: ["Root"], deps: []) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
        }
        workspace.checkResolved { result in
            result.check(notPresent: "foo")
        }
    }

    func testPackageMirror() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Dep"]),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Dep", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    toolsVersion: .v5
                ),
            ],
            packages: [
                MockPackage(
                    name: "Dep",
                    targets: [
                        MockTarget(name: "Dep", dependencies: ["Bar"]),
                    ],
                    products: [
                        MockProduct(name: "Dep", targets: ["Dep"]),
                    ],
                    dependencies: [
                        MockDependency(name: nil, path: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0", "1.5.0"],
                    toolsVersion: .v5
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["1.0.0", "1.5.0"]
                ),
                MockPackage(
                    name: "Baz",
                    targets: [
                        MockTarget(name: "Baz"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Baz"]),
                    ],
                    versions: ["1.0.0", "1.4.0"]
                ),
                MockPackage(
                    name: "Bam",
                    targets: [
                        MockTarget(name: "Bam"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bam"]),
                    ],
                    versions: ["1.0.0", "1.5.0"]
                ),
            ]
        )

        workspace.checkPackageGraph(roots: ["Foo"]) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Foo")
                result.check(packages: "Foo", "Dep", "Bar")
                result.check(targets: "Foo", "Dep", "Bar")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "Dep", at: .checkout(.version("1.5.0")))
            result.check(dependency: "Bar", at: .checkout(.version("1.5.0")))
            result.check(notPresent: "Baz")
        }

        workspace.config.mirrors.set(mirrorURL: workspace.packagesDir.appending(component: "Baz").pathString, forURL: workspace.packagesDir.appending(component: "Bar").pathString)
        workspace.config.mirrors.set(mirrorURL: workspace.packagesDir.appending(component: "Baz").pathString, forURL: workspace.packagesDir.appending(component: "Bam").pathString)
        try workspace.config.saveState()

        let deps: [MockDependency] = [
            .init(name: "Bam", requirement: .upToNextMajor(from: "1.0.0"), products: .specific(["Bar"])),
        ]

        workspace.checkPackageGraph(roots: ["Foo"], deps: deps) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Foo")
                result.check(packages: "Foo", "Dep", "Baz")
                result.check(targets: "Foo", "Dep", "Baz")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "Dep", at: .checkout(.version("1.5.0")))
            result.check(dependency: "Baz", at: .checkout(.version("1.4.0")))
            result.check(notPresent: "Bar")
            result.check(notPresent: "Bam")
        }
    }

    func testTransitiveDependencySwitchWithSameIdentity() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Bar"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar", dependencies: ["Foo"]),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0"]
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar", dependencies: ["Nested/Foo"]),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    dependencies: [
                        MockDependency(name: nil, path: "Nested/Foo", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.1.0"],
                    toolsVersion: .v5
                ),
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.0.0"]
                ),
                MockPackage(
                    name: "Foo",
                    path: "Nested/Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Nested/Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        // In this test, we get into a state where add an entry in the resolved
        // file for a transitive dependency whose URL is later changed to
        // something else, while keeping the same package identity.
        //
        // This is normally detected during pins validation before the
        // dependency resolution process even begins but if we're starting with
        // a clean slate, we don't even know about the correct urls of the
        // transitive dependencies. We will end up fetching the wrong
        // dependency as we prefetch the pins. If we get into this case, it
        // should kick off another dependency resolution operation which will
        // have enough information to remove the invalid pins of transitive
        // dependencies.

        var deps: [MockDependency] = [
            .init(name: "Bar", requirement: .exact("1.0.0"), products: .specific(["Bar"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Bar", "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }

        do {
            let ws = workspace.createWorkspace()
            XCTAssertNotNil(ws.state.dependencies[forURL: "/tmp/ws/pkgs/Foo"])
        }

        workspace.checkReset { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }

        deps = [
            .init(name: "Bar", requirement: .exact("1.1.0"), products: .specific(["Bar"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { graph, diagnostics in
            PackageGraphTester(graph) { result in
                result.check(roots: "Root")
                result.check(packages: "Bar", "Foo", "Root")
            }
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .checkout(.version("1.1.0")))
        }

        do {
            let ws = workspace.createWorkspace()
            XCTAssertNotNil(ws.state.dependencies[forURL: "/tmp/ws/pkgs/Nested/Foo"])
        }
    }

    func testForceResolveToResolvedVersions() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo", "Bar"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: ["1.0.0", "1.2.0", "1.3.2"]
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["1.0.0", "develop"]
                ),
            ]
        )

        // Load the initial graph.
        let deps: [MockDependency] = [
            .init(name: "Bar", requirement: .revision("develop"), products: .specific(["Bar"])),
        ]
        workspace.checkPackageGraph(roots: ["Root"], deps: deps) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.3.2")))
            result.check(dependency: "bar", at: .checkout(.branch("develop")))
        }
        workspace.checkResolved { result in
            result.check(dependency: "foo", at: .checkout(.version("1.3.2")))
            result.check(dependency: "bar", at: .checkout(.branch("develop")))
        }

        // Change pin of foo to something else.
        do {
            let ws = workspace.createWorkspace()
            let pinsStore = try ws.pinsStore.load()
            let fooPin = pinsStore.pins.first(where: { $0.packageRef.identity.description == "foo" })!

            let fooRepo = workspace.repoProvider.specifierMap[RepositorySpecifier(url: fooPin.packageRef.path)]!
            let revision = try fooRepo.resolveRevision(tag: "1.0.0")
            let newState = CheckoutState(revision: revision, version: "1.0.0")

            pinsStore.pin(packageRef: fooPin.packageRef, state: newState)
            try pinsStore.saveState()
        }

        // Check force resolve. This should produce an error because the resolved file is out-of-date.
        workspace.checkPackageGraph(roots: ["Root"], forceResolvedVersions: true) { _, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: "cannot update Package.resolved file because automatic resolution is disabled", checkContains: true, behavior: .error)
            }
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .checkout(.branch("develop")))
        }
        workspace.checkResolved { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .checkout(.branch("develop")))
        }

        // A normal resolution.
        workspace.checkPackageGraph(roots: ["Root"]) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }
        workspace.checkResolved { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }

        // This force resolution should succeed.
        workspace.checkPackageGraph(roots: ["Root"], forceResolvedVersions: true) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }
        workspace.checkResolved { result in
            result.check(dependency: "foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "bar", at: .checkout(.version("1.0.0")))
        }
    }

    func testForceResolveToResolvedVersionsLocalPackage() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .localPackage),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo"),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    versions: [nil]
                ),
            ]
        )

        workspace.checkPackageGraph(roots: ["Root"], forceResolvedVersions: true) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .local)
        }
    }

    func testSimpleAPI() throws {
        guard Resources.havePD4Runtime else { return }

        // This verifies that the simplest possible loading APIs are available for package clients.

        // This checkout of the SwiftPM package.
        let package = AbsolutePath(#file).parentDirectory.parentDirectory.parentDirectory

        // Clients must locate the corresponding “swiftc” exectuable themselves for now.
        // (This just uses the same one used by all the other tests.)
        let swiftCompiler = Resources.default.swiftCompiler

        // From here the API should be simple and straightforward:
        let diagnostics = DiagnosticsEngine()
        let manifest = try tsc_await {
            ManifestLoader.loadManifest(packagePath: package, swiftCompiler: swiftCompiler, swiftCompilerFlags: [], packageKind: .local, verbosity: TSCUtility.verbosity, on: .global(), completion: $0)
        }

        let loadedPackage = try tsc_await {
            PackageBuilder.loadPackage(packagePath: package, swiftCompiler: swiftCompiler, swiftCompilerFlags: [], xcTestMinimumDeploymentTargets: [:], diagnostics: diagnostics, verbosity: TSCUtility.verbosity, on: .global(), completion: $0)
        }

        let graph = try Workspace.loadGraph(
            packagePath: package, swiftCompiler: swiftCompiler, swiftCompilerFlags: [], diagnostics: diagnostics, verbosity: TSCUtility.verbosity
        )

        XCTAssertEqual(manifest.name, "SwiftPM")
        XCTAssertEqual(loadedPackage.name, "SwiftPM")
        XCTAssert(graph.reachableProducts.contains(where: { $0.name == "SwiftPM" }))
    }

    func testRevisionDepOnLocal() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .branch("develop")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Local"]),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Local", requirement: .localPackage),
                    ],
                    versions: ["develop"]
                ),
                MockPackage(
                    name: "Local",
                    targets: [
                        MockTarget(name: "Local"),
                    ],
                    products: [
                        MockProduct(name: "Local", targets: ["Local"]),
                    ],
                    versions: [nil]
                ),
            ]
        )

        workspace.checkPackageGraph(roots: ["Root"]) { _, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .equal("package 'Foo' is required using a revision-based requirement and it depends on local package 'Local', which is not supported"), behavior: .error)
            }
        }
    }

    func testRootPackagesOverrideBasenameMismatch() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Baz",
                    path: "Overridden/bazzz-master",
                    targets: [
                        MockTarget(name: "Baz"),
                    ],
                    products: [
                        MockProduct(name: "Baz", targets: ["Baz"]),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Baz",
                    path: "bazzz",
                    targets: [
                        MockTarget(name: "Baz"),
                    ],
                    products: [
                        MockProduct(name: "Baz", targets: ["Baz"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        let deps: [MockDependency] = [
            .init(name: "bazzz", requirement: .exact("1.0.0"), products: .specific(["Baz"])),
        ]

        workspace.checkPackageGraph(roots: ["Overridden/bazzz-master"], deps: deps) { _, diagnostics in
            DiagnosticsEngineTester(diagnostics, ignoreNotes: true) { result in
                result.check(diagnostic: .equal("unable to override package 'Baz' because its identity 'bazzz' doesn't match override's identity (directory name) 'bazzz-master'"), behavior: .error)
            }
        }
    }

    func testUnsafeFlags() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar", settings: [.init(tool: .swift, name: .unsafeFlags, value: ["-F", "/tmp"])]),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["1.0.0", nil]
                ),
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Bar", "Baz"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .localPackage),
                        MockDependency(name: "Baz", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar", settings: [.init(tool: .swift, name: .unsafeFlags, value: ["-F", "/tmp"])]),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["1.0.0", nil]
                ),
                MockPackage(
                    name: "Baz",
                    targets: [
                        MockTarget(name: "Baz", dependencies: ["Bar"], settings: [.init(tool: .swift, name: .unsafeFlags, value: ["-F", "/tmp"])]),
                    ],
                    products: [
                        MockProduct(name: "Baz", targets: ["Baz"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0", "1.5.0"]
                ),
            ]
        )

        // We should only see errors about use of unsafe flag in the version-based dependency.
        workspace.checkPackageGraph(roots: ["Foo", "Bar"]) { _, diagnostics in
            DiagnosticsEngineTester(diagnostics, ignoreNotes: true) { result in
                result.checkUnordered(diagnostic: .equal("the target 'Baz' in product 'Baz' contains unsafe build flags"), behavior: .error)
                result.checkUnordered(diagnostic: .equal("the target 'Bar' in product 'Baz' contains unsafe build flags"), behavior: .error)
            }
        }
    }

    func testEditDependencyHadOverridableConstraints() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo", "Baz"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .branch("master")),
                        MockDependency(name: "Baz", requirement: .upToNextMajor(from: "1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Bar"]),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .branch("master")),
                    ],
                    versions: ["master", nil]
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                    ],
                    products: [
                        MockProduct(name: "Bar", targets: ["Bar"]),
                    ],
                    versions: ["master", "1.0.0", nil]
                ),
                MockPackage(
                    name: "Baz",
                    targets: [
                        MockTarget(name: "Baz", dependencies: ["Bar"]),
                    ],
                    products: [
                        MockProduct(name: "Baz", targets: ["Baz"]),
                    ],
                    dependencies: [
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0", nil]
                ),
            ]
        )

        // Load the graph.
        workspace.checkPackageGraph(roots: ["Root"]) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .checkout(.branch("master")))
            result.check(dependency: "bar", at: .checkout(.branch("master")))
            result.check(dependency: "baz", at: .checkout(.version("1.0.0")))
        }

        // Edit foo.
        let fooPath = workspace.createWorkspace().editablesPath.appending(component: "Foo")
        workspace.checkEdit(packageName: "Foo") { diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .edited(nil))
        }
        XCTAssertTrue(fs.exists(fooPath))

        // Add entry for the edited package.
        do {
            let fooKey = MockManifestLoader.Key(url: "/tmp/ws/pkgs/Foo")
            let editedFooKey = MockManifestLoader.Key(url: "/tmp/ws/edits/Foo")
            let manifest = workspace.manifestLoader.manifests[fooKey]!
            workspace.manifestLoader.manifests[editedFooKey] = manifest
        }
        XCTAssertMatch(workspace.delegate.events, [.equal("will resolve dependencies")])
        workspace.delegate.clear()

        workspace.checkPackageGraph(roots: ["Root"]) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "foo", at: .edited(nil))
            result.check(dependency: "bar", at: .checkout(.branch("master")))
            result.check(dependency: "baz", at: .checkout(.version("1.0.0")))
        }
        XCTAssertNoMatch(workspace.delegate.events, [.equal("will resolve dependencies")])
    }

    func testTargetBasedDependency() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()
        
        let barProducts: [MockProduct]
        #if ENABLE_TARGET_BASED_DEPENDENCY_RESOLUTION
        barProducts = [MockProduct(name: "Bar", targets: ["Bar"]), MockProduct(name: "BarUnused", targets: ["BarUnused"])]
        #else
        // Whether a product is being used does not affect dependency resolution in this case, so we omit the unused product.
        barProducts = [MockProduct(name: "Bar", targets: ["Bar"])]
        #endif

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "Root", dependencies: ["Foo", "Bar"]),
                        MockTarget(name: "RootTests", dependencies: ["TestHelper1"], type: .test),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "Foo", requirement: .upToNextMajor(from: "1.0.0")),
                        MockDependency(name: "Bar", requirement: .upToNextMajor(from: "1.0.0")),
                        MockDependency(name: "TestHelper1", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    toolsVersion: .v5_2
                ),
            ],
            packages: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo1", dependencies: ["Foo2"]),
                        MockTarget(name: "Foo2", dependencies: ["Baz"]),
                        MockTarget(name: "FooTests", dependencies: ["TestHelper2"], type: .test),
                    ],
                    products: [
                        MockProduct(name: "Foo", targets: ["Foo1"]),
                    ],
                    dependencies: [
                        MockDependency(name: "TestHelper2", requirement: .upToNextMajor(from: "1.0.0")),
                        MockDependency(name: "Baz", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0"],
                    toolsVersion: .v5_2
                ),
                MockPackage(
                    name: "Bar",
                    targets: [
                        MockTarget(name: "Bar"),
                        MockTarget(name: "BarUnused", dependencies: ["Biz"]),
                        MockTarget(name: "BarTests", dependencies: ["TestHelper2"], type: .test),
                    ],
                    products: barProducts,
                    dependencies: [
                        MockDependency(name: "TestHelper2", requirement: .upToNextMajor(from: "1.0.0")),
                        MockDependency(name: "Biz", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0"],
                    toolsVersion: .v5_2
                ),
                MockPackage(
                    name: "Baz",
                    targets: [
                        MockTarget(name: "Baz"),
                    ],
                    products: [
                        MockProduct(name: "Baz", targets: ["Baz"]),
                    ],
                    versions: ["1.0.0"],
                    toolsVersion: .v5_2
                ),
                MockPackage(
                    name: "TestHelper1",
                    targets: [
                        MockTarget(name: "TestHelper1"),
                    ],
                    products: [
                        MockProduct(name: "TestHelper1", targets: ["TestHelper1"]),
                    ],
                    versions: ["1.0.0"],
                    toolsVersion: .v5_2
                ),
            ],
            toolsVersion: .v5_2,
            enablePubGrub: true
        )

        // Load the graph.
        workspace.checkPackageGraph(roots: ["Root"]) { _, diagnostics in
            XCTAssertNoDiagnostics(diagnostics)
        }
        workspace.checkManagedDependencies { result in
            result.check(dependency: "Foo", at: .checkout(.version("1.0.0")))
            result.check(dependency: "Bar", at: .checkout(.version("1.0.0")))
            result.check(dependency: "Baz", at: .checkout(.version("1.0.0")))
            result.check(dependency: "TestHelper1", at: .checkout(.version("1.0.0")))
            result.check(notPresent: "Biz")
            result.check(notPresent: "TestHelper2")
        }
    }

    func testChecksumForBinaryArtifact() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["Foo"]),
                    ],
                    products: []
                ),
            ],
            packages: []
        )

        let ws = workspace.createWorkspace()

        // Checks the valid case.
        do {
            let binaryPath = sandbox.appending(component: "binary.zip")
            try fs.writeFileContents(binaryPath, bytes: ByteString([0xAA, 0xBB, 0xCC]))

            let diagnostics = DiagnosticsEngine()
            let checksum = ws.checksum(forBinaryArtifactAt: binaryPath, diagnostics: diagnostics)
            XCTAssertTrue(!diagnostics.hasErrors)
            XCTAssertEqual(workspace.checksumAlgorithm.hashes.map { $0.contents }, [[0xAA, 0xBB, 0xCC]])
            XCTAssertEqual(checksum, "ccbbaa")
        }

        // Checks an unsupported extension.
        do {
            let unknownPath = sandbox.appending(component: "unknown")
            let diagnostics = DiagnosticsEngine()
            let checksum = ws.checksum(forBinaryArtifactAt: unknownPath, diagnostics: diagnostics)
            XCTAssertEqual(checksum, "")
            DiagnosticsEngineTester(diagnostics) { result in
                let expectedDiagnostic = "unexpected file type; supported extensions are: zip"
                result.check(diagnostic: .contains(expectedDiagnostic), behavior: .error)
            }
        }

        // Checks a supported extension that is not a file (does not exist).
        do {
            let unknownPath = sandbox.appending(component: "missingFile.zip")
            let diagnostics = DiagnosticsEngine()
            let checksum = ws.checksum(forBinaryArtifactAt: unknownPath, diagnostics: diagnostics)
            XCTAssertEqual(checksum, "")
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .contains("file not found at path: /tmp/ws/missingFile.zip"),
                             behavior: .error)
            }
        }

        // Checks a supported extension that is a directory instead of a file.
        do {
            let unknownPath = sandbox.appending(component: "aDirectory.zip")
            try fs.createDirectory(unknownPath)

            let diagnostics = DiagnosticsEngine()
            let checksum = ws.checksum(forBinaryArtifactAt: unknownPath, diagnostics: diagnostics)
            XCTAssertEqual(checksum, "")
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .contains("file not found at path: /tmp/ws/aDirectory.zip"),
                             behavior: .error)
            }
        }
    }

    func testArtifactDownload() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()
        var downloads: [MockDownloader.Download] = []

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            downloader: MockDownloader(fileSystem: fs, downloadFile: { url, destination, _, completion in
                let contents: [UInt8]
                switch url.lastPathComponent {
                case "a1.zip": contents = [0xA1]
                case "a2.zip": contents = [0xA2]
                case "a3.zip": contents = [0xA3]
                case "b.zip": contents = [0xB0]
                default:
                    XCTFail("unexpected url")
                    contents = []
                }

                try! fs.writeFileContents(
                    destination,
                    bytes: ByteString(contents),
                    atomically: true
                )

                downloads.append(MockDownloader.Download(url: url, destinationPath: destination))
                completion(.success(()))
            }),
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: [
                            "B",
                            .product(name: "A1", package: "A"),
                            .product(name: "A2", package: "A"),
                            .product(name: "A3", package: "A"),
                            .product(name: "A4", package: "A"),
                        ]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "A", requirement: .exact("1.0.0")),
                        MockDependency(name: "B", requirement: .exact("1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "A",
                    targets: [
                        MockTarget(
                            name: "A1",
                            type: .binary,
                            url: "https://a.com/a1.zip",
                            checksum: "a1"
                        ),
                        MockTarget(
                            name: "A2",
                            type: .binary,
                            url: "https://a.com/a2.zip",
                            checksum: "a2"
                        ),
                        MockTarget(
                            name: "A3",
                            type: .binary,
                            url: "https://a.com/a3.zip",
                            checksum: "a3"
                        ),
                        MockTarget(
                            name: "A4",
                            type: .binary,
                            path: "A4.xcframework"
                        ),
                    ],
                    products: [
                        MockProduct(name: "A1", targets: ["A1"]),
                        MockProduct(name: "A2", targets: ["A2"]),
                        MockProduct(name: "A3", targets: ["A3"]),
                        MockProduct(name: "A4", targets: ["A4"]),
                    ],
                    versions: ["1.0.0"]
                ),
                MockPackage(
                    name: "B",
                    targets: [
                        MockTarget(
                            name: "B",
                            type: .binary,
                            url: "https://b.com/b.zip",
                            checksum: "b0"
                        ),
                    ],
                    products: [
                        MockProduct(name: "B", targets: ["B"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        let a4FrameworkPath = workspace.packagesDir.appending(components: "A", "A4.xcframework")
        try fs.createDirectory(a4FrameworkPath, recursive: true)

        try [("A", "A1.xcframework"), ("A", "A2.xcframework"), ("B", "B.xcframework")].forEach {
            let frameworkPath = workspace.artifactsDir.appending(components: $0.0, $0.1)
            try fs.createDirectory(frameworkPath, recursive: true)
        }

        // Pin A to 1.0.0, Checkout B to 1.0.0
        let aURL = workspace.urlForPackage(withName: "A")
        let aRef = PackageReference(identity: PackageIdentity(url: aURL), path: aURL)
        let aRepo = workspace.repoProvider.specifierMap[RepositorySpecifier(url: aURL)]!
        let aRevision = try aRepo.resolveRevision(tag: "1.0.0")
        let aState = CheckoutState(revision: aRevision, version: "1.0.0")

        try workspace.set(
            pins: [aRef: aState],
            managedDependencies: [],
            managedArtifacts: [
                ManagedArtifact(
                    packageRef: aRef,
                    targetName: "A1",
                    source: .remote(
                        url: "https://a.com/a1.zip",
                        checksum: "a1",
                        subpath: RelativePath("A/A1.xcframework")
                    )
                ),
                ManagedArtifact(
                    packageRef: aRef,
                    targetName: "A3",
                    source: .remote(
                        url: "https://a.com/old/a3.zip",
                        checksum: "a3-old-checksum",
                        subpath: RelativePath("A/A3.xcframework")
                    )
                ),
                ManagedArtifact(
                    packageRef: aRef,
                    targetName: "A4",
                    source: .remote(
                        url: "https://a.com/a4.zip",
                        checksum: "a4",
                        subpath: RelativePath("A/A4.xcframework")
                    )
                ),
                ManagedArtifact(
                    packageRef: aRef,
                    targetName: "A5",
                    source: .remote(
                        url: "https://a.com/a5.zip",
                        checksum: "a5",
                        subpath: RelativePath("A/A5.xcframework")
                    )
                ),
                ManagedArtifact(
                    packageRef: aRef,
                    targetName: "A6",
                    source: .local(path: "A6.xcframework")
                ),
            ]
        )

        workspace.checkPackageGraph(roots: ["Foo"]) { graph, diagnostics in
            XCTAssertEqual(diagnostics.diagnostics.map { $0.message.text }, ["downloaded archive of binary target 'A3' does not contain expected binary artifact 'A3.xcframework'"])
            XCTAssert(fs.isDirectory(AbsolutePath("/tmp/ws/.build/artifacts/B")))
            XCTAssert(!fs.exists(AbsolutePath("/tmp/ws/.build/artifacts/A/A3.xcframework")))
            XCTAssert(!fs.exists(AbsolutePath("/tmp/ws/.build/artifacts/A/A4.xcframework")))
            XCTAssert(!fs.exists(AbsolutePath("/tmp/ws/.build/artifacts/A/A5.xcframework")))
            XCTAssert(!fs.exists(AbsolutePath("/tmp/ws/.build/artifacts/Foo")))
            XCTAssertEqual(downloads.map { $0.url }, [
                URL(string: "https://b.com/b.zip")!,
                URL(string: "https://a.com/a2.zip")!,
                URL(string: "https://a.com/a3.zip")!,
            ])
            XCTAssertEqual(workspace.checksumAlgorithm.hashes, [
                ByteString([0xB0]),
                ByteString([0xA2]),
                ByteString([0xA3]),
            ])
            XCTAssertEqual(workspace.archiver.extractions.map { $0.destinationPath }, [
                AbsolutePath("/tmp/ws/.build/artifacts/B"),
                AbsolutePath("/tmp/ws/.build/artifacts/A"),
                AbsolutePath("/tmp/ws/.build/artifacts/A"),
            ])
            XCTAssertEqual(
                downloads.map { $0.destinationPath },
                workspace.archiver.extractions.map { $0.archivePath }
            )
            PackageGraphTester(graph) { graph in
                if let a1 = graph.find(target: "A1")?.underlyingTarget as? BinaryTarget {
                    XCTAssertEqual(a1.artifactPath, AbsolutePath("/tmp/ws/.build/artifacts/A/A1.xcframework"))
                    XCTAssertEqual(a1.artifactSource, .remote(url: "https://a.com/a1.zip"))
                } else {
                    XCTFail("expected binary target")
                }

                if let a2 = graph.find(target: "A2")?.underlyingTarget as? BinaryTarget {
                    XCTAssertEqual(a2.artifactPath, AbsolutePath("/tmp/ws/.build/artifacts/A/A2.xcframework"))
                    XCTAssertEqual(a2.artifactSource, .remote(url: "https://a.com/a2.zip"))
                } else {
                    XCTFail("expected binary target")
                }

                if let a3 = graph.find(target: "A3")?.underlyingTarget as? BinaryTarget {
                    XCTAssertEqual(a3.artifactPath, AbsolutePath("/tmp/ws/.build/artifacts/A/A3.xcframework"))
                    XCTAssertEqual(a3.artifactSource, .remote(url: "https://a.com/a3.zip"))
                } else {
                    XCTFail("expected binary target")
                }

                if let a4 = graph.find(target: "A4")?.underlyingTarget as? BinaryTarget {
                    XCTAssertEqual(a4.artifactPath, a4FrameworkPath)
                    XCTAssertEqual(a4.artifactSource, .local)
                } else {
                    XCTFail("expected binary target")
                }

                if let b = graph.find(target: "B")?.underlyingTarget as? BinaryTarget {
                    XCTAssertEqual(b.artifactPath, AbsolutePath("/tmp/ws/.build/artifacts/B/B.xcframework"))
                    XCTAssertEqual(b.artifactSource, .remote(url: "https://b.com/b.zip"))
                } else {
                    XCTFail("expected binary target")
                }
            }
        }

        workspace.checkManagedArtifacts { result in
            result.check(packageName: "A", targetName: "A1", source: .remote(
                url: "https://a.com/a1.zip",
                checksum: "a1",
                subpath: RelativePath("A/A1.xcframework")
            ))
            result.check(packageName: "A", targetName: "A2", source: .remote(
                url: "https://a.com/a2.zip",
                checksum: "a2",
                subpath: RelativePath("A/A2.xcframework")
            ))
            result.check(packageName: "A", targetName: "A3", source: .remote(
                url: "https://a.com/a3.zip",
                checksum: "a3",
                subpath: RelativePath("A/A3.xcframework")
            ))
            result.check(packageName: "A", targetName: "A4", source: .local(path: "A4.xcframework"))
            result.checkNotPresent(packageName: "A", targetName: "A5")
            result.check(packageName: "B", targetName: "B", source: .remote(
                url: "https://b.com/b.zip",
                checksum: "b0",
                subpath: RelativePath("B/B.xcframework")
            ))
        }
    }

    func testArtifactDownloaderOrArchiverError() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            downloader: MockDownloader(fileSystem: fs, downloadFile: { url, destination, _, completion in
                switch url {
                case URL(string: "https://a.com/a1.zip")!:
                    completion(.failure(.serverError(statusCode: 500)))
                case URL(string: "https://a.com/a2.zip")!:
                    try! fs.writeFileContents(destination, bytes: ByteString([0xA2]))
                    completion(.success(()))
                case URL(string: "https://a.com/a3.zip")!:
                    try! fs.writeFileContents(destination, bytes: "different contents = different checksum")
                    completion(.success(()))
                default:
                    XCTFail("unexpected url")
                    completion(.success(()))
                }
            }),
            archiver: MockArchiver(extract: { _, destinationPath, completion in
                XCTAssertEqual(destinationPath, AbsolutePath("/tmp/ws/.build/artifacts/A"))
                completion(.failure(DummyError()))
            }),
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: [
                            .product(name: "A1", package: "A"),
                            .product(name: "A2", package: "A"),
                        ]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "A", requirement: .exact("1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "A",
                    targets: [
                        MockTarget(
                            name: "A1",
                            type: .binary,
                            url: "https://a.com/a1.zip",
                            checksum: "a1"
                        ),
                        MockTarget(
                            name: "A2",
                            type: .binary,
                            url: "https://a.com/a2.zip",
                            checksum: "a2"
                        ),
                        MockTarget(
                            name: "A3",
                            type: .binary,
                            url: "https://a.com/a3.zip",
                            checksum: "a3"
                        ),
                    ],
                    products: [
                        MockProduct(name: "A1", targets: ["A1"]),
                        MockProduct(name: "A2", targets: ["A2"]),
                        MockProduct(name: "A3", targets: ["A3"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        workspace.checkPackageGraph(roots: ["Foo"]) { result, diagnostics in
            print(diagnostics.diagnostics)
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .contains("artifact of binary target 'A1' failed download: invalid status code 500"), behavior: .error)
                result.check(diagnostic: .contains("artifact of binary target 'A2' failed extraction: dummy error"), behavior: .error)
                result.check(diagnostic: .contains("checksum of downloaded artifact of binary target 'A3' (6d75736b6365686320746e65726566666964203d2073746e65746e6f6320746e65726566666964) does not match checksum specified by the manifest (a3)"), behavior: .error)
            }
        }
    }

    func testArtifactChecksumChange() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Foo",
                    targets: [
                        MockTarget(name: "Foo", dependencies: ["A"]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "A", requirement: .exact("1.0.0")),
                    ]
                ),
            ],
            packages: [
                MockPackage(
                    name: "A",
                    targets: [
                        MockTarget(name: "A", type: .binary, url: "https://a.com/a.zip", checksum: "a"),
                    ],
                    products: [
                        MockProduct(name: "A", targets: ["A"]),
                    ],
                    versions: ["0.9.0", "1.0.0"]
                ),
            ]
        )

        // Pin A to 1.0.0, Checkout A to 1.0.0
        let aURL = workspace.urlForPackage(withName: "A")
        let aRef = PackageReference(identity: PackageIdentity(url: aURL), path: aURL)
        let aRepo = workspace.repoProvider.specifierMap[RepositorySpecifier(url: aURL)]!
        let aRevision = try aRepo.resolveRevision(tag: "1.0.0")
        let aState = CheckoutState(revision: aRevision, version: "1.0.0")
        let aDependency = ManagedDependency(packageRef: aRef, subpath: RelativePath("A"), checkoutState: aState)

        try workspace.set(
            pins: [aRef: aState],
            managedDependencies: [aDependency],
            managedArtifacts: [
                ManagedArtifact(
                    packageRef: aRef,
                    targetName: "A",
                    source: .remote(
                        url: "https://a.com/a.zip",
                        checksum: "old-checksum",
                        subpath: RelativePath("A/A.xcframework")
                    )
                ),
            ]
        )

        workspace.checkPackageGraph(roots: ["Foo"]) { result, diagnostics in
            XCTAssertEqual(workspace.downloader.downloads, [])
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(diagnostic: .contains("artifact of binary target 'A' has changed checksum"), behavior: .error)
            }
        }
    }

    func testAndroidCompilerFlags() throws {
        let target = try Triple("x86_64-unknown-linux-android")
        let sdk = AbsolutePath("/some/path/to/an/SDK.sdk")
        let toolchainPath = AbsolutePath("/some/path/to/a/toolchain.xctoolchain")

        let destination = Destination(
            target: target,
            sdk: sdk,
            binDir: toolchainPath.appending(components: "usr", "bin")
        )

        XCTAssertEqual(UserToolchain.deriveSwiftCFlags(triple: target, destination: destination), [
            // Needed when cross‐compiling for Android. 2020‐03‐01
            "-sdk", sdk.pathString,
        ])
    }

    func testDuplicateIdentityAtRoot() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "RootTarget", dependencies: [
                            .product(name: "FooProduct", package: "FooUtilityPackage"),
                            .product(name: "BarProduct", package: "BarUtilityPackage")
                        ]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "FooUtilityPackage", path: "foo/utility", requirement: .upToNextMajor(from: "1.0.0")),
                        MockDependency(name: "BarUtilityPackage", path: "bar/utility", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    toolsVersion: .v5
                ),
            ],
            packages: [
                MockPackage(
                    name: "FooUtilityPackage",
                    path: "foo/utility",
                    targets: [
                        MockTarget(name: "FooTarget"),
                    ],
                    products: [
                        MockProduct(name: "FooProduct", targets: ["FooTarget"]),
                    ],
                    versions: ["1.0.0", "2.0.0"]
                ),
                // this package never gets loaded since the dependency declaration identity is the same as "FooPackage"
                MockPackage(
                    name: "BarUtilityPackage",
                    path: "bar/utility",
                    targets: [
                        MockTarget(name: "BarTarget"),
                    ],
                    products: [
                        MockProduct(name: "BarProduct", targets: ["BarTarget"]),
                    ],
                    versions: ["1.0.0", "2.0.0"]
                ),
            ]
        )

        workspace.checkPackageGraph(roots: ["Root"]) { graph, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(
                    diagnostic: "'Root' dependency on '/tmp/ws/pkgs/bar/utility' conflicts with dependency on '/tmp/ws/pkgs/foo/utility' which has the same identity 'utility'",
                    behavior: .error,
                    location: "'Root' /tmp/ws/roots/Root"
                )
            }
        }
    }

    func testDuplicateNameAtRoot() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "RootTarget", dependencies: [
                            .product(name: "FooProduct", package: "FooPackage"),
                            .product(name: "BarProduct", package: "BarPackage")
                        ]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "FooPackage", path: "foo", requirement: .upToNextMajor(from: "1.0.0")),
                        MockDependency(name: "FooPackage", path: "bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    toolsVersion: .v5
                ),
            ],
            packages: [
                MockPackage(
                    name: "FooPackage",
                    path: "foo",
                    targets: [
                        MockTarget(name: "FooTarget"),
                    ],
                    products: [
                        MockProduct(name: "FooProduct", targets: ["FooTarget"]),
                    ],
                    versions: ["1.0.0", "2.0.0"]
                ),
                // this package never gets loaded since the dependency declaration name is the same as "FooPackage"
                MockPackage(
                    name: "BarPackage",
                    path: "bar",
                    targets: [
                        MockTarget(name: "BarTarget"),
                    ],
                    products: [
                        MockProduct(name: "BarProduct", targets: ["BarTarget"]),
                    ],
                    versions: ["1.0.0", "2.0.0"]
                ),
            ]
        )

        workspace.checkPackageGraph(roots: ["Root"]) { graph, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(
                    diagnostic: "'Root' dependency on '/tmp/ws/pkgs/bar' conflicts with dependency on '/tmp/ws/pkgs/foo' which has the same explicit name 'FooPackage'",
                    behavior: .error,
                    location: "'Root' /tmp/ws/roots/Root"
                )
            }
        }
    }

    func testDuplicateTransitiveIdentityWithNames() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "RootTarget", dependencies: [
                            .product(name: "FooUtilityProduct", package: "FooUtilityPackage"),
                            .product(name: "BarProduct", package: "BarPackage")
                        ]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "FooUtilityPackage", path: "foo/utility", requirement: .upToNextMajor(from: "1.0.0")),
                        MockDependency(name: "BarPackage", path: "bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    toolsVersion: .v5
                ),
            ],
            packages: [
                MockPackage(
                    name: "FooUtilityPackage",
                    path: "foo/utility",
                    targets: [
                        MockTarget(name: "FooUtilityTarget"),
                    ],
                    products: [
                        MockProduct(name: "FooUtilityProduct", targets: ["FooUtilityTarget"]),
                    ],
                    versions: ["1.0.0"]
                ),
                MockPackage(
                    name: "BarPackage",
                    path: "bar",
                    targets: [
                        MockTarget(name: "BarTarget", dependencies: [
                            .product(name: "OtherUtilityProduct", package: "OtherUtilityPackage"),
                        ]),
                    ],
                    products: [
                        MockProduct(name: "BarProduct", targets: ["BarTarget"]),
                    ],
                    dependencies: [
                        MockDependency(name: "OtherUtilityPackage", path: "other/utility", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0"]
                ),
                // this package never gets loaded since its identity is the same as "FooPackage"
                MockPackage(
                    name: "OtherUtilityPackage",
                    path: "other/utility",
                    targets: [
                        MockTarget(name: "OtherUtilityTarget"),
                    ],
                    products: [
                        MockProduct(name: "OtherUtilityProduct", targets: ["OtherUtilityTarget"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        // FIXME: rdar://72940946
        // we need to improve this situation or diagnostics when working on identity
        workspace.checkPackageGraph(roots: ["Root"]) { graph, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(
                    diagnostic: "'BarPackage' dependency on '/tmp/ws/pkgs/other/utility' conflicts with dependency on '/tmp/ws/pkgs/foo/utility' which has the same identity 'utility'",
                    behavior: .error,
                    location: "'BarPackage' /tmp/ws/pkgs/bar"
                )
            }
        }
    }

    func testDuplicateTransitiveIdentityWithoutNames() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "RootTarget", dependencies: [
                            .product(name: "FooUtilityProduct", package: "FooUtilityPackage"),
                            .product(name: "BarProduct", package: "BarPackage")
                        ]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: nil, path: "foo/utility", requirement: .upToNextMajor(from: "1.0.0")),
                        MockDependency(name: nil, path: "bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    toolsVersion: .v5
                ),
            ],
            packages: [
                MockPackage(
                    name: "FooUtilityPackage",
                    path: "foo/utility",
                    targets: [
                        MockTarget(name: "FooUtilityTarget"),
                    ],
                    products: [
                        MockProduct(name: "FooUtilityProduct", targets: ["FooUtilityTarget"]),
                    ],
                    versions: ["1.0.0"]
                ),
                MockPackage(
                    name: "BarPackage",
                    path: "bar",
                    targets: [
                        MockTarget(name: "BarTarget", dependencies: [
                            .product(name: "OtherUtilityProduct", package: "OtherUtilityPackage"),
                        ]),
                    ],
                    products: [
                        MockProduct(name: "BarProduct", targets: ["BarTarget"]),
                    ],
                    dependencies: [
                        MockDependency(name: nil, path: "other-foo/utility", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0"]
                ),
                // this package never gets loaded since its identity is the same as "FooPackage"
                MockPackage(
                    name: "OtherUtilityPackage",
                    path: "other/utility",
                    targets: [
                        MockTarget(name: "OtherUtilityTarget"),
                    ],
                    products: [
                        MockProduct(name: "OtherUtilityProduct", targets: ["OtherUtilityTarget"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        // FIXME: rdar://72940946
        // we need to improve this situation or diagnostics when working on identity
        workspace.checkPackageGraph(roots: ["Root"]) { graph, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(
                    diagnostic: "product 'OtherUtilityProduct' not found in package 'OtherUtilityPackage'. it is required by package 'BarPackage' target 'BarTarget'.",
                    behavior: .error,
                    location: "'BarPackage' /tmp/ws/pkgs/bar"
                )
            }
        }
    }

    func testDuplicateNestedTransitiveIdentityWithNames() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "RootTarget", dependencies: [
                            .product(name: "FooUtilityProduct", package: "FooUtilityPackage")
                        ]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "FooUtilityPackage", path: "foo/utility", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    toolsVersion: .v5
                ),
            ],
            packages: [
                MockPackage(
                    name: "FooUtilityPackage",
                    path: "foo/utility",
                    targets: [
                        MockTarget(name: "FooUtilityTarget", dependencies: [
                            .product(name: "BarProduct", package: "BarPackage")
                        ]),
                    ],
                    products: [
                        MockProduct(name: "FooUtilityProduct", targets: ["FooUtilityTarget"]),
                    ],
                    dependencies: [
                        MockDependency(name: "BarPackage", path: "bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0"]
                ),
                MockPackage(
                    name: "BarPackage",
                    path: "bar",
                    targets: [
                        MockTarget(name: "BarTarget", dependencies: [
                            .product(name: "OtherUtilityProduct", package: "OtherUtilityPackage"),
                        ]),
                    ],
                    products: [
                        MockProduct(name: "BarProduct", targets: ["BarTarget"]),
                    ],
                    dependencies: [
                        MockDependency(name: "OtherUtilityPackage", path: "other/utility", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0"]
                ),
                // this package never gets loaded since its identity is the same as "FooPackage"
                MockPackage(
                    name: "OtherUtilityPackage",
                    path: "other/utility",
                    targets: [
                        MockTarget(name: "OtherUtilityTarget"),
                    ],
                    products: [
                        MockProduct(name: "OtherUtilityProduct", targets: ["OtherUtilityTarget"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        // FIXME: rdar://72940946
        // we need to improve this situation or diagnostics when working on identity
        workspace.checkPackageGraph(roots: ["Root"]) { graph, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(
                    diagnostic: "cyclic dependency declaration found: Root -> FooUtilityPackage -> BarPackage -> FooUtilityPackage",
                    behavior: .error,
                    location: "<unknown>"
                )
            }
        }
    }

    func testDuplicateNestedTransitiveIdentityWithoutNames() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    targets: [
                        MockTarget(name: "RootTarget", dependencies: [
                            .product(name: "FooUtilityProduct", package: "FooUtilityPackage")
                        ]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: nil, path: "foo/utility", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    toolsVersion: .v5
                ),
            ],
            packages: [
                MockPackage(
                    name: "FooUtilityPackage",
                    path: "foo/utility",
                    targets: [
                        MockTarget(name: "FooUtilityTarget", dependencies: [
                            .product(name: "BarProduct", package: "BarPackage")
                        ]),
                    ],
                    products: [
                        MockProduct(name: "FooUtilityProduct", targets: ["FooUtilityTarget"]),
                    ],
                    dependencies: [
                        MockDependency(name: nil, path: "bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0"],
                    toolsVersion: .v5
                ),
                MockPackage(
                    name: "BarPackage",
                    path: "bar",
                    targets: [
                        MockTarget(name: "BarTarget", dependencies: [
                            .product(name: "OtherUtilityProduct", package: "OtherUtilityPackage"),
                        ]),
                    ],
                    products: [
                        MockProduct(name: "BarProduct", targets: ["BarTarget"]),
                    ],
                    dependencies: [
                        MockDependency(name: nil, path: "other/utility", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0"],
                    toolsVersion: .v5
                ),
                // this package never gets loaded since its identity is the same as "FooPackage"
                MockPackage(
                    name: "OtherUtilityPackage",
                    path: "other/utility",
                    targets: [
                        MockTarget(name: "OtherUtilityTarget"),
                    ],
                    products: [
                        MockProduct(name: "OtherUtilityProduct", targets: ["OtherUtilityTarget"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        // FIXME: rdar://72940946
        // we need to improve this situation or diagnostics when working on identity
        workspace.checkPackageGraph(roots: ["Root"]) { graph, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(
                    diagnostic: "cyclic dependency declaration found: Root -> FooUtilityPackage -> BarPackage -> FooUtilityPackage",
                    behavior: .error,
                    location: "<unknown>"
                )
            }
        }
    }

    func testRootPathConflictsWithTransitiveIdentity() throws {
        let sandbox = AbsolutePath("/tmp/ws/")
        let fs = InMemoryFileSystem()

        let workspace = try MockWorkspace(
            sandbox: sandbox,
            fs: fs,
            roots: [
                MockPackage(
                    name: "Root",
                    path: "foo",
                    targets: [
                        MockTarget(name: "RootTarget", dependencies: [
                            .product(name: "BarProduct", package: "BarPackage")
                        ]),
                    ],
                    products: [],
                    dependencies: [
                        MockDependency(name: "BarPackage", path: "bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    toolsVersion: .v5
                ),
            ],
            packages: [
                MockPackage(
                    name: "BarPackage",
                    path: "bar",
                    targets: [
                        MockTarget(name: "BarTarget", dependencies: [
                            .product(name: "FooProduct", package: "FooPackage"),
                        ]),
                    ],
                    products: [
                        MockProduct(name: "BarProduct", targets: ["BarTarget"]),
                    ],
                    dependencies: [
                        MockDependency(name: "FooPackage", path: "foo", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    versions: ["1.0.0"]
                ),
                // this package never gets loaded since its identity is the same as "FooPackage"
                MockPackage(
                    name: "FooPackage",
                    path: "foo",
                    targets: [
                        MockTarget(name: "FooTarget"),
                    ],
                    products: [
                        MockProduct(name: "FooProduct", targets: ["FooTarget"]),
                    ],
                    versions: ["1.0.0"]
                ),
            ]
        )

        // FIXME: rdar://72940946
        // we need to improve this situation or diagnostics when working on identity
        workspace.checkPackageGraph(roots: ["foo"]) { graph, diagnostics in
            DiagnosticsEngineTester(diagnostics) { result in
                result.check(
                    diagnostic: "cyclic dependency declaration found: Root -> BarPackage -> Root",
                    behavior: .error,
                    location: "<unknown>"
                )
            }
        }
    }
}

extension PackageGraph {
    /// Finds the package matching the given name.
    func lookup(_ name: String) -> ResolvedPackage {
        return packages.first { $0.name == name }!
    }
}

struct DummyError: LocalizedError, Equatable {
    public var errorDescription: String? { "dummy error" }
}
