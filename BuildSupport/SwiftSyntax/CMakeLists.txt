include(FetchContent)

find_package(SwiftSyntax CONFIG GLOBAL)
if(NOT SwiftSyntax_FOUND)
  set(SWIFT_SYNTAX_INSTALL_TARGETS YES)
  if(DEFINED SWIFTPM_PATH_TO_SWIFT_SYNTAX_SOURCE)
    file(TO_CMAKE_PATH "${SWIFTPM_PATH_TO_SWIFT_SYNTAX_SOURCE}" swift_syntax_path)
    FetchContent_Declare(SwiftSyntax
      SOURCE_DIR "${swift_syntax_path}")
  else()
    FetchContent_Declare(SwiftSyntax
      GIT_REPOSITORY https://github.com/swiftlang/swift-syntax
      GIT_TAG main)
  endif()
  FetchContent_MakeAvailable(SwiftSyntax)
endif()
