/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import SwiftSyntax
import TSCBasic
import TSCUtility
import PackageModel

/// A package manifest rewriter.
///
/// This class provides functionality for rewriting the
/// Swift package manifest using the SwiftSyntax library.
///
/// Similar to SwiftSyntax, this class only deals with the
/// syntax and has no functionality for semantics of the manifest.
public final class ManifestRewriter {

    /// The contents of the original manifest.
    public let originalManifest: String

    /// The contents of the edited manifest.
    public var editedManifest: String {
        return editedSource.description
    }

    /// The edited manifest syntax.
    private var editedSource: SourceFileSyntax

    /// Engine used to report manifest rewrite failures.
    private let diagnosticsEngine: DiagnosticsEngine

    /// Create a new manfiest editor with the given contents.
    public init(_ manifest: String, diagnosticsEngine: DiagnosticsEngine) throws {
        self.originalManifest = manifest
        self.diagnosticsEngine = diagnosticsEngine
        self.editedSource = try SyntaxParser.parse(source: manifest)
    }

    /// Add a package dependency.
    public func addPackageDependency(
        name: String?,
        url: String,
        requirement: PackageDependencyRequirement,
        branchAndRevisionConvenienceMethodsSupported: Bool
    ) throws {
        let initFnExpr = try findPackageInit()

        // Find dependencies section in the argument list of Package(...).
        let packageDependenciesFinder = ArrayExprArgumentFinder(expectedLabel: "dependencies")
        packageDependenciesFinder.walk(initFnExpr.argumentList)

        let packageDependencies: ArrayExprSyntax
        switch packageDependenciesFinder.result {
        case .found(let existingPackageDependencies):
            packageDependencies = existingPackageDependencies
        case .missing:
            // We didn't find a dependencies section, so insert one.
            let argListWithDependencies = EmptyArrayArgumentWriter(argumentLabel: "dependencies",
                                                                   followingArgumentLabels:
                                                                   "targets",
                                                                   "swiftLanguageVersions",
                                                                   "cLanguageStandard",
                                                                   "cxxLanguageStandard")
                .visit(initFnExpr.argumentList)

            // Find the inserted section.
            let packageDependenciesFinder = ArrayExprArgumentFinder(expectedLabel: "dependencies")
            packageDependenciesFinder.walk(argListWithDependencies)
            guard case .found(let newPackageDependencies) = packageDependenciesFinder.result else {
                fatalError("Could not find just inserted dependencies array")
            }
            packageDependencies = newPackageDependencies
        case .incompatibleExpr:
            diagnosticsEngine.emit(.incompatibleArgument(name: "targets"))
            throw Diagnostics.fatalError
        }

        // Add the the package dependency entry.
        let newManifest = PackageDependencyWriter(
            name: name,
            url: url,
            requirement: requirement,
            branchAndRevisionConvenienceMethodsSupported: branchAndRevisionConvenienceMethodsSupported
        ).visit(packageDependencies).root

        self.editedSource = newManifest.as(SourceFileSyntax.self)!
    }

    /// Add a target dependency.
    public func addByNameTargetDependency(
        target: String,
        dependency: String
    ) throws {
        let targetDependencies = try findTargetDependenciesArrayExpr(target: target)

        // Add the target dependency entry.
        let newManifest = targetDependencies.withAdditionalElementExpr(ExprSyntax(
            SyntaxFactory.makeStringLiteralExpr(dependency)
        )).root

        self.editedSource = newManifest.as(SourceFileSyntax.self)!
    }

