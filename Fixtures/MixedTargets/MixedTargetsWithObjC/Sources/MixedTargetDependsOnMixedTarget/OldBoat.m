#import <Foundation/Foundation.h>

#import "include/OldBoat.h"

#if TEST_MODULE_IMPORTS
// Import the mixed target's module.
@import BasicMixedTarget;
#else
// Import the mixed target's public headers. Both "..." and <...> style imports
// should resolve.
#import "CarPart.h"
#import <CarPart.h>
#import "Driver.h"
#import <Driver.h>
#import "OldCar.h"
#import <OldCar.h>
#import "BasicMixedTarget-Swift.h"
#import <BasicMixedTarget-Swift.h>
#endif // TEST_MODULE_IMPORTS

@interface OldBoat ()
// The below types comes from the `BasicMixedTarget` module`.
@property(nonatomic, strong) Engine *engine;
@property(nonatomic, strong) Driver *driver;
@end

@implementation OldBoat
@end
