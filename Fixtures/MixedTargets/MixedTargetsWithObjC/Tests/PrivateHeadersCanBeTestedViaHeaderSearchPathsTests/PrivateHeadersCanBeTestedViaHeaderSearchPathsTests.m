#import <XCTest/XCTest.h>

@import MixedTargetWithNonPublicHeaders;

#import "Sources/MixedTargetWithNonPublicHeaders/Foo/Foo/Foo.h"
#import "Sources/MixedTargetWithNonPublicHeaders/Bar.h"

@interface PrivateHeadersCanBeTestedViaHeaderSearchPathsTests : XCTestCase
@end

@implementation PrivateHeadersCanBeTestedViaHeaderSearchPathsTests

- (void)testPrivateHeaders {
    Foo *foo = [[Foo alloc] init];
    Bar *bar = [[Bar alloc] init];
}

@end