    public func addProductTargetDependency(
        target: String,
        product: String,
        package: String
    ) throws {
        let targetDependencies = try findTargetDependenciesArrayExpr(target: target)

        let dotProductExpr = SyntaxFactory.makeMemberAccessExpr(base: nil,
                                                                dot: SyntaxFactory.makePeriodToken(),
                                                                name: SyntaxFactory.makeIdentifier("product"),
                                                                declNameArguments: nil)

        let argumentList = SyntaxFactory.makeTupleExprElementList([
            SyntaxFactory.makeTupleExprElement(label: SyntaxFactory.makeIdentifier("name"),
                                               colon: SyntaxFactory.makeColonToken(trailingTrivia: .spaces(1)),
                                               expression: ExprSyntax(SyntaxFactory.makeStringLiteralExpr(product)),
                                               trailingComma: SyntaxFactory.makeCommaToken(trailingTrivia: .spaces(1))),
            SyntaxFactory.makeTupleExprElement(label: SyntaxFactory.makeIdentifier("package"),
                                               colon: SyntaxFactory.makeColonToken(trailingTrivia: .spaces(1)),
                                               expression: ExprSyntax(SyntaxFactory.makeStringLiteralExpr(package)),
                                               trailingComma: nil)
        ])

        let callExpr = SyntaxFactory.makeFunctionCallExpr(calledExpression: ExprSyntax(dotProductExpr),
                                                          leftParen: SyntaxFactory.makeLeftParenToken(),
                                                          argumentList: argumentList,
                                                          rightParen: SyntaxFactory.makeRightParenToken(),
                                                          trailingClosure: nil,
                                                          additionalTrailingClosures: nil)

        // Add the target dependency entry.
        let newManifest = targetDependencies.withAdditionalElementExpr(ExprSyntax(callExpr)).root
        self.editedSource = newManifest.as(SourceFileSyntax.self)!
    }

    private func findTargetDependenciesArrayExpr(target: String) throws -> ArrayExprSyntax {
        let initFnExpr = try findPackageInit()

        // Find the `targets: []` array.
        let targetsArrayFinder = ArrayExprArgumentFinder(expectedLabel: "targets")
        targetsArrayFinder.walk(initFnExpr.argumentList)
        guard case .found(let targetsArrayExpr) = targetsArrayFinder.result else {
            diagnosticsEngine.emit(.missingPackageInitArgument(name: "targets"))
            throw Diagnostics.fatalError
        }

        // Find the target node.
        let targetFinder = NamedEntityArgumentListFinder(name: target)
        targetFinder.walk(targetsArrayExpr)
        guard let targetNode = targetFinder.foundEntity else {
            diagnosticsEngine.emit(.missingTarget(name: target))
            throw Diagnostics.fatalError
        }

        let targetDependencyFinder = ArrayExprArgumentFinder(expectedLabel: "dependencies")
        targetDependencyFinder.walk(targetNode)

        guard case .found(let targetDependencies) = targetDependencyFinder.result else {
            diagnosticsEngine.emit(.missingArgument(name: "dependencies", parent: "target '\(target)'"))
            throw Diagnostics.fatalError
        }
        return targetDependencies
    }

    /// Add a new target.
    public func addTarget(
        targetName: String,
        factoryMethodName: String
    ) throws {
        let initFnExpr = try findPackageInit()
        let targetsNode = try findOrCreateTargetsList(in: initFnExpr)

        let dotTargetExpr = SyntaxFactory.makeMemberAccessExpr(
            base: nil,
            dot: SyntaxFactory.makePeriodToken(),
            name: SyntaxFactory.makeIdentifier(factoryMethodName),
            declNameArguments: nil
        )

        let nameArg = SyntaxFactory.makeTupleExprElement(
            label: SyntaxFactory.makeIdentifier("name"),
            colon: SyntaxFactory.makeColonToken(trailingTrivia: .spaces(1)),
            expression: ExprSyntax(SyntaxFactory.makeStringLiteralExpr(targetName)),
            trailingComma: SyntaxFactory.makeCommaToken()
        )

        let emptyArray = SyntaxFactory.makeArrayExpr(leftSquare: SyntaxFactory.makeLeftSquareBracketToken(), elements: SyntaxFactory.makeBlankArrayElementList(), rightSquare: SyntaxFactory.makeRightSquareBracketToken())
        let depenenciesArg = SyntaxFactory.makeTupleExprElement(
            label: SyntaxFactory.makeIdentifier("dependencies"),
            colon: SyntaxFactory.makeColonToken(trailingTrivia: .spaces(1)),
            expression: ExprSyntax(emptyArray),
            trailingComma: nil
        )

        let expr = SyntaxFactory.makeFunctionCallExpr(
            calledExpression: ExprSyntax(dotTargetExpr),
            leftParen: SyntaxFactory.makeLeftParenToken(),
            argumentList: SyntaxFactory.makeTupleExprElementList([
                nameArg, depenenciesArg,
            ]),
            rightParen: SyntaxFactory.makeRightParenToken(),
            trailingClosure: nil,
            additionalTrailingClosures: nil
        )

        let newManifest = targetsNode
            .withAdditionalElementExpr(ExprSyntax(expr))
            .reindentingLastCallExprElement()
            .root

        self.editedSource = newManifest.as(SourceFileSyntax.self)!
    }

