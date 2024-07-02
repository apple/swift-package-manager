//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct Foundation.Data
import struct Foundation.Date
import struct Foundation.URL
#if canImport(Security)
import Security
#endif

public protocol AuthorizationProvider: Sendable {
    func authentication(for url: URL) -> (user: String, password: String)?
}

public protocol AuthorizationWriter {
    @available(*, noasync, message: "Use the async alternative")
    func addOrUpdate(
        for url: URL,
        user: String,
        password: String,
        persist: Bool,
        callback: @escaping (Result<Void, Error>) -> Void
    )

    @available(*, noasync, message: "Use the async alternative")
    func remove(for url: URL, callback: @escaping (Result<Void, Error>) -> Void)
}

public extension AuthorizationWriter {
    func addOrUpdate(
        for url: URL,
        user: String,
        password: String,
        persist: Bool = true
    ) async throws {
        try await safe_async {
            self.addOrUpdate(
                for: url,
                user: user,
                password: password, 
                persist: persist,
                callback: $0)
        }
    }

    func remove(for url: URL) async throws {
        try await safe_async {
            self.remove(for: url, callback: $0)
        }
    }
}

public enum AuthorizationProviderError: Error {
    case invalidURLHost
    case notFound
    case other(String)
}

extension AuthorizationProvider {
    @Sendable
    public func httpAuthorizationHeader(for url: URL) -> String? {
        guard let (user, password) = self.authentication(for: url) else {
            return nil
        }
        guard user != "token" else {
            return "Bearer \(password)"
        }
        let authString = "\(user):\(password)"
        let authData = Data(authString.utf8)
        return "Basic \(authData.base64EncodedString())"
    }
}

// MARK: - netrc

public final class NetrcAuthorizationProvider: AuthorizationProvider, AuthorizationWriter {
    // marked internal for testing
    internal let path: AbsolutePath
    private let fileSystem: FileSystem

    private let cache = ThreadSafeKeyValueStore<String, (user: String, password: String)>()

    public init(path: AbsolutePath, fileSystem: FileSystem) throws {
        self.path = path
        self.fileSystem = fileSystem
        // validate file is okay at the time of initializing the provider
        _ = try Self.load(fileSystem: fileSystem, path: path)
    }

    public func addOrUpdate(
        for url: URL,
        user: String,
        password: String,
        persist: Bool = true,
        callback: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let machine = Self.machine(for: url) else {
            return callback(.failure(AuthorizationProviderError.invalidURLHost))
        }

        if !persist {
            self.cache[machine] = (user, password)
            return callback(.success(()))
        }

        // Same entry already exists, no need to add or update
        let netrc = try? Self.load(fileSystem: self.fileSystem, path: self.path)
        guard netrc?.machines
            .first(where: { $0.name.lowercased() == machine && $0.login == user && $0.password == password }) == nil
        else {
            return callback(.success(()))
        }

        do {
            // Append to end of file
            try self.fileSystem.withLock(on: self.path, type: .exclusive) {
                let contents = try? self.fileSystem.readFileContents(self.path).contents
                try self.fileSystem.writeFileContents(self.path) { stream in
                    // Write existing contents
                    if let contents, !contents.isEmpty {
                        stream.write(contents)
                        stream.write("\n")
                    }
                    stream.write("machine \(machine) login \(user) password \(password)")
                    stream.write("\n")
                }
            }

            callback(.success(()))
        } catch {
            callback(.failure(
                AuthorizationProviderError
                    .other("Failed to update netrc file at \(self.path): \(error.interpolationDescription)")
            ))
        }
    }

    public func remove(for url: URL, callback: @escaping (Result<Void, Error>) -> Void) {
        callback(.failure(
            AuthorizationProviderError
                .other("User must edit netrc file at \(self.path) manually to remove entries")
        ))
    }

