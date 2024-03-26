//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

/// The diagnostic triggered when the package has a newer tools version than the installed tools.
public struct RequireNewerTools: Error, CustomStringConvertible {
    /// The identity of the package.
    public let packageIdentity: PackageIdentity

    /// The version of the package.
    public let packageVersion: String?

    /// The installed tools version.
    public let installedToolsVersion: ToolsVersion

    /// The tools version of the package.
    public let packageToolsVersion: ToolsVersion

    public init(
        packageIdentity: PackageIdentity,
        packageVersion: String? = nil,
        installedToolsVersion: ToolsVersion,
        packageToolsVersion: ToolsVersion
    ) {
        self.packageIdentity = packageIdentity
        self.packageVersion = packageVersion
        self.installedToolsVersion = installedToolsVersion
        self.packageToolsVersion = packageToolsVersion
    }

    public var description: String {
        var text = "package '\(self.packageIdentity)'"
        if let packageVersion {
            text += " @ \(packageVersion)"
        }
        text += " is using Swift tools version \(packageToolsVersion.description) but the installed version is \(installedToolsVersion.description)"
        return text
    }
}

/// The diagnostic triggered when the package has an unsupported tools version.
public struct UnsupportedToolsVersion: Error, CustomStringConvertible {
    /// The identity of the package.
    public let packageIdentity: PackageIdentity

    /// The version of the package.
    public let packageVersion: String?

    /// The current tools version support by the tools.
    public let currentToolsVersion: ToolsVersion

    /// The tools version of the package.
    public let packageToolsVersion: ToolsVersion

    fileprivate var hintString: String {
        return "consider using '\(currentToolsVersion.specification(roundedTo: .minor))' to specify the current tools version"
    }

    public init(
        packageIdentity: PackageIdentity,
        packageVersion: String? = nil,
        currentToolsVersion: ToolsVersion,
        packageToolsVersion: ToolsVersion
    ) {
        self.packageIdentity = packageIdentity
        self.packageVersion = packageVersion
        self.currentToolsVersion = currentToolsVersion
        self.packageToolsVersion = packageToolsVersion
    }

    public var description: String {
        var text = "package '\(self.packageIdentity)'"
        if let packageVersion {
            text += " @ \(packageVersion)"
        }
        text += " is using Swift tools version \(packageToolsVersion.description) which is no longer supported; \(hintString)"
        return text
    }
}

public struct InvalidToolchainDiagnostic: Error, CustomStringConvertible {
    public let error: String

    public init(_ error: String) {
        self.error = error
    }

    public var description: String {
        "toolchain is invalid: \(error)"
    }
}
