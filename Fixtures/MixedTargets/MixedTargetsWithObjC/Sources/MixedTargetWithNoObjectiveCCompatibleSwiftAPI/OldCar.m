#import <Foundation/Foundation.h>

#import "OldCar.h"
#import "include/OldCar.h"

// Import the Swift part of the module. Note that this header wouldn't vend any
// API as this target intentionally has no Objective-C compatible Swift API.
#import "MixedTargetWithNoObjectiveCCompatibleSwiftAPI-Swift.h"

#import "Transmission.h"

@interface OldCar ()
@property(nonatomic) Transmission *transmission;
#if EXPECT_FAILURE
@property(nonatomic) Driver *driver;
#endif
@end

@implementation OldCar
@end
