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

import enum TSCBasic.JSON

extension Triple {
    public init(_ description: String) throws {
        self.init(description, normalizing: false)
    }
}

extension Triple {
    public static let macOS = try! Self("x86_64-apple-macosx")
}

extension Triple {
    public var isWasm: Bool {
        [.wasm32, .wasm64].contains(self.arch)
    }

    public func isApple() -> Bool {
        vendor == .apple
    }

    public func isAndroid() -> Bool {
        os == .linux && environment == .android
    }

    public func isDarwin() -> Bool {
        switch (vendor, os) {
        case (.apple, .noneOS):
            return false
        case (.apple, _), (_, .macosx), (_, .darwin):
            return true
        default:
            return false
        }
    }

    public func isLinux() -> Bool {
        os == .linux
    }

    public func isWindows() -> Bool {
        os == .win32
    }

    public func isWASI() -> Bool {
        os == .wasi
    }

    public func isOpenBSD() -> Bool {
        os == .openbsd
    }

    /// Returns the triple string for the given platform version.
    ///
    /// This is currently meant for Apple platforms only.
    public func tripleString(forPlatformVersion version: String) -> String {
        precondition(isDarwin())
        return """
            \(self.archName)-\
            \(self.vendorName)-\
            \(self.osNameUnversioned)\(version)\
            \(self.environmentName.isEmpty ? "" : "-\(self.environmentName)")
            """
    }

    public var tripleString: String {
        self.triple
    }

    /// Determine the versioned host triple using the Swift compiler.
    public static func getHostTriple(usingSwiftCompiler swiftCompiler: AbsolutePath) throws -> Triple {
        // Call the compiler to get the target info JSON.
        let compilerOutput: String
        do {
            let result = try AsyncProcess.popen(args: swiftCompiler.pathString, "-print-target-info")
            compilerOutput = try result.utf8Output().spm_chomp()
        } catch {
            throw InternalError("Failed to get target info (\(error.interpolationDescription))")
        }
        // Parse the compiler's JSON output.
        let parsedTargetInfo: JSON
        do {
            parsedTargetInfo = try JSON(string: compilerOutput)
        } catch {
            throw InternalError(
                "Failed to parse target info (\(error.interpolationDescription)).\nRaw compiler output: \(compilerOutput)"
            )
        }
        // Get the triple string from the parsed JSON.
        let tripleString: String
        do {
            tripleString = try parsedTargetInfo.get("target").get("triple")
        } catch {
            throw InternalError(
                "Target info does not contain a triple string (\(error.interpolationDescription)).\nTarget info: \(parsedTargetInfo)"
            )
        }

        // Parse the triple string.
        do {
            return try Triple(tripleString)
        } catch {
            throw InternalError(
                "Failed to parse triple string (\(error.interpolationDescription)).\nTriple string: \(tripleString)"
            )
        }
    }
}

extension Triple {
    /// The file prefix for dynamic libraries
    public var dynamicLibraryPrefix: String {
        switch os {
        case .win32:
            return ""
        default:
            return "lib"
        }
    }

    /// The file extension for dynamic libraries (eg. `.dll`, `.so`, or `.dylib`)
    public var dynamicLibraryExtension: String {
        guard let os = self.os else {
            fatalError("Cannot create dynamic libraries unknown os.")
        }

        switch os {
        case _ where isDarwin():
            return ".dylib"
        case .linux, .openbsd:
            return ".so"
        case .win32:
            return ".dll"
        case .wasi:
            return ".wasm"
        default:
            fatalError("Cannot create dynamic libraries for os \"\(os)\".")
        }
    }

    public var executableExtension: String {
        guard !self.isWasm else {
            return ".wasm"
        }

        guard let os = self.os else {
            return ""
        }

        switch os {
        case _ where isDarwin():
            return ""
        case .linux, .openbsd:
            return ""
        case .win32:
            return ".exe"
        case .noneOS:
            return ""
        default:
            return ""
        }
    }

    /// The file extension for static libraries.
    public var staticLibraryExtension: String {
        ".a"
    }

    /// The file extension for Foundation-style bundle.
    public var nsbundleExtension: String {
        switch os {
        case _ where isDarwin():
            return ".bundle"
        default:
            // See: https://github.com/apple/swift-corelibs-foundation/blob/master/Docs/FHS%20Bundles.md
            return ".resources"
        }
    }

    /// Returns `true` if code compiled for `triple` can run on `self` value of ``Triple``.
    public func isRuntimeCompatible(with triple: Triple) -> Bool {
        guard self != triple else {
            return true
        }

        if
            self.arch == triple.arch &&
            self.vendor == triple.vendor &&
            self.os == triple.os &&
            self.environment == triple.environment
        {
            return self.osVersion >= triple.osVersion
        } else {
            return false
        }
    }
}

extension Triple: CustomStringConvertible {
    public var description: String { tripleString }
}

extension Triple: Equatable {
    public static func ==(lhs: Triple, rhs: Triple) -> Bool {
      lhs.arch == rhs.arch
        && lhs.vendor == rhs.vendor
        && lhs.os == rhs.os
        && lhs.environment == rhs.environment
        && lhs.osVersion == rhs.osVersion
    }
}
