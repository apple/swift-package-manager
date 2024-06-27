//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

/// A command to run during the build, including executable, command lines,
/// environment variables, initial working directory, etc. All paths should be
/// based on the ones passed to the plugin in the target build context.
public enum Command {
    /// Returns a command that runs when any of its output files are needed by
    /// the build, but out-of-date.
    ///
    /// An output file is out-of-date if it doesn't exist, or if any input files
    /// have changed since the command was last run.
    ///
    /// - Note: the paths in the list of output files may depend on the list of
    ///   input file paths, but **must not** depend on reading the contents of
    ///   any input files. Such cases must be handled using a `prebuildCommand`.
    ///
    /// - parameters:
    ///   - displayName: An optional string to show in build logs and other
    ///     status areas.
    ///   - executable: The absolute path to the executable to be invoked.
    ///   - arguments: Command-line arguments to be passed to the executable.
    ///   - environment: Environment variable assignments visible to the
    ///     executable.
    ///   - inputFiles: Files on which the contents of output files may depend.
    ///     Any paths passed as `arguments` should typically be passed here as
    ///     well.
    ///   - outputFiles: Files to be generated or updated by the executable.
    ///     Any files recognizable by their extension as source files
    ///     (e.g. `.swift`) are compiled into the target for which this command
    ///     was generated as if in its source directory; other files are treated
    ///     as resources as if explicitly listed in `Package.swift` using
    ///     `.process(...)`.
    @available(_PackageDescription, introduced: 6.0)
    case buildCommand(
        displayName: String?,
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        inputFiles: [URL] = [],
        outputFiles: [URL] = []
    )

    /// Returns a command that runs unconditionally before every build.
    ///
    /// Prebuild commands can have a significant performance impact
    /// and should only be used when there would be no way to know the
    /// list of output file paths without first reading the contents
    /// of one or more input files. Typically there is no way to
    /// determine this list without first running the command, so
    /// instead of encoding that list, the caller supplies an
    /// `outputFilesDirectory` parameter, and all files in that
    /// directory after the command runs are treated as output files.
    ///
    /// - parameters:
    ///   - displayName: An optional string to show in build logs and other
    ///     status areas.
    ///   - executable: The absolute path to the executable to be invoked.
    ///   - arguments: Command-line arguments to be passed to the executable.
    ///   - environment: Environment variable assignments visible to the executable.
    ///   - outputFilesDirectory: A directory into which the command writes its
    ///     output files.  Any files there recognizable by their extension as
    ///     source files (e.g. `.swift`) are compiled into the target for which
    ///     this command was generated as if in its source directory; other
    ///     files are treated as resources as if explicitly listed in
    ///     `Package.swift` using `.process(...)`.
    @available(_PackageDescription, introduced: 6.0)
    case prebuildCommand(
        displayName: String?,
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        outputFilesDirectory: URL
    )
}

extension Command {
    /// Returns a command that runs when any of its output files are needed by
    /// the build, but out-of-date.
    ///
    /// An output file is out-of-date if it doesn't exist, or if any input files
    /// have changed since the command was last run.
    ///
    /// - Note: the paths in the list of output files may depend on the list of
    ///   input file paths, but **must not** depend on reading the contents of
    ///   any input files. Such cases must be handled using a `prebuildCommand`.
    ///
    /// - parameters:
    ///   - displayName: An optional string to show in build logs and other
    ///     status areas.
    ///   - executable: The absolute path to the executable to be invoked.
    ///   - arguments: Command-line arguments to be passed to the executable.
    ///   - environment: Environment variable assignments visible to the
    ///     executable.
    ///   - inputFiles: Files on which the contents of output files may depend.
    ///     Any paths passed as `arguments` should typically be passed here as
    ///     well.
    ///   - outputFiles: Files to be generated or updated by the executable.
    ///     Any files recognizable by their extension as source files
    ///     (e.g. `.swift`) are compiled into the target for which this command
    ///     was generated as if in its source directory; other files are treated
    ///     as resources as if explicitly listed in `Package.swift` using
    ///     `.process(...)`.
    @available(_PackageDescription, deprecated: 6.0, message: "Use `URL` type instead of `Path`.")
    public static func buildCommand(
        displayName: String?,
        executable: Path,
        arguments: [CustomStringConvertible],
        environment: [String: CustomStringConvertible] = [:],
        inputFiles: [Path] = [],
        outputFiles: [Path] = []
    ) -> Command {
        self.buildCommand(
            displayName: displayName,
            executable: URL(fileURLWithPath: executable.stringValue),
            arguments: arguments.map(\.description),
            environment: environment.mapValues { $0.description },
            inputFiles: inputFiles.map { URL(fileURLWithPath: $0.stringValue) },
            outputFiles: outputFiles.map { URL(fileURLWithPath: $0.stringValue) }
        )
    }