    public func authentication(for url: URL) -> (user: String, password: String)? {
        if let machine = Self.machine(for: url), let cached = self.cache[machine] {
            return cached
        }
        return self.machine(for: url).map { (user: $0.login, password: $0.password) }
    }

    private func machine(for url: URL) -> Basics.Netrc.Machine? {
        // Since updates are appended to the end of the file, we
        // take the _last_ match to use the most recent entry.
        if let machine = Self.machine(for: url),
           let existing = self.machines.last(where: { $0.name.lowercased() == machine })
        {
            return existing
        }

        // No match found. Use the first default if any.
        if let existing = self.machines.first(where: { $0.isDefault }) {
            return existing
        }

        return .none
    }

    // marked internal for testing
    internal var machines: [Basics.Netrc.Machine] {
        // this ignores any errors reading the file
        // initial validation is done at the time of initializing the provider
        // and if the file becomes corrupt at runtime it will handle it gracefully
        let netrc = try? Self.load(fileSystem: self.fileSystem, path: self.path)
        return netrc?.machines ?? []
    }

    private static func load(fileSystem: FileSystem, path: AbsolutePath) throws -> Netrc? {
        do {
            return try NetrcParser.parse(fileSystem: fileSystem, path: path)
        } catch NetrcError.fileNotFound, NetrcError.machineNotFound {
            // These are recoverable errors.
            return .none
        }
    }

    private static func machine(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else {
            return nil
        }
        return host.isEmpty ? nil : host
    }
}

// MARK: - Keychain

#if canImport(Security)
public final class KeychainAuthorizationProvider: AuthorizationProvider, AuthorizationWriter {
    private let observabilityScope: ObservabilityScope

    private let cache = ThreadSafeKeyValueStore<String, (user: String, password: String)>()

    public init(observabilityScope: ObservabilityScope) {
        self.observabilityScope = observabilityScope
    }

    public func addOrUpdate(
        for url: URL,
        user: String,
        password: String,
        persist: Bool = true,
        callback: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let protocolHostPort = ProtocolHostPort(from: url) else {
            return callback(.failure(AuthorizationProviderError.invalidURLHost))
        }

        self.observabilityScope
            .emit(debug: "add/update credentials for '\(protocolHostPort)' [\(url.absoluteString)] in keychain")

        if !persist {
            self.cache[protocolHostPort.description] = (user, password)
            return callback(.success(()))
        }

        let passwordData = Data(password.utf8)

        do {
            if !(try self.update(protocolHostPort: protocolHostPort, account: user, password: passwordData)) {
                try self.create(protocolHostPort: protocolHostPort, account: user, password: passwordData)
            }
            callback(.success(()))
        } catch {
            callback(.failure(error))
        }
    }

    public func remove(for url: URL, callback: @escaping (Result<Void, Error>) -> Void) {
        guard let protocolHostPort = ProtocolHostPort(from: url) else {
            return callback(.failure(AuthorizationProviderError.invalidURLHost))
        }

        self.observabilityScope
            .emit(debug: "remove credentials for '\(protocolHostPort)' [\(url.absoluteString)] from keychain")

        do {
            try self.delete(protocolHostPort: protocolHostPort)
            callback(.success(()))
        } catch {
            callback(.failure(error))
        }
    }

