# This source file is part of the Swift open source project
#
# Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(SPMBuildCore
  BinaryTarget+Extensions.swift
  BuildParameters/BuildParameters.swift
  BuildParameters/BuildParameters+Debugging.swift
  BuildParameters/BuildParameters+Driver.swift
  BuildParameters/BuildParameters+Linking.swift
  BuildParameters/BuildParameters+Output.swift
  BuildParameters/BuildParameters+Testing.swift
  BuildSystem/AsyncBuildSystem.swift
  BuildSystem/BuildSystem.swift
  BuildSystem/BuildSystemCommand.swift
  BuildSystem/BuildSystemDelegate.swift
  BuildSystem/BuildSystemEvent.swift
  BuiltTestProduct.swift
  Plugins/PluginContextSerializer.swift
  Plugins/PluginInvocation.swift
  Plugins/PluginMessages.swift
  Plugins/PluginScriptRunner.swift
  PrebuildCommandResult.swift
  ResolvedPackage+Extensions.swift
  Triple+Extensions.swift
  XCFrameworkMetadata.swift)
# NOTE(compnerd) workaround for CMake not setting up include flags yet
set_target_properties(SPMBuildCore PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})
target_link_libraries(SPMBuildCore PUBLIC
  TSCBasic
  TSCUtility
  Basics
  PackageGraph)


install(TARGETS SPMBuildCore
  ARCHIVE DESTINATION lib
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin)
set_property(GLOBAL APPEND PROPERTY SwiftPM_EXPORTS SPMBuildCore)
