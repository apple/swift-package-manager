#import <XCTest/XCTest.h>

// Import test helper defined in Swift.
#import "MixedTestTargetWithSharedUtilitiesTests-Swift.h"
// Import test helpers defined in Objective-C.
#import "ObjcTestHelper.h"
#import "Subdirectory1/Subdirectory2/OtherObjcTestHelper.h"

@interface ObjcMixedTargetTests : XCTestCase

@end

@implementation ObjcMixedTargetTests

- (void)testSwiftUtilityIsVisible {
    SwiftTestHelper *helper = [[SwiftTestHelper alloc] init];
}

- (void)testObjcUtilityIsVisibile {
    ObjcTestHelper *helper = [[ObjcTestHelper alloc] init];
}

@end
