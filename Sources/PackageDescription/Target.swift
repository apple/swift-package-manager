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

@_implementationOnly import Foundation

/// The basic building block of a Swift package.
///
/// Each target contains a set of source files that Swift Package Manager compiles into a module
/// or test suite. You can vend targets to other packages by defining products
/// that include the targets.
///
/// A target may depend on other targets within the same package and on products
/// vended by the package's dependencies.
public final class Target {

    /// The different types of a target.
    public enum TargetType: String {
        /// A target that contains code for the Swift package's functionality.
        case regular
        /// A target that contains code for an executable's main module.
        case executable
        /// A target that contains tests for the Swift package's other targets.
        case test
        /// A target that adapts a library on the system to work with Swift
        /// packages.
        case system
        /// A target that references a binary artifact.
        case binary
        /// A target that provides a package plug-in.
        case plugin
        /// A target that provides a Swift macro.
        case `macro`
    }

    /// The different types of a target's dependency on another entity.
    public enum Dependency {
        /// A dependency on a target.
        ///
        ///  - Parameters:
        ///    - name: The name of the target.
        ///    - condition: A condition that limits the application of the target dependency. For example, only apply a dependency for a specific platform.
        case targetItem(name: String, condition: TargetDependencyCondition?)
        /// A dependency on a product.
        ///
        /// - Parameters:
        ///    - name: The name of the product.
        ///    - package: The name of the package.
        ///    - moduleAlias: The module aliases for targets in the product.
        ///    - condition: A condition that limits the application of the target dependency. For example, only apply a dependency for a specific platform.
        case productItem(name: String, package: String?, moduleAliases: [String: String]?, condition: TargetDependencyCondition?)
        /// A by-name dependency on either a target or a product.
        ///
        /// - Parameters:
        ///   - name: The name of the dependency, either a target or a product.
        ///   - condition: A condition that limits the application of the target
        ///     dependency. For example, only apply a dependency for a specific
        ///     platform.
        case byNameItem(name: String, condition: TargetDependencyCondition?)
    }

    /// The name of the target.
    public var name: String

    /// The path of the target, relative to the package root.
    ///
    /// If the path is `nil`, Swift Package Manager looks for a target's source files at
    /// predefined search paths and in a subdirectory with the target's name.
    ///
    /// The predefined search paths are the following directories under the
    /// package root:
    ///
    /// - `Sources`, `Source`, `src`, and `srcs` for regular targets
    /// - `Tests`, `Sources`, `Source`, `src`, and `srcs` for test targets
    ///
    /// For example, Swift Package Manager looks for source files inside the
    /// `[PackageRoot]/Sources/[TargetName]` directory.
    ///
    /// Don't escape the package root; that is, values like `../Foo` or `/Foo`
    /// are invalid.
    public var path: String?

    /// The URL of a binary target.
    ///
    /// The URL points to an archive file that contains the referenced binary
    /// artifact at its root.
    ///
    /// Binary targets are only available on Apple platforms.
    @available(_PackageDescription, introduced: 5.3)
    public var url: String?

    /// The source files in this target.
    ///
    /// If this property is `nil`, Swift Package Manager includes all valid source files in the
    /// target's path and treats specified paths as relative to the target's
    /// path.
    ///
    /// A path can be a path to a directory or an individual source file. In
    /// case of a directory, Swift Package Manager searches for valid source files recursively
    /// inside it.
    public var sources: [String]?

    /// The explicit list of resource files in the target.
    @available(_PackageDescription, introduced: 5.3)
    public var resources: [Resource]?

    /// The paths to source and resource files that you don't want to include in the target.
    ///
    /// Excluded paths are relative to the target path. This property has
    /// precedence over the `sources` and `resources` properties.
    public var exclude: [String]

    /// A Boolean value that indicates whether this is a test target.
    public var isTest: Bool {
        return type == .test
    }

    /// The target's dependencies on other entities inside or outside the package.
    public var dependencies: [Dependency]

    /// The path to the directory that contains public headers of a C-family target.
    ///
    /// If this is `nil`, the directory is set to `include`.
    public var publicHeadersPath: String?

    /// The type of the target.
    public let type: TargetType

    /// If true, access to package declarations from other targets in the package is allowed.
    public let packageAccess: Bool

    /// The name of the package configuration file, without extension, for the system library target.
    ///
    /// If present, the Swift Package Manager tries every package configuration
    /// name separated by a space to search for the `<name>.pc` file
    /// to get the additional flags needed for the system library target.
    public let pkgConfig: String?

    /// The providers array for a system library target.
    public let providers: [SystemPackageProvider]?

    /// The capability provided by a package plug-in target.
    @available(_PackageDescription, introduced: 5.5)
    public var pluginCapability: PluginCapability?

    /// The different types of capability that a plug-in can provide.
    ///
    /// In this version of SwiftPM, only build tool and command plug-ins are supported;
    /// this enumeration will be extended as new plug-in capabilities are added.
    public enum PluginCapability {
        /// Specifies that the plug-in provides a build tool capability.
        ///
        /// The plug-in to apply to each target that uses it, and creates commands
        /// that run before or during the build of the target.
        @available(_PackageDescription, introduced: 5.5)
        case buildTool

        /// Specifies that the plug-in provides a user command capability.
        ///
        ///- Parameters:
        ///   - intent: The semantic intent of the plug-in; either one of the predefined intents,
        ///     or a custom intent.
        ///   - permissions: Any permissions needed by the command plug-in. This affects what the
        ///     sandbox in which the plug-in is run allows. Some permissions may require
        ///     user approval.
        ///
        /// Plug-ins that specify a `command` capability define commands that can run
        /// using the SwiftPM command line interface, or in an IDE that supports
        /// Swift packages. You can invoke the command manually on one or more targets in a package.
        ///
        ///```swift
        ///swift package <verb>
        ///```
        ///
        /// The package can specify the _verb_ used to invoke the command.
        @available(_PackageDescription, introduced: 5.6)
        case command(intent: PluginCommandIntent, permissions: [PluginPermission] = [])
    }

