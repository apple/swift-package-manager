#import <XCTest/XCTest.h>

@import MixedTargetWithNoPublicObjectiveCHeaders;

@interface ObjcMixedTargetWithNoPublicObjectiveCHeadersTests : XCTestCase

@end

@implementation ObjcMixedTargetWithNoPublicObjectiveCHeadersTests

- (void)testPublicSwiftAPI {
    // Check that Objective-C compatible Swift API surface is exposed...
    Bar *bar = [[Bar alloc] init];
}

#if EXPECT_FAILURE
- (void)testObjcAPI {
    // No Objective-C API surface should be exposed...
    OnLoadHook *onLoadHook = [[OnLoadHook alloc] init];
}
#endif

@end
