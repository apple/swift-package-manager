//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation
import PackageModel

import struct TSCBasic.ByteString

import struct TSCUtility.Version

/// Protocol for the manifest loader interface.
public struct ToolsVersionParser {
    // designed to be used as a static utility
    private init() {}

    public static func parse(manifestPath: AbsolutePath, fileSystem: FileSystem) throws -> ToolsVersion {
        // FIXME: We should diagnose errors not specific to the tools version specification outside of this function.
        // In order to that, maybe we can restructure the parsing to somthing like this:
        //     parse(_ manifestContent: String) throws -> Manifest {
        //         ...
        //         guard !manifestContent.isEmpty else { throw appropariteError }
        //         let (toolsVersion, remainingContent) = parseAndConsumeToolsVersionSpecification(manifestConent)
        //         let packageDetails = parsePackageDetails(remainingContent)
        //         ...
        //         return Manifest(toolsVersion, ...)
        //     }

        let manifestContents: ByteString
        do {
            manifestContents = try fileSystem.readFileContents(manifestPath)
        } catch {
            throw Error.inaccessibleManifest(path: manifestPath, reason: String(describing: error))
        }

        // FIXME: This is doubly inefficient.
        // `contents`'s value comes from `FileSystem.readFileContents(_)`, which is [inefficient](https://github.com/apple/swift-tools-support-core/blob/8f9838e5d4fefa0e12267a1ff87d67c40c6d4214/Sources/TSCBasic/FileSystem.swift#L167). Calling `ByteString.validDescription` on `contents` is also [inefficient, and possibly incorrect](https://github.com/apple/swift-tools-support-core/blob/8f9838e5d4fefa0e12267a1ff87d67c40c6d4214/Sources/TSCBasic/ByteString.swift#L121). However, this is a one-time thing for each package manifest, and almost necessary in order to work with all Unicode line-terminators. We probably can improve its efficiency and correctness by using `URL` for the file's path, and get is content via `Foundation.String(contentsOf:encoding:)`. Swift System's [`FilePath`](https://github.com/apple/swift-system/blob/8ffa04c0a0592e6f4f9c30926dedd8fa1c5371f9/Sources/System/FilePath.swift) and friends might help as well.
        // This is source-breaking.
        // A manifest that has an [invalid byte sequence](https://en.wikipedia.org/wiki/UTF-8#Invalid_sequences_and_error_handling) (such as `0x7F8F`) after the tools version specification line could work in Swift < 5.4, but results in an error since Swift 5.4.
        guard let manifestContentsDecodedWithUTF8 = manifestContents.validDescription else {
            throw Error.nonUTF8EncodedManifest(path: manifestPath)
        }

        guard !manifestContentsDecodedWithUTF8.isEmpty else {
            throw ManifestParseError.emptyManifest(path: manifestPath)
        }

        do {
          return try self.parse(utf8String: manifestContentsDecodedWithUTF8)
        } catch Error.malformedToolsVersionSpecification(.commentMarker(.isMissing)) {
          throw UnsupportedToolsVersion(packageIdentity: .init(path: manifestPath), currentToolsVersion: .current, packageToolsVersion: .v3)
        }
    }

    public static func parse(utf8String: String) throws -> ToolsVersion {
        do {
            return try Self._parse(utf8String: utf8String)
        } catch {
            // Keep scanning in case the tools-version is specified somewhere further down in the file.
            var string = utf8String
            while let newlineIndex = string.firstIndex(where: { $0.isNewline }) {
                string = String(string[newlineIndex...].dropFirst())
                if !string.isEmpty, let result = try? Self._parse(utf8String: string) {
                    if result >= ToolsVersion.v5_11 {
                        return result
                    } else {
                        throw Error.backwardIncompatiblePre5_11(.toolsVersionNeedsToBeFirstLine, specifiedVersion: result)
                    }
                }
            }
            // If we fail to find a tools-version in the entire manifest, throw the original error.
            throw error
        }
    }