    /// The target's C build settings.
    @available(_PackageDescription, introduced: 5)
    public var cSettings: [CSetting]?

    /// The target's C++ build settings.
    @available(_PackageDescription, introduced: 5)
    public var cxxSettings: [CXXSetting]?

    /// The target's Swift build settings.
    @available(_PackageDescription, introduced: 5)
    public var swiftSettings: [SwiftSetting]?

    /// The target's linker settings.
    @available(_PackageDescription, introduced: 5)
    public var linkerSettings: [LinkerSetting]?
 
    /// The checksum for the archive file that contains the referenced binary
    /// artifact.
    ///
    /// If you make a remote binary framework available as a Swift package,
    /// declare a remote, or _URL-based_, binary target in your package manifest
    /// with ``Target/binaryTarget(name:url:checksum:)``. Always run `swift
    /// package compute-checksum path/to/MyFramework.zip` at the command line to
    /// make sure you create a correct SHA256 checksum.
    ///
    /// For more information, see
    /// <doc:distributing-binary-frameworks-as-swift-packages>.
    @available(_PackageDescription, introduced: 5.3)
    public var checksum: String?

    /// The uses of package plug-ins by the target.
    @available(_PackageDescription, introduced: 5.5)
    public var plugins: [PluginUsage]?
    
    /// A plug-in used in a target.
    @available(_PackageDescription, introduced: 5.5)
    public enum PluginUsage {
        /// Specifies the use of a plug-in product in a package dependency.
        ///
        /// - Parameters:
        ///   - name: The name of the plug-in target.
        ///   - package: The name of the package that defines the plug-in target.
        case plugin(name: String, package: String?)
    }

    /// Construct a target.
    @_spi(PackageDescriptionInternal)
    public init(
        name: String,
        dependencies: [Dependency],
        path: String?,
        url: String? = nil,
        exclude: [String],
        sources: [String]?,
        resources: [Resource]? = nil,
        publicHeadersPath: String?,
        type: TargetType,
        packageAccess: Bool,
        pkgConfig: String? = nil,
        providers: [SystemPackageProvider]? = nil,
        pluginCapability: PluginCapability? = nil,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil,
        checksum: String? = nil,
        plugins: [PluginUsage]? = nil
    ) {
        self.name = name
        self.dependencies = dependencies
        self.path = path
        self.url = url
        self.publicHeadersPath = publicHeadersPath
        self.sources = sources
        self.resources = resources
        self.exclude = exclude
        self.type = type
        self.packageAccess = packageAccess
        self.pkgConfig = pkgConfig
        self.providers = providers
        self.pluginCapability = pluginCapability
        self.cSettings = cSettings
        self.cxxSettings = cxxSettings
        self.swiftSettings = swiftSettings
        self.linkerSettings = linkerSettings
        self.checksum = checksum
        self.plugins = plugins

        switch type {
        case .regular, .executable, .test:
            precondition(
                url == nil &&
                pkgConfig == nil &&
                providers == nil &&
                pluginCapability == nil &&
                checksum == nil
            )
        case .system:
            precondition(
                url == nil &&
                dependencies.isEmpty &&
                exclude.isEmpty &&
                sources == nil &&
                resources == nil &&
                publicHeadersPath == nil &&
                pluginCapability == nil &&
                cSettings == nil &&
                cxxSettings == nil &&
                swiftSettings == nil &&
                linkerSettings == nil &&
                checksum == nil &&
                plugins == nil
            )
        case .binary:
            precondition(
                dependencies.isEmpty &&
                exclude.isEmpty &&
                sources == nil &&
                resources == nil &&
                publicHeadersPath == nil &&
                pkgConfig == nil &&
                providers == nil &&
                pluginCapability == nil &&
                cSettings == nil &&
                cxxSettings == nil &&
                swiftSettings == nil &&
                linkerSettings == nil &&
                plugins == nil
            )
        case .plugin:
            precondition(
                url == nil &&
                resources == nil &&
                publicHeadersPath == nil &&
                pkgConfig == nil &&
                providers == nil &&
                pluginCapability != nil &&
                cSettings == nil &&
                cxxSettings == nil &&
                swiftSettings == nil &&
                linkerSettings == nil &&
                plugins == nil
            )
        case .macro:
            precondition(
                url == nil &&
                resources == nil &&
                publicHeadersPath == nil &&
                pkgConfig == nil &&
                providers == nil &&
                pluginCapability == nil &&
                cSettings == nil &&
                cxxSettings == nil
            )
        }
    }

    /// Creates a library or executable target.
    ///
    /// A target can contain either Swift or C-family source files, but not both. The Swift Package Manager
    /// considers a target to be an executable target if its directory contains a `main.swift`, `main.m`, `main.c`,
    /// or `main.cpp` file. The Swift Package Manager considers all other targets to be library targets.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
    ///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
    ///       for example, `[PackageRoot]/Sources/[TargetName]`.
    ///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
    ///   - exclude: A list of paths to files or directories that the Swift Package Manager shouldn't consider to be source or resource files.
    ///       A path is relative to the target's directory.
    ///       This parameter has precedence over the ``sources`` parameter.
    ///   - sources: An explicit list of source files. If you provide a path to a directory,
    ///       the Swift Package Manager searches for valid source files recursively.
    ///   - publicHeadersPath: The directory containing public headers of a C-family library target.
    @available(_PackageDescription, introduced: 4, obsoleted: 5)
    public static func target(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        publicHeadersPath: String? = nil
    ) -> Target {
        return Target(
            name: name,
            dependencies: dependencies,
            path: path,
            exclude: exclude,
            sources: sources,
            publicHeadersPath: publicHeadersPath,
            type: .regular,
            packageAccess: false
        )
    }

