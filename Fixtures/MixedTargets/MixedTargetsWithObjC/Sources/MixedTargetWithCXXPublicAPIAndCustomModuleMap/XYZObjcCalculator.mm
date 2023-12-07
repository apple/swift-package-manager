#import <Foundation/Foundation.h>

#import "include/XYZObjcCalculator.h"

// Import C++ headers.
#import "XYZCxxFactorialFinder.hpp"
#import "XYZCxxSumFinder.hpp"

@implementation XYZObjcCalculator

+ (long)factorialForInt:(int)integer {
    XYZCxxFactorialFinder ff;
    return ff.factorial(integer);
}

+ (long)sumX:(int)x andY:(int)y {
    XYZCxxSumFinder sf;
    return sf.sum(x, y);
}

@end
