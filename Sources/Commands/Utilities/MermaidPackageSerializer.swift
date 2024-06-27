//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct OrderedCollections.OrderedDictionary
import class PackageModel.Package
import class PackageModel.Product
import class PackageModel.Module

struct MermaidPackageSerializer {
    let package: Package
    var shouldIncludeLegend = false

    var renderedMarkdown: String {
        var subgraphs = OrderedDictionary<String, [Edge]>()
        subgraphs[package.identity.description] = package.products.productTargetEdges
        
        for edge in package.modules.targetDependencyEdges {
            if let subgraph = edge.to.subgraph {
                subgraphs[subgraph, default: []].append(edge)
            } else {
                subgraphs[package.identity.description]?.append(edge)
            }
        }

        return """
        ```mermaid
        flowchart TB
            \(
                shouldIncludeLegend ?
                    """
                    subgraph legend
                        legend:target(target)
                        legend:product[[product]]
                        legend:dependency{{package dependency}}
                    end

                    """ : ""
            )\(
                subgraphs.map { subgraph, edges in
                    """
                    subgraph \(subgraph)
                            \(
                                edges.map(\.description).joined(separator: "\n        ")
                            )
                        end
                    """
                }.joined(separator: "\n\n    ")
            )
        ```

        """
    }

    fileprivate struct Node {
        enum Border {
            case roundedCorners
            case doubled
            case hexagon

            func added(to title: String) -> String {
                switch self {
                case .roundedCorners:
                    "(\(title))"
                case .doubled:
                    "[[\(title)]]"
                case .hexagon:
                    "{{\(title)}}"
                }
            }
        }

        let id: String
        let title: String
        let border: Border
        let subgraph: String?
    }

    fileprivate struct Edge {
        let from: Node
        let to: Node
    }
}

extension MermaidPackageSerializer.Node {
    init(id: String, title: String) {
        self.id = id
        self.border = .roundedCorners
        self.title = title
        self.subgraph = nil
    }

    init(product: Product) {
        self.init(id: "product:\(product.name)", title: product.name, border: .doubled, subgraph: nil)
    }

    init(target: Module) {
        self.init(id: "target:\(target.name)", title: target.name)
    }

    init(dependency: Module.Dependency) {
        switch dependency {
        case let .product(product, _):
            self.init(
                id: product.name,
                title: product.name,
                border: .hexagon,
                subgraph: product.package
            )
        case let .module(target, _):
            self.init(target: target)
        }
    }
}

extension MermaidPackageSerializer.Node: CustomStringConvertible {
    var description: String {
        "\(self.id)\(self.border.added(to: self.title))"
    }
}

extension MermaidPackageSerializer.Edge {
    init(product: Product, target: Module) {
        self.from = .init(product: product)
        self.to = .init(target: target)
    }
}

extension MermaidPackageSerializer.Edge: CustomStringConvertible {
    var description: String {
        "\(self.from.description)-->\(self.to.description)"
    }
}

extension [Product] {
    fileprivate var productTargetEdges: [MermaidPackageSerializer.Edge] {
        self.flatMap { product in
            product.modules.map { target in (product, target) }
        }.map(MermaidPackageSerializer.Edge.init)
    }
}

extension [Module] {
    fileprivate var targetDependencyEdges: [MermaidPackageSerializer.Edge] {
        self.flatMap { target in
            target.dependencies.map {
                let dependencyNode = MermaidPackageSerializer.Node(dependency: $0)

                return .init(
                    from: .init(target: target),
                    to: dependencyNode
                )
            }
        }
    }
}

