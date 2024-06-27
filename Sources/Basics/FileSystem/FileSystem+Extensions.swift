//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct Foundation.Data
import class Foundation.FileManager
import struct Foundation.UUID
import SystemPackage

import struct TSCBasic.ByteString
import struct TSCBasic.FileInfo
import class TSCBasic.FileLock
import enum TSCBasic.FileMode
import protocol TSCBasic.FileSystem
import enum TSCBasic.FileSystemAttribute
import var TSCBasic.localFileSystem
import protocol TSCBasic.WritableByteStream

public typealias FileSystem = TSCBasic.FileSystem
public let localFileSystem = TSCBasic.localFileSystem

// MARK: - Custom path

extension FileSystem {
    /// Check whether the given path exists and is accessible.
    public func exists(_ path: AbsolutePath, followSymlink: Bool) -> Bool {
        self.exists(path.underlying, followSymlink: followSymlink)
    }

    /// exists override with default value.
    public func exists(_ path: AbsolutePath) -> Bool {
        self.exists(path.underlying)
    }

    /// Check whether the given path is accessible and a directory.
    public func isDirectory(_ path: AbsolutePath) -> Bool {
        self.isDirectory(path.underlying)
    }

    /// Check whether the given path is accessible and a file.
    public func isFile(_ path: AbsolutePath) -> Bool {
        self.isFile(path.underlying)
    }

    /// Check whether the given path is an accessible and executable file.
    public func isExecutableFile(_ path: AbsolutePath) -> Bool {
        self.isExecutableFile(path.underlying)
    }

    /// Check whether the given path is accessible and is a symbolic link.
    public func isSymlink(_ path: AbsolutePath) -> Bool {
        self.isSymlink(path.underlying)
    }

    /// Check whether the given path is accessible and readable.
    public func isReadable(_ path: AbsolutePath) -> Bool {
        self.isReadable(path.underlying)
    }

    /// Check whether the given path is accessible and writable.
    public func isWritable(_ path: AbsolutePath) -> Bool {
        self.isWritable(path.underlying)
    }

    /// Returns `true` if a given path has a quarantine attribute applied if when file system supports this attribute.
    /// Returns `false` if such attribute is not applied or it isn't supported.
    public func hasAttribute(_ name: FileSystemAttribute, _ path: AbsolutePath) -> Bool {
        self.hasAttribute(name, path.underlying)
    }

    /// Get the contents of the given directory, in an undefined order.
    public func getDirectoryContents(_ path: AbsolutePath) throws -> [String] {
        try self.getDirectoryContents(path.underlying)
    }

    /// Get the current working directory (similar to `getcwd(3)`), which can be
    /// different for different (virtualized) implementations of a FileSystem.
    /// The current working directory can be empty if e.g. the directory became
    /// unavailable while the current process was still working in it.
    /// This follows the POSIX `getcwd(3)` semantics.
    public var currentWorkingDirectory: AbsolutePath? {
        self.currentWorkingDirectory.flatMap { AbsolutePath($0) }
    }

    /// Change the current working directory.
    /// - Parameters:
    ///   - path: The path to the directory to change the current working directory to.
    public func changeCurrentWorkingDirectory(to path: AbsolutePath) throws {
        try self.changeCurrentWorkingDirectory(to: path.underlying)
    }

    /// Get the home directory of current user
    public var homeDirectory: AbsolutePath {
        get throws {
            try AbsolutePath(self.homeDirectory)
        }
    }

    /// Get the caches directory of current user
    public var cachesDirectory: AbsolutePath? {
        self.cachesDirectory.flatMap { AbsolutePath($0) }
    }

    /// Get the temp directory
    public var tempDirectory: AbsolutePath {
        get throws {
            try AbsolutePath(self.tempDirectory)
        }
    }

    /// Create the given directory.
    public func createDirectory(_ path: AbsolutePath) throws {
        try self.createDirectory(path.underlying)
    }

    /// Create the given directory.
    ///
    /// - recursive: If true, create missing parent directories if possible.
    public func createDirectory(_ path: AbsolutePath, recursive: Bool) throws {
        try self.createDirectory(path.underlying, recursive: recursive)
    }

