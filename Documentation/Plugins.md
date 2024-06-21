#  Getting Started with Plugins

This guide provides a brief overview of Swift Package Manager plugins, describes how a package can make use of plugins, and shows how to get started writing your own plugins.

## Overview

Some of Swift Package Manager's functionality can be extended through _plugins_.  Package plugins are written in Swift using the `PackagePlugin` API provided by the Swift Package Manager.  This is similar to how the Swift Package manifest itself is implemented as a Swift script that runs as needed in order to produce the information SwiftPM needs.

A plugin is represented in the SwiftPM package manifest as a target of the `pluginTarget` type — and if it should be available to other packages, there also needs to be a corresponding `pluginProduct` target.  Source code for a plugin is normally located in a directory under the `Plugins` directory in the package, but this can be customized.

SwiftPM currently defines two extension points for plugins:

- custom build tool tasks that provide commands to run before or during the build
- custom commands that are run using the `swift package` command line interface

A plugin declares which extension point it implements by defining the plugin's _capability_.  This determines the entry point through which SwiftPM will call it, and determines which actions the plugin can perform.

Plugins have access to a representation of the package model, and plugins that define custom commands can also invoke services provided by SwiftPM to build and test products and targets defined in the package to which the plugin is applied.

Every plugin runs as a separate process, and (on platforms that support sandboxing) it is wrapped in a sandbox that prevents network access as well as attempts to write to arbitrary locations in the file system.  Custom command plugins that need to modify the package source code can specify this requirement, and if the user approves, will have write access to the package directory.  Build tool plugins cannot modify the package source code.  All plugins can write to a temporary directory.

## Using a Package Plugin

A package plugin is available to the package that defines it, and if there is a corresponding plugin product, it is also available to any other package that has a direct dependency on the package that defines it.

To get access to a plugin defined in another package, add a package dependency on the package that defines the plugin.  This will let the package access any build tool plugins and command plugins from the dependency.

### Making use of a build tool plugin

Add the plugin to the `plugins:` parameter of each target to which it applies:

```swift
// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "my-plugin-example",
    dependencies: [
        .package(url: "https://github.com/example/my-plugin-package.git", from: "1.0"),
    ],
    targets: [
        .executableTarget(
            name: "MyExample",
            plugins: [
                .plugin(name: "MyBuildToolPlugin", package: "my-plugin-package"),
            ]
        )
    ]
)
```

This will cause SwiftPM to call the plugin, passing it a simplified version of the package model for the target to which it is being applied.  Any build commands returned by the plugin will be incorporated into the build graph and will run at the appropriate time during the build.

### Making use of a command plugin

Unlike build tool plugins, which are invoked as needed when SwiftPM constructs the build task graph, command plugins are only invoked directly by the user.  This is done through the `swift` `package` command line interface:

```shell
❯ swift package my-plugin --my-flag my-parameter
```

Any command line arguments that appear after the invocation verb defined by the plugin are passed unmodified to the plugin — in this case, `--my-flag` and `my-parameter`.  This is commonly used in order to narrow down the application of a command to one or more targets, through the convention of one or more occurrences of a `--target` option with the name of the target(s).

To list the plugins that are available within the context of a package, use the `--list` option of the `plugin` subcommand:

```shell
❯ swift package plugin --list
```

Command plugins that need to write to the file system will cause SwiftPM to ask the user for approval if `swift package` is invoked from a console, or deny the request if it is not.  Passing the `--allow-writing-to-package-directory` flag to the `swift package` invocation will allow the request without questions — this is particularly useful in a Continuous Integration environment. Similarly, the `--allow-network-connections` flag can be used to allow network connections without showing a prompt.

## Writing a Plugin

The first step when writing a package plugin is to decide what kind of plugin you need.  If your goal is to generate source files that should be part of a build, or to perform other actions at the start of every build, implement a build tool plugin.  If your goal is to provide actions that users can perform at any time and that are not associated with a build, implement a command plugin.

### Build tool plugins

Build tool plugins are invoked before a package is built in order to construct command invocations to run as part of the build.  There are two kinds of commands that a build tool plugin can return:

- prebuild commands — are run before the build starts and can generate an arbitrary number of output files with names that can't be predicted before running the command
- build commands — are incorporated into the build system's dependency graph and will run at the appropriate time during the build based on the existence and timestamps of their predefined inputs and outputs

