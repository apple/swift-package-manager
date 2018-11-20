#if !canImport(ObjectiveC)
import XCTest

extension BuildPlanTests {
    // DO NOT MODIFY: This is autogenerated, use: 
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__BuildPlanTests = [
        ("testBasicClangPackage", testBasicClangPackage),
        ("testBasicExtPackages", testBasicExtPackages),
        ("testBasicReleasePackage", testBasicReleasePackage),
        ("testBasicSwiftPackage", testBasicSwiftPackage),
        ("testClangTargets", testClangTargets),
        ("testCLanguageStandard", testCLanguageStandard),
        ("testCModule", testCModule),
        ("testCppModule", testCppModule),
        ("testDynamicProducts", testDynamicProducts),
        ("testExecAsDependency", testExecAsDependency),
        ("testIndexStore", testIndexStore),
        ("testNonReachableProductsAndTargets", testNonReachableProductsAndTargets),
        ("testPkgConfigGenericDiagnostic", testPkgConfigGenericDiagnostic),
        ("testPkgConfigHintDiagnostic", testPkgConfigHintDiagnostic),
        ("testPlatforms", testPlatforms),
        ("testREPLArguments", testREPLArguments),
        ("testSwiftCMixed", testSwiftCMixed),
        ("testSystemPackageBuildPlan", testSystemPackageBuildPlan),
        ("testTestModule", testTestModule),
        ("testWindowsTarget", testWindowsTarget),
    ]
}

extension IncrementalBuildTests {
    // DO NOT MODIFY: This is autogenerated, use: 
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__IncrementalBuildTests = [
        ("testIncrementalSingleModuleCLibraryInSources", testIncrementalSingleModuleCLibraryInSources),
    ]
}

public func __allTests() -> [XCTestCaseEntry] {
    return [
        testCase(BuildPlanTests.__allTests__BuildPlanTests),
        testCase(IncrementalBuildTests.__allTests__IncrementalBuildTests),
    ]
}
#endif
