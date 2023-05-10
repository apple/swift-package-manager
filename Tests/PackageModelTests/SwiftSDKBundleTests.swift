//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageModel
import SPMTestSupport
import XCTest

import struct TSCBasic.ByteString
import class TSCBasic.InMemoryFileSystem

private let testArtifactID = "test-artifact"

private let infoJSON = """
{
  "artifacts" : {
    "\(testArtifactID)" : {
      "type" : "swiftSDK",
      "version" : "0.0.1",
      "variants" : [
        {
          "path" : "\(testArtifactID)/aarch64-unknown-linux",
          "supportedTriples" : [
            "arm64-apple-macosx13.0"
          ]
        }
      ]
    }
  },
  "schemaVersion" : "1.0"
}
"""

final class SwiftSDKBundleTests: XCTestCase {
    func testInstall() async throws {
        let system = ObservabilitySystem.makeForTesting()

        let bundleName1 = "test1.artifactbundle"
        let bundleName2 = "test2.artifactbundle"
        let bundlePath1 = "/\(bundleName1)"
        let bundlePath2 = "/\(bundleName2)"
        let destinationsDirectory = try AbsolutePath(validating: "/destinations")
        let fileSystem = InMemoryFileSystem(files: [
            "\(bundlePath1)/info.json": ByteString(encodingAsUTF8: infoJSON),
            "\(bundlePath2)/info.json": ByteString(encodingAsUTF8: infoJSON),
        ])
        try fileSystem.createDirectory(fileSystem.tempDirectory)
        try fileSystem.createDirectory(destinationsDirectory)

        let archiver = MockArchiver()

        try SwiftSDKBundle.install(
            bundlePathOrURL: bundlePath1,
            destinationsDirectory: destinationsDirectory,
            fileSystem,
            archiver,
            system.topScope
        )

        let invalidPath = "foobar"
        do {
            try SwiftSDKBundle.install(
                bundlePathOrURL: "foobar",
                destinationsDirectory: destinationsDirectory,
                fileSystem,
                archiver,
                system.topScope
            )

            XCTFail("Function expected to throw")
        } catch {
            guard let error = error as? DestinationError else {
                XCTFail("Unexpected error type")
                return
            }

            print(error)
            switch error {
            case .invalidBundleName(let bundleName):
                XCTAssertEqual(bundleName, invalidPath)
            default:
                XCTFail("Unexpected error value")
            }
        }

        do {
            try SwiftSDKBundle.install(
                bundlePathOrURL: bundlePath1,
                destinationsDirectory: destinationsDirectory,
                fileSystem,
                archiver,
                system.topScope
            )

            XCTFail("Function expected to throw")
        } catch {
            guard let error = error as? DestinationError else {
                XCTFail("Unexpected error type")
                return
            }

            switch error {
            case .destinationBundleAlreadyInstalled(let installedBundleName):
                XCTAssertEqual(bundleName1, installedBundleName)
            default:
                XCTFail("Unexpected error value")
            }
        }

        do {
            try SwiftSDKBundle.install(
                bundlePathOrURL: bundlePath2,
                destinationsDirectory: destinationsDirectory,
                fileSystem,
                archiver,
                system.topScope
            )

             XCTFail("Function expected to throw")
         } catch {
            guard let error = error as? DestinationError else {
                XCTFail("Unexpected error type")
                return
            }

            switch error {
            case .destinationArtifactAlreadyInstalled(let installedBundleName, let newBundleName, let artifactID):
                XCTAssertEqual(bundleName1, installedBundleName)
                XCTAssertEqual(bundleName2, newBundleName)
                XCTAssertEqual(artifactID, testArtifactID)
            default:
                XCTFail("Unexpected error value")
            }
        }
    }
}
