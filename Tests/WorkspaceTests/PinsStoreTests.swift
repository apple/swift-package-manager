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

import Basics
import PackageModel
import PackageGraph
import _InternalTestSupport
import SourceControl
import Workspace
import XCTest

import class TSCBasic.InMemoryFileSystem

import struct TSCUtility.Version

final class PinsStoreTests: XCTestCase {

    let v1: Version = "1.0.0"

    func testBasics() throws {
        let fs = InMemoryFileSystem()
        let pinsFile = AbsolutePath("/pinsfile.txt")

        do {
            let fooPath = AbsolutePath("/foo")
            let foo = PackageIdentity(path: fooPath)
            let fooRef = PackageReference.localSourceControl(identity: foo, path: fooPath)

            let barPath = AbsolutePath("/bar")
            let bar = PackageIdentity(path: barPath)
            let barRef = PackageReference.localSourceControl(identity: bar, path: barPath)

            var store = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init())
            
            // Pins file should not be created right now.
            XCTAssert(!fs.exists(pinsFile))
            XCTAssert(store.pins.isEmpty)

            let revision = UUID().uuidString
            let state = PinsStore.PinState.version(v1, revision: revision)
            store.pin(packageRef: fooRef, state: state)
            try store.saveState(toolsVersion: ToolsVersion.current, originHash: .none)

            XCTAssert(fs.exists(pinsFile))

            // Load the store again from disk.
            let store2 = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init())
            // Test basics on the store.
            for s in [store, store2] {
                XCTAssert(s.pins.count == 1)
                XCTAssertEqual(s.pins[bar], nil)
                let fooPin = s.pins[foo]!
                XCTAssertEqual(fooPin.packageRef, fooRef)
                XCTAssertEqual(fooPin.state, .version(v1, revision: revision))
                XCTAssertEqual(fooPin.state.description, v1.description)
            }

            // We should be able to pin again.
            store.pin(packageRef: fooRef, state: state)
            store.pin(
                packageRef: fooRef,
                state: .version("1.0.2", revision: revision)
            )
            store.pin(packageRef: barRef, state: state)
            try store.saveState(toolsVersion: ToolsVersion.current, originHash: .none)

