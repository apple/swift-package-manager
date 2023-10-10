//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// Represents a single package in the graph (either the root or a dependency).
public struct Package {
    /// Unique identifier for the package.
    public let id: ID
    public typealias ID = String

    /// The name of the package (for display purposes only).
    public let displayName: String

    /// The absolute path of the package directory in the local file system.
    public let directory: Path

    /// The origin of the package (root, local, repository, registry, etc).
    public let origin: PackageOrigin

    /// The tools version specified by the resolved version of the package.
    /// Behavior is often gated on the tools version, to make sure older
    /// packages continue to work as intended.
    public let toolsVersion: ToolsVersion
  
    /// Any dependencies on other packages, in the same order as they are
    /// specified in the package manifest.
    public let dependencies: [PackageDependency]

    /// Any regular products defined in this package (except plugin products),
    /// in the same order as they are specified in the package manifest.
    public let products: [Product]

    /// Any regular targets defined in this package (except plugin targets),
    /// in the same order as they are specified in the package manifest.
    public let targets: [Target]
}

/// Represents the origin of a package as it appears in the graph.
public enum PackageOrigin {
    /// A root package (unversioned).
    case root

    /// A local package, referenced by path (unversioned).
    case local(path: String)

    /// A package from a Git repository, with a URL and with a textual
    /// description of the resolved version or branch name (for display
    /// purposes only), along with the corresponding SCM revision. The
    /// revision is the Git commit hash and may be useful for plugins
    /// that generates source code that includes version information.
    case repository(url: String, displayVersion: String, scmRevision: String)

    /// A package from a registry, with an identity and with a textual
    /// description of the resolved version or branch name (for display
    /// purposes only).
    case registry(identity: String, displayVersion: String)
}

/// Represents a version of SwiftPM on whose semantics a package relies.
public struct ToolsVersion {
    /// The major version.
    public let major: Int

    /// The minor version.
    public let minor: Int

    /// The patch version.
    public let patch: Int
}

/// Represents a resolved dependency of a package on another package. This is a
/// separate entity in order to make it easier for future versions of the API to
/// add information about the dependency itself.
public struct PackageDependency {
    /// The package to which the dependency was resolved.
    public let package: Package
    
    init(package: Package) {
        self.package = package
    }
}

/// Represents a single product defined in a package.
public protocol Product {
    /// Unique identifier for the product.
    var id: ID { get }
    typealias ID = String
    
    /// The name of the product, as defined in the package manifest. This name
    /// is unique among the products of the package in which it is defined.
    var name: String { get }
    
    /// The targets that directly comprise the product, in the order in which
    /// they are declared in the package manifest. The product will contain the
    /// transitive closure of the these targets and their dependencies. Some
    /// kinds of products have further restrictions on the set of targets (for
    /// example, an executable product must have one and only one target that
    /// defines the main entry point for an executable).
    var targets: [Target] { get }
}

/// Represents an executable product defined in a package.
public struct ExecutableProduct: Product {
    /// Unique identifier for the product.
    public let id: ID
    
    /// The name of the product, as defined in the package manifest. This name
    /// is unique among the products of the package in which it is defined.
    public let name: String

    /// The targets that directly comprise the product, in the order in which
    /// they are declared in the package manifest. The product will contain the
    /// transitive closure of the these targets and their dependencies. For an
    /// ExecutableProduct, exactly one of the targets in this list must be an
    /// ExecutableTarget.
    public let targets: [Target]

    /// The target that contains the main entry point of the executable. Every
    /// executable product has exactly one main executable target. This target
    /// will always be one of the targets in the product's `targets` array.
    public let mainTarget: Target
}

/// Represents a library product defined in a package.
public struct LibraryProduct: Product {
    /// Unique identifier for the product.
    public let id: ID

    /// The name of the product, as defined in the package manifest. This name
    /// is unique among the products of the package in which it is defined.
    public let name: String

    /// The targets that directly comprise the product, in the order in which
    /// they are declared in the package manifest. The product will contain the
    /// transitive closure of the these targets and their dependencies.
    public let targets: [Target]

    /// Whether the library is static, dynamic, or automatically determined.
    public let kind: Kind

    /// Represents a kind of library product.
    public enum Kind {
        /// A static library, whose code is copied into its clients.
        case `static`

