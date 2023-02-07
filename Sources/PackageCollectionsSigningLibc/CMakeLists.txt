# This source file is part of the Swift open source project
#
# Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(PackageCollectionsSigningLibc STATIC
  asn1/a_d2i_fp.c
  asn1/a_i2d_fp.c
  ocsp_asn.c
  ocsp_cl.c
  ocsp_lib.c
  ocsp_vfy.c)
target_include_directories(PackageCollectionsSigningLibc PUBLIC
  include)
target_link_libraries(PackageCollectionsSigningLibc PRIVATE
  CCryptoBoringSSL)
