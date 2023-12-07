#import <Foundation/Foundation.h>

// The below import statements should be supported.
#import "MixedTargetWithCustomPaths/Sources/Public/OldCar.h"
#import "OldCar.h"
#import "Public/OldCar.h"
#import <OldCar.h>
#import <Public/OldCar.h>

// Import the Swift part of the module.
#import "MixedTargetWithCustomPaths-Swift.h"

// Both import statements should be supported.
#import "MixedTargetWithCustomPaths/Sources/Transmission.h"
#import "Transmission.h"

@interface OldCar ()
@property(nonatomic) Transmission *transmission;
@end

@implementation OldCar
@end
