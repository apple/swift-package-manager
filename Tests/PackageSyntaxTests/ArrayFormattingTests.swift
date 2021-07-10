/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import XCTest
import PackageSyntax
import SwiftSyntax

final class ArrayFormattingTests: XCTestCase {
    func assertAdding(string: String, to arrayLiteralCode: String, produces result: String) {
        let sourceFileSyntax = try! SyntaxParser.parse(source: arrayLiteralCode)
        let arrayExpr = sourceFileSyntax.statements.first?.item.as(ArrayExprSyntax.self)!
        let outputSyntax = arrayExpr?.withAdditionalElementExpr(ExprSyntax(SyntaxFactory.makeStringLiteralExpr(string)))
        XCTAssertEqual(outputSyntax!.description, result)
    }

    func assertAdding(string: String, toFunctionCallArg functionCallCode: String, produces result: String) {
        let sourceFileSyntax = try! SyntaxParser.parse(source: functionCallCode)
        let funcExpr = sourceFileSyntax.statements.first!.item.as(FunctionCallExprSyntax.self)!
        let arg = funcExpr.argumentList.first!
        let arrayExpr = arg.expression.as(ArrayExprSyntax.self)!
        let newExpr = arrayExpr.withAdditionalElementExpr(ExprSyntax(SyntaxFactory.makeStringLiteralExpr(string)))
        let outputSyntax = funcExpr.withArgumentList(
            funcExpr.argumentList.replacing(childAt: 0,
                                            with: arg.withExpression(ExprSyntax(newExpr)))
        )
        XCTAssertEqual(outputSyntax.description, result)
    }

