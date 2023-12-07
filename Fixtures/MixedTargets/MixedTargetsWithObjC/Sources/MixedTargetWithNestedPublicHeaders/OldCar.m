#import <Foundation/Foundation.h>

// Both import statements should be supported.
// - This one is from the root of the `publicHeadersPath`.
#import "OldCar.h"
// - This one is from the root of the target's sources directory.
#import "Blah/Public/OldCar.h"

// Import the Swift part of the module.
#import "MixedTargetWithNestedPublicHeaders-Swift.h"

#import "Transmission.h"

@interface OldCar ()
@property(nonatomic) Transmission *transmission;
@end

@implementation OldCar
@end