    private static func _parse(utf8String: String) throws -> ToolsVersion {
        assert(!utf8String.isEmpty, "empty manifest should've been diagnosed before parsing the tools version specification")
        /// The manifest represented in its constituent parts.
        let manifestComponents = Self.split(utf8String)
        /// The Swift tools version specification represented in its constituent parts.
        let toolsVersionSpecificationComponents = manifestComponents.toolsVersionSpecificationComponents

        // The diagnosis of the manifest's formatting's correctness goes in the following order:
        //
        // 1. Check that the comment marker, the label, and the version specifier in the Swift tools version specification are not missing (empty).
        //
        // 2. Check that everything in the Swift tools version specification up to the version specifier is formatted correctly according to the relaxed rules since Swift 5.4. Backward-compatibility is not considered here, because the user-specified version is unknown yet.
        //
        //    1. Check that the comment marker is formatted correctly.
        //
        //    2. Check that the label is formatted correctly
        //
        //    3. Check that there is no unforeseen formatting error in the Swift tools version specification up to the version specifier.
        //
        // 3. Check that the version spicier is formatted correctly.
        //
        // 4. Check that the manifest is formatted backward-compatibly, if the user-specified version is < 5.4. Backward-compatibility checks are now possible, because the user-specified version has become known since the previous step.
        //
        //    1. Check that the manifest's leading whitespace is backward-compatible with Swift < 5.4.
        //
        //    2. Check that the spacing after the comment marker in the Swift tools version specification is backward-compatible with Swift < 5.4.
        //
        //    3. Check that the spacing after the label in the Swift tools version specification is backward-compatible with Swift < 5.4.
        //
        // This order is based on the general idea that a manifest's readability should come before its validity when being diagnosed. The package manager must first understand what is written in the manifest before it can tell if anything is wrong. This idea is manifested (no pun intended) in 2 areas of the diagnosis process:
        //
        // 1. The version specifier contains the most important piece of information, but it's checked last in the Swift tools version specification. This happens twice: both in checking its existence and in checking its correctness.
        //
        //    This is because the package manager must be confident that the version specifier it sees is exactly what the user has provided, not polluted by anything that comes before it. With English written left-to-right, and the manifest parsed largely left-to-right, errors in the comment marker and the label could be mistaken by the package manager as the version specifier's. Consider the following Swift tools version specification, where an "l" is mistyped with "1":
        //
        //        // swift-too1s-version: 5.3
        //
        //    Were the version specifier checked before everything else, the package manager will mistake "1s-version: 5.3" as the version specifier, treating the typo in the label as an error in the version specifier. The user will likely be confused, when informed by the diagnostics message that the version specifier is misspelt.
        //
        //    With the label checked before the version specifier, the diagnosis can be more precise, and this kind of confusion to the user can be avoided.
        //
        // 2. Backward-compatibility checks of the manifest are after the formatting checks of the Swift tools version specification, not during them.
        //
        //    Although it makes more sense, form a human's perspective, if the backward-compatibility checks is integrated within the formatting checks, the package manager can not see things as holistically as a human does. It can not pinpoint all errors in the manifest simultaneously, or understand the user's intention when the manifest has formatting errors, let alone finding any backward-incompatibility. It is better to first ensure that the manifest is formatted correctly according to the latest rules, then compare it against old rules to find backward-incompatibilities.

        let commentMarker = toolsVersionSpecificationComponents.commentMarker
        guard !commentMarker.isEmpty else {
            throw Error.malformedToolsVersionSpecification(.commentMarker(.isMissing))
        }

        let label = toolsVersionSpecificationComponents.label
        guard !label.isEmpty else {
            throw Error.malformedToolsVersionSpecification(.label(.isMissing))
        }

        let versionSpecifier = toolsVersionSpecificationComponents.versionSpecifier
        guard !versionSpecifier.isEmpty else {
            throw Error.malformedToolsVersionSpecification(.versionSpecifier(.isMissing))
        }

        guard toolsVersionSpecificationComponents.everythingUpToVersionSpecifierIsWellFormed else {
            if commentMarker != "//" {
                throw Error.malformedToolsVersionSpecification(.commentMarker(.isMisspelt(String(commentMarker))))
            }

            if label.lowercased() != "swift-tools-version:" {
                throw Error.malformedToolsVersionSpecification(.label(.isMisspelt(String(label))))
            }

            // The above If-statements should have covered all possible malformations in Swift tools version specification up to the version specifier.
            // If you changed the logic in this file, and this fatal error is triggered, then you need to re-check the logic, and make sure all possible error conditions are covered in the Else-block.
            throw Error.malformedToolsVersionSpecification(.unidentified)
        }

        guard let version = ToolsVersion(string: String(versionSpecifier)) else {
            throw Error.malformedToolsVersionSpecification(.versionSpecifier(.isMisspelt(String(versionSpecifier))))
        }

        guard version >= .v5_4 || manifestComponents.isCompatibleWithPreSwift5_4 else {
            let manifestLeadingWhitespace = manifestComponents.leadingWhitespace
            if !manifestLeadingWhitespace.allSatisfy({ $0 == "\n" }) {
                throw Error.backwardIncompatiblePre5_4(.leadingWhitespace(String(manifestLeadingWhitespace)), specifiedVersion: version)
            }

            let spacingAfterCommentMarker = toolsVersionSpecificationComponents.spacingAfterCommentMarker
            if spacingAfterCommentMarker != "\u{20}" {
                throw Error.backwardIncompatiblePre5_4(.spacingAfterCommentMarker(String(spacingAfterCommentMarker)), specifiedVersion: version)
            }

            let spacingAfterLabel = toolsVersionSpecificationComponents.spacingAfterLabel
            if !spacingAfterLabel.isEmpty {
                throw Error.backwardIncompatiblePre5_4(.spacingAfterLabel(String(spacingAfterLabel)), specifiedVersion: version)
            }

            // The above If-statements should have covered all possible backward incompatibilities with Swift < 5.4.
            // If you changed the logic in this file, and this fatal error is triggered, then you need to re-check the logic, and make sure all possible error conditions are covered in the Else-block.
            throw Error.backwardIncompatiblePre5_4(.unidentified, specifiedVersion: version)
        }

        return version
    }

