//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2018-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
@_implementationOnly import Glibc
#elseif canImport(Musl)
@_implementationOnly import Musl
#elseif canImport(Darwin)
@_implementationOnly import Darwin.C
#elseif canImport(ucrt) && canImport(WinSDK)
@_implementationOnly import ucrt
@_implementationOnly import struct WinSDK.HANDLE
#endif
@_implementationOnly import Foundation

/// The configuration of a Swift package.
///
/// Pass configuration options as parameters to your package's initializer
/// statement to provide the name of the package, its targets, products,
/// dependencies, and other configuration options.
///
/// By convention, you need to define the properties of a package in a single
/// nested initializer statement. Don't modify it after initialization. The
/// following package manifest shows the initialization of a simple package
/// object for the MyLibrary Swift package:
///
/// ```swift
/// // swift-tools-version:5.3
/// import PackageDescription
///
/// let package = Package(
///     name: "MyLibrary",
///     platforms: [
///         .macOS(.v10_15),
///     ],
///     products: [
///         .library(name: "MyLibrary", targets: ["MyLibrary"])
///     ],
///     dependencies: [
///         .package(url: "https://url/of/another/package/named/utility", from: "1.0.0")
///     ],
///     targets: [
///         .target(name: "MyLibrary", dependencies: ["Utility"]),
///         .testTarget(name: "MyLibraryTests", dependencies: ["MyLibrary"])
///     ]
/// )
/// ```
///
/// In Swift tools versions earlier than 5.4, the package manifest must begin with the string `// swift-tools-version:`
/// followed by a version number specifier. Version 5.4 and later has relaxed the whitespace requirements.
/// The following code listing shows a few examples of valid declarations of the Swift tools version:
///
/// ```swift
/// // swift-tools-version:3.0.2
/// // swift-tools-version:3.1
/// // swift-tools-version:4.0
/// // swift-tools-version:5.3
/// // swift-tools-version: 5.6
/// ```
///
/// The Swift tools version declares the version of the `PackageDescription`
/// library, the minimum version of the Swift tools and Swift language
/// compatibility version to process the manifest, and the required minimum
/// version of the Swift tools to use the Swift package. Each version of Swift
/// can introduce updates to the PackageDescription framework, but the previous
/// API version is available to packages which declare a prior tools version.
/// This behavior means you can take advantage of new releases of Swift, the Swift
/// tools, and the PackageDescription library, without having to update your
/// package's manifest or losing access to existing packages.
public final class Package {
    /// The name of the Swift package.
    ///
    /// If the name of the package is `nil`, Swift Package Manager deduces the name of the
    /// package using its Git URL.
    public var name: String

    /// The list of minimum versions for platforms supported by the package.
    @available(_PackageDescription, introduced: 5)
    public var platforms: [SupportedPlatform]?

    /// The default localization for resources.
    @available(_PackageDescription, introduced: 5.3)
    public var defaultLocalization: LanguageTag?

    /// The name to use for C modules.
    ///
    /// If present, the Swift Package Manager searches for a `<name>.pc` file to
    /// get the required additional flags for a system target.
    public var pkgConfig: String?

    /// An array of providers for a system target.
    public var providers: [SystemPackageProvider]?

    /// The list of targets that are part of this package.
    public var targets: [Target]

    /// The list of products that this package vends and that clients can use.
    public var products: [Product]

    /// The list of package dependencies.
    public var dependencies: [Dependency]

    /// The list of Swift language modes with which this package is compatible.
    public var swiftLanguageModes: [SwiftLanguageMode]?
    
    /// Legacy property name, accesses value of `swiftLanguageModes`
    @available(_PackageDescription, obsoleted: 6, renamed: "swiftLanguageModes")
    public var swiftLanguageVersions: [SwiftVersion]? {
        get { swiftLanguageModes }
        set { swiftLanguageModes = newValue }
    }

    /// The C language standard to use for all C targets in this package.
    public var cLanguageStandard: CLanguageStandard?

    /// The C++ language standard to use for all C++ targets in this package.
    public var cxxLanguageStandard: CXXLanguageStandard?