    public func addBinaryTarget(targetName: String,
                                urlOrPath: String,
                                checksum: String?) throws {
        let initFnExpr = try findPackageInit()
        let targetsNode = try findOrCreateTargetsList(in: initFnExpr)

        let dotTargetExpr = SyntaxFactory.makeMemberAccessExpr(
            base: nil,
            dot: SyntaxFactory.makePeriodToken(),
            name: SyntaxFactory.makeIdentifier("binaryTarget"),
            declNameArguments: nil
        )

        var args: [TupleExprElementSyntax] = []

        let nameArg = SyntaxFactory.makeTupleExprElement(
            label: SyntaxFactory.makeIdentifier("name"),
            colon: SyntaxFactory.makeColonToken(trailingTrivia: .spaces(1)),
            expression: ExprSyntax(SyntaxFactory.makeStringLiteralExpr(targetName)),
            trailingComma: SyntaxFactory.makeCommaToken()
        )
        args.append(nameArg)

        if TSCUtility.URL.scheme(urlOrPath) == nil {
            guard checksum == nil else {
                diagnosticsEngine.emit(.unexpectedChecksumForBinaryTarget(path: urlOrPath))
                throw Diagnostics.fatalError
            }

            let pathArg = SyntaxFactory.makeTupleExprElement(
                label: SyntaxFactory.makeIdentifier("path"),
                colon: SyntaxFactory.makeColonToken(trailingTrivia: .spaces(1)),
                expression: ExprSyntax(SyntaxFactory.makeStringLiteralExpr(urlOrPath)),
                trailingComma: nil
            )
            args.append(pathArg)
        } else {
            guard let checksum = checksum else {
                diagnosticsEngine.emit(.missingChecksumForBinaryTarget(url: urlOrPath))
                throw Diagnostics.fatalError
            }

            let urlArg = SyntaxFactory.makeTupleExprElement(
                label: SyntaxFactory.makeIdentifier("url"),
                colon: SyntaxFactory.makeColonToken(trailingTrivia: .spaces(1)),
                expression: ExprSyntax(SyntaxFactory.makeStringLiteralExpr(urlOrPath)),
                trailingComma: SyntaxFactory.makeCommaToken()
            )
            args.append(urlArg)

            let checksumArg = SyntaxFactory.makeTupleExprElement(
                label: SyntaxFactory.makeIdentifier("checksum"),
                colon: SyntaxFactory.makeColonToken(trailingTrivia: .spaces(1)),
                expression: ExprSyntax(SyntaxFactory.makeStringLiteralExpr(checksum)),
                trailingComma: nil
            )
            args.append(checksumArg)
        }

        let expr = SyntaxFactory.makeFunctionCallExpr(
            calledExpression: ExprSyntax(dotTargetExpr),
            leftParen: SyntaxFactory.makeLeftParenToken(),
            argumentList: SyntaxFactory.makeTupleExprElementList(args),
            rightParen: SyntaxFactory.makeRightParenToken(),
          trailingClosure: nil,
          additionalTrailingClosures: nil
        )

        let newManifest = targetsNode
            .withAdditionalElementExpr(ExprSyntax(expr))
            .reindentingLastCallExprElement()
            .root

        self.editedSource = newManifest.as(SourceFileSyntax.self)!
    }

