# This source file is part of the Swift open source project
#
# Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(Workspace
  CheckoutState.swift
  DefaultPluginScriptRunner.swift
  Diagnostics.swift
  FileSystemPackageContainer.swift
  InitPackage.swift
  ManagedArtifact.swift
  ManagedDependency.swift
  RegistryPackageContainer.swift
  ResolvedFileWatcher.swift
  ResolverPrecomputationProvider.swift
  SourceControlPackageContainer.swift
  ToolsVersionSpecificationRewriter.swift
  Workspace.swift
  Workspace+BinaryArtifacts.swift
  Workspace+Configuration.swift
  Workspace+State.swift)
target_link_libraries(Workspace PUBLIC
  TSCBasic
  TSCUtility
  Basics
  SPMBuildCore
  PackageFingerprint
  PackageGraph
  PackageLoading
  PackageModel
  PackageRegistry
  SourceControl)
target_link_libraries(PackageLoading PUBLIC
  $<$<NOT:$<PLATFORM_ID:Darwin>>:Foundation>)
# NOTE(compnerd) workaround for CMake not setting up include flags yet
set_target_properties(Workspace PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

if(USE_CMAKE_INSTALL)
install(TARGETS Workspace
  ARCHIVE DESTINATION lib
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin)
endif()
set_property(GLOBAL APPEND PROPERTY SwiftPM_EXPORTS Workspace)
