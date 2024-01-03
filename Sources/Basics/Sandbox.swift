//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import func TSCBasic.determineTempDirectory

public enum SandboxNetworkPermission: Equatable {
    case none
    case local(ports: [Int])
    case all(ports: [Int])
    case docker
    case unixDomainSocket

    fileprivate var domain: String? {
        switch self {
        case .none, .docker, .unixDomainSocket: return nil
        case .local: return "local"
        case .all: return "*"
        }
    }

    fileprivate var ports: [Int] {
        switch self {
        case .all(let ports): return ports
        case .local(let ports): return ports
        case .none, .docker, .unixDomainSocket: return []
        }
    }
}

public enum Sandbox {
    /// Applies a sandbox invocation to the given command line (if the platform supports it),
    /// and returns the modified command line. On platforms that don't support sandboxing, the
    /// command line is returned unmodified.
    ///
    /// - Parameters:
    ///   - command: The command line to sandbox (including executable as first argument)
    ///   - fileSystem: The file system instance to use.
    ///   - strictness: The basic strictness level of the standbox.
    ///   - writableDirectories: Paths under which writing should be allowed, even if they would otherwise be read-only based on the strictness or paths in `readOnlyDirectories`.
    ///   - readOnlyDirectories: Paths under which writing should be denied, even if they would have otherwise been allowed by the rules implied by the strictness level.
    public static func apply(
        command: [String],
        fileSystem: FileSystem,
        strictness: Strictness = .default,
        writableDirectories: [AbsolutePath] = [],
        readOnlyDirectories: [AbsolutePath] = [],
        allowNetworkConnections: [SandboxNetworkPermission] = []
    ) throws -> [String] {
        #if os(macOS)
        let profile = try macOSSandboxProfile(
            fileSystem: fileSystem,
            strictness: strictness,
            writableDirectories: writableDirectories,
            readOnlyDirectories: readOnlyDirectories,
            allowNetworkConnections: allowNetworkConnections
        )
        return ["/usr/bin/sandbox-exec", "-p", profile] + command
        #else
        // rdar://40235432, rdar://75636874 tracks implementing sandboxes for other platforms.
        return command
        #endif
    }

    /// Basic strictness level of a sandbox applied to a command line.
    public enum Strictness: Equatable {
        /// Blocks network access and all file system modifications.
        case `default`
        /// More lenient restrictions than the default, for compatibility with SwiftPM manifests using a tools version older than 5.3.
        case manifest_pre_53 // backwards compatibility for manifests
        /// Like `default`, but also makes temporary-files directories (such as `/tmp`) on the platform writable.
        case writableTemporaryDirectory
    }
}

// MARK: - macOS

#if os(macOS)
fileprivate let threadSafeDarwinCacheDirectories: [AbsolutePath] = {
    func GetConfStr(_ name: CInt) -> AbsolutePath? {
        let length: Int = confstr(name, nil, 0)

        let buffer: UnsafeMutableBufferPointer<CChar> = .allocate(capacity: length)
        defer { buffer.deallocate() }

        guard confstr(name, buffer.baseAddress, length) == length else { return nil }

        let value = String(cString: buffer.baseAddress!)
        guard value.hasSuffix("/") else { return nil }

        return try? resolveSymlinks(AbsolutePath(validating: value))
    }

    var directories: [AbsolutePath] = []
    try? directories.append(AbsolutePath(validating: "/private/var/tmp"))
    (try? TSCBasic.determineTempDirectory()).map { directories.append(AbsolutePath($0)) }
    GetConfStr(_CS_DARWIN_USER_TEMP_DIR).map { directories.append($0) }
    GetConfStr(_CS_DARWIN_USER_CACHE_DIR).map { directories.append($0) }
    return directories
}()

