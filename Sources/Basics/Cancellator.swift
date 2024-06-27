//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Dispatch
import Foundation
import class TSCBasic.Thread
#if canImport(WinSDK)
import WinSDK
#endif

public typealias CancellationHandler = @Sendable (DispatchTime) throws -> Void

public final class Cancellator: Cancellable, Sendable {
    public typealias RegistrationKey = String

    private let observabilityScope: ObservabilityScope?
    private let registry = ThreadSafeKeyValueStore<String, (name: String, handler: CancellationHandler)>()
    private let cancelationQueue = DispatchQueue(
        label: "org.swift.swiftpm.cancellator",
        qos: .userInteractive,
        attributes: .concurrent
    )
    private let cancelling = ThreadSafeBox<Bool>(false)

    private static let signalHandlerLock = NSLock()
    private static var isSignalHandlerInstalled = false

    public init(observabilityScope: ObservabilityScope?) {
        self.observabilityScope = observabilityScope
    }

    #if os(Windows)
    // unfortunately this is needed for C callback handlers used by Windows shutdown handler
    static var shared: Cancellator?
    #endif

    /// Installs signal handlers to terminate sub-processes on cancellation.
    public func installSignalHandlers() {
        Self.signalHandlerLock.withLock {
            precondition(!Self.isSignalHandlerInstalled)

            #if os(Windows)
            // Closures passed to `SetConsoleCtrlHandler` can't capture context, working around that with a global.
            Self.shared = self

            // set shutdown handler to terminate sub-processes, etc
            _ = SetConsoleCtrlHandler({ _ in
                // Terminate all processes on receiving an interrupt signal.
                try? Cancellator.shared?.cancel(deadline: .now() + .seconds(30))

                // Reset the handler.
                _ = SetConsoleCtrlHandler(nil, false)

                // Exit as if by signal()
                TerminateProcess(GetCurrentProcess(), 3)

                return true
            }, true)
            #else
            // trap SIGINT to terminate sub-processes, etc
            signal(SIGINT, SIG_IGN)
            let interruptSignalSource = DispatchSource.makeSignalSource(signal: SIGINT)
            interruptSignalSource.setEventHandler { [weak self] in
                // cancel the trap?
                interruptSignalSource.cancel()

                // Terminate all processes on receiving an interrupt signal.
                try? self?.cancel(deadline: .now() + .seconds(30))

                // Install the default signal handler.
                var action = sigaction()
                #if canImport(Darwin) || os(OpenBSD)
                action.__sigaction_u.__sa_handler = SIG_DFL
                #elseif canImport(Musl)
                action.__sa_handler.sa_handler = SIG_DFL
                #elseif os(Android)
                action.sa_handler = SIG_DFL
                #else
                action.__sigaction_handler = unsafeBitCast(
                    SIG_DFL,
                    to: sigaction.__Unnamed_union___sigaction_handler.self
                )
                #endif
                sigaction(SIGINT, &action, nil)
                kill(getpid(), SIGINT)
            }
            interruptSignalSource.resume()
            #endif

            Self.isSignalHandlerInstalled = true
        }
    }

    @discardableResult
    public func register(name: String, handler: @escaping CancellationHandler) -> RegistrationKey? {
        if self.cancelling.get(default: false) {
            self.observabilityScope?.emit(debug: "not registering '\(name)' with terminator, termination in progress")
            return .none
        }
        let key = UUID().uuidString
        self.observabilityScope?.emit(debug: "registering '\(name)' with terminator")
        self.registry[key] = (name: name, handler: handler)
        return key
    }

    @discardableResult
    public func register(name: String, handler: Cancellable) -> RegistrationKey? {
        self.register(name: name, handler: handler.cancel(deadline:))
    }

    @discardableResult
    public func register(name: String, handler: @escaping @Sendable () throws -> Void) -> RegistrationKey? {
        self.register(name: name, handler: { _ in try handler() })
    }

    package func register(_ process: AsyncProcess) -> RegistrationKey? {
        self.register(name: "\(process.arguments.joined(separator: " "))", handler: process.terminate)
    }

