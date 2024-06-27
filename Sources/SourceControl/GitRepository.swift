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

@_spi(ProcessEnvironmentBlockShim)
import Basics
import Dispatch
import class Foundation.NSLock

import struct TSCBasic.ByteString
import protocol TSCBasic.DiagnosticLocation
import struct TSCBasic.FileInfo
import enum TSCBasic.FileMode
import struct TSCBasic.FileSystemError
import class Basics.AsyncProcess
import struct Basics.AsyncProcessResult
import struct TSCBasic.RegEx

import protocol TSCUtility.DiagnosticLocationProviding
import enum TSCUtility.Git

// MARK: - GitShellHelper

/// Helper for shelling out to `git`
private struct GitShellHelper {
    private let cancellator: Cancellator

    init(cancellator: Cancellator) {
        self.cancellator = cancellator
    }

    /// Private function to invoke the Git tool with its default environment and given set of arguments.  The specified
    /// failure message is used only in case of error.  This function waits for the invocation to finish and returns the
    /// output as a string.
    func run(
        _ args: [String],
        environment: Environment = .init(Git.environmentBlock),
        outputRedirection: AsyncProcess.OutputRedirection = .collect
    ) throws -> String {
        let process = AsyncProcess(
            arguments: [Git.tool] + args,
            environment: environment,
            outputRedirection: outputRedirection
        )
        let result: AsyncProcessResult
        do {
            guard let terminationKey = self.cancellator.register(process) else {
                throw CancellationError() // terminating
            }
            defer { self.cancellator.deregister(terminationKey) }
            try process.launch()
            result = try process.waitUntilExit()
            guard result.exitStatus == .terminated(code: 0) else {
                throw GitShellError(result: result)
            }
            return try result.utf8Output().spm_chomp()
        } catch let error as GitShellError {
            throw error
        } catch {
            // Handle a failure to even launch the Git tool by synthesizing a result that we can wrap an error around.
            let result = AsyncProcessResult(
                arguments: process.arguments,
                environment: process.environment,
                exitStatus: .terminated(code: -1),
                output: .failure(error),
                stderrOutput: .failure(error)
            )
            throw GitShellError(result: result)
        }
    }
}

// MARK: - GitRepositoryProvider

/// A `git` repository provider.
public struct GitRepositoryProvider: RepositoryProvider, Cancellable {
    private let cancellator: Cancellator
    private let git: GitShellHelper

    private var repositoryCache = ThreadSafeKeyValueStore<String, Repository>()

    public init() {
        // helper to cancel outstanding processes
        self.cancellator = Cancellator(observabilityScope: .none)
        // helper to abstract shelling out to git
        self.git = GitShellHelper(cancellator: cancellator)
    }

    @discardableResult
    private func callGit(
        _ args: [String],
        environment: Environment = .init(Git.environmentBlock),
        repository: RepositorySpecifier,
        failureMessage: String = "",
        progress: FetchProgress.Handler? = nil
    ) throws -> String {
        if let progress {
            var stdoutBytes: [UInt8] = [], stderrBytes: [UInt8] = []
            do {
                // Capture stdout and stderr from the Git subprocess invocation, but also pass along stderr to the
                // handler. We count on it being line-buffered.
                let outputHandler = AsyncProcess.OutputRedirection.stream(stdout: { stdoutBytes += $0 }, stderr: {
                    stderrBytes += $0
                    gitFetchStatusFilter($0, progress: progress)
                })
                return try self.git.run(
                    args + ["--progress"],
                    environment: environment,
                    outputRedirection: outputHandler
                )
            } catch let error as GitShellError {
                let result = AsyncProcessResult(
                    arguments: error.result.arguments,
                    environment: error.result.environment,
                    exitStatus: error.result.exitStatus,
                    output: .success(stdoutBytes),
                    stderrOutput: .success(stderrBytes)
                )
                throw GitCloneError(repository: repository, message: failureMessage, result: result)
            }
        } else {
            do {
                return try self.git.run(args, environment: environment)
            } catch let error as GitShellError {
                throw GitCloneError(repository: repository, message: failureMessage, result: error.result)
            }
        }
    }

    @discardableResult
    private func callGit(
        _ args: String...,
        environment: Environment = .init(Git.environmentBlock),
        repository: RepositorySpecifier,
        failureMessage: String = "",
        progress: FetchProgress.Handler? = nil
    ) throws -> String {
        try callGit(
            args.map { $0 },
            environment: environment,
            repository: repository,
            failureMessage: failureMessage,
            progress: progress
        )
    }

    private func clone(
        _ repository: RepositorySpecifier,
        _ origin: String,
        _ destination: String,
        _ options: [String],
        progress: FetchProgress.Handler? = nil
    ) throws {
        let invocation: [String] = [
            "clone",
            // Enable symbolic links for Windows support.
            "-c", "core.symlinks=true",
            // Disable fsmonitor to avoid spawning a monitor process.
            "-c", "core.fsmonitor=false",
            // Enable long path support on Windows as otherwise we are limited
            // to 261 characters in the complete path.
            "-c", "core.longpaths=true",
        ] + options + [origin, destination]

        try self.callGit(
            invocation,
            repository: repository,
            failureMessage: "Failed to clone repository \(repository.location)",
            progress: progress
        )
    }

