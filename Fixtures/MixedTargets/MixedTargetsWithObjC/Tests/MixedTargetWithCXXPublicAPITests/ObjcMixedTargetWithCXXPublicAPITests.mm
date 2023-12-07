#import <XCTest/XCTest.h>

#if TEST_MODULE_IMPORTS
@import MixedTargetWithCXXPublicAPI;
#else
#import "CXXSumFinder.hpp"
#import "ObjcCalculator.h"
#import "MixedTargetWithCXXPublicAPI-Swift.h"
#endif // TEST_MODULE_IMPORTS

@interface ObjcMixedTargetWithCXXPublicAPITests : XCTestCase
@end

@implementation ObjcMixedTargetWithCXXPublicAPITests

- (void)testPublicObjcAPI {
    XCTAssertEqual([ObjcCalculator factorialForInt:5], 120);
    XCTAssertEqual([ObjcCalculator sumX:1 andY:2], 3);
}

- (void)testPublicSwiftAPI {
    XCTAssertEqualObjects([Factorial text], @"Hello, World!");
}

- (void)testPublicCXXAPI {
    CXXSumFinder sf;
    XCTAssertEqual(sf.sum(1,2), 3);
}

@end

