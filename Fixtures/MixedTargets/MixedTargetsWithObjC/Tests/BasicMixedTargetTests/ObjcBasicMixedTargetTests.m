#import <XCTest/XCTest.h>

#if TEST_MODULE_IMPORTS
@import BasicMixedTarget;
#else
#import "CarPart.h"
#import "Driver.h"
#import "OldCar.h"
#import "BasicMixedTarget-Swift.h"
#endif // TEST_MODULE_IMPORTS

@interface ObjcBasicMixedTargetTests : XCTestCase
@end

@implementation ObjcBasicMixedTargetTests

- (void)testPublicSwiftAPI {
    // Check that Objective-C compatible Swift API surface is exposed...
    Engine *engine = [[Engine alloc] init];
}

- (void)testPublicObjcAPI {
    // Check that Objective-C API surface is exposed...
    OldCar *oldCar = [[OldCar alloc] init];
    Driver *driver = [[Driver alloc] init];
    CarPart *carPart = [[CarPart alloc] init];
}

@end