    public func fetch(
        repository: RepositorySpecifier,
        to path: Basics.AbsolutePath,
        progressHandler: FetchProgress.Handler? = nil
    ) throws {
        // Perform a bare clone.
        //
        // NOTE: We intentionally do not create a shallow clone here; the
        // expected cost of iterative updates on a full clone is less than on a
        // shallow clone.
        guard !localFileSystem.exists(path) else {
            throw InternalError("\(path) already exists")
        }

        try self.clone(
            repository,
            repository.location.gitURL,
            path.pathString,
            ["--mirror"],
            progress: progressHandler
        )
    }

    public func repositoryExists(at directory: Basics.AbsolutePath) -> Bool {
        return localFileSystem.isDirectory(directory)
    }

    public func isValidDirectory(_ directory: Basics.AbsolutePath) throws -> Bool {
        let result = try self.git.run(["-C", directory.pathString, "rev-parse", "--git-dir"])
        return result == ".git" || result == "." || result == directory.pathString
    }

    public func isValidDirectory(_ directory: Basics.AbsolutePath, for repository: RepositorySpecifier) throws -> Bool {
        let remoteURL = try self.git.run(["-C", directory.pathString, "config", "--get", "remote.origin.url"])
        return remoteURL == repository.url
    }

    public func copy(from sourcePath: Basics.AbsolutePath, to destinationPath: Basics.AbsolutePath) throws {
        try localFileSystem.copy(from: sourcePath, to: destinationPath)
    }

    public func open(repository: RepositorySpecifier, at path: Basics.AbsolutePath) -> Repository {
        let key = "\(repository)@\(path)"
        return self.repositoryCache.memoize(key) {
            GitRepository(git: self.git, path: path, isWorkingRepo: false)
        }
    }

    public func createWorkingCopy(
        repository: RepositorySpecifier,
        sourcePath: Basics.AbsolutePath,
        at destinationPath: Basics.AbsolutePath,
        editable: Bool
    ) throws -> WorkingCheckout {
        if editable {
            // For editable clones, i.e. the user is expected to directly work on them, first we create
            // a clone from our cache of repositories and then we replace the remote to the one originally
            // present in the bare repository.

            try self.clone(
                repository,
                sourcePath.pathString,
                destinationPath.pathString,
                ["--no-checkout"]
            )

            // The default name of the remote.
            let origin = "origin"
            // In destination repo remove the remote which will be pointing to the source repo.
            let clone = GitRepository(git: self.git, path: destinationPath)
            // Set the original remote to the new clone.
            try clone.setURL(remote: origin, url: repository.location.gitURL)
            // FIXME: This is unfortunate that we have to fetch to update remote's data.
            try clone.fetch()
        } else {
            // Clone using a shared object store with the canonical copy.
            //
            // We currently expect using shared storage here to be safe because we
            // only ever expect to attempt to use the working copy to materialize a
            // revision we selected in response to dependency resolution, and if we
            // re-resolve such that the objects in this repository changed, we would
            // only ever expect to get back a revision that remains present in the
            // object storage.

            try self.clone(
                repository,
                sourcePath.pathString,
                destinationPath.pathString,
                ["--shared", "--no-checkout"]
            )
        }
        return try self.openWorkingCopy(at: destinationPath)
    }

    public func workingCopyExists(at path: Basics.AbsolutePath) throws -> Bool {
        guard localFileSystem.exists(path) else {
            throw InternalError("\(path) does not exist")
        }

        let repo = GitRepository(git: self.git, path: path)
        return try repo.checkoutExists()
    }

    public func openWorkingCopy(at path: Basics.AbsolutePath) throws -> WorkingCheckout {
        GitRepository(git: self.git, path: path)
    }

    public func cancel(deadline: DispatchTime) throws {
        try self.cancellator.cancel(deadline: deadline)
    }
}

// MARK: - GitRepository

// FIXME: Currently, this class is serving two goals, it is the Repository
// interface used by `RepositoryProvider`, but is also a class which can be
// instantiated directly against non-RepositoryProvider controlled
// repositories. This may prove inconvenient if what is currently `Repository`
// becomes inconvenient or incompatible with the ideal interface for this
// class. It is possible we should rename `Repository` to something more
// abstract, and change the provider to just return an adaptor around this
// class.
//
/// A basic Git repository in the local file system (almost always a clone of a remote).  This class is thread safe.
public final class GitRepository: Repository, WorkingCheckout {
    /// A hash object.
    public struct Hash: Hashable {
        // FIXME: We should optimize this representation.
        let bytes: ByteString

        /// Create a hash from the given hexadecimal representation.
        ///
        /// - Returns; The hash, or nil if the identifier is invalid.
        public init?(_ identifier: String) {
            self.init(asciiBytes: ByteString(encodingAsUTF8: identifier).contents)
        }

        /// Create a hash from the given ASCII bytes.
        ///
        /// - Returns; The hash, or nil if the identifier is invalid.
        init?<C: Collection>(asciiBytes bytes: C) where C.Iterator.Element == UInt8 {
            if bytes.count != 40 {
                return nil
            }
            for byte in bytes {
                switch byte {
                case UInt8(ascii: "0") ... UInt8(ascii: "9"),
                     UInt8(ascii: "a") ... UInt8(ascii: "z"):
                    continue
                default:
                    return nil
                }
            }
            self.bytes = ByteString(bytes)
        }
    }

    /// A commit object.
    public struct Commit: Equatable {
        /// The object hash.
        public let hash: Hash

        /// The tree contained in the commit.
        public let tree: Hash
    }

