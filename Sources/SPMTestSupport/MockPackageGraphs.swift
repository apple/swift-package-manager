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

import struct Basics.AbsolutePath
import class Basics.ObservabilitySystem
import class Basics.ObservabilityScope
import struct PackageGraph.ModulesGraph
import class PackageModel.Manifest
import struct PackageModel.ProductDescription
import struct PackageModel.TargetDescription
import protocol TSCBasic.FileSystem
import class TSCBasic.InMemoryFileSystem

package typealias MockPackageGraph = (
    graph: ModulesGraph,
    fileSystem: any FileSystem,
    observabilityScope: ObservabilityScope
)

package func macrosPackageGraph() throws -> MockPackageGraph {
    let fs = InMemoryFileSystem(emptyFiles:
        "/swift-firmware/Sources/Core/source.swift",
        "/swift-firmware/Sources/HAL/source.swift",
        "/swift-firmware/Tests/CoreTests/source.swift",
        "/swift-firmware/Tests/HALTests/source.swift",
        "/swift-mmio/Sources/MMIO/source.swift",
        "/swift-mmio/Sources/MMIOMacros/source.swift",
        "/swift-syntax/Sources/SwiftSyntax/source.swift",
        "/swift-syntax/Tests/SwiftSyntaxTests/source.swift"
    )

    let observability = ObservabilitySystem.makeForTesting()
    let graph = try loadModulesGraph(
        fileSystem: fs,
        manifests: [
            Manifest.createRootManifest(
                displayName: "swift-firmware",
                path: "/swift-firmware",
                dependencies: [
                    .localSourceControl(
                        path: "/swift-mmio",
                        requirement: .upToNextMajor(from: "1.0.0")
                    )
                ],
                products: [
                    ProductDescription(
                        name: "Core",
                        type: .executable,
                        targets: ["Core"]
                    )
                ],
                targets: [
                    TargetDescription(
                        name: "Core",
                        dependencies: ["HAL"],
                        type: .executable
                    ),
                    TargetDescription(
                        name: "HAL",
                        dependencies: [.product(name: "MMIO", package: "swift-mmio")]
                    ),
                    TargetDescription(name: "CoreTests", dependencies: ["Core"], type: .test),
                    TargetDescription(name: "HALTests", dependencies: ["HAL"], type: .test),
                ]
            ),
            Manifest.createFileSystemManifest(
                displayName: "swift-mmio",
                path: "/swift-mmio",
                dependencies: [
                    .localSourceControl(
                        path: "/swift-syntax",
                        requirement: .upToNextMajor(from: "1.0.0")
                    )
                ],
                products: [
                    ProductDescription(
                        name: "MMIO",
                        type: .library(.automatic),
                        targets: ["MMIO"]
                    )
                ],
                targets: [
                    TargetDescription(
                        name: "MMIO",
                        dependencies: [.target(name: "MMIOMacros")]
                    ),
                    TargetDescription(
                        name: "MMIOMacros",
                        dependencies: [.product(name: "SwiftSyntax", package: "swift-syntax")],
                        type: .macro
                    )
                ]
            ),
            Manifest.createFileSystemManifest(
                displayName: "swift-syntax",
                path: "/swift-syntax",
                products: [
                    ProductDescription(
                        name: "SwiftSyntax",
                        type: .library(.automatic),
                        targets: ["SwiftSyntax"]
                    )
                ],
                targets: [
                    TargetDescription(name: "SwiftSyntax", dependencies: []),
                    TargetDescription(name: "SwiftSyntaxTests", dependencies: ["SwiftSyntax"], type: .test),
                ]
            ),
        ],
        observabilityScope: observability.topScope
    )

    XCTAssertNoDiagnostics(observability.diagnostics)

    return (graph, fs, observability.topScope)
}

