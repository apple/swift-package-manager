#import <XCTest/XCTest.h>

#if TEST_MODULE_IMPORTS
@import MixedTargetWithCXXPublicAPIAndCustomModuleMap;
#else
#import "XYZCxxSumFinder.hpp"
#import "XYZObjcCalculator.h"
#import "MixedTargetWithCXXPublicAPIAndCustomModuleMap-Swift.h"
#endif // TEST_MODULE_IMPORTS

@interface ObjcMixedTargetWithCXXPublicAPIAndCustomModuleMapTests : XCTestCase
@end

@implementation ObjcMixedTargetWithCXXPublicAPIAndCustomModuleMapTests

- (void)testPublicObjcAPI {
    XCTAssertEqual([XYZObjcCalculator factorialForInt:5], 120);
    XCTAssertEqual([XYZObjcCalculator sumX:1 andY:2], 3);
}

- (void)testPublicSwiftAPI {
    XCTAssertEqualObjects([Factorial text], @"Hello, World!");
}

- (void)testPublicCXXAPI {
    XYZCxxSumFinder sf;
    XCTAssertEqual(sf.sum(1,2), 3);
}

@end