    func testInsertingIntoArrayExprWith2PlusElements() throws {
        assertAdding(string: "c", to: #"["a", "b"]"#, produces: #"["a", "b", "c",]"#)
        assertAdding(string: "c", to: #"["a", "b",]"#, produces: #"["a", "b", "c",]"#)
        assertAdding(string: "c", to: #"["a","b"]"#, produces: #"["a","b","c",]"#)
        assertAdding(string: "c",
                     to: #"["a", /*hello*/"b"/*world!*/]"#,
                     produces: #"["a", /*hello*/"b",/*world!*/ "c",]"#)
        assertAdding(string: "c", to: """
            [
                "a",
                "b"
            ]
        """, produces: """
            [
                "a",
                "b",
                "c",
            ]
        """)
        assertAdding(string: "c", to: """
            [
                "a",
                "b",
            ]
        """, produces: """
            [
                "a",
                "b",
                "c",
            ]
        """)
        assertAdding(string: "c", to: """
            [
                "a", "b"
            ]
        """, produces: """
            [
                "a", "b", "c",
            ]
        """)
        assertAdding(string: "e", to: """
            [
                "a", "b",
                "c", "d",
            ]
        """, produces: """
            [
                "a", "b",
                "c", "d", "e",
            ]
        """)
        assertAdding(string: "e", to: """
            ["a", "b",
             "c", "d"]
        """, produces: """
            ["a", "b",
             "c", "d", "e",]
        """)
        assertAdding(string: "c", to: """
        \t[
        \t\t"a",
        \t\t"b",
        \t]
        """, produces: """
        \t[
        \t\t"a",
        \t\t"b",
        \t\t"c",
        \t]
        """)
        assertAdding(string: "c", to: """
            [
                "a", // Comment about a
                "b",
            ]
        """, produces: """
            [
                "a", // Comment about a
                "b", 
                "c",
            ]
        """)
        assertAdding(string: "c", to: """
            [
                "a",
                "b", // Comment about b
            ]
        """, produces: """
            [
                "a",
                "b", // Comment about b
                "c",
            ]
        """)
        assertAdding(string: "c", to: """
            [
                "a",
                "b",
                /*comment*/
            ]
        """, produces: """
            [
                "a",
                "b",
                /*comment*/
                "c",
            ]
        """)
        assertAdding(string: "c", to: """
            [
                /*
                1
                */
                "a",
                /*
                2
                */
                "b",
                /*
                3
                */
            ]
        """, produces: """
            [
                /*
                1
                */
                "a",
                /*
                2
                */
                "b",
                /*
                3
                */
                "c",
            ]
        """)
        assertAdding(string: "c", to: """
            [
                /// Comment

                "a",


                "b",
            ]
        """, produces: """
            [
                /// Comment

                "a",


                "b",

        
                "c",
            ]
        """)
        assertAdding(string: "3", toFunctionCallArg: """
        foo(someArg: ["1", "2"])
        """, produces: """
        foo(someArg: ["1", "2", "3",])
        """)
        assertAdding(string: "3", toFunctionCallArg: """
            foo(someArg: ["1",
                          "2"])
        """, produces: """
            foo(someArg: ["1",
                          "2",
                          "3",])
        """)
        assertAdding(string: "3", toFunctionCallArg: """
                    foo(
                        arg1: ["1", "2"], arg2: []
                    )
        """, produces: """
                    foo(
                        arg1: ["1", "2", "3",], arg2: []
                    )
        """)
        assertAdding(string: "3", toFunctionCallArg: """
        foo(someArg: [
            "1",
            "2",
        ])
        """, produces: """
        foo(someArg: [
            "1",
            "2",
            "3",
        ])
        """)
        assertAdding(string: "3", toFunctionCallArg: """
                    foo(
                        arg1: [
                            "1",
                            "2",
                        ], arg2: []
                    )
        """, produces: """
                    foo(
                        arg1: [
                            "1",
                            "2",
                            "3",
                        ], arg2: []
                    )
        """)
    }

    func testInsertingIntoEmptyArrayExpr() {
        assertAdding(string: "1", to: #"[]"#, produces: """
        [
            "1",
        ]
        """)
        assertAdding(string: "1", to: """
        [

        ]
        """, produces: """
        [
            "1",
        ]
        """)
        assertAdding(string: "1", to: """
        [
        ]
        """, produces: """
        [
            "1",
        ]
        """)
        assertAdding(string: "1", to: """
            [

            ]
        """, produces: """
            [
                "1",
            ]
        """)
        assertAdding(string: "1", to: """
        \t[

        \t]
        """, produces: """
        \t[
        \t\t"1",
        \t]
        """)
        assertAdding(string: "1", toFunctionCallArg: """
        foo(someArg: [])
        """, produces: """
        foo(someArg: [
            "1",
        ])
        """)
        assertAdding(string: "1", toFunctionCallArg: """
            foo(someArg: [])
        """, produces: """
            foo(someArg: [
                "1",
            ])
        """)
        assertAdding(string: "1", toFunctionCallArg: """
                    foo(
                        arg1: [], arg2: []
                    )
        """, produces: """
                    foo(
                        arg1: [
                            "1",
                        ], arg2: []
                    )
        """)
        assertAdding(string: "1", toFunctionCallArg: """
        \tfoo(someArg: [])
        """, produces: """
        \tfoo(someArg: [
        \t\t"1",
        \t])
        """)
    }

    func testInsertingIntoSingleElementArrayExpr() {
        assertAdding(string: "b", to: """
        ["a"]
        """, produces: """
        [
            "a",
            "b",
        ]
        """)
        assertAdding(string: "b", to: """
        [
            "a"
        ]
        """, produces: """
        [
            "a",
            "b",
        ]
        """)
        assertAdding(string: "b", to: """
        ["a",]
        """, produces: """
        [
            "a",
            "b",
        ]
        """)
        assertAdding(string: "b", to: """
        [
            "a",
        ]
        """, produces: """
        [
            "a",
            "b",
        ]
        """)
        assertAdding(string: "2", toFunctionCallArg: """
        foo(someArg: ["1"])
        """, produces: """
        foo(someArg: [
            "1",
            "2",
        ])
        """)
        assertAdding(string: "2", toFunctionCallArg: """
            foo(someArg: ["1"])
        """, produces: """
            foo(someArg: [
                "1",
                "2",
            ])
        """)
        assertAdding(string: "2", toFunctionCallArg: """
                    foo(
                        arg1: ["1"], arg2: []
                    )
        """, produces: """
                    foo(
                        arg1: [
                            "1",
                            "2",
                        ], arg2: []
                    )
        """)
        assertAdding(string: "2", toFunctionCallArg: """
        foo(someArg: [
            "1"
        ])
        """, produces: """
        foo(someArg: [
            "1",
            "2",
        ])
        """)
        assertAdding(string: "2", toFunctionCallArg: """
            foo(someArg: [
                "1"
            ])
        """, produces: """
            foo(someArg: [
                "1",
                "2",
            ])
        """)
        assertAdding(string: "2", toFunctionCallArg: """
                    foo(
                        arg1: [
                            "1"
                        ], arg2: []
                    )
        """, produces: """
                    foo(
                        arg1: [
                            "1",
                            "2",
                        ], arg2: []
                    )
        """)
    }

    func assert(code: String, hasIndent indent: Trivia, forLine line: Int) {
        let sourceFileSyntax = try! SyntaxParser.parse(source: code)
        let converter = SourceLocationConverter(file: "test.swift", tree: sourceFileSyntax)
        let visitor = DetermineLineIndentVisitor(lineNumber: line, sourceLocationConverter: converter)
        visitor.walk(sourceFileSyntax)
        XCTAssertEqual(visitor.lineIndent, indent)
    }

    func testIndentVisitor() throws {
        assert(code: """
        foo(
            arg: []
        )
        """, hasIndent: [.spaces(4)], forLine: 2)
        assert(code: """
        foo(
        \targ: []
        )
        """, hasIndent: [.tabs(1)], forLine: 2)
        assert(code: """
        foo(
            arg1: [], arg2: []
        )
        """, hasIndent: [.spaces(4)], forLine: 2)
        assert(code: """
        foo(
            bar(
                arg1: [],
                arg2: []
            )
        )
        """, hasIndent: [.spaces(8)], forLine: 3)
        assert(code: """
        foo(
            bar(arg1: [],
                arg2: [])
        )
        """, hasIndent: [.spaces(4)], forLine: 2)
        assert(code: """
        foo(
            bar(arg1: [],
                arg2: [])
        )
        """, hasIndent: [.spaces(8)], forLine: 3)
    }
}