    /// A tree object.
    public struct Tree {
        public enum Location: Hashable {
            case hash(Hash)
            case tag(String)
        }

        public struct Entry {
            public enum EntryType {
                case blob
                case commit
                case executableBlob
                case symlink
                case tree

                init?(mode: Int) {
                    // Although the mode is a full UNIX mode mask, there are
                    // only a limited set of allowed values.
                    switch mode {
                    case 0o040000:
                        self = .tree
                    case 0o100644:
                        self = .blob
                    case 0o100755:
                        self = .executableBlob
                    case 0o120000:
                        self = .symlink
                    case 0o160000:
                        self = .commit
                    default:
                        return nil
                    }
                }
            }

            /// The object location.
            public let location: Location

            /// The type of object referenced.
            public let type: EntryType

            /// The name of the object.
            public let name: String
        }

        /// The object location.
        public let location: Location

        /// The list of contents.
        public let contents: [Entry]
    }

    /// The path of the repository in the local file system.
    public let path: AbsolutePath

    /// Concurrent queue to execute git cli on.
    private let git: GitShellHelper

    // lock top protect concurrent modifications to the repository
    private let lock = NSLock()

    /// If this repo is a work tree repo (checkout) as opposed to a bare repo.
    private let isWorkingRepo: Bool

    /// Dictionary for memoizing results of git calls that are not expected to change.
    private var cachedHashes = ThreadSafeKeyValueStore<String, Hash>()
    private var cachedBlobs = ThreadSafeKeyValueStore<Hash, ByteString>()
    private var cachedTrees = ThreadSafeKeyValueStore<String, Tree>()
    private var cachedTags = ThreadSafeBox<[String]>()
    private var cachedBranches = ThreadSafeBox<[String]>()
    private var cachedIsBareRepo = ThreadSafeBox<Bool>()
    private var cachedHasSubmodules = ThreadSafeBox<Bool>()

    public convenience init(path: AbsolutePath, isWorkingRepo: Bool = true, cancellator: Cancellator? = .none) {
        // used in one-off operations on git repo, as such the terminator is not ver important
        let cancellator = cancellator ?? Cancellator(observabilityScope: .none)
        let git = GitShellHelper(cancellator: cancellator)
        self.init(git: git, path: path, isWorkingRepo: isWorkingRepo)
    }

    fileprivate init(git: GitShellHelper, path: AbsolutePath, isWorkingRepo: Bool = true) {
        self.git = git
        self.path = path
        self.isWorkingRepo = isWorkingRepo
        assert({
            // Ignore if we couldn't run popen for some reason.
            (try? self.isBare() != isWorkingRepo) ?? true
        }())
    }

    /// Private function to invoke the Git tool with its default environment and given set of arguments, specifying the
    /// path of the repository as the one to operate on.  The specified failure message is used only in case of error.
    /// This function waits for the invocation to finish and returns the output as a string.
    @discardableResult
    private func callGit(
        _ args: String...,
        environment: Environment = .init(Git.environmentBlock),
        failureMessage: String = "",
        progress: FetchProgress.Handler? = nil
    ) throws -> String {
        if let progress {
            var stdoutBytes: [UInt8] = [], stderrBytes: [UInt8] = []
            do {
                // Capture stdout and stderr from the Git subprocess invocation, but also pass along stderr to the
                // handler. We count on it being line-buffered.
                let outputHandler = AsyncProcess.OutputRedirection.stream(stdout: { stdoutBytes += $0 }, stderr: {
                    stderrBytes += $0
                    gitFetchStatusFilter($0, progress: progress)
                })
                return try self.git.run(
                    ["-C", self.path.pathString] + args,
                    environment: environment,
                    outputRedirection: outputHandler
                )
            } catch let error as GitShellError {
                let result = AsyncProcessResult(
                    arguments: error.result.arguments,
                    environment: error.result.environment,
                    exitStatus: error.result.exitStatus,
                    output: .success(stdoutBytes),
                    stderrOutput: .success(stderrBytes))
                throw GitRepositoryError(path: self.path, message: failureMessage, result: result)
            }
        } else {
            do {
                return try self.git.run(["-C", self.path.pathString] + args, environment: environment)
            } catch let error as GitShellError {
                throw GitRepositoryError(path: self.path, message: failureMessage, result: error.result)
            }
        }
    }

    /// Changes URL for the remote.
    ///
    /// - parameters:
    ///   - remote: The name of the remote to operate on. It should already be present.
    ///   - url: The new url of the remote.
    public func setURL(remote: String, url: String) throws {
        // use barrier for write operations
        try self.lock.withLock {
            try callGit(
                "remote",
                "set-url",
                remote,
                url,
                failureMessage: "Couldn’t set the URL of the remote ‘\(remote)’ to ‘\(url)’"
            )
        }
    }

    /// Gets the current list of remotes of the repository.
    ///
    /// - Returns: An array of tuple containing name and url of the remote.
    public func remotes() throws -> [(name: String, url: String)] {
        try self.lock.withLock {
            // Get the remote names.
            let remoteNamesOutput = try callGit(
                "remote",
                failureMessage: "Couldn’t get the list of remotes"
            )
            let remoteNames = remoteNamesOutput.split(whereSeparator: { $0.isNewline }).map(String.init)
            return try remoteNames.map { name in
                // For each remote get the url.
                let url = try callGit(
                    "config",
                    "--get",
                    "remote.\(name).url",
                    failureMessage: "Couldn’t get the URL of the remote ‘\(name)’"
                )
                return (name, url)
            }
        }
    }