    public func authentication(for url: URL) -> (user: String, password: String)? {
        guard let protocolHostPort = ProtocolHostPort(from: url) else {
            return nil
        }

        if let cached = self.cache[protocolHostPort.description] {
            return cached
        }

        self.observabilityScope
            .emit(debug: "search credentials for '\(protocolHostPort)' [\(url.absoluteString)] in keychain")

        do {
            guard let existingItems = try self.search(protocolHostPort: protocolHostPort) as? [[String: Any]] else {
                throw AuthorizationProviderError
                    .other("Failed to extract credentials for '\(protocolHostPort)' from keychain")
            }

            // Log warning if there is more than one result
            if existingItems.count > 1 {
                self.observabilityScope
                    .emit(
                        warning: "multiple (\(existingItems.count)) keychain entries found for '\(protocolHostPort)' [\(url.absoluteString)]"
                    )
            }

            // Sort by modification timestamp
            let sortedItems = existingItems.sorted {
                switch (
                    $0[kSecAttrModificationDate as String] as? Date,
                    $1[kSecAttrModificationDate as String] as? Date
                ) {
                case (nil, nil):
                    return false
                case (_, nil):
                    return true
                case (nil, _):
                    return false
                case (.some(let left), .some(let right)):
                    return left < right
                }
            }

            // Return most recently modified item
            guard let mostRecent = sortedItems.last,
                  let created = mostRecent[kSecAttrCreationDate as String] as? Date,
                  // Get password for this specific item
                  let existingItem = try self.get(
                      protocolHostPort: protocolHostPort,
                      created: created,
                      modified: mostRecent[kSecAttrModificationDate as String] as? Date
                  ) as? [String: Any],
                  let passwordData = existingItem[kSecValueData as String] as? Data,
                  let account = existingItem[kSecAttrAccount as String] as? String
            else {
                throw AuthorizationProviderError
                    .other("Failed to extract credentials for '\(protocolHostPort)' from keychain")
            }
          
            let password = String(decoding: passwordData, as: UTF8.self)

            return (user: account, password: password)
        } catch {
            switch error {
            case AuthorizationProviderError.notFound:
                self.observabilityScope.emit(debug: "no credentials found for '\(protocolHostPort)' in keychain")
            case AuthorizationProviderError.other(let detail):
                self.observabilityScope.emit(error: detail)
            default:
                self.observabilityScope.emit(
                    error: "failed to find credentials for '\(protocolHostPort)' in keychain",
                    underlyingError: error
                )
            }
            return nil
        }
    }

    private func create(protocolHostPort: ProtocolHostPort, account: String, password: Data) throws {
        var query: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
                                    kSecAttrProtocol as String: protocolHostPort.protocolCFString,
                                    kSecAttrServer as String: protocolHostPort.server,
                                    kSecAttrAccount as String: account,
                                    kSecValueData as String: password]