    /// Initializes a Swift package with configuration options you provide.
    ///
    /// - Parameters:
    ///   - name: The name of the Swift package, or `nil`, if you want the Swift Package Manager to deduce the
    ///           name from the package's Git URL.
    ///   - pkgConfig: The name to use for C modules. If present, the Swift
    ///           Package Manager searches for a `<name>.pc` file to get the
    ///           additional flags required for a system target.
    ///   - providers: The package providers for a system package.
    ///   - products: The list of products that this package vends and that clients can use.
    ///   - dependencies: The list of package dependencies.
    ///   - targets: The list of targets that are part of this package.
    ///   - swiftLanguageVersions: The list of Swift versions that this package is compatible with.
    ///   - cLanguageStandard: The C language standard to use for all C targets in this package.
    ///   - cxxLanguageStandard: The C++ language standard to use for all C++ targets in this package.
    @available(_PackageDescription, obsoleted: 4.2)
    public init(
        name: String,
        pkgConfig: String? = nil,
        providers: [SystemPackageProvider]? = nil,
        products: [Product] = [],
        dependencies: [Dependency] = [],
        targets: [Target] = [],
        swiftLanguageVersions: [Int]? = nil,
        cLanguageStandard: CLanguageStandard? = nil,
        cxxLanguageStandard: CXXLanguageStandard? = nil
    ) {
        self.name = name
        self.pkgConfig = pkgConfig
        self.providers = providers
        self.products = products
        self.dependencies = dependencies
        self.targets = targets
        self.swiftLanguageModes = swiftLanguageVersions.map{ $0.map{ .version("\($0)") } }
        self.cLanguageStandard = cLanguageStandard
        self.cxxLanguageStandard = cxxLanguageStandard
        registerExitHandler()
    }

    /// Initializes a Swift package with configuration options you provide.
    ///
    /// - Parameters:
    ///   - name: The name of the Swift package, or `nil`, if you want the Swift Package Manager to deduce the
    ///           name from the package's Git URL.
    ///   - pkgConfig: The name to use for C modules. If present, the Swift
    ///           Package Manager searches for a `<name>.pc` file to get the
    ///           additional flags required for a system target.
    ///   - products: The list of products that this package makes available for clients to use.
    ///   - dependencies: The list of package dependencies.
    ///   - targets: The list of targets that are part of this package.
    ///   - swiftLanguageVersions: The list of Swift versions that this package is compatible with.
    ///   - cLanguageStandard: The C language standard to use for all C targets in this package.
    ///   - cxxLanguageStandard: The C++ language standard to use for all C++ targets in this package.
    @available(_PackageDescription, introduced: 4.2, obsoleted: 5)
    public init(
        name: String,
        pkgConfig: String? = nil,
        providers: [SystemPackageProvider]? = nil,
        products: [Product] = [],
        dependencies: [Dependency] = [],
        targets: [Target] = [],
        swiftLanguageVersions: [SwiftVersion]? = nil,
        cLanguageStandard: CLanguageStandard? = nil,
        cxxLanguageStandard: CXXLanguageStandard? = nil
    ) {
        self.name = name
        self.pkgConfig = pkgConfig
        self.providers = providers
        self.products = products
        self.dependencies = dependencies
        self.targets = targets
        self.swiftLanguageModes = swiftLanguageVersions
        self.cLanguageStandard = cLanguageStandard
        self.cxxLanguageStandard = cxxLanguageStandard
        registerExitHandler()
    }