        /// Dynamic library, whose code is referenced by its clients.
        case `dynamic`

        /// The kind of library produced is unspecified and will be determined
        /// by the build system based on how the library is used.
        case automatic
    }
}

/// Represents a single target defined in a package.
public protocol Target {
    /// Unique identifier for the target.
    var id: ID { get }
    typealias ID = String

    /// The name of the target, as defined in the package manifest. This name
    /// is unique among the targets of the package in which it is defined.
    var name: String { get }
    
    /// The absolute path of the target directory in the local file system.
    var directory: Path { get }
    
    /// Any other targets on which this target depends, in the same order as
    /// they are specified in the package manifest. Conditional dependencies
    /// that do not apply have already been filtered out.
    var dependencies: [TargetDependency] { get }
}

/// Represents a dependency of a target on a product or on another target.
public enum TargetDependency {
    /// A dependency on a target in the same package.
    case target(Target)

    /// A dependency on a product in another package.
    case product(Product)
}

/// Represents a target consisting of a source code module, containing either
/// Swift or source files in one of the C-based languages.
public protocol SourceModuleTarget: Target {
    /// The name of the module produced by the target (derived from the target
    /// name, though future SwiftPM versions may allow this to be customized).
    var moduleName: String { get }
    
    /// The kind of module, describing whether it contains unit tests, contains
    /// the main entry point of an executable, or neither.
    var kind: ModuleKind { get }

    /// The source files that are associated with this target (any files that
    /// have been excluded in the manifest have already been filtered out).
    var sourceFiles: FileList { get }

    /// Any custom linked libraries required by the module, as specified in the
    /// package manifest.
    var linkedLibraries: [String] { get }

    /// Any custom linked frameworks required by the module, as specified in the
    /// package manifest.
    var linkedFrameworks: [String] { get }
}

/// Represents the kind of module.
public enum ModuleKind {
    /// A module that contains generic code (not a test nor an executable).
    case generic
    /// A module that contains code for an executable's main module.
    case executable
    /// A module that contains code for a snippet.
    @available(_PackageDescription, introduced: 5.8)
    case snippet
    /// A module that contains unit tests.
    case test
    /// A module that contains code for a macro.
    @available(_PackageDescription, introduced: 5.9)
    case macro // FIXME: This should really come from `CompilerPluginSupport` somehow, but we lack the infrastructure to allow that currently.
}

/// Represents a target consisting of a source code module compiled using Swift.
public struct SwiftSourceModuleTarget: SourceModuleTarget {
    /// Unique identifier for the target.
    public let id: ID
    
    /// The name of the target, as defined in the package manifest. This name
    /// is unique among the targets of the package in which it is defined.
    public let name: String
    
    /// The kind of module, describing whether it contains unit tests, contains
    /// the main entry point of an executable, or neither.
    public let kind: ModuleKind

    /// The absolute path of the target directory in the local file system.
    public let directory: Path
    
    /// Any other targets on which this target depends, in the same order as
    /// they are specified in the package manifest. Conditional dependencies
    /// that do not apply have already been filtered out.
    public let dependencies: [TargetDependency]

    /// The name of the module produced by the target (derived from the target
    /// name, though future SwiftPM versions may allow this to be customized).
    public let moduleName: String

    /// The source files that are associated with this target (any files that
    /// have been excluded in the manifest have already been filtered out).
    public let sourceFiles: FileList

    /// Any custom compilation conditions specified for the Swift target in the
    /// package manifest.
    public let compilationConditions: [String]

    /// Any custom linked libraries required by the module, as specified in the
    /// package manifest.
    public let linkedLibraries: [String]

    /// Any custom linked frameworks required by the module, as specified in the
    /// package manifest.
    public let linkedFrameworks: [String]
}

/// Represents a target consisting of a source code module compiled using Clang.
public struct ClangSourceModuleTarget: SourceModuleTarget {
    /// Unique identifier for the target.
    public let id: ID
    
    /// The name of the target, as defined in the package manifest. This name
    /// is unique among the targets of the package in which it is defined.
    public let name: String
    
    /// The kind of module, describing whether it contains unit tests, contains
    /// the main entry point of an executable, or neither.
    public let kind: ModuleKind

    /// The absolute path of the target directory in the local file system.
    public let directory: Path
    
