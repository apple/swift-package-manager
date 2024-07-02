# This source file is part of the Swift open source project
#
# Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(Commands
  PackageCommands/AddDependency.swift
  PackageCommands/AddProduct.swift 
  PackageCommands/AddTarget.swift
  PackageCommands/AddTargetDependency.swift
  PackageCommands/APIDiff.swift
  PackageCommands/ArchiveSource.swift
  PackageCommands/CompletionCommand.swift
  PackageCommands/ComputeChecksum.swift
  PackageCommands/Config.swift
  PackageCommands/Describe.swift
  PackageCommands/DumpCommands.swift
  PackageCommands/EditCommands.swift
  PackageCommands/Format.swift
  PackageCommands/Init.swift
  PackageCommands/Install.swift
  PackageCommands/Learn.swift
  PackageCommands/PluginCommand.swift
  PackageCommands/ResetCommands.swift
  PackageCommands/Resolve.swift
  PackageCommands/ShowDependencies.swift
  PackageCommands/SwiftPackageCommand.swift
  PackageCommands/ToolsVersionCommand.swift
  PackageCommands/Update.swift
  Snippets/CardEvent.swift
  Snippets/Cards/SnippetCard.swift
  Snippets/Cards/SnippetGroupCard.swift
  Snippets/Cards/TopCard.swift
  Snippets/CardStack.swift
  Snippets/Card.swift
  Snippets/Colorful.swift
  SwiftBuildCommand.swift
  SwiftRunCommand.swift
  SwiftTestCommand.swift
  CommandWorkspaceDelegate.swift
  Utilities/APIDigester.swift
  Utilities/DependenciesSerializer.swift
  Utilities/DescribedPackage.swift
  Utilities/DOTManifestSerializer.swift
  Utilities/MermaidPackageSerializer.swift
  Utilities/MultiRootSupport.swift
  Utilities/PlainTextEncoder.swift
  Utilities/PluginDelegate.swift
  Utilities/SymbolGraphExtract.swift
  Utilities/TestingSupport.swift
  Utilities/XCTEvents.swift)
target_link_libraries(Commands PUBLIC
  SwiftCollections::OrderedCollections
  ArgumentParser
  Basics
  Build
  CoreCommands
  LLBuildManifest
  PackageGraph
  PackageModelSyntax
  SourceControl
  TSCBasic
  TSCUtility
  Workspace
  XCBuildSupport)
target_link_libraries(Commands PRIVATE
  DriverSupport
  $<$<NOT:$<PLATFORM_ID:Darwin>>:FoundationXML>)
# NOTE(compnerd) workaround for CMake not setting up include flags yet
set_target_properties(Commands PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

install(TARGETS Commands
  ARCHIVE DESTINATION lib
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin)
