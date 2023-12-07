#import <XCTest/XCTest.h>

@import MixedTargetWithCustomModuleMapAndResources;

@interface ObjcMixedTargetWithCustomModuleMapAndResourcesTests : XCTestCase
@end

@implementation ObjcMixedTargetWithCustomModuleMapAndResourcesTests

- (void)testPublicSwiftAPI {
    // Check that Objective-C compatible Swift API surface is exposed...
    Engine *engine = [[Engine alloc] init];
}

- (void)testPublicObjcAPI {
    // Check that Objective-C API surface is exposed...
    ABCOldCar *oldCar = [[ABCOldCar alloc] init];
    ABCDriver *driver = [[ABCDriver alloc] init];
}

@end