    /// Splits the given manifest into its constituent components.
    ///
    /// A manifest consists of the following parts:
    ///
    ///                                                    ⎫
    ///                                                    ⎪
    ///                                                    ⎬ leading whitespace-only lines
    ///                                                    ⎪
    ///                                                    ⎭
    ///       ┌ Swift tools version specification
    ///       │                            ┌ ignored trailing contents
    ///       ⌄~~~~~~~~~~~~~~~~~~~~~~~~~~~~⌄~~~~~~~~~~
    ///       //  swift-tools-version:  5.4;2020-09-16     } the Swift tools version specification line
    ///     ⌃~⌃~⌃~⌃~~~~~~~~~~~~~~~~~~~⌃~⌃~~⌃⌃~~~~~~~~~
    ///     │ │ │ └ label             │ │  │└ trailing comment segment including a trailing line terminator, if any (not returned by this function)
    ///     │ │ └ spacing             │ │  └ specification terminator (not returned by this function)
    ///     │ └ comment marker        │ └ version specifier
    ///     │                         └ spacing
    ///     └ additional leading whitespace
    ///                                                    ⎫
    ///                                                    ┇
    ///                                                    ⎬ the rest of the manifest's contents
    ///                                                    ┇
    ///                                                    ⎭
    ///
    /// - Note: The splitting mostly assumes that the manifest is well-formed. A malformed component may lead to incorrect identification of other components.
    ///
    ///   For example, a malformed Swift tools version specification `"// swift-too1s-version:5.3"` misleads this function to identify `"swift-too"` as the label, and `"1s-version:5.3"` the version specifier.
    ///
    /// - Parameter manifest: The UTF-8-encoded content of the manifest.
    /// - Returns: The components of the given manifest.
    public static func split(_ manifest: String) -> ManifestComponents {

        // We split the string manually instead of using `Collection.split(maxSplits:omittingEmptySubsequences:whereSeparator:)`, because the latter "strips" leading and trailing whitespace, and we need to record the leading whitespace to check for backward-compatibility later.

        /// The position of the first character of the Swift tools version specification line in the manifest.
        ///
        /// Because the tools version specification line is the first non-whitespace-only line in the manifest, the position of its first character is also the position of the first non-whitespace character in the manifest. If there is only whitespace in the manifest, then this position is the `endIndex` of the manifest.
        let startIndexOfSpecification = manifest.firstIndex(where: { !$0.isWhitespace } ) ?? manifest.endIndex

        /// The whitespace at the start of the manifest.
        ///
        /// Because the tools version specification is the first non-whitespace-only character sequence in the manifest, the manifest's leading whitespace are the only characters in front of the tools version specification.
        let leadingWhitespace = manifest[..<startIndexOfSpecification]

        /// The position right past the last character of the Swift tools version specification line in the manifest.
        ///
        /// Because the specification line ends at a line terminator, the position right past the line's last character is the position of the terminator of the line. If no such line terminator exists, then this position is the `endIndex` of the manifest.
        let endIndexOfSpecificationLine = manifest[startIndexOfSpecification...].firstIndex(where: \.isNewline) ?? manifest.endIndex

        /// The Swift tools version specification with ignored trailing contents.
        ///
        /// The specification is the first comment (until its terminator) in the manifest that declares the version of the `PackageDescription` library, the minimum version of the Swift tools and Swift language compatibility version to process the manifest, and the minimum version of the Swift tools that are needed to use the Swift package.
        ///
        /// The ignored trailing contents are everything starting from the first semicolon after the version specifier in the line.
        let specificationWithIgnoredTrailingContents = manifest[startIndexOfSpecification..<endIndexOfSpecificationLine]

        /// The position right past the last character of the Swift tools version specification's comment marker.
        ///
        /// This is the same as the position of the first character that is neither `"/"` nor `"*"` in the Swift tools version specification. If no such character exists, then this position is the `endIndex` of the Swift tools version specification.
        let endIndexOfCommentMarker = specificationWithIgnoredTrailingContents.firstIndex(where: { $0 != "/" && $0 != "*" } ) ?? specificationWithIgnoredTrailingContents.endIndex

        /// The comment marker of the Swift tools version specification.
        ///
        /// The continuous sequence of `"/"`s and `"*"`s immediately following the leading whitespace is considered as the comment marker, regardless of its validity.
        let commentMarker = specificationWithIgnoredTrailingContents[..<endIndexOfCommentMarker]

        /// The position right past the last character of the spacing that immediately follows the comment marker.
        ///
        /// Because the spacing consists of only horizontal whitespace characters, this position is the same as the first character that's not a horizontal whitespace after `commentMarker`. If no such character exists, then the position is the `endIndex` of the Swift tools version specification line.
        let startIndexOfLabel = specificationWithIgnoredTrailingContents[endIndexOfCommentMarker...].firstIndex(where: { !$0.isWhitespace } ) ?? specificationWithIgnoredTrailingContents.endIndex
        //                                                                                                                  ☝️
        // Technically, this is looking for the position of the first character that's not a whitespace, BOTH HORIZONTAL AND VERTICAL. However, since all vertical horizontal whitespace characters are also line terminators, and because the Swift tools version specification does not contain any line terminator, we can safely use `Character.isWhitespace` to check if a character is a horizontal whitespace.

        /// The spacing that immediately follows `commentMarker`.
        ///
        /// The spacing consists of only horizontal whitespace characters.
        let spacingAfterCommentMarker = specificationWithIgnoredTrailingContents[endIndexOfCommentMarker..<startIndexOfLabel]

        // FIXME: Improve the logic for identifying the label and the version specifier.
        //
        // At this point, everything before the label has been parsed, and everything starting from the label until the end of the Swift tools version specification line hasn't.
        //
        // The task that remains is to identify and record the following well defined components: a label, a version specifier, and an optional spacing between the label and the version specifier. However, because of the countless misspellings there could be, it's virtually impossible to teach SwiftPM to perfectly tell where the label ends and where the version specifier begins, without making the logic too complex.
        //
        // Let's explore this problem starting from a well-formed Swift tools version specification, because it's the only invariable that we can rely on. The current `Substring`-based strategy depends on landmarks that sit on either the `startIndex` or the `endIndex` of a component. We already know where the label starts, and it's trivial to find where the version specifier ends (its terminator is well-defined), so all that we need look for now are the `endIndex` of the label and the `startIndex` of the version specifier. In a well-formatted Swift tools version specification, the label ends with a ":", and the version specifier starts with a digit. Let's see how these 2 landmarks fare with some examples:
        //
        // 1. A well-formatted Swift tools version specification
        //
        //        // swift-tools-version: 5.4
        //
        //    The `endIndex` of the label can be clearly identified with the first ":", and the `startIndex` of the version specifier can be clearly identified with the first digit "5".
        //
        // 2. A misspelt label with a digit within:
        //
        //        // swift-too1s-version: 5.4
        //    The `endIndex` of the label can be identified with the first ":"; the `startIndex` of the version specifier can be identified with the digit "5", if and only if the search for the first ":" takes precedence.
        //
        // 3. A misspelt label with a colon and a digit within:
        //
        //        // sw:ft-too1s-version: 5.4
        //
        //    The `endIndex` of the label can be identified with the last ":";  the `startIndex` of the version specifier can be identified with the digit "5", if and only if the search for the last ":" takes precedence.
        //
        // Between example 2 and 3, the rules are already conflicting. Although the examples above are purposely constructed to illustrate the ineffectiveness of using ":" and digits to locate the label and the version specifier, it's undeniable a human can flawlessly point out where the labels and version specifiers are at a glance. There are more examples that shows it's even harder to find a one-size-fits-all landmark-based rule than illustrated above:
        //
        //     // swift-too1s-version:-5.4
        //     // swift-too1s-version 5:4:0
        //     // swift tools version 5-4-1
        //     // swift-tools-version: S.A.I
        //     // swift-tools-version::5.4
        //     ...
        //
        // One useful information we can glean from these examples is that using both ":" and digits as landmarks doesn't work, so it's better to stick with just one of them and ignore the other. Because the version specifier is the more important component than the label is, the current implementation of this function searches for the first numerical character in the sequence to prioritize the identification of the version specifier. The ":"-first approach isn't completely abandoned, either: If the sequence is prefixed with "swift-tools-version:" (case-insensitive), then we can be mostly certain that the user has provided a well-formatted label, and use the position past that of the first ":" in the sequence as the `startIndex` of the label. There are still countless label misspellings that begin with "swift-tools-version:", but since for all of them, the misspelt part comes after the well-formed part, in the interest of keeping the logic relatively straightforward, the labels' misspellings in this sort of situation are carried over as the version specifiers'.
        //
        // Although it's possible to replace the landmark-based logic altogether with a fuzzy matching-based approach or some heuristics, it overly complicates this function. Even if a more advanced method is applied at the expense of high complexity, it's still unlikely to be perfect. Maybe someone can find better solution without incurring much additional cost.

        /// The position right past the last character in the label part of the Swift tool version specification.
        ///
        /// If the label begins with exactly `"swift-tools-version:"`, then this position is right after the `":"`'s. Otherwise, it's the position of the first horizontal whitespace character since the spacing after the comment marker (if there is a spacing between the label and the version specifier) or the `startIndex` of the version specifier (if there is no spacing between the label and the version specifier).
        let endIndexOfLabel: Substring.Index

        /// The position of the first character in the version specifier.
        ///
        /// If the label begins with exactly `"swift-tools-version:"`,  then this position is that of the first non-whitespace character after the label in the Swift tools version specification line. Otherwise, it's the same as the position of the first numeric character in the Swift tools version specification line. If no suitable character exists in either case, then this position is the `endIndex` of the line.
        ///
        /// - Note:
        ///
        ///   For a misspelt Swift tools version specification `"// swift-too1s-version:5.3"`, the first `"1"` is considered as the first character of the version specifier, and so `"1s-version:5.3"` is taken as the version specifier.
        ///
        ///   For a misspelt Swift tools version specification `"// swift-tools-version:-5.3"`, the label begins with `"swift-tools-version:"`, so all the misspelling is treated as the version specifiers, and so `"-5.3"` is taken as the version specifier.
        let startIndexOfVersionSpecifier: Substring.Index

        /// The trailing slice of the Swift tools version specification line starting from the label.
        let specificationSnippetFromLabelToLineTerminator = specificationWithIgnoredTrailingContents[startIndexOfLabel...]

        if specificationSnippetFromLabelToLineTerminator.lowercased().hasPrefix("swift-tools-version:") {
            // The optional index can be safely unwrapped, because we know for sure there is a ":" in the substring.                                     👇
            endIndexOfLabel = specificationSnippetFromLabelToLineTerminator.index(after: specificationSnippetFromLabelToLineTerminator.firstIndex(of: ":")!)
            // Because there is potentially a spacing between the label and the version specifier, we need to skip the whitespace first.
            startIndexOfVersionSpecifier = specificationSnippetFromLabelToLineTerminator[endIndexOfLabel...].firstIndex(where: { !$0.isWhitespace } ) ?? specificationSnippetFromLabelToLineTerminator.endIndex
        } else {
            // FIXME: Use `CharacterSet.decimalDigits` instead?
            // `Character.isNumber` is true for more than just decimal characters (e.g. ㊅ and 𝟘), but `CharacterSet.contains(_:)` works only on Unicode scalars.
            startIndexOfVersionSpecifier = specificationSnippetFromLabelToLineTerminator.firstIndex(where: \.isNumber) ?? specificationWithIgnoredTrailingContents.endIndex
            /// The label part of the Swift tools version specification with the whitespace sequence between the label and the version specifier.
            /// - Note: For a misspelt Swift tools version specification `"// swift-too1s-version: 5.4"`, the label stops at the second `"o"`, so only `"swift-too"` is recognised as the label with no spacing following it.
            let labelWithTrailingWhitespace = specificationWithIgnoredTrailingContents[startIndexOfLabel..<startIndexOfVersionSpecifier]
            // Because there is no whitespace within the label, and because the spacing consists of only horizontal whitespace characters, the end index of the label is the same as the position of the first whitespace character between the beginning of the label and the beginning of the version specifier. If no such whitespace character exists, then there is no spacing, and so this position is the `endIndex` of these sequence of characters (i.e. the starting position of the version specifier).
            endIndexOfLabel = labelWithTrailingWhitespace.firstIndex(where: \.isWhitespace) ?? startIndexOfVersionSpecifier
        }

        /// The label part of the Swift tools version specification.
        /// - Note: For a misspelt Swift tools version specification `"// swift-too1s-version: 5.4"`, the label stops at the second `"o"`, so only `"swift-too"` is recognised as the label.
        let label = specificationSnippetFromLabelToLineTerminator[startIndexOfLabel..<endIndexOfLabel]

        /// The spacing between the label part of the Swift tools version specification and the version specifier.
        /// - Note: For a misspelt Swift tools version specification `"// swift-too1s-version: 5.4"`, the label stops at the second `"o"`, and the version specifier starts from the first `"1"`, so no spacing is recognised.
        let spacingAfterLabel = specificationSnippetFromLabelToLineTerminator[endIndexOfLabel..<startIndexOfVersionSpecifier]

        /// The position of the version specifier's terminator.
        ///
        /// The terminator can be either a `";"` or a line terminator. If no such character exists, then this position is the `endIndex` of the Swift tools version specification.
        let indexOfVersionSpecifierTerminator = specificationWithIgnoredTrailingContents[startIndexOfVersionSpecifier...].firstIndex(where: { $0 == ";" } ) ?? specificationWithIgnoredTrailingContents.endIndex
        //                                                                                                                                          ☝️
        // Technically, this is looking for the position of the first ";" only, not the first line terminator. However, because the Swift tools version specification does not contain any line terminator, we can safely search just the first ";".

        // If the label doesn't start with "// swift-too1s-version: 5.4", the version specifier and its terminator together are first found by locating the first numeric character in the specification line, and the version specifier starts with that first numeric character. So, if the version specifier is empty, then the line has no numeric characters, then the specification's ignored trailing contents are empty too. Basically, if the version specifier is empty, then the specification has no ignored trailing contents. This is only true for when the label doesn't start with "// swift-too1s-version: 5.4".

        /// The version specifier.
        /// - Note: For a misspelt Swift tools version specification `"// swift-too1s-version:5.3"`, the first `"1"` is considered as the first character of the version specifier, and so `"1s-version:5.3"` is taken as the version specifier.
        let versionSpecifier = specificationSnippetFromLabelToLineTerminator[startIndexOfVersionSpecifier..<indexOfVersionSpecifierTerminator]

        // The tertiary condition checks if the specification line's end index is the same as the manifest's.
        // If it is, then just use the index, because the rest of the manifest is empty, and because using `index(after:)` on it results in an index-out-of-bound error.
        /// The position of the first character following the tools version specification line in the manifest.
        ///
        /// If no such character exists, then the position is the `endIndex` of the manifest.
        let startIndexOfManifestAfterSpecification = endIndexOfSpecificationLine == manifest.endIndex ? manifest.endIndex : manifest.index(after: endIndexOfSpecificationLine)

        /// The remaining contents of the manifest that follows right after the tools version specification line.
        let manifestAfterSpecification = manifest[startIndexOfManifestAfterSpecification...]

        return ManifestComponents(
            leadingWhitespace: leadingWhitespace,
            toolsVersionSpecificationComponents: ToolsVersionSpecificationComponents(
                commentMarker: commentMarker,
                spacingAfterCommentMarker: spacingAfterCommentMarker,
                label: label,
                spacingAfterLabel: spacingAfterLabel,
                versionSpecifier: versionSpecifier
            ),
            contentsAfterToolsVersionSpecification: manifestAfterSpecification
        )
    }
}

