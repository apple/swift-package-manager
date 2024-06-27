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


extension Package {
    /// A package dependency of a Swift package.
    ///
    /// A package dependency consists of a Git URL to the source of the package,
    /// and a requirement for the version of the package.
    ///
    /// Swift Package Manager performs a process called _dependency resolution_ to determine
    /// the exact version of the package dependencies that an app or other Swift
    /// package can use. The `Package.resolved` file records the results of the
    /// dependency resolution and lives in the top-level directory of a Swift
    /// package. If you add the Swift package as a package dependency to an app
    /// for an Apple platform, you can find the `Package.resolved` file inside
    /// your `.xcodeproj` or `.xcworkspace`.
    public class Dependency {
        /// The type of dependency.
        @available(_PackageDescription, introduced: 5.6)
        public enum Kind {
            /// A dependency located at the given path.
            /// - Parameters:
            ///    - name: The name of the dependency.
            ///    - path: The path to the dependency.
            case fileSystem(name: String?, path: String)
            /// A dependency based on a source control requirement.
            ///  - Parameters:
            ///    - name: The name of the dependency.
            ///    - location: The Git URL of the dependency.
            ///    - requirement: The version-based requirement for a package.
            case sourceControl(name: String?, location: String, requirement: SourceControlRequirement)
            /// A dependency based on a registry requirement.
            /// - Parameters:
            ///   - id: The package identifier of the dependency.
            ///   - requirement: The version based requirement for a package.
            case registry(id: String, requirement: RegistryRequirement)
        }

        /// A description of the package dependency.
        @available(_PackageDescription, introduced: 5.6)
        public let kind: Kind

        /// The dependencies traits configuration.
        @_spi(ExperimentalTraits)
        @available(_PackageDescription, introduced: 999.0)
        public let traits: Set<Trait>

        /// The name of the dependency.
        ///
        /// If the `name` is `nil`, Swift Package Manager deduces the dependency's name from its
        /// package identity or Git URL.
        @available(_PackageDescription, deprecated: 5.6, message: "use kind instead")
        public var name: String? {
            get {
                switch self.kind {
                case .fileSystem(name: let name, path: _):
                    return name
                case .sourceControl(name: let name, location: _, requirement: _):
                    return name
                case .registry:
                    return nil
                }
            }
        }

        /// The Git URL of the package dependency.
        @available(_PackageDescription, deprecated: 5.6, message: "use kind instead")
        public var url: String? {
            get {
                switch self.kind {
                case .fileSystem(name: _, path: let path):
                    return path
                case .sourceControl(name: _, location: let location, requirement: _):
                    return location
                case .registry:
                    return nil
                }
            }
        }

        /// Module aliases for targets in this dependency. The key is an original target name and
        /// the value is a new unique name mapped to the name of the .swiftmodule binary.
        internal var moduleAliases: [String: String]?

        /// The dependency requirement of the package dependency.
        @available(_PackageDescription, deprecated: 5.6, message: "use kind instead")
        public var requirement: Requirement {
            get {
                switch self.kind {
                case .fileSystem:
                    return .localPackageItem
                case .sourceControl(name: _, location: _, requirement: let requirement):
                    switch requirement {
                    case .branch(let branch):
                        return .branchItem(branch)
                    case .exact(let version):
                        return .exactItem(version)
                    case .range(let range):
                        return .rangeItem(range)
                    case .revision(let revision):
                        return .revisionItem(revision)
                    }
                case .registry(id: _, requirement: let requirement):
                    switch requirement {
                    case .exact(let version):
                        return .exactItem(version)
                    case .range(let range):
                        return .rangeItem(range)
                    }
                }
            }
        }

        /// Initializes and returns a newly allocated requirement with the specified url and requirements.
        @available(_PackageDescription, deprecated: 5.6)
        convenience init(
            name: String?,
            url: String,
            requirement: Requirement,
            traits: Set<Trait>?
        ) {
            switch requirement {
            case .localPackageItem:
                self.init(name: name, path: url, traits: traits)
            case .branchItem(let branch):
                self.init(name: name, location: url, requirement: .branch(branch), traits: traits)
            case .exactItem(let version):
                self.init(name: name, location: url, requirement: .exact(version), traits: traits)
            case .revisionItem(let revision):
                self.init(name: name, location: url, requirement: .revision(revision), traits: traits)
            case .rangeItem(let range):
                self.init(name: name, location: url, requirement: .range(range), traits: traits)
            }
        }

        init(kind: Kind, traits: Set<Trait>?) {
            self.kind = kind
            self.traits = traits ?? [.defaults]
        }