    /// Creates a symbolic link of the source path at the target path
    /// - Parameters:
    ///   - path: The path at which to create the link.
    ///   - destination: The path to which the link points to.
    ///   - relative: If `relative` is true, the symlink contents will be a relative path, otherwise it will be
    /// absolute.
    public func createSymbolicLink(_ path: AbsolutePath, pointingAt destination: AbsolutePath, relative: Bool) throws {
        try self.createSymbolicLink(path.underlying, pointingAt: destination.underlying, relative: relative)
    }

    /// Get the contents of a file.
    ///
    /// - Returns: The file contents as bytes, or nil if missing.
    public func readFileContents(_ path: AbsolutePath) throws -> ByteString {
        try self.readFileContents(path.underlying)
    }

    /// Write the contents of a file.
    public func writeFileContents(_ path: AbsolutePath, bytes: ByteString) throws {
        try self.writeFileContents(path.underlying, bytes: bytes)
    }

    /// Write the contents of a file.
    public func writeFileContents(_ path: AbsolutePath, bytes: ByteString, atomically: Bool) throws {
        try self.writeFileContents(path.underlying, bytes: bytes, atomically: atomically)
    }

    /// Write to a file from a stream producer.
    public func writeFileContents(_ path: AbsolutePath, body: (WritableByteStream) -> Void) throws {
        try self.writeFileContents(path.underlying, body: body)
    }

    /// Recursively deletes the file system entity at `path`.
    ///
    /// If there is no file system entity at `path`, this function does nothing (in particular, this is not considered
    /// to be an error).
    public func removeFileTree(_ path: AbsolutePath) throws {
        try self.removeFileTree(path.underlying)
    }

    /// Change file mode.
    public func chmod(_ mode: FileMode, path: AbsolutePath, options: Set<FileMode.Option>) throws {
        try self.chmod(mode, path: path.underlying, options: options)
    }

    // Change file mode.
    public func chmod(_ mode: FileMode, path: AbsolutePath) throws {
        try self.chmod(mode, path: path.underlying)
    }

    /// Returns the file info of the given path.
    ///
    /// The method throws if the underlying stat call fails.
    public func getFileInfo(_ path: AbsolutePath) throws -> FileInfo {
        try self.getFileInfo(path.underlying)
    }

    /// Copy a file or directory.
    public func copy(from source: AbsolutePath, to destination: AbsolutePath) throws {
        try self.copy(from: source.underlying, to: destination.underlying)
    }

    /// Move a file or directory.
    public func move(from source: AbsolutePath, to destination: AbsolutePath) throws {
        try self.move(from: source.underlying, to: destination.underlying)
    }

    /// Execute the given block while holding the lock.
    public func withLock<T>(on path: AbsolutePath, type: FileLock.LockType, blocking: Bool = true, _ body: () throws -> T) throws -> T {
        try self.withLock(on: path.underlying, type: type, blocking: blocking, body)
    }

    /// Returns any known item replacement directories for a given path. These may be used by platform-specific
    /// libraries to handle atomic file system operations, such as deletion.
    func itemReplacementDirectories(for path: AbsolutePath) throws -> [AbsolutePath] {
        return try self.itemReplacementDirectories(for: path.underlying).compactMap { AbsolutePath($0) }
    }
}

// MARK: - user level

extension FileSystem {
    /// SwiftPM directory under user's home directory (~/.swiftpm)
    /// or under $XDG_CONFIG_HOME/swiftpm if the environmental variable is defined
    public var dotSwiftPM: AbsolutePath {
        get throws {
            if let configurationDirectory = Environment.current["XDG_CONFIG_HOME"] {
                return try AbsolutePath(validating: configurationDirectory).appending("swiftpm")
            } else {
                return try self.homeDirectory.appending(".swiftpm")
            }
        }
    }

    private var idiomaticSwiftPMDirectory: AbsolutePath? {
        get throws {
            try FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
                .flatMap { try AbsolutePath(validating: $0.path) }?.appending("org.swift.swiftpm")
        }
    }
}