    /// Creates a library or executable target.
    ///
    /// A target can contain either Swift or C-family source files, but not both. The Swift Package Manager
    /// considers a target to be an executable target if its directory contains a `main.swift`, `main.m`, `main.c`,
    /// or `main.cpp` file. The Swift Package Manager considers all other targets to be library targets.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
    ///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
    ///       for example, `[PackageRoot]/Sources/[TargetName]`.
    ///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
    ///   - exclude: A list of paths to files or directories that the Swift Package Manager shouldn't consider to be source or resource files.
    ///       Paths are relative to the target's directory.
    ///       This parameter has precedence over the ``sources`` parameter.
    ///   - sources: An explicit list of source files. If you provide a path to a directory,
    ///       the Swift Package Manager searches for valid source files recursively.
    ///   - publicHeadersPath: The directory containing public headers of a C-family library target.
    ///   - cSettings: The C settings for this target.
    ///   - cxxSettings: The C++ settings for this target.
    ///   - swiftSettings: The Swift settings for this target.
    ///   - linkerSettings: The linker settings for this target.
    @available(_PackageDescription, introduced: 5, obsoleted: 5.3)
    public static func target(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        publicHeadersPath: String? = nil,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil
    ) -> Target {
        return Target(
            name: name,
            dependencies: dependencies,
            path: path,
            exclude: exclude,
            sources: sources,
            publicHeadersPath: publicHeadersPath,
            type: .regular,
            packageAccess: false,
            cSettings: cSettings,
            cxxSettings: cxxSettings,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings
        )
    }

    /// Creates a regular target.
    ///
    /// A target can contain either Swift or C-family source files, but not both. It contains code that is built as
    /// a regular module that can be included in a library or executable product, but that cannot itself be used as
    /// the main target of an executable product.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
    ///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
    ///       for example, `[PackageRoot]/Sources/[TargetName]`.
    ///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
    ///   - exclude: A list of paths to files or directories that the Swift Package Manager shouldn't consider to be source or resource files.
    ///       A path is relative to the target's directory.
    ///       This parameter has precedence over the ``sources`` parameter.
    ///   - sources: An explicit list of source files. If you provide a path to a directory,
    ///       the Swift Package Manager searches for valid source files recursively.
    ///   - resources: An explicit list of resources files.
    ///   - publicHeadersPath: The directory containing public headers of a C-family library target.
    ///   - cSettings: The C settings for this target.
    ///   - cxxSettings: The C++ settings for this target.
    ///   - swiftSettings: The Swift settings for this target.
    ///   - linkerSettings: The linker settings for this target.
    @available(_PackageDescription, introduced: 5.3, obsoleted: 5.5)
    public static func target(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        resources: [Resource]? = nil,
        publicHeadersPath: String? = nil,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil
    ) -> Target {
        return Target(
            name: name,
            dependencies: dependencies,
            path: path,
            exclude: exclude,
            sources: sources,
            resources: resources,
            publicHeadersPath: publicHeadersPath,
            type: .regular,
            packageAccess: false,
            cSettings: cSettings,
            cxxSettings: cxxSettings,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings
        )
    }

    /// Creates a regular target.
    ///
    /// A target can contain either Swift or C-family source files, but not both. It contains code that is built as
    /// a regular module that can be included in a library or executable product, but that cannot itself be used as
    /// the main target of an executable product.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
    ///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
    ///       for example, `[PackageRoot]/Sources/[TargetName]`.
    ///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
    ///   - exclude: A list of paths to files or directories that the Swift Package Manager shouldn't consider to be source or resource files.
    ///       A path is relative to the target's directory.
    ///       This parameter has precedence over the ``sources`` parameter.
    ///   - sources: An explicit list of source files. If you provide a path to a directory,
    ///       the Swift Package Manager searches for valid source files recursively.
    ///   - resources: An explicit list of resources files.
    ///   - publicHeadersPath: The directory containing public headers of a C-family library target.
    ///   - cSettings: The C settings for this target.
    ///   - cxxSettings: The C++ settings for this target.
    ///   - swiftSettings: The Swift settings for this target.
    ///   - linkerSettings: The linker settings for this target.
    ///   - plugins: The plug-ins used by this target.
    @available(_PackageDescription, introduced: 5.5, obsoleted: 5.9)
    public static func target(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        resources: [Resource]? = nil,
        publicHeadersPath: String? = nil,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil,
        plugins: [PluginUsage]? = nil
    ) -> Target {
        return Target(
            name: name,
            dependencies: dependencies,
            path: path,
            exclude: exclude,
            sources: sources,
            resources: resources,
            publicHeadersPath: publicHeadersPath,
            type: .regular,
            packageAccess: false,
            cSettings: cSettings,
            cxxSettings: cxxSettings,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings,
            plugins: plugins
        )
    }

    /// Creates a regular target.
    ///
    /// A target can contain either Swift or C-family source files, but not both. It contains code that is built as
    /// a regular module for inclusion in a library or executable product, but that cannot itself be used as
    /// the main target of an executable product.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
    ///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
    ///       for example, `[PackageRoot]/Sources/[TargetName]`.
    ///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
    ///   - exclude: A list of paths to files or directories that the Swift Package Manager shouldn't consider to be source or resource files.
    ///       A path is relative to the target's directory.
    ///       This parameter has precedence over the ``sources`` parameter.
    ///   - sources: An explicit list of source files. If you provide a path to a directory,
    ///       Swift Package Manager searches for valid source files recursively.
    ///   - resources: An explicit list of resources files.
    ///   - publicHeadersPath: The directory that contains public headers of a C-family library target.
    ///   - packageAccess: Allows package symbols from other targets in the package.
    ///   - cSettings: The C settings for this target.
    ///   - cxxSettings: The C++ settings for this target.
    ///   - swiftSettings: The Swift settings for this target.
    ///   - linkerSettings: The linker settings for this target.
    ///   - plugins: The plug-ins used by this target
    @available(_PackageDescription, introduced: 5.9)
    public static func target(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        resources: [Resource]? = nil,
        publicHeadersPath: String? = nil,
        packageAccess: Bool = true,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil,
        plugins: [PluginUsage]? = nil
    ) -> Target {
        return Target(
            name: name,
            dependencies: dependencies,
            path: path,
            exclude: exclude,
            sources: sources,
            resources: resources,
            publicHeadersPath: publicHeadersPath,
            type: .regular,
            packageAccess: packageAccess,
            cSettings: cSettings,
            cxxSettings: cxxSettings,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings,
            plugins: plugins
        )
    }