        convenience init(
            name: String?,
            path: String,
            traits: Set<Trait>?
        ) {
            self.init(
                kind: .fileSystem(
                    name: name,
                    path: path
                ),
                traits: traits
            )
        }
        
        convenience init(
            name: String?,
            location: String,
            requirement: SourceControlRequirement,
            traits: Set<Trait>?
        ) {
            self.init(
                kind: .sourceControl(
                    name: name,
                    location: location,
                    requirement: requirement
                ),
                traits: traits
            )
        }
        
        convenience init(
            id: String,
            requirement: RegistryRequirement,
            traits: Set<Trait>?
        ) {
            self.init(
                kind: .registry(
                    id: id,
                    requirement: requirement
                ),
                traits: traits
            )
        }
    }
}

// MARK: - file system

extension Package.Dependency {
    /// Adds a dependency to a package located at the given path.
    ///
    /// The Swift Package Manager uses the package dependency as-is
    /// and does not perform any source control access. Local package dependencies
    /// are especially useful during development of a new package or when working
    /// on multiple tightly coupled packages.
    ///
    /// - Parameter path: The file system path to the package.
    ///
    /// - Returns: A package dependency.
    public static func package(
        path: String
    ) -> Package.Dependency {
        return .init(name: nil, path: path, traits: nil)
    }

    /// Adds a dependency to a package located at the given path.
    ///
    /// The Swift Package Manager uses the package dependency as-is
    /// and does not perform any source control access. Local package dependencies
    /// are especially useful during development of a new package or when working
    /// on multiple tightly coupled packages.
    ///
    /// - Parameter path: The file system path to the package.
    /// - Parameter traits: The trait configuration of this dependency. Defaults to enabling the default traits.
    ///
    /// - Returns: A package dependency.
    @_spi(ExperimentalTraits)
    @available(_PackageDescription, introduced: 999.0)
    public static func package(
        path: String,
        traits: Set<Trait> = [.defaults]
    ) -> Package.Dependency {
        return .init(name: nil, path: path, traits: traits)
    }

    /// Adds a dependency to a package located at the given path on the filesystem.
    ///
    /// Swift Package Manager uses the package dependency as-is and doesn't perform any source
    /// control access. Local package dependencies are especially useful during
    /// development of a new package or when working on multiple tightly coupled
    /// packages.
    ///
    /// - Parameters:
    ///   - name: The name of the Swift package.
    ///   - path: The file system path to the package.
    ///
    /// - Returns: A package dependency.
    @available(_PackageDescription, introduced: 5.2)
    public static func package(
        name: String,
        path: String
    ) -> Package.Dependency {
        return .init(name: name, path: path, traits: nil)
    }

    /// Adds a dependency to a package located at the given path on the filesystem.
    ///
    /// Swift Package Manager uses the package dependency as-is and doesn't perform any source
    /// control access. Local package dependencies are especially useful during
    /// development of a new package or when working on multiple tightly coupled
    /// packages.
    ///
    /// - Parameters:
    ///   - name: The name of the Swift package.
    ///   - path: The file system path to the package.
    ///   - traits: The trait configuration of this dependency. Defaults to enabling the default traits.
    ///
    /// - Returns: A package dependency.
    @_spi(ExperimentalTraits)
    @available(_PackageDescription, introduced: 999.0)
    public static func package(
        name: String,
        path: String,
        traits: Set<Trait> = [.defaults]
    ) -> Package.Dependency {
        return .init(name: name, path: path, traits: traits)
    }
}

// MARK: - source control

extension Package.Dependency {
    /// Adds a package dependency that uses the version requirement, starting with the given minimum version,
    /// going up to the next major version.
    ///
    /// This is the recommended way to specify a remote package dependency.
    /// It allows you to specify the minimum version you require, allows updates that include bug fixes
    /// and backward-compatible feature updates, but requires you to explicitly update to a new major version of the dependency.
    /// This approach provides the maximum flexibility on which version to use,
    /// while making sure you don't update to a version with breaking changes,
    /// and helps to prevent conflicts in your dependency graph.
    ///
    /// The following example allows the Swift Package Manager to select a version
    /// like a  `1.2.3`, `1.2.4`, or `1.3.0`, but not `2.0.0`.
    ///
    ///```swift
    ///.package(url: "https://example.com/example-package.git", from: "1.2.3"),
    ///```
    ///
    /// - Parameters:
    ///    - url: The valid Git URL of the package.
    ///    - version: The minimum version requirement.
    ///
    /// - Returns: A `Package.Dependency` instance.
    public static func package(
        url: String,
        from version: Version
    ) -> Package.Dependency {
        return .package(url: url, .upToNextMajor(from: version))
    }

