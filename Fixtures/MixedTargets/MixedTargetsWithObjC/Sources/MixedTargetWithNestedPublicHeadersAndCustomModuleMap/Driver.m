#import <Foundation/Foundation.h>

// Both import statements should be supported.
// - This one is from the root of the `publicHeadersPath`.
#import "Driver/Driver.h"
// - This one is from the root of the target's sources directory.
#import "Blah/Public/Driver/Driver.h"

@implementation Driver
@end