    // MARK: Helpers for package search functionality

    public func getDefaultBranch() throws -> String {
        try callGit("rev-parse", "--abbrev-ref", "HEAD", failureMessage: "Couldn’t get the default branch")
    }

    public func getBranches() throws -> [String] {
        try self.cachedBranches.memoize {
            try self.lock.withLock {
                let branches = try callGit("branch", "-l", failureMessage: "Couldn’t get the list of branches")
                return branches.split(whereSeparator: { $0.isNewline }).map { $0.dropFirst(2) }.map(String.init)
            }
        }
    }

    // MARK: Repository Interface

    /// Returns the tags present in repository.
    public func getTags() throws -> [String] {
        // Get the contents using `ls-tree`.
        try self.cachedTags.memoize {
            try self.lock.withLock {
                let tagList = try callGit(
                    "tag",
                    "-l",
                    failureMessage: "Couldn’t get the list of tags"
                )
                return tagList.split(whereSeparator: { $0.isNewline }).map(String.init)
            }
        }
    }

    public func resolveRevision(tag: String) throws -> Revision {
        try Revision(identifier: self.resolveHash(treeish: tag, type: "commit").bytes.description)
    }

    public func resolveRevision(identifier: String) throws -> Revision {
        try Revision(identifier: self.resolveHash(treeish: identifier, type: "commit").bytes.description)
    }

    public func fetch() throws {
        try self.fetch(progress: nil)
    }

    public func fetch(progress: FetchProgress.Handler? = nil) throws {
        // use barrier for write operations
        try self.lock.withLock {
            try callGit(
                "remote",
                "-v",
                "update",
                "-p",
                failureMessage: "Couldn’t fetch updates from remote repositories",
                progress: progress
            )
            self.cachedTags.clear()
        }
    }

    public func hasUncommittedChanges() -> Bool {
        // Only a working repository can have changes.
        guard self.isWorkingRepo else { return false }
        return self.lock.withLock {
            guard let result = try? callGit("status", "-s") else {
                return false
            }
            return !result.isEmpty
        }
    }

    public func openFileView(revision: Revision) throws -> FileSystem {
        try GitFileSystemView(repository: self, revision: revision)
    }

    public func openFileView(tag: String) throws -> FileSystem {
        try GitFileSystemView(repository: self, tag: tag)
    }

    // MARK: Working Checkout Interface

    public func hasUnpushedCommits() throws -> Bool {
        try self.lock.withLock {
            let hasOutput = try callGit(
                "log",
                "--branches",
                "--not",
                "--remotes",
                failureMessage: "Couldn’t check for unpushed commits"
            ).isEmpty
            return !hasOutput
        }
    }

    public func getCurrentRevision() throws -> Revision {
        try self.lock.withLock {
            try Revision(identifier: callGit(
                "rev-parse",
                "--verify",
                "HEAD",
                failureMessage: "Couldn’t get current revision"
            ))
        }
    }

    public func getCurrentTag() -> String? {
        self.lock.withLock {
            try? callGit(
                "describe",
                "--exact-match",
                "--tags",
                failureMessage: "Couldn’t get current tag"
            )
        }
    }

    public func checkout(tag: String) throws {
        // FIXME: Audit behavior with off-branch tags in remote repositories, we
        // may need to take a little more care here.
        // use barrier for write operations
        try self.lock.withLock {
            try callGit(
                "reset",
                "--hard",
                tag,
                failureMessage: "Couldn’t check out tag ‘\(tag)’"
            )
            try self.updateSubmoduleAndCleanIfNecessary()
        }
    }

    public func checkout(revision: Revision) throws {
        // FIXME: Audit behavior with off-branch tags in remote repositories, we
        // may need to take a little more care here.
        // use barrier for write operations
        try self.lock.withLock {
            try callGit(
                "checkout",
                "-f",
                revision.identifier,
                failureMessage: "Couldn’t check out revision ‘\(revision.identifier)’"
            )
            try self.updateSubmoduleAndCleanIfNecessary()
        }
    }

    internal func isBare() throws -> Bool {
        return try self.cachedIsBareRepo.memoize(body: {
            let output = try callGit(
                "rev-parse",
                "--is-bare-repository",
                failureMessage: "Couldn’t test for bare repository"
            )

            return output == "true"
        })
    }

    internal func checkoutExists() throws -> Bool {
        return try !self.isBare()
    }

    private func updateSubmoduleAndCleanIfNecessary() throws {
        if self.cachedHasSubmodules.get(default: false) || localFileSystem.exists(self.path.appending(".gitmodules")) {
            self.cachedHasSubmodules.put(true)
            try self.updateSubmoduleAndCleanNotOnQueue()
        }
    }

    /// Initializes and updates the submodules, if any, and cleans left over the files and directories using git-clean.
    private func updateSubmoduleAndCleanNotOnQueue() throws {
        try self.callGit(
            "submodule",
            "update",
            "--init",
            "--recursive",
            failureMessage: "Couldn’t update repository submodules"
        )
        try self.callGit(
            "clean",
            "-ffdx",
            failureMessage: "Couldn’t clean repository submodules"
        )
    }

    /// Returns true if a revision exists.
    public func exists(revision: Revision) -> Bool {
        let output = try? callGit("rev-parse", "--verify", "\(revision.identifier)^{commit}")
        return output != nil
    }

