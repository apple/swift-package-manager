@_spi(DontAdoptOutsideOfSwiftPMExposedForBenchmarksAndTestsOnly)
import Basics
import Benchmark
import Foundation
import PackageModel

@_spi(DontAdoptOutsideOfSwiftPMExposedForBenchmarksAndTestsOnly)
import func PackageGraph.loadModulesGraph

import Workspace

let benchmarks = {
    let defaultMetrics: [BenchmarkMetric]
    if let envVar = ProcessInfo.processInfo.environment["SWIFTPM_BENCHMARK_ALL_METRICS"],
    envVar.lowercased() == "true" || envVar == "1" {
        defaultMetrics = .all
    } else {
        defaultMetrics = [
            .mallocCountTotal,
            .syscalls,
        ]
    }

    let modulesGraphDepth: Int
    if let envVar = ProcessInfo.processInfo.environment["SWIFTPM_BENCHMARK_MODULES_GRAPH_DEPTH"],
    let parsedValue = Int(envVar) {
        modulesGraphDepth = parsedValue
    } else {
        modulesGraphDepth = 150
    }

    let modulesGraphWidth: Int
    if let envVar = ProcessInfo.processInfo.environment["SWIFTPM_BENCHMARK_MODULES_GRAPH_WIDTH"],
    let parsedValue = Int(envVar) {
        modulesGraphWidth = parsedValue
    } else {
        modulesGraphWidth = 150
    }

    let packagesGraphDepth: Int
    if let envVar = ProcessInfo.processInfo.environment["SWIFTPM_BENCHMARK_PACKAGES_GRAPH_DEPTH"],
    let parsedValue = Int(envVar) {
        packagesGraphDepth = parsedValue
    } else {
        packagesGraphDepth = 10
    }

    // Benchmarks computation of a resolved graph of modules for a package using `Workspace` as an entry point. It runs PubGrub to get
    // resolved concrete versions of dependencies, assigning all modules and products to each other as corresponding dependencies
    // with their build triples, but with the build plan not yet constructed. In this benchmark specifically we're loading `Package.swift`
    // for SwiftPM itself.
    Benchmark(
        "SwiftPMWorkspaceModulesGraph",
        configuration: .init(
            metrics: defaultMetrics,
            maxDuration: .seconds(10),
            thresholds: [
                .mallocCountTotal: .init(absolute: [.p90: 12000]),
                .syscalls: .init(absolute: [.p90: 1600]),
            ]
        )
    ) { benchmark in
        let path = try AbsolutePath(validating: #file).parentDirectory.parentDirectory.parentDirectory
        let workspace = try Workspace(fileSystem: localFileSystem, location: .init(forRootPackage: path, fileSystem: localFileSystem))

        for _ in benchmark.scaledIterations {
            try workspace.loadPackageGraph(rootPath: path, observabilityScope: ObservabilitySystem.NOOP)
        }
    }

    // Benchmarks computation of a resolved graph of modules for a trivial synthesized package using `loadModulesGraph`
    // as an entry point, which almost immediately delegates to `ModulesGraph.load` under the hood.
    Benchmark(
        "SyntheticModulesGraph",
        configuration: .init(
            metrics: defaultMetrics,
            maxDuration: .seconds(10),
            thresholds: [
                .mallocCountTotal: .init(absolute: [.p90: 17000]),
                .syscalls: .init(absolute: [.p90: 5]),
            ]
        )
    ) { benchmark in
        try syntheticModulesGraph(
            benchmark,
            modulesGraphDepth: modulesGraphDepth,
            modulesGraphWidth: modulesGraphWidth
        )
    }

    // Benchmarks computation of a resolved graph of modules for a synthesized package that includes macros,
    // using `loadModulesGraph` as an entry point, which almost immediately delegates to `ModulesGraph.load` under
    // the hood.
    Benchmark(
        "SyntheticModulesGraphWithMacros",
        configuration: .init(
            metrics: defaultMetrics,
            maxDuration: .seconds(10),
            thresholds: [
                .mallocCountTotal: .init(absolute: [.p90: 8000]),
                .syscalls: .init(absolute: [.p90: 5]),
            ]
        )
    ) { benchmark in
        try syntheticModulesGraph(
            benchmark, 
            modulesGraphDepth: modulesGraphDepth, 
            modulesGraphWidth: modulesGraphWidth,
            includeMacros: true
        )
    }
}

func syntheticModulesGraph(
    _ benchmark: Benchmark, 
    modulesGraphDepth: Int, 
    modulesGraphWidth: Int, 
    includeMacros: Bool = false
) throws {
    // If macros are included, modules are split in three parts:
    // 1. top-level modules
    // 2. macros
    // 3. dependencies of macros
    let macrosDenominator = includeMacros ? 3 : 1
    let libraryModules: [TargetDescription] = try (0..<(modulesGraphWidth / macrosDenominator)).map { i -> TargetDescription in
        let dependencies = (0..<min(i, modulesGraphDepth / macrosDenominator)).flatMap { i -> [TargetDescription.Dependency] in
            if includeMacros {
                [.target(name: "Module\(i)"), .target(name: "Macros\(i)")]
            } else {
                [.target(name: "Module\(i)")]
            }
        }
        return try TargetDescription(name: "Module\(i)", dependencies: dependencies)
    }

    let macrosModules: [TargetDescription]
    let macrosDependenciesModules: [TargetDescription]
    if includeMacros {
        macrosModules = try (0..<modulesGraphWidth / macrosDenominator).map { i in
            try TargetDescription(name: "Macros\(i)", dependencies: (0..<min(i, modulesGraphDepth)).map {
                .target(name: "MacrosDependency\($0)")
            })
        }
        macrosDependenciesModules = try (0..<modulesGraphWidth / macrosDenominator).map { i in
            try TargetDescription(name: "MacrosDependency\(i)")
        }
    } else {
        macrosModules = []
        macrosDependenciesModules = []
    }

    let modules = libraryModules + macrosModules + macrosDependenciesModules
    let fileSystem = InMemoryFileSystem(
        emptyFiles: modules.map {
            "/benchmark/Sources/\($0.name)/empty.swift"
        }
    )
    let rootPackagePath = try AbsolutePath(validating: "/benchmark")

    let manifest = Manifest(
        displayName: "benchmark",
        path: rootPackagePath,
        packageKind: .root(rootPackagePath),
        packageLocation: rootPackagePath.pathString,
        defaultLocalization: nil,
        platforms: [],
        version: nil,
        revision: nil,
        toolsVersion: .v5_10,
        pkgConfig: nil,
        providers: nil,
        cLanguageStandard: nil,
        cxxLanguageStandard: nil,
        swiftLanguageVersions: nil,
        targets: modules
    )

    for _ in benchmark.scaledIterations {
        try blackHole(
            loadModulesGraph(fileSystem: fileSystem, manifests: [manifest], observabilityScope: ObservabilitySystem.NOOP)
        )
    }
}