extension ToolsVersionParser {
    /// A representation of a manifest in its constituent parts.
    public struct ManifestComponents {
        /// The largest contiguous sequence of whitespace characters at the very beginning of the manifest.
        public let leadingWhitespace: Substring
        /// The Swift tools version specification represented in its constituent parts.
        public let toolsVersionSpecificationComponents: ToolsVersionSpecificationComponents
        /// The remaining contents of the manifest that follows right after the tools version specification line.
        public let contentsAfterToolsVersionSpecification: Substring
        /// A Boolean value indicating whether the manifest represented in its constituent parts is backward-compatible with Swift < 5.4.
        public var isCompatibleWithPreSwift5_4: Bool {
            leadingWhitespace.allSatisfy { $0 == "\n" } && toolsVersionSpecificationComponents.isCompatibleWithPreSwift5_4
        }
    }

    /// A representation of a Swift tools version specification in its constituent parts.
    ///
    /// A Swift tools version specification consists of the following parts:
    ///
    ///     //  swift-tools-version:  5.4
    ///     ⌃~⌃~⌃~~~~~~~~~~~~~~~~~~~⌃~⌃~~
    ///     │ │ └ label             │ └ version specifier
    ///     │ └ spacing             └ spacing
    ///     └ comment marker
    ///
    public struct ToolsVersionSpecificationComponents {
        /// The comment marker.
        ///
        /// In a well-formed Swift tools version specification, the comment marker is `"//"`.
        public let commentMarker: Substring