    /// Adds a package dependency that uses the version requirement, starting with the given minimum version,
    /// going up to the next major version.
    ///
    /// This is the recommended way to specify a remote package dependency.
    /// It allows you to specify the minimum version you require, allows updates that include bug fixes
    /// and backward-compatible feature updates, but requires you to explicitly update to a new major version of the dependency.
    /// This approach provides the maximum flexibility on which version to use,
    /// while making sure you don't update to a version with breaking changes,
    /// and helps to prevent conflicts in your dependency graph.
    ///
    /// The following example allows the Swift Package Manager to select a version
    /// like a  `1.2.3`, `1.2.4`, or `1.3.0`, but not `2.0.0`.
    ///
    ///```swift
    ///.package(url: "https://example.com/example-package.git", from: "1.2.3"),
    ///```
    ///
    /// - Parameters:
    ///    - url: The valid Git URL of the package.
    ///    - version: The minimum version requirement.
    ///    - traits: The trait configuration of this dependency. Defaults to enabling the default traits.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @_spi(ExperimentalTraits)
    @available(_PackageDescription, introduced: 999.0)
    public static func package(
        url: String,
        from version: Version,
        traits: Set<Trait> = [.defaults]
    ) -> Package.Dependency {
        return .package(url: url, .upToNextMajor(from: version), traits: traits)
    }

    /// Adds a package dependency that uses the version requirement, starting
    /// with the given minimum version, going up to the next major version.
    ///
    /// This is the recommended way to specify a remote package dependency. It
    /// allows you to specify the minimum version you require, allows updates
    /// that include bug fixes and backward-compatible feature updates, but
    /// requires you to explicitly update to a new major version of the
    /// dependency. This approach provides the maximum flexibility on which
    /// version to use, while making sure you don't update to a version with
    /// breaking changes, and helps to prevent conflicts in your dependency
    /// graph.
    ///
    /// The following example allows the Swift package manager to select a
    /// version like a `1.2.3`, `1.2.4`, or `1.3.0`, but not `2.0.0`.
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", from:
    /// "1.2.3"),
    /// ```
    ///
    /// - Parameters:
    ///   - name: The name of the Swift package or `nil` to deduce the name from  the package's Git URL.
    ///   - url: The valid Git URL of the package.
    ///   - version: The minimum version requirement.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @available(_PackageDescription, introduced: 5.2, deprecated: 5.6, message: "use package(url:from:) instead")
    public static func package(
        name: String,
        url: String,
        from version: Version
    ) -> Package.Dependency {
        return .package(name: name, url: url, .upToNextMajor(from: version))
    }

    /// Adds a remote package dependency given a branch requirement.
    ///
    ///```swift
    /// .package(url: "https://example.com/example-package.git", branch: "main"),
    /// ```
    ///
    /// - Parameters:
    ///   - url: The valid Git URL of the package.
    ///   - branch: A dependency requirement. See static methods on ``Requirement-swift.enum`` for available options.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @available(_PackageDescription, introduced: 5.5)
    public static func package(
        url: String,
        branch: String
    ) -> Package.Dependency {
        return .package(url: url, requirement: .branch(branch))
    }

    /// Adds a remote package dependency given a branch requirement.
    ///
    ///```swift
    /// .package(url: "https://example.com/example-package.git", branch: "main"),
    /// ```
    ///
    /// - Parameters:
    ///   - url: The valid Git URL of the package.
    ///   - branch: A dependency requirement. See static methods on ``Requirement-swift.enum`` for available options.
    ///   - traits: The trait configuration of this dependency. Defaults to enabling the default traits.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @_spi(ExperimentalTraits)
    @available(_PackageDescription, introduced: 999.0)
    public static func package(
        url: String,
        branch: String,
        traits: Set<Trait> = [.defaults]
    ) -> Package.Dependency {
        return .package(url: url, requirement: .branch(branch), traits: traits)
    }

    /// Adds a remote package dependency given a branch requirement.
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", branch: "main"),
    /// ```
    ///
    /// - Parameters:
    ///   - name: The name of the package, or nil to deduce it from the URL.
    ///   - url: The valid Git URL of the package.
    ///   - branch: A dependency requirement. See static methods on ``Requirement-swift.enum`` for available options.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @available(_PackageDescription, introduced: 5.5, deprecated: 5.6, message: "use package(url:branch:) instead")
    public static func package(
        name: String,
        url: String,
        branch: String
    ) -> Package.Dependency {
        return .package(name: name, url: url, requirement: .branch(branch))
    }

