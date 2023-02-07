# This source file is part of the Swift open source project
#
# Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(PackageCollectionsSigning STATIC
  Certificate/Certificate.swift
  Certificate/CertificatePolicy.swift
  Key/ASN1/ASN1.swift
  Key/ASN1/ASN1Error.swift
  Key/ASN1/PEMDocument.swift
  Key/ASN1/SEC1PrivateKey.swift
  Key/ASN1/SubjectPublickeyInfo.swift
  Key/ASN1/Types/ASN1BitString.swift
  Key/ASN1/Types/ASN1Identifier.swift
  Key/ASN1/Types/ASN1Integer.swift
  Key/ASN1/Types/ASN1ObjectIdentifier.swift
  Key/ASN1/Types/ASN1OctetString.swift
  Key/BoringSSLKey.swift
  Key/Key+EC.swift
  Key/Key+RSA.swift
  Key/Key.swift
  PackageCollectionSigning.swift
  Signing/BoringSSLSigning.swift
  Signing/Signature.swift
  Signing/Signing+ECKey.swift
  Signing/Signing+RSAKey.swift
  Signing/Signing.swift
  Utilities/Base64URL.swift
  Utilities/Utilities.swift)
# NOTE(compnerd) workaround for CMake not setting up include flags yet
set_target_properties(PackageCollectionsSigning PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_Swift_MODULE_DIRECTORY};${PROJECT_SOURCE_DIR}/Sources/PackageCollectionsSigningLibc/include")
target_link_libraries(PackageCollectionsSigning PUBLIC
  $<$<NOT:$<PLATFORM_ID:Darwin>>:dispatch>
  $<$<NOT:$<PLATFORM_ID:Darwin>>:Foundation>
  Basics
  CCryptoBoringSSL
  Crypto
  PackageCollectionsModel
  TSCBasic)
target_link_libraries(PackageCollectionsSigning PRIVATE
  PackageCollectionsSigningLibc)