Build commands are preferred over prebuild commands when the paths of all of the inputs and outputs are known before the command runs, since they allow the build system to more efficiently decide when they should be run.  This is actually quite common.  Examples include source translation tools that generate one output file (with a predictable name) for each input file, or other cases where the plugin can control the names of the outputs without having to first run the tool.  In this case the build system can run the command only when some of the outputs are missing or when the inputs have changed since the last time the command ran.  There doesn't have to be a one-to-one correspondence between inputs and outputs; a plugin is free to choose how many (if any) output files to create by examining the input target using any logic it wants to.

Prebuild commands should be used only when the names of the outputs are not known until the tool is run — this is the case if the _contents_ of the input files (as opposed to just their names) determines the number and names of the output files.  Prebuild commands have to run before every build, and should therefore do their own caching to do as little work as possible to avoid slowing down incremental builds.

In either case, it is important to note that it is not the plugin itself that does all the work of the build command — rather, the plugin constructs the commands that will later need to run, and it is those commands that perform the actual work.  The plugin itself is usually quite small and is mostly concerned with forming the command line for the build command that does the actual work.

#### Declaring a build tool plugin in the package manifest

Like all kinds of package plugins, build tool plugins are declared in the package manifest.  This is done using a `pluginTarget` entry in the `targets` section of the package.  If the plugin should be visible to other packages, there needs to be a corresponding `plugin` entry in the `products` section as well:

```swift
// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "MyPluginPackage",
    products: [
        .plugin(
            name: "MyBuildToolPlugin",
            targets: [
                "MyBuildToolPlugin"
            ]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/example/sometool",
            from: "0.1.0"
        )
    ],
    targets: [
        .plugin(
            name: "MyBuildToolPlugin",
            capability: .buildTool(),
            dependencies: [
                .product(name: "SomeTool", package: "sometool"),
            ]
        )
    ]
)
```

The `plugin` target declares the name and capability of the plugin, along with its dependencies.  The capability of `.buildTool()` is what declares it as a build tool plugin as opposed to any other kind of plugin — this also determines what entry point the plugin is expected to implement (as described below).

The Swift script files that implement the logic of the plugin are expected to be in a directory named the same as the plugin, located under the `Plugins` subdirectory of the package.  This can be overridden with a `path` parameter in the `pluginTarget`.

The `plugin` product is what makes the plugin visible to other packages that have dependencies on the package that defines the plugin.  The name of the plugin doesn't have to match the name of the product, but they are often the same in order to avoid confusion.  The plugin product should list only the name of the plugin target it vends.  If a built tool plugin is used only within the package that declares it, there is no need to declare a `plugin` product.

#### Build tool target dependencies

The dependencies specify the command line tools that will be available for use in commands constructed by the plugin.  Each dependency can be either an `executableTarget` or a `binaryTarget` target in the same package, or can be an `executable` product in another package (there are no binary products in SwiftPM).  In the example above, the plugin depends on the hypothetical _SomeTool_ product in the _sometool_ package on which the package that defines the plugin has a dependency.  Note that this does not necessarily mean that _SomeTool_ will have been built when the plugin is invoked — it only means that the plugin will be able to look up the path at which the tool will exist at the time any commands constructed by the plugin are run.

