//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if compiler(>=6.0)
import Basics
import PackageModel
import SourceControl
import _InternalTestSupport
import XCTest

final class TraitLoadingTests: PackageDescriptionLoadingTests {
    override var toolsVersion: ToolsVersion {
        .vNext
    }

    func testTraits() async throws {
        let content =  """
            @_spi(ExperimentalTraits) import PackageDescription
            let package = Package(
                name: "Foo",
                traits: [
                    "Trait1",
                    Trait(name: "Trait2", description: "Trait 2 description"),
                    .trait(name: "Trait3", description: "Trait 3 description", enabledTraits: ["Trait1"]),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.traits, [
            TraitDescription(name: "Trait1"),
            TraitDescription(name: "Trait2", description: "Trait 2 description"),
            TraitDescription(name: "Trait3", description: "Trait 3 description", enabledTraits: ["Trait1"]),
        ])
    }

    func testTraits_whenTooMany() async throws {
        let traits = Array(0...300).map { "\"Trait\($0)\"" }.joined(separator: ",")
        let content =  """
            @_spi(ExperimentalTraits) import PackageDescription
            let package = Package(
                name: "Foo",
                traits: [\(traits)]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (_, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        let firstDiagnostic = try XCTUnwrap(validationDiagnostics.first)
        XCTAssertEqual(firstDiagnostic.severity, .error)
        XCTAssertEqual(firstDiagnostic.message, "A package can define a maximum of 300 traits")
    }

    func testTraits_whenUnknownEnabledTrait() async throws {
        let content =  """
            @_spi(ExperimentalTraits) import PackageDescription
            let package = Package(
                name: "Foo",
                traits: [
                    Trait(name: "Trait1", enabledTraits: ["Trait2"]),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (_, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        let firstDiagnostic = try XCTUnwrap(validationDiagnostics.first)
        XCTAssertEqual(firstDiagnostic.severity, .error)
        XCTAssertEqual(firstDiagnostic.message, "Trait Trait1 enables Trait2 which is not defined in the package")
    }

    func testTraits_whenInvalidFirstCharacter() async throws {
        let invalidTraitNames = [
            ";",
            "{",
            "}",
            "<",
            ">",
            "$",
            ".",
            "?",
            ",",
            "ⒶⒷⒸ",
        ]

        for traitName in invalidTraitNames {
            let content =  """
            @_spi(ExperimentalTraits) import PackageDescription
            let package = Package(
                name: "Foo",
                traits: [
                    "\(traitName)"
                ]
            )
            """

            let observability = ObservabilitySystem.makeForTesting()
            let (_, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            let firstDiagnostic = try XCTUnwrap(validationDiagnostics.first)
            XCTAssertEqual(firstDiagnostic.severity, .error)
            XCTAssertEqual(firstDiagnostic.message, "Invalid first character (\(traitName.first!)) in trait \(traitName). The first character must be a Unicode XID start character (most letters), a digit, or _.")
        }
    }

    func testTraits_whenInvalidSecondCharacter() async throws {
        let invalidTraitNames = [
            "_;",
            "_{",
            "_}",
            "_<",
            "_>",
            "_$",
            "foo,",
            "foo:bar",
            "foo?",
            "a¼",
        ]

        for traitName in invalidTraitNames {
            let content =  """
            @_spi(ExperimentalTraits) import PackageDescription
            let package = Package(
                name: "Foo",
                traits: [
                    "\(traitName)"
                ]
            )
            """

            let observability = ObservabilitySystem.makeForTesting()
            let (_, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            let firstDiagnostic = try XCTUnwrap(validationDiagnostics.first)
            XCTAssertEqual(firstDiagnostic.severity, .error)
        }
    }

    func testDefaultTraits() async throws {
        let content =  """
            @_spi(ExperimentalTraits) import PackageDescription
            let package = Package(
                name: "Foo",
                traits: [
                    .default(enabledTraits: ["Trait1", "Trait3"]),
                    Trait(name: "Trait1"),
                    Trait(name: "Trait2"),
                    .trait(name: "Trait3", enabledTraits: ["Trait1"]),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.traits, [
            TraitDescription(name: "default", description: "The default traits of this package.", enabledTraits: ["Trait1", "Trait3"]),
            TraitDescription(name: "Trait1"),
            TraitDescription(name: "Trait2"),
            TraitDescription(name: "Trait3", enabledTraits: ["Trait1"]),
        ])
    }

    func testDependencies() async throws {
        let content =  """
            @_spi(ExperimentalTraits) import PackageDescription
            let package = Package(
                name: "Foo",
                traits: [
                    .default(enabledTraits: ["Trait1", "Trait2"]),
                    .trait(name: "Trait1"),
                    .trait(name: "Trait2"),
                ],
                dependencies: [
                    .package(
                        id: "x.foo",
                        from: "1.1.1",
                        traits: [
                            "FooTrait1",
                            .trait(name: "FooTrait2", condition: .when(traits: ["Trait1"])),
                            Package.Dependency.Trait(name: "FooTrait3", condition: .when(traits: ["Trait2"])),
                            .defaults
                        ]
                    ),
                    .package(
                        path: "../Bar",
                        traits: [
                            "BarTrait1",
                            .trait(name: "BarTrait2", condition: .when(traits: ["Trait1"])),
                            Package.Dependency.Trait(name: "BarTrait3", condition: .when(traits: ["Trait2"])),
                            .defaults
                        ]
                    ),
                    .package(
                        url: "https://github.com/Foo/FooBar",
                        from: "1.0.0",
                        traits: [
                            "FooBarTrait1",
                            .trait(name: "FooBarTrait2", condition: .when(traits: ["Trait1"])),
                            Package.Dependency.Trait(name: "FooBarTrait3", condition: .when(traits: ["Trait2"])),
                            .defaults
                        ]
                    ),
                ],
                targets: [
                    .target(
                        name: "Target",
                        dependencies: [
                            .product(
                                name: "Product1",
                                package: "foobar",
                                condition: .when(traits: ["Trait1"])
                            ),
                            .product(
                                name: "Product2",
                                package: "bar",
                                condition: .when(traits: ["Trait2"])
                            ),
                        ],
                        swiftSettings: [
                            .define("DEFINE1", .when(traits: ["Trait1"])),
                            .define("DEFINE2", .when(traits: ["Trait2"])),
                            .define("DEFINE3", .when(traits: ["Trait1", "Trait2"])),
                        ]
                    )
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.traits, [
            TraitDescription(name: "default", description: "The default traits of this package.", enabledTraits: ["Trait1", "Trait2"]),
            TraitDescription(name: "Trait1"),
            TraitDescription(name: "Trait2"),
        ])
        let deps = Dictionary(uniqueKeysWithValues: manifest.dependencies.map{ ($0.identity.description, $0) })
        XCTAssertEqual(
            deps["x.foo"]?.traits,
            [
                .init(name: "FooTrait1"),
                .init(name: "FooTrait2", condition: .init(traits: ["Trait1"])),
                .init(name: "FooTrait3", condition: .init(traits: ["Trait2"])),
                .init(name: "default"),
            ]
        )
        XCTAssertEqual(
            deps["bar"]?.traits,
            [
                .init(name: "BarTrait1"),
                .init(name: "BarTrait2", condition: .init(traits: ["Trait1"])),
                .init(name: "BarTrait3", condition: .init(traits: ["Trait2"])),
                .init(name: "default"),
            ]
        )
        XCTAssertEqual(
            deps["foobar"]?.traits,
            [
                .init(name: "FooBarTrait1"),
                .init(name: "FooBarTrait2", condition: .init(traits: ["Trait1"])),
                .init(name: "FooBarTrait3", condition: .init(traits: ["Trait2"])),
                .init(name: "default"),
            ]
        )
        XCTAssertEqual(
            manifest.targets.first,
            try .init(
                name: "Target",
                dependencies: [
                    .product(
                        name: "Product1",
                        package: "foobar",
                        condition: .init(traits: ["Trait1"])
                    ),
                    .product(
                        name: "Product2",
                        package: "bar",
                        condition: .init(traits: ["Trait2"])
                    ),
                ],
                settings: [
                    .init(
                        tool: .swift,
                        kind: .define("DEFINE1"),
                        condition: .init(traits: ["Trait1"])
                    ),
                    .init(
                        tool: .swift,
                        kind: .define("DEFINE2"),
                        condition: .init(traits: ["Trait2"])
                    ),
                    .init(
                        tool: .swift,
                        kind: .define("DEFINE3"),
                        condition: .init(traits: ["Trait1", "Trait2"])
                    ),
                ]
            )
        )
    }
}
#endif