        /// The spacing after the comment marker
        ///
        /// In a well-formed Swift tools version specification, the spacing after the comment marker is a continuous sequence of horizontal whitespace characters.
        ///
        /// For Swift < 5.4, the spacing after the comment marker must be a single `U+0020`.
        public let spacingAfterCommentMarker: Substring

        /// The label part of the Swift tools version specification.
        ///
        /// In a well-formed Swift tools version specification, the label is `"swift-tools-version:"`
        public let label: Substring

        /// The spacing between the label part of the Swift tools version specification and the version specifier.
        ///
        /// In a well-formed Swift tools version specification, the spacing after the label is a continuous sequence of horizontal whitespace characters.
        ///
        /// For Swift < 5.4, no spacing is allowed after the label.
        public let spacingAfterLabel: Substring

        /// The version specifier.
        public let versionSpecifier: Substring

        /// A Boolean value indicating whether everything up to the version specifier in the Swift tools version specification represented in its constituent parts is well-formed.
        public var everythingUpToVersionSpecifierIsWellFormed: Bool {
            // The label is case-insensitive.
            // Making it case-sensitive is source breaking for all existing Swift versions.
            //
            // An argument for making it case-sensitive is that it can make the package manager slightly more efficient:
            //
            // "swift-tools-version:" has more than 15 UTF-8 code units, so `label` is likely to have more than 15 UTF-8 code units too.
            // Strings with more than 15 UTF-8 code units are heap-allocated on 64-bit platforms, 10 on 32-bit platforms.
            // `Substring.lowercase()` returns a heap-allocated string here, and this is inefficient.
            // Although, the allocation happens only once per manifest (once per loading attempt), so the inefficiency is rather insignificant.
            // Short-circuiting the `lowercase()` can remove an allocation.
            commentMarker == "//" && label.lowercased() == "swift-tools-version:"
        }

