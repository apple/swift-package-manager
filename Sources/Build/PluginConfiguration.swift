//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2015-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct Basics.AbsolutePath
import protocol SPMBuildCore.PluginScriptRunner

public struct PluginConfiguration {
    /// Entity responsible for compiling and running plugin scripts.
    let scriptRunner: PluginScriptRunner

    /// Directory where plugin intermediate files are stored.
    let workDirectory: AbsolutePath

    /// Whether to sandbox commands from build tool plugins.
    let disableSandbox: Bool

    public init(scriptRunner: PluginScriptRunner, workDirectory: AbsolutePath, disableSandbox: Bool) {
        self.scriptRunner = scriptRunner
        self.workDirectory = workDirectory
        self.disableSandbox = disableSandbox
    }
}
