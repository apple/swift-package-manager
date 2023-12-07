#import <Foundation/Foundation.h>

#import "Driver.h"

// The `Engine` type is declared in the Swift part of the module. Such types
// must be forward declared in headers.
@class Engine;

@interface OldCar : NSObject
// `Engine` is defined in Swift.
@property(nullable) Engine *engine;
// `Driver` is defined in Objective-C.
@property(nullable) Driver *driver;
@end
