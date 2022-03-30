//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// The supported C language standard to use for compiling C sources in the
/// package.
public enum CLanguageStandard: String, Encodable {

    /// The identifier for the C89 language standard.
    case c89

    /// The identifier for the C90 language standard.
    case c90

    /// The identifier for the C99 language standard.
    case c99

    /// The identifier for the C11 language standard.
    case c11

    /// The identifier for the C17 language stadard.
    @available(_PackageDescription, introduced: 5.4)
    case c17

    /// The identifier for the C18 language standard.
    @available(_PackageDescription, introduced: 5.4)
    case c18

    /// The identifier for the C2x draft language standard.
    @available(_PackageDescription, introduced: 5.4)
    case c2x

    /// The identifier for the GNU89 language standard.
    case gnu89

    /// The identifier for the GNU90 language standard.
    case gnu90

    /// The identifier for the GNU99 language standard.
    case gnu99

    /// The identifier for the GNU11 language standard.
    case gnu11

    /// The identifier for the GNU17 language standard.
    @available(_PackageDescription, introduced: 5.4)
    case gnu17

    /// The identifier for the GNU18 language standard.
    @available(_PackageDescription, introduced: 5.4)
    case gnu18

    /// The identifier for the GNU2x draft language standard.
    @available(_PackageDescription, introduced: 5.4)
    case gnu2x

    /// The identifier for the ISO9899-1990 language standard.
    case iso9899_1990 = "iso9899:1990"

    /// The identifier for the ISO9899-199409 language standard.
    case iso9899_199409 = "iso9899:199409"

    /// The identifier for the ISO9899-1999 language standard.
    case iso9899_1999 = "iso9899:1999"

    /// The identifier for the ISO9899-2011 language standard.
    case iso9899_2011 = "iso9899:2011"

    /// The identifier for the ISO9899-2017 language standard.
    @available(_PackageDescription, introduced: 5.4)
    case iso9899_2017 = "iso9899:2017"

    /// The identifier for the ISO9899-2018 language standard.
    @available(_PackageDescription, introduced: 5.4)
    case iso9899_2018 = "iso9899:2018"
}

/// The supported C++ language standard to use for compiling C++ sources in the
/// package.
///
/// Aliases are available for some C++ language standards. For example,
/// use `cxx98` or `cxx03` for the "ISO C++ 1998 with amendments" standard.
/// To learn more, see [C++ Support in Clang](https://clang.llvm.org/cxx_status.html).
public enum CXXLanguageStandard: String, Encodable {

    /// The identifier for the C++98 language standard.
    case cxx98 = "c++98"

    /// The identifier for the C++03 language standard.
    case cxx03 = "c++03"

    /// The identifier for the C++11 language standard.
    case cxx11 = "c++11"

    /// The identifier for the C++14 language standard.
    case cxx14 = "c++14"

    /// The identifier for the ISO C++ 2017 (with amendments) language standard..
    @available(_PackageDescription, introduced: 5.4)
    case cxx17 = "c++17"

    /// The identifier for the C++1z language standard.
    @available(_PackageDescription, introduced: 4, deprecated: 5.4, renamed: "cxx17")
    case cxx1z = "c++1z"

    /// The identifier for the ISO C++ 2020 language standard.
    @available(_PackageDescription, introduced: 5.4)
    case cxx20 = "c++20"

    /// The identifier for the ISO C++ 2023 draft language standard.
    @available(_PackageDescription, introduced: 5.6)
    case cxx2b = "c++2b"

    /// The identifier for the GNU++98 language standard.
    case gnucxx98 = "gnu++98"

    /// The identifier for the GNU++03 language standard.
    case gnucxx03 = "gnu++03"

    /// The identifier for the GNU++11 language standard.
    case gnucxx11 = "gnu++11"

    /// The identifier for the GNU++14 language standard.
    case gnucxx14 = "gnu++14"

    /// The identifier for the GNU++17 language standard.
    @available(_PackageDescription, introduced: 5.4)
    case gnucxx17 = "gnu++17"

    /// The identifier for the GNU++1z language standard.
    @available(_PackageDescription, introduced: 4, deprecated: 5.4, renamed: "gnucxx17")
    case gnucxx1z = "gnu++1z"

    /// The identifier for the CNU++20 language standard.
    @available(_PackageDescription, introduced: 5.4)
    case gnucxx20 = "gnu++20"

    /// The identifier for the GNU++2b draft language standard.
    @available(_PackageDescription, introduced: 5.6)
    case gnucxx2b = "gnu++2b"
}

/// The version of the Swift language to use for compiling Swift sources in the
/// package.
public enum SwiftVersion {
    /// The identifier for the Swift 3 language version.
    @available(_PackageDescription, introduced: 4, obsoleted: 5)
    case v3

    /// The identifier for the Swift 4 language version.
    @available(_PackageDescription, introduced: 4)
    case v4

    /// The identifier for the Swift 4.2 language version.
    @available(_PackageDescription, introduced: 4)
    case v4_2

    /// The identifier for the Swift 5 language version.
    @available(_PackageDescription, introduced: 5)
    case v5

    /// A user-defined value for the Swift version.
    ///
    /// The value is passed as-is to the Swift compiler's `-swift-version` flag.
    case version(String)
}