    /// Any other targets on which this target depends, in the same order as
    /// they are specified in the package manifest. Conditional dependencies
    /// that do not apply have already been filtered out.
    public let dependencies: [TargetDependency]

    /// The name of the module produced by the target (derived from the target
    /// name, though future SwiftPM versions may allow this to be customized).
    public let moduleName: String

    /// The source files that are associated with this target (any files that
    /// have been excluded in the manifest have already been filtered out).
    public let sourceFiles: FileList

    /// Any preprocessor definitions specified for the Clang target.
    public let preprocessorDefinitions: [String]
    
    /// Any custom header search paths specified for the Clang target.
    public let headerSearchPaths: [String]

    /// The directory containing public C headers, if applicable. This will
    /// only be set for targets that have a directory of a public headers.
    public let publicHeadersDirectory: Path?

    /// Any custom linked libraries required by the module, as specified in the
    /// package manifest.
    public let linkedLibraries: [String]

    /// Any custom linked frameworks required by the module, as specified in the
    /// package manifest.
    public let linkedFrameworks: [String]
}

/// Represents a target describing an artifact (e.g. a library or executable)
/// that is distributed as a binary.
public struct BinaryArtifactTarget: Target {
    /// Unique identifier for the target.
    public let id: ID

    /// The name of the target, as defined in the package manifest. This name
    /// is unique among the targets of the package in which it is defined.
    public let name: String
    
    /// The absolute path of the target directory in the local file system.
    public let directory: Path
    
    /// Any other targets on which this target depends, in the same order as
    /// they are specified in the package manifest. Conditional dependencies
    /// that do not apply have already been filtered out.
    public let dependencies: [TargetDependency]

    /// The kind of binary artifact.
    public let kind: Kind
    
    /// The original source of the binary artifact.
    public let origin: Origin
    
    /// The location of the binary artifact in the local file system.
    public let artifact: Path

    /// Represents a kind of binary artifact.
    public enum Kind {
        case xcframework
        case artifactsArchive
        case libraryArchive
    }
    
    // Represents the original location of a binary artifact.
    public enum Origin: Equatable {
        /// Represents an artifact that was available locally.
        case local

        /// Represents an artifact that was downloaded from a remote URL.
        case remote(url: String)
    }

}

/// Represents a target describing a system library that is expected to be
/// present on the host system.
public struct SystemLibraryTarget: Target {
    /// Unique identifier for the target.
    public let id: ID

    /// The name of the target, as defined in the package manifest. This name
    /// is unique among the targets of the package in which it is defined.
    public var name: String
    
    /// The absolute path of the target directory in the local file system.
    public var directory: Path
    
    /// Any other targets on which this target depends, in the same order as
    /// they are specified in the package manifest. Conditional dependencies
    /// that do not apply have already been filtered out.
    public var dependencies: [TargetDependency]

    /// The name of the `pkg-config` file, if any, describing the library.
    public let pkgConfig: String?

    /// Flags from `pkg-config` to pass to Clang (and to SwiftC via `-Xcc`).
    public let compilerFlags: [String]
  
    /// Flags from `pkg-config` to pass to the platform linker.
    public let linkerFlags: [String]
}

/// Provides information about a list of files. The order is not defined
/// but is guaranteed to be stable. This allows the implementation to be
/// more efficient than a static file list.
public struct FileList {
    private var files: [File]

    init(_ files: [File]) {
        self.files = files
    }
}
extension FileList: Sequence {
    public struct Iterator: IteratorProtocol {
        private var files: ArraySlice<File>
        fileprivate init(files: ArraySlice<File>) {
            self.files = files
        }
        mutating public func next() -> File? {
            guard let nextInfo = self.files.popFirst() else {
                return nil
            }
            return nextInfo
        }
    }
    public func makeIterator() -> Iterator {
        return Iterator(files: ArraySlice(self.files))
    }
}

/// Provides information about a single file in a FileList.
public struct File {
    /// The path of the file.
    public let path: Path
    
    /// File type, as determined by SwiftPM.
    public let type: FileType
}

/// Provides information about the type of a file. Any future cases will
/// use availability annotations to make sure existing plugins still work
/// until they increase their required tools version.
public enum FileType {
    /// A source file.
    case source

    /// A header file.
    case header

    /// A resource file (either processed or copied).
    case resource

    /// A file not covered by any other rule.
    case unknown
}
