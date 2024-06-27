# This source file is part of the Swift open source project
#
# Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(Build
  BuildDescription/ClangModuleBuildDescription.swift
  BuildDescription/PluginBuildDescription.swift
  BuildDescription/ProductBuildDescription.swift
  BuildDescription/ResolvedModule+BuildDescription.swift
  BuildDescription/SwiftModuleBuildDescription.swift
  BuildDescription/ModuleBuildDescription.swift
  BuildManifest/LLBuildManifestBuilder.swift
  BuildManifest/LLBuildManifestBuilder+Clang.swift
  BuildManifest/LLBuildManifestBuilder+Product.swift
  BuildManifest/LLBuildManifestBuilder+Resources.swift
  BuildManifest/LLBuildManifestBuilder+Swift.swift
  BuildOperation.swift
  BuildPlan/BuildPlan.swift
  BuildPlan/BuildPlan+Clang.swift
  BuildPlan/BuildPlan+Product.swift
  BuildPlan/BuildPlan+Swift.swift
  BuildPlan/BuildPlan+Test.swift
  ClangSupport.swift
  LLBuildCommands.swift
  LLBuildDescription.swift
  LLBuildProgressTracker.swift
  SwiftCompilerOutputParser.swift
  TestObservation.swift)
target_link_libraries(Build PUBLIC
  TSCBasic
  Basics
  PackageGraph
  SPMBuildCore)
target_link_libraries(Build PRIVATE
  DriverSupport
  LLBuildManifest
  SPMLLBuild
  SwiftDriver)
target_link_libraries(Build INTERFACE
  llbuildSwift)

# NOTE(compnerd) workaround for CMake not setting up include flags yet
set_target_properties(Build PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

install(TARGETS Build
  ARCHIVE DESTINATION lib
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin)
set_property(GLOBAL APPEND PROPERTY SwiftPM_EXPORTS Build)