    /// Adds a remote package dependency given a revision requirement.
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", revision: "aa681bd6c61e22df0fd808044a886fc4a7ed3a65"),
    /// ```
    ///
    /// - Parameters:
    ///   - url: The valid Git URL of the package.
    ///   - revision: A dependency requirement. See static methods on ``Requirement-swift.enum`` for available options.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @available(_PackageDescription, introduced: 5.5)
    public static func package(
        url: String,
        revision: String
    ) -> Package.Dependency {
        return .package(url: url, requirement: .revision(revision))
    }

    /// Adds a remote package dependency given a revision requirement.
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", revision: "aa681bd6c61e22df0fd808044a886fc4a7ed3a65"),
    /// ```
    ///
    /// - Parameters:
    ///   - url: The valid Git URL of the package.
    ///   - revision: A dependency requirement. See static methods on ``Requirement-swift.enum`` for available options.
    ///   - traits: The trait configuration of this dependency. Defaults to enabling the default traits.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @_spi(ExperimentalTraits)
    @available(_PackageDescription, introduced: 999.0)
    public static func package(
        url: String,
        revision: String,
        traits: Set<Trait> = [.defaults]
    ) -> Package.Dependency {
        return .package(url: url, requirement: .revision(revision), traits: traits)
    }

    /// Adds a remote package dependency given a revision requirement.
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", revision: "aa681bd6c61e22df0fd808044a886fc4a7ed3a65"),
    /// ```
    ///
    /// - Parameters:
    ///   - name: The name of the package, or nil to deduce it from the URL.
    ///   - url: The valid Git URL of the package.
    ///   - revision: A dependency requirement. See static methods on ``Requirement-swift.enum`` for available options.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @available(_PackageDescription, introduced: 5.5, deprecated: 5.6, message: "use package(url:revision:) instead")
    public static func package(
        name: String,
        url: String,
        revision: String
    ) -> Package.Dependency {
        return .package(name: name, url: url, requirement: .revision(revision))
    }

    /// Adds a package dependency starting with a specific minimum version, up to
    /// but not including a specified maximum version.
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions `1.2.3`, `1.2.4`, `1.2.5`, but not `1.2.6`.
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", "1.2.3"..<"1.2.6"),
    /// ```
    ///
    /// - Parameters:
    ///   - name: The name of the package, or nil to deduce it from the URL.
    ///   - url: The valid Git URL of the package.
    ///   - range: The custom version range requirement.
    ///
    /// - Returns: A `Package.Dependency` instance.
    public static func package(
        url: String,
        _ range: Range<Version>
    ) -> Package.Dependency {
        return .package(name: nil, url: url, requirement: .range(range))
    }

    /// Adds a package dependency starting with a specific minimum version, up to
    /// but not including a specified maximum version.
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions `1.2.3`, `1.2.4`, `1.2.5`, but not `1.2.6`.
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", "1.2.3"..<"1.2.6"),
    /// ```
    ///
    /// - Parameters:
    ///   - name: The name of the package, or nil to deduce it from the URL.
    ///   - url: The valid Git URL of the package.
    ///   - range: The custom version range requirement.
    ///   - traits: The trait configuration of this dependency. Defaults to enabling the default traits.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @_spi(ExperimentalTraits)
    @available(_PackageDescription, introduced: 999.0)
    public static func package(
        url: String,
        _ range: Range<Version>,
        traits: Set<Trait> = [.defaults]
    ) -> Package.Dependency {
        return .package(name: nil, url: url, requirement: .range(range), traits: traits)
    }

    /// Adds a package dependency starting with a specific minimum version, up to
    /// but not including a specified maximum version.
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions `1.2.3`, `1.2.4`, `1.2.5`, but not `1.2.6`.
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", "1.2.3"..<"1.2.6"),
    /// ```
    ///
    /// - Parameters:
    ///   - name: The name of the package, or `nil` to deduce it from the URL.
    ///   - url: The valid Git URL of the package.
    ///   - range: The custom version range requirement.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @available(_PackageDescription, introduced: 5.2, deprecated: 5.6, message: "use package(url:_:) instead")
    public static func package(
        name: String,
        url: String,
        _ range: Range<Version>
    ) -> Package.Dependency {
        return .package(name: name, url: url, requirement: .range(range))
    }