    #if !os(iOS) && !os(watchOS) && !os(tvOS)
    public func register(_ process: Foundation.Process) -> RegistrationKey? {
        self.register(name: "\(process.description)", handler: process.terminate(timeout:))
    }
    #endif

    public func deregister(_ key: RegistrationKey) {
        self.registry[key] = nil
    }

    public func cancel(deadline: DispatchTime) throws {
        self._cancel(deadline: deadline)
    }

    // marked internal for testing
    @discardableResult
    internal func _cancel(deadline: DispatchTime? = .none) -> Int {
        self.cancelling.put(true)

        self.observabilityScope?
            .emit(info: "starting cancellation cycle with \(self.registry.count) cancellation handlers registered")

        let deadline = deadline ?? .now() + .seconds(30)
        // deadline for individual handlers set slightly before overall deadline
        let delta: DispatchTimeInterval = .nanoseconds(abs(deadline.distance(to: .now()).nanoseconds() ?? 0) / 5)
        let handlersDeadline = deadline - delta

        let cancellationHandlers = self.registry.get()
        let cancelled = ThreadSafeArrayStore<String>()
        let group = DispatchGroup()
        for (_, (name, handler)) in cancellationHandlers {
            self.cancelationQueue.async(group: group) {
                do {
                    self.observabilityScope?.emit(debug: "cancelling '\(name)'")
                    try handler(handlersDeadline)
                    cancelled.append(name)
                } catch {
                    self.observabilityScope?.emit(
                        warning: "failed cancelling '\(name)'",
                        underlyingError: error
                    )
                }
            }
        }

        if case .timedOut = group.wait(timeout: deadline) {
            self.observabilityScope?
                .emit(
                    warning: "timeout waiting for cancellation with \(cancellationHandlers.count - cancelled.count) cancellation handlers remaining"
                )
        } else {
            self.observabilityScope?.emit(info: "cancellation cycle completed successfully")
        }

        self.cancelling.put(false)

        return cancelled.count
    }
}

public protocol Cancellable {
    func cancel(deadline: DispatchTime) throws -> Void
}

public struct CancellationError: Error, CustomStringConvertible {
    public let description: String

    public init() {
        self.init(description: "Operation cancelled")
    }

    private init(description: String) {
        self.description = description
    }

    static func failedToRegisterProcess(_ process: AsyncProcess) -> Self {
        Self(
            description: """
            failed to register a cancellation handler for this process invocation `\(
                process.arguments.joined(separator: " ")
            )`
            """
        )
    }
}

extension AsyncProcess {
    fileprivate func terminate(timeout: DispatchTime) {
        // send graceful shutdown signal
        self.signal(SIGINT)

        // start a thread to see if we need to terminate more forcibly
        let forceKillSemaphore = DispatchSemaphore(value: 0)
        let forceKillThread = TSCBasic.Thread {
            if case .timedOut = forceKillSemaphore.wait(timeout: timeout) {
                // send a force-kill signal
                #if os(Windows)
                self.signal(SIGTERM)
                #else
                self.signal(SIGKILL)
                #endif
            }
        }
        forceKillThread.start()
        _ = try? self.waitUntilExit()
        forceKillSemaphore.signal() // let the force-kill thread know we do not need it any more
        // join the force-kill thread thread so we don't exit before everything terminates
        forceKillThread.join()
    }
}

#if !os(iOS) && !os(watchOS) && !os(tvOS)
extension Foundation.Process {
    fileprivate func terminate(timeout: DispatchTime) {
        guard self.isRunning else {
            return
        }

        // send graceful shutdown signal (SIGINT)
        self.interrupt()

        // start a thread to see if we need to terminate more forcibly
        let forceKillSemaphore = DispatchSemaphore(value: 0)
        let forceKillThread = TSCBasic.Thread {
            if case .timedOut = forceKillSemaphore.wait(timeout: timeout) {
                guard self.isRunning else {
                    return
                }

                // force kill (SIGTERM)
                self.terminate()
            }
        }
        forceKillThread.start()
        self.waitUntilExit()
        forceKillSemaphore.signal() // let the force-kill thread know we do not need it any more
        // join the force-kill thread thread so we don't exit before everything terminates
        forceKillThread.join()
    }
}
#endif