        if let port = protocolHostPort.port {
            query[kSecAttrPort as String] = port
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthorizationProviderError
                .other("Failed to save credentials for '\(protocolHostPort)' to keychain: status \(status)")
        }
    }

    private func update(protocolHostPort: ProtocolHostPort, account: String, password: Data) throws -> Bool {
        var query: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
                                    kSecAttrProtocol as String: protocolHostPort.protocolCFString,
                                    kSecAttrServer as String: protocolHostPort.server]

        if let port = protocolHostPort.port {
            query[kSecAttrPort as String] = port
        }

        let attributes: [String: Any] = [kSecAttrAccount as String: account,
                                         kSecValueData as String: password]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status != errSecItemNotFound else {
            return false
        }
        guard status == errSecSuccess else {
            throw AuthorizationProviderError
                .other("Failed to update credentials for '\(protocolHostPort)' in keychain: status \(status)")
        }
        return true
    }

    private func delete(protocolHostPort: ProtocolHostPort) throws {
        var query: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
                                    kSecAttrProtocol as String: protocolHostPort.protocolCFString,
                                    kSecAttrServer as String: protocolHostPort.server]

        if let port = protocolHostPort.port {
            query[kSecAttrPort as String] = port
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess else {
            throw AuthorizationProviderError
                .other("Failed to delete credentials for '\(protocolHostPort)' from keychain: status \(status)")
        }
    }

    private func search(protocolHostPort: ProtocolHostPort) throws -> CFTypeRef? {
        var query: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
                                    kSecAttrProtocol as String: protocolHostPort.protocolCFString,
                                    kSecAttrServer as String: protocolHostPort.server,
                                    kSecMatchLimit as String: kSecMatchLimitAll, // returns all matches
                                    kSecReturnAttributes as String: true]
        // https://developer.apple.com/documentation/security/keychain_services/keychain_items/searching_for_keychain_items
        // Can't combine `kSecMatchLimitAll` and `kSecReturnData` (which contains password)

        if let port = protocolHostPort.port {
            query[kSecAttrPort as String] = port
        }

        var items: CFTypeRef?
        // Search keychain for server's username and password, if any.
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status != errSecItemNotFound else {
            throw AuthorizationProviderError.notFound
        }
        guard status == errSecSuccess else {
            throw AuthorizationProviderError
                .other("Failed to find credentials for '\(protocolHostPort)' in keychain: status \(status)")
        }

        return items
    }

    private func get(protocolHostPort: ProtocolHostPort, created: Date, modified: Date?) throws -> CFTypeRef? {
        self.observabilityScope
            .emit(debug: "read credentials for '\(protocolHostPort)', created at \(created), in keychain")

        var query: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
                                    kSecAttrProtocol as String: protocolHostPort.protocolCFString,
                                    kSecAttrServer as String: protocolHostPort.server,
                                    kSecAttrCreationDate as String: created,
                                    kSecMatchLimit as String: kSecMatchLimitOne, // limit to one match
                                    kSecReturnAttributes as String: true,
                                    kSecReturnData as String: true] // password

        if let port = protocolHostPort.port {
            query[kSecAttrPort as String] = port
        }
        if let modified {
            query[kSecAttrModificationDate as String] = modified
        }

        var item: CFTypeRef?
        // Search keychain for server's username and password, if any.
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            throw AuthorizationProviderError.notFound
        }
        guard status == errSecSuccess else {
            throw AuthorizationProviderError
                .other("Failed to find credentials for '\(protocolHostPort)' in keychain: status \(status)")
        }

        return item
    }

    struct ProtocolHostPort: Hashable, CustomStringConvertible {
        let `protocol`: String?
        let host: String
        let port: Int?

        var server: String {
            self.host
        }

        var protocolCFString: CFString {
            // See
            // https://developer.apple.com/documentation/security/keychain_services/keychain_items/item_attribute_keys_and_values?language=swift
            // for a list of possible values for the `kSecAttrProtocol` attribute.
            switch self.protocol {
            case "https":
                return kSecAttrProtocolHTTPS
            case "http":
                return kSecAttrProtocolHTTP
            default:
                return kSecAttrProtocolHTTPS
            }
        }

        init?(from url: URL) {
            guard let host = url.host?.lowercased(), !host.isEmpty else {
                return nil
            }

            self.protocol = url.scheme?.lowercased()
            self.host = host
            self.port = url.port
        }

        var description: String {
            "\(self.protocol.map { "\($0)://" } ?? "")\(self.host)\(self.port.map { ":\($0)" } ?? "")"
        }
    }
}
#endif

// MARK: - Composite

public struct CompositeAuthorizationProvider: AuthorizationProvider {
    // marked internal for testing
    internal let providers: [AuthorizationProvider]
    private let observabilityScope: ObservabilityScope

    public init(_ providers: AuthorizationProvider..., observabilityScope: ObservabilityScope) {
        self.init(providers, observabilityScope: observabilityScope)
    }

    public init(_ providers: [AuthorizationProvider], observabilityScope: ObservabilityScope) {
        self.providers = providers
        self.observabilityScope = observabilityScope
    }

    public func authentication(for url: URL) -> (user: String, password: String)? {
        for provider in self.providers {
            if let authentication = provider.authentication(for: url) {
                switch provider {
                case let provider as NetrcAuthorizationProvider:
                    self.observabilityScope.emit(info: "credentials for \(url) found in netrc file at \(provider.path)")
                #if canImport(Security)
                case is KeychainAuthorizationProvider:
                    self.observabilityScope.emit(info: "credentials for \(url) found in keychain")
                #endif
                default:
                    self.observabilityScope.emit(info: "credentials for \(url) found in \(provider)")
                }
                return authentication
            }
        }
        return nil
    }
}
