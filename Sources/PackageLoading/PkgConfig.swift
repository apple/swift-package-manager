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

import Basics
import Foundation
import OrderedCollections

import class Basics.AsyncProcess

/// Information on an individual `pkg-config` supported package.
public struct PkgConfig {
    /// The name of the package.
    public let name: String

    /// The path to the definition file.
    public let pcFile: AbsolutePath

    /// The list of C compiler flags in the definition.
    public let cFlags: [String]

    /// The list of libraries to link.
    public let libs: [String]

    /// Load the information for the named package.
    ///
    /// It will search `fileSystem` for the pkg config file in the following order:
    /// * Paths defined in `PKG_CONFIG_PATH` environment variable
    /// * Paths defined in `additionalSearchPaths` argument
    /// * Built-in search paths (see `PCFileFinder.searchPaths`)
    ///
    /// - parameter name: Name of the pkg config file (without file extension).
    /// - parameter additionalSearchPaths: Additional paths to search for pkg config file.
    /// - parameter fileSystem: The file system to use
    ///
    /// - throws: PkgConfigError
    public init(
        name: String,
        additionalSearchPaths: [AbsolutePath]? = .none,
        brewPrefix: AbsolutePath? = .none,
        sysrootDir: AbsolutePath? = .none,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws {
        try self.init(
            name: name,
            additionalSearchPaths: additionalSearchPaths ?? [],
            brewPrefix: brewPrefix,
            sysrootDir: sysrootDir,
            loadingContext: LoadingContext(),
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )
    }

    private init(
        name: String,
        additionalSearchPaths: [AbsolutePath],
        brewPrefix: AbsolutePath?,
        sysrootDir: AbsolutePath?,
        loadingContext: LoadingContext,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws {
        loadingContext.pkgConfigStack.append(name)

        if let path = try? AbsolutePath(validating: name) {
            guard fileSystem.isFile(path) else { throw PkgConfigError.couldNotFindConfigFile(name: name) }
            self.name = path.basenameWithoutExt
            self.pcFile = path
        } else {
            self.name = name
            let pkgFileFinder = PCFileFinder(brewPrefix: brewPrefix)
            self.pcFile = try pkgFileFinder.locatePCFile(
                name: name,
                customSearchPaths: try PkgConfig.envSearchPaths + additionalSearchPaths,
                fileSystem: fileSystem,
                observabilityScope: observabilityScope
            )
        }

        var parser = try PkgConfigParser(pcFile: pcFile, fileSystem: fileSystem, sysrootDir: Environment.current["PKG_CONFIG_SYSROOT_DIR"])
        try parser.parse()

        func getFlags(from dependencies: [String]) throws -> (cFlags: [String], libs: [String]) {
            var cFlags = [String]()
            var libs = [String]()

            for dep in dependencies {
                if let index = loadingContext.pkgConfigStack.firstIndex(of: dep) {
                    observabilityScope.emit(warning: "circular dependency detected while parsing \(loadingContext.pkgConfigStack[0]): \(loadingContext.pkgConfigStack[index..<loadingContext.pkgConfigStack.count].joined(separator: " -> ")) -> \(dep)")
                    continue
                }

                // FIXME: This is wasteful, we should be caching the PkgConfig result.
                let pkg = try PkgConfig(
                    name: dep,
                    additionalSearchPaths: additionalSearchPaths,
                    brewPrefix: brewPrefix,
                    sysrootDir: sysrootDir,
                    loadingContext: loadingContext,
                    fileSystem: fileSystem,
                    observabilityScope: observabilityScope
                )

                cFlags += pkg.cFlags
                libs += pkg.libs
            }

            return (cFlags: cFlags, libs: libs)
        }

        let dependencyFlags = try getFlags(from: parser.dependencies)
        let privateDependencyFlags = try getFlags(from: parser.privateDependencies)

        self.cFlags = parser.cFlags + dependencyFlags.cFlags + privateDependencyFlags.cFlags
        self.libs = parser.libs + dependencyFlags.libs

        loadingContext.pkgConfigStack.removeLast();
    }

    private static var envSearchPaths: [AbsolutePath] {
        get throws {
            if let configPath = Environment.current["PKG_CONFIG_PATH"] {
                #if os(Windows)
                return try configPath.split(separator: ";").map({ try AbsolutePath(validating: String($0)) })
                #else
                return try configPath.split(separator: ":").map({ try AbsolutePath(validating: String($0)) })
                #endif
            }
            return []
        }
    }
}

extension PkgConfig {
    /// Information to track circular dependencies and other PkgConfig issues
    public class LoadingContext {
        public init() {
            pkgConfigStack = [String]()
        }

        public var pkgConfigStack: [String]
    }
}


/// Parser for the `pkg-config` `.pc` file format.
///
/// See: https://www.freedesktop.org/wiki/Software/pkg-config/
// This is only internal so it can be unit tested.
internal struct PkgConfigParser {
    public let pcFile: AbsolutePath
    private let fileSystem: FileSystem
    public private(set) var variables = [String: String]()
    public private(set) var dependencies = [String]()
    public private(set) var privateDependencies = [String]()
    public private(set) var cFlags = [String]()
    public private(set) var libs = [String]()
    public private(set) var sysrootDir: String?

    public init(pcFile: AbsolutePath, fileSystem: FileSystem, sysrootDir: String?) throws {
        guard fileSystem.isFile(pcFile) else {
            throw StringError("invalid pcfile \(pcFile)")
        }
        self.pcFile = pcFile
        self.fileSystem = fileSystem
        self.sysrootDir = sysrootDir
    }

    // Compress repeated path separators to one.
    private func compressPathSeparators(_ value: String) -> String {
        let components = value.components(separatedBy: "/").filter { !$0.isEmpty }.joined(separator: "/")
        if value.hasPrefix("/") {
            return "/" + components
        } else {
            return components
        }
    }

    // Trim duplicate sysroot prefixes, matching the approach of pkgconf
    private func trimDuplicateSysroot(_ value: String) -> String {
        // If sysroot has been applied more than once, remove the first instance.
        // pkgconf makes this check after variable expansion to handle rare .pc
        // files which expand ${pc_sysrootdir} directly:
        //    https://github.com/pkgconf/pkgconf/issues/123
        //
        // For example:
        //       /sysroot/sysroot/remainder -> /sysroot/remainder
        //
        // However, pkgconf's algorithm searches for an additional sysrootdir anywhere in
        // the string after the initial prefix, rather than looking for two sysrootdir prefixes
        // directly next to each other:
        //
        //     /sysroot/filler/sysroot/remainder -> /filler/sysroot/remainder
        //
        // It might seem more logical not to strip sysroot in this case, as it is not a double
        // prefix, but for compatibility trimDuplicateSysroot is faithful to pkgconf's approach
        // in the functions `pkgconf_tuple_parse` and `should_rewrite_sysroot`.

        // Only trim if sysroot is defined with a meaningful value
        guard let sysrootDir, sysrootDir != "/" else {
           return value
        }

        // Only trim absolute paths starting with sysroot
        guard value.hasPrefix("/"), value.hasPrefix(sysrootDir) else {
            return value
        }

        // If sysroot appears multiple times, trim the prefix
        // N.B. sysroot can appear anywhere in the remainder
        // of the value, mirroring pkgconf's logic
        let pathSuffix = value.dropFirst(sysrootDir.count)
        if pathSuffix.contains(sysrootDir) {
            return String(pathSuffix)
        } else {
            return value
        }
    }

    // Apply sysroot to generated paths, matching the approach of pkgconf
    private func applySysroot(_ value: String) -> String {
        // The two main pkg-config implementations handle sysroot differently:
        //
        //     `pkg-config` (freedesktop.org) prepends sysroot after variable expansion, when in creates the compiler flag lists
        //     `pkgconf` prepends sysroot to variables when they are defined, so sysroot is included when they are expanded
        //
        // pkg-config's method skips single character compiler flags, such as '-I' and '-L', and has special cases for longer options.
        // It does not handle spaces between the flags and their values properly, and prepends sysroot multiple times in some cases,
        // such as when the .pc file uses the sysroot_dir variable directly or has been rewritten to hard-code the sysroot prefix.
        //
        // pkgconf's method handles spaces correctly, although it also requires extra checks to ensure that sysroot is not applied
        // more than once.
        //
        // In 2024 pkg-config is the more popular option according to Homebrew installation statistics, but the major Linux distributions
        // have generally switched to pkgconf.
        //
        // We will use pkgconf's method here as it seems more robust than pkg-config's, and pkgconf's greater popularity on Linux
        // means libraries developed there may depend on the specific way it handles .pc files.

        if value.hasPrefix("/"), let sysrootDir, !value.hasPrefix(sysrootDir) {
            return compressPathSeparators(trimDuplicateSysroot(sysrootDir + value))
        } else {
            return compressPathSeparators(trimDuplicateSysroot(value))
        }
    }

    public mutating func parse() throws {
        func removeComment(line: String) -> String {
            if let commentIndex = line.firstIndex(of: "#") {
                return String(line[line.startIndex..<commentIndex])
            }
            return line
        }

        // Add pcfiledir variable. This is the path of the directory containing this pc file.
        variables["pcfiledir"] = pcFile.parentDirectory.pathString

        // Add pc_sysrootdir variable. This is the path of the sysroot directory for pc files.
        // pkgconf does not define pc_sysrootdir if the path of the .pc file is outside sysrootdir.
        // SwiftPM does not currently make that check.
        variables["pc_sysrootdir"] = sysrootDir ?? AbsolutePath.root.pathString

        let fileContents: String = try fileSystem.readFileContents(pcFile)
        for line in fileContents.components(separatedBy: "\n") {
            // Remove commented or any trailing comment from the line.
            let uncommentedLine = removeComment(line: line)
            // Ignore any empty or whitespace line.
            guard let line = uncommentedLine.spm_chuzzle() else { continue }

            if line.contains(":") {
                // Found a key-value pair.
                try parseKeyValue(line: line)
            } else if line.contains("=") {
                // Found a variable.
                let (name, maybeValue) = line.spm_split(around: "=")
                let value = maybeValue?.spm_chuzzle() ?? ""
                variables[name.spm_chuzzle() ?? ""] = try applySysroot(resolveVariables(value))
            } else {
                // Unexpected thing in the pc file, abort.
                throw PkgConfigError.parsingError("Unexpected line: \(line) in \(pcFile)")
            }
        }
    }

    private mutating func parseKeyValue(line: String) throws {
        guard line.contains(":") else {
            throw InternalError("invalid pcfile, expecting line to contain :")
        }
        let (key, maybeValue) = line.spm_split(around: ":")
        let value = try resolveVariables(maybeValue?.spm_chuzzle() ?? "")
        switch key.lowercased() {
        case "requires":
            dependencies = try parseDependencies(value)
        case "requires.private":
            privateDependencies = try parseDependencies(value)
        case "libs":
            libs = try splitEscapingSpace(value)
        case "cflags":
            cFlags = try splitEscapingSpace(value)
        default:
            break
        }
    }

    /// Parses `Requires: ` string into array of dependencies.
    ///
    /// The dependency string has separator which can be (multiple) space or a
    /// comma. Additionally each there can be an optional version constraint to
    /// a dependency.
    private func parseDependencies(_ depString: String) throws -> [String] {
        let operators = ["=", "<", ">", "<=", ">="]
        let separators = [" ", ","]

        // Look at a char at an index if present.
        func peek(idx: Int) -> Character? {
            guard idx <= depString.count - 1 else { return nil }
            return depString[depString.index(depString.startIndex, offsetBy: idx)]
        }

        // This converts the string which can be separated by comma or spaces
        // into an array of string.
        func tokenize() -> [String] {
            var tokens = [String]()
            var token = ""
            for (idx, char) in depString.enumerated() {
                // Encountered a separator, use the token.
                if separators.contains(String(char)) {
                    // If next character is a space skip.
                    if let peeked = peek(idx: idx+1), peeked == " " { continue }
                    // Append to array of tokens and reset token variable.
                    tokens.append(token)
                    token = ""
                } else {
                    token += String(char)
                }
            }
            // Append the last collected token if present.
            if !token.isEmpty { tokens += [token] }
            return tokens
        }

        var deps = [String]()
        var it = tokenize().makeIterator()
        while let arg = it.next() {
            // If we encounter an operator then we need to skip the next token.
            if operators.contains(arg) {
                // We should have a version number next, skip.
                guard it.next() != nil else {
                    throw PkgConfigError.parsingError("""
                        Expected version number after \(deps.last.debugDescription) \(arg) in \"\(depString)\" in \
                        \(pcFile)
                        """)
                }
            } else if !arg.isEmpty {
                // Otherwise it is a dependency.
                deps.append(arg)
            }
        }
        return deps
    }

    /// Perform variable expansion on the line by processing the each fragment
    /// of the string until complete.
    ///
    /// Variables occur in form of ${variableName}, we search for a variable
    /// linearly in the string and if found, lookup the value of the variable in
    /// our dictionary and replace the variable name with its value.
    private func resolveVariables(_ line: String) throws -> String {
        // Returns variable name, start index and end index of a variable in a string if present.
        // We make sure it of form ${name} otherwise it is not a variable.
        func findVariable(_ fragment: String)
            -> (name: String, startIndex: String.Index, endIndex: String.Index)? {
            guard let dollar = fragment.firstIndex(of: "$"),
                  dollar != fragment.endIndex && fragment[fragment.index(after: dollar)] == "{",
                  let variableEndIndex = fragment.firstIndex(of: "}")
            else { return nil }
            return (String(fragment[fragment.index(dollar, offsetBy: 2)..<variableEndIndex]), dollar, variableEndIndex)
        }

        var result = ""
        var fragment = line
        while !fragment.isEmpty {
            // Look for a variable in our current fragment.
            if let variable = findVariable(fragment) {
                // Append the contents before the variable.
                result += fragment[fragment.startIndex..<variable.startIndex]
                guard let variableValue = variables[variable.name] else {
                    throw PkgConfigError.parsingError(
                        "Expected a value for variable '\(variable.name)' in \(pcFile). Variables: \(variables)")
                }
                // Append the value of the variable.
                result += variableValue
                // Update the fragment with post variable string.
                fragment = String(fragment[fragment.index(after: variable.endIndex)...])
            } else {
                // No variable found, just append rest of the fragment to result.
                result += fragment
                fragment = ""
            }
        }
        return String(result)
    }

    /// Split line on unescaped spaces.
    ///
    /// Will break on space in "abc def" and "abc\\ def" but not in "abc\ def"
    /// and ignore multiple spaces such that "abc def" will split into ["abc",
    /// "def"].
    private func splitEscapingSpace(_ line: String) throws -> [String] {
        var splits = [String]()
        var fragment = [Character]()

        func saveFragment() {
            if !fragment.isEmpty {
                splits.append(String(fragment))
                fragment.removeAll()
            }
        }

        var it = line.makeIterator()
        // Indicates if we're in a quoted fragment, we shouldn't append quote.
        var inQuotes = false
        while let char = it.next() {
            if char == "\"" {
                inQuotes = !inQuotes
            } else if char == "\\" {
                if let next = it.next() {
#if os(Windows)
                    if ![" ", "\\"].contains(next) { fragment.append("\\") }
#endif
                    fragment.append(next)
                }
            } else if char == " " && !inQuotes {
                saveFragment()
            } else {
                fragment.append(char)
            }
        }
        guard !inQuotes else {
            throw PkgConfigError.parsingError(
                "Text ended before matching quote was found in line: \(line) file: \(pcFile)")
        }
        saveFragment()
        return splits
    }
}

// This is only internal so it can be unit tested.
internal struct PCFileFinder {
    /// Cached results of locations `pkg-config` will search for `.pc` files
    /// FIXME: This shouldn't use a static variable, since the first lookup
    /// will cache the result of whatever `brewPrefix` was passed in.  It is
    /// also not threadsafe.
    public private(set) static var pkgConfigPaths: [AbsolutePath]? // FIXME: @testable(internal)
    private static var shouldEmitPkgConfigPathsDiagnostic = false

    /// The built-in search path list.
    ///
    /// By default, this is combined with the search paths inferred from
    /// `pkg-config` itself.
    static let searchPaths = [
        try? AbsolutePath(validating: "/usr/local/lib/pkgconfig"),
        try? AbsolutePath(validating: "/usr/local/share/pkgconfig"),
        try? AbsolutePath(validating: "/usr/lib/pkgconfig"),
        try? AbsolutePath(validating: "/usr/share/pkgconfig"),
    ].compactMap({ $0 })

    /// Get search paths from `pkg-config` itself to locate `.pc` files.
    ///
    /// This is needed because on Linux machines, the search paths can be different
    /// from the standard locations that we are currently searching.
    private init(pkgConfigPath: String) {
        if PCFileFinder.pkgConfigPaths == nil {
            do {
                let searchPaths = try AsyncProcess.checkNonZeroExit(args:
                    pkgConfigPath, "--variable", "pc_path", "pkg-config"
                ).spm_chomp()

#if os(Windows)
                PCFileFinder.pkgConfigPaths = try searchPaths.split(separator: ";").map({ try AbsolutePath(validating: String($0)) })
#else
                PCFileFinder.pkgConfigPaths = try searchPaths.split(separator: ":").map({ try AbsolutePath(validating: String($0)) })
#endif
            } catch {
                PCFileFinder.shouldEmitPkgConfigPathsDiagnostic = true
                PCFileFinder.pkgConfigPaths = []
            }
        }
    }

    public init(brewPrefix: AbsolutePath?) {
        self.init(pkgConfigPath: brewPrefix?.appending(components: "bin", "pkg-config").pathString ?? "pkg-config")
    }

    public init(pkgConfig: AbsolutePath? = .none) {
        self.init(pkgConfigPath: pkgConfig?.pathString ?? "pkg-config")
    }

    /// Reset the cached `pkgConfigPaths` property, so that it will be evaluated
    /// again when instantiating a `PCFileFinder()`.  This is intended only for
    /// use by testing.  This is a temporary workaround for the use of a static
    /// variable by this class.
    internal static func resetCachedPkgConfigPaths() {
        PCFileFinder.pkgConfigPaths = nil
    }

    public func locatePCFile(
        name: String,
        customSearchPaths: [AbsolutePath],
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> AbsolutePath {
        // FIXME: We should consider building a registry for all items in the
        // search paths, which is likely to be substantially more efficient if
        // we end up searching for a reasonably sized number of packages.
        for path in OrderedSet(customSearchPaths + PCFileFinder.pkgConfigPaths! + PCFileFinder.searchPaths) {
            let pcFile = path.appending(component: name + ".pc")
            if fileSystem.isFile(pcFile) {
                return pcFile
            }
        }
        if PCFileFinder.shouldEmitPkgConfigPathsDiagnostic {
            PCFileFinder.shouldEmitPkgConfigPathsDiagnostic = false
            observabilityScope.emit(warning: "failed to retrieve search paths with pkg-config; maybe pkg-config is not installed")
        }
        throw PkgConfigError.couldNotFindConfigFile(name: name)
    }
}

internal enum PkgConfigError: Swift.Error, CustomStringConvertible {
    case couldNotFindConfigFile(name: String)
    case parsingError(String)
    case prohibitedFlags(String)

    public var description: String {
        switch self {
        case .couldNotFindConfigFile(let name):
            return "couldn't find pc file for \(name)"
        case .parsingError(let error):
            return "parsing error(s): \(error)"
        case .prohibitedFlags(let flags):
            return "prohibited flag(s): \(flags)"
        }
    }
}
