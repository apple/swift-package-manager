#import <Foundation/Foundation.h>

#import "include/OldBoat.h"

@implementation OldBoat

- (void)checkForLifeJackets {
    // Check that `LifeJacket` type from `SwiftTarget` is visible.
    if (self.lifeJackets.count > 0) {
        NSLog(@"Life jackets on board!");
    } else {
        NSLog(@"Life jackets missing!");
    }
}

@end
