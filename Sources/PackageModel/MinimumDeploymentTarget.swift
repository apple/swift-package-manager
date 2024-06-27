//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics

import class Basics.AsyncProcess

public struct MinimumDeploymentTarget {
    private struct MinimumDeploymentTargetKey: Hashable {
        let binaryPath: AbsolutePath
        let platform: PackageModel.Platform
    }

    private let minimumDeploymentTargets = ThreadSafeKeyValueStore<MinimumDeploymentTargetKey,PlatformVersion>()
    private let xcTestMinimumDeploymentTargets = ThreadSafeKeyValueStore<PackageModel.Platform,PlatformVersion>()

    public static let `default`: MinimumDeploymentTarget = .init()

    private init() {
    }

    public func computeMinimumDeploymentTarget(of binaryPath: AbsolutePath, platform: PackageModel.Platform) throws -> PlatformVersion {
        try self.minimumDeploymentTargets.memoize(MinimumDeploymentTargetKey(binaryPath: binaryPath, platform: platform)) {
            return try Self.computeMinimumDeploymentTarget(of: binaryPath, platform: platform) ?? platform.oldestSupportedVersion
        }
    }

    public func computeXCTestMinimumDeploymentTarget(for platform: PackageModel.Platform) -> PlatformVersion {
        self.xcTestMinimumDeploymentTargets.memoize(platform) {
            return Self.computeXCTestMinimumDeploymentTarget(for: platform)
        }
    }

    static func computeMinimumDeploymentTarget(of binaryPath: AbsolutePath, platform: PackageModel.Platform) throws -> PlatformVersion? {
        guard let (_, platformName) = platform.sdkNameAndPlatform else {
            return nil
        }

        let runResult = try AsyncProcess.popen(arguments: ["/usr/bin/xcrun", "vtool", "-show-build", binaryPath.pathString])
        var lines = try runResult.utf8Output().components(separatedBy: "\n")
        while !lines.isEmpty {
            let first = lines.removeFirst()
            if first.contains("platform \(platformName)"), let line = lines.first, line.contains("minos") {
                return line.components(separatedBy: " ").last.map(PlatformVersion.init(stringLiteral:))
            }
        }
        return nil
    }

    static func computeXCTestMinimumDeploymentTarget(with runResult: AsyncProcessResult, platform: PackageModel.Platform) throws -> PlatformVersion? {
        guard let output = try runResult.utf8Output().spm_chuzzle() else { return nil }
        let sdkPath = try AbsolutePath(validating: output)
        let xcTestPath = try AbsolutePath(validating: "Developer/Library/Frameworks/XCTest.framework/XCTest", relativeTo: sdkPath)
        return try computeMinimumDeploymentTarget(of: xcTestPath, platform: platform)
    }

    static func computeXCTestMinimumDeploymentTarget(for platform: PackageModel.Platform) -> PlatformVersion {
        guard let (sdkName, _) = platform.sdkNameAndPlatform else {
            return platform.oldestSupportedVersion
        }

        // On macOS, we are determining the deployment target by looking at the XCTest binary.
        #if os(macOS)
        do {
            let runResult = try AsyncProcess.popen(arguments: ["/usr/bin/xcrun", "--sdk", sdkName, "--show-sdk-platform-path"])

            if let version = try computeXCTestMinimumDeploymentTarget(with: runResult, platform: platform) {
                return version
            }
        } catch { } // we do not treat this a fatal and instead use the fallback minimum deployment target
        #endif

        return platform.oldestSupportedVersion
    }
}

private extension PackageModel.Platform {
    var sdkNameAndPlatform: (String, String)? {
        switch self {
        case .macOS:
            return ("macosx", "MACOS")
        case .macCatalyst:
            return ("macosx", "MACCATALYST")
        case .iOS:
            return ("iphoneos", "IOS")
        case .tvOS:
            return ("appletvos", "TVOS")
        case .watchOS:
            return ("watchos", "WATCHOS")
        case .visionOS:
            return ("xros", "XROS")
        case .driverKit:
            return nil // DriverKit does not support XCTest.
        default:
            return nil
        }
    }
}
