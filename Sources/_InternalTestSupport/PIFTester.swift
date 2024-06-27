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
import XCBuildSupport
import XCTest

public func PIFTester(_ pif: PIF.TopLevelObject, _ body: (PIFWorkspaceTester) throws -> Void) throws {
    try body(PIFWorkspaceTester(workspace: pif.workspace))
}

public final class PIFWorkspaceTester {
    private let workspace: PIF.Workspace
    private let projectMap: [PIF.GUID: PIF.Project]
    private let targetMap: [PIF.GUID: PIF.BaseTarget]

    fileprivate init(workspace: PIF.Workspace) {
        self.workspace = workspace

        let projectsByGUID = workspace.projects.map { ($0.guid, $0) }
        projectMap = Dictionary(uniqueKeysWithValues: projectsByGUID)
        let targetsByGUID = workspace.projects.flatMap { $0.targets.map { ($0.guid, $0) } }
        targetMap = Dictionary(uniqueKeysWithValues: targetsByGUID)
    }

    public func checkProject(
        _ guid: PIF.GUID,
        file: StaticString = #file,
        line: UInt = #line,
        body: (PIFProjectTester) -> Void
    ) throws {
        guard let project = projectMap[guid] else {
            return XCTFail("project \(guid) not found", file: file, line: line)
        }

        body(try PIFProjectTester(project: project, targetMap: targetMap))
    }
}

public final class PIFProjectTester {
    private let project: PIF.Project
    private let targetMap: [PIF.GUID: PIF.BaseTarget]
    private let fileMap: [PIF.GUID: String]

    public var guid: PIF.GUID { project.guid }
    public var path: AbsolutePath { project.path }
    public var projectDirectory: AbsolutePath { project.projectDirectory }
    public var name: String { project.name }
    public var developmentRegion: String { project.developmentRegion }

    fileprivate init(project: PIF.Project, targetMap: [PIF.GUID: PIF.BaseTarget]) throws {
        self.project = project
        self.targetMap = targetMap
        self.fileMap = try collectFiles(
            from: project.groupTree,
            parentPath: project.path,
            projectPath: project.path,
            builtProductsPath: project.path
        )
    }

    public func checkTarget(
        _ guid: PIF.GUID,
        file: StaticString = #file,
        line: UInt = #line,
        body: ((PIFTargetTester) -> Void)? = nil
    ) {
        guard let baseTarget = baseTarget(withGUID: guid) else {
            let guids = project.targets.map { $0.guid }.joined(separator: ", ")
            return XCTFail("target \(guid) not found among \(guids)", file: file, line: line)
        }

        guard let target = baseTarget as? PIF.Target else {
            return XCTFail("target \(guid) is not a standard target", file: file, line: line)
        }

        body?(PIFTargetTester(target: target, targetMap: targetMap, fileMap: fileMap))
    }

    public func checkNoTarget(
        _ guid: PIF.GUID,
        file: StaticString = #file,
        line: UInt = #line,
        body: ((PIFTargetTester) -> Void)? = nil
    ) {
        if baseTarget(withGUID: guid) != nil {
            XCTFail("target \(guid) found", file: file, line: line)
        }
    }

    public func checkAggregateTarget(
        _ guid: PIF.GUID,
        file: StaticString = #file,
        line: UInt = #line,
        body: ((PIFAggregateTargetTester) -> Void)? = nil
    ) {
        guard let baseTarget = baseTarget(withGUID: guid) else {
            let guids = project.targets.map { $0.guid }.joined(separator: ", ")
            return XCTFail("target \(guid) not found among \(guids)", file: file, line: line)
        }

        guard let target = baseTarget as? PIF.AggregateTarget else {
            return XCTFail("target \(guid) is not an aggregate target", file: file, line: line)
        }

        body?(PIFAggregateTargetTester(target: target, targetMap: targetMap, fileMap: fileMap))
    }

    public func checkBuildConfiguration(
        _ name: String,
        file: StaticString = #file,
        line: UInt = #line,
        body: (PIFBuildConfigurationTester) -> Void
    ) {
        guard let configuration = buildConfiguration(withName: name) else {
            let names = project.buildConfigurations.map { $0.name }.joined(separator: ", ")
            return XCTFail("build configuration \(name) not found among \(names)", file: file, line: line)
        }

        body(PIFBuildConfigurationTester(buildConfiguration: configuration))
    }

    public func buildConfiguration(withName name: String) -> PIF.BuildConfiguration? {
        return project.buildConfigurations.first { $0.name == name }
    }

    public func baseTarget(withGUID guid: PIF.GUID) -> PIF.BaseTarget? {
        return project.targets.first { $0.guid == guid }
    }
}