    /// Creates an executable target.
    ///
    /// An executable target can contain either Swift or C-family source files, but not both. It contains code that
    /// is built as an executable module that can be used as the main target of an executable product. The target
    /// is expected to either have a source file named `main.swift`, `main.m`, `main.c`, or `main.cpp`, or a source
    /// file that contains the `@main` keyword.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
    ///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
    ///       for example, `[PackageRoot]/Sources/[TargetName]`.
    ///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
    ///   - exclude: A list of paths to files or directories that the Swift Package Manager shouldn't consider to be source or resource files.
    ///       A path is relative to the target's directory.
    ///       This parameter has precedence over the ``sources`` parameter.
    ///   - sources: An explicit list of source files. If you provide a path to a directory,
    ///       the Swift Package Manager searches for valid source files recursively.
    ///   - resources: An explicit list of resources files.
    ///   - publicHeadersPath: The directory containing public headers of a C-family library target.
    ///   - cSettings: The C settings for this target.
    ///   - cxxSettings: The C++ settings for this target.
    ///   - swiftSettings: The Swift settings for this target.
    ///   - linkerSettings: The linker settings for this target.
    @available(_PackageDescription, introduced: 5.4, obsoleted: 5.5)
    public static func executableTarget(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        resources: [Resource]? = nil,
        publicHeadersPath: String? = nil,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil
    ) -> Target {
        return Target(
            name: name,
            dependencies: dependencies,
            path: path,
            exclude: exclude,
            sources: sources,
            resources: resources,
            publicHeadersPath: publicHeadersPath,
            type: .executable,
            packageAccess: false,
            cSettings: cSettings,
            cxxSettings: cxxSettings,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings
        )
    }

    /// Creates an executable target.
    ///
    /// An executable target can contain either Swift or C-family source files, but not both. It contains code that
    /// is built as an executable module that can be used as the main target of an executable product. The target
    /// is expected to either have a source file named `main.swift`, `main.m`, `main.c`, or `main.cpp`, or a source
    /// file that contains the `@main` keyword.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
    ///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
    ///       for example, `[PackageRoot]/Sources/[TargetName]`.
    ///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
    ///   - exclude: A list of paths to files or directories that the Swift Package Manager shouldn't consider to be source or resource files.
    ///       A path is relative to the target's directory.
    ///       This parameter has precedence over the ``sources`` parameter.
    ///   - sources: An explicit list of source files. If you provide a path to a directory,
    ///       the Swift Package Manager searches for valid source files recursively.
    ///   - resources: An explicit list of resources files.
    ///   - publicHeadersPath: The directory containing public headers of a C-family library target.
    ///   - cSettings: The C settings for this target.
    ///   - cxxSettings: The C++ settings for this target.
    ///   - swiftSettings: The Swift settings for this target.
    ///   - linkerSettings: The linker settings for this target.
    ///   - plugins: The plug-ins used by this target.
    @available(_PackageDescription, introduced: 5.5, obsoleted: 5.9)
    public static func executableTarget(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        resources: [Resource]? = nil,
        publicHeadersPath: String? = nil,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil,
        plugins: [PluginUsage]? = nil
    ) -> Target {
        return Target(
            name: name,
            dependencies: dependencies,
            path: path,
            exclude: exclude,
            sources: sources,
            resources: resources,
            publicHeadersPath: publicHeadersPath,
            type: .executable,
            packageAccess: false,
            cSettings: cSettings,
            cxxSettings: cxxSettings,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings,
            plugins: plugins
        )
    }
    /// Creates an executable target.
    ///
    /// An executable target can contain either Swift or C-family source files, but not both. It contains code that
    /// is built as an executable module for use as the main target of an executable product. The target
    /// is expected to either have a source file named `main.swift`, `main.m`, `main.c`, or `main.cpp`, or a source
    /// file that contains the `@main` keyword.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
    ///   - path: The custom path for the target. By default, Swift Package Manager requires a target's sources to reside at predefined search paths;
    ///       for example, `[PackageRoot]/Sources/[TargetName]`.
    ///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
    ///   - exclude: A list of paths to files or directories that Swift Package Manager shouldn't consider to be source or resource files.
    ///       A path is relative to the target's directory.
    ///       This parameter has precedence over the ``sources`` parameter.
    ///   - sources: An explicit list of source files. If you provide a path to a directory,
    ///       Swift Package Manager searches for valid source files recursively.
    ///   - resources: An explicit list of resources files.
    ///   - publicHeadersPath: The directory that contains public headers of a C-family library target.
    ///   - packageAccess: Allows package symbols from other targets in the package.
    ///   - cSettings: The C settings for this target.
    ///   - cxxSettings: The C++ settings for this target.
    ///   - swiftSettings: The Swift settings for this target.
    ///   - linkerSettings: The linker settings for this target.
    ///   - plugins: The plug-ins used by this target
    @available(_PackageDescription, introduced: 5.9)
    public static func executableTarget(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        resources: [Resource]? = nil,
        publicHeadersPath: String? = nil,
        packageAccess: Bool = true,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil,
        plugins: [PluginUsage]? = nil
    ) -> Target {
        return Target(
            name: name,
            dependencies: dependencies,
            path: path,
            exclude: exclude,
            sources: sources,
            resources: resources,
            publicHeadersPath: publicHeadersPath,
            type: .executable,
            packageAccess: packageAccess,
            cSettings: cSettings,
            cxxSettings: cxxSettings,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings,
            plugins: plugins
        )
    }

    /// Creates a test target.
    ///
    /// Write test targets using the XCTest testing framework.
    /// Test targets generally declare a dependency on the targets they test.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
    ///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
    ///       for example, `[PackageRoot]/Sources/[TargetName]`.
    ///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
    ///   - exclude: A list of paths to files or directories that the Swift Package Manager shouldn't consider to be source or resource files.
    ///       A path is relative to the target's directory.
    ///       This parameter has precedence over the ``sources`` parameter.
    ///   - sources: An explicit list of source files. If you provide a path to a directory,
    ///       the Swift Package Manager searches for valid source files recursively.
    @available(_PackageDescription, introduced: 4, obsoleted: 5)
    public static func testTarget(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil
    ) -> Target {
        return Target(
            name: name,
            dependencies: dependencies,
            path: path,
            exclude: exclude,
            sources: sources,
            publicHeadersPath: nil,
            type: .test,
            packageAccess: false
        )
    }

