//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SourceControl

import class Basics.AsyncProcess

import enum TSCUtility.Git

/// Extensions useful for unit testing purposes.
/// Note: These are not thread safe.
package extension GitRepository {
    /// Create the repository using git init.
    func create() throws {
        try systemQuietly([Git.tool, "-C", self.path.pathString, "init"])
    }

    /// Returns current branch name. If HEAD is on a detached state, this returns HEAD.
    func currentBranch() throws -> String {
        return try AsyncProcess.checkNonZeroExit(
            args: Git.tool, "-C", path.pathString, "rev-parse", "--abbrev-ref", "HEAD").spm_chomp()
    }

    /// Returns the revision for a given tag.
    func revision(forTag tag: String) throws -> String {
        return try AsyncProcess.checkNonZeroExit(
            args: Git.tool, "-C", path.pathString, "rev-parse", tag).spm_chomp()
    }

    /// Stage a file.
    func stage(file: String) throws {
        try systemQuietly([Git.tool, "-C", self.path.pathString, "add", file])
    }

    /// Stage multiple files.
    func stage(files: String...) throws {
        try systemQuietly([Git.tool, "-C", self.path.pathString, "add"] + files)
    }

    /// Stage entire unstaged changes.
    func stageEverything() throws {
        try systemQuietly([Git.tool, "-C", self.path.pathString, "add", "."])
    }

    /// Commit the staged changes. If the message is not provided a dummy message will be used for the commit.
    func commit(message: String? = nil) throws {
        // FIXME: We don't need to set these every time but we usually only commit once or twice for a test repo.
        try systemQuietly([Git.tool, "-C", self.path.pathString, "config", "user.email", "example@example.com"])
        try systemQuietly([Git.tool, "-C", self.path.pathString, "config", "user.name", "Example Example"])
        try systemQuietly([Git.tool, "-C", self.path.pathString, "config", "commit.gpgsign", "false"])
        try systemQuietly([Git.tool, "-C", self.path.pathString, "config", "tag.gpgsign", "false"])
        try systemQuietly([Git.tool, "-C", self.path.pathString, "commit", "-m", message ?? "Add some files."])
    }

    /// Tag the git repo.
    func tag(name: String) throws {
        try systemQuietly([Git.tool, "-C", self.path.pathString, "tag", name])
    }

    /// Push the changes to specified remote and branch.
    func push(remote: String, branch: String) throws {
        try systemQuietly([Git.tool, "-C", self.path.pathString, "push", remote, branch])
    }
}