            store = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init())
            XCTAssert(store.pins.count == 2)

        }

        // Test source control version pin.

        do {
            let path = AbsolutePath("/foo")
            let identity = PackageIdentity(path: path)
            let revision = UUID().uuidString

            var store = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init())
            store.pin(
                packageRef: .localSourceControl(identity: identity, path: path),
                state: .version("1.2.3", revision: revision)
            )
            try store.saveState(toolsVersion: ToolsVersion.current, originHash: .none)
            store = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init())

            let pin = store.pins[identity]!
            XCTAssertEqual(pin.state, .version("1.2.3", revision: revision))
            XCTAssertEqual(pin.state.description, "1.2.3")
        }

        // Test source control branch pin.

        do {
            let path = AbsolutePath("/foo")
            let identity = PackageIdentity(path: path)
            let revision = UUID().uuidString

            var store = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init())
            store.pin(
                packageRef: .localSourceControl(identity: identity, path: path),
                state: .branch(name: "develop", revision: revision)
            )
            try store.saveState(toolsVersion: ToolsVersion.current, originHash: .none)
            store = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init())

            let pin = store.pins[identity]!
            XCTAssertEqual(pin.state, .branch(name: "develop", revision: revision))
            XCTAssertEqual(pin.state.description, "develop")
        }

        // Test source control revision pin.

        do {
            let path = AbsolutePath("/foo")
            let identity = PackageIdentity(path: path)
            let revision = UUID().uuidString

            var store = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init())
            store.pin(
                packageRef: .localSourceControl(identity: identity, path: path),
                state: .revision(revision)
            )
            try store.saveState(toolsVersion: ToolsVersion.current, originHash: .none)
            store = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init())

            let pin = store.pins[identity]!
            XCTAssertEqual(pin.state, .revision(revision))
            XCTAssertEqual(pin.state.description, revision)
        }

        // Test registry pin.

        do {
            let identity = PackageIdentity.plain("baz.baz") // FIXME: use scope identifier

            var store = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init())
            store.pin(
                packageRef: .registry(identity: identity),
                state: .version("1.2.3", revision: .none)
            )
            try store.saveState(toolsVersion: ToolsVersion.current, originHash: .none)
            store = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init())

            let pin = store.pins[identity]!
            XCTAssertEqual(pin.state, .version("1.2.3", revision: .none))
            XCTAssertEqual(pin.state.description, "1.2.3")
        }
    }

    func testLoadingSchema1() throws {
        let fs = InMemoryFileSystem()
        let pinsFile = AbsolutePath("/pinsfile.txt")

        try fs.writeFileContents(pinsFile, string:
            """
            {
              "version": 1,
              "object": {
                "pins": [
                  {
                    "package": "Clang_C",
                    "repositoryURL": "https://github.com/something/Clang_C.git",
                    "state": {
                      "branch": null,
                      "revision": "90a9574276f0fd17f02f58979423c3fd4d73b59e",
                      "version": "1.0.2",
                    }
                  },
                  {
                    "package": "Commandant",
                    "repositoryURL": "https://github.com/something/Commandant.git",
                    "state": {
                      "branch": null,
                      "revision": "c281992c31c3f41c48b5036c5a38185eaec32626",
                      "version": "0.12.0"
                    }
                  }
                ]
              }
            }
            """
        )

        let store = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init())
        XCTAssertEqual(store.pins.keys.map { $0.description }.sorted(), ["clang_c", "commandant"])
    }

    func testLoadingSchema2() throws {
        let fs = InMemoryFileSystem()
        let pinsFile = AbsolutePath("/pinsfile.txt")

        try fs.writeFileContents(pinsFile, string:
            """
            {
                "version": 2,
                "pins": [
                  {
                    "identity": "clang_c",
                    "kind": "remoteSourceControl",
                    "location": "https://github.com/something/Clang_C.git",
                    "state": {
                      "revision": "90a9574276f0fd17f02f58979423c3fd4d73b59e",
                      "version": "1.0.2",
                    }
                  },
                  {
                    "identity": "commandant",
                    "kind": "remoteSourceControl",
                    "location": "https://github.com/something/Commandant.git",
                    "state": {
                      "revision": "c281992c31c3f41c48b5036c5a38185eaec32626",
                      "version": "0.12.0"
                    }
                  },
                  {
                    "identity": "scope.package",
                    "kind": "registry",
                    "location": "",
                    "state": {
                      "version": "0.12.0"
                    }
                  }
                ]
            }
            """
        )

        let store = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init())
        XCTAssertEqual(store.pins.keys.map { $0.description }.sorted(), ["clang_c", "commandant", "scope.package"])
    }

    func testLoadingSchema3() throws {
        let fs = InMemoryFileSystem()
        let pinsFile = AbsolutePath("/pinsfile.txt")

        let originHash = UUID().uuidString

        try fs.writeFileContents(pinsFile, string:
            """
            {
                "version": 3,
                "originHash": "\(originHash)",
                "pins": [
                  {
                    "identity": "clang_c",
                    "kind": "remoteSourceControl",
                    "location": "https://github.com/something/Clang_C.git",
                    "state": {
                      "revision": "90a9574276f0fd17f02f58979423c3fd4d73b59e",
                      "version": "1.0.2",
                    }
                  },
                  {
                    "identity": "commandant",
                    "kind": "remoteSourceControl",
                    "location": "https://github.com/something/Commandant.git",
                    "state": {
                      "revision": "c281992c31c3f41c48b5036c5a38185eaec32626",
                      "version": "0.12.0"
                    }
                  },
                  {
                    "identity": "scope.package",
                    "kind": "registry",
                    "location": "",
                    "state": {
                      "version": "0.12.0"
                    }
                  }
                ]
            }
            """
        )

        let store = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init())
        XCTAssertEqual(store.pins.keys.map { $0.description }.sorted(), ["clang_c", "commandant", "scope.package"])
        XCTAssertEqual(store.originHash, originHash)
    }

    func testLoadingUnknownSchemaVersion() throws {
        let fs = InMemoryFileSystem()
        let pinsFile = AbsolutePath("/pinsfile.txt")

        let version = -1
        try fs.writeFileContents(pinsFile, string: "{ \"version\": \(version) }");

        XCTAssertThrowsError(try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init()), "error expected", { error in
            XCTAssertEqual("\(error)", "\(pinsFile) file is corrupted or malformed; fix or delete the file to continue: unknown 'PinsStorage' version '\(version)' at '\(pinsFile)'.")
        })

    }

    func testLoadingBadFormat() throws {
        let fs = InMemoryFileSystem()
        let pinsFile = AbsolutePath("/pinsfile.txt")

        try fs.writeFileContents(pinsFile, string: "boom")

        XCTAssertThrowsError(try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init()), "error expected", { error in
            XCTAssertMatch("\(error)", .contains("\(pinsFile) file is corrupted or malformed; fix or delete the file to continue"))
        })
    }

    func testEmptyPins() throws {
        let fs = InMemoryFileSystem()
        let pinsFile = AbsolutePath("/pinsfile.txt")
        let store = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fs, mirrors: .init())

        try store.saveState(toolsVersion: ToolsVersion.current, originHash: .none)
        XCTAssertFalse(fs.exists(pinsFile))

        let fooPath = AbsolutePath("/foo")
        let foo = PackageIdentity(path: fooPath)
        let fooRef = PackageReference.localSourceControl(identity: foo, path: fooPath)
        let revision = "81513c8fd220cf1ed1452b98060cd80d3725c5b7"
        store.pin(packageRef: fooRef, state: .version(v1, revision: revision))

        XCTAssert(!fs.exists(pinsFile))

        try store.saveState(toolsVersion: ToolsVersion.current, originHash: .none)
        XCTAssert(fs.exists(pinsFile))

        store.unpinAll()
        try store.saveState(toolsVersion: ToolsVersion.current, originHash: .none)
        XCTAssertFalse(fs.exists(pinsFile))
    }

    func testPinsWithMirrors() throws {
        let fooURL = SourceControlURL("https://github.com/corporate/foo.git")
        let fooIdentity = PackageIdentity(url: fooURL)
        let fooMirroredURL = SourceControlURL("https://github.corporate.com/team/foo.git")

        let barURL = SourceControlURL("https://github.com/corporate/baraka.git")
        let barIdentity = PackageIdentity(url: barURL)
        let barMirroredURL = SourceControlURL("https://github.corporate.com/team/bar.git")
        let barMirroredIdentity = PackageIdentity(url: barMirroredURL)

        let bazURL = SourceControlURL("https://github.com/cool/baz.git")
        let bazIdentity = PackageIdentity(url: bazURL)

        let mirrors = try DependencyMirrors()
        try mirrors.set(mirror: fooMirroredURL.absoluteString, for: fooURL.absoluteString)
        try mirrors.set(mirror: barMirroredURL.absoluteString, for: barURL.absoluteString)

        let fileSystem = InMemoryFileSystem()
        let pinsFile = AbsolutePath("/pins.txt")

        let store = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fileSystem, mirrors: mirrors)

        store.pin(packageRef: .remoteSourceControl(identity: fooIdentity, url: fooMirroredURL),
                  state: .version(v1, revision: "foo-revision"))
        store.pin(packageRef: .remoteSourceControl(identity: barIdentity, url: barMirroredURL),
                  state: .version(v1, revision: "bar-revision"))
        store.pin(packageRef: .remoteSourceControl(identity: bazIdentity, url: bazURL),
                  state: .version(v1, revision: "baz-revision"))

        XCTAssert(store.pins.count == 3)
        XCTAssertEqual(store.pins[fooIdentity]!.packageRef.kind, .remoteSourceControl(fooMirroredURL))
        XCTAssertEqual(store.pins[barIdentity]!.packageRef.kind, .remoteSourceControl(barMirroredURL))
        XCTAssertNil(store.pins[barMirroredIdentity])
        XCTAssertEqual(store.pins[bazIdentity]!.packageRef.kind, .remoteSourceControl(bazURL))

        try store.saveState(toolsVersion: ToolsVersion.current, originHash: .none)
        XCTAssert(fileSystem.exists(pinsFile))

        let content: String = try fileSystem.readFileContents(pinsFile)
        XCTAssertMatch(content, .contains(fooURL.absoluteString))
        XCTAssertNoMatch(content, .contains(fooMirroredURL.absoluteString))

        // Load the store again from disk, with no mirrors
        let store2 = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fileSystem, mirrors: .init())
        XCTAssert(store2.pins.count == 3)
        XCTAssertEqual(store2.pins[fooIdentity]!.packageRef.kind, .remoteSourceControl(fooURL))
        XCTAssertEqual(store2.pins[barIdentity]!.packageRef.kind, .remoteSourceControl(barURL))
        XCTAssertEqual(store2.pins[bazIdentity]!.packageRef.kind, .remoteSourceControl(bazURL))

        // Load the store again from disk, with mirrors
        let store3 = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fileSystem, mirrors: mirrors)
        XCTAssert(store3.pins.count == 3)
        XCTAssertEqual(store3.pins, store.pins)
    }

    func testPinsWithMirrorsDeterminism() throws {
        let fooIdentity = PackageIdentity.plain("foo")
        let fooURL1 = SourceControlURL("https://github.com/corporate/foo")
        let fooURL2 = SourceControlURL("https://github.com/corporate/foo.git")
        let fooURL3 = SourceControlURL("https://github.com/old-corporate/foo")
        let fooURL4 = SourceControlURL("https://github.com/old-corporate/foo.git")
        let fooMirroredURL = SourceControlURL("https://github.corporate.com/team/foo")

        let mirrors = try DependencyMirrors()
        try mirrors.set(mirror: fooMirroredURL.absoluteString, for: fooURL1.absoluteString)
        try mirrors.set(mirror: fooMirroredURL.absoluteString, for: fooURL2.absoluteString)
        try mirrors.set(mirror: fooMirroredURL.absoluteString, for: fooURL3.absoluteString)
        try mirrors.set(mirror: fooMirroredURL.absoluteString, for: fooURL4.absoluteString)

        let fileSystem = InMemoryFileSystem()
        let pinsFile = AbsolutePath("/pins.txt")

        let store1 = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fileSystem, mirrors: mirrors)
        store1.pin(
            packageRef: .remoteSourceControl(identity: fooIdentity, url: fooMirroredURL),
            state: .version(v1, revision: "revision")
        )

        XCTAssert(store1.pins.count == 1)
        XCTAssertEqual(store1.pins[fooIdentity]!.packageRef.kind, .remoteSourceControl(fooMirroredURL))

        try store1.saveState(toolsVersion: ToolsVersion.current, originHash: .none)
        XCTAssert(fileSystem.exists(pinsFile))

        let content: String = try fileSystem.readFileContents(pinsFile)
        XCTAssertMatch(content, .contains(fooURL1.absoluteString))
        XCTAssertNoMatch(content, .contains(fooURL2.absoluteString))
        XCTAssertNoMatch(content, .contains(fooURL3.absoluteString))
        XCTAssertNoMatch(content, .contains(fooURL4.absoluteString))
        XCTAssertNoMatch(content, .contains(fooMirroredURL.absoluteString))

        // Load the store again from disk, with no mirrors
        let store2 = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fileSystem, mirrors: .init())
        XCTAssert(store2.pins.count == 1)
        XCTAssertEqual(store2.pins[fooIdentity]!.packageRef.kind, .remoteSourceControl(fooURL1))

        // Load the store again from disk, with mirrors
        let store3 = try PinsStore(pinsFile: pinsFile, workingDirectory: .root, fileSystem: fileSystem, mirrors: mirrors)
        XCTAssert(store3.pins.count == 1)
        XCTAssertEqual(store3.pins, store1.pins)
    }

    func testMirrorsDeterminism() throws {
        let URL1 = URL("https://github.com/corporate/foo")
        let URL2 = URL("https://github.com/corporate/foo.git")
        let URL3 = URL("https://github.com/old-corporate/foo")
        let URL4 = URL("https://github.com/old-corporate/foo.git")
        let mirroredURL = URL("https://github.corporate.com/team/foo")

        do {
            let mirrors = try DependencyMirrors([
                URL1.absoluteString: mirroredURL.absoluteString,
                URL2.absoluteString: mirroredURL.absoluteString,
                URL3.absoluteString: mirroredURL.absoluteString,
                URL4.absoluteString: mirroredURL.absoluteString
            ])

            XCTAssertEqual(mirrors.mirror(for: URL2.absoluteString), mirroredURL.absoluteString)
            // reverse index is sorted by "visited", then alphabetically
            XCTAssertEqual(mirrors.original(for: mirroredURL.absoluteString), URL2.absoluteString)
        }

        do {
            let mirrors = try DependencyMirrors([
                URL1.absoluteString: mirroredURL.absoluteString,
                URL2.absoluteString: mirroredURL.absoluteString,
                URL3.absoluteString: mirroredURL.absoluteString,
                URL4.absoluteString: mirroredURL.absoluteString
            ])

            XCTAssertEqual(mirrors.mirror(for: URL3.absoluteString), mirroredURL.absoluteString)
            // reverse index is sorted by "visited", then alphabetically
            XCTAssertEqual(mirrors.original(for: mirroredURL.absoluteString), URL3.absoluteString)
        }

        do {
            let mirrors = try DependencyMirrors([
                URL1.absoluteString: mirroredURL.absoluteString,
                URL2.absoluteString: mirroredURL.absoluteString,
                URL3.absoluteString: mirroredURL.absoluteString,
                URL4.absoluteString: mirroredURL.absoluteString
            ])

            XCTAssertEqual(mirrors.mirror(for: URL2.absoluteString), mirroredURL.absoluteString)
            XCTAssertEqual(mirrors.mirror(for: URL3.absoluteString), mirroredURL.absoluteString)
            // reverse index is sorted by "visited", then alphabetically
            XCTAssertEqual(mirrors.original(for: mirroredURL.absoluteString), URL2.absoluteString)
        }

        do {
            let mirrors = try DependencyMirrors([
                URL1.absoluteString: mirroredURL.absoluteString,
                URL2.absoluteString: mirroredURL.absoluteString,
                URL3.absoluteString: mirroredURL.absoluteString,
                URL4.absoluteString: mirroredURL.absoluteString
            ])

            XCTAssertEqual(mirrors.mirror(for: URL3.absoluteString), mirroredURL.absoluteString)
            XCTAssertEqual(mirrors.mirror(for: URL2.absoluteString), mirroredURL.absoluteString)
            // reverse index is sorted by "visited", then alphabetically
            XCTAssertEqual(mirrors.original(for: mirroredURL.absoluteString), URL3.absoluteString)
        }

        do {
            let mirrors = try DependencyMirrors([
                URL1.absoluteString: mirroredURL.absoluteString,
                URL2.absoluteString: mirroredURL.absoluteString,
                URL3.absoluteString: mirroredURL.absoluteString,
                URL4.absoluteString: mirroredURL.absoluteString
            ])

            // reverse index is sorted by "visited", then alphabetically
            XCTAssertEqual(mirrors.original(for: mirroredURL.absoluteString), URL1.absoluteString)
        }
    }

}