    // Add a new product.
    public func addProduct(name: String, type: ProductType) throws {
        let initFnExpr = try findPackageInit()

        let productsFinder = ArrayExprArgumentFinder(expectedLabel: "products")
        productsFinder.walk(initFnExpr.argumentList)
        let productsNode: ArrayExprSyntax

        switch productsFinder.result {
        case .found(let existingProducts):
            productsNode = existingProducts
        case .missing:
            // We didn't find a products section, so insert one.
            let argListWithProducts = EmptyArrayArgumentWriter(argumentLabel: "products",
                                                               followingArgumentLabels:
                                                               "dependencies",
                                                               "targets",
                                                               "swiftLanguageVersions",
                                                               "cLanguageStandard",
                                                               "cxxLanguageStandard")
                .visit(initFnExpr.argumentList)

            // Find the inserted section.
            let productsFinder = ArrayExprArgumentFinder(expectedLabel: "products")
            productsFinder.walk(argListWithProducts)
            guard case .found(let newProducts) = productsFinder.result else {
                fatalError("Could not find just inserted products array")
            }
            productsNode = newProducts
        case .incompatibleExpr:
            diagnosticsEngine.emit(.incompatibleArgument(name: "products"))
            throw Diagnostics.fatalError
        }

        let newManifest = NewProductWriter(
            name: name, type: type
        ).visit(productsNode).root

        self.editedSource = newManifest.as(SourceFileSyntax.self)!
    }

    // Add a target to a product.
    public func addProductTarget(product: String, target: String) throws {
        let initFnExpr = try findPackageInit()

        // Find the `products: []` array.
        let productsArrayFinder = ArrayExprArgumentFinder(expectedLabel: "products")
        productsArrayFinder.walk(initFnExpr.argumentList)
        guard case .found(let productsArrayExpr) = productsArrayFinder.result else {
            diagnosticsEngine.emit(.missingPackageInitArgument(name: "products"))
            throw Diagnostics.fatalError
        }

        // Find the product node.
        let productFinder = NamedEntityArgumentListFinder(name: product)
        productFinder.walk(productsArrayExpr)
        guard let productNode = productFinder.foundEntity else {
            diagnosticsEngine.emit(.missingProduct(name: product))
            throw Diagnostics.fatalError
        }

        let productTargetsFinder = ArrayExprArgumentFinder(expectedLabel: "targets")
        productTargetsFinder.walk(productNode)

        guard case .found(let productTargets) = productTargetsFinder.result else {
            diagnosticsEngine.emit(.missingArgument(name: "targets", parent: "product '\(product)'"))
            throw Diagnostics.fatalError
        }

        let newManifest = productTargets.withAdditionalElementExpr(ExprSyntax(
            SyntaxFactory.makeStringLiteralExpr(target)
        )).root

        self.editedSource = newManifest.as(SourceFileSyntax.self)!
    }

    private func findOrCreateTargetsList(in packageInitExpr: FunctionCallExprSyntax) throws -> ArrayExprSyntax {
        let targetsFinder = ArrayExprArgumentFinder(expectedLabel: "targets")
        targetsFinder.walk(packageInitExpr.argumentList)

        let targetsNode: ArrayExprSyntax
        switch targetsFinder.result {
        case .found(let existingTargets):
            targetsNode = existingTargets
        case .missing:
            // We didn't find a targets section, so insert one.
            let argListWithTargets = EmptyArrayArgumentWriter(argumentLabel: "targets",
                                                              followingArgumentLabels:
                                                              "swiftLanguageVersions",
                                                              "cLanguageStandard",
                                                              "cxxLanguageStandard")
                .visit(packageInitExpr.argumentList)

            // Find the inserted section.
            let targetsFinder = ArrayExprArgumentFinder(expectedLabel: "targets")
            targetsFinder.walk(argListWithTargets)
            guard case .found(let newTargets) = targetsFinder.result else {
                fatalError("Could not find just-inserted targets array")
            }
            targetsNode = newTargets
        case .incompatibleExpr:
            diagnosticsEngine.emit(.incompatibleArgument(name: "targets"))
            throw Diagnostics.fatalError
        }

        return targetsNode
    }