    /// Initializes a Swift package with configuration options you provide.
    ///
    /// - Parameters:
    ///   - name: The name of the Swift package, or `nil`, if you want the Swift Package Manager to deduce the
    ///           name from the package's Git URL.
    ///   - platforms: The list of supported platforms that have a custom deployment target.
    ///   - pkgConfig: The name to use for C modules. If present, the Swift
    ///           Package Manager searches for a `<name>.pc` file to get the
    ///           additional flags required for a system target.
    ///   - products: The list of products that this package makes available for clients to use.
    ///   - dependencies: The list of package dependencies.
    ///   - targets: The list of targets that are part of this package.
    ///   - swiftLanguageVersions: The list of Swift versions that this package is compatible with.
    ///   - cLanguageStandard: The C language standard to use for all C targets in this package.
    ///   - cxxLanguageStandard: The C++ language standard to use for all C++ targets in this package.
    @available(_PackageDescription, introduced: 5, obsoleted: 5.3)
    public init(
        name: String,
        platforms: [SupportedPlatform]? = nil,
        pkgConfig: String? = nil,
        providers: [SystemPackageProvider]? = nil,
        products: [Product] = [],
        dependencies: [Dependency] = [],
        targets: [Target] = [],
        swiftLanguageVersions: [SwiftVersion]? = nil,
        cLanguageStandard: CLanguageStandard? = nil,
        cxxLanguageStandard: CXXLanguageStandard? = nil
    ) {
        self.name = name
        self.platforms = platforms
        self.pkgConfig = pkgConfig
        self.providers = providers
        self.products = products
        self.dependencies = dependencies
        self.targets = targets
        self.swiftLanguageModes = swiftLanguageVersions
        self.cLanguageStandard = cLanguageStandard
        self.cxxLanguageStandard = cxxLanguageStandard
        registerExitHandler()
    }

    /// Initializes a Swift package with configuration options you provide.
    ///
    /// - Parameters:
    ///   - name: The name of the Swift package, or `nil` to use the package's Git URL to deduce the name.
    ///   - defaultLocalization: The default localization for resources.
    ///   - platforms: The list of supported platforms with a custom deployment target.
    ///   - pkgConfig: The name to use for C modules. If present, Swift Package Manager searches for a
    ///   `<name>.pc` file to get the additional flags required for a system target.
    ///   - providers: The package providers for a system target.
    ///   - products: The list of products that this package makes available for clients to use.
    ///   - dependencies: The list of package dependencies.
    ///   - targets: The list of targets that are part of this package.
    ///   - swiftLanguageVersions: The list of Swift versions with which this package is compatible.
    ///   - cLanguageStandard: The C language standard to use for all C targets in this package.
    ///   - cxxLanguageStandard: The C++ language standard to use for all C++ targets in this package.
    @available(_PackageDescription, introduced: 5.3)
    @available(_PackageDescription, obsoleted: 6, renamed:"init(name:defaultLocalization:platforms:pkgConfig:providers:products:dependencies:targets:swiftLanguageModes:cLanguageStandard:cxxLanguageStandard:)")
    public init(
        name: String,
        defaultLocalization: LanguageTag? = nil,
        platforms: [SupportedPlatform]? = nil,
        pkgConfig: String? = nil,
        providers: [SystemPackageProvider]? = nil,
        products: [Product] = [],
        dependencies: [Dependency] = [],
        targets: [Target] = [],
        swiftLanguageVersions: [SwiftVersion]? = nil,
        cLanguageStandard: CLanguageStandard? = nil,
        cxxLanguageStandard: CXXLanguageStandard? = nil
    ) {
        self.name = name
        self.defaultLocalization = defaultLocalization
        self.platforms = platforms
        self.pkgConfig = pkgConfig
        self.providers = providers
        self.products = products
        self.dependencies = dependencies
        self.targets = targets
        self.swiftLanguageModes = swiftLanguageVersions
        self.cLanguageStandard = cLanguageStandard
        self.cxxLanguageStandard = cxxLanguageStandard
        registerExitHandler()
    }
    
