# Usage

## Table of Contents

* [Overview](README.md)
* [**Usage**](Usage.md)
  * [Creating a Package](#creating-a-package)
    * [Creating a Library Package](#creating-a-library-package)
    * [Creating an Executable Package](#creating-an-executable-package)
    * [Creating a Macro Package](#creating-a-macro-package)
  * [Defining Dependencies](#defining-dependencies)
  * [Publishing a Package](#publishing-a-package)
  * [Requiring System Libraries](#requiring-system-libraries)
  * [Packaging Legacy Code](#packaging-legacy-code)
  * [Handling Version-specific Logic](#handling-version-specific-logic)
  * [Editing a Package](#editing-a-package)
    * [Top of Tree Development](#top-of-tree-development)
  * [Resolving Versions (Package.resolved file)](#resolving-versions-packageresolved-file)
  * [Setting the Swift Tools Version](#setting-the-swift-tools-version)
  * [Testing](#testing)
  * [Running](#running)
  * [Setting the Build Configuration](#setting-the-build-configuration)
    * [Debug](#debug)
    * [Release](#release)
    * [Additional Flags](#additional-flags)
  * [Depending on Apple Modules](#depending-on-apple-modules)
  * [Creating C Language Targets](#creating-c-language-targets)
  * [Using Shell Completion Scripts](#using-shell-completion-scripts)
  * [Package manifest specification](PackageDescription.md)
  * [Packages and continuous integration](ContinousIntegration.md)

---

## Creating a Package

Simply put: a package is a git repository with semantically versioned tags,
that contains Swift sources and a `Package.swift` manifest file at its root.

### Creating a Library Package

A library package contains code which other packages can use and depend on. To
get started, create a directory and run `swift package init`:

    $ mkdir MyPackage
    $ cd MyPackage
    $ swift package init # or swift package init --type library
    $ swift build
    $ swift test

This will create the directory structure needed for a library package with a
target and the corresponding test target to write unit tests. A library package
can contain multiple targets as explained in [Target Format
Reference](PackageDescription.md#target).

### Creating an Executable Package

SwiftPM can create native binaries which can be executed from the command line. To
get started:

    $ mkdir MyExecutable
    $ cd MyExecutable
    $ swift package init --type executable
    $ swift build
    $ swift run
    Hello, World!

This creates the directory structure needed for executable targets. Any target
can be turned into a executable target if there is a `main.swift` file present in
its sources. The complete reference for layout is
[here](PackageDescription.md#target).

### Creating a Macro Package

SwiftPM can generate boilerplate for custom macros:

    $ mkdir MyMacro
    $ cd MyMacro
    $ swift package init --type macro
    $ swift build
    $ swift run
    The value 42 was produced by the code "a + b"

This creates a package with a `.macro` type target with its required dependencies
on [swift-syntax](https://github.com/apple/swift-syntax), a library `.target` 
containing the macro's code, and an `.executableTarget` and `.testTarget` for 
running the macro. The sample macro, `StringifyMacro`, is documented in the Swift 
Evolution proposal for [Expression Macros](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md)
and the WWDC [Write Swift macros](https://developer.apple.com/videos/play/wwdc2023/10166) 
video. See further documentation on macros in [The Swift Programming Language](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/macros/) book.

## Defining Dependencies

To depend on a package, define the dependency and the version in the manifest of
your package, and add a product from that package as a dependency, e.g., if
you want to use https://github.com/apple/example-package-playingcard as
a dependency, add the GitHub URL in the dependencies of `Package.swift`:

```swift
import PackageDescription

let package = Package(
    name: "MyPackage",
    dependencies: [
        .package(url: "https://github.com/apple/example-package-playingcard.git", from: "3.0.4"),
    ],
    targets: [
        .target(
            name: "MyPackage",
            dependencies: ["PlayingCard"]
        ),
        .testTarget(
            name: "MyPackageTests",
            dependencies: ["MyPackage"]
        ),
    ]
)
```

Now you should be able to `import PlayingCard` in the `MyPackage` target.

## Publishing a Package

To publish a package, create and push a semantic version tag:

    $ git init
    $ git add .
    $ git remote add origin [github-URL]
    $ git commit -m "Initial Commit"
    $ git tag 1.0.0
    $ git push origin master --tags

Now other packages can depend on version 1.0.0 of this package using the github
url.
An example of a published package can be found here:
https://github.com/apple/example-package-fisheryates

## Requiring System Libraries

You can link against system libraries using the package manager. To do so, you'll
need to add a special `target` of type `.systemLibrary`, and a `module.modulemap`
for each system library you're using.

Let's see an example of adding [libgit2](https://libgit2.github.com) as a
dependency to an executable target.

Create a directory called `example`, and initialize it as a package that
builds an executable:

    $ mkdir example
    $ cd example
    example$ swift package init --type executable

Edit the `Sources/example/main.swift` so it consists of this code:

```swift
import Clibgit

let options = git_repository_init_options()
print(options)
```

To `import Clibgit`, the package manager requires that the libgit2 library has
been installed by a system packager (eg. `apt`, `brew`, `macPort`, `yum`, `nuget`, etc.). The
following files from the libgit2 system-package are of interest:

    /usr/local/lib/libgit2.dylib      # .so on Linux
    /usr/local/include/git2.h

**Note:** the system library may be located elsewhere on your system, such as:
- `/usr/`, or `/opt/homebrew/` if you're using Homebrew on an Apple Silicon Mac.
- `C:\vcpkg\installed\x64-windows\include` on Windows, if you're using `vcpkg`.
On most Unix-like systems, you can use `pkg-config` to lookup where a library is installed:

    example$ pkg-config --cflags libgit2
    -I/usr/local/libgit2/1.6.4/include


**First, let's define the `target` in the package description**:

```swift
// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "example",
    targets: [
        // systemLibrary is a special type of build target that wraps a system library
        // in a target that other targets can require as their dependency.
        .systemLibrary(
            name: "Clibgit",
            pkgConfig: "libgit2",
            providers: [
                .brew(["libgit2"]),
                .apt(["libgit2-dev"])
            ]
        )
    ]
)

```

**Note:** For Windows-only packages `pkgConfig` should be omitted as
`pkg-config` is not expected to be available. If you don't want to use the
`pkgConfig` parameter you can pass the path of a directory containing the
library using the `-L` flag in the command line when building your package
instead.

    example$ swift build -Xlinker -L/usr/local/lib/

Next, create a directory `Sources/Clibgit` in your `example` project, and
add a `module.modulemap` and the header file to it:

    module Clibgit [system] {
      header "git2.h"
      link "git2"
      export *
    }

The header file should look like this:

```c
// git2.h
#pragma once
#include <git2.h>
```

**Note:** Avoiding specifying an absolute path to `git2.h` provided
by the library in the `module.modulemap`. Doing so will break compatibility of 
your project between machines that may use a different file system layout or
install libraries to different paths.

> The convention we hope the community will adopt is to prefix such modules
> with `C` and to camelcase the modules as per Swift module name conventions.
> Then the community is free to name another module simply `libgit` which
> contains more “Swifty” function wrappers around the raw C interface.

The `example` directory structure should look like this now:

    .
    ├── Package.swift
    └── Sources
        ├── Clibgit
        │   ├── git2.h
        │   └── module.modulemap
        └── main.swift

At this point, your system library target is fully defined, and you can now use
that target as a dependency in other targets in your `Package.swift`, like this:

```swift

import PackageDescription

let package = Package(
    name: "example",
    targets: [
        .executableTarget(
            name: "example",

            // example executable requires "Clibgit" target as its dependency.
            // It's a systemLibrary target defined below.
            dependencies: ["Clibgit"],
            path: "Sources"
        ),

        // systemLibrary is a special type of build target that wraps a system library
        // in a target that other targets can require as their dependency.
        .systemLibrary(
            name: "Clibgit",
            pkgConfig: "libgit2",
            providers: [
                .brew(["libgit2"]),
                .apt(["libgit2-dev"])
            ]
        )
    ]
)

```

Now if we type `swift build` in our example app directory we will create an
executable:

    example$ swift build
    …
    example$ .build/debug/example
    git_repository_init_options(version: 0, flags: 0, mode: 0, workdir_path: nil, description: nil, template_path: nil, initial_head: nil, origin_url: nil)
    example$

### Requiring a System Library Without `pkg-config`

Let’s see another example of using [IJG’s JPEG library](http://www.ijg.org)
from an executable, which has some caveats.

Create a directory called `example`, and initialize it as a package that builds
an executable:

    $ mkdir example
    $ cd example
    example$ swift package init --type executable

Edit the `Sources/main.swift` so it consists of this code:

```swift
import CJPEG

let jpegData = jpeg_common_struct()
print(jpegData)
```

Install the JPEG library, on macOS you can use Homebrew package manager: `brew install jpeg`.
`jpeg` is a keg-only formula, meaning it won't be linked to `/usr/local/lib`,
and you'll have to link it manually at build time.

Just like in the previous example, run `mkdir Sources/CJPEG` and add the
following `module.modulemap`:

    module CJPEG [system] {
        header "shim.h"
        header "/usr/local/opt/jpeg/include/jpeglib.h"
        link "jpeg"
        export *
    }

Create a `shim.h` file in the same directory and add `#include <stdio.h>` in
it.

    $ echo '#include <stdio.h>' > shim.h

This is because `jpeglib.h` is not a correct module, that is, it does not contain
the required line `#include <stdio.h>`. Alternatively, you can add `#include <stdio.h>`
to the top of jpeglib.h to avoid creating the `shim.h` file.

Now to use the CJPEG package we must declare our dependency in our example
app’s `Package.swift`:

```swift

import PackageDescription

let package = Package(
    name: "example",
    targets: [
        .executableTarget(
            name: "example",
            dependencies: ["CJPEG"],
            path: "Sources"
            ),
        .systemLibrary(
            name: "CJPEG",
            providers: [
                .brew(["jpeg"])
            ])
    ]
)
```

Now if we type `swift build` in our example app directory we will create an
executable:

    example$ swift build -Xlinker -L/usr/local/jpeg/lib
    …
    example$ .build/debug/example
    jpeg_common_struct(err: nil, mem: nil, progress: nil, client_data: nil, is_decompressor: 0, global_state: 0)
    example$

We have to specify the path where the libjpeg is present using `-Xlinker` because
there is no pkg-config file for it. We plan to provide a solution to avoid passing
the flag in the command line.

### Packages That Provide Multiple Libraries

Some system packages provide multiple libraries (`.so` and `.dylib` files). In
such cases you should add all the libraries to that Swift modulemap package’s
`.modulemap` file:

    module CFoo [system] {
        header "/usr/local/include/foo/foo.h"
        link "foo"
        export *
    }

    module CFooBar [system] {
        header "/usr/include/foo/bar.h"
        link "foobar"
        export *
    }

    module CFooBaz [system] {
        header "/usr/include/foo/baz.h"
        link "foobaz"
        export *
    }

`foobar` and `foobaz` link to `foo`; we don’t need to specify this information
in the module-map because the headers `foo/bar.h` and `foo/baz.h` both include
`foo/foo.h`. It is very important however that those headers do include their
dependent headers, otherwise when the modules are imported into Swift the
dependent modules will not get imported automatically and link errors will
happen. If these link errors occur for consumers of a package that consumes your
package, the link errors can be especially difficult to debug.

### Cross-platform Module Maps

Module maps must contain absolute paths, thus they are not cross-platform. We
intend to provide a solution for this in the package manager. In the long term,
we hope that system libraries and system packagers will provide module maps and
thus this component of the package manager will become redundant.

*Notably* the above steps will not work if you installed JPEG and JasPer with
[Homebrew](http://brew.sh) since the files will be installed to `/usr/local` on
Intel Macs, or /opt/homebrew on Apple silicon Macs. For now adapt the paths,
but as said, we plan to support basic relocations like these.

### Module Map Versioning

Version the module maps semantically. The meaning of semantic version is less
clear here, so use your best judgement. Do not follow the version of the system
library the module map represents; version the module map(s) independently.

Follow the conventions of system packagers; for example, the debian package for
python3 is called python3, as there is not a single package for python and
python is designed to be installed side-by-side. Were you to make a module map
for python3 you should name it `CPython3`.

### System Libraries With Optional Dependencies

At this time you will need to make another module map package to represent
system packages that are built with optional dependencies.

For example, `libarchive` optionally depends on `xz`, which means it can be
compiled with `xz` support, but it is not required. To provide a package that
uses libarchive with xz you must make a `CArchive+CXz` package that depends on
`CXz` and provides `CArchive`.

## Packaging Legacy Code

You may be working with code that builds both as a package and not. For example,
you may be packaging a project that also builds with Xcode.

In these cases, you can use the preprocessor definition `SWIFT_PACKAGE` to
conditionally compile code for Swift packages.

In your source file:
```swift
#if SWIFT_PACKAGE
import Foundation
#endif
```

## Handling Version-specific Logic

The package manager is designed to support packages which work with a variety of
Swift project versions, including both the language and the package manager
version.

In most cases, if you want to support multiple Swift versions in a package you
should do so by using the language-specific version checks available in the
source code itself. However, in some circumstances this may become unmanageable,
specifically, when the package manifest itself cannot be written to be Swift
version agnostic (for example, because it optionally adopts new package manager
features not present in older versions).

The package manager has support for a mechanism to allow Swift version-specific
customizations for the both package manifest and the package versions which will
be considered.

### Version-specific Tag Selection

The tags which define the versions of the package available for clients to use
can _optionally_ be suffixed with a marker in the form of `@swift-3`. When the
package manager is determining the available tags for a repository, _if_
a version-specific marker is available which matches the current tool version,
then it will *only* consider the versions which have the version-specific
marker. Conversely, version-specific tags will be ignored by any non-matching
tool version.

For example, suppose the package `Foo` has the tags `[1.0.0, 1.2.0@swift-3,
1.3.0]`. If version 3.0 of the package manager is evaluating the available
versions for this repository, it will only ever consider version `1.2.0`.
However, version 4.0 would consider only `1.0.0` and `1.3.0`.

This feature is intended for use in the following scenarios:

1. A package wishes to maintain support for Swift 3.0 in older versions, but
   newer versions of the package require Swift 4.0 for the manifest to be
   readable. Since Swift 3.0 will not know to ignore those versions, it would
   fail when performing dependency resolution on the package if no action is
   taken. In this case, the author can re-tag the last versions which supported
   Swift 3.0 appropriately.

2. A package wishes to maintain dual support for Swift 3.0 and Swift 4.0 at the
   same version numbers, but this requires substantial differences in the code.
   In this case, the author can maintain parallel tag sets for both versions.

It is *not* expected that the packages would ever use this feature unless absolutely
necessary to support existing clients. Specifically, packages *should not*
adopt this syntax for tagging versions supporting the _latest GM_ Swift
version.

The package manager supports looking for any of the following marked tags, in
order of preference:

1. `MAJOR.MINOR.PATCH` (e.g., `1.2.0@swift-3.1.2`)
2. `MAJOR.MINOR` (e.g., `1.2.0@swift-3.1`)
3. `MAJOR` (e.g., `1.2.0@swift-3`)

### Version-specific Manifest Selection

The package manager will additionally look for a version-specific marked
manifest version when loading the particular version of a package, by searching
for a manifest in the form of `Package@swift-3.swift`. The set of markers
looked for is the same as for version-specific tag selection.

This feature is intended for use in cases where a package wishes to maintain
compatibility with multiple Swift project versions, but requires a
substantively different manifest file for this to be viable (e.g., due to
changes in the manifest API).

It is *not* expected the packages would ever use this feature unless absolutely
necessary to support existing clients. Specifically, packages *should not*
adopt this syntax for tagging versions supporting the _latest GM_ Swift
version.

In case the current Swift version doesn't match any version-specific manifest,
the package manager will pick the manifest with the most compatible tools
version. For example, if there are three manifests:

`Package.swift` (tools version 3.0)
`Package@swift-4.swift` (tools version 4.0)
`Package@swift-4.2.swift` (tools version 4.2)

The package manager will pick `Package.swift` on Swift 3, `Package@swift-4.swift` on
Swift 4, and `Package@swift-4.2.swift` on Swift 4.2 and above because its tools
version will be most compatible with future version of the package manager.

## Editing a Package

Swift package manager supports editing dependencies, when your work requires
making a change to one of your dependencies (for example, to fix a bug, or add
a new API). The package manager moves the dependency into a location under the
`Packages/` directory where it can be edited.

For the packages which are in the editable state, `swift build` will always use
the exact sources in this directory to build, regardless of their state, Git
repository status, tags, or the tag desired by dependency resolution. In other
words, this will _just build_ against the sources that are present. When an
editable package is present, it will be used to satisfy all instances of that
package in the dependency graph. It is possible to edit all, some, or none of
the packages in a dependency graph, without restriction.

Editable packages are best used to do experimentation with dependency code, or to
create and submit a patch in the dependency owner's repository (upstream).
There are two ways to put a package in editable state:

    $ swift package edit Foo --branch bugFix

This will create a branch called `bugFix` from the currently resolved version and
put the dependency `Foo` in the `Packages/` directory.

    $ swift package edit Foo --revision 969c6a9

This is similar to the previous version, except that the Package Manager will leave
the dependency at a detached HEAD on the specified revision.

Note: If the branch or revision option is not provided, the Package Manager will
checkout the currently resolved version on a detached HEAD.

Once a package is in an editable state, you can navigate to the directory
`Packages/Foo` to make changes, build and then push the changes or open a pull
request to the upstream repository.

You can end editing a package using `unedit` command:

    $ swift package unedit Foo

This will remove the edited dependency from `Packages/` and put the originally
resolved version back.

This command fails if there are uncommitted changes or changes which are not
pushed to the remote repository. If you want to discard these changes and
unedit, you can use the `--force` option:

    $ swift package unedit Foo --force

### Top of Tree Development

This feature allows overriding a dependency with a local checkout on the
filesystem. This checkout is completely unmanaged by the package manager and
will be used as-is. The only requirement is that the package name in the
overridden checkout should not change. This is extremely useful when developing
multiple packages in tandem or when working on packages alongside an
application.

The command to attach (or create) a local checkout is:

    $ swift package edit <package name> --path <path/to/dependency>

For example, if `Foo` depends on `Bar` and you have a checkout of `Bar` at
`/workspace/bar`:

    foo$ swift package edit Bar --path /workspace/bar

A checkout of `Bar` will be created if it doesn't exist at the given path. If
a checkout exists, package manager will validate the package name at the given
path and attach to it.

The package manager will also create a symlink in the `Packages/` directory to the
checkout path.

Use unedit command to stop using the local checkout:

    $ swift package unedit <package name>
    # Example:
    $ swift package unedit Bar

## Resolving Versions (Package.resolved File)

The package manager records the result of dependency resolution in a
`Package.resolved` file in the top-level of the package, and when this file is
already present in the top-level, it is used when performing dependency
resolution, rather than the package manager finding the latest eligible version
of each package. Running `swift package update` updates all dependencies to the
latest eligible versions and updates the `Package.resolved` file accordingly.

Resolved versions will always be recorded by the package manager. Some users may
choose to add the Package.resolved file to their package's .gitignore file. When
this file is checked in, it allows a team to coordinate on what versions of the
dependencies they should use. If this file is gitignored, each user will
separately choose when to get new versions based on when they run the `swift
package update` command, and new users will start with the latest eligible
version of each dependency. Either way, for a package which is a dependency of
other packages (e.g., a library package), that package's `Package.resolved` file
will not have any effect on its client packages.

The `swift package resolve` command resolves the dependencies, taking into
account the current version restrictions in the `Package.swift` manifest and
`Package.resolved` resolved versions file, and issuing an error if the graph
cannot be resolved. For packages which have previously resolved versions
recorded in the `Package.resolved` file, the resolve command will resolve to
those versions as long as they are still eligible. If the resolved version's file
changes (e.g., because a teammate pushed a new version of the file) the next
resolve command will update packages to match that file. After a successful
resolve command, the checked out versions of all dependencies and the versions
recorded in the resolved versions file will match. In most cases the resolve
command will perform no changes unless the `Package.swift` manifest or
`Package.resolved` file have changed.

Most SwiftPM commands will implicitly invoke the `swift package resolve`
functionality before running, and will cancel with an error if dependencies
cannot be resolved.

## Setting the Swift Tools Version

The tools version declares the minimum version of the Swift tools required to
use the package, determines what version of the PackageDescription API should
be used in the `Package.swift` manifest, and determines which Swift language
compatibility version should be used to parse the `Package.swift` manifest.

When resolving package dependencies, if the version of a dependency that would
normally be chosen specifies a Swift tools version which is greater than the
version in use, that version of the dependency will be considered ineligible
and dependency resolution will continue with evaluating the next-best version.
If no version of a dependency (which otherwise meets the version requirements
from the package dependency graph) supports the version of the Swift tools in
use, a dependency resolution error will result.

### Swift Tools Version Specification

The Swift tools version is specified by a special comment in the first line of
the `Package.swift` manifest. To specify a tools version, a `Package.swift` file
must begin with the string `// swift-tools-version:`, followed by a version
number specifier.

The version number specifier follows the syntax defined by semantic versioning
2.0, with an amendment that the patch version component is optional and
considered to be 0 if not specified. The `semver` syntax allows for an optional
pre-release version component or build version component; those components will
be completely ignored by the package manager currently.
After the version number specifier, an optional `;` character may be present;
it, and anything else after it until the end of the first line, will be ignored
by this version of the package manager, but is reserved for the use of future
versions of the package manager.

Some Examples:

    // swift-tools-version:3.1
    // swift-tools-version:3.0.2
    // swift-tools-version:4.0

### Tools Version Commands

The following Swift tools version commands are supported:

* Report tools version of the package:

        $ swift package tools-version

* Set the package's tools version to the version of the tools currently in use:

        $ swift package tools-version --set-current

* Set the tools version to a given value:

        $ swift package tools-version --set <value>

## Testing

Use the `swift test` tool to run the tests of a Swift package. For more information on
the test tool, run `swift test --help`.

## Running

Use the `swift run [executable [arguments...]]` tool to run an executable product of a Swift
package. The executable's name is optional when running without arguments and when there
is only one executable product. For more information on the run tool, run
`swift run --help`.

## Setting the Build Configuration

SwiftPM allows two build configurations: Debug (default) and Release.

### Debug

By default, running `swift build` will build in its debug configuration.
Alternatively, you can also use `swift build -c debug`. The build artifacts are
located in a directory called `debug` under the build folder. A Swift target is built
with the following flags in debug mode:

* `-Onone`: Compile without any optimization.
* `-g`: Generate debug information.
* `-enable-testing`: Enable the Swift compiler's testability feature.

A C language target is built with the following flags in debug mode:

* `-O0`: Compile without any optimization.
* `-g`: Generate debug information.

### Release

To build in release mode, type `swift build -c release`. The build artifacts
are located in directory named `release` under the build folder. A Swift target is
built with following flags in release mode:

* `-O`: Compile with optimizations.
* `-whole-module-optimization`: Optimize input files (per module) together
  instead of individually.

A C language target is built with following flags in release mode:

* `-O2`: Compile with optimizations.

### Additional Flags

You can pass more flags to the C, C++, or Swift compilers in three different ways:

* Command-line flags passed to these tools: flags like `-Xcc` or `-Xswiftc` are used to
  pass C or Swift flags to all targets, as shown with `-Xlinker` above.
* Target-specific flags in the manifest: options like `cSettings` or `swiftSettings` are
  used for fine-grained control of compilation flags for particular targets.
* A destination JSON file: once you have a set of working command-line flags that you
  want applied to all targets, you can collect them in a JSON file and pass them in through
  `extra-cc-flags` and `extra-swiftc-flags` with `--destination example.json`. Take a
  look at `Utilities/build_ubuntu_cross_compilation_toolchain` for an example.

One difference is that C flags passed in the `-Xcc` command-line or manifest's `cSettings`
are supplied to the Swift compiler too for convenience, but `extra-cc-flags` aren't.

## Depending on Apple Modules

Swift Package Manager includes a build system that can build for macOS and Linux.
Xcode 11 integrates with `libSwiftPM` to provide support for iOS, watchOS, and tvOS platforms.
To build your package with Xcode from command line you can use
[`xcodebuild`](https://developer.apple.com/library/archive/technotes/tn2339/_index.html).
An example invocation would be:

```
xcodebuild -scheme Foo -destination 'generic/platform=iOS'
```

where `Foo` would be the name of the library product you're trying to build. You can
get the full list of available schemes for you SwiftPM package with `xcodebuild -list`.
You can get the list of available destinations for a given scheme with this invocation:

```
xcodebuild -showdestinations -scheme Foo
```


## Creating C Language Targets

C language targets are similar to Swift targets, except that the C language
libraries should contain a directory named `include` to hold the public headers.

To allow a Swift target to import a C language target, add a [target](PackageDescription.md#target) in the manifest file. Swift Package Manager will
automatically generate a modulemap for each C language library target for these
3 cases:

* If `include/Foo/Foo.h` exists and `Foo` is the only directory under the
  include directory, and the include directory contains no header files, then
  `include/Foo/Foo.h` becomes the umbrella header.

* If `include/Foo.h` exists and `include` contains no other subdirectory, then
  `include/Foo.h` becomes the umbrella header.

* Otherwise, the `include` directory becomes an umbrella directory, which means
  that all headers under it will be included in the module.

In case of complicated `include` layouts or headers that are not compatible with
modules, a custom `module.modulemap` can be provided in the `include` directory.

For executable targets, only one valid C language main file is allowed, e.g., it
is invalid to have `main.c` and `main.cpp` in the same target.

## Using Shell Completion Scripts

SwiftPM ships with completion scripts for both Bash and ZSH. These files should be generated in order to use them.

### Bash

Use the following commands to install the Bash completions to `~/.swift-package-complete.bash` and automatically load them using your `~/.bash_profile` file.

```bash
swift package completion-tool generate-bash-script > ~/.swift-package-complete.bash
echo -e "source ~/.swift-package-complete.bash\n" >> ~/.bash_profile
source ~/.swift-package-complete.bash
```

Alternatively, add the following commands to your `~/.bash_profile` file to directly load completions:

```bash
# Source Swift completion
if [ -n "`which swift`" ]; then
    eval "`swift package completion-tool generate-bash-script`"
fi
```

### ZSH

Use the following commands to install the ZSH completions to `~/.zsh/_swift`. You can chose a different folder, but the filename should be `_swift`. This will also add `~/.zsh` to your `$fpath` using your `~/.zshrc` file.

```bash
mkdir ~/.zsh
swift package completion-tool generate-zsh-script > ~/.zsh/_swift
echo -e "fpath=(~/.zsh \$fpath)\n" >> ~/.zshrc
compinit
```