public class PIFBaseTargetTester {
    public let baseTarget: PIF.BaseTarget

    public var guid: PIF.GUID { baseTarget.guid }
    public var name: String { baseTarget.name }
    public let dependencies: Set<PIF.GUID>
    public let sources: Set<String>
    public let frameworks: Set<String>
    public let resources: Set<String>

    fileprivate init(baseTarget: PIF.BaseTarget, targetMap: [PIF.GUID: PIF.BaseTarget], fileMap: [PIF.GUID: String]) {
        self.baseTarget = baseTarget
        dependencies = Set(baseTarget.dependencies.map { targetMap[$0.targetGUID]!.guid })

        let sourcesBuildFiles = baseTarget.buildPhases.first { $0 is PIF.SourcesBuildPhase }?.buildFiles ?? []
        sources = Set(sourcesBuildFiles.map { buildFile -> String in
            if case .file(let guid) = buildFile.reference {
                return fileMap[guid]!
            } else {
                fatalError("unexpected build file reference: \(buildFile)")
            }
        })

        let frameworksBuildFiles = baseTarget.buildPhases.first { $0 is PIF.FrameworksBuildPhase }?.buildFiles ?? []
        frameworks = Set(frameworksBuildFiles.map { buildFile -> String in
            switch buildFile.reference {
            case .target(let guid):
                return targetMap[guid]!.guid
            case .file(let guid):
                return fileMap[guid]!
            }
        })

        let resourcesBuildFiles = baseTarget.buildPhases.first { $0 is PIF.ResourcesBuildPhase }?.buildFiles ?? []
        resources = Set(resourcesBuildFiles.map { buildFile -> String in
            if case .file(let guid) = buildFile.reference {
                return fileMap[guid]!
            } else {
                fatalError("unexpected build file reference: \(buildFile)")
            }
        })
    }

    public func checkBuildConfiguration(
        _ name: String,
        file: StaticString = #file,
        line: UInt = #line,
        body: (PIFBuildConfigurationTester) -> Void
    ) {
        guard let configuration = buildConfiguration(withName: name) else {
            return XCTFail("build configuration \(name) not found", file: file, line: line)
        }

        body(PIFBuildConfigurationTester(buildConfiguration: configuration))
    }

    public func buildConfiguration(withName name: String) -> PIF.BuildConfiguration? {
        return baseTarget.buildConfigurations.first { $0.name == name }
    }

    public func checkImpartedBuildSettings(
        file: StaticString = #file,
        line: UInt = #line,
        _ body: (PIFBuildSettingsTester) -> Void
    ) {
        let buildSettingsTester = PIFBuildSettingsTester(
            buildSettings: baseTarget.buildConfigurations.first!.impartedBuildProperties.buildSettings
        )
        body(buildSettingsTester)
    }

    public func checkAllImpartedBuildSettings(
        file: StaticString = #file,
        line: UInt = #line,
        _ body: (PIFBuildSettingsTester) -> Void
    ) {
        let buildSettingsTester = PIFBuildSettingsTester(
            buildSettings: baseTarget.buildConfigurations.first!.impartedBuildProperties.buildSettings
        )
        body(buildSettingsTester)
        buildSettingsTester.checkUncheckedSettings(file: file, line: line)
    }

    public func checkNoImpartedBuildSettings(file: StaticString = #file, line: UInt = #line) {
        let buildSettingsTester = PIFBuildSettingsTester(
            buildSettings: baseTarget.buildConfigurations.first!.impartedBuildProperties.buildSettings
        )
        buildSettingsTester.checkUncheckedSettings(file: file, line: line)
    }
}

public final class PIFTargetTester: PIFBaseTargetTester {
    private let target: PIF.Target
    public var productType: PIF.Target.ProductType { target.productType }
    public var productName: String { target.productName }

    fileprivate init(target: PIF.Target, targetMap: [PIF.GUID: PIF.BaseTarget], fileMap: [PIF.GUID: String]) {
        self.target = target
        super.init(baseTarget: target, targetMap: targetMap, fileMap: fileMap)
    }
}

public final class PIFAggregateTargetTester: PIFBaseTargetTester {
    private let target: PIF.AggregateTarget

    fileprivate init(target: PIF.AggregateTarget, targetMap: [PIF.GUID: PIF.BaseTarget], fileMap: [PIF.GUID: String]) {
        self.target = target
        super.init(baseTarget: target, targetMap: targetMap, fileMap: fileMap)
    }
}

public final class PIFBuildConfigurationTester {
    private let buildConfiguration: PIF.BuildConfiguration

    public var guid: PIF.GUID { buildConfiguration.guid }
    public var name: String { buildConfiguration.name }