    /// Creates a test target.
    ///
    /// Write test targets using the XCTest testing framework.
    /// Test targets generally declare a dependency on the targets they test.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
    ///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
    ///       for example, `[PackageRoot]/Sources/[TargetName]`.
    ///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
    ///   - exclude: A list of paths to files or directories that the Swift Package Manager shouldn't consider to be source or resource files.
    ///       A path is relative to the target's directory.
    ///       This parameter has precedence over the ``sources`` parameter.
    ///   - sources: An explicit list of source files. If you provide a path to a directory,
    ///       the Swift Package Manager searches for valid source files recursively.
    ///   - cSettings: The C settings for this target.
    ///   - cxxSettings: The C++ settings for this target.
    ///   - swiftSettings: The Swift settings for this target.
    ///   - linkerSettings: The linker settings for this target.
    @available(_PackageDescription, introduced: 5, obsoleted: 5.3)
    public static func testTarget(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil
    ) -> Target {
        return Target(
            name: name,
            dependencies: dependencies,
            path: path,
            exclude: exclude,
            sources: sources,
            publicHeadersPath: nil,
            type: .test,
            packageAccess: false,
            cSettings: cSettings,
            cxxSettings: cxxSettings,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings
        )
    }

    /// Creates a test target.
    ///
    /// Write test targets using the XCTest testing framework.
    /// Test targets generally declare a dependency on the targets they test.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
    ///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
    ///       for example, `[PackageRoot]/Sources/[TargetName]`.
    ///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
    ///   - exclude: A list of paths to files or directories that the Swift Package Manager shouldn't consider to be source or resource files.
    ///       A path is relative to the target's directory.
    ///       This parameter has precedence over the ``sources`` parameter.
    ///   - sources: An explicit list of source files. If you provide a path to a directory,
    ///       the Swift Package Manager searches for valid source files recursively.
    ///   - resources: An explicit list of resources files.
    ///   - cSettings: The C settings for this target.
    ///   - cxxSettings: The C++ settings for this target.
    ///   - swiftSettings: The Swift settings for this target.
    ///   - linkerSettings: The linker settings for this target.
    @available(_PackageDescription, introduced: 5.3, obsoleted: 5.5)
    public static func testTarget(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        resources: [Resource]? = nil,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil
    ) -> Target {
        return Target(
            name: name,
            dependencies: dependencies,
            path: path,
            exclude: exclude,
            sources: sources,
            resources: resources,
            publicHeadersPath: nil,
            type: .test,
            packageAccess: false,
            cSettings: cSettings,
            cxxSettings: cxxSettings,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings
        )
    }

    /// Creates a test target.
    ///
    /// Write test targets using the XCTest testing framework.
    /// Test targets generally declare a dependency on the targets they test.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
    ///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
    ///       for example, `[PackageRoot]/Sources/[TargetName]`.
    ///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
    ///   - exclude: A list of paths to files or directories that the Swift Package Manager shouldn't consider to be source or resource files.
    ///       A path is relative to the target's directory.
    ///       This parameter has precedence over the ``sources`` parameter.
    ///   - sources: An explicit list of source files. If you provide a path to a directory,
    ///       the Swift Package Manager searches for valid source files recursively.
    ///   - resources: An explicit list of resources files.
    ///   - cSettings: The C settings for this target.
    ///   - cxxSettings: The C++ settings for this target.
    ///   - swiftSettings: The Swift settings for this target.
    ///   - linkerSettings: The linker settings for this target.
    ///   - plugins: The plug-ins used by this target.
    @available(_PackageDescription, introduced: 5.5, obsoleted: 5.9)
    public static func testTarget(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        resources: [Resource]? = nil,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil,
        plugins: [PluginUsage]? = nil
    ) -> Target {
        return Target(
            name: name,
            dependencies: dependencies,
            path: path,
            exclude: exclude,
            sources: sources,
            resources: resources,
            publicHeadersPath: nil,
            type: .test,
            packageAccess: false,
            cSettings: cSettings,
            cxxSettings: cxxSettings,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings,
            plugins: plugins
        )
    }

    /// Creates a test target.
    ///
    /// Write test targets using the XCTest testing framework.
    /// Test targets generally declare a dependency on the targets they test.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
    ///   - path: The custom path for the target. By default, Swift Package Manager requires a target's sources to reside at predefined search paths;
    ///       for example, `[PackageRoot]/Sources/[TargetName]`.
    ///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
    ///   - exclude: A list of paths to files or directories that Swift Package Manager shouldn't consider to be source or resource files.
    ///       A path is relative to the target's directory.
    ///       This parameter has precedence over the ``sources`` parameter.
    ///   - sources: An explicit list of source files. If you provide a path to a directory,
    ///       Swift Package Manager searches for valid source files recursively.
    ///   - resources: An explicit list of resources files.
    ///   - packageAccess: Allows access to package symbols from other targets in the package.
    ///   - cSettings: The C settings for this target.
    ///   - cxxSettings: The C++ settings for this target.
    ///   - swiftSettings: The Swift settings for this target.
    ///   - linkerSettings: The linker settings for this target.
    ///   - plugins: The plug-ins used by this target.
    @available(_PackageDescription, introduced: 5.9)
    public static func testTarget(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        resources: [Resource]? = nil,
        packageAccess: Bool = true,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil,
        plugins: [PluginUsage]? = nil
    ) -> Target {
        return Target(
            name: name,
            dependencies: dependencies,
            path: path,
            exclude: exclude,
            sources: sources,
            resources: resources,
            publicHeadersPath: nil,
            type: .test,
            packageAccess: packageAccess,
            cSettings: cSettings,
            cxxSettings: cxxSettings,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings,
            plugins: plugins
        )
    }