    /// Initializes a Swift package with configuration options you provide.
    ///
    /// - Parameters:
    ///   - name: The name of the Swift package, or `nil` to use the package's Git URL to deduce the name.
    ///   - defaultLocalization: The default localization for resources.
    ///   - platforms: The list of supported platforms with a custom deployment target.
    ///   - pkgConfig: The name to use for C modules. If present, Swift Package Manager searches for a
    ///   `<name>.pc` file to get the additional flags required for a system target.
    ///   - providers: The package providers for a system target.
    ///   - products: The list of products that this package makes available for clients to use.
    ///   - dependencies: The list of package dependencies.
    ///   - targets: The list of targets that are part of this package.
    ///   - swiftLanguageModes: The list of Swift language modes with which this package is compatible.
    ///   - cLanguageStandard: The C language standard to use for all C targets in this package.
    ///   - cxxLanguageStandard: The C++ language standard to use for all C++ targets in this package.
    @available(_PackageDescription, introduced: 6)
    public init(
        name: String,
        defaultLocalization: LanguageTag? = nil,
        platforms: [SupportedPlatform]? = nil,
        pkgConfig: String? = nil,
        providers: [SystemPackageProvider]? = nil,
        products: [Product] = [],
        dependencies: [Dependency] = [],
        targets: [Target] = [],
        swiftLanguageModes: [SwiftLanguageMode]? = nil,
        cLanguageStandard: CLanguageStandard? = nil,
        cxxLanguageStandard: CXXLanguageStandard? = nil
    ) {
        self.name = name
        self.defaultLocalization = defaultLocalization
        self.platforms = platforms
        self.pkgConfig = pkgConfig
        self.providers = providers
        self.products = products
        self.dependencies = dependencies
        self.targets = targets
        self.swiftLanguageModes = swiftLanguageModes
        self.cLanguageStandard = cLanguageStandard
        self.cxxLanguageStandard = cxxLanguageStandard
        registerExitHandler()
    }


    private func registerExitHandler() {
        // Add a custom exit handler to cause the package's JSON representation
        // to be dumped at exit, if requested.  Emitting it to a separate file
        // descriptor from stdout keeps any of the manifest's stdout output from
        // interfering with it.
        //
        // FIXME: This doesn't belong here, but for now is the mechanism we use
        // to get the interpreter to dump the package when attempting to load a
        // manifest.
        //
        // Warning:  The `-fileno` flag is a contract between PackageDescription
        // and libSwiftPM, and since different versions of the two can be used
        // together, it isn't safe to rename or remove it.
        //
        // Note: `-fileno` is not viable on Windows.  Instead, we pass the file
        // handle through the `-handle` option.
#if os(Windows)
        if let index = CommandLine.arguments.firstIndex(of: "-handle") {
            if let handle = Int(CommandLine.arguments[index + 1], radix: 16) {
                dumpPackageAtExit(self, to: handle)
            }
        }
#else
        if let optIdx = CommandLine.arguments.firstIndex(of: "-fileno") {
            if let jsonOutputFileDesc = Int32(CommandLine.arguments[optIdx + 1]) {
                dumpPackageAtExit(self, to: jsonOutputFileDesc)
            }
        }
#endif
    }
}

/// A wrapper around an IETF language tag.
///
/// To learn more about the IETF worldwide standard for language tags, see
/// [RFC5646](https://tools.ietf.org/html/rfc5646).
public struct LanguageTag: Hashable {

    /// An IETF BCP 47 standard language tag.
    let tag: String

    /// Creates a language tag from its [IETF BCP 47](https://datatracker.ietf.org/doc/html/rfc5646) string representation.
    ///
    /// - Parameter tag: The string representation of an IETF language tag.
    private init(_ tag: String) {
        self.tag = tag
    }
}

extension LanguageTag: RawRepresentable {
    public var rawValue: String { tag }

    /// Creates a new instance with the specified raw value.
    ///
    /// If there's no value of the type that corresponds with the specified raw
    /// value, this initializer returns `nil`.
    ///
    /// - Parameter rawValue: The raw value to use for the new instance.
    public init?(rawValue: String) {
        tag = rawValue
    }
}

/// ExpressibleByStringLiteral implementation.
extension LanguageTag: ExpressibleByStringLiteral {
    
    /// Creates an instance initialized to the given value.
    ///
    /// - Parameter value: The value of the new instance.
    public init(stringLiteral value: String) {
        tag = value
    }

    /// Creates an instance initialized to the given value.
    /// - Parameter value: The value of the new instance.
    public init(extendedGraphemeClusterLiteral value: String) {
        self.init(stringLiteral: value)
    }