    private func findPackageInit() throws -> FunctionCallExprSyntax {
        // Find Package initializer.
        let packageFinder = PackageInitFinder()
        packageFinder.walk(editedSource)
        switch packageFinder.result {
        case .found(let initFnExpr):
            return initFnExpr
        case .foundMultiple:
            diagnosticsEngine.emit(.multiplePackageInits)
            throw Diagnostics.fatalError
        case .missing:
            diagnosticsEngine.emit(.missingPackageInit)
            throw Diagnostics.fatalError
        }
    }
}

// MARK: - Syntax Visitors

/// Package init finder.
final class PackageInitFinder: SyntaxVisitor {

    enum Result {
        case found(FunctionCallExprSyntax)
        case foundMultiple
        case missing
    }

    /// Reference to the function call of the package initializer.
    private(set) var result: Result = .missing

    override func visit(_ node: InitializerClauseSyntax) -> SyntaxVisitorContinueKind {
        if let fnCall = FunctionCallExprSyntax(Syntax(node.value)),
            let identifier = fnCall.calledExpression.firstToken,
            identifier.text == "Package" {
            if case .missing = result {
                result = .found(fnCall)
            } else {
                result = .foundMultiple
            }
        }
        return .skipChildren
    }
}

/// Finder for an array expression used as or as part of a labeled argument.
final class ArrayExprArgumentFinder: SyntaxVisitor {

    enum Result {
        case found(ArrayExprSyntax)
        case missing
        case incompatibleExpr
    }

    private(set) var result: Result
    private let expectedLabel: String

    init(expectedLabel: String) {
        self.expectedLabel = expectedLabel
        self.result = .missing
        super.init()
    }

    override func visit(_ node: TupleExprElementSyntax) -> SyntaxVisitorContinueKind {
        guard node.label?.text == expectedLabel else {
            return .skipChildren
        }

        // We have custom code like foo + bar + [] (hopefully there is an array expr here).
        if let seq = node.expression.as(SequenceExprSyntax.self),
           let arrayExpr = seq.elements.first(where: { $0.is(ArrayExprSyntax.self) })?.as(ArrayExprSyntax.self) {
            result = .found(arrayExpr)
        } else if let arrayExpr = node.expression.as(ArrayExprSyntax.self) {
            result = .found(arrayExpr)
        } else {
            result = .incompatibleExpr
        }

        return .skipChildren
    }
}

/// Given an Array expression of call expressions, find the argument list of the call
/// expression with the specified `name` argument.
final class NamedEntityArgumentListFinder: SyntaxVisitor {

    let entityToFind: String
    private(set) var foundEntity: TupleExprElementListSyntax?

    init(name: String) {
        self.entityToFind = name
    }

    override func visit(_ node: TupleExprElementSyntax) -> SyntaxVisitorContinueKind {
        guard case .identifier(let label)? = node.label?.tokenKind else {
            return .skipChildren
        }
        guard label == "name", let targetNameExpr = node.expression.as(StringLiteralExprSyntax.self),
              targetNameExpr.segments.count == 1, let segment = targetNameExpr.segments.first?.as(StringSegmentSyntax.self) else {
            return .skipChildren
        }

        guard case .stringSegment(let name) = segment.content.tokenKind else {
            return .skipChildren
        }

        if name == self.entityToFind {
            self.foundEntity = node.parent?.as(TupleExprElementListSyntax.self)
            return .skipChildren
        }

        return .skipChildren
    }
}

// MARK: - Syntax Rewriters

/// Writer for an empty array argument.
final class EmptyArrayArgumentWriter: SyntaxRewriter {
    let argumentLabel: String
    let followingArgumentLabels: Set<String>

    init(argumentLabel: String, followingArgumentLabels: String...) {
        self.argumentLabel = argumentLabel
        self.followingArgumentLabels = .init(followingArgumentLabels)
    }

