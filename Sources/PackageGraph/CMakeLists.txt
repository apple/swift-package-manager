# This source file is part of the Swift open source project
#
# Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(PackageGraph
  BoundVersion.swift
  BuildTriple.swift
  DependencyMirrors.swift
  Diagnostics.swift
  GraphLoadingNode.swift
  ModuleAliasTracker.swift
  ModulesGraph.swift
  ModulesGraph+Loading.swift
  PackageContainer.swift
  PackageGraphRoot.swift
  PackageModel+Extensions.swift
  PackageRequirement.swift
  PinsStore.swift
  TraitConfiguration.swift
  Resolution/PubGrub/Assignment.swift
  Resolution/PubGrub/ContainerProvider.swift
  Resolution/PubGrub/DiagnosticReportBuilder.swift
  Resolution/PubGrub/Incompatibility.swift
  Resolution/PubGrub/PartialSolution.swift
  Resolution/PubGrub/PubGrubDependencyResolver.swift
  Resolution/PubGrub/PubGrubPackageContainer.swift
  Resolution/PubGrub/Term.swift
  Resolution/DependencyResolutionNode.swift
  Resolution/DependencyResolverBinding.swift
  Resolution/DependencyResolverDelegate.swift
  Resolution/DependencyResolverError.swift
  Resolution/PlatformVersionProvider.swift
  Resolution/ResolvedPackage.swift
  Resolution/ResolvedProduct.swift
  Resolution/ResolvedModule.swift
  Version+Extensions.swift
  VersionSetSpecifier.swift)
target_link_libraries(PackageGraph PUBLIC
  TSCBasic
  Basics
  PackageLoading
  PackageModel
  TSCUtility)
target_link_libraries(PackageGraph PRIVATE
  SourceControl)
# NOTE(compnerd) workaround for CMake not setting up include flags yet
set_target_properties(PackageGraph PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

install(TARGETS PackageGraph
  ARCHIVE DESTINATION lib
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin)
set_property(GLOBAL APPEND PROPERTY SwiftPM_EXPORTS PackageGraph)