    public func checkout(newBranch: String) throws {
        guard self.isWorkingRepo else {
            throw InternalError("This operation is only valid in a working repository")
        }
        // use barrier for write operations
        try self.lock.withLock {
            try callGit(
                "checkout",
                "-b",
                newBranch,
                failureMessage: "Couldn’t check out new branch ‘\(newBranch)’"
            )
        }
    }

    public func archive(to path: AbsolutePath) throws {
        guard self.isWorkingRepo else {
            throw InternalError("This operation is only valid in a working repository")
        }

        try self.lock.withLock {
            try callGit(
                "archive",
                "--format",
                "zip",
                "--prefix",
                "\(path.basenameWithoutExt)/",
                "--output",
                path.pathString,
                "HEAD",
                failureMessage: "Couldn’t create an archive"
            )
        }
    }

    /// Returns true if there is an alternative object store in the repository and it is valid.
    public func isAlternateObjectStoreValid(expected: AbsolutePath) -> Bool {
        let objectStoreFile = self.path.appending(components: ".git", "objects", "info", "alternates")
        guard let bytes = try? localFileSystem.readFileContents(objectStoreFile) else {
            return false
        }
        let split = bytes.contents.split(separator: UInt8(ascii: "\n"), maxSplits: 1, omittingEmptySubsequences: false)
        guard let firstLine = ByteString(split[0]).validDescription else {
            return false
        }
        guard let objectsPath = try? AbsolutePath(validating: firstLine), localFileSystem.isDirectory(objectsPath) else {
            return false
        }
        let repositoryPath = objectsPath.parentDirectory
        return expected == repositoryPath
    }

    /// Returns true if the file at `path` is ignored by `git`
    public func areIgnored(_ paths: [Basics.AbsolutePath]) throws -> [Bool] {
        try self.lock.withLock {
            let stringPaths = paths.map(\.pathString)

            let output: String
            do {
                output = try self.git.run(["-C", self.path.pathString, "check-ignore"] + stringPaths)
            } catch let error as GitShellError {
                guard error.result.exitStatus == .terminated(code: 1) else {
                    throw GitRepositoryError(
                        path: self.path,
                        message: "unable to check ignored files",
                        result: error.result
                    )
                }
                output = try error.result.utf8Output().spm_chomp()
            }

            return stringPaths.map(output.split(whereSeparator: { $0.isNewline }).map {
                let string = String($0).replacingOccurrences(of: "\\\\", with: "\\")
                if string.utf8.first == UInt8(ascii: "\"") {
                    return String(string.dropFirst(1).dropLast(1))
                }
                return string
            }.contains)
        }
    }

    // MARK: Git Operations

    /// Resolve a "treeish" to a concrete hash.
    ///
    /// Technically this method can accept much more than a "treeish", it maps
    /// to the syntax accepted by `git rev-parse`.
    public func resolveHash(treeish: String, type: String? = nil) throws -> Hash {
        let specifier: String
        if let type {
            specifier = treeish + "^{\(type)}"
        } else {
            specifier = treeish
        }
        return try self.cachedHashes.memoize(specifier) {
            try self.lock.withLock {
                let output = try callGit(
                    "rev-parse",
                    "--verify",
                    specifier,
                    failureMessage: "Couldn’t get revision ‘\(specifier)’"
                )
                guard let hash = Hash(output) else {
                    throw GitInterfaceError.malformedResponse("expected an object hash in \(output)")
                }
                return hash
            }
        }
    }

    /// Read the commit referenced by `hash`.
    public func readCommit(hash: Hash) throws -> Commit {
        // Currently, we just load the tree, using the typed `rev-parse` syntax.
        let treeHash = try resolveHash(treeish: hash.bytes.description, type: "tree")

        return Commit(hash: hash, tree: treeHash)
    }

    /// Read a tree object.
    public func readTree(location: Tree.Location) throws -> Tree {
        switch location {
        case .hash(let hash):
            return try self.readTree(hash: hash)
        case .tag(let tag):
            return try self.readTree(tag: tag)
        }
    }

    /// Read a tree object.
    public func readTree(hash: Hash) throws -> Tree {
        let hashString = hash.bytes.description
        return try self.cachedTrees.memoize(hashString) {
            try self.lock.withLock {
                let output = try callGit(
                    "ls-tree",
                    hashString,
                    failureMessage: "Couldn’t read '\(hashString)'"
                )
                let entries = try self.parseTree(output)
                return Tree(location: .hash(hash), contents: entries)
            }
        }
    }

    public func readTree(tag: String) throws -> Tree {
        try self.cachedTrees.memoize(tag) {
            try self.lock.withLock {
                let output = try callGit(
                    "ls-tree",
                    tag,
                    failureMessage: "Couldn’t read '\(tag)'"
                )
                let entries = try self.parseTree(output)
                return Tree(location: .tag(tag), contents: entries)
            }
        }
    }

