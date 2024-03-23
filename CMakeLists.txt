# This source file is part of the Swift open source project
#
# Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

cmake_minimum_required(VERSION 3.19)

if(POLICY CMP0077)
  cmake_policy(SET CMP0077 NEW)
endif()

if(POLICY CMP0091)
  cmake_policy(SET CMP0091 NEW)
endif()

project(SwiftPM LANGUAGES C Swift)

option(BUILD_SHARED_LIBS "Build shared libraries by default" YES)

set(CMAKE_Swift_LANGUAGE_VERSION 5)
set(CMAKE_Swift_MODULE_DIRECTORY ${CMAKE_BINARY_DIR}/swift)
set(CMAKE_Swift_COMPILE_OPTIONS_MSVC_RUNTIME_LIBRARY MultiThreadedDLL)

set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake/modules)
set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreadedDLL)
set(CMAKE_POSITION_INDEPENDENT_CODE ${BUILD_SHARED_LIBS})

# Toolchain Vended dependencies
find_package(dispatch QUIET)
find_package(Foundation QUIET)

include(FetchContent)

set(_SPM_SAVED_BUILD_TESTING ${BUILD_TESTING})
set(_SPM_SAVED_BUILD_EXAMPLES ${BUILD_EXAMPLES})
set(_SPM_VENDOR_DEPENDENCIES)

set(BUILD_EXAMPLES NO)
set(BUILD_TESTING NO)

find_package(ArgumentParser CONFIG)
if(NOT ArgumentParser_FOUND)
  message(STATUS "Vending swift-argument-parser")
  FetchContent_Declare(ArgumentParser
    GIT_REPOSITORY https://github.com/apple/swift-argument-parser
    GIT_TAG 1.2.3)
  list(APPEND _SPM_VENDOR_DEPENDENCIES ArgumentParser)
endif()

find_package(TSC CONFIG)
if(NOT TSC_FOUND)
  message(STATUS "Vending swift-tools-support-core")
  FetchContent_Declare(ToolsSupportCore
    GIT_REPOSITORY https://github.com/apple/swift-tools-support-core
    GIT_TAG main)
  list(APPEND _SPM_VENDOR_DEPENDENCIES ToolsSupportCore)
endif()

find_package(LLBuild CONFIG)
if(NOT LLBuild_FOUND)
  if(APPLE)
    find_package(LLBuild REQUIRED)
  else()
    message(STATUS "Vending swift-llbuild")
    set(LLBUILD_SUPPORT_BINDINGS Swift)
    FetchContent_Declare(LLBuild
      GIT_REPOSITORY https://github.com/apple/swift-llbuild
      GIT_TAG main)
    list(APPEND _SPM_VENDOR_DEPENDENCIES LLBuild)
  endif()
endif()

find_package(SwiftASN1 CONFIG)
if(NOT SwiftASN1_FOUND)
  message(STATUS "Vending swift-asn1")
  FetchContent_Declare(ASN1
    GIT_REPOSITORY https://github.com/apple/swift-asn1
    GIT_TAG 1.1.0)
  list(APPEND _SPM_VENDOR_DEPENDENCIES ASN1)
endif()

find_package(SwiftCertificates CONFIG)
if(NOT SwiftCertificates_FOUND)
  message(STATUS "Vending swift-certificates")
  FetchContent_Declare(Certificates
    GIT_REPOSITORY https://github.com/apple/swift-certificates
    GIT_TAG main)
  list(APPEND _SPM_VENDOR_DEPENDENCIES Certificates)
endif()

find_package(SwiftCollections CONFIG)
if(NOT SwiftCollections_FOUND)
  message(STATUS "Vending swift-collections")
  FetchContent_Declare(Collections
    GIT_REPOSITORY https://github.com/apple/swift-collections
    GIT_TAG release/1.0)
  list(APPEND _SPM_VENDOR_DEPENDENCIES Collections)
endif()

find_package(SwiftCrypto CONFIG)
if(NOT SwiftCrypto_FOUND)
  message(STATUS "Vending swift-crypto")
  FetchContent_Declare(Crypto
    GIT_REPOSITORY https://github.com/apple/swift-crypto
    GIT_TAG 3.0.0)
  list(APPEND _SPM_VENDOR_DEPENDENCIES Crypto)
endif()

find_package(SwiftDriver CONFIG)
if(NOT SwiftDriver_FOUND)
  message(STATUS "Vending swift-driver")
  FetchContent_Declare(Driver
    GIT_REPOSITORY https://github.com/apple/swift-driver
    GIT_TAG main)
  list(APPEND _SPM_VENDOR_DEPENDENCIES Driver)
endif()

find_package(SwiftSystem CONFIG)
if(NOT SwiftSystem_FOUND)
  message(STATUS "Vending swift-system")
  FetchContent_Declare(System
    GIT_REPOSITORY https://github.com/apple/swift-system
    GIT_TAG 1.1.1)
  list(APPEND _SPM_VENDOR_DEPENDENCIES System)
endif()

if(_SPM_VENDOR_DEPENDENCIES)
  FetchContent_MakeAvailable(${_SPM_VENDOR_DEPENDENCIES})

  if(NOT TARGET SwiftCollections::DequeModule)
    add_library(SwiftCollections::DequeModule ALIAS DequeModule)
  endif()
  if(NOT TARGET SwiftCollections::OrderedCollections)
    add_library(SwiftCollections::OrderedCollections ALIAS OrderedCollections)
  endif()

  if(NOT TARGET SwiftSystem::SystemPackage)
    add_library(SwiftSystem::SystemPackage ALIAS SystemPackage)
  endif()
endif()

find_package(SQLite3 REQUIRED)

# Enable `package` modifier for the whole package.
add_compile_options("$<$<COMPILE_LANGUAGE:Swift>:-package-name;SwiftPM>")

set(BUILD_TESTING ${_SPM_SAVED_BUILD_TESTING})
set(BUILD_EXAMPLES ${_SPM_SAVED_BUILD_EXAMPLES})

add_subdirectory(Sources)
add_subdirectory(cmake/modules)
