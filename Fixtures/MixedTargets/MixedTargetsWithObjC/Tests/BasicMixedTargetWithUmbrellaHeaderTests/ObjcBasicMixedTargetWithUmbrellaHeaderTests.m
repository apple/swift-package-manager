#import <XCTest/XCTest.h>

@import BasicMixedTargetWithUmbrellaHeader;

@interface ObjcBasicMixedTargetWithUmbrellaHeaderTests : XCTestCase

@end

@implementation ObjcBasicMixedTargetWithUmbrellaHeaderTests

- (void)testPublicSwiftAPI {
    // Check that Objective-C compatible Swift API surface is exposed...
    Cookie *cookie = [[Cookie alloc] init];
}

- (void)testPublicObjcAPI {
    // Check that Objective-C API surface is exposed...
    Bakery *bakery = [[Bakery alloc] init];
    Dessert *dessert = [[Dessert alloc] init];
}

@end
