#import <Foundation/Foundation.h>

#import "include/OldBoat.h"

@implementation OldBoat

- (void)checkForLifeJackets {
    // Check that property from superclass is visible.
    if (self.hasLifeJackets) {
        NSLog(@"Life jackets on board!");
    } else {
        NSLog(@"Life jackets missing!");
    }
}

@end
