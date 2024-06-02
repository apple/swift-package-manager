//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// The build configuration, such as debug or release.
public struct BuildConfiguration: Sendable {
    /// The configuration of the build. Valid values are `debug` and `release`.
    let config: String

    private init(_ config: String) {
        self.config = config
    }

    /// The debug build configuration.
    public static let debug: BuildConfiguration = BuildConfiguration("debug")

    /// The release build configuration.
    public static let release: BuildConfiguration = BuildConfiguration("release")
}

/// A condition that limits the application of a build setting.
///
/// By default, build settings are applicable for all platforms and build
/// configurations. Use the `.when` modifier to define a build setting for a
/// specific condition. Invalid usage of `.when` emits an error during manifest
/// parsing. For example, it's invalid to specify a `.when` condition with both
/// parameters as `nil`.
///
/// The following example shows how to use build setting conditions with various
/// APIs:
///
/// ```swift
/// ...
/// .target(
///     name: "MyTool",
///     dependencies: ["Utility"],
///     cSettings: [
///         .headerSearchPath("path/relative/to/my/target"),
///         .define("DISABLE_SOMETHING", .when(platforms: [.iOS], configuration: .release)),
///     ],
///     swiftSettings: [
///         .define("ENABLE_SOMETHING", .when(configuration: .release)),
///     ],
///     linkerSettings: [
///         .linkLibrary("openssl", .when(platforms: [.linux])),
///     ]
/// ),
/// ```
public struct BuildSettingCondition: Sendable {
    /// The applicable platforms for this build setting condition.
    let platforms: [Platform]?
    /// The applicable build configuration for this build setting condition.
    let config: BuildConfiguration?

    private init(platforms: [Platform]?, config: BuildConfiguration?) {
        self.platforms = platforms
        self.config = config
    }

    @available(_PackageDescription, deprecated: 5.7)
    public static func when(
        platforms: [Platform]? = nil,
        configuration: BuildConfiguration? = nil
    ) -> BuildSettingCondition {
        precondition(!(platforms == nil && configuration == nil))
        return BuildSettingCondition(platforms: platforms, config: configuration)
    }

    /// Creates a build setting condition.
    ///
    /// - Parameters:
    ///   - platforms: The applicable platforms for this build setting condition.
    ///   - configuration: The applicable build configuration for this build setting condition.
    @available(_PackageDescription, introduced: 5.7)
    public static func when(platforms: [Platform], configuration: BuildConfiguration) -> BuildSettingCondition {
        BuildSettingCondition(platforms: platforms, config: configuration)
    }

    /// Creates a build setting condition.
    ///
    /// - Parameter platforms: The applicable platforms for this build setting condition.
    @available(_PackageDescription, introduced: 5.7)
    public static func when(platforms: [Platform]) -> BuildSettingCondition {
        BuildSettingCondition(platforms: platforms, config: .none)
    }

    /// Creates a build setting condition.
    ///
    /// - Parameter configuration: The applicable build configuration for this build setting condition.
    @available(_PackageDescription, introduced: 5.7)
    public static func when(configuration: BuildConfiguration) -> BuildSettingCondition {
        BuildSettingCondition(platforms: .none, config: configuration)
    }
}

/// The underlying build setting data.
struct BuildSettingData {

    /// The name of the build setting.
    let name: String

    /// The value of the build setting.
    let value: [String]

    /// A condition that restricts the application of the build setting.
    let condition: BuildSettingCondition?
}

/// A C language build setting.
public struct CSetting: Sendable {
    /// The abstract build setting data.
    let data: BuildSettingData

    private init(name: String, value: [String], condition: BuildSettingCondition?) {
        self.data = BuildSettingData(name: name, value: value, condition: condition)
    }

    /// Provides a header search path relative to the target's directory.
    ///
    /// Use this setting to add a search path for headers within your target.
    /// You can't use absolute paths and you can't use this setting to provide
    /// headers that are visible to other targets.
    ///
    /// The path must be a directory inside the package.
    ///
    /// - Since: First available in PackageDescription 5.0.
    ///
    /// - Parameters:
    ///   - path: The path of the directory that contains the headers. The path is relative to the target's directory.
    ///   - condition: A condition that restricts the use of the build setting.
    @available(_PackageDescription, introduced: 5.0)
    public static func headerSearchPath(_ path: String, _ condition: BuildSettingCondition? = nil) -> CSetting {
        return CSetting(name: "headerSearchPath", value: [path], condition: condition)
    }