// MARK: - cache

extension FileSystem {
    private var idiomaticUserCacheDirectory: AbsolutePath? {
        // in TSC: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        self.cachesDirectory
    }

    /// SwiftPM cache directory under user's caches directory (if exists)
    public var swiftPMCacheDirectory: AbsolutePath {
        get throws {
            if let path = self.idiomaticUserCacheDirectory {
                return path.appending("org.swift.swiftpm")
            } else {
                return try self.dotSwiftPMCachesDirectory
            }
        }
    }

    private var dotSwiftPMCachesDirectory: AbsolutePath {
        get throws {
            try self.dotSwiftPM.appending("cache")
        }
    }
}

extension FileSystem {
    public func getOrCreateSwiftPMCacheDirectory() throws -> AbsolutePath {
        let idiomaticCacheDirectory = try self.swiftPMCacheDirectory
        // Create idiomatic if necessary
        if !self.exists(idiomaticCacheDirectory) {
            try self.createDirectory(idiomaticCacheDirectory, recursive: true)
        }
        // Create ~/.swiftpm if necessary
        if !self.exists(try self.dotSwiftPM) {
            try self.createDirectory(self.dotSwiftPM, recursive: true)
        }
        // Create ~/.swiftpm/cache symlink if necessary
        // locking ~/.swiftpm to protect from concurrent access
        try self.withLock(on: self.dotSwiftPM, type: .exclusive) {
            if !self.exists(try self.dotSwiftPMCachesDirectory, followSymlink: false) {
                try self.createSymbolicLink(
                    dotSwiftPMCachesDirectory,
                    pointingAt: idiomaticCacheDirectory,
                    relative: false
                )
            }
        }
        return idiomaticCacheDirectory
    }
}

extension FileSystem {
    private var dotSwiftPMInstalledBinsDir: AbsolutePath {
        get throws {
            try self.dotSwiftPM.appending("bin")
        }
    }

    public func getOrCreateSwiftPMInstalledBinariesDirectory() throws -> AbsolutePath {
        let idiomaticInstalledBinariesDirectory = try self.dotSwiftPMInstalledBinsDir
        // Create idiomatic if necessary
        if !self.exists(idiomaticInstalledBinariesDirectory) {
            try self.createDirectory(idiomaticInstalledBinariesDirectory, recursive: true)
        }
        // Create ~/.swiftpm if necessary
        if !self.exists(try self.dotSwiftPM) {
            try self.createDirectory(self.dotSwiftPM, recursive: true)
        }
        // Create ~/.swiftpm/bin symlink if necessary
        // locking ~/.swiftpm to protect from concurrent access
        try self.withLock(on: self.dotSwiftPM, type: .exclusive) {
            if !self.exists(try self.dotSwiftPMInstalledBinsDir, followSymlink: false) {
                try self.createSymbolicLink(
                    self.dotSwiftPMInstalledBinsDir,
                    pointingAt: idiomaticInstalledBinariesDirectory,
                    relative: false
                )
            }
        }
        return idiomaticInstalledBinariesDirectory
    }
}

// MARK: - configuration

extension FileSystem {
    /// SwiftPM config directory under user's config directory (if exists)
    public var swiftPMConfigurationDirectory: AbsolutePath {
        get throws {
            if let path = try self.idiomaticSwiftPMDirectory {
                return path.appending("configuration")
            } else {
                return try self.dotSwiftPMConfigurationDirectory
            }
        }
    }

    private var dotSwiftPMConfigurationDirectory: AbsolutePath {
        get throws {
            try self.dotSwiftPM.appending("configuration")
        }
    }
}