    /// Adds a package dependency starting with a specific minimum version, going
    /// up to and including a specific maximum version.
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions 1.2.3, 1.2.4, 1.2.5, as well as 1.2.6.
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", "1.2.3"..."1.2.6"),
    /// ```
    ///
    /// - Parameters:
    ///   - name: The name of the package, or `nil` to deduce it from the URL.
    ///   - url: The valid Git URL of the package.
    ///   - range: The closed version range requirement.
    ///
    /// - Returns: A `Package.Dependency` instance.
    public static func package(
        url: String,
        _ range: ClosedRange<Version>
    ) -> Package.Dependency {
        return .package(name: nil, url: url, closedRange: range)
    }

    /// Adds a package dependency starting with a specific minimum version, going
    /// up to and including a specific maximum version.
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions 1.2.3, 1.2.4, 1.2.5, as well as 1.2.6.
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", "1.2.3"..."1.2.6"),
    /// ```
    ///
    /// - Parameters:
    ///   - name: The name of the package, or `nil` to deduce it from the URL.
    ///   - url: The valid Git URL of the package.
    ///   - range: The closed version range requirement.
    ///   - traits: The trait configuration of this dependency. Defaults to enabling the default traits.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @_spi(ExperimentalTraits)
    @available(_PackageDescription, introduced: 999.0)
    public static func package(
        url: String,
        _ range: ClosedRange<Version>,
        traits: Set<Trait> = [.defaults]
    ) -> Package.Dependency {
        return .package(name: nil, url: url, closedRange: range, traits: traits)
    }

    /// Adds a package dependency starting with a specific minimum version, going
    /// up to and including a specific maximum version.
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions 1.2.3, 1.2.4, 1.2.5, as well as 1.2.6.
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", "1.2.3"..."1.2.6"),
    /// ```
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions between 1.0.0 and 2.0.0
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", .upToNextMajor(from: "1.0.0"),
    /// ```
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions between 1.0.0 and 1.1.0
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", .upToNextMinor(from: "1.0.0"),
    /// ```
    ///
    /// - Parameters:
    ///   - name: The name of the package, or `nil` to deduce it from the URL.
    ///   - url: The valid Git URL of the package.
    ///   - range: The closed version range requirement.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @available(_PackageDescription, introduced: 5.2, deprecated: 5.6, message: "use package(url:_:) instead")
    public static func package(
        name: String,
        url: String,
        _ range: ClosedRange<Version>
    ) -> Package.Dependency {
        return .package(name: name, url: url, closedRange: range)
    }

    /// Adds a package dependency starting with a specific minimum version, going
    /// up to and including a specific maximum version.
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions 1.2.3, 1.2.4, 1.2.5, as well as 1.2.6.
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", "1.2.3"..."1.2.6"),
    /// ```
    ///
    /// - Parameters:
    ///   - name: The name of the package, or `nil` to deduce it from the URL.
    ///   - url: The valid Git URL of the package.
    ///   - range: The closed version range requirement.
    ///
    /// - Returns: A `Package.Dependency` instance.
    private static func package(
        name: String?,
        url: String,
        closedRange: ClosedRange<Version>
    ) -> Package.Dependency {
        // Increase upperbound's patch version by one.
        let upper = closedRange.upperBound
        let upperBound = Version(
            upper.major, upper.minor, upper.patch + 1,
            prereleaseIdentifiers: upper.prereleaseIdentifiers,
            buildMetadataIdentifiers: upper.buildMetadataIdentifiers)
        return .package(name: name, url: url, requirement: .range(closedRange.lowerBound ..< upperBound))
    }

    /// Adds a package dependency starting with a specific minimum version, going
    /// up to and including a specific maximum version.
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions 1.2.3, 1.2.4, 1.2.5, as well as 1.2.6.
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", "1.2.3"..."1.2.6"),
    /// ```
    ///
    /// - Parameters:
    ///   - name: The name of the package, or `nil` to deduce it from the URL.
    ///   - url: The valid Git URL of the package.
    ///   - range: The closed version range requirement.
    ///   - traits: The trait configuration of this dependency. Defaults to enabling the default traits.
    ///
    /// - Returns: A `Package.Dependency` instance.
    private static func package(
        name: String?,
        url: String,
        closedRange: ClosedRange<Version>,
        traits: Set<Trait> = [.defaults]
    ) -> Package.Dependency {
        // Increase upperbound's patch version by one.
        let upper = closedRange.upperBound
        let upperBound = Version(
            upper.major, upper.minor, upper.patch + 1,
            prereleaseIdentifiers: upper.prereleaseIdentifiers,
            buildMetadataIdentifiers: upper.buildMetadataIdentifiers)
        return .package(
            name: name,
            url: url,
            requirement: .range(
                closedRange.lowerBound ..< upperBound
            ),
            traits: traits
        )
    }

