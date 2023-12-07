#import <Foundation/Foundation.h>

@import BasicMixedTarget;

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Ensure that the module is actually loaded.
        Engine *engine = [[Engine alloc] init];
        OldCar *oldCar = [[OldCar alloc] init];

        NSLog(@"Hello, world!");
    }
    return 0;
}