extension FileSystem {
    public func getOrCreateSwiftPMConfigurationDirectory(warningHandler: @escaping (String) -> Void) throws
        -> AbsolutePath
    {
        let idiomaticConfigurationDirectory = try self.swiftPMConfigurationDirectory

        // temporary 5.6, remove on next version: transition from previous configuration location
        if !self.exists(idiomaticConfigurationDirectory) {
            try self.createDirectory(idiomaticConfigurationDirectory, recursive: true)
        }

        let handleExistingFiles = { (configurationFiles: [AbsolutePath]) in
            for file in configurationFiles {
                let destination = idiomaticConfigurationDirectory.appending(component: file.basename)
                if !self.exists(destination) {
                    try self.copy(from: file, to: destination)
                } else {
                    // Only emit a warning if source and destination file differ in their contents.
                    let srcContents = try? self.readFileContents(file)
                    let dstContents = try? self.readFileContents(destination)
                    if srcContents != dstContents {
                        warningHandler(
                            "Usage of \(file) has been deprecated. Please delete it and use the new \(destination) instead."
                        )
                    }
                }
            }
        }

        // in the case where ~/.swiftpm/configuration is not the idiomatic location (eg on macOS where its
        // /Users/<user>/Library/org.swift.swiftpm/configuration)
        if try idiomaticConfigurationDirectory != self.dotSwiftPMConfigurationDirectory {
            // copy the configuration files from old location (eg /Users/<user>/Library/org.swift.swiftpm) to new one
            // (eg /Users/<user>/Library/org.swift.swiftpm/configuration)
            // but leave them there for backwards compatibility (eg older xcode)
            let oldConfigDirectory = idiomaticConfigurationDirectory.parentDirectory
            if self.exists(oldConfigDirectory, followSymlink: false) && self.isDirectory(oldConfigDirectory) {
                let configurationFiles = try self.getDirectoryContents(oldConfigDirectory)
                    .map { oldConfigDirectory.appending(component: $0) }
                    .filter {
                        self.isFile($0) && !self.isSymlink($0) && $0
                            .extension != "lock" && ((try? self.readFileContents($0)) ?? []).count > 0
                    }
                try handleExistingFiles(configurationFiles)
            }
            // in the case where ~/.swiftpm/configuration is the idiomatic location (eg on Linux)
        } else {
            // copy the configuration files from old location (~/.swiftpm/config) to new one (~/.swiftpm/configuration)
            // but leave them there for backwards compatibility (eg older toolchain)
            let oldConfigDirectory = try self.dotSwiftPM.appending("config")
            if self.exists(oldConfigDirectory, followSymlink: false) && self.isDirectory(oldConfigDirectory) {
                let configurationFiles = try self.getDirectoryContents(oldConfigDirectory)
                    .map { oldConfigDirectory.appending(component: $0) }
                    .filter {
                        self.isFile($0) && !self.isSymlink($0) && $0
                            .extension != "lock" && ((try? self.readFileContents($0)) ?? []).count > 0
                    }
                try handleExistingFiles(configurationFiles)
            }
        }
        // ~temporary 5.6 migration

        // Create idiomatic if necessary
        if !self.exists(idiomaticConfigurationDirectory) {
            try self.createDirectory(idiomaticConfigurationDirectory, recursive: true)
        }
        // Create ~/.swiftpm if necessary
        if !self.exists(try self.dotSwiftPM) {
            try self.createDirectory(self.dotSwiftPM, recursive: true)
        }
        // Create ~/.swiftpm/configuration symlink if necessary
        // locking ~/.swiftpm to protect from concurrent access
        try self.withLock(on: self.dotSwiftPM, type: .exclusive) {
            if !self.exists(try self.dotSwiftPMConfigurationDirectory, followSymlink: false) {
                try self.createSymbolicLink(
                    dotSwiftPMConfigurationDirectory,
                    pointingAt: idiomaticConfigurationDirectory,
                    relative: false
                )
            }
        }

        return idiomaticConfigurationDirectory
    }
}

// MARK: - security

extension FileSystem {
    /// SwiftPM security directory under user's security directory (if exists)
    public var swiftPMSecurityDirectory: AbsolutePath {
        get throws {
            if let path = try self.idiomaticSwiftPMDirectory {
                return path.appending("security")
            } else {
                return try self.dotSwiftPMSecurityDirectory
            }
        }
    }

    private var dotSwiftPMSecurityDirectory: AbsolutePath {
        get throws {
            try self.dotSwiftPM.appending("security")
        }
    }
}