    /// Defines a value for a macro.
    ///
    /// If you don't specify a value, the macro's default value is 1.
    ///
    /// - Since: First available in PackageDescription 5.0.
    ///
    /// - Parameters:
    ///   - name: The name of the macro.
    ///   - value: The value of the macro.
    ///   - condition: A condition that restricts the use of the build
    /// setting.
    @available(_PackageDescription, introduced: 5.0)
    public static func define(_ name: String, to value: String? = nil, _ condition: BuildSettingCondition? = nil) -> CSetting {
        var settingValue = name
        if let value {
            settingValue += "=" + value
        }
        return CSetting(name: "define", value: [settingValue], condition: condition)
    }

    /// Sets unsafe flags to pass arbitrary command-line flags to the
    /// corresponding build tool.
    ///
    /// As the usage of the word “unsafe” implies, Swift Package Manager can't safely determine
    /// if the build flags have any negative side effect on the build since
    /// certain flags can change the behavior of how it performs a build.
    ///
    /// As some build flags can be exploited for unsupported or malicious
    /// behavior, the use of unsafe flags makes the products containing this
    /// target ineligible for use by other packages.
    ///
    /// - Since: First available in PackageDescription 5.0.
    ///
    /// - Parameters:
    ///   - flags: The unsafe flags to set.
    ///   - condition: A condition that restricts the application of the build
    /// setting.
    @available(_PackageDescription, introduced: 5.0)
    public static func unsafeFlags(_ flags: [String], _ condition: BuildSettingCondition? = nil) -> CSetting {
        return CSetting(name: "unsafeFlags", value: flags, condition: condition)
    }
}

/// A CXX-language build setting.
public struct CXXSetting: Sendable {
    /// The data store for the CXX build setting.
    let data: BuildSettingData

    private init(name: String, value: [String], condition: BuildSettingCondition?) {
        self.data = BuildSettingData(name: name, value: value, condition: condition)
    }

    /// Provides a header search path relative to the target's directory.
    ///
    /// Use this setting to add a search path for headers within your target.
    /// You can't use absolute paths and you can't use this setting to provide
    /// headers that are visible to other targets.
    ///
    /// The path must be a directory inside the package.
    ///
    /// - Since: First available in PackageDescription 5.0.
    ///
    /// - Parameters:
    ///   - path: The path of the directory that contains the headers. The path is
    ///   relative to the target's directory.
    ///   - condition: A condition that restricts the application of the build setting.
    @available(_PackageDescription, introduced: 5.0)
    public static func headerSearchPath(_ path: String, _ condition: BuildSettingCondition? = nil) -> CXXSetting {
        return CXXSetting(name: "headerSearchPath", value: [path], condition: condition)
    }

    /// Defines a value for a macro.
    ///
    /// If you don't specify a value, the macro's default value is 1.
    ///
    /// - Since: First available in PackageDescription 5.0.
    ///
    /// - Parameters:
    ///   - name: The name of the macro.
    ///   - value: The value of the macro.
    ///   - condition: A condition that restricts the application of the build
    /// setting.
    @available(_PackageDescription, introduced: 5.0)
    public static func define(_ name: String, to value: String? = nil, _ condition: BuildSettingCondition? = nil) -> CXXSetting {
        var settingValue = name
        if let value {
            settingValue += "=" + value
        }
        return CXXSetting(name: "define", value: [settingValue], condition: condition)
    }

    /// Sets unsafe flags to pass arbitrary command-line flags to the
    /// corresponding build tool.
    ///
    /// As the usage of the word “unsafe” implies, Swift Package Manager can't safely determine
    /// if the build flags have any negative side effect on the build since
    /// certain flags can change the behavior of how it performs a build.
    ///
    /// As some build flags can be exploited for unsupported or malicious
    /// behavior, you can't use products with unsafe build flags as dependencies in another package.
    ///
    /// - Since: First available in PackageDescription 5.0.
    ///
    /// - Parameters:
    ///   - flags: The unsafe flags to set.
    ///   - condition: A condition that restricts the application of the build
    /// setting.
    @available(_PackageDescription, introduced: 5.0)
    public static func unsafeFlags(_ flags: [String], _ condition: BuildSettingCondition? = nil) -> CXXSetting {
        return CXXSetting(name: "unsafeFlags", value: flags, condition: condition)
    }
}