Executable dependencies are built for the host platform as part of the build, while binary dependencies are references to `artifactbundle` archives that contains prebuilt binaries (see [SE-305](https://github.com/apple/swift-evolution/blob/main/proposals/0305-swiftpm-binary-target-improvements.md)).  Binary targets are often used when the tool is built using a different build system than SwiftPM, or when building it on demand is prohibitively expensive or requires a special build environment.

#### Implementing the build tool plugin script

By default, Swift Package Manager looks for the implementation of a declared plugin in a subdirectory of the `Plugins` directory named with the same name as the plugin target.  This can be overridden using the `path` parameter in the target declaration.

A plugin consists of one or more Swift source files, and the main entry point of the build tool plugin script is expected to conform to the `BuildToolPlugin` protocol.

Similar to how a package manifest imports the *PackageDescription* module provided by SwiftPM, a package plugin imports the *PackagePlugin* module which contains the API through which the plugin receives information from SwiftPM and communicates results back to it.

```swift
import PackagePlugin

@main
struct MyPlugin: BuildToolPlugin {
    
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target.sourceModule else { return [] }
        let inputFiles = target.sourceFiles.filter({ $0.path.extension == "dat" })
        return try inputFiles.map {
            let inputFile = $0
            let inputPath = inputFile.path
            let outputName = inputPath.stem + ".swift"
            let outputPath = context.pluginWorkDirectory.appending(outputName)
            return .buildCommand(
                displayName: "Generating \(outputName) from \(inputPath.lastComponent)",
                executable: try context.tool(named: "SomeTool").path,
                arguments: [ "--verbose", "\(inputPath)", "\(outputPath)" ],
                inputFiles: [ inputPath, ],
                outputFiles: [ outputPath ]
            )
        }
    }
}
```

The plugin script can import *Foundation* and other standard libraries, but in the current version of SwiftPM, it cannot import other libraries.

##### Build Commands

In this example, the returned command is of the type `buildCommand`, so it will be incorporated into the build system's command graph and will run if any of the output files are missing or if the contents of any of the input files have changed since the last time the command ran.

The target to which the plugin applies is passed as the `target` parameter.  Only source module targets have source files, so a plugin that iterates over source files will commonly test that the target it was given conforms to `SourceModuleTarget`.

##### Prebuild Commands

A build tool plugin can return a combination of build commands and prebuild commands.  A `prebuildCommand` runs after the build tool plugin but before the build starts.  This one populates a `GeneratedFiles/` directory:

```swift
import PackagePlugin
import Foundation

@main
struct MyBuildToolPlugin: BuildToolPlugin {
    
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        // This example configures `sometool` to write to a "GeneratedFiles" directory in
        // the plugin work directory (which is unique for each plugin and target).
        let outputDir = context.pluginWorkDirectory.appending("GeneratedFiles")
        try FileManager.default.createDirectory(atPath: outputDir.string,
            withIntermediateDirectories: true)

        // Return a command to run `sometool` as a prebuild command. It will be run before
        // every build and generates source files into an output directory provided by the
        // build context.
        return [.prebuildCommand(
            displayName: "Running SomeTool",
            executable: try context.tool(named: "SomeTool").path,
            arguments: [ "--verbose", "--outdir", outputDir ],
            outputFilesDirectory: outputDir)
        ]
    }
}
```

A prebuild command has no inputs, so it will never be re-run due to changes in source files. The only trigger for re-running a prebuild command is a change to declared dependencies, which can only be (prebuilt) binary targets, since these commands run before any other targets have been built.

Any `.swift` files that are outputs of build commands or prebuild commands will be treated as Swift source files and compiled into the target being built by the plugin. Currently, compilation of output files in other source langauges isn't supported, so any other output files are treated as resources and processed as if they had been declared in the manifest with the `.process()` rule.  The intent is to eventually support any type of file that could have been included as a source file in the target, and to let the plugin provide greater controls over the downstream processing of generated files.

### Command plugins

Command plugins are invoked at will by the user, by invoking `swift` `package` `<command>` `<arguments>`.  They are unrelated to the build graph, and often perform their work by invoking to command line tools as subprocesses.

Command plugins are declared in a similar way to build tool plugins, except that they declare a `.command()` capability and implement a different entry point in the plugin script.

A command plugin specifies the semantic intent of the command — this might be one of the predefined intents such “documentation generation” or “source code formatting”, or it might be a custom intent with a specialized verb that can be passed to the `swift` `package` command.  A command plugin can also specify any special permissions it needs, such as the permission to modify the files under the package directory.

The command's intent declaration provides a way of grouping command plugins by their functional categories, so that SwiftPM — or an IDE that supports SwiftPM packages — can show the commands that are available for a particular purpose. For example, this approach supports having different command plugins for generating documentation for a package, while still allowing those different commands to be grouped and discovered by intent.

#### Declaring a command plugin in the package manifest

The manifest of a package that declares a command plugin might look like:

```swift
// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "MyPluginPackage",
    products: [
        .plugin(
            name: "MyCommandPlugin",
            targets: [
                "MyCommandPlugin"
            ]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/example/sometool",
            from: "0.1.0"
        )
    ],
    targets: [
        .plugin(
            name: "MyCommandPlugin",
            capability: .command(
                intent: .sourceCodeFormatting(),
                permissions: [
                    .writeToPackageDirectory(reason: "This command reformats source files")
                ]
            ),
            dependencies: [
                .product(name: "SomeTool", package: "sometool"),
            ]
        )
    ]
)
```

Here the plugin declares that its purpose is source code formatting, and specifically declares that it will need permission to modify files in the package directory.  Plugins are run in a sandbox that prevents network access and most file system access, but declarations about the need to write to the package add those permissions to the sandbox (after asking the user to approve).

#### Implementing the command plugin script

As with build tool plugins, the scripts that implement command plugins should be located under the `Plugins` subdirectory in the package.

For a command plugin the entry point of the plugin script is expected to conform to the `CommandPlugin` protocol:

```swift
import PackagePlugin
import Foundation

@main
struct MyCommandPlugin: CommandPlugin {

    func performCommand(
        context: PluginContext,
        arguments: [String]
    ) throws {
        // We'll be invoking `sometool` to format code, so start by locating it.
        let sometool = try context.tool(named: "sometool")

        // By convention, use a configuration file in the root directory of the
        // package. This allows package owners to commit their format settings
        // to their repository.
        let configFile = context.package.directory.appending(".sometoolconfig")

        // Extract the target arguments (if there are none, we assume all).
        var argExtractor = ArgumentExtractor(arguments)
        let targetNames = argExtractor.extractOption(named: "target")
        let targets = targetNames.isEmpty
            ? context.package.targets
            : try context.package.targets(named: targetNames)

        // Iterate over the targets we've been asked to format.
        for target in targets {
            // Skip any type of target that doesn't have source files.
            // Note: We could choose to instead emit a warning or error here.
            guard let target = target.sourceModule else { continue }

            // Invoke `sometool` on the target directory, passing a configuration
            // file from the package directory.
            let sometoolExec = URL(fileURLWithPath: sometool.path.string)
            let sometoolArgs = [
                "--config", "\(configFile)",
                "--cache", "\(context.pluginWorkDirectory.appending("cache-dir"))",
                "\(target.directory)"
            ]
            let process = try Process.run(sometoolExec, arguments: sometoolArgs)
            process.waitUntilExit()

            // Check whether the subprocess invocation was successful.
            if process.terminationReason == .exit && process.terminationStatus == 0 {
                print("Formatted the source code in \(target.directory).")
            }
            else {
                let problem = "\(process.terminationReason):\(process.terminationStatus)"
                Diagnostics.error("Formatting invocation failed: \(problem)")
            }
        }
    }
}
```

Unlike build tool plugins, which are always applied to a single package target, a command plugin does not necessarily operate on just a single target.  The `context` parameter provides access to the inputs, including to a distilled version of the package graph rooted at the package to which the command plugin is applied.

Command plugins can also accept arguments, which can control options for the plugin's actions or can further narrow down what the plugin operates on.  This example supports the convention of passing `--target` to limit the scope of the plugin to a set of targets in the package.

In the current version of Swift Package Manager, plugins can only use standard system libraries (and not those from other packages, such as SwiftArgumentParser).  Consequently, this plugin uses the built-in `ArgumentExtractor` helper in the *PackagePlugin* module to do simple argument extraction.

### Diagnostics

Plugin entry points are marked `throws`, and any errors thrown from the entry point cause the plugin invocation to be marked as having failed.  The thrown error is presented to the user, and should include a clear description of what went wrong.

Additionally, plugins can use the `Diagnostics` API in PackagePlugin to emit warnings and errors that optionally include references to file paths and line numbers in those files.

### Debugging and Testing

SwiftPM doesn't currently have any specific support for debugging and testing plugins.  Many plugins act only as adapters that construct command lines for invoking the tools that do the real work — in the cases in which there is non-trivial code in a plugin, the best current approach is to factor out that code into separate source files that can be included in unit tests in the plugin package via symbolic links with relative paths.

### Xcode Extensions to the PackagePlugin API

When invoked in Apple’s Xcode IDE, plugins have access to a library module provided by Xcode called *XcodeProjectPlugin* — this module extends the *PackagePlugin* APIs to let plugins work on Xcode targets in addition to packages.

In order to write a plugin that works with packages in every environment and that conditionally works with Xcode projects when run in Xcode, the plugin should conditionally import the *XcodeProjectPlugin* module when it is available.  For example:

```swift
import PackagePlugin

@main
struct MyCommandPlugin: CommandPlugin {
    /// This entry point is called when operating on a Swift package.
    func performCommand(context: PluginContext, arguments: [String]) throws {
        debugPrint(context)
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension MyCommandPlugin: XcodeCommandPlugin {
    /// This entry point is called when operating on an Xcode project.
    func performCommand(context: XcodePluginContext, arguments: [String]) throws {
        debugPrint(context)
    }
}
#endif
```

The `XcodePluginContext` input structure is similar to the regular `PluginContext` structure, except that it provides access to an Xcode project that uses Xcode naming and semantics for the project model (which is somewhat different from that of SwiftPM).  Some of the underlying types, such as `FileList`, `Path`, etc are the same for `PackagePlugin` and `XcodeProjectPlugin` types.

If any targets are chosen in the Xcode user interface, Xcode passes their names as `--target` arguments to the plugin.

It is expected that other IDEs or custom environments that use SwiftPM could similarly provide modules that define new entry points and extend the functionality of the core `PackagePlugin` APIs.

### References

- "Meet Swift Package plugins" [WWDC22 session](https://developer.apple.com/videos/play/wwdc2022-110359)
- "Create Swift Package plugins" [WWDC22 session](https://developer.apple.com/videos/play/wwdc2022-110401)
