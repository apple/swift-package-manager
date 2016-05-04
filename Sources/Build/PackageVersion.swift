/*
 This source file is part of the Swift.org open source project

 Copyright 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import POSIX
import PackageType
import class Utility.Git
import struct Utility.Path
import func libc.fclose

public func generateVersionData(_ rootDir: String, rootPackage: Package, externalPackages: [Package]) throws {
    let dirPath = Path.join(rootDir, ".build/versionData")
    try mkdir(dirPath)

    try saveRootPackage(dirPath, package: rootPackage)
    for (pkgName, data) in generateData(externalPackages) {
        try saveVersionData(dirPath, packageName: pkgName, data: data)
    }
}

func saveRootPackage(_ dirPath: String, package: Package) throws {
    guard let repo = Git.Repo(path: package.path) else { return }
    var data = versionData(package: package)
    data += "public let sha: String? = "

    let prefix = repo.versionsArePrefixed ? "v" : ""
    let versionSha = try repo.versionSha(tag: "\(prefix)\(package.version)")

    if repo.sha != versionSha {
        data += "\"\(repo.sha)\"\n"
    } else {
        data += "nil\n"
    }

    data += "public let modified: Bool = "
    data += repo.hasLocalChanges ? "true" : "false"
    data += "\n"

    try saveVersionData(dirPath, packageName: package.name, data: data)
}

func generateData(_ packages: [Package]) -> [String : String] {
    var data = [String : String]()
    for pkg in packages {
        data[pkg.name] = versionData(package: pkg)
    }
    return data
}

func versionData(package: Package) -> String {
    var data = "public let url: String = \"\(package.url)\"\n"
    data += "public let version: (major: Int, minor: Int, patch: Int, prereleaseIdentifiers: [String], buildMetadata: String?) = "
    data += "\(package.version.major, package.version.minor, package.version.patch, package.version.prereleaseIdentifiers, package.version.buildMetadataIdentifier)\n"
    data += "public let versionString: String = \"\(package.version)\"\n"

    return data
}

private func saveVersionData(_ dirPath: String, packageName: String, data: String) throws {
    let filePath = Path.join(dirPath, "\(packageName).swift")
    let file = try fopen(filePath, mode: .Write)
    defer {
        libc.fclose(file)
    }
    try fputs(data, file)
}