/// A Swift language build setting.
public struct SwiftSetting: Sendable {
    /// The data store for the Swift build setting.
    let data: BuildSettingData

    private init(name: String, value: [String], condition: BuildSettingCondition?) {
        self.data = BuildSettingData(name: name, value: value, condition: condition)
    }

    /// Defines a compilation condition.
    ///
    /// Use compilation conditions to only compile statements if a certain
    /// condition is true. For example, the Swift compiler will only compile the
    /// statements inside the `#if` block when `ENABLE_SOMETHING` is defined:
    ///
    /// ```swift
    /// #if ENABLE_SOMETHING
    ///    ...
    /// #endif
    /// ```
    ///
    /// Unlike macros in C/C++, compilation conditions don't have an associated
    /// value.
    ///
    /// - Since: First available in PackageDescription 5.0.
    ///
    /// - Parameters:
    ///   - name: The name of the macro.
    ///   - condition: A condition that restricts the application of the build
    /// setting.
    @available(_PackageDescription, introduced: 5.0)
    public static func define(_ name: String, _ condition: BuildSettingCondition? = nil) -> SwiftSetting {
        return SwiftSetting(name: "define", value: [name], condition: condition)
    }

    /// Set unsafe flags to pass arbitrary command-line flags to the
    /// corresponding build tool.
    ///
    /// As the usage of the word “unsafe” implies, Swift Package Manager can't safely determine
    /// if the build flags have any negative side effect on the build since
    /// certain flags can change the behavior of how it performs a build.
    ///
    /// As some build flags can be exploited for unsupported or malicious
    /// behavior, the use of unsafe flags makes the products containing this
    /// target ineligible for use by other packages.
    ///
    /// - Since: First available in PackageDescription 5.0.
    ///
    /// - Parameters:
    ///   - flags: The unsafe flags to set.
    ///   - condition: A condition that restricts the application of the build
    /// setting.
    @available(_PackageDescription, introduced: 5.0)
    public static func unsafeFlags(_ flags: [String], _ condition: BuildSettingCondition? = nil) -> SwiftSetting {
        return SwiftSetting(name: "unsafeFlags", value: flags, condition: condition)
    }

    /// Enable an upcoming feature with the given name.
    ///
    /// An upcoming feature is one that is available in Swift as of a
    /// certain language version, but isn't available by default in prior
    /// language modes because it has some impact on source compatibility.
    ///
    /// You can add and use multiple upcoming features in a given target
    /// without affecting its dependencies. Targets will ignore any unknown
    /// upcoming features.
    ///
    /// - Since: First available in PackageDescription 5.8.
    ///
    /// - Parameters:
    ///   - name: The name of the upcoming feature; for example, `ConciseMagicFile`.
    ///   - condition: A condition that restricts the application of the build
    /// setting.
    @available(_PackageDescription, introduced: 5.8)
    public static func enableUpcomingFeature(
        _ name: String,
        _ condition: BuildSettingCondition? = nil
    ) -> SwiftSetting {
        return SwiftSetting(
            name: "enableUpcomingFeature", value: [name], condition: condition)
    }

    /// Enable an experimental feature with the given name.
    ///
    /// An experimental feature is one that's in development, but
    /// is not yet available in Swift as a language feature.
    ///
    /// You can add and use multiple experimental features in a given target
    /// without affecting its dependencies. Targets will ignore any  unknown
    /// experimental features.
    ///
    /// - Since: First available in PackageDescription 5.8.
    ///
    /// - Parameters:
    ///   - name: The name of the experimental feature; for example, `VariadicGenerics`.
    ///   - condition: A condition that restricts the application of the build
    /// setting.
    @available(_PackageDescription, introduced: 5.8)
    public static func enableExperimentalFeature(
        _ name: String,
        _ condition: BuildSettingCondition? = nil
    ) -> SwiftSetting {
        return SwiftSetting(
            name: "enableExperimentalFeature", value: [name], condition: condition)
    }

