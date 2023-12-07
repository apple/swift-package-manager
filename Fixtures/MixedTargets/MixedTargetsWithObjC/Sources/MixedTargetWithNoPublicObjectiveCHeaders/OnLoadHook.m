#import <Foundation/Foundation.h>

#import "OnLoadHook.h"

// Import the Swift part of the module.
#import "MixedTargetWithNoPublicObjectiveCHeaders-Swift.h"

@implementation OnLoadHook

+ (void)load {
  [[[Bar alloc] init] doStuff];
}

@end