extension FileSystem {
    public func getOrCreateSwiftPMSecurityDirectory() throws -> AbsolutePath {
        let idiomaticSecurityDirectory = try self.swiftPMSecurityDirectory

        // temporary 5.6, remove on next version: transition from ~/.swiftpm/security to idiomatic location + symbolic
        // link
        if try idiomaticSecurityDirectory != self.dotSwiftPMSecurityDirectory &&
            self.exists(try self.dotSwiftPMSecurityDirectory) &&
            self.isDirectory(try self.dotSwiftPMSecurityDirectory)
        {
            try self.removeFileTree(self.dotSwiftPMSecurityDirectory)
        }
        // ~temporary 5.6 migration

        // Create idiomatic if necessary
        if !self.exists(idiomaticSecurityDirectory) {
            try self.createDirectory(idiomaticSecurityDirectory, recursive: true)
        }
        // Create ~/.swiftpm if necessary
        if !self.exists(try self.dotSwiftPM) {
            try self.createDirectory(self.dotSwiftPM, recursive: true)
        }
        // Create ~/.swiftpm/security symlink if necessary
        // locking ~/.swiftpm to protect from concurrent access
        try self.withLock(on: self.dotSwiftPM, type: .exclusive) {
            if !self.exists(try self.dotSwiftPMSecurityDirectory, followSymlink: false) {
                try self.createSymbolicLink(
                    dotSwiftPMSecurityDirectory,
                    pointingAt: idiomaticSecurityDirectory,
                    relative: false
                )
            }
        }
        return idiomaticSecurityDirectory
    }
}

// MARK: - Swift SDKs

private let swiftSDKsDirectoryName = "swift-sdks"

extension FileSystem {
    /// Path to Swift SDKs directory (if exists)
    public var swiftSDKsDirectory: AbsolutePath {
        get throws {
            if let path = try idiomaticSwiftPMDirectory {
                return path.appending(component: swiftSDKsDirectoryName)
            } else {
                return try dotSwiftPMSwiftSDKsDirectory
            }
        }
    }

    private var dotSwiftPMSwiftSDKsDirectory: AbsolutePath {
        get throws {
            try dotSwiftPM.appending(component: swiftSDKsDirectoryName)
        }
    }

    public func getSharedSwiftSDKsDirectory(explicitDirectory: AbsolutePath?) throws -> AbsolutePath {
        if let explicitDirectory {
            // Create the explicit SDKs path if necessary
            if !exists(explicitDirectory) {
                try createDirectory(explicitDirectory, recursive: true)
            }
            return explicitDirectory
        } else {
            return try swiftSDKsDirectory
        }
    }

    public func getOrCreateSwiftPMSwiftSDKsDirectory() throws -> AbsolutePath {
        let idiomaticSwiftSDKDirectory = try swiftSDKsDirectory

        // Create idiomatic if necessary
        if !exists(idiomaticSwiftSDKDirectory) {
            try createDirectory(idiomaticSwiftSDKDirectory, recursive: true)
        }
        // Create ~/.swiftpm if necessary
        if !exists(try dotSwiftPM) {
            try createDirectory(dotSwiftPM, recursive: true)
        }
        // Create ~/.swiftpm/swift-sdks symlink if necessary
        // locking ~/.swiftpm to protect from concurrent access
        try withLock(on: dotSwiftPM, type: .exclusive) {
            if !exists(try dotSwiftPMSwiftSDKsDirectory, followSymlink: false) {
                try createSymbolicLink(
                    dotSwiftPMSwiftSDKsDirectory,
                    pointingAt: idiomaticSwiftSDKDirectory,
                    relative: false
                )
            }
        }
        return idiomaticSwiftSDKDirectory
    }
}

// MARK: - Utilities

extension FileSystem {
    @_disfavoredOverload
    public func readFileContents(_ path: AbsolutePath) throws -> Data {
        try Data(self.readFileContents(path).contents)
    }

    @_disfavoredOverload
    public func readFileContents(_ path: AbsolutePath) throws -> String {
        try String(decoding: self.readFileContents(path), as: UTF8.self)
    }

