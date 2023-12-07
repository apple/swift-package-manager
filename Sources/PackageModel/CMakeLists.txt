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
  InstalledSwiftPMConfiguration.swift
  Manifest/Manifest.swift
  Manifest/PackageConditionDescription.swift
  Manifest/PackageDependencyDescription.swift
  Manifest/PlatformDescription.swift
  Manifest/ProductDescription.swift
  Manifest/SystemPackageProviderDescription.swift
  Manifest/TargetBuildSettingDescription.swift
  Manifest/TargetDescription.swift
  ManifestSourceGeneration.swift
  MinimumDeploymentTarget.swift
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
  Target/BinaryTarget.swift
  Target/ClangTarget.swift
  Target/MixedTarget.swift
  Target/PluginTarget.swift
  Target/SwiftTarget.swift
  Target/SystemLibraryTarget.swift
  Target/Target.swift
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

if(USE_CMAKE_INSTALL)
install(TARGETS PackageModel
  ARCHIVE DESTINATION lib
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin)
endif()
set_property(GLOBAL APPEND PROPERTY SwiftPM_EXPORTS PackageModel)