    /// Adds a package dependency that uses the exact version requirement.
    ///
    /// Specifying exact version requirements are not recommended as
    /// they can cause conflicts in your dependency graph when other packages depend on this package.
    /// As Swift packages follow the semantic versioning convention,
    /// think about specifying a version range instead.
    ///
    /// The following example instructs the Swift Package Manager to use version `1.2.3`.
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", exact: "1.2.3"),
    /// ```
    ///
    /// - Parameters:
    ///   - url: The valid Git URL of the package.
    ///   - version: The exact version of the dependency for this requirement.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @available(_PackageDescription, introduced: 5.6)
    public static func package(
        url: String,
        exact version: Version
    ) -> Package.Dependency {
        return .package(url: url, requirement: .exact(version))
    }

    /// Adds a package dependency that uses the exact version requirement.
    ///
    /// Specifying exact version requirements are not recommended as
    /// they can cause conflicts in your dependency graph when other packages depend on this package.
    /// As Swift packages follow the semantic versioning convention,
    /// think about specifying a version range instead.
    ///
    /// The following example instructs the Swift Package Manager to use version `1.2.3`.
    ///
    /// ```swift
    /// .package(url: "https://example.com/example-package.git", exact: "1.2.3"),
    /// ```
    ///
    /// - Parameters:
    ///   - url: The valid Git URL of the package.
    ///   - version: The exact version of the dependency for this requirement.
    ///   - traits: The trait configuration of this dependency.  Defaults to enabling the default traits.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @_spi(ExperimentalTraits)
    @available(_PackageDescription, introduced: 999.0)
    public static func package(
        url: String,
        exact version: Version,
        traits: Set<Trait> = [.defaults]
    ) -> Package.Dependency {
        return .package(url: url, requirement: .exact(version), traits: traits)
    }

    /// Adds a remote package dependency given a version requirement.
    ///
    /// - Parameters:
    ///   - name: The name of the package, or nil to deduce it from the URL.
    ///   - url: The valid Git URL of the package.
    ///   - requirement: A dependency requirement. See static methods on `Package.Dependency.Requirement` for available options.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @available(_PackageDescription, deprecated: 5.6, message: "use specific requirement APIs instead (e.g. use 'branch:' instead of '.branch')")
    public static func package(
        url: String,
        _ requirement: Package.Dependency.Requirement
    ) -> Package.Dependency {
        return .package(name: nil, url: url, requirement)
    }

    /// Adds a remote package dependency with a given version requirement.
    ///
    /// - Parameters:
    ///   - name: The name of the Swift package or `nil` to deduce the name from the package's Git URL.
    ///   - url: The valid Git URL of the package.
    ///   - requirement: A dependency requirement. See static methods on
    ///     ``Package/Dependency/Requirement-swift.enum`` for available options.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @available(_PackageDescription, introduced: 5.2, deprecated: 5.6, message: "use specific requirement APIs instead (e.g. use 'branch:' instead of '.branch')")
    public static func package(
        name: String?,
        url: String,
        _ requirement: Package.Dependency.Requirement
    ) -> Package.Dependency {
        precondition(!requirement.isLocalPackage, "Use `.package(path:)` API to declare a local package dependency")
        return .init(name: name, url: url, requirement: requirement, traits: nil)
    }

    // intentionally private to hide enum detail
    private static func package(
        name: String? = nil,
        url: String,
        requirement: Package.Dependency.SourceControlRequirement
    ) -> Package.Dependency {
        return .init(name: name, location: url, requirement: requirement, traits: nil)
    }

    // intentionally private to hide enum detail
    private static func package(
        name: String? = nil,
        url: String,
        requirement: Package.Dependency.SourceControlRequirement,
        traits: Set<Trait>?
    ) -> Package.Dependency {
        return .init(name: name, location: url, requirement: requirement, traits: traits)
    }
}

// MARK: - registry

extension Package.Dependency {
    /// Adds a package dependency that uses the version requirement, starting with the given minimum version,
    /// going up to the next major version.
    ///
    /// This is the recommended way to specify a remote package dependency.
    /// It allows you to specify the minimum version you require, allows updates that include bug fixes
    /// and backward-compatible feature updates, but requires you to explicitly update to a new major version of the dependency.
    /// This approach provides the maximum flexibility on which version to use,
    /// while making sure you don't update to a version with breaking changes,
    /// and helps to prevent conflicts in your dependency graph.
    ///
    /// The following example allows the Swift Package Manager to select a version
    /// like a  `1.2.3`, `1.2.4`, or `1.3.0`, but not `2.0.0`.
    ///
    /// ```swift
    /// .package(id: "scope.name", from: "1.2.3"),
    /// ```
    ///
    /// - Parameters:
    ///   - id: The identity of the package.
    ///   - version: The minimum version requirement.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @available(_PackageDescription, introduced: 5.7)
    public static func package(
        id: String,
        from version: Version
    ) -> Package.Dependency {
        return .package(id: id, .upToNextMajor(from: version))
    }

