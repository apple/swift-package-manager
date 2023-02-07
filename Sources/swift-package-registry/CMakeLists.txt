# This source file is part of the Swift open source project
#
# Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_executable(swift-package-registry
  main.swift)
target_link_libraries(swift-package-registry PRIVATE
  Commands
  PackageRegistryTool)

if(USE_CMAKE_INSTALL)
install(TARGETS swift-package-registry
  RUNTIME DESTINATION bin)
endif()
