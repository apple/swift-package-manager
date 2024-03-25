//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// Runs a cleanup closure (`deferred`) after a given `work` closure,
/// making sure `deferred` is run also when `work` throws an error.
/// - Parameters:
///   - work: The work that should be performed. Will always be executed.
///   - deferred: The cleanup that needs to be done in any case.
/// - Throws: Any error thrown by `deferred` or `work` (in that order).
/// - Returns: The result of `work`.
/// - Note: If `work` **and** `deferred` throw an error,
///         the one thrown by `deferred` is thrown from this function.
/// - SeeAlso: ``withAsyncThrowing(do:defer:)``
public func withThrowing<T>(
    do work: () throws -> T,
    defer deferred: () throws -> Void
) throws -> T {
    do {
        let result = try work()
        try deferred()
        return result
    } catch {
        try deferred()
        throw error
    }
}

/// Runs an async cleanup closure (`deferred`) after a given async `work` closure,
/// making sure `deferred` is run also when `work` throws an error.
/// - Parameters:
///   - work: The work that should be performed. Will always be executed.
///   - deferred: The cleanup that needs to be done in any case.
/// - Throws: Any error thrown by `deferred` or `work` (in that order).
/// - Returns: The result of `work`.
/// - Note: If `work` **and** `deferred` throw an error,
///         the one thrown by `deferred` is thrown from this function.
/// - SeeAlso: ``withThrowing(do:defer:)``
public func withAsyncThrowing<T: Sendable>(
    do work: @Sendable () async throws -> T,
    defer deferred: @Sendable () async throws -> Void
) async throws -> T {
    do {
        let result = try await work()
        try await deferred()
        return result
    } catch {
        try await deferred()
        throw error
    }
}