    public enum InteroperabilityMode: String {
        case C
        case Cxx
    }

    /// Enable Swift interoperability with a given language.
    ///
    /// This is useful for enabling interoperability with Swift and C++ for a given
    /// target.
    ///
    /// Enabling C++ interoperability mode might alter the way some existing
    /// C and Objective-C APIs are imported.
    ///
    /// - Since: First available in PackageDescription 5.9.
    ///
    /// - Parameters:
    ///   - mode: The language mode, either C or CXX.
    ///   - condition: A condition that restricts the application of the build
    /// setting.
    @available(_PackageDescription, introduced: 5.9)
    public static func interoperabilityMode(
      _ mode: InteroperabilityMode,
      _ condition: BuildSettingCondition? = nil
    ) -> SwiftSetting {
        return SwiftSetting(
          name: "interoperabilityMode", value: [mode.rawValue], condition: condition)
    }

    /// Defines a `-swift-version` to pass  to the
    /// corresponding build tool.
    ///
    /// - Since: First available in PackageDescription 6.0.
    ///
    /// - Parameters:
    ///   - mode: The Swift language mode to use.
    ///   - condition: A condition that restricts the application of the build setting.
    @available(_PackageDescription, introduced: 6.0)
    public static func swiftLanguageMode(
      _ mode: SwiftLanguageMode,
      _ condition: BuildSettingCondition? = nil
    ) -> SwiftSetting {
        return SwiftSetting(
            name: "swiftLanguageMode", value: [.init(describing: mode)], condition: condition)
    }
}

/// A linker build setting.
public struct LinkerSetting: Sendable {
    /// The data store for the Linker setting.
    let data: BuildSettingData

    private init(name: String, value: [String], condition: BuildSettingCondition?) {
        self.data = BuildSettingData(name: name, value: value, condition: condition)
    }

    /// Declares linkage to a system library.
    ///
    /// This setting is most useful when the library can't be linked
    /// automatically, such as C++ based libraries and non-modular libraries.
    ///
    /// - Since: First available in PackageDescription 5.0.
    ///
    /// - Parameters:
    ///   - library: The library name.
    ///   - condition: A condition that restricts the application of the build
    /// setting.
    @available(_PackageDescription, introduced: 5.0)
    public static func linkedLibrary(_ library: String, _ condition: BuildSettingCondition? = nil) -> LinkerSetting {
        return LinkerSetting(name: "linkedLibrary", value: [library], condition: condition)
    }

    /// Declares linkage to a system framework.
    ///
    /// This setting is most useful when the framework can't be linked
    /// automatically, such as C++ based frameworks and non-modular frameworks.
    ///
    /// - Since: First available in PackageDescription 5.0.
    ///
    /// - Parameters:
    ///   - framework: The framework name.
    ///   - condition: A condition that restricts the application of the build
    /// setting.
    @available(_PackageDescription, introduced: 5.0)
    public static func linkedFramework(_ framework: String, _ condition: BuildSettingCondition? = nil) -> LinkerSetting {
        return LinkerSetting(name: "linkedFramework", value: [framework], condition: condition)
    }
   
    /// Sets unsafe flags to pass arbitrary command-line flags to the
    /// corresponding build tool.
    ///
    /// As the usage of the word “unsafe” implies, Swift Package Manager can't safely determine
    /// if the build flags have any negative side effect on the build since
    /// certain flags can change the behavior of how it performs a build.
    ///
    /// As some build flags can be exploited for unsupported or malicious
    /// behavior, the use of unsafe flags makes the products containing this
    /// target ineligible for use by other packages.
    ///
    /// - Since: First available in PackageDescription 5.0.
    ///
    /// - Parameters:
    ///   - flags: The unsafe flags to set.
    ///   - condition: A condition that restricts the application of the build
    /// setting.
    @available(_PackageDescription, introduced: 5.0)
    public static func unsafeFlags(_ flags: [String], _ condition: BuildSettingCondition? = nil) -> LinkerSetting {
        return LinkerSetting(name: "unsafeFlags", value: flags, condition: condition)
    }
}
