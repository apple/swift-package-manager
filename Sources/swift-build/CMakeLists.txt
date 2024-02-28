# This source file is part of the Swift open source project
#
# Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_executable(swift-build
    Entrypoint.swift)
target_link_libraries(swift-build PRIVATE
    Commands)
target_compile_options(swift-build PRIVATE
  -parse-as-library)

install(TARGETS swift-build
  DESTINATION bin)
