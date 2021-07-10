/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import SwiftSyntax

extension ArrayExprSyntax {
    public func withAdditionalElementExpr(_ expr: ExprSyntax) -> ArrayExprSyntax {
        if self.elements.count >= 2 {
            // If the array expression has >=2 elements, use the trivia between
            // the last and second-to-last elements to determine how we insert
            // the new one.
            let lastElement = self.elements.last!
            let secondToLastElement = self.elements[self.elements.index(self.elements.endIndex, offsetBy: -2)]

            let newElements = self.elements
                .removingLast()
                .appending(
                    lastElement.withTrailingComma(
                        SyntaxFactory.makeCommaToken(
                            trailingTrivia: (lastElement.trailingTrivia ?? []) +
                                rightSquare.leadingTrivia.droppingPiecesAfterLastComment() +
                                (secondToLastElement.trailingTrivia ?? [])
                        )
                    )
                )
                .appending(
                    SyntaxFactory.makeArrayElement(
                        expression: expr,
                        trailingComma: SyntaxFactory.makeCommaToken()
                    ).withLeadingTrivia(lastElement.leadingTrivia?.droppingPiecesUpToAndIncludingLastComment() ?? [])
                )

            return self.withElements(newElements)
                .withRightSquare(
                    self.rightSquare.withLeadingTrivia(
                        self.rightSquare.leadingTrivia.droppingPiecesUpToAndIncludingLastComment()
                    )
                )
        } else {
            // For empty and single-element array exprs, we determine the indent
            // of the line the opening square bracket appears on, and then use
            // that to indent the added element and closing brace onto newlines.
            let (indentTrivia, unitIndent) = self.leftSquare.determineIndentOfStartingLine()
            var newElements: [ArrayElementSyntax] = []
            if !self.elements.isEmpty {
                let existingElement = self.elements.first!
                newElements.append(
                    SyntaxFactory.makeArrayElement(expression: existingElement.expression,
                                                   trailingComma: SyntaxFactory.makeCommaToken())
                        .withLeadingTrivia(indentTrivia + unitIndent)
                        .withTrailingTrivia((existingElement.trailingTrivia ?? []) + .newlines(1))
                )
            }

            newElements.append(
                SyntaxFactory.makeArrayElement(expression: expr, trailingComma: SyntaxFactory.makeCommaToken())
                    .withLeadingTrivia(indentTrivia + unitIndent)
            )

            return self.withLeftSquare(self.leftSquare.withTrailingTrivia(.newlines(1)))
                .withElements(SyntaxFactory.makeArrayElementList(newElements))
                .withRightSquare(self.rightSquare.withLeadingTrivia(.newlines(1) + indentTrivia))
        }
    }
}

extension ArrayExprSyntax {
    func reindentingLastCallExprElement() -> ArrayExprSyntax {
        let lastElement = elements.last!
        let (indent, unitIndent) = lastElement.determineIndentOfStartingLine()
        let formattingVisitor = MultilineArgumentListRewriter(indent: indent, unitIndent: unitIndent)
        let formattedLastElement = formattingVisitor.visit(lastElement).as(ArrayElementSyntax.self)!
        return self.withElements(elements.replacing(childAt: elements.count - 1, with: formattedLastElement))
    }
}

fileprivate extension TriviaPiece {
    var isComment: Bool {
        switch self {
        case .spaces, .tabs, .verticalTabs, .formfeeds, .newlines,
             .carriageReturns, .carriageReturnLineFeeds, .garbageText:
            return false
        case .lineComment, .blockComment, .docLineComment, .docBlockComment:
            return true
        }
    }

    var isHorizontalWhitespace: Bool {
        switch self {
        case .spaces, .tabs:
            return true
        default:
            return false
        }
    }

    var isSpaces: Bool {
        guard case .spaces = self else { return false }
        return true
    }

    var isTabs: Bool {
        guard case .tabs = self else { return false }
        return true
    }
}

fileprivate extension Trivia {
    func droppingPiecesAfterLastComment() -> Trivia {
        Trivia(pieces: .init(self.lazy.reversed().drop(while: { !$0.isComment }).reversed()))
    }

    func droppingPiecesUpToAndIncludingLastComment() -> Trivia {
        Trivia(pieces: .init(self.lazy.reversed().prefix(while: { !$0.isComment }).reversed()))
    }
}

extension SyntaxProtocol {
    func determineIndentOfStartingLine() -> (indent: Trivia, unitIndent: Trivia) {
        let sourceLocationConverter = SourceLocationConverter(file: "", tree: self.root.as(SourceFileSyntax.self)!)
        let line = startLocation(converter: sourceLocationConverter).line ?? 0
        let visitor = DetermineLineIndentVisitor(lineNumber: line, sourceLocationConverter: sourceLocationConverter)
        visitor.walk(self.root)
        return (indent: visitor.lineIndent, unitIndent: visitor.lineUnitIndent)
    }
}

public final class DetermineLineIndentVisitor: SyntaxVisitor {

    let lineNumber: Int
    let locationConverter: SourceLocationConverter
    private var bestMatch: TokenSyntax?

    public var lineIndent: Trivia {
        guard let pieces = bestMatch?.leadingTrivia
                .lazy
                .reversed()
                .prefix(while: \.isHorizontalWhitespace)
                .reversed() else { return .spaces(4) }
        return Trivia(pieces: Array(pieces))
    }

    public var lineUnitIndent: Trivia {
        if lineIndent.allSatisfy(\.isSpaces) {
            let addedSpaces = lineIndent.reduce(0, {
                guard case .spaces(let count) = $1 else { fatalError() }
                return $0 + count
            }) % 4 == 0 ? 4 : 2
            return .spaces(addedSpaces)
        } else if lineIndent.allSatisfy(\.isTabs) {
            return .tabs(1)
        } else {
            // If we can't determine the indent, default to 4 spaces.
            return .spaces(4)
        }
    }

    public init(lineNumber: Int, sourceLocationConverter: SourceLocationConverter) {
        self.lineNumber = lineNumber
        self.locationConverter = sourceLocationConverter
    }

    public override func visit(_ tokenSyntax: TokenSyntax) -> SyntaxVisitorContinueKind {
        let range = tokenSyntax.sourceRange(converter: locationConverter,
                                               afterLeadingTrivia: false,
                                               afterTrailingTrivia: true)
        guard let startLine = range.start.line,
              let endLine = range.end.line,
              let startColumn = range.start.column,
              let endColumn = range.end.column else {
            return .skipChildren
        }

        if (startLine, startColumn) <= (lineNumber, 1),
           (lineNumber, 1) <= (endLine, endColumn) {
            bestMatch = tokenSyntax
            return .visitChildren
        } else {
            return .skipChildren
        }
    }
}

/// Moves each argument to a function call expression onto a new line and indents them appropriately.
final class MultilineArgumentListRewriter: SyntaxRewriter {
    let indent: Trivia
    let unitIndent: Trivia

    init(indent: Trivia, unitIndent: Trivia) {
        self.indent = indent
        self.unitIndent = unitIndent
    }

    override func visit(_ token: TokenSyntax) -> Syntax {
        guard token.tokenKind == .rightParen else { return Syntax(token) }
        return Syntax(token.withLeadingTrivia(.newlines(1) + indent))
    }

    override func visit(_ node: TupleExprElementSyntax) -> Syntax {
        return Syntax(node.withLeadingTrivia(.newlines(1) + indent + unitIndent))
    }
}
