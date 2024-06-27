# Contributing to Swift Package Manager

There are several types of contributions one can make. Bug fixes, documentation and enhancements that do not materially change the user facing semantics of Swift Package Manager should be submitted directly as PR.

Larger changes that do materially change the semantics of Swift Package Manager (e.g. changes to the manifest format or behavior) are required to go through [Swift Evolution Process](https://github.com/apple/swift-evolution/blob/master/process.md).

To see how previous evolution decisions for SwiftPM have been made and have some direction for the development of future features please check out the [Community Proposals](https://forums.swift.org/tag/packagemanager).

For more information about making contributions to the Swift project in general see [Swift Contribution Guide](https://swift.org/contributing/).

## Reporting issues

Issues are tracked using [SwiftPM GitHub Issue Tracker](https://github.com/swiftlang/swift-package-manager/issues).

Fill the following fields:

* `Title`: A one line summary of the problem you're facing.
* `Description`: The complete description of the problem. Be specific.
* `Expected behavior`: How you expect SwiftPM to behave. 
* `Actual behavior` : What actually happens.
* `Steps to reproduce`: Be specific, provide steps to reproduce the bug.
* `Swift Package Manager version/commit hash` : With which version are you testing.
* `Actual behavior` : What actually happens.
* `Swift & OS version` : (output of `swift --version && uname -a`).

Please include a minimal example package which can reproduce the issue. The
sample package can be attached with the report or you can include the URL of the
package hosted on places like GitHub.
Also, include the verbose logs by adding `--verbose` or `-v` after a subcommand.
For example:

    $ swift build --verbose
    $ swift package update --verbose

If the bug is with a generated Xcode project, include how the project was
generated and the Xcode build log.

## Setting up the development environment

First, clone a copy of SwiftPM code from https://github.com/swiftlang/swift-package-manager.

If you are preparing to make a contribution you should fork the repository first and clone the fork which will make opening Pull Requests easier. See "Creating Pull Requests" section below.

SwiftPM is typically built with a pre-existing version of SwiftPM present on the system, but there are multiple ways to setup your development environment:

### Using Xcode (Easiest)

1. Install Xcode from [https://developer.apple.com/xcode](https://developer.apple.com/xcode) (including betas!).
2. Verify the expected version of Xcode was installed.
3. Open SwiftPM's `Package.swift` manifest with Xcode.
4. Use Xcode to inspect, edit, and build the code.
5. Select the `SwiftPM-Package` scheme to run the tests from Xcode. Note that the `SwiftPM-Package`
should be built prior to running any other schemes. This is so the `PackageDescription` module can be
built and cached for use.

### Using the Command Line

If you are using macOS and have Xcode installed, you can use Swift from the command line immediately.

If you are not using macOS or do not have Xcode installed, you need to download and install a toolchain.

#### Installing a toolchain

1. Download a toolchain from https://swift.org/download/
2. Install it and verify the expected version of the toolchain was installed:

**macOS**

```bash
$> export TOOLCHAINS=swift
$> xcrun --find swift
/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift
$> swift package --version
Swift Package Manager - Swift 5.3.0
$> swift --version
Apple Swift version 5.3
```

**Linux**

```bash
$> export PATH=/path/to/swift-toolchain/usr/bin:"${PATH}"
$> which swift
/path/to/swift-toolchain/usr/bin/swift
$> swift package --version
Swift Package Manager - Swift 5.3.0
$> swift --version
Apple Swift version 5.3
```

Note: Alternatively use tools like [swiftenv](https://github.com/kylef/swiftenv) that help manage toolchains versions.

## Local Development

With a Swift toolchain installed and the SwiftPM code cloned, you are ready to make changes and test them locally.

### Building

```bash
$> swift build
```

A successful build will create a `.build/` directory with the following approximate structure:

```
artifacts
checkouts
debug
repositories
x86_64-apple-macosx
```

Binary artifacts are located in `x86_64-apple-macosx/` when building on macOS,
or the equivalent on other architectures and operating systems.

These binaries can be used to test the code modification. For example, to test the `swift package init` and `swift build` commands from the new SwiftPM artifacts in `.build/`:

```bash
$> cd /tmp && mkdir hello && cd hello
$> /path/to/swiftpm/.build/x86_64-apple-macosx/debug/swift-package init
$> /path/to/swiftpm/.build/x86_64-apple-macosx/debug/swift-build
```

### Testing

```bash
$> swift test
```

to run a single test:

```bash
$> swift test --filter PackageGraphTests.DependencyResolverTests/testBasics
```

Or another example, to run tests for the test targets BuildTests and WorkspaceTests, but skip some test cases:

```bash
$> swift test --filter BuildTests --skip BuildPlanTests --filter WorkspaceTests --skip InitTests
```

To run the performance tests, enable them with an ENV variable:

```bash
$> export TSC_ENABLE_PERF_TESTS=1
$> swift test -c release --filter PerformanceTests
```

### The bootstrap script

The bootstrap script is designed for building SwiftPM on systems that do not have Xcode or a toolchain installed.
It is used on bare systems to bootstrap the Swift toolchain (including SwiftPM), and as such not typically used outside the Swift team.

The bootstrap script requires having [CMake](https://cmake.org/) and [Ninja](https://ninja-build.org/) installed.
Please refer to the [_Get Started_ guide](https://github.com/apple/swift/blob/main/docs/HowToGuides/GettingStarted.md#installing-dependencies) on the Swift project repository for installation instructions.

Clone the following repositories beside the SwiftPM directory:

1. [swift-argument-parser] and check out tag with the [latest version](https://github.com/apple/swift-argument-parser/tags).

   For example, if the latest tag is 0.4.3:
   ```sh
   $> git clone https://github.com/apple/swift-argument-parser --branch 0.4.3
   ```

2. [swift-llbuild] as llbuild
   ```sh
   $> git clone https://github.com/apple/swift-llbuild llbuild
   ```
   > Note: Make sure the directory for llbuild is called "llbuild" and not "swift-llbuild".

3. [swift-tools-support-core]
   ```sh
   $> git clone https://github.com/apple/swift-tools-support-core
   ```

4. [Yams] and checkout tag with the [latest version](https://github.com/jpsim/Yams.git/tags) before 5.0.0.

   For example, if the latest tag is 4.0.6:
   ```sh
   $> git clone https://github.com/jpsim/yams --branch 4.0.6
   ```

5. [swift-driver]
   ```sh
   $> git clone https://github.com/apple/swift-driver
   ```

6. [swift-system] and check out tag with the [latest version](https://github.com/apple/swift-system/tags).

    For example, if the latest tag is 1.0.0:
    ```sh
    $> git clone https://github.com/apple/swift-system --branch 1.0.0
    ```

7. [swift-collections] and check out tag with the [latest version](https://github.com/apple/swift-collections/tags).

    For example, if the latest tag is 1.0.1:
    ```sh
    $> git clone https://github.com/apple/swift-collections --branch 1.0.1
    ```

7. [swift-crypto] and check out tag with the [latest version](https://github.com/apple/swift-crypto/tags).

    For example, if the latest tag is 2.3.0:
    ```sh
    $> git clone https://github.com/apple/swift-crypto --branch 2.3.0
    ```

8. [swift-asn1]
   ```sh
   $> git clone https://github.com/apple/swift-asn1
   ```

9. [swift-certificates]
   ```sh
   $> git clone https://github.com/apple/swift-certificates
   ```

[swift-argument-parser]: https://github.com/apple/swift-argument-parser
[swift-collections]: https://github.com/apple/swift-collections
[swift-driver]: https://github.com/apple/swift-driver
[swift-llbuild]: https://github.com/apple/swift-llbuild
[swift-system]: https://github.com/apple/swift-system
[swift-tools-support-core]: https://github.com/apple/swift-tools-support-core
[swift-crypto]: https://github.com/apple/swift-crypto
[swift-asn1]: https://github.com/apple/swift-asn1
[swift-certificates]: https://github.com/apple/swift-certificates
[Yams]: https://github.com/jpsim/yams


#### Building

```bash
$> Utilities/bootstrap build
```

See "Using the Command Line / Building" section above for more information on how to test the new artifacts.

#### Testing

```bash
$> Utilities/bootstrap test
```

## Working with Docker to build and test for Linux

When developing on macOS and need to test on Linux, install
[Docker](https://www.docker.com/products/docker-desktop) and
[Docker compose](https://docs.docker.com/compose/install/) and
use the following docker compose commands:

Prepare the underlying image with the selected Ubuntu and Swift versions:

```bash
docker-compose \
  -f Utilities/docker/docker-compose.yaml \
  -f Utilities/docker/docker-compose.<os-version>.<swift-version>.yaml \
  build
```

Start an interactive shell session:

```bash
docker-compose \
  -f Utilities/docker/docker-compose.yaml \
  -f Utilities/docker/docker-compose.<os-version>.<swift-version>.yaml \
  run --rm shell
```

Build SwiftPM (using the pre-installed SwiftPM version).

```bash
docker-compose \
  -f Utilities/docker/docker-compose.yaml \
  -f Utilities/docker/docker-compose.<os-version>.<swift-version>.yaml \
  run --rm build
```

Test SwiftPM (using the pre-installed SwiftPM version).

```bash
docker-compose \
  -f Utilities/docker/docker-compose.yaml \
  -f Utilities/docker/docker-compose.<os-version>.<swift-version>.yaml \
  run --rm test
```

Build SwiftPM using the bootstrap script:

```bash
docker-compose \
  -f Utilities/docker/docker-compose.yaml \
  -f Utilities/docker/docker-compose.<os-version>.<swift-version>.yaml \
  run --rm bootstrap-build
```

Test SwiftPM using the bootstrap script:

```bash
docker-compose \
  -f Utilities/docker/docker-compose.yaml \
  -f Utilities/docker/docker-compose.<os-version>.<swift-version>.yaml \
  run --rm bootstrap-test
```

Note there are several Linux and Swift versions options to choose from, e.g.:

`docker-compose.1804.53.yaml` => Ubuntu 18.04, Swift 5.3

`docker-compose.2004.54.yaml` => Ubuntu 20.04, Swift 5.4

`docker-compose.2004.main.yaml` => Ubuntu 20.04, Swift nightly

## Creating Pull Requests

1. Fork: https://github.com/swiftlang/swift-package-manager
2. Clone a working copy of your fork
3. Create a new branch
4. Make your code changes
5. Try to keep your changes (when possible) below 200 lines of code.
6. We use [SwiftFormat](https://www.github.com/nicklockwood/SwiftFormat) to enforce code style. Please install and run SwiftFormat before submitting your PR.
7. Commit (include the Radar link or GitHub issue id in the commit message if possible and a description your changes). Try to have only 1 commit in your PR (but, of course, if you add changes that can be helpful to be kept aside from the previous commit, make a new commit for them).
8. Push the commit / branch to your fork
9. Make a PR from your fork / branch to `apple: main`
10. While creating your PR, make sure to follow the PR Template providing information about the motivation and highlighting the changes.
11. Reviewers are going to be automatically added to your PR
12. Pull requests will be merged by the maintainers after it passes CI testing and receives approval from one or more reviewers. Merge timing may be impacted by release schedule considerations.

By submitting a pull request, you represent that you have the right to license
your contribution to Apple and the community, and agree by submitting the patch
that your contributions are licensed under the [Swift
license](https://swift.org/LICENSE.txt).

## Continuous Integration

SwiftPM uses [swift-ci](https://ci.swift.org) infrastructure for its continuous integration testing. The bots can be triggered on pull-requests if you have commit access. Otherwise, ask one of the code owners to trigger them for you.

To run smoke test suite with the trunk compiler and other projects use:

```
@swift-ci please smoke test
```

This is **required** before a pull-request can be merged.


To run just the self-hosted test suite (faster turnaround times so it can be used to get quick feedback) use:

```
@swift-ci please smoke test self hosted
```


To run the swift toolchain test suite including SwiftPM use:

```
@swift-ci please test
```


To run package compatibility test suite (validates we do not break 3rd party packages) use:

```
@swift-ci please test package compatibility
```

## Generating Documentation

SwiftPM uses [DocC](https://github.com/apple/swift-docc) to generate some of its documentation (currently only the `PackageDescription` module). Documentation can be built using Xcode's GUI (Product → Build Documentation or `⌃⇧⌘D`) or manually:

1. Build and dump the symbol graph metadata used to generate the documentation:

```
swift package dump-symbol-graph
```

2. Generate the documentation and start a local preview server to review your changes:

```
xcrun docc preview Sources/PackageDescription/PackageDescription.docc --additional-symbol-graph-dir .build/*/symbolgraph/
```

Note that this may generate documentation for multiple modules — the preview link for PackageDescription will typically be: http://localhost:8000/documentation/packagedescription

## Advanced

### Using Custom Swift Compilers

SwiftPM needs the Swift compiler to parse `Package.swift` manifest files and to
compile Swift source files. You can use the `SWIFT_EXEC` and `SWIFT_EXEC_MANIFEST`
environment variables to control which compiler to use for these operations.

`SWIFT_EXEC_MANIFEST`: This variable controls which compiler to use for parsing
`Package.swift` manifest files. The lookup order for the manifest compiler is:
`SWIFT_EXEC_MANIFEST`, `swiftc` adjacent to the `swiftpm` binaries, then `SWIFT_EXEC`

`SWIFT_EXEC`: This variable controls which compiler to use for compiling Swift
sources. The lookup order for the sources' compiler is: `SWIFT_EXEC`, then `swiftc` adjacent
to `swiftpm` binaries. This is also useful for Swift compiler developers when they
want to use a debug compiler with SwiftPM.

```bash
$> SWIFT_EXEC=/path/to/my/built/swiftc swift build
```

### Overriding the Path to the Runtime Libraries

SwiftPM computes the path of its runtime libraries relative to where it is
installed. This path can be overridden by setting the environment variable
`SWIFTPM_CUSTOM_LIBS_DIR` to a directory containing the libraries, or a colon-separated list of
absolute search paths. SwiftPM will choose the first
path which exists on disk. If none of the paths are present on disk, it will fall
back to built-in computation.

### Making changes in TSC targets

SwiftPM uses [Tools Support Core](https://github.com/apple/swift-tools-support-core) (aka TSC) for many of its general purpose utilities. Changes in SwiftPM often require changes in TSC first. To coordinate changes, open a PR against TSC first, then a second one against SwiftPM pulling the correct TSC version.

## Community and Support

If you want to connect with the Swift community you can:
* Use Swift Forums: [https://forums.swift.org/c/development/SwiftPM](https://forums.swift.org/c/development/SwiftPM)
* Contact the CODEOWNERS: https://github.com/swiftlang/swift-package-manager/blob/main/CODEOWNERS

## Additional resources

* `Swift.org` Contributing page
[https://swift.org/contributing/](https://swift.org/contributing/)
* License
[https://swift.org/LICENSE.txt](https://swift.org/LICENSE.txt)
* Code of Conduct
[https://swift.org/community/#code-of-conduct](https://swift.org/community/#code-of-conduct)

## Troubleshooting

* If during `swift build` you encounter this error:
```bash
/../apple-repos/swift-package-manager/.build/checkouts/swift-driver/Sources/SwiftDriver/Explicit Module Builds/InterModuleDependencyGraph.swift:102:3: error: unknown attribute '_spi'
  @_spi(Testing) public var isFramework: Bool
  ^
```
Make sure you are using SwiftPM 5.3
```bash
$> swift package --version
Swift Package Manager - Swift 5.3.0
```
* If during `swift build` you encounter this error:
```bash
/../swift-package-manager/Sources/PackageLoading/Target+PkgConfig.swift:84:36: error: type 'PkgConfigError' has no member 'prohibitedFlags'
            error = PkgConfigError.prohibitedFlags(filtered.unallowed.joined(separator: ", "))
                    ~~~~~~~~~~~~~~ ^~~~~~~~~~~~~~~
```
Make sure to update your TSC (Tools Support Core):
```bash
$> swift package update
```
Alternatively, if you are using Xcode, you can update to the latest version of all packages:  
**Xcode App** > *File* > *Swift Packages* > *Update to Latest Package Versions*
