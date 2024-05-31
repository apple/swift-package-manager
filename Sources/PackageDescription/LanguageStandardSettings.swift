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

/// The supported C language standard you use to compile C sources in the
/// package.
public enum CLanguageStandard: String {

    /// The identifier for the ISO C 1990 language standard.
    case c89

    /// The identifier for the ISO C 1990 language standard.
    case c90

    /// The identifier for the ISO C 1999 language standard.
    case c99

    /// The identifier for the ISO C 2011 language standard.
    case c11

    /// The identifier for the ISO C 2017 language stadard.
    @available(_PackageDescription, introduced: 5.4)
    case c17

    /// The identifier for the ISO C 2017 language standard.
    @available(_PackageDescription, introduced: 5.4)
    case c18

    /// The identifier for the ISO C2x draft language standard.
    @available(_PackageDescription, introduced: 5.4)
    case c2x

    /// The identifier for the ISO C 1990 language standard with GNU extensions.
    case gnu89

    /// The identifier for the ISO C 1990 language standard with GNU extensions.
    case gnu90

    /// The identifier for the ISO C 1999 language standard with GNU extensions.
    case gnu99

    /// The identifier for the ISO C 2011 language standard with GNU extensions.
    case gnu11

    /// The identifier for the ISO C 2017 language standard with GNU extensions.
    @available(_PackageDescription, introduced: 5.4)
    case gnu17

    /// The identifier for the ISO C 2017 language standard with GNU extensions.
    @available(_PackageDescription, introduced: 5.4)
    case gnu18

    /// The identifier for the ISO C2x draft language standard with GNU extensions.
    @available(_PackageDescription, introduced: 5.4)
    case gnu2x

    /// The identifier for the ISO C 1990 language standard.
    case iso9899_1990 = "iso9899:1990"

    /// The identifier for the ISO C 1990 language standard with amendment 1.
    case iso9899_199409 = "iso9899:199409"

    /// The identifier for the ISO C 1999 language standard.
    case iso9899_1999 = "iso9899:1999"

    /// The identifier for the ISO C 2011 language standard.
    case iso9899_2011 = "iso9899:2011"

    /// The identifier for the ISO C 2017 language standard.
    @available(_PackageDescription, introduced: 5.4)
    case iso9899_2017 = "iso9899:2017"

    /// The identifier for the ISO C 2017 language standard.
    @available(_PackageDescription, introduced: 5.4)
    case iso9899_2018 = "iso9899:2018"
}

/// The supported C++ language standard you use to compile C++ sources in the
/// package.
///
/// Aliases are available for some C++ language standards. For example,
/// use `cxx98` or `cxx03` for the "ISO C++ 1998 with amendments" standard.
/// To learn more, see [C++ Support in Clang](https://clang.llvm.org/cxx_status.html).
public enum CXXLanguageStandard: String {

    /// The identifier for the ISO C++ 1998 language standard with amendments.
    case cxx98 = "c++98"

    /// The identifier for the ISO C++ 1998 language standard with amendments.
    case cxx03 = "c++03"

    /// The identifier for the ISO C++ 2011 language standard with amendments.
    case cxx11 = "c++11"

    /// The identifier for the ISO C++ 2014 language standard with amendments.
    case cxx14 = "c++14"

    /// The identifier for the ISO C++ 2017 language standard with amendments.
    @available(_PackageDescription, introduced: 5.4)
    case cxx17 = "c++17"

    /// The identifier for the ISO C++ 2017 language standard with amendments.
    @available(_PackageDescription, introduced: 4, deprecated: 5.4, renamed: "cxx17")
    case cxx1z = "c++1z"

    /// The identifier for the ISO C++ 2020 language standard.
    @available(_PackageDescription, introduced: 5.4)
    case cxx20 = "c++20"

    /// The identifier for the ISO C++ 2023 draft language standard.
    @available(_PackageDescription, introduced: 5.6)
    case cxx2b = "c++2b"

    /// The identifier for the ISO C++ 1998 language standard with amendments and GNU extensions.
    case gnucxx98 = "gnu++98"

    /// The identifier for the ISO C++ 1998 language standard with amendments and GNU extensions.
    case gnucxx03 = "gnu++03"

    /// The identifier for the ISO C++ 2011 language standard with amendments and GNU extensions.
    case gnucxx11 = "gnu++11"

    /// The identifier for the ISO C++ 2014 language standard with amendments and GNU extensions.
    case gnucxx14 = "gnu++14"

    /// The identifier for the ISO C++ 2017 language standard with amendments and GNU extensions.
    @available(_PackageDescription, introduced: 5.4)
    case gnucxx17 = "gnu++17"

    /// The identifier for the ISO C++ 2017 language standard with amendments and GNU extensions.
    @available(_PackageDescription, introduced: 4, deprecated: 5.4, renamed: "gnucxx17")
    case gnucxx1z = "gnu++1z"

    /// The identifier for the ISO C++ 2020 language standard with GNU extensions.
    @available(_PackageDescription, introduced: 5.4)
    case gnucxx20 = "gnu++20"

    /// The identifier for the ISO C++ 2023 draft language standard with GNU extensions.
    @available(_PackageDescription, introduced: 5.6)
    case gnucxx2b = "gnu++2b"
}

/// The Swift language mode used to compile Swift sources in the package
public enum SwiftLanguageMode {
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

    /// The identifier for the Swift 6 language version.
    @available(_PackageDescription, introduced: 6)
    case v6

    /// A user-defined value for the Swift version.
    ///
    /// The value is passed as-is to the Swift compiler's `-swift-version` flag.
    case version(String)
}

extension SwiftLanguageMode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .v3: "3"
        case .v4: "4"
        case .v4_2: "4.2"
        case .v5: "5"
        case .v6: "6"
        case .version(let version): version
        }
    }
}

/// Type alias to previous name for backward source compatibility
public typealias SwiftVersion = SwiftLanguageMode
