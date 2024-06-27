//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct Basics.IdentifiableSet
import struct PackageModel.MinimumDeploymentTarget
import struct PackageModel.Platform
import struct PackageModel.PlatformVersion
import struct PackageModel.SupportedPlatform

/// Merging two sets of supported platforms, preferring the max constraint
func merge(into partial: inout [SupportedPlatform], platforms: [SupportedPlatform]) {
    for platformSupport in platforms {
        if let existing = partial.firstIndex(where: { $0.platform == platformSupport.platform }) {
            if partial[existing].version < platformSupport.version {
                partial.remove(at: existing)
                partial.append(platformSupport)
            }
        } else {
            partial.append(platformSupport)
        }
    }
}

public struct PlatformVersionProvider: Hashable {
    public enum Implementation: Hashable {
        case mergingFromModules(IdentifiableSet<ResolvedModule>)
        case customXCTestMinimumDeploymentTargets([PackageModel.Platform: PlatformVersion])
        case minimumDeploymentTargetDefault
    }

    private let implementation: Implementation

    public init(implementation: Implementation) {
        self.implementation = implementation
    }

    func derivedXCTestPlatformProvider(_ declared: PackageModel.Platform) -> PlatformVersion? {
        switch self.implementation {
        case .mergingFromModules(let targets):
            let platforms = targets.reduce(into: [SupportedPlatform]()) { partial, item in
                merge(
                    into: &partial,
                    platforms: [item.getSupportedPlatform(for: declared, usingXCTest: item.type == .test)]
                )
            }
            return platforms.first!.version

        case .customXCTestMinimumDeploymentTargets(let customXCTestMinimumDeploymentTargets):
            return customXCTestMinimumDeploymentTargets[declared]

        case .minimumDeploymentTargetDefault:
            return MinimumDeploymentTarget.default.computeXCTestMinimumDeploymentTarget(for: declared)
        }
    }

    /// Returns the supported platform instance for the given platform.
    func getDerived(declared: [SupportedPlatform], for platform: Platform, usingXCTest: Bool) -> SupportedPlatform {
        // derived platform based on known minimum deployment target logic
        if let declaredPlatform = declared.first(where: { $0.platform == platform }) {
            var version = declaredPlatform.version

            if usingXCTest,
               let xcTestMinimumDeploymentTarget = self.derivedXCTestPlatformProvider(platform),
               version < xcTestMinimumDeploymentTarget
            {
                version = xcTestMinimumDeploymentTarget
            }

            // If the declared version is smaller than the oldest supported one, we raise the derived version to that.
            if version < platform.oldestSupportedVersion {
                version = platform.oldestSupportedVersion
            }

            return SupportedPlatform(
                platform: declaredPlatform.platform,
                version: version,
                options: declaredPlatform.options
            )
        } else {
            let minimumSupportedVersion: PlatformVersion
            if usingXCTest,
               let xcTestMinimumDeploymentTarget = self.derivedXCTestPlatformProvider(platform),
               xcTestMinimumDeploymentTarget > platform.oldestSupportedVersion
            {
                minimumSupportedVersion = xcTestMinimumDeploymentTarget
            } else {
                minimumSupportedVersion = platform.oldestSupportedVersion
            }

            let oldestSupportedVersion: PlatformVersion
            if platform == .macCatalyst {
                let iOS = self.getDerived(declared: declared, for: .iOS, usingXCTest: usingXCTest)
                // If there was no deployment target specified for Mac Catalyst, fall back to the iOS deployment target.
                oldestSupportedVersion = max(minimumSupportedVersion, iOS.version)
            } else {
                oldestSupportedVersion = minimumSupportedVersion
            }

            return SupportedPlatform(
                platform: platform,
                version: oldestSupportedVersion,
                options: []
            )
        }
    }
}
