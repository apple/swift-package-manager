Note: This is in reverse chronological order, so newer entries are added to the top.

Swift Next
-----------

* [#7530]

  Starting from tools-version 6.0 makes it possible for packages to depend on each other if such dependency doesn't form any target-level cycles.
  For example, package `A` can depend on `B` and `B` on `A` unless targets in `B` depend on products of `A` that depend on some of the same
  targets from `B` and vice versa.

Swift 6.0
-----------

* [#7507] 

  `swift experimental-sdk` command is deprecated with `swift sdk` command replacing it. `--experimental-swift-sdk` and
  `--experimental-swift-sdks-path` options on `swift build` are deprecated with replacements that don't have the
  `experimental` prefix.

* [#7535] The `swift sdk configuration` subcommand is deprecated with a replacement named `configure` that has options that exactly match
  [SE-0387 proposal text].

* [#7202]

  Package manifests can now access information about the Git repository the given package is in via the context object's 
  `gitInformation` property. This allows to determine the current tag (if any), the current commit and whether or not there are uncommited changes.

* [#7201]

  `// swift-tools-version:` can now be specified on subsequent lines of `Package.swift`, for example when first few lines are required to contain a licensing comment header.

* [#7118]

  Macros cross-compiled by SwiftPM with Swift SDKs are now correctly built, loaded, and evaluated for the host triple.

Swift 5.10
-----------

* [#7010]

  On macOS, `swift build` and `swift run` now produce binaries that allow backtraces in debug builds. Pass `SWIFT_BACKTRACE=enable=yes` environment variable to enable backtraces on such binaries when running them.

* [#7101]

   Binary artifacts are now cached along side repository checkouts so they do not need to be re-downloaded across projects.

Swift 5.9
-----------

* [SE-0386]

  SwiftPM packages can now use `package` as a new access modifier, allowing accessing symbols in another target / module within the same package without making it public.

* [SE-0387]

  New `swift experimental-sdk` experimental command is now available for managing Swift SDK bundles that follow the format described in [SE-0387]: "Swift SDKs for Cross-Compilation".

* [SE-0391]

  SwiftPM can now publish to a registry following the publishing spec as defined in [SE-0391]. SwiftPM also gains support for signed packages. Trust-on-first-use (TOFU) check which includes only fingerprints (e.g., checksums) previously has been extended to include signing identities, and it is enforced for source archives as well as package manifests.

* [#5966]

  Plugin compilation can be influenced by using `-Xbuild-tools-swiftc` arguments in the SwiftPM command line. This is similar to the existing mechanism for influencing the manifest compilation using `-Xmanifest` arguments. Manifest compilation will also be influenced by `-Xbuild-tools-swiftc`, but only if no other `-Xmanifest` arguments are provided. Using `-Xmanifest` will show a deprecation message. `-Xmanifest` will be removed in the future.

* [#6060]

  Support for building plugin dependencies for the host when cross-compiling.

* [#6067]

  Basic support for a new `.embedInCode` resource rule which allows embedding the contents of the resource into the executable code by generating a byte array, e.g.

  ```
  struct PackageResources {
    static let best_txt: [UInt8] = [104,101,108,108,111,32,119,111,114,108,100,10]
  }
  ```

* [#6111]

  Package creation using `package init` now also supports the build tool plugin and command plugin types.

* [#6114]

  Added a new `allowNetworkConnections(scope:reason:)` for giving a command plugin permissions to access the network. Permissions can be scoped to Unix domain sockets in general or specifically for Docker, as well as local or remote IP connections which can be limited by port. For non-interactive use cases, there is also a `--allow-network-connections` commandline flag to allow network connections for a particular scope.

* [#6144]

  Remove the `system-module` and `manifest` templates and clean up the remaining `empty`, `library`, and `executable` templates so they include the minimum information needed to get started, with links to documentation in the generated library, executable, and test content.

* [#6185], [#6200]

  Add a new `CompilerPluginSupport` module which contains the definition for macro targets. Macro targets allow authoring and distribution of custom Swift macros such as [expression macros](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md).

* [#6276]

  Add new build setting in the package manifest that enables Swift/C++ Interoperability for a given Swift target.

  ```
  .interoperabilityMode(.Cxx, version: "swift-5.9")
  ```
  
* [#6294]

  When a package contains a single target, sources may be distributed anywhere within the `./Sources` directory. If sources are placed in a subdirectory under `./Sources/<target>`, or there is more than one target, the existing expectation for sources apply.

* [#6540]

  Build tool plugins can be used with C-family targets

* [#6663]

  Add `visionOS` as a platform alongside `iOS` and other platforms
  

Swift 5.8
-----------

* [SE-0362] 

  SwiftPM targets can now specify the upcoming language features they require. `Package.swift` manifest syntax has been expanded with an API to include setting `enableUpcomingFeature` and `enableExperimentalFeature` flags at the target level, as specified by [SE-0362].
  
* [SE-0378]

  SwiftPM now supports token authentication when interacting with a package registry. The `swift package-registry` command has two new subcommands `login` and `logout` as defined in SE-0378 for adding/removing registry credentials.  

* [#5810]

  SwiftPM now allows exposing an executable product that consists solely of a binary target that is backed by an artifact bundle. This allow vending binary executables as their own separate package, independently of the plugins that are using them.  

* [#5819]

  Improved handling of offline behavior when a cached version of a dependency exists on disk. SwiftPM will check for network availability status to determine if it should attempt to update a checked version of a dependency, and when offline will use the cached version without an update.

* [#5874]

  In packages using tools version 5.8 or later, Foundation is no longer implicitly imported into package manifests. If Foundation APIs are used, the module needs to be imported explicitly.
  
* [#5892]

  Added new `--emit-extension-block-symbols` and `--omit-extension-block-symbols` via `swift package dump-symbol-graph`. `--emit-extension-block-symbols` dumps symbol graph files that are extension block symbol format. The default behavior does not change. The `--omit-extension-block-symbols` flag will be used to explicitly disable the feature once the default behavior has been changed to `--emit-extension-block-symbols` in the future.
  
* [#5949]
  
  New `--pkg-config-path` option on `build`, `test`, and `run` commands has been introduced as an alternative to passing `PKG_CONFIG_PATH` environment variable. It allows specifying alternative path to search for `.pc` files used by `pkg-config`. Use the option multiple times to specify more than one path.  

Swift 5.7
-----------

* [SE-0292]

  SwiftPM can now resolve dependencies from a server compliant with the package registry server API defined in SE-0292. 
  
* [SE-0339]

  Module aliases can now be defined in the package manifest to disambiguate between modules with the same name originating from different packages. 

* [#4119] 
 
  Add a `--disable-testable-imports` flag to `swift test` with which tests are built without the testability feature (`import @testable` disabled).

* [#4131]

  Update to manifest API to make it impossible to create an invalid build settings condition.

* [#4135]

  Enable linker dead stripping for all platforms. This can be disabled with `--disable-dead-strip`

* [#4168]

  Update to manifest API to make it impossible to create an invalid target dependency condition.

Swift 5.6
-----------
* [SE-0303]

  Package plugins of the type `buildTool` can now be declared in packages that specify a tools version of 5.6 or later, and can be invoked using the `swift build` command.
  
* [SE-0332]

  Package plugins of the type `command` can now be declared in packages that specify a tools version of 5.6 or later, and can be invoked using the `swift package` subcommand.

* [#3649]

  Semantic version dependencies can now be resolved against Git tag names that contain only major and minor version identifiers.  A tag with the form `X.Y` will be treated as `X.Y.0`. This improves compatibility with existing repositories.

* [#3486]

  Both parsing and comparison of semantic versions now strictly follow the [Semantic Versioning 2.0.0 specification](https://semver.org). 
  
  The parsing logic now treats the first "-" in a version string as the delimiter between the version core and the pre-release identifiers, _only_ if there is no preceding "+". Otherwise, it's treated as part of a build metadata identifier.
  
  The comparison logic now ignores build metadata identifiers, and treats 2 semantic versions as equal if and only if they're equal in their major, minor, patch versions and pre-release identifiers.

* [#3641]

  Soft deprecate `.package(name:, url:)` dependency syntax in favor of `.package(url:)`, given that an explicit `name` attribute is no longer needed for target dependencies lookup.

* [#3641]

  Adding a dependency requirement can now be done with the convenience initializer `.package(url: String, exact: Version)`.

* [#3641]

  Dependency requirement enum calling convention is deprecated in favour of labeled argument:    
    * `.package(url: String, .branch(String))` -> `.package(url: String, branch: String)`
    * `.package(url: String, .revision(String))` -> `.package(url: String, revision: String)`    
    * `.package(url: String, .exact(Version))` -> `.package(url: String, exact: Version)` 

* [#3717]

  Introduce a second version of `Package.resolved` file format which more accurately captures package identity.

* [#3890]

  To increase the security of packages, SwiftPM performs trust on first use (TOFU) validation. The fingerprint of a package is now being recorded when the package is first downloaded from a Git repository or package registry. Subsequent downloads must have fingerpints matching previous recorded values, otherwise it would result in build warnings or failures depending on settings.   

* [#3670], [#3901], [#3942]

  Location of configuration files (including mirror file) have changed to accomodate new features that require more robust configuration directories structure, such as SE-0292:  
    * `<project>/.swiftpm/config` (mirrors file) was moved to `<project>/.swiftpm/configuration/mirrors.json`. SwiftPM 5.6 will automatically copy the file from the old location to the new one and emit a warning to prompt the user to delete the file from the old location.
    * `~/.swiftpm/config/collections.json` (collections file) was moved to `~/.swiftpm/configuration/collections.json`. SwiftPM 5.6 will automatically copy the file from the old location to the new one and emit a warning to prompt the user to delete the file from the old location.


Swift 5.5
-----------
* [#3410]

  In a package that specifies a minimum tools version of 5.5, `@main` can now be used in a single-source file executable as long as the name of the source file isn't `main.swift`.  To work around special compiler semantics with single-file modules, SwiftPM now passes `-parse-as-library` when compiling an executable module that contains a single Swift source file whose name is not `main.swift`.

* [#3310]

  Adding a dependency requirement can now be done with the convenience initializer `.package(url: String, revision: String)`.

* [#3292]

  Adding a dependency requirement can now be done with the convenience initializer `.package(url: String, branch: String)`.

* [#3280]

  A more intuitive `.product(name:, package:)` target dependency syntax is now accepted, where `package` is the package identifier as defined by the package URL.

* [#3316]

  Test targets can now link against executable targets as if they were libraries, so that they can test any data structures or algorithms in them.  All the code in the executable except for the main entry point itself is available to the unit test.  Separate executables are still linked, and can be tested as a subprocess in the same way as before.  This feature is available to tests defined in packages that have a tools version of `5.5` or newer. 


Swift 5.4
-----------
* [#2937]
  
  * Improvements
    
    `Package` manifests can now have any combination of leading whitespace characters. This allows more flexibility in formatting the manifests.
    
    [SR-13566] The Swift tools version specification in each manifest file now accepts any combination of _horizontal_ whitespace characters surrounding `swift-tools-version`, if and only if the specified version ≥ `5.4`. For example, `//swift-tools-version:	5.4` and `//		 swift-tools-version: 5.4` are valid.
  
    All [Unicode line terminators](https://www.unicode.org/reports/tr14/) are now recognized in `Package` manifests. This ensures correctness in parsing manifests that are edited and/or built on many non-Unix-like platforms that use ASCII or Unicode encodings. 
  
  * API Removal
  
    `ToolsVersionLoader.Error.malformedToolsVersion(specifier: String, currentToolsVersion: ToolsVersion)` is replaced by `ToolsVersionLoader.Error.malformedToolsVersionSpecification(_ malformation: ToolsVersionSpecificationMalformation)`.
    
    `ToolsVersionLoader.split(_ bytes: ByteString) -> (versionSpecifier: String?, rest: [UInt8])` and `ToolsVersionLoader.regex` are together replaced by `ToolsVersionLoader.split(_ manifest: String) -> ManifestComponents`.
  
  * Source Breakages for Swift Packages
    
    The package manager now throws an error if a manifest file contains invalid UTF-8 byte sequences.
    

Swift 4.2
---------

* [SE-0209]

  The `swiftLanguageVersions` property no longer takes its Swift language versions via
  a freeform Integer array; instead it should be passed as a new `SwiftVersion` enum
  array.

* [SE-0208]

  The `Package` manifest now accepts a new type of target, `systemLibrary`. This
  deprecates "system-module packages" which are now to be included in the packages
  that require system-installed dependencies.

* [SE-0201]

  Packages can now specify a dependency as `package(path: String)` to point to a
  path on the local filesystem which hosts a package. This will enable interconnected
  projects to be edited in parallel.

* [#1604]

  The `generate-xcodeproj` has a new `--watch` option to automatically regenerate the Xcode project
  if changes are detected. This uses the
  [`watchman`](https://facebook.github.io/watchman/docs/install.html) tool to detect filesystem
  changes.

* Scheme generation has been improved:
  * One scheme containing all regular and test targets of the root package.
  * One scheme per executable target containing the test targets whose dependencies
    intersect with the dependencies of the exectuable target.

* [SR-6978]
  Packages which mix versions of the form `vX.X.X` with `Y.Y.Y` will now be parsed and
  ordered numerically.

* [#1489]
  A simpler progress bar is now generated for "dumb" terminals.


Swift 4.1
---------

* [#1485]
  Support has been added to automatically generate the `LinuxMain` files for testing on
  Linux systems. On a macOS system, run `swift test --generate-linuxmain`.

* [SR-5918]
  `Package` manifests that include multiple products with the same name will now throw an
  error.


Swift 4.0
---------

* The generated Xcode project creates a dummy target which provides
  autocompletion for the manifest files. The name of the dummy target is in
  format: `<PackageName>PackageDescription`.

* `--specifier` option for `swift test` is now deprecated.
  Use `--filter` instead which supports regex.


Swift 3.0
---------

* [SE-0135]

  The package manager now supports writing Swift 3.0 specific tags and
  manifests, in order to support future evolution of the formats used in both
  cases while still allowing the Swift 3.0 package manager to continue to
  function.

* [SE-0129]

  Test modules now *must* be named with a `Tests` suffix (e.g.,
  `Foo/Tests/BarTests/BarTests.swift`). This name also defines the name of the
  Swift module, replacing the old `BarTestSuite` module name.

* It is no longer necessary to run `swift build` before running `swift test` (it
  will always regenerates the build manifest when necessary). In addition, it
  now accepts (and requires) the same `-Xcc`, etc. options as are used with
  `swift build`.

* The `Package` initializer now requires the `name:` parameter.

[SE-0129]: https://github.com/apple/swift-evolution/blob/main/proposals/0129-package-manager-test-naming-conventions.md
[SE-0135]: https://github.com/apple/swift-evolution/blob/main/proposals/0135-package-manager-support-for-differentiating-packages-by-swift-version.md
[SE-0201]: https://github.com/apple/swift-evolution/blob/main/proposals/0201-package-manager-local-dependencies.md
[SE-0208]: https://github.com/apple/swift-evolution/blob/main/proposals/0208-package-manager-system-library-targets.md
[SE-0209]: https://github.com/apple/swift-evolution/blob/main/proposals/0209-package-manager-swift-lang-version-update.md
[SE-0292]: https://github.com/apple/swift-evolution/blob/main/proposals/0292-package-registry-service.md
[SE-0303]: https://github.com/apple/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md
[SE-0332]: https://github.com/apple/swift-evolution/blob/main/proposals/0332-swiftpm-command-plugins.md
[SE-0339]: https://github.com/apple/swift-evolution/blob/main/proposals/0339-module-aliasing-for-disambiguation.md
[SE-0362]: https://github.com/apple/swift-evolution/blob/main/proposals/0362-piecemeal-future-features.md
[SE-0378]: https://github.com/apple/swift-evolution/blob/main/proposals/0378-package-registry-auth.md
[SE-0386]: https://github.com/apple/swift-evolution/blob/main/proposals/0386-package-access-modifier.md
[SE-0387]: https://github.com/apple/swift-evolution/blob/main/proposals/0387-cross-compilation-destinations.md
[SE-0391]: https://github.com/apple/swift-evolution/blob/main/proposals/0391-package-registry-publish.md
[SE-0387 proposal text]: https://github.com/apple/swift-evolution/blob/main/proposals/0387-cross-compilation-destinations.md#swift-sdk-installation-and-configuration

[SR-5918]: https://bugs.swift.org/browse/SR-5918
[SR-6978]: https://bugs.swift.org/browse/SR-6978
[SR-13566]: https://bugs.swift.org/browse/SR-13566

[#1485]: https://github.com/apple/swift-package-manager/pull/1485
[#1489]: https://github.com/apple/swift-package-manager/pull/1489
[#1604]: https://github.com/apple/swift-package-manager/pull/1604
[#2937]: https://github.com/apple/swift-package-manager/pull/2937
[#3280]: https://github.com/apple/swift-package-manager/pull/3280
[#3292]: https://github.com/apple/swift-package-manager/pull/3292
[#3310]: https://github.com/apple/swift-package-manager/pull/3310
[#3316]: https://github.com/apple/swift-package-manager/pull/3316
[#3410]: https://github.com/apple/swift-package-manager/pull/3410
[#3486]: https://github.com/apple/swift-package-manager/pull/3486
[#3641]: https://github.com/apple/swift-package-manager/pull/3641
[#3649]: https://github.com/apple/swift-package-manager/pull/3649
[#3670]: https://github.com/apple/swift-package-manager/pull/3670
[#3717]: https://github.com/apple/swift-package-manager/pull/3717
[#3890]: https://github.com/apple/swift-package-manager/pull/3890
[#3901]: https://github.com/apple/swift-package-manager/pull/3901
[#3942]: https://github.com/apple/swift-package-manager/pull/3942
[#4119]: https://github.com/apple/swift-package-manager/pull/4119
[#4131]: https://github.com/apple/swift-package-manager/pull/4131
[#4135]: https://github.com/apple/swift-package-manager/pull/4135
[#4168]: https://github.com/apple/swift-package-manager/pull/4168
[#5728]: https://github.com/apple/swift-package-manager/pull/5728
[#5810]: https://github.com/apple/swift-package-manager/pull/5810
[#5819]: https://github.com/apple/swift-package-manager/pull/5819
[#5874]: https://github.com/apple/swift-package-manager/pull/5874
[#5949]: https://github.com/apple/swift-package-manager/pull/5949
[#5892]: https://github.com/apple/swift-package-manager/pull/5892
[#5966]: https://github.com/apple/swift-package-manager/pull/5966
[#6060]: https://github.com/apple/swift-package-manager/pull/6060
[#6067]: https://github.com/apple/swift-package-manager/pull/6067
[#6111]: https://github.com/apple/swift-package-manager/pull/6111
[#6114]: https://github.com/apple/swift-package-manager/pull/6114
[#6144]: https://github.com/apple/swift-package-manager/pull/6144
[#6294]: https://github.com/apple/swift-package-manager/pull/6294
[#6185]: https://github.com/apple/swift-package-manager/pull/6185
[#6200]: https://github.com/apple/swift-package-manager/pull/6200
[#6276]: https://github.com/apple/swift-package-manager/pull/6276
[#6540]: https://github.com/apple/swift-package-manager/pull/6540
[#6663]: https://github.com/apple/swift-package-manager/pull/6663
[#7010]: https://github.com/apple/swift-package-manager/pull/7010
[#7101]: https://github.com/apple/swift-package-manager/pull/7101
[#7118]: https://github.com/apple/swift-package-manager/pull/7118
[#7201]: https://github.com/apple/swift-package-manager/pull/7201
[#7202]: https://github.com/apple/swift-package-manager/pull/7202
[#7507]: https://github.com/apple/swift-package-manager/pull/7507
[#7530]: https://github.com/apple/swift-package-manager/pull/7530
[#7535]: https://github.com/apple/swift-package-manager/pull/7535
