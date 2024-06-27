//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import class PackageModel.Module
import class PackageModel.Product

/// Triple for which code should be compiled for.
/// > Note: We're not using "host" and "target" triple terminology in this enum, as that clashes with build
/// > system "targets" and can lead to confusion in this context.
public enum BuildTriple: String {
    /// Triple for which build tools are compiled (the host triple).
    case tools = "tools"

    /// Triple of the destination platform for which end products are compiled (the target triple).
    case destination = "destination"
}

extension Module {
    var buildTriple: BuildTriple {
        if self.type == .macro || self.type == .plugin {
            .tools
        } else {
            .destination
        }
    }
}

extension Product {
    var buildTriple: BuildTriple {
        if self.type == .macro || self.type == .plugin {
            .tools
        } else {
            .destination
        }
    }
}
