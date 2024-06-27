# This source file is part of the Swift open source project
#
# Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(Basics
  Archiver/Archiver.swift
  Archiver/TarArchiver.swift
  Archiver/ZipArchiver.swift
  Archiver/UniversalArchiver.swift
  AsyncProcess.swift
  AuthorizationProvider.swift
  Cancellator.swift
  Collections/ByteString+Extensions.swift
  Collections/Dictionary+Extensions.swift
  Collections/IdentifiableSet.swift
  Collections/String+Extensions.swift
  Concurrency/ConcurrencyHelpers.swift
  Concurrency/NSLock+Extensions.swift
  Concurrency/SendableBox.swift
  Concurrency/ThreadSafeArrayStore.swift
  Concurrency/ThreadSafeBox.swift
  Concurrency/ThreadSafeKeyValueStore.swift
  Concurrency/TokenBucket.swift
  DispatchTimeInterval+Extensions.swift
  Environment/Environment.swift
  Environment/EnvironmentKey.swift
  Environment/EnvironmentShims.swift
  Errors.swift
  FileSystem/AbsolutePath.swift
  FileSystem/FileSystem+Extensions.swift
  FileSystem/InMemoryFileSystem.swift
  FileSystem/NativePathExtensions.swift
  FileSystem/RelativePath.swift
  FileSystem/TemporaryFile.swift
  FileSystem/TSCAdapters.swift
  FileSystem/VFSOverlay.swift
  Graph/AdjacencyMatrix.swift
  Graph/DirectedGraph.swift
  Graph/GraphAlgorithms.swift
  Graph/UndirectedGraph.swift
  SourceControlURL.swift
  HTTPClient/HTTPClient.swift
  HTTPClient/HTTPClientConfiguration.swift
  HTTPClient/HTTPClientError.swift
  HTTPClient/HTTPClientHeaders.swift
  HTTPClient/HTTPClientRequest.swift
  HTTPClient/HTTPClientResponse.swift
  HTTPClient/HTTPMethod.swift
  HTTPClient/LegacyHTTPClient.swift
  HTTPClient/LegacyHTTPClientRequest.swift
  HTTPClient/URLSessionHTTPClient.swift
  ImportScanning.swift
  JSON+Extensions.swift
  JSONDecoder+Extensions.swift
  Netrc.swift
  Observability.swift
  OSSignpost.swift
  ProgressAnimation/NinjaProgressAnimation.swift
  ProgressAnimation/PercentProgressAnimation.swift
  ProgressAnimation/ProgressAnimationProtocol.swift
  ProgressAnimation/SingleLinePercentProgressAnimation.swift
  ProgressAnimation/ThrottledProgressAnimation.swift
  SQLite.swift
  Sandbox.swift
  SendableTimeInterval.swift
  Serialization/SerializedJSON.swift
  SwiftVersion.swift
  SQLiteBackedCache.swift
  Triple+Basics.swift
  Version+Extensions.swift
  WritableByteStream+Extensions.swift
  Vendor/Triple.swift
  Vendor/Triple+Platforms.swift)
target_link_libraries(Basics PUBLIC
  SwiftCollections::DequeModule
  SwiftCollections::OrderedCollections
  SwiftSystem::SystemPackage
  TSCBasic
  TSCUtility)
target_link_libraries(Basics PRIVATE
  SPMSQLite3
  TSCclibc)

# NOTE(compnerd) workaround for CMake not setting up include flags yet
set_target_properties(Basics PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})
target_link_options(Basics PRIVATE
    "$<$<PLATFORM_ID:Darwin>:SHELL:-Xlinker -framework -Xlinker Security>")

install(TARGETS Basics
  ARCHIVE DESTINATION lib
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin)
set_property(GLOBAL APPEND PROPERTY SwiftPM_EXPORTS Basics)