    /// Adds a package dependency that uses the version requirement, starting with the given minimum version,
    /// going up to the next major version.
    ///
    /// This is the recommended way to specify a remote package dependency.
    /// It allows you to specify the minimum version you require, allows updates that include bug fixes
    /// and backward-compatible feature updates, but requires you to explicitly update to a new major version of the dependency.
    /// This approach provides the maximum flexibility on which version to use,
    /// while making sure you don't update to a version with breaking changes,
    /// and helps to prevent conflicts in your dependency graph.
    ///
    /// The following example allows the Swift Package Manager to select a version
    /// like a  `1.2.3`, `1.2.4`, or `1.3.0`, but not `2.0.0`.
    ///
    /// ```swift
    /// .package(id: "scope.name", from: "1.2.3"),
    /// ```
    ///
    /// - Parameters:
    ///   - id: The identity of the package.
    ///   - version: The minimum version requirement.
    ///   - traits: The trait configuration of this dependency. Defaults to enabling the default traits.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @_spi(ExperimentalTraits)
    @available(_PackageDescription, introduced: 999.0)
    public static func package(
        id: String,
        from version: Version,
        traits: Set<Trait> = [.defaults]
    ) -> Package.Dependency {
        return .package(id: id, .upToNextMajor(from: version), traits: traits)
    }

    /// Adds a package dependency that uses the exact version requirement.
    ///
    /// Specifying exact version requirements are not recommended as
    /// they can cause conflicts in your dependency graph when multiple other packages depend on a package.
    /// Because Swift packages follow the semantic versioning convention,
    /// think about specifying a version range instead.
    ///
    /// The following example instructs the Swift Package Manager to use version `1.2.3`.
    ///
    /// ```swift
    /// .package(id: "scope.name", exact: "1.2.3"),
    /// ```
    ///
    /// - Parameters:
    ///   - id: The identity of the package.
    ///   - version: The exact version of the dependency for this requirement.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @available(_PackageDescription, introduced: 5.7)
    public static func package(
        id: String,
        exact version: Version
    ) -> Package.Dependency {
        return .package(id: id, requirement: .exact(version), traits: nil)
    }

    /// Adds a package dependency that uses the exact version requirement.
    ///
    /// Specifying exact version requirements are not recommended as
    /// they can cause conflicts in your dependency graph when multiple other packages depend on a package.
    /// Because Swift packages follow the semantic versioning convention,
    /// think about specifying a version range instead.
    ///
    /// The following example instructs the Swift Package Manager to use version `1.2.3`.
    ///
    /// ```swift
    /// .package(id: "scope.name", exact: "1.2.3"),
    /// ```
    ///
    /// - Parameters:
    ///   - id: The identity of the package.
    ///   - version: The exact version of the dependency for this requirement.
    ///   - traits: The trait configuration of this dependency. Defaults to enabling the default traits.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @_spi(ExperimentalTraits)
    @available(_PackageDescription, introduced: 999.0)
    public static func package(
        id: String,
        exact version: Version,
        traits: Set<Trait> = [.defaults]
    ) -> Package.Dependency {
        return .package(id: id, requirement: .exact(version), traits: traits)
    }

    /// Adds a package dependency starting with a specific minimum version, up to
    /// but not including a specified maximum version.
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions `1.2.3`, `1.2.4`, `1.2.5`, but not `1.2.6`.
    ///
    /// ```swift
    /// .package(id: "scope.name", "1.2.3"..<"1.2.6"),
    /// ```
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions between 1.0.0 and 2.0.0
    ///
    /// ```swift
    /// .package(id: "scope.name", .upToNextMajor(from: "1.0.0"),
    /// ```
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions between 1.0.0 and 1.1.0
    ///
    /// ```swift
    /// .package(id: "scope.name", .upToNextMinor(from: "1.0.0"),
    /// ```
    ///
    /// - Parameters:
    ///   - id: The identity of the package.
    ///   - range: The custom version range requirement.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @available(_PackageDescription, introduced: 5.7)
    public static func package(
        id: String,
        _ range: Range<Version>
    ) -> Package.Dependency {
        return .package(id: id, requirement: .range(range), traits: nil)
    }