    /// Creates a system library target.
    ///
    /// Use system library targets to adapt a library installed on the system to
    /// work with Swift packages. Such libraries are generally installed by
    /// system package managers (such as Homebrew, MacPorts and apt-get) and exposed to
    /// Swift packages by providing a `modulemap` file along with other metadata
    /// such as the library's `pkgConfig` name.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - path: The custom path for the target. By default, a targets sources
    ///     are expected to be located in the predefined search paths, such as
    ///     `[PackageRoot]/Sources/[TargetName]`. Do not escape the package root;
    ///     that is, values like `../Foo` or `/Foo` are invalid.
    ///   - pkgConfig: The name of the `pkg-config` file for this system library.
    ///   - providers: The providers for this system library.
    public static func systemLibrary(
        name: String,
        path: String? = nil,
        pkgConfig: String? = nil,
        providers: [SystemPackageProvider]? = nil
    ) -> Target {
        return Target(
            name: name,
            dependencies: [],
            path: path,
            exclude: [],
            sources: nil,
            publicHeadersPath: nil,
            type: .system,
            packageAccess: false,
            pkgConfig: pkgConfig,
            providers: providers)
    }

    /// Creates a binary target that references a remote artifact.
    ///
    /// Binary targets are only available on Apple platforms.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - url: The URL to the binary artifact. This URL must point to an archive
    ///     file that contains a binary artifact in its root directory.
    ///   - checksum: The checksum of the archive file that contains the binary
    ///     artifact.
    @available(_PackageDescription, introduced: 5.3)
    public static func binaryTarget(
        name: String,
        url: String,
        checksum: String
    ) -> Target {
        return Target(
            name: name,
            dependencies: [],
            path: nil,
            url: url,
            exclude: [],
            sources: nil,
            publicHeadersPath: nil,
            type: .binary,
            packageAccess: false,
            checksum: checksum)
    }

    /// Creates a binary target that references an artifact on disk.
    ///
    /// Binary targets are only available on Apple platforms.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - path: The path to the binary artifact. This path can point directly to
    ///     a binary artifact or to an archive file that contains the binary
    ///     artifact at its root.
    @available(_PackageDescription, introduced: 5.3)
    public static func binaryTarget(
        name: String,
        path: String
    ) -> Target {
        return Target(
            name: name,
            dependencies: [],
            path: path,
            exclude: [],
            sources: nil,
            publicHeadersPath: nil,
            type: .binary,
            packageAccess: false)
    }
    
    /// Defines a new package plugin target.
    ///
    /// A plugin target provides custom build commands to SwiftPM (and to
    /// any IDEs based on libSwiftPM).
    ///
    /// The capability determines what kind of build commands it can add. Besides
    /// determining at what point in the build those commands run, the capability
    /// determines the context that is available to the plugin and the kinds of
    /// commands it can create.
    ///
    /// In the initial version of this proposal, three capabilities are provided:
    /// prebuild, build tool, and postbuild. See the declaration of each capability
    /// under ``PluginCapability-swift.enum`` for more information.
    ///
    /// The package plugin itself is implemented using a Swift script that is
    /// invoked for each target that uses it. The script is invoked after the
    /// package graph has been resolved, but before the build system creates its
    /// dependency graph. It is also invoked after changes to the target or the
    /// build parameters.
    ///
    /// Note that the role of the package plugin is only to define the commands
    /// that will run before, during, or after the build. It does not itself run
    /// those commands. The commands are defined in an IDE-neutral way, and are
    /// run as appropriate by the build system that builds the package. The extension
    /// itself is only a procedural way of generating commands and their input
    /// and output dependencies.
    ///
    /// The package plugin may specify the executable targets or binary targets
    /// that provide the build tools that will be used by the generated commands
    /// during the build. In the initial implementation, prebuild actions can only
    /// depend on binary targets. Build tool and postbuild plugins can depend
    /// on executables as well as binary targets. This is due to how
    /// Swift Package Manager constructs its build plan.
    ///
    /// - Parameters:
    ///   - name: The name of the plugin target.
    ///   - capability: The type of capability the plugin target provides.
    ///   - dependencies: The plugin target's dependencies.
    ///   - path: The path of the plugin target, relative to the package root.
    ///   - exclude: The paths to source and resource files that you want to exclude from the plug-in target.
    ///   - sources: The source files in the plug-in target.
    /// - Returns: A `Target` instance.
    @available(_PackageDescription, introduced: 5.5, obsoleted: 5.9)
    public static func plugin(
        name: String,
        capability: PluginCapability,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil
    ) -> Target {
        return Target(
            name: name,
            dependencies: dependencies,
            path: path,
            exclude: exclude,
            sources: sources,
            publicHeadersPath: nil,
            type: .plugin,
            packageAccess: false,
            pluginCapability: capability)
    }

