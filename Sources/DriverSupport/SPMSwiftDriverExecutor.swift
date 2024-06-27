//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import SwiftDriver

import class TSCBasic.Process
import struct TSCBasic.ProcessResult

public final class SPMSwiftDriverExecutor: DriverExecutor {
    
    private enum Error: Swift.Error, CustomStringConvertible {
        case inPlaceExecutionUnsupported
        
        var description: String {
            switch self {
            case .inPlaceExecutionUnsupported:
                return "the integrated Swift driver does not support in-place execution"
            }
        }
    }
    
    public let resolver: ArgsResolver
    let fileSystem: FileSystem
    let env: Environment

    public init(resolver: ArgsResolver,
         fileSystem: FileSystem,
         env: Environment) {
        self.resolver = resolver
        self.fileSystem = fileSystem
        self.env = env
    }
    
    public func execute(job: Job,
                 forceResponseFiles: Bool,
                 recordedInputModificationDates: [TypedVirtualPath : TimePoint]) throws -> ProcessResult {
        let arguments: [String] = try resolver.resolveArgumentList(for: job,
                                                                   useResponseFiles: forceResponseFiles ? .forced : .heuristic)
        
        try job.verifyInputsNotModified(since: recordedInputModificationDates,
                                        fileSystem: fileSystem)
        
        if job.requiresInPlaceExecution {
            throw Error.inPlaceExecutionUnsupported
        }
        
        
        var childEnv = [String: String](env)
        childEnv.merge(job.extraEnvironment, uniquingKeysWith: { (_, new) in new })

        let process = try Process.launchProcess(arguments: arguments, env: childEnv)
        return try process.waitUntilExit()
    }
    
    public func execute(workload: DriverExecutorWorkload,
                 delegate: JobExecutionDelegate,
                 numParallelJobs: Int, forceResponseFiles: Bool,
                 recordedInputModificationDates: [TypedVirtualPath : TimePoint]) throws {
        throw InternalError("Multi-job build plans should be lifted into the SPM build graph.")
    }
    
    public func checkNonZeroExit(args: String..., environment: [String : String]) throws -> String {
        try AsyncProcess.checkNonZeroExit(arguments: args, environment: .init(environment))
    }
    
    public func description(of job: Job, forceResponseFiles: Bool) throws -> String {
        // FIXME: This is duplicated from SwiftDriver, maybe it shouldn't be a protocol requirement.
        let (args, usedResponseFile) = try resolver.resolveArgumentList(for: job,
                                                                        useResponseFiles: forceResponseFiles ? .forced : .heuristic)
        var result = args.joined(separator: " ")
        
        if usedResponseFile {
            // Print the response file arguments as a comment.
            result += " # \(job.commandLine.joinedUnresolvedArguments)"
        }
        
        if !job.extraEnvironment.isEmpty {
            result += " #"
            for (envVar, val) in job.extraEnvironment {
                result += " \(envVar)=\(val)"
            }
        }
        return result
    }
}
