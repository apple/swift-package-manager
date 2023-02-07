# This source file is part of the Swift open source project
#
# Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(PackageCollections
  API.swift
  Model/Collection.swift
  Model/CVE.swift
  Model/License.swift
  Model/PackageList.swift
  Model/PackageTypes.swift
  Model/Search.swift
  Model/TargetListResult.swift
  PackageCollections+CertificatePolicy.swift
  PackageCollections+Configuration.swift
  PackageCollections+Storage.swift
  PackageCollections+Validation.swift
  PackageCollections.swift
  PackageIndex+Configuration.swift
  PackageIndex.swift
  PackageIndexAndCollections.swift
  Providers/GitHubPackageMetadataProvider.swift
  Providers/JSONPackageCollectionProvider.swift
  Providers/PackageCollectionProvider.swift
  Providers/PackageMetadataProvider.swift
  Storage/FilepackageCollectionsSourcesStorage.swift
  Storage/PackageCollectionsSourcesStorage.swift
  Storage/PackageCollectionsStorage.swift
  Storage/SQLitePackageCollectionsStorage.swift
  Storage/Trie.swift
  Utility.swift)
# NOTE(compnerd) workaround for CMake not setting up include flags yet
set_target_properties(PackageCollections PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})
target_link_libraries(PackageCollections PUBLIC
  $<$<NOT:$<PLATFORM_ID:Darwin>>:dispatch>
  $<$<NOT:$<PLATFORM_ID:Darwin>>:Foundation>
  Basics
  PackageModel
  SourceControl
  TSCBasic)
target_link_libraries(PackageCollections PRIVATE
  PackageCollectionsModel
  PackageCollectionsSigning)
target_link_libraries(PackageCollections PUBLIC
  Crypto
  CCryptoBoringSSL)

if(USE_CMAKE_INSTALL)
  install(TARGETS PackageCollections
          ARCHIVE DESTINATION lib
          LIBRARY DESTINATION lib
          RUNTIME DESTINATION bin)
endif()
set_property(GLOBAL APPEND PROPERTY SwiftPM_EXPORTS PackageCollections)
