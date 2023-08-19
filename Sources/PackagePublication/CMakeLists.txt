# This source file is part of the Swift open source project
#
# Copyright (c) 2023 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(PackagePublication STATIC
  ManifestSigner.swift
  PackageArchiver.swift
  PackagePublication.swift
  PackageSigner.swift)
target_link_libraries(PackagePublication PUBLIC
  $<$<NOT:$<PLATFORM_ID:Darwin>>:Foundation>
  Basics
  PackageModel
  PackageSigning
  SourceControl
  TSCBasic
  TSCUtility)
# NOTE(compnerd) workaround for CMake not setting up include flags yet
set_target_properties(PackagePublication PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})
