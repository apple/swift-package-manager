# This source file is part of the Swift open source project
#
# Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(XCBuildSupport STATIC
  PIF.swift
  PIFBuilder.swift
  XCBuildDelegate.swift
  XCBuildMessage.swift
  XCBuildOutputParser.swift
  XcodeBuildSystem.swift)
target_link_libraries(XCBuildSupport PUBLIC
  Build
  TSCBasic
  TSCUtility
  PackageGraph
)

set_target_properties(XCBuildSupport PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})
set_property(GLOBAL APPEND PROPERTY SwiftPM_EXPORTS XCBuildSupport)
