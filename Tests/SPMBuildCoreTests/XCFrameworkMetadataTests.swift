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

import class Basics.InMemoryFileSystem
import SPMBuildCore
import XCTest

final class XCFrameworkMetadataTests: XCTestCase {
    func testParseFramework() throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/Info.plist":  """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>AvailableLibraries</key>
                <array>
                    <dict>
                        <key>LibraryIdentifier</key>
                        <string>macos-x86_64</string>
                        <key>LibraryPath</key>
                        <string>MyFramework.framework</string>
                        <key>SupportedArchitectures</key>
                        <array>
                            <string>x86_64</string>
                        </array>
                        <key>SupportedPlatform</key>
                        <string>macos</string>
                    </dict>
                    <dict>
                        <key>LibraryIdentifier</key>
                        <string>ios-arm64_x86_64-simulator</string>
                        <key>LibraryPath</key>
                        <string>MyFramework.framework</string>
                        <key>SupportedArchitectures</key>
                        <array>
                            <string>arm64</string>
                            <string>x86_64</string>
                        </array>
                        <key>SupportedPlatform</key>
                        <string>ios</string>
                        <key>SupportedPlatformVariant</key>
                        <string>simulator</string>
                    </dict>
                </array>
                <key>CFBundlePackageType</key>
                <string>XFWK</string>
                <key>XCFrameworkFormatVersion</key>
                <string>1.0</string>
            </dict>
            </plist>
            """,
        ])

        let metadata = try XCFrameworkMetadata.parse(fileSystem: fileSystem, rootPath: .root)
        XCTAssertEqual(metadata,
                       XCFrameworkMetadata(libraries: [
                           XCFrameworkMetadata.Library(
                               libraryIdentifier: "macos-x86_64",
                               libraryPath: "MyFramework.framework",
                               headersPath: nil,
                               platform: "macos",
                               architectures: ["x86_64"],
                               variant: nil
                           ),
                           XCFrameworkMetadata.Library(
                               libraryIdentifier: "ios-arm64_x86_64-simulator",
                               libraryPath: "MyFramework.framework",
                               headersPath: nil,
                               platform: "ios",
                               architectures: ["arm64", "x86_64"],
                               variant: "simulator"
                           ),
                       ]))
    }

    func testParseLibrary() throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/Info.plist": """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>AvailableLibraries</key>
                <array>
                    <dict>
                        <key>LibraryIdentifier</key>
                        <string>macos-x86_64</string>
                        <key>HeadersPath</key>
                        <string>Headers</string>
                        <key>LibraryPath</key>
                        <string>MyLibrary.a</string>
                        <key>SupportedArchitectures</key>
                        <array>
                            <string>x86_64</string>
                        </array>
                        <key>SupportedPlatform</key>
                        <string>macos</string>
                    </dict>
                </array>
                <key>CFBundlePackageType</key>
                <string>XFWK</string>
                <key>XCFrameworkFormatVersion</key>
                <string>1.0</string>
            </dict>
            </plist>
            """,
        ])

        let metadata = try XCFrameworkMetadata.parse(fileSystem: fileSystem, rootPath: .root)
        XCTAssertEqual(metadata,
                       XCFrameworkMetadata(
                           libraries: [
                               XCFrameworkMetadata.Library(
                                   libraryIdentifier: "macos-x86_64",
                                   libraryPath: "MyLibrary.a",
                                   headersPath: "Headers",
                                   platform: "macos",
                                   architectures: ["x86_64"],
                                   variant: nil
                               ),
                           ]))
    }
}