    override func visit(_ node: TupleExprElementListSyntax) -> Syntax {
        let leadingTrivia = node.firstToken?.leadingTrivia ?? .zero

        let existingLabels = node.map(\.label?.text)
        let insertionIndex = existingLabels.firstIndex {
            followingArgumentLabels.contains($0 ?? "")
        } ?? existingLabels.endIndex

        let dependenciesArg = SyntaxFactory.makeTupleExprElement(
            label: SyntaxFactory.makeIdentifier(argumentLabel, leadingTrivia: leadingTrivia),
            colon: SyntaxFactory.makeColonToken(trailingTrivia: .spaces(1)),
            expression: ExprSyntax(SyntaxFactory.makeArrayExpr(
                                    leftSquare: SyntaxFactory.makeLeftSquareBracketToken(),
                                    elements: SyntaxFactory.makeBlankArrayElementList(),
                                    rightSquare: SyntaxFactory.makeRightSquareBracketToken())),
            trailingComma: insertionIndex != existingLabels.endIndex ? SyntaxFactory.makeCommaToken() : nil
        )

        var newNode = node
        if let lastArgument = newNode.last,
           insertionIndex == existingLabels.endIndex {
            // If the new argument is being added at the end of the list, the argument before it needs a comma.
            newNode = newNode.replacing(childAt: newNode.count-1,
                                        with: lastArgument.withTrailingComma(SyntaxFactory.makeCommaToken()))
        }
        
        return Syntax(newNode.inserting(dependenciesArg, at: insertionIndex))
    }
}

/// Package dependency writer.
final class PackageDependencyWriter: SyntaxRewriter {

    /// The dependency name to write.
    let name: String?

    /// The dependency url to write.
    let url: String

    /// The dependency requirement.
    let requirement: PackageDependencyRequirement

    /// Whether convenience methods for branch and revision dependencies are supported.
    let branchAndRevisionConvenienceMethodsSupported: Bool

    init(name: String?,
         url: String,
         requirement: PackageDependencyRequirement,
         branchAndRevisionConvenienceMethodsSupported: Bool) {
        self.name = name
        self.url = url
        self.requirement = requirement
        self.branchAndRevisionConvenienceMethodsSupported = branchAndRevisionConvenienceMethodsSupported
    }