package func macrosTestsPackageGraph() throws -> MockPackageGraph {
    let fs = InMemoryFileSystem(emptyFiles:
        "/swift-mmio/Sources/MMIO/source.swift",
        "/swift-mmio/Sources/MMIOMacros/source.swift",
        "/swift-mmio/Sources/MMIOMacrosTests/source.swift",
        "/swift-syntax/Sources/SwiftSyntax/source.swift",
        "/swift-syntax/Sources/SwiftSyntaxMacrosTestSupport/source.swift",
        "/swift-syntax/Tests/SwiftSyntaxTests/source.swift"
    )

    let observability = ObservabilitySystem.makeForTesting()
    let graph = try loadModulesGraph(
        fileSystem: fs,
        manifests: [
            Manifest.createRootManifest(
                displayName: "swift-mmio",
                path: "/swift-mmio",
                dependencies: [
                    .localSourceControl(
                        path: "/swift-syntax",
                        requirement: .upToNextMajor(from: "1.0.0")
                    )
                ],
                products: [
                    ProductDescription(
                        name: "MMIO",
                        type: .library(.automatic),
                        targets: ["MMIO"]
                    )
                ],
                targets: [
                    TargetDescription(
                        name: "MMIO",
                        dependencies: [.target(name: "MMIOMacros")]
                    ),
                    TargetDescription(
                        name: "MMIOMacros",
                        dependencies: [.product(name: "SwiftSyntax", package: "swift-syntax")],
                        type: .macro
                    ),
                    TargetDescription(
                        name: "MMIOMacrosTests",
                        dependencies: [
                            .target(name: "MMIOMacros"),
                            .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
                        ],
                        type: .test
                    )
                ]
            ),
            Manifest.createFileSystemManifest(
                displayName: "swift-syntax",
                path: "/swift-syntax",
                products: [
                    ProductDescription(
                        name: "SwiftSyntax",
                        type: .library(.automatic),
                        targets: ["SwiftSyntax"]
                    ),
                    ProductDescription(
                        name: "SwiftSyntaxMacrosTestSupport",
                        type: .library(.automatic),
                        targets: ["SwiftSyntaxMacrosTestSupport"]
                    )
                ],
                targets: [
                    TargetDescription(name: "SwiftSyntax", dependencies: []),
                    TargetDescription(
                        name: "SwiftSyntaxMacrosTestSupport",
                        dependencies: [.target(name: "SwiftSyntax")]
                    ),
                    TargetDescription(name: "SwiftSyntaxTests", dependencies: ["SwiftSyntax"], type: .test),
                ]
            ),
        ],
        observabilityScope: observability.topScope
    )

    XCTAssertNoDiagnostics(observability.diagnostics)

    return (graph, fs, observability.topScope)
}

package func trivialPackageGraph(pkgRootPath: AbsolutePath) throws -> MockPackageGraph {
    let fs = InMemoryFileSystem(
        emptyFiles:
        "/Pkg/Sources/app/main.swift",
        "/Pkg/Sources/lib/lib.c",
        "/Pkg/Sources/lib/include/lib.h",
        "/Pkg/Tests/test/TestCase.swift"
    )

    let observability = ObservabilitySystem.makeForTesting()
    let graph = try loadModulesGraph(
        fileSystem: fs,
        manifests: [
            Manifest.createRootManifest(
                displayName: "Pkg",
                path: "/Pkg",
                targets: [
                    TargetDescription(name: "app", dependencies: ["lib"]),
                    TargetDescription(name: "lib", dependencies: []),
                    TargetDescription(name: "test", dependencies: ["lib"], type: .test),
                ]
            ),
        ],
        observabilityScope: observability.topScope
    )
    XCTAssertNoDiagnostics(observability.diagnostics)

    return (graph, fs, observability.topScope)
}

package func embeddedCxxInteropPackageGraph(pkgRootPath: AbsolutePath) throws -> MockPackageGraph {
    let fs = InMemoryFileSystem(
        emptyFiles:
        "/Pkg/Sources/app/main.swift",
        "/Pkg/Sources/lib/lib.cpp",
        "/Pkg/Sources/lib/include/lib.h",
        "/Pkg/Tests/test/TestCase.swift"
    )

    let observability = ObservabilitySystem.makeForTesting()
    let graph = try loadModulesGraph(
        fileSystem: fs,
        manifests: [
            Manifest.createRootManifest(
                displayName: "Pkg",
                path: "/Pkg",
                targets: [
                    TargetDescription(
                        name: "app",
                        dependencies: ["lib"],
                        settings: [.init(tool: .swift, kind: .enableExperimentalFeature("Embedded"))]
                    ),
                    TargetDescription(
                        name: "lib",
                        dependencies: [],
                        settings: [.init(tool: .swift, kind: .interoperabilityMode(.Cxx))]
                    ),
                    TargetDescription(
                        name: "test",
                        dependencies: ["lib"],
                        type: .test
                    ),
                ]
            ),
        ],
        observabilityScope: observability.topScope
    )
    XCTAssertNoDiagnostics(observability.diagnostics)

    return (graph, fs, observability.topScope)
}
