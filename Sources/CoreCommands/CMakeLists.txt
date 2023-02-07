# This source file is part of the Swift open source project
#
# Copyright (c) 2022 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(CoreCommands
  BuildSystemSupport.swift
  SwiftTool.swift
  SwiftToolObservabilityHandler.swift
  Options.swift)
target_link_libraries(CoreCommands PUBLIC
  ArgumentParser
  Basics
  Build
  PackageGraph
  TSCBasic
  TSCUtility
  Workspace
  XCBuildSupport)
target_link_libraries(CoreCommands PRIVATE
  DriverSupport
  $<$<NOT:$<PLATFORM_ID:Darwin>>:FoundationXML>)
# NOTE(compnerd) workaround for CMake not setting up include flags yet
set_target_properties(CoreCommands PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

if(USE_CMAKE_INSTALL)
install(TARGETS CoreCommands
  ARCHIVE DESTINATION lib
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin)
endif()
set_property(GLOBAL APPEND PROPERTY SwiftPM_EXPORTS CoreCommands)
