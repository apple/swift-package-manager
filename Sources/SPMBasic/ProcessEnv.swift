/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2019 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Foundation
import SPMLibc

/// Provides functionality related a process's enviorment.
public enum ProcessEnv {

    /// Returns a dictionary containing the current environment.
    public static var vars: [String: String] {
        return ProcessInfo.processInfo.environment
    }

    /// Set the given key and value in the process's environment.
    public static func setVar(_ key: String, value: String) throws {
      #if os(Windows)
        guard 0 != key.withCString(encodedAs: UTF16.self, { keyStr in
            value.withCString(encodedAs: UTF16.self) { valStr in
                SetEnvironmentVariableW(keyStr, valStr)
            }
        }) else {
            throw SystemError.setenv(Int32(GetLastError()), key)
        }
      #else
        guard SPMLibc.setenv(key, value, 1) == 0 else {
            throw SystemError.setenv(errno, key)
        }
      #endif
    }

    /// Unset the give key in the process's environment.
    public static func unsetVar(_ key: String) throws {
      #if os(Windows)
        guard 0 != key.withCString(encodedAs: UTF16.self, { keyStr in
            SetEnvironmentVariableW(keyStr, nil)
        }) else {
            throw SystemError.unsetenv(Int32(GetLastError()), key)
        }
      #else
        guard SPMLibc.unsetenv(key) == 0 else {
            throw SystemError.unsetenv(errno, key)
        }
      #endif
    }

    /// The current working directory of the process.
    public static var cwd: AbsolutePath? {
        return localFileSystem.currentWorkingDirectory
    }

    /// Change the current working directory of the process.
    public static func chdir(_ path: AbsolutePath) throws {
        let path = path.pathString
      #if os(Windows)
        guard 0 != path.withCString(encodedAs: UTF16.self, {
            SetCurrentDirectoryW($0)
        }) else {
            throw SystemError.chdir(Int32(GetLastError()), path)
        }
      #else
        guard SPMLibc.chdir(path) == 0 else {
            throw SystemError.chdir(errno, path)
        }
      #endif
    }
}
