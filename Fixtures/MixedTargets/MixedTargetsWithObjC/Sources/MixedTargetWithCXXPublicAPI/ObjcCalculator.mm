#import <Foundation/Foundation.h>

#import "include/ObjcCalculator.h"

// Import C++ headers.
#import "CXXFactorialFinder.hpp"
#import "CXXSumFinder.hpp"

@implementation ObjcCalculator

+ (long)factorialForInt:(int)integer {
    CXXFactorialFinder ff;
    return ff.factorial(integer);
}

+ (long)sumX:(int)x andY:(int)y {
    CXXSumFinder sf;
    return sf.sum(x, y);
}

@end