    /// Adds a package dependency starting with a specific minimum version, up to
    /// but not including a specified maximum version.
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions `1.2.3`, `1.2.4`, `1.2.5`, but not `1.2.6`.
    ///
    /// ```swift
    /// .package(id: "scope.name", "1.2.3"..<"1.2.6"),
    /// ```
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions between 1.0.0 and 2.0.0
    ///
    /// ```swift
    /// .package(id: "scope.name", .upToNextMajor(from: "1.0.0"),
    /// ```
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions between 1.0.0 and 1.1.0
    ///
    /// ```swift
    /// .package(id: "scope.name", .upToNextMinor(from: "1.0.0"),
    /// ```
    ///
    /// - Parameters:
    ///   - id: The identity of the package.
    ///   - range: The custom version range requirement.
    ///   - traits: The trait configuration of this dependency. Defaults to enabling the default traits.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @_spi(ExperimentalTraits)
    @available(_PackageDescription, introduced: 999.0)
    public static func package(
        id: String,
        _ range: Range<Version>,
        traits: Set<Trait> = [.defaults]
    ) -> Package.Dependency {
        return .package(id: id, requirement: .range(range), traits: traits)
    }

    /// Adds a package dependency starting with a specific minimum version, going
    /// up to and including a specific maximum version.
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions 1.2.3, 1.2.4, 1.2.5, as well as 1.2.6.
    ///
    /// ```swift
    /// .package(id: "scope.name", "1.2.3"..."1.2.6"),
    /// ```
    ///
    /// - Parameters:
    ///   - id: The identity of the package.
    ///   - range: The closed version range requirement.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @available(_PackageDescription, introduced: 5.7)
    public static func package(
        id: String,
        _ range: ClosedRange<Version>
    ) -> Package.Dependency {
        // Increase upperbound's patch version by one.
        let upper = range.upperBound
        let upperBound = Version(
            upper.major, upper.minor, upper.patch + 1,
            prereleaseIdentifiers: upper.prereleaseIdentifiers,
            buildMetadataIdentifiers: upper.buildMetadataIdentifiers)
        return .package(id: id, range.lowerBound ..< upperBound)
    }

    /// Adds a package dependency starting with a specific minimum version, going
    /// up to and including a specific maximum version.
    ///
    /// The following example allows the Swift Package Manager to pick
    /// versions 1.2.3, 1.2.4, 1.2.5, as well as 1.2.6.
    ///
    /// ```swift
    /// .package(id: "scope.name", "1.2.3"..."1.2.6"),
    /// ```
    ///
    /// - Parameters:
    ///   - id: The identity of the package.
    ///   - range: The closed version range requirement.
    ///   - traits: The trait configuration of this dependency. Defaults to enabling the default traits.
    ///
    /// - Returns: A `Package.Dependency` instance.
    @_spi(ExperimentalTraits)
    @available(_PackageDescription, introduced: 999.0)
    public static func package(
        id: String,
        _ range: ClosedRange<Version>,
        traits: Set<Trait> = [.defaults]
    ) -> Package.Dependency {
        // Increase upperbound's patch version by one.
        let upper = range.upperBound
        let upperBound = Version(
            upper.major, upper.minor, upper.patch + 1,
            prereleaseIdentifiers: upper.prereleaseIdentifiers,
            buildMetadataIdentifiers: upper.buildMetadataIdentifiers)
        return .package(id: id, range.lowerBound ..< upperBound, traits: traits)
    }

    // intentionally private to hide enum detail
    private static func package(
        id: String,
        requirement: Package.Dependency.RegistryRequirement,
        traits: Set<Trait>?
    ) -> Package.Dependency {
        let pattern = #"\A[a-zA-Z\d](?:[a-zA-Z\d]|-(?=[a-zA-Z\d])){0,38}\.[a-zA-Z0-9](?:[a-zA-Z0-9]|[-_](?=[a-zA-Z0-9])){0,99}\z"#
        if id.range(of: pattern, options: .regularExpression) == nil {
            errors.append("Invalid package identifier: '\(id)'")
        }

        return .init(id: id, requirement: requirement, traits: traits)
    }
}

// MARK: - common APIs used by mistake as unavailable to provide better error messages.

extension Package.Dependency {
    @available(*, unavailable, message: "use package(url:exact:) instead")
    public static func package(url: String, version: Version) -> Package.Dependency {
        fatalError()
    }

    @available(*, unavailable, message: "use package(url:_:) instead")
    public static func package(url: String, range: Range<Version>) -> Package.Dependency {
        fatalError()
    }
}