        /// A Boolean value indicating whether the Swift tools version specification represented in its constituent parts is backward-compatible with Swift < 5.4.
        public var isCompatibleWithPreSwift5_4: Bool {
            everythingUpToVersionSpecifierIsWellFormed && spacingAfterCommentMarker == "\u{20}" && spacingAfterLabel.isEmpty
        }
    }
}

extension ToolsVersionParser {
    // Parameter names for associated values help the auto-complete provide hints at the call site, even when the argument label is suppressed.

    // FIXME: Use generic associated type `T: StringProtocol` instead of concrete types `String` and `Substring`, when/if this feature comes to Swift.
    public enum Error: Swift.Error, CustomStringConvertible {

        /// Location of the tools version specification's malformation.
        public enum ToolsVersionSpecificationMalformationLocation {
            /// The nature of malformation at the location in Swift tools version specification.
            public enum MalformationDetails {
                /// The Swift tools version specification component is missing in the non-empty manifest.
                case isMissing
                /// The Swift tools version specification component is misspelt.
                case isMisspelt(_ misspelling: String)
            }
            /// The comment marker is malformed.
            ///
            /// If the comment marker is missing, it could be an indication that the entire Swift tools version specification is missing.
            case commentMarker(_ malformationDetails: MalformationDetails)
            /// The label part of the Swift tools version specification is malformed.
            case label(_ malformationDetails: MalformationDetails)
            /// The version specifier is malformed.
            ///
            /// If the version specifier is diagnosed as missing, it could be a misdiagnosis of some misspellings in the label due to a compromise made in `ToolsVersionLoader.split(_:)`. For example, the following Swift tools version specification will be misdiagnosed to be missing a version specifier:
            ///
            ///     // swift-tools-version:;5.3
            ///
            /// This is because the position right past `":"` is considered as the `startIndex` of the version specifier, but at the same time the character at this position is `";"`, a terminator of the Swift tools version specification. This misleads `ToolsVersionLoader.load(file:fileSystem:)` to believe the version specifier is empty (i.e. missing).
            case versionSpecifier(_ malformationDetails: MalformationDetails)
            /// An unidentifiable component of the Swift tools version specification is malformed.
            case unidentified
        }

        /// Details of backward-incompatible contents with Swift tools version < 5.4.
        ///
        /// A backward-incompatibility is not necessarily a malformation.
        public enum BackwardIncompatibilityPre5_4 {
            /// The whitespace at the start of the manifest is not all `U+000A`.
            case leadingWhitespace(_ whitespace: String)
            /// The horizontal spacing between "//" and  "swift-tools-version" either is empty or uses whitespace characters unsupported by Swift < 5.4.
            case spacingAfterCommentMarker(_ spacing: String)
            /// There is a non-empty spacing between the label part of the Swift tools version specification and the version specifier.
            case spacingAfterLabel(_ spacing: String)
            /// There is an unidentifiable backward-incompatibility with Swift tools version < 5.4 within the manifest.
            case unidentified
        }