    /// Defines a new package plug-in target.
    ///
    /// A plug-in target provides custom build commands to SwiftPM (and to
    /// any IDEs based on libSwiftPM).
    ///
    /// The capability determines what kind of build commands it can add. Besides
    /// determining at what point in the build those commands run, the capability
    /// determines the context that is available to the plug-in and the kinds of
    /// commands it can create.
    ///
    /// In the initial version of this proposal, three capabilities are provided:
    /// prebuild, build tool, and postbuild. For more information, see the declaration of each capability
    /// under ``PluginCapability-swift.enum``.
    ///
    /// The package plug-in itself is implemented using a Swift script that is
    /// invoked for each target that uses it. The script is invoked after the
    /// package graph has been resolved, but before the build system creates its
    /// dependency graph. It's also invoked after changes to the target or the
    /// build parameters.
    ///
    /// Note that the role of the package plug-in is only to define the commands
    /// that run before, during, or after the build. It doesn't run
    /// those commands itself. The commands are defined in an IDE-neutral way, and are
    /// run as appropriate by the build system that builds the package. The extension
    /// itself is only a procedural way of generating commands and their input
    /// and output dependencies.
    ///
    /// The package plug-in may specify the executable or binary targets
    /// that provide the build tools used by the generated commands
    /// during the build. In the initial implementation, prebuild actions can only
    /// depend on binary targets. Build tool and postbuild plug-ins can depend
    /// on executables as well as binary targets. This is due to how
    /// Swift Package Manager constructs its build plan.
    ///
    /// - Parameters:
    ///   - name: The name of the plug-in target.
    ///   - capability: The type of capability the plug-in target provides.
    ///   - dependencies: The plug-in target's dependencies.
    ///   - path: The path of the plug-in target relative to the package root.
    ///   - exclude: The paths to source and resource files that you want to exclude from the plug-in target.
    ///   - sources: The source files in the plug-in target.
    ///   - packageAccess: Allows access to package symbols from other targets in the package.
    /// - Returns: A `Target` instance.
    @available(_PackageDescription, introduced: 5.9)
    public static func plugin(
        name: String,
        capability: PluginCapability,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        packageAccess: Bool = true
    ) -> Target {
        return Target(
            name: name,
            dependencies: dependencies,
            path: path,
            exclude: exclude,
            sources: sources,
            publicHeadersPath: nil,
            type: .plugin,
            packageAccess: packageAccess,
            pluginCapability: capability)
    }
}

extension Target.Dependency {
    @available(_PackageDescription, obsoleted: 5.7, message: "use .product(name:package:condition) instead.")
    public static func productItem(name: String, package: String? = nil, condition: TargetDependencyCondition? = nil) -> Target.Dependency {
        return .productItem(name: name, package: package, moduleAliases: nil, condition: nil)
    }

    /// Creates a dependency on a target in the same package.
    ///
    /// - Parameter name: The name of the target.
    /// - Returns: A `Target.Dependency` instance.
    @available(_PackageDescription, obsoleted: 5.3)
    public static func target(name: String) -> Target.Dependency {
        return .targetItem(name: name, condition: nil)
    }

    /// Creates a dependency on a product from a package dependency.
    ///
    /// - Parameters:
    ///   - name: The name of the product.
    ///   - package: The name of the package.
    /// - Returns: A `Target.Dependency` instance.
@available(_PackageDescription, obsoleted: 5.2, message: "the 'package' argument is mandatory as of tools version 5.2")
    public static func product(name: String, package: String? = nil) -> Target.Dependency {
        return .productItem(name: name, package: package, moduleAliases: nil, condition: nil)
    }

    /// Creates a dependency that resolves to either a target or a product with the specified name.
    ///
    /// - Parameter name: The name of the dependency, either a target or a product.
    /// - Returns: A `Target.Dependency` instance.
    /// The Swift Package Manager creates the by-name dependency after it has loaded the package graph.
@available(_PackageDescription, obsoleted: 5.3)
    public static func byName(name: String) -> Target.Dependency {
        return .byNameItem(name: name, condition: nil)
    }

    /// Creates a dependency on a product from a package dependency.
    ///
    /// - Parameters:
    ///   - name: The name of the product.
    ///   - package: The name of the package.
    /// - Returns: A `Target.Dependency` instance.
@available(_PackageDescription, introduced: 5.2, obsoleted: 5.3)
    public static func product(
        name: String,
        package: String
    ) -> Target.Dependency {
        return .productItem(name: name, package: package, moduleAliases: nil, condition: nil)
    }

    /// Creates a dependency on a target in the same package.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - condition: A condition that limits the application of the target
    ///     dependency. For example, only apply a dependency for a specific
    ///     platform.
    /// - Returns: A `Target.Dependency` instance.
@available(_PackageDescription, introduced: 5.3)
    public static func target(name: String, condition: TargetDependencyCondition? = nil) -> Target.Dependency {
        return .targetItem(name: name, condition: condition)
    }

    /// Creates a target dependency on a product from a package dependency.
    ///
    /// - Parameters:
    ///   - name: The name of the product.
    ///   - package: The name of the package.
    ///   - condition: A condition that limits the application of the target
    ///     dependency. For example, only apply a dependency for a specific
    ///     platform.
    /// - Returns: A `Target.Dependency` instance.
@_disfavoredOverload
    @available(_PackageDescription, introduced: 5.3, obsoleted: 5.7)
    public static func product(
        name: String,
        package: String,
        condition: TargetDependencyCondition? = nil
    ) -> Target.Dependency {
        return .productItem(name: name, package: package, moduleAliases: nil, condition: condition)
    }

    /// Creates a target dependency on a product from a package dependency.
    ///
    /// - Parameters:
    ///   - name: The name of the product.
    ///   - package: The name of the package.
    ///   - moduleAliases: The module aliases for targets in the product.
    ///   - condition: A condition that limits the application of the target dependency. For example, only apply a
    ///       dependency for a specific platform.
    /// - Returns: A `Target.Dependency` instance.
@available(_PackageDescription, introduced: 5.7)
    public static func product(
      name: String,
      package: String,
      moduleAliases: [String: String]? = nil,
      condition: TargetDependencyCondition? = nil
    ) -> Target.Dependency {
        return .productItem(name: name, package: package, moduleAliases: moduleAliases, condition: condition)
    }

    /// Creates a dependency that resolves to either a target or a product with
    /// the specified name.
    ///
    /// Swift Package Manager creates the by-name dependency after it has loaded the package
    /// graph.
    ///
    /// - Parameters:
    ///   - name: The name of the dependency, either a target or a product.
    ///   - condition: A condition that limits the application of the target
    ///     dependency. For example, only apply a dependency for a specific
    ///     platform.
    /// - Returns: A `Target.Dependency` instance.
@available(_PackageDescription, introduced: 5.3)
    public static func byName(name: String, condition: TargetDependencyCondition? = nil) -> Target.Dependency {
        return .byNameItem(name: name, condition: condition)
    }
}

/// A condition that limits the application of a target's dependency.
public struct TargetDependencyCondition {
    let platforms: [Platform]?

    private init(platforms: [Platform]?) {
        self.platforms = platforms
    }

