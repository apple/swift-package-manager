/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
import Foundation
import PackageModel
import TSCUtility

public struct XCFrameworkMetadata: Equatable {
    public struct Library: Equatable {
        public let libraryIdentifier: String
        public let libraryPath: String
        public let headersPath: String?
        public let platform: String
        public let architectures: [String]

        public init(
            libraryIdentifier: String,
            libraryPath: String,
            headersPath: String?,
            platform: String,
            architectures: [String]
        ) {
            self.libraryIdentifier = libraryIdentifier
            self.libraryPath = libraryPath
            self.headersPath = headersPath
            self.platform = platform
            self.architectures = architectures
        }
    }

    public let libraries: [Library]

    public init(libraries: [Library]) {
        self.libraries = libraries
    }
}

extension XCFrameworkMetadata {
    public static func parse(fileSystem: FileSystem, rootPath: AbsolutePath) throws -> XCFrameworkMetadata {
        let path = rootPath.appending(component: "Info.plist")
        guard fileSystem.exists(path) else {
            throw StringError("XCFramework Info.plist not found at '\(rootPath)'")
        }

        do {
            let bytes = try fileSystem.readFileContents(path)
            return try bytes.withData { data in
                let decoder = PropertyListDecoder()
                return try decoder.decode(XCFrameworkMetadata.self, from: data)
            }
        } catch {
            throw StringError("failed parsing XCFramework Info.plist at '\(path)': \(error)")
        }
    }
}

extension XCFrameworkMetadata: Decodable {
    enum CodingKeys: String, CodingKey {
        case libraries = "AvailableLibraries"
    }
}

extension XCFrameworkMetadata.Library: Decodable {
    enum CodingKeys: String, CodingKey {
        case libraryIdentifier = "LibraryIdentifier"
        case libraryPath = "LibraryPath"
        case headersPath = "HeadersPath"
        case platform = "SupportedPlatform"
        case architectures = "SupportedArchitectures"
    }
}

extension Triple.Arch: Decodable {}