        /// Details of backward-incompatible contents with Swift tools version < 5.11.
        public enum BackwardIncompatibilityPre5_11 {
            /// Tools-versions on subsequent lines of the manifest are only accepted by 5.11 or later.
            case toolsVersionNeedsToBeFirstLine
        }

        /// Package directory is inaccessible (missing, unreadable, etc).
        case inaccessiblePackage(path: AbsolutePath, reason: String)
        /// Package manifest file is inaccessible (missing, unreadable, etc).
        case inaccessibleManifest(path: AbsolutePath, reason: String)
        /// Package manifest file's content can not be decoded as a UTF-8 string.
        case nonUTF8EncodedManifest(path: AbsolutePath)
        /// Malformed tools version specification.
        case malformedToolsVersionSpecification(_ malformationLocation: ToolsVersionSpecificationMalformationLocation)
        /// Backward-incompatible contents with Swift tools version < 5.4.
        case backwardIncompatiblePre5_4(_ incompatibility: BackwardIncompatibilityPre5_4, specifiedVersion: ToolsVersion)
        /// Backward-incompatible contents with Swift tools version < 5.11.
        case backwardIncompatiblePre5_11(_ incompatibility: BackwardIncompatibilityPre5_11, specifiedVersion: ToolsVersion)

        public var description: String {

            /// Returns a description of the given characters' Unicode code points.
            ///
            /// This tells the user what characters are currently used in the specification.
            ///
            /// - Parameter characters: The given characters the description of whose code points are to be returned.
            /// - Returns: A list of `characters`' code points, each prefixed by "U+", separated by commas, and bounded together by a pair of square brackets.
            func unicodeCodePointsPrefixedByUPlus<T: StringProtocol>(of characters: T) -> String {
                let unicodeCodePointsOfCharacters: [UInt32] = characters.flatMap(\.unicodeScalars).map(\.value)
                let unicodeCodePointsOfCharactersPrefixedByUPlus: [String] = unicodeCodePointsOfCharacters.map { codePoint in
                    var codePointString = String(codePoint, radix: 16).uppercased()
                    if codePointString.count < 4 {
                        codePointString = String(repeating: "0", count: 4 - codePointString.count) + codePointString
                    }
                    return "U+\(codePointString)"
                }
                // FIXME: Use `ListFormatter` instead?
                return "[\(unicodeCodePointsOfCharactersPrefixedByUPlus.joined(separator: ", "))]"
            }

            switch self {
            case let .inaccessiblePackage(packageDirectoryPath, reason):
                return "the package at '\(packageDirectoryPath)' cannot be accessed (\(reason))"
            case let .inaccessibleManifest(manifestFilePath, reason):
                return "the package manifest at '\(manifestFilePath)' cannot be accessed (\(reason))"
            case let .nonUTF8EncodedManifest(manifestFilePath):
                return "the package manifest at '\(manifestFilePath)' cannot be decoded using UTF-8"
            case let .malformedToolsVersionSpecification(malformationLocation):
                switch malformationLocation {
                case .commentMarker(let commentMarker):
                    switch commentMarker {
                    case .isMissing:
                        return "the manifest is missing a Swift tools version specification; consider prepending to the manifest '\(ToolsVersion.current.specification())' to specify the current Swift toolchain version as the lowest Swift version supported by the project; if such a specification already exists, consider moving it to the top of the manifest, or prepending it with '//' to help Swift Package Manager find it"
                    case .isMisspelt(let misspeltCommentMarker):
                        return "the comment marker '\(misspeltCommentMarker)' is misspelt for the Swift tools version specification; consider replacing it with '//'"
                    }
                case .label(let label):
                    switch label {
                    case .isMissing:
                        return "the Swift tools version specification is missing a label; consider inserting 'swift-tools-version:' between the comment marker and the version specifier"
                    case .isMisspelt(let misspeltLabel):
                        return "the Swift tools version specification's label '\(misspeltLabel)' is misspelt; consider replacing it with 'swift-tools-version:'"
                    }
                case .versionSpecifier(let versionSpecifier):
                    switch versionSpecifier {
                    case .isMissing:
                        return "the Swift tools version specification is possibly missing a version specifier; consider using '\(ToolsVersion.current.specification())' to specify the current Swift toolchain version as the lowest Swift version supported by the project"
                    case .isMisspelt(let misspeltVersionSpecifier):
                        return "the Swift tools version '\(misspeltVersionSpecifier)' is misspelt or otherwise invalid; consider replacing it with '\(ToolsVersion.current.specification())' to specify the current Swift toolchain version as the lowest Swift version supported by the project"
                    }
                case .unidentified:
                    return "the Swift tools version specification has a formatting error, but the package manager is unable to find either the location or cause of it; consider replacing it with '\(ToolsVersion.current.specification())' to specify the current Swift toolchain version as the lowest Swift version supported by the project; additionally, please consider filing a bug report on https://bugs.swift.org with this file attached"
                }
            case let .backwardIncompatiblePre5_4(incompatibility, specifiedVersion):
                switch incompatibility {
                case .leadingWhitespace(let whitespace):
                    return "leading whitespace sequence \(unicodeCodePointsPrefixedByUPlus(of: whitespace)) in manifest is supported by only Swift ≥ 5.4; the specified version \(specifiedVersion) supports only line feeds (U+000A) preceding the Swift tools version specification; consider moving the Swift tools version specification to the first line of the manifest"
                case .spacingAfterCommentMarker(let spacing):
                    return "\(spacing.isEmpty ? "zero spacing" : "horizontal whitespace sequence \(unicodeCodePointsPrefixedByUPlus(of: spacing))") between '//' and 'swift-tools-version' is supported by only Swift ≥ 5.4; consider replacing the sequence with a single space (U+0020) for Swift \(specifiedVersion)"
                case .spacingAfterLabel(let spacing):
                    return "horizontal whitespace sequence \(unicodeCodePointsPrefixedByUPlus(of: spacing)) immediately preceding the version specifier is supported by only Swift ≥ 5.4; consider removing the sequence for Swift \(specifiedVersion)"
                case .unidentified:
                    return "the manifest is backward-incompatible with Swift < 5.4, but the package manager is unable to pinpoint the exact incompatibility; consider replacing the current Swift tools version specification with '\(specifiedVersion.specification())' to specify Swift \(specifiedVersion) as the lowest Swift version supported by the project, then move the new specification to the very beginning of this manifest file; additionally, please consider filing a bug report on https://bugs.swift.org with this file attached"
                }
            case let .backwardIncompatiblePre5_11(incompatibility, _):
                switch incompatibility {
                case .toolsVersionNeedsToBeFirstLine:
                    return "the manifest is backward-incompatible with Swift < 5.11 because the tools-version was specified in a subsequent line of the manifest, not the first line. Either move the tools-version specification or increase the required tools-version of your manifest"
                }
            }

        }
    }
}

