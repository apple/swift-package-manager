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

import Basics
import PackageModel
import SourceControl
import SPMTestSupport
import XCTest

final class TraitLoadingTests: PackageDescriptionLoadingTests {
    override var toolsVersion: ToolsVersion {
        .vNext
    }

    func testTraits() async throws {
        let content =  """
            import PackageDescription
            let package = Package(
                name: "Foo",
                traits: [
                    "Trait1",
                    Trait(name: "Trait2"),
                    Trait(name: "Trait3", enabledTraits: ["Trait1"]),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.traits, [
            TraitDescription(name: "Trait1"),
            TraitDescription(name: "Trait2"),
            TraitDescription(name: "Trait3", enabledTraits: ["Trait1"]),
        ])
    }

    func testTraits_whenTooMany() async throws {
        let traits = Array(0...300).map { "\"Trait\($0)\"" }.joined(separator: ",")
        let content =  """
            import PackageDescription
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

    func testTraits_whenDefault() async throws {
        let traits = ["default", "DEFAULT", "DEfauLT", "defaults", "DEFaulTs", "DEFAULTS"]

        for trait in traits {
            let content =  """
            import PackageDescription
            let package = Package(
                name: "Foo",
                traits: ["\(trait)"]
            )
            """

            let observability = ObservabilitySystem.makeForTesting()
            let (_, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            let firstDiagnostic = try XCTUnwrap(validationDiagnostics.first)
            XCTAssertEqual(firstDiagnostic.severity, .error)
            XCTAssertEqual(firstDiagnostic.message, "Traits are not allowed to be named 'default' or 'defaults' to avoid confusion with default traits")
        }
    }

    func testTraits_whenUnknownEnabledTrait() async throws {
        let content =  """
            import PackageDescription
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
            import PackageDescription
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
            import PackageDescription
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
            import PackageDescription
            let package = Package(
                name: "Foo",
                traits: [
                    "Trait1",
                    Trait(name: "Trait2"),
                    Trait(name: "Trait3", enabledTraits: ["Trait1"]),
                ],
                defaultTraits: [
                    "Trait1",
                    "Trait3",
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.traits, [
            TraitDescription(name: "Trait1"),
            TraitDescription(name: "Trait2"),
            TraitDescription(name: "Trait3", enabledTraits: ["Trait1"]),
        ])
        XCTAssertEqual(manifest.defaultTraits, [
            "Trait1",
            "Trait3",
        ])
    }

    func testDefaultTraits_whenUnknownDefaultTrait() async throws {
        let content =  """
            import PackageDescription
            let package = Package(
                name: "Foo",
                traits: [
                    "Trait1",
                ],
                defaultTraits: [
                    "Trait2",
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (_, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        let firstDiagnostic = try XCTUnwrap(validationDiagnostics.first)
        XCTAssertEqual(firstDiagnostic.severity, .error)
        XCTAssertEqual(firstDiagnostic.message, "Default trait Trait2 is not defined in the package")
    }
}
