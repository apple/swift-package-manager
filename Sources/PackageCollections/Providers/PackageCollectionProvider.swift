//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics

/// `PackageCollection` provider. For example, package feeds, (future) Package Index.
protocol PackageCollectionProvider {
    /// Retrieves `PackageCollection` from the specified source.
    ///
    /// - Parameters:
    ///   - source: Where the `PackageCollection` is located
    ///   - callback: The closure to invoke when result becomes available
    ///
    @available(*, noasync, message: "Use the async alternative")
    func get(_ source: PackageCollectionsModel.CollectionSource, callback: @escaping (Result<PackageCollectionsModel.Collection, Error>) -> Void)
}

extension PackageCollectionProvider {
    func get(_ source: Model.CollectionSource) async throws -> Model.Collection {
        try await safe_async {
            self.get(source, callback: $0)
        }
    }
}
