# This source file is part of the Swift open source project
#
# Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(PackageDescription
  BuildSettings.swift
  Context.swift
  ContextModel.swift
  LanguageStandardSettings.swift
  PackageDescription.swift
  PackageDescriptionSerialization.swift
  PackageDescriptionSerializationConversion.swift
  PackageDependency.swift
  PackageDependencyTrait.swift
  PackageRequirement.swift
  Product.swift
  Resource.swift
  SupportedPlatforms.swift
  Target.swift
  Trait.swift
  Version.swift
  Version+StringLiteralConvertible.swift)

target_compile_options(PackageDescription PUBLIC
  $<$<COMPILE_LANGUAGE:Swift>:-package-description-version$<SEMICOLON>999.0>)

if(CMAKE_HOST_SYSTEM_NAME STREQUAL Darwin)
  target_link_options(PackageDescription PRIVATE
    "SHELL:-Xlinker -install_name -Xlinker @rpath/libPackageDescription.dylib")
endif()

set_target_properties(PackageDescription PROPERTIES
    Swift_MODULE_NAME PackageDescription
    Swift_MODULE_DIRECTORY ${CMAKE_BINARY_DIR}/pm/ManifestAPI
    INSTALL_NAME_DIR \\@rpath
    OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/pm/ManifestAPI
    OUTPUT_NAME PackageDescription
    ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/pm/ManifestAPI
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/pm/ManifestAPI
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/pm/ManifestAPI
)

if(NOT CMAKE_SYSTEM_NAME STREQUAL Darwin)
  target_link_libraries(PackageDescription PRIVATE
    Foundation)
  target_link_options(PackageDescription PRIVATE
    "SHELL:-no-toolchain-stdlib-rpath")
  set_target_properties(PackageDescription PROPERTIES
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "$ORIGIN/../../$<LOWER_CASE:${CMAKE_SYSTEM_NAME}>")
endif()

install(FILES
  ${CMAKE_BINARY_DIR}/pm/ManifestAPI/PackageDescription.swiftmodule
  ${CMAKE_BINARY_DIR}/pm/ManifestAPI/PackageDescription.swiftdoc
  DESTINATION lib/swift/pm/ManifestAPI
)

install(TARGETS PackageDescription
  DESTINATION lib/swift/pm/ManifestAPI)
