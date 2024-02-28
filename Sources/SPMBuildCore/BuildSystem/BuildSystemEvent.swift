//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2018-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@_spi(SwiftPMInternal)
public enum BuildSystemEvent {
    /// Called when build command is about to start.
    case willStart(command: BuildSystemCommand)

    /// Called when build command did start.
    case didStart(command: BuildSystemCommand)

    /// Called when build task did update progress.
    case didUpdateTaskProgress(text: String)

    /// Called when build command did finish.
    case didFinish(command: BuildSystemCommand)

    case didDetectCycleInRules

    /// Called when build did finish.
    case didFinishWithResult(success: Bool)

    /// Called when build did cancel
    case didCancel
}
