#import <Foundation/Foundation.h>

// Both import statements should be supported.
// - This one is from the root of the `publicHeadersPath`.
#import "Driver/Driver.h"
// - This one is from the root of the target's sources directory.
#import "Blah/Public/Driver/Driver.h"

// The `Engine` type is declared in the Swift part of the module. Such types
// must be forward declared in headers.
@class Engine;

@interface OldCar : NSObject
// `Engine` is defined in Swift.
@property(nullable) Engine *engine;
// `Driver` is defined in Objective-C.
@property(nullable) Driver *driver;
@end