fileprivate func macOSSandboxProfile(
    fileSystem: FileSystem,
    strictness: Sandbox.Strictness,
    writableDirectories: [AbsolutePath],
    readOnlyDirectories: [AbsolutePath],
    allowNetworkConnections: [SandboxNetworkPermission]
) throws -> String {
    var contents = "(version 1)\n"

    // Deny everything by default.
    contents += "(deny default)\n"

    // Import the system sandbox profile.
    contents += "(import \"system.sb\")\n"

    // Allow reading all files; ideally we'd only allow the package directory and any dependencies,
    // but all kinds of system locations need to be accessible.
    contents += "(allow file-read*)\n"

    // This is needed to launch any processes.
    contents += "(allow process*)\n"
    
    // This is needed to use the UniformTypeIdentifiers API.
    contents += "(allow mach-lookup (global-name \"com.apple.lsd.mapdb\"))\n"

    if allowNetworkConnections.filter({ $0 != .none }).isEmpty == false {
        // this is used by the system for caching purposes and will lead to log spew if not allowed
        contents += "(allow file-write* (regex \"/Users/*/Library/Caches/*/Cache.db*\"))"

        // this allows the specific network connections, as well as resolving DNS
        contents += """
        (system-network)
        (allow network-outbound
            (literal "/private/var/run/mDNSResponder")
        """

        allowNetworkConnections.forEach {
            if let domain = $0.domain {
                $0.ports.forEach { port in
                    contents += "(remote ip \"\(domain):\(port)\")"
                }

                // empty list of ports means all are permitted
                if $0.ports.isEmpty {
                    contents += "(remote ip \"\(domain):*\")"
                }
            }

            switch $0 {
            case .docker:
                // specifically allow Docker by basename of the socket
                contents += "(remote unix-socket (regex \"*/docker.sock\"))"
            case .unixDomainSocket:
                // this allows unix domain sockets
                contents += "(remote unix-socket)"
            default:
                break
            }
        }

        contents += "\n)\n"
    }

    // The following accesses are only needed when interpreting the manifest (versus running a compiled version).
    if strictness == .manifest_pre_53 {
        // This is required by the Swift compiler.
        contents += "(allow sysctl*)\n"
    }

    // Allow writing only to certain directories.
    var writableDirectoriesExpression: [String] = []

    // The following accesses are only needed when interpreting the manifest (versus running a compiled version).
    if strictness == .manifest_pre_53 {
        writableDirectoriesExpression += threadSafeDarwinCacheDirectories.map {
            ##"(regex #"^\##($0.pathString)/org\.llvm\.clang.*")"##
        }
    }
    // Optionally allow writing to temporary directories (a lot of use of Foundation requires this).
    else if strictness == .writableTemporaryDirectory {
        // Add `subpath` expressions for the regular and the Foundation temporary directories.
        for tmpDir in ["/tmp", NSTemporaryDirectory()] {
            writableDirectoriesExpression += try [
                "(subpath \(resolveSymlinks(AbsolutePath(validating: tmpDir)).quotedAsSubpathForSandboxProfile))",
            ]
        }
    }

    // Emit rules for paths under which writing is allowed. Some of these expressions may be regular expressions and others literal subpaths.
    if writableDirectoriesExpression.count > 0 {
        contents += "(allow file-write*\n"
        for expression in writableDirectoriesExpression {
            contents += "    \(expression)\n"
        }
        contents += ")\n"
    }

    // Emit rules for paths under which writing should be disallowed, even if they would be covered by a previous rule to allow writing to them. A classic case is a package which is located under the temporary directory, which should be read-only even though the temporary directory as a whole is writable.
    if readOnlyDirectories.count > 0 {
        contents += "(deny file-write*\n"
        for path in readOnlyDirectories {
            contents += "    (subpath \(try resolveSymlinks(path).quotedAsSubpathForSandboxProfile))\n"
        }
        contents += ")\n"
    }

    // Emit rules for paths under which writing is allowed, even if they are descendants directories that are otherwise read-only.
    if writableDirectories.count > 0 {
        contents += "(allow file-write*\n"
        // For any explicit writable directories, also include the relevant item replacement directories so that Foundation APIs using atomic writes are not blocked by the sandbox.
        for path in writableDirectories + Set(writableDirectories.compactMap { try? fileSystem.itemReplacementDirectories(for: $0) }.flatMap { $0}) {
            contents += "    (subpath \(try resolveSymlinks(path).quotedAsSubpathForSandboxProfile))\n"
        }
        contents += ")\n"
    }

    return contents
}

extension AbsolutePath {
    /// Private computed property that returns a version of the path as a string quoted for use as a subpath in a .sb sandbox profile.
    fileprivate var quotedAsSubpathForSandboxProfile: String {
        "\"" + self.pathString
            .replacing("\\", with: "\\\\")
            .replacing("\"", with: "\\\"")
            + "\""
    }
}
#endif