extension ManifestLoader {
    /// Returns the manifest at the given package path.
    ///
    /// Version specific manifest is chosen if present, otherwise path to regular
    /// manifest is returned.
    public static func findManifest(
        packagePath: AbsolutePath,
        fileSystem: FileSystem,
        currentToolsVersion: ToolsVersion
    ) throws -> AbsolutePath {
        // Look for a version-specific manifest.
        for versionSpecificKey in ToolsVersion.current.versionSpecificKeys {
            let versionSpecificPath = packagePath.appending(component: Manifest.basename + versionSpecificKey + ".swift")
            if fileSystem.isFile(versionSpecificPath) {
                return versionSpecificPath
            }
        }

        let contents: [String]
        do { contents = try fileSystem.getDirectoryContents(packagePath) } catch {
            throw ToolsVersionParser.Error.inaccessiblePackage(path: packagePath, reason: String(describing: error))
        }
        let regex = #/^Package@swift-(?<major>\d+)(?:\.(?<minor>\d+))?(?:\.(?<patch>\d+))?.swift$/#
        // Collect all version-specific manifests at the given package path.
        let versionSpecificManifests = Dictionary(contents.compactMap{ file -> (ToolsVersion, String)? in
            let parsedVersionMatches = file.matches(of: regex)
            guard parsedVersionMatches.count == 1,
                  let parsedVersion = parsedVersionMatches.first else {
                return nil
            }
            let major = Int(parsedVersion.major) ?? 0
            let minor: Int
            if let minorString = parsedVersion.minor {
                minor = Int(minorString) ?? 0
            } else {
                minor = 0
            }
            let patch: Int
            if let patchString = parsedVersion.patch {
                patch = Int(patchString) ?? 0
            } else {
                patch = 0
            }
            return (ToolsVersion(version: Version(major, minor, patch)), file)
        }, uniquingKeysWith: { $1 })

        let regularManifest = packagePath.appending(component: Manifest.filename)

        // Try to get the tools version of the regular manifest.  As the comment marker is missing, we default to
        // tools version 3.1.0 (as documented).
        let regularManifestToolsVersion: ToolsVersion
        do {
            regularManifestToolsVersion = try ToolsVersionParser.parse(manifestPath: regularManifest, fileSystem: fileSystem)
        }
        catch let error as UnsupportedToolsVersion where error.packageToolsVersion == .v3 {
          regularManifestToolsVersion = .v3
        }

        // Find the newest version-specific manifest that is compatible with the current tools version.
        guard let versionSpecificCandidate = versionSpecificManifests.keys.sorted(by: >).first(where: { $0 <= currentToolsVersion }) else {
            // Otherwise, return the regular manifest.
            return regularManifest
        }

        let versionSpecificManifest = packagePath.appending(component: versionSpecificManifests[versionSpecificCandidate]!)

        // SwiftPM 4 introduced tools-version designations; earlier packages default to tools version 3.1.0.
        // See https://swift.org/blog/swift-package-manager-manifest-api-redesign.
        let versionSpecificManifestToolsVersion: ToolsVersion
        if versionSpecificCandidate < .v4 {
            versionSpecificManifestToolsVersion = .v3
        }
        else {
            versionSpecificManifestToolsVersion = try ToolsVersionParser.parse(manifestPath: versionSpecificManifest, fileSystem: fileSystem)
        }

        // Compare the tools version of this manifest with the regular
        // manifest and use the version-specific manifest if it has
        // a greater tools version.
        if versionSpecificManifestToolsVersion > regularManifestToolsVersion {
            return versionSpecificManifest
        } else {
            // If there's no primary candidate, validate the regular manifest.
            if regularManifestToolsVersion.validateToolsVersion(currentToolsVersion) {
                return regularManifest
            } else {
                // If that's incompatible, use the closest version-specific manifest we got.
                return versionSpecificManifest
            }
        }
    }
}