    /// Creates a target dependency condition.
    ///
    /// - Parameter platforms: The applicable platforms for this target dependency condition.
    @_disfavoredOverload
    @available(_PackageDescription, obsoleted: 5.7, message: "using .when with nil platforms is obsolete")
    public static func when(
        platforms: [Platform]? = nil
    ) -> TargetDependencyCondition {
        // FIXME: This should be an error, not a precondition.
        precondition(!(platforms == nil))
        return TargetDependencyCondition(platforms: platforms)
    }

    /// Creates a target dependency condition.
    ///
    /// - Parameter platforms: The applicable platforms for this target dependency condition.
    @available(_PackageDescription, introduced: 5.7)
    public static func when(
        platforms: [Platform]
    ) -> TargetDependencyCondition? {
        return !platforms.isEmpty ? TargetDependencyCondition(platforms: platforms) : .none
    }
}

extension Target.PluginCapability {
    
    /// The plug-in is a build tool.
    ///
    /// The plug-in to apply to each target that uses it, and creates commands
    /// that run before or during the build of the target.
    ///
    ///  - Returns: A plug-in capability that defines a build tool.
    @available(_PackageDescription, introduced: 5.5)
    public static func buildTool() -> Target.PluginCapability {
        return .buildTool
    }
}

/// The intended use case of the command plug-in.
@available(_PackageDescription, introduced: 5.6)
public enum PluginCommandIntent {
    /// The plug-in generates documentation.
    ///
    /// The command used to generate documentation, either by parsing the
    /// package contents directly or by using the build system support for generating
    /// symbol graphs. Invoked by a `generate-documentation` verb to `swift package`.
    case documentationGeneration

    /// The plug-in formats source code.
    ///
    /// The command used to modify the source code in the package based
    /// on a set of rules. Invoked by a `format-source-code` verb to `swift package`.
    case sourceCodeFormatting

    /// A custom command plug-in intent.
    ///
    ///  Use this case when none of the predefined cases fulfill the role of the plug-in.
    ///  - Parameters:
    ///    - verb: The invocation verb of the plug-in.
    ///    - description: A human readable description of the plug-in's role.
    case custom(verb: String, description: String)
}

@available(_PackageDescription, introduced: 5.6)
public extension PluginCommandIntent {
    /// The plugin generates documentation.
    ///
    /// The intent of the command is to generate documentation, either by parsing the
    /// package contents directly or by using the build system support for generating
    /// symbol graphs. Invoked by a `generate-documentation` verb to `swift package`.
    ///
    ///  - Returns: A `PluginCommandIntent` instance.
    static func documentationGeneration() -> PluginCommandIntent {
        return documentationGeneration
    }

    /// The plug-in formats source code.
    ///
    /// The intent of the command is to modify the source code in the package based
    /// on a set of rules. Invoked by a `format-source-code` verb to `swift package`.
    ///
    /// - Returns: A `PluginCommandIntent` instance.
    static func sourceCodeFormatting() -> PluginCommandIntent {
        return sourceCodeFormatting
    }
}

/// The type of permission a plug-in requires.
///
/// Supported types are ``allowNetworkConnections(scope:reason:)`` and ``writeToPackageDirectory(reason:)``.
@available(_PackageDescription, introduced: 5.6)
public enum PluginPermission {
    /// Create a permission to make network connections.
    ///
    /// The command plug-in requires permission to make network connections. The `reason` string is shown
    /// to the user at the time of request for approval, explaining why the plug-in is requesting access.
    ///   - Parameter scope: The scope of the permission.
    ///   - Parameter reason: A reason why the permission is needed. This is shown to the user when permission is sought.
    @available(_PackageDescription, introduced: 5.9)
    case allowNetworkConnections(scope: PluginNetworkPermissionScope, reason: String)

    /// Create a permission to modify files in the package's directory.
    ///
    /// The command plug-in requires permission to modify the files under the package
    /// directory. The `reason` string is shown to the user at the time of request
    /// for approval, explaining why the plug-in requests access.
    ///   - Parameter reason: A reason why the permission is needed. This is shown to the user when permission is sought.
    case writeToPackageDirectory(reason: String)
}

/// The scope of a network permission.
///
/// The scope can be none, local connections only, or all connections.
@available(_PackageDescription, introduced: 5.9)
public enum PluginNetworkPermissionScope {
    /// Do not allow network access.
    case none
    /// Allow local network connections; can be limited to a list of allowed ports.
    case local(ports: [Int] = [])
    /// Allow local and outgoing network connections; can be limited to a list of allowed ports.
    case all(ports: [Int] = [])
    /// Allow connections to Docker through UNIX domain sockets.
    case docker
    /// Allow connections to any UNIX domain socket.
    case unixDomainSocket

    /// Allow local and outgoing network connections, limited to a range of allowed ports.
    public static func all(ports: Range<Int>) -> PluginNetworkPermissionScope {
        return .all(ports: Array(ports))
    }

    /// Allow local network connections, limited to a range of allowed ports.
    public static func local(ports: Range<Int>) -> PluginNetworkPermissionScope {
        return .local(ports: Array(ports))
    }
}

extension Target.PluginUsage {
    /// Specifies use of a plugin target in the same package.
    ///
    /// - Parameter name: The name of the plugin target.
    /// - Returns: A `PluginUsage` instance.
    @available(_PackageDescription, introduced: 5.5)
    public static func plugin(name: String) -> Target.PluginUsage {
        return .plugin(name: name, package: nil)
    }
}


// MARK: ExpressibleByStringLiteral

/// `ExpressibleByStringLiteral` conformance.
///
extension Target.Dependency: ExpressibleByStringLiteral {

    /// Creates a target dependency instance with the given value.
    ///
    /// - Parameter value: A string literal.
    public init(stringLiteral value: String) {
        self = .byNameItem(name: value, condition: nil)
    }
}

/// `ExpressibleByStringLiteral` conformance.
///
extension Target.PluginUsage: ExpressibleByStringLiteral {

    /// Specifies use of a plugin target in the same package.
    ///
    /// - Parameter value: A string literal.
    public init(stringLiteral value: String) {
        self = .plugin(name: value, package: nil)
    }
}

