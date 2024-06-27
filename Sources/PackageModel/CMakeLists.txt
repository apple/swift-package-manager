# This source file is part of the Swift open source project
#
# Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(PackageModel
  ArtifactsArchiveMetadata.swift
  BuildConfiguration.swift
  BuildEnvironment.swift
  BuildFlags.swift
  BuildSettings.swift
  DependencyMapper.swift
  Diagnostics.swift
  IdentityResolver.swift
  InstalledLibrariesSupport/LibraryMetadata.swift
  InstalledSwiftPMConfiguration.swift
  Manifest/Manifest.swift
  Manifest/PackageConditionDescription.swift
  Manifest/PackageDependencyDescription.swift
  Manifest/PlatformDescription.swift
  Manifest/ProductDescription.swift
  Manifest/SystemPackageProviderDescription.swift
  Manifest/TargetBuildSettingDescription.swift
  Manifest/TargetDescription.swift
  Manifest/TraitDescription.swift
  ManifestSourceGeneration.swift
  MinimumDeploymentTarget.swift
  Module/BinaryModule.swift
  Module/ClangModule.swift
  Module/PluginModule.swift
  Module/ProvidedLibraryModule.swift
  Module/SwiftModule.swift
  Module/SystemLibraryModule.swift
  Module/Module.swift
  ModuleMapType.swift
  PackageModel.swift
  PackageIdentity.swift
  PackageReference.swift
  Platform.swift
  PlatformRegistry.swift
  Product.swift
  Registry.swift
  RegistryReleaseMetadata.swift
  Resource.swift
  Sanitizers.swift
  Snippets/Model/Snippet.swift
  Snippets/Model/SnippetGroup.swift
  Snippets/Parsing/PlainTextSnippetExtractor.swift
  Sources.swift
  SupportedLanguageExtension.swift
  SwiftLanguageVersion.swift
  SwiftSDKs/SwiftSDK.swift
  SwiftSDKs/SwiftSDKConfigurationStore.swift
  SwiftSDKs/SwiftSDKBundle.swift
  SwiftSDKs/SwiftSDKBundleStore.swift
  Toolchain.swift
  ToolchainConfiguration.swift
  Toolset.swift
  ToolsVersion.swift
  ToolsVersionSpecificationGeneration.swift
  UserToolchain.swift
  WindowsToolchainInfo.swift)
target_link_libraries(PackageModel PUBLIC
  TSCBasic
  TSCUtility
  Basics)
# NOTE(compnerd) workaround for CMake not setting up include flags yet
set_target_properties(PackageModel PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

install(TARGETS PackageModel
  ARCHIVE DESTINATION lib
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin)
set_property(GLOBAL APPEND PROPERTY SwiftPM_EXPORTS PackageModel)