    fileprivate init(buildConfiguration: PIF.BuildConfiguration) {
        self.buildConfiguration = buildConfiguration
    }

    public func checkBuildSettings(file: StaticString = #file, line: UInt = #line, _ body: (PIFBuildSettingsTester) -> Void) {
        let buildSettingsTester = PIFBuildSettingsTester(buildSettings: buildConfiguration.buildSettings)
        body(buildSettingsTester)
    }

    public func checkAllBuildSettings(file: StaticString = #file, line: UInt = #line, _ body: (PIFBuildSettingsTester) -> Void) {
        let buildSettingsTester = PIFBuildSettingsTester(buildSettings: buildConfiguration.buildSettings)
        body(buildSettingsTester)
        buildSettingsTester.checkUncheckedSettings(file: file, line: line)
    }

    public func checkNoBuildSettings(file: StaticString = #file, line: UInt = #line) {
        let buildSettingsTester = PIFBuildSettingsTester(buildSettings: buildConfiguration.buildSettings)
        buildSettingsTester.checkUncheckedSettings(file: file, line: line)
    }
}

public final class PIFBuildSettingsTester {
    private var buildSettings: PIF.BuildSettings

    fileprivate init(buildSettings: PIF.BuildSettings) {
        self.buildSettings = buildSettings
    }

    public subscript(_ key: PIF.BuildSettings.SingleValueSetting) -> String? {
        if let value = buildSettings[key] {
            buildSettings[key] = nil
            return value
        } else {
            return nil
        }
    }

    public subscript(_ key: PIF.BuildSettings.SingleValueSetting, for platform: PIF.BuildSettings.Platform) -> String? {
        if let value = buildSettings[key, for: platform] {
            buildSettings[key, for: platform] = nil
            return value
        } else {
            return nil
        }
    }

    public subscript(_ key: PIF.BuildSettings.MultipleValueSetting) -> [String]? {
        if let value = buildSettings[key] {
            buildSettings[key] = nil
            return value
        } else {
            return nil
        }
    }

    public subscript(_ key: PIF.BuildSettings.MultipleValueSetting, for platform: PIF.BuildSettings.Platform) -> [String]? {
        if let value = buildSettings[key, for: platform] {
            buildSettings[key, for: platform] = nil
            return value
        } else {
            return nil
        }
    }

    public func checkUncheckedSettings(file: StaticString = #file, line: UInt = #line) {
        let uncheckedKeys =
            Array(buildSettings.singleValueSettings.keys.map { $0.rawValue }) +
            Array(buildSettings.multipleValueSettings.keys.map { $0.rawValue })
        XCTAssert(uncheckedKeys.isEmpty, "settings are left unchecked: \(uncheckedKeys)", file: file, line: line)

        for (platform, settings) in buildSettings.platformSpecificSingleValueSettings {
            let uncheckedKeys = Array(settings.keys.map { $0.rawValue })
            XCTAssert(uncheckedKeys.isEmpty, "\(platform) settings are left unchecked: \(uncheckedKeys)", file: file, line: line)
        }

        for (platform, settings) in buildSettings.platformSpecificMultipleValueSettings {
            let uncheckedKeys = Array(settings.keys.map { $0.rawValue })
            XCTAssert(uncheckedKeys.isEmpty, "\(platform) settings are left unchecked: \(uncheckedKeys)", file: file, line: line)
        }
    }
}

private func collectFiles(
    from reference: PIF.Reference,
    parentPath: AbsolutePath,
    projectPath: AbsolutePath,
    builtProductsPath: AbsolutePath
) throws -> [PIF.GUID: String] {
    let referencePath: AbsolutePath
    switch reference.sourceTree {
    case .absolute:
        referencePath = try AbsolutePath(validating: reference.path)
    case .group:
        referencePath = try AbsolutePath(validating: reference.path, relativeTo: parentPath)
    case .sourceRoot:
        referencePath = try AbsolutePath(validating: reference.path, relativeTo: projectPath)
    case .builtProductsDir:
        referencePath = try AbsolutePath(validating: reference.path, relativeTo: builtProductsPath)
    }

    var files: [PIF.GUID: String] = [:]

    if reference is PIF.FileReference {
        assert(files[reference.guid] == nil, "non-unique GUID")
        files[reference.guid] = referencePath.pathString
    } else if let group = reference as? PIF.Group {
        for child in group.children {
            let childFiles = try collectFiles(
                from: child,
                parentPath: referencePath,
                projectPath: projectPath,
                builtProductsPath: builtProductsPath
            )
            files.merge(childFiles, uniquingKeysWith: { _, _ in fatalError("non-unique GUID") })
        }
    }

    return files
}