    /// Creates an instance initialized to the given value.
    ///
    /// - Parameter value: The value of the new instance.
    public init(unicodeScalarLiteral value: String) {
        self.init(stringLiteral: value)
    }
}

extension LanguageTag: CustomStringConvertible {

    /// A textual representation of the language tag.
    public var description: String { tag }
}

/// The system package providers that this package uses.
public enum SystemPackageProvider {

    /// Packages installable by the HomeBrew package manager.
    case brewItem([String])
    /// Packages installable by the apt-get package manager.
    case aptItem([String])
    /// Packages installable by the Yellowdog Updated, Modified (YUM) package manager.
    @available(_PackageDescription, introduced: 5.3)
    case yumItem([String])
    /// Packages installable by the NuGet package manager.
    @available(_PackageDescription, introduced: 999.0)
    case nugetItem([String])

    /// Creates a system package provider with a list of installable packages
    /// for people who use the HomeBrew package manager on macOS.
    ///
    /// - Parameter packages: The list of package names.
    ///
    /// - Returns: A package provider.
    public static func brew(_ packages: [String]) -> SystemPackageProvider {
        return .brewItem(packages)
    }

    /// Creates a system package provider with a list of installable packages
    /// for users of the apt-get package manager on Ubuntu Linux.
    ///
    /// - Parameter packages: The list of package names.
    ///
    /// - Returns: A package provider.
    public static func apt(_ packages: [String]) -> SystemPackageProvider {
        return .aptItem(packages)
    }

    /// Creates a system package provider with a list of installable packages
    /// for users of the yum package manager on Red Hat Enterprise Linux or
    /// CentOS.
    ///
    /// - Parameter packages: The list of package names.
    ///
    /// - Returns: A package provider.
    @available(_PackageDescription, introduced: 5.3)
    public static func yum(_ packages: [String]) -> SystemPackageProvider {
        return .yumItem(packages)
    }

    /// Creates a system package provider with a list of installable packages
    /// for users of the NuGet package manager on Linux or Windows.
    ///
    /// - Parameter packages: The list of package names.
    ///
    /// - Returns: A package provider.
    @available(_PackageDescription, introduced: 999.0)
    public static func nuget(_ packages: [String]) -> SystemPackageProvider {
        return .nugetItem(packages)
    }
}

// MARK: - Package Dumping

private func manifestToJSON(_ package: Package) -> String {
    struct Output: Codable {
        let package: Serialization.Package
        let errors: [String]
        let version: Int
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try! encoder.encode(Output(package: .init(package), errors: errors, version: 2))
    return String(decoding: data, as: UTF8.self)
}

var errors: [String] = []

#if os(Windows)
private var dumpInfo: (package: Package, handle: Int)?
private func dumpPackageAtExit(_ package: Package, to handle: Int) {
    let dump: @convention(c) () -> Void = {
        guard let dumpInfo else { return }

        let hFile: HANDLE = HANDLE(bitPattern: dumpInfo.handle)!
        // NOTE: `_open_osfhandle` transfers ownership of the `HANDLE` to the file
        // descriptor.  DO NOT invoke `CloseHandle` on `hFile`.
        let fd: CInt = _open_osfhandle(Int(bitPattern: hFile), _O_APPEND)
        // NOTE: `_fdopen` transfers ownership of the file descriptor to the
        // `FILE *`.  DO NOT invoke `_close` on the `fd`.
        guard let fp = _fdopen(fd, "w") else {
            _close(fd)
            return
        }
        defer { fclose(fp) }

        fputs(manifestToJSON(dumpInfo.package), fp)
    }

    dumpInfo = (package, handle)
    atexit(dump)
}
#else
private var dumpInfo: (package: Package, fileDesc: Int32)?
private func dumpPackageAtExit(_ package: Package, to fileDesc: Int32) {
    func dump() {
        guard let dumpInfo else { return }
        guard let fd = fdopen(dumpInfo.fileDesc, "w") else { return }
        fputs(manifestToJSON(dumpInfo.package), fd)
        fclose(fd)
    }
    dumpInfo = (package, fileDesc)
    atexit(dump)
}
#endif