    private func parseTree(_ text: String) throws -> [Tree.Entry] {
        var entries = [Tree.Entry]()
        for line in text.components(separatedBy: "\n") {
            // Ignore empty lines.
            if line == "" { continue }

            // Each line in the response should match:
            //
            //   `mode type hash\tname`
            //
            // where `mode` is the 6-byte octal file mode, `type` is a 4-byte or 6-byte
            // type ("blob", "tree", "commit"), `hash` is the hash, and the remainder of
            // the line is the file name.
            let bytes = ByteString(encodingAsUTF8: line)
            let expectedBytesCount = 6 + 1 + 4 + 1 + 40 + 1
            guard bytes.count > expectedBytesCount,
                  bytes.contents[6] == UInt8(ascii: " "),
                  // Search for the second space since `type` is of variable length.
                  let secondSpace = bytes.contents[6 + 1 ..< bytes.contents.endIndex].firstIndex(of: UInt8(ascii: " ")),
                  bytes.contents[secondSpace] == UInt8(ascii: " "),
                  bytes.contents[secondSpace + 1 + 40] == UInt8(ascii: "\t")
            else {
                throw GitInterfaceError.malformedResponse("unexpected tree entry '\(line)' in '\(text)'")
            }

            // Compute the mode.
            let mode = bytes.contents[0 ..< 6].reduce(0) { (acc: Int, char: UInt8) in
                (acc << 3) | (Int(char) - Int(UInt8(ascii: "0")))
            }
            guard let type = Tree.Entry.EntryType(mode: mode),
                  let hash = Hash(asciiBytes: bytes.contents[(secondSpace + 1) ..< (secondSpace + 1 + 40)]),
                  let name = ByteString(bytes.contents[(secondSpace + 1 + 40 + 1) ..< bytes.count]).validDescription
            else {
                throw GitInterfaceError.malformedResponse("unexpected tree entry '\(line)' in '\(text)'")
            }

            // FIXME: We do not handle de-quoting of names, currently.
            if name.hasPrefix("\"") {
                throw GitInterfaceError.malformedResponse("unexpected tree entry '\(line)' in '\(text)'")
            }

            entries.append(Tree.Entry(location: .hash(hash), type: type, name: name))
        }
        return entries
    }

    /// Read a blob object.
    func readBlob(hash: Hash) throws -> ByteString {
        try self.cachedBlobs.memoize(hash) {
            try self.lock.withLock {
                // Get the contents using `cat-file`.
                //
                // FIXME: We need to get the raw bytes back, not a String.
                let output = try callGit(
                    "cat-file",
                    "-p",
                    hash.bytes.description,
                    failureMessage: "Couldn’t read ‘\(hash.bytes.description)’"
                )
                return ByteString(encodingAsUTF8: output)
            }
        }
    }

    /// Read a symbolic link.
    func readLink(hash: Hash) throws -> String {
        return try callGit(
            "cat-file", "-p", String(describing: hash.bytes),
            failureMessage: "Couldn't read '\(String(describing: hash.bytes))'"
        )
    }
}

// MARK: - GitFileSystemView

/// A `git` file system view.
///
/// The current implementation is based on lazily caching data with no eviction
/// policy, and is very unoptimized.
private class GitFileSystemView: FileSystem {
    typealias Hash = GitRepository.Hash
    typealias Tree = GitRepository.Tree

    // MARK: Git Object Model

    // The map of loaded trees.
    var trees = ThreadSafeKeyValueStore<Tree.Location, Tree>()

    /// The underlying repository.
    let repository: GitRepository

    /// The root tree hash.
    // let root: GitRepository.Hash
    let root: Tree.Location

    init(repository: GitRepository, revision: Revision) throws {
        self.repository = repository
        self.root = try .hash(repository.readCommit(hash: Hash(revision.identifier)!).tree)
    }

    init(repository: GitRepository, tag: String) throws {
        self.repository = repository
        self.root = .tag(tag)
    }

    // MARK: FileSystem Implementations

    private func getEntry(_ path: TSCAbsolutePath) throws -> Tree.Entry? {
        // Walk the components resolving the tree (starting with a synthetic
        // root entry).
        var current = Tree.Entry(location: self.root, type: .tree, name: AbsolutePath.root.pathString)
        var currentPath = AbsolutePath.root
        for component in path.components {
            // Skip the root pseudo-component.
            if component == AbsolutePath.root.pathString { continue }

            currentPath = currentPath.appending(component: component)
            // We have a component to resolve, so the current entry must be a tree.
            guard current.type == .tree else {
                throw FileSystemError(.notDirectory, .init(currentPath))
            }

            // Fetch the tree.
            let tree = try self.getTree(current.location)

            // Search the tree for the component.
            //
            // FIXME: This needs to be optimized, somewhere.
            guard let index = tree.contents.firstIndex(where: { $0.name == component }) else {
                return nil
            }

            current = tree.contents[index]
        }

        return current
    }

    private func getTree(_ location: Tree.Location) throws -> Tree {
        // Check the cache.
        if let tree = trees[location] {
            return tree
        }

        // Otherwise, load it.
        let tree = try repository.readTree(location: location)
        self.trees[location] = tree
        return tree
    }

    func exists(_ path: TSCAbsolutePath, followSymlink: Bool) -> Bool {
        do {
            return try self.getEntry(path) != nil
        } catch {
            return false
        }
    }

