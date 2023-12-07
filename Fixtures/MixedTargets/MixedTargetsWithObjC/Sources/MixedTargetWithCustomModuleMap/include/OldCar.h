#import <Foundation/Foundation.h>

#import "Driver.h"

// The `Engine` type is declared in the Swift part of the module. Such types
// must be forward declared in headers.
@class Engine;

// `My` prefix is to avoid naming collision in test bundle.
@interface MyOldCar : NSObject
// `Engine` is defined in Swift.
@property(nullable) Engine *engine;
// `Driver` is defined in Objective-C.
@property(nullable) MyDriver *driver;
@end