    override func visit(_ node: ArrayExprSyntax) -> ExprSyntax {

        let dotPackageExpr = SyntaxFactory.makeMemberAccessExpr(
            base: nil,
            dot: SyntaxFactory.makePeriodToken(),
            name: SyntaxFactory.makeIdentifier("package"),
            declNameArguments: nil
        )

        var args: [TupleExprElementSyntax] = []

        if let name = self.name {
            let nameArg = SyntaxFactory.makeTupleExprElement(
                label: SyntaxFactory.makeIdentifier("name"),
                colon: SyntaxFactory.makeColonToken(trailingTrivia: .spaces(1)),
                expression: ExprSyntax(SyntaxFactory.makeStringLiteralExpr(name)),
                trailingComma: SyntaxFactory.makeCommaToken(trailingTrivia: .spaces(1))
            )
            args.append(nameArg)
        }

        let locationArgLabel = requirement == .localPackage ? "path" : "url"
        let locationArg = SyntaxFactory.makeTupleExprElement(
            label: SyntaxFactory.makeIdentifier(locationArgLabel),
            colon: SyntaxFactory.makeColonToken(trailingTrivia: .spaces(1)),
            expression: ExprSyntax(SyntaxFactory.makeStringLiteralExpr(self.url)),
            trailingComma: requirement == .localPackage ? nil : SyntaxFactory.makeCommaToken(trailingTrivia: .spaces(1))
        )
        args.append(locationArg)

        let addUnlabeledImplicitMemberCallWithStringArg = { (baseName: String, argumentLabel: String?, argumentString: String) in
            let memberExpr = SyntaxFactory.makeMemberAccessExpr(base: nil,
                                                                dot: SyntaxFactory.makePeriodToken(),
                                                                name: SyntaxFactory.makeIdentifier(baseName),
                                                                declNameArguments: nil)
            let argList = SyntaxFactory.makeTupleExprElementList([
                SyntaxFactory.makeTupleExprElement(label: argumentLabel.map { SyntaxFactory.makeIdentifier($0) },
                                                   colon: argumentLabel.map { _ in SyntaxFactory.makeColonToken(trailingTrivia: .spaces(1)) },
                                                   expression: ExprSyntax(SyntaxFactory.makeStringLiteralExpr(argumentString)),
                                                   trailingComma: nil)
            ])
            let exactExpr = SyntaxFactory.makeFunctionCallExpr(calledExpression: ExprSyntax(memberExpr),
                                                               leftParen: SyntaxFactory.makeLeftParenToken(),
                                                               argumentList: argList,
                                                               rightParen: SyntaxFactory.makeRightParenToken(),
                                                               trailingClosure: nil,
                                                               additionalTrailingClosures: nil)
            let exactArg = SyntaxFactory.makeTupleExprElement(label: nil,
                                                              colon: nil,
                                                              expression: ExprSyntax(exactExpr),
                                                              trailingComma: nil)
            args.append(exactArg)
        }

        let addUnlabeledRangeArg = { (start: String, end: String, rangeOperator: String) in
            let rangeExpr = SyntaxFactory.makeSequenceExpr(elements: SyntaxFactory.makeExprList([
                ExprSyntax(SyntaxFactory.makeStringLiteralExpr(start)),
                ExprSyntax(SyntaxFactory.makeBinaryOperatorExpr(
                            operatorToken: SyntaxFactory.makeUnspacedBinaryOperator(rangeOperator))
                ),
                ExprSyntax(SyntaxFactory.makeStringLiteralExpr(end))
            ]))
            let arg = SyntaxFactory.makeTupleExprElement(label: nil,
                                                         colon: nil,
                                                         expression: ExprSyntax(rangeExpr),
                                                         trailingComma: nil)
            args.append(arg)
        }

        let addLabeledStringArg = { (label: String, literalString: String) in
            let arg = SyntaxFactory.makeTupleExprElement(label: SyntaxFactory.makeIdentifier(label),
                                                         colon: SyntaxFactory.makeColonToken(trailingTrivia: .spaces(1)),
                                                         expression: ExprSyntax(SyntaxFactory.makeStringLiteralExpr(literalString)),
                                                         trailingComma: nil)
            args.append(arg)
        }

        switch requirement {
        case .exact(let version):
            addUnlabeledImplicitMemberCallWithStringArg("exact", nil, version)
        case .revision(let revision):
            if branchAndRevisionConvenienceMethodsSupported {
                addLabeledStringArg("revision", revision)
            } else {
                addUnlabeledImplicitMemberCallWithStringArg("revision", nil, revision)
            }
        case .branch(let branch):
            if branchAndRevisionConvenienceMethodsSupported {
                addLabeledStringArg("branch", branch)
            } else {
                addUnlabeledImplicitMemberCallWithStringArg("branch", nil, branch)
            }
        case .upToNextMajor(let version):
            addUnlabeledImplicitMemberCallWithStringArg("upToNextMajor", "from", version)
        case .upToNextMinor(let version):
            addUnlabeledImplicitMemberCallWithStringArg("upToNextMinor", "from", version)
        case .range(let start, let end):
            addUnlabeledRangeArg(start, end, "..<")
        case .closedRange(let start, let end):
            addUnlabeledRangeArg(start, end, "...")
        case .localPackage:
            break
        }

        let expr = SyntaxFactory.makeFunctionCallExpr(
            calledExpression: ExprSyntax(dotPackageExpr),
            leftParen: SyntaxFactory.makeLeftParenToken(),
            argumentList: SyntaxFactory.makeTupleExprElementList(args),
            rightParen: SyntaxFactory.makeRightParenToken(),
          trailingClosure: nil,
          additionalTrailingClosures: nil
        )

        return ExprSyntax(node.withAdditionalElementExpr(ExprSyntax(expr)))
    }
}

/// Writer for inserting a new product in a products array.
final class NewProductWriter: SyntaxRewriter {

