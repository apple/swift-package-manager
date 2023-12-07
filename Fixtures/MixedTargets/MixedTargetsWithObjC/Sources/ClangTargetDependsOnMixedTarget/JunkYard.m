#import <Foundation/Foundation.h>

#import "include/JunkYard.h"

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

@interface JunkYard ()
// The below types come from the `BasicMixedTarget` module.
@property(nullable) Engine *engine;
@property(nullable) Driver *driver;
@property(nullable) OldCar *oldCar;
@property(nullable) CarPart *carPart;
@end

@implementation JunkYard
@end