    /// Returns a command that runs when any of its output files are needed
    /// by the build, but out-of-date.
    ///
    /// An output file is out-of-date if it doesn't exist, or if any input
    /// files have changed since the command was last run.
    ///
    /// - Note: the paths in the list of output files may depend on the list
    ///   of input file paths, but **must not** depend on reading the contents
    ///   of any input files. Such cases must be handled using a `prebuildCommand`.
    ///
    /// - parameters:
    ///   - displayName: An optional string to show in build logs and other
    ///     status areas.
    ///   - executable: The absolute path to the executable to be invoked.
    ///   - arguments: Command-line arguments to be passed to the executable.
    ///   - environment: Environment variable assignments visible to the executable.
    ///   - workingDirectory: Optional initial working directory when the executable
    ///     runs.
    ///   - inputFiles: Files on which the contents of output files may depend.
    ///     Any paths passed as `arguments` should typically be passed here as well.
    ///   - outputFiles: Files to be generated or updated by the executable.
    ///     Any files recognizable by their extension as source files
    ///     (e.g. `.swift`) are compiled into the target for which this command
    ///     was generated as if in its source directory; other files are treated
    ///     as resources as if explicitly listed in `Package.swift` using
    ///     `.process(...)`.
    @available(*, unavailable, message: "specifying the initial working directory for a command is not yet supported")
    public static func buildCommand(
        displayName: String?,
        executable: Path,
        arguments: [CustomStringConvertible],
        environment: [String: CustomStringConvertible] = [:],
        workingDirectory: Path? = .none,
        inputFiles: [Path] = [],
        outputFiles: [Path] = []
    ) -> Command {
        self.buildCommand(
            displayName: displayName,
            executable: URL(fileURLWithPath: executable.stringValue),
            arguments: arguments.map(\.description),
            environment: environment.mapValues { $0.description },
            inputFiles: inputFiles.map { URL(fileURLWithPath: $0.stringValue) },
            outputFiles: outputFiles.map { URL(fileURLWithPath: $0.stringValue) }
        )
    }

    /// Returns a command that runs unconditionally before every build.
    ///
    /// Prebuild commands can have a significant performance impact
    /// and should only be used when there would be no way to know the
    /// list of output file paths without first reading the contents
    /// of one or more input files. Typically there is no way to
    /// determine this list without first running the command, so
    /// instead of encoding that list, the caller supplies an
    /// `outputFilesDirectory` parameter, and all files in that
    /// directory after the command runs are treated as output files.
    ///
    /// - parameters:
    ///   - displayName: An optional string to show in build logs and other
    ///     status areas.
    ///   - executable: The absolute path to the executable to be invoked.
    ///   - arguments: Command-line arguments to be passed to the executable.
    ///   - environment: Environment variable assignments visible to the executable.
    ///   - workingDirectory: Optional initial working directory when the executable
    ///     runs.
    ///   - outputFilesDirectory: A directory into which the command writes its
    ///     output files.  Any files there recognizable by their extension as
    ///     source files (e.g. `.swift`) are compiled into the target for which
    ///     this command was generated as if in its source directory; other
    ///     files are treated as resources as if explicitly listed in
    ///     `Package.swift` using `.process(...)`.
    @available(_PackageDescription, deprecated: 6.0, message: "Use `URL` type instead of `Path`.")
    public static func prebuildCommand(
        displayName: String?,
        executable: Path,
        arguments: [CustomStringConvertible],
        environment: [String: CustomStringConvertible] = [:],
        outputFilesDirectory: Path
    ) -> Command {
        self.prebuildCommand(
            displayName: displayName,
            executable: URL(fileURLWithPath: executable.stringValue),
            arguments: arguments.map(\.description),
            environment: environment.mapValues { $0.description },
            outputFilesDirectory: URL(fileURLWithPath: outputFilesDirectory.stringValue)
        )
    }

    /// Returns a command that runs unconditionally before every build.
    ///
    /// Because prebuild commands are run on every build, they can have a
    /// significant performance impact and should only be used when there
    /// would be no way to know the list of output file paths without first
    /// reading the contents of one or more input files. Typically there is
    /// no way to determine this list without first running the command, so
    /// instead of encoding that list, the caller supplies an
    /// `outputFilesDirectory` parameter, and all files in that directory
    /// after the command runs are treated as output files.
    ///
    /// - parameters:
    ///   - displayName: An optional string to show in build logs and other
    ///     status areas.
    ///   - executable: The absolute path to the executable to be invoked.
    ///   - arguments: Command-line arguments to be passed to the executable.
    ///   - environment: Environment variable assignments visible to the executable.
    ///   - workingDirectory: Optional initial working directory when the executable
    ///     runs.
    ///   - outputFilesDirectory: A directory into which the command writes its
    ///     output files.  Any files there recognizable by their extension as
    ///     source files (e.g. `.swift`) are compiled into the target for which
    ///     this command was generated as if in its source directory; other
    ///     files are treated as resources as if explicitly listed in
    ///     `Package.swift` using `.process(...)`.
    @available(*, unavailable, message: "specifying the initial working directory for a command is not yet supported")
    public static func prebuildCommand(
        displayName: String?,
        executable: Path,
        arguments: [CustomStringConvertible],
        environment: [String: CustomStringConvertible] = [:],
        workingDirectory: Path? = .none,
        outputFilesDirectory: Path
    ) -> Command {
        self.prebuildCommand(
            displayName: displayName,
            executable: URL(fileURLWithPath: executable.stringValue),
            arguments: arguments.map(\.description),
            environment: environment.mapValues { $0.description },
            outputFilesDirectory: URL(fileURLWithPath: outputFilesDirectory.stringValue)
        )
    }
}