    func isFile(_ path: TSCAbsolutePath) -> Bool {
        do {
            if let entry = try getEntry(path), entry.type != .tree {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    func isDirectory(_ path: TSCAbsolutePath) -> Bool {
        do {
            if let entry = try getEntry(path), entry.type == .tree {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    func isSymlink(_ path: TSCAbsolutePath) -> Bool {
        do {
            if let entry = try getEntry(path), entry.type == .symlink {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    func isExecutableFile(_ path: TSCAbsolutePath) -> Bool {
        if let entry = try? getEntry(path), entry.type == .executableBlob {
            return true
        }
        return false
    }

    func isReadable(_ path: TSCAbsolutePath) -> Bool {
        self.exists(path)
    }

    func isWritable(_: TSCAbsolutePath) -> Bool {
        false
    }

    public var currentWorkingDirectory: TSCAbsolutePath? {
        TSCAbsolutePath.root
    }

    func changeCurrentWorkingDirectory(to path: TSCAbsolutePath) throws {
        throw InternalError("changeCurrentWorkingDirectory not supported")
    }

    func getDirectoryContents(_ path: TSCAbsolutePath) throws -> [String] {
        guard let entry = try getEntry(path) else {
            throw FileSystemError(.noEntry, path)
        }
        guard entry.type == .tree else {
            throw FileSystemError(.notDirectory, path)
        }
        return try self.getTree(entry.location).contents.map(\.name)
    }

    func readFileContents(_ path: TSCAbsolutePath) throws -> ByteString {
        guard let entry = try getEntry(path) else {
            throw FileSystemError(.noEntry, path)
        }
        guard entry.type != .tree else {
            throw FileSystemError(.isDirectory, path)
        }
        guard case .hash(let hash) = entry.location else {
            throw InternalError("only hash locations supported")
        }
        switch entry.type {
        case .symlink:
            let path = try repository.readLink(hash: hash)
            return try readFileContents(AbsolutePath(validating: path))
        case .blob, .executableBlob:
            return try self.repository.readBlob(hash: hash)
        default:
            throw InternalError("unsupported git entry type \(entry.type) at path \(path)")
        }
    }

    // MARK: Unsupported methods.

    public var homeDirectory: TSCAbsolutePath {
        fatalError("unsupported")
    }

    public var cachesDirectory: TSCAbsolutePath? {
        fatalError("unsupported")
    }

    public var tempDirectory: TSCAbsolutePath {
        fatalError("unsupported")
    }

    func createDirectory(_ path: TSCAbsolutePath) throws {
        throw FileSystemError(.unsupported, path)
    }

    func createDirectory(_ path: TSCAbsolutePath, recursive: Bool) throws {
        throw FileSystemError(.unsupported, path)
    }

    func createSymbolicLink(_ path: TSCAbsolutePath, pointingAt destination: TSCAbsolutePath, relative: Bool) throws {
        throw FileSystemError(.unsupported, path)
    }

    func writeFileContents(_ path: TSCAbsolutePath, bytes: ByteString) throws {
        throw FileSystemError(.unsupported, path)
    }

    func removeFileTree(_ path: TSCAbsolutePath) throws {
        throw FileSystemError(.unsupported, path)
    }

    func chmod(_ mode: FileMode, path: TSCAbsolutePath, options: Set<FileMode.Option>) throws {
        throw FileSystemError(.unsupported, path)
    }

    func copy(from sourcePath: TSCAbsolutePath, to destinationPath: TSCAbsolutePath) throws {
        fatalError("will never be supported")
    }

    func move(from sourcePath: TSCAbsolutePath, to destinationPath: TSCAbsolutePath) throws {
        fatalError("will never be supported")
    }
}

// State of `GitFileSystemView` is protected with `ThreadSafeKeyValueStore`.
extension GitFileSystemView: @unchecked Sendable {}

// MARK: - Errors

private struct GitShellError: Error {
    let result: AsyncProcessResult
}

private enum GitInterfaceError: Swift.Error {
    /// This indicates a problem communicating with the `git` tool.
    case malformedResponse(String)

    /// This indicates that a fatal error was encountered
    case fatalError
}

public struct GitRepositoryError: Error, CustomStringConvertible, DiagnosticLocationProviding {
    public let path: AbsolutePath
    public let message: String
    package let result: AsyncProcessResult

    public struct Location: DiagnosticLocation {
        public let path: AbsolutePath
        public var description: String {
            self.path.pathString
        }
    }

    public var diagnosticLocation: DiagnosticLocation? {
        Location(path: self.path)
    }

    public var description: String {
        let stdout = (try? self.result.utf8Output()) ?? ""
        let stderr = (try? self.result.utf8stderrOutput()) ?? ""
        let output = (stdout + stderr).spm_chomp().spm_multilineIndent(count: 4)
        return "\(self.message):\n\(output)"
    }
}

public struct GitCloneError: Error, CustomStringConvertible, DiagnosticLocationProviding {
    public let repository: RepositorySpecifier
    public let message: String
    package let result: AsyncProcessResult

    public struct Location: DiagnosticLocation {
        public let repository: RepositorySpecifier
        public var description: String {
            self.repository.location.description
        }
    }

    public var diagnosticLocation: DiagnosticLocation? {
        Location(repository: self.repository)
    }

    public var description: String {
        let stdout = (try? self.result.utf8Output()) ?? ""
        let stderr = (try? self.result.utf8stderrOutput()) ?? ""
        let output = (stdout + stderr).spm_chomp().spm_multilineIndent(count: 4)
        return "\(self.message):\n\(output)"
    }
}

public enum GitProgressParser: FetchProgress {
    case enumeratingObjects(currentObjects: Int)
    case countingObjects(progress: Double, currentObjects: Int, totalObjects: Int)
    case compressingObjects(progress: Double, currentObjects: Int, totalObjects: Int)
    case receivingObjects(
        progress: Double,
        currentObjects: Int,
        totalObjects: Int,
        downloadProgress: String?,
        downloadSpeed: String?
    )
    case resolvingDeltas(progress: Double, currentObjects: Int, totalObjects: Int)

    /// The pattern used to match git output. Capture groups are labeled from ?<i0> to ?<i19>.
    static let pattern = #"""
    (?xi)
    (?:
        remote: \h+ (?<i0>Enumerating \h objects): \h+ (?<i1>[0-9]+)
    )|
    (?:
        remote: \h+ (?<i2>Counting \h objects): \h+ (?<i3>[0-9]+)% \h+ \((?<i4>[0-9]+)\/(?<i5>[0-9]+)\)
    )|
    (?:
        remote: \h+ (?<i6>Compressing \h objects): \h+ (?<i7>[0-9]+)% \h+ \((?<i8>[0-9]+)\/(?<i9>[0-9]+)\)
    )|
    (?:
        (?<i10>Resolving \h deltas): \h+ (?<i11>[0-9]+)% \h+ \((?<i12>[0-9]+)\/(?<i13>[0-9]+)\)
    )|
    (?:
        (?<i14>Receiving \h objects): \h+ (?<i15>[0-9]+)% \h+ \((?<i16>[0-9]+)\/(?<i17>[0-9]+)\)
        (?:, \h+ (?<i18>[0-9]+.?[0-9]+ \h [A-Z]iB) \h+ \| \h+ (?<i19>[0-9]+.?[0-9]+ \h [A-Z]iB\/s))?
    )
    """#
    static let regex = try? RegEx(pattern: pattern)

    init?(from string: String) {
        guard let matches = GitProgressParser.regex?.matchGroups(in: string).first,
              matches.count == 20 else { return nil }

        if matches[0] == "Enumerating objects" {
            guard let currentObjects = Int(matches[1]) else { return nil }

            self = .enumeratingObjects(currentObjects: currentObjects)
        } else if matches[2] == "Counting objects" {
            guard let progress = Double(matches[3]),
                  let currentObjects = Int(matches[4]),
                  let totalObjects = Int(matches[5]) else { return nil }

            self = .countingObjects(
                progress: progress / 100,
                currentObjects: currentObjects,
                totalObjects: totalObjects
            )

        } else if matches[6] == "Compressing objects" {
            guard let progress = Double(matches[7]),
                  let currentObjects = Int(matches[8]),
                  let totalObjects = Int(matches[9]) else { return nil }

            self = .compressingObjects(
                progress: progress / 100,
                currentObjects: currentObjects,
                totalObjects: totalObjects
            )

        } else if matches[10] == "Resolving deltas" {
            guard let progress = Double(matches[11]),
                  let currentObjects = Int(matches[12]),
                  let totalObjects = Int(matches[13]) else { return nil }

            self = .resolvingDeltas(
                progress: progress / 100,
                currentObjects: currentObjects,
                totalObjects: totalObjects
            )

        } else if matches[14] == "Receiving objects" {
            guard let progress = Double(matches[15]),
                  let currentObjects = Int(matches[16]),
                  let totalObjects = Int(matches[17]) else { return nil }

            let downloadProgress = matches[18]
            let downloadSpeed = matches[19]

            self = .receivingObjects(
                progress: progress / 100,
                currentObjects: currentObjects,
                totalObjects: totalObjects,
                downloadProgress: downloadProgress,
                downloadSpeed: downloadSpeed
            )

        } else {
            return nil
        }
    }

    public var message: String {
        switch self {
        case .enumeratingObjects: return "Enumerating objects"
        case .countingObjects: return "Counting objects"
        case .compressingObjects: return "Compressing objects"
        case .receivingObjects: return "Receiving objects"
        case .resolvingDeltas: return "Resolving deltas"
        }
    }

    public var step: Int {
        switch self {
        case .enumeratingObjects(let currentObjects):
            return currentObjects
        case .countingObjects(_, let currentObjects, _):
            return currentObjects
        case .compressingObjects(_, let currentObjects, _):
            return currentObjects
        case .receivingObjects(_, let currentObjects, _, _, _):
            return currentObjects
        case .resolvingDeltas(_, let currentObjects, _):
            return currentObjects
        }
    }

    public var totalSteps: Int? {
        switch self {
        case .enumeratingObjects:
            return 0
        case .countingObjects(_, _, let totalObjects):
            return totalObjects
        case .compressingObjects(_, _, let totalObjects):
            return totalObjects
        case .receivingObjects(_, _, let totalObjects, _, _):
            return totalObjects
        case .resolvingDeltas(_, _, let totalObjects):
            return totalObjects
        }
    }

    public var downloadProgress: String? {
        switch self {
        case .receivingObjects(_, _, _, let downloadProgress, _):
            return downloadProgress
        default:
            return nil
        }
    }

    public var downloadSpeed: String? {
        switch self {
        case .receivingObjects(_, _, _, _, let downloadSpeed):
            return downloadSpeed
        default:
            return nil
        }
    }
}

/// Processes stdout output and calls the progress callback with `GitStatus` objects.
private func gitFetchStatusFilter(_ bytes: [UInt8], progress: FetchProgress.Handler) {
    guard let string = String(bytes: bytes, encoding: .utf8) else { return }
    let lines = string
        .split { $0.isNewline }
        .map { String($0) }

    for line in lines {
        if let status = GitProgressParser(from: line) {
            switch status {
            case .receivingObjects:
                progress(status)
            default:
                continue
            }
        }
    }
}

extension RepositorySpecifier.Location {
    fileprivate var gitURL: String {
        switch self {
        case .path(let path):
            return path.pathString
        case .url(let url):
            return url.absoluteString
        }
    }
}