    let name: String
    let type: ProductType

    init(name: String, type: ProductType) {
        self.name = name
        self.type = type
    }

    override func visit(_ node: ArrayExprSyntax) -> ExprSyntax {
        let dotExpr = SyntaxFactory.makeMemberAccessExpr(
            base: nil,
            dot: SyntaxFactory.makePeriodToken(),
            name: SyntaxFactory.makeIdentifier(type == .executable ? "executable" : "library"),
            declNameArguments: nil
        )

        var args: [TupleExprElementSyntax] = []

        let nameArg = SyntaxFactory.makeTupleExprElement(
            label: SyntaxFactory.makeIdentifier("name"),
            colon: SyntaxFactory.makeColonToken(trailingTrivia: .spaces(1)),
            expression: ExprSyntax(SyntaxFactory.makeStringLiteralExpr(name)),
            trailingComma: SyntaxFactory.makeCommaToken()
        )
        args.append(nameArg)

        if case .library(let kind) = type, kind != .automatic {
            let typeExpr = SyntaxFactory.makeMemberAccessExpr(base: nil,
                                                              dot: SyntaxFactory.makePeriodToken(),
                                                              name: SyntaxFactory.makeIdentifier(kind == .dynamic ? "dynamic" : "static"),
                                                              declNameArguments: nil)
            let typeArg = SyntaxFactory.makeTupleExprElement(
                label: SyntaxFactory.makeIdentifier("type"),
                colon: SyntaxFactory.makeColonToken(trailingTrivia: .spaces(1)),
                expression: ExprSyntax(typeExpr),
                trailingComma: SyntaxFactory.makeCommaToken()
            )
            args.append(typeArg)
        }

        let emptyArray = SyntaxFactory.makeArrayExpr(leftSquare: SyntaxFactory.makeLeftSquareBracketToken(),
                                                     elements: SyntaxFactory.makeBlankArrayElementList(),
                                                     rightSquare: SyntaxFactory.makeRightSquareBracketToken())
        let targetsArg = SyntaxFactory.makeTupleExprElement(
            label: SyntaxFactory.makeIdentifier("targets"),
            colon: SyntaxFactory.makeColonToken(trailingTrivia: .spaces(1)),
            expression: ExprSyntax(emptyArray),
            trailingComma: nil
        )
        args.append(targetsArg)

        let expr = SyntaxFactory.makeFunctionCallExpr(
            calledExpression: ExprSyntax(dotExpr),
            leftParen: SyntaxFactory.makeLeftParenToken(),
            argumentList: SyntaxFactory.makeTupleExprElementList(args),
            rightParen: SyntaxFactory.makeRightParenToken(),
          trailingClosure: nil,
          additionalTrailingClosures: nil
        )

        return ExprSyntax(node
                            .withAdditionalElementExpr(ExprSyntax(expr))
                            .reindentingLastCallExprElement())
    }
}

private extension TSCBasic.Diagnostic.Message {
    static var missingPackageInit: Self =
        .error("couldn't find Package initializer")
    static var multiplePackageInits: Self =
        .error("found multiple Package initializers")
    static func missingPackageInitArgument(name: String) -> Self {
        .error("couldn't find '\(name)' argument in Package initializer")
    }
    static func missingArgument(name: String, parent: String) -> Self {
        .error("couldn't find '\(name)' argument of \(parent)")
    }
    static func incompatibleArgument(name: String) -> Self {
        .error("'\(name)' argument is not an array literal or concatenation of array literals")
    }
    static func missingProduct(name: String) -> Self {
        .error("couldn't find product '\(name)'")
    }
    static func missingTarget(name: String) -> Self {
        .error("couldn't find target '\(name)'")
    }
    static func unexpectedChecksumForBinaryTarget(path: String) -> Self {
        .error("'\(path)' is a local path, but a checksum was specified for the binary target")
    }
    static func missingChecksumForBinaryTarget(url: String) -> Self {
        .error("'\(url)' is a remote URL, but no checksum was specified for the binary target")
    }
}