    public func writeFileContents(_ path: AbsolutePath, data: Data) throws {
        try self._writeFileContents(path, bytes: .init(data))
    }

    public func writeFileContents(_ path: AbsolutePath, string: String) throws {
        try self._writeFileContents(path, bytes: .init(encodingAsUTF8: string))
    }

    private func _writeFileContents(_ path: AbsolutePath, bytes: ByteString) throws {
        // using the "body" variant since it creates the directory first
        // we should probably fix TSC to be consistent about this behavior
        try self.writeFileContents(path, body: { $0.send(bytes) })
    }
}

extension FileSystem {
    /// Write bytes to the path if the given contents are different.
    public func writeIfChanged(path: AbsolutePath, string: String) throws {
        try writeIfChanged(path: path, bytes: .init(encodingAsUTF8: string))
    }

    public func writeIfChanged(path: AbsolutePath, data: Data) throws {
        try writeIfChanged(path: path, bytes: .init(data))
    }

    /// Write bytes to the path if the given contents are different.
    public func writeIfChanged(path: AbsolutePath, bytes: ByteString) throws {
        try createDirectory(path.parentDirectory, recursive: true)

        // Return if the contents are same.
        if isFile(path), try readFileContents(path) == bytes {
            return
        }

        try writeFileContents(path, bytes: bytes)
    }
}

extension FileSystem {
    public func forceCreateDirectory(at path: AbsolutePath) throws {
        try self.createDirectory(path.parentDirectory, recursive: true)
        if self.exists(path) {
            try self.removeFileTree(path)
        }
        try self.createDirectory(path, recursive: true)
    }
}

extension FileSystem {
    public func stripFirstLevel(of path: AbsolutePath) throws {
        let topLevelDirectories = try self.getDirectoryContents(path)
            .map { path.appending(component: $0) }
            .filter { self.isDirectory($0) }

        guard topLevelDirectories.count == 1, let rootDirectory = topLevelDirectories.first else {
            throw StringError("stripFirstLevel requires single top level directory")
        }

        let tempDirectory = path.parentDirectory.appending(component: UUID().uuidString)
        try self.move(from: rootDirectory, to: tempDirectory)

        let rootContents = try self.getDirectoryContents(tempDirectory)
        for entry in rootContents {
            try self.move(from: tempDirectory.appending(component: entry), to: path.appending(component: entry))
        }

        try self.removeFileTree(tempDirectory)
    }
}

// MARK: - Locking

extension FileLock {
    public static func prepareLock(
        fileToLock: AbsolutePath,
        at lockFilesDirectory: AbsolutePath? = nil
    ) throws -> FileLock {
        return try Self.prepareLock(fileToLock: fileToLock.underlying, at: lockFilesDirectory?.underlying)
    }
}

/// Convenience initializers for testing purposes.
extension InMemoryFileSystem {
    /// Create a new file system with the given files, provided as a map from
    /// file path to contents.
    public convenience init(files: [String: ByteString]) {
        self.init()

        for (path, contents) in files {
            let path = try! AbsolutePath(validating: path)
            try! createDirectory(path.parentDirectory, recursive: true)
            try! writeFileContents(path, bytes: contents)
        }
    }

    /// Create a new file system with an empty file at each provided path.
    public convenience init(emptyFiles files: String...) {
        self.init(emptyFiles: files)
    }

    /// Create a new file system with an empty file at each provided path.
    public convenience init(emptyFiles files: [String]) {
        self.init()
        self.createEmptyFiles(at: .root, files: files)
    }
}

extension FileSystem {
    public func createEmptyFiles(at root: AbsolutePath, files: String...) {
        self.createEmptyFiles(at: root, files: files)
    }

    public func createEmptyFiles(at root: AbsolutePath, files: [String]) {
        do {
            try createDirectory(root, recursive: true)
            for path in files {
                let path = try AbsolutePath(validating: String(path.dropFirst()), relativeTo: root)
                try createDirectory(path.parentDirectory, recursive: true)
                try writeFileContents(path, bytes: "")
            }
        } catch {
            fatalError("Failed to create empty files: \(error)")
        }
    }
}
