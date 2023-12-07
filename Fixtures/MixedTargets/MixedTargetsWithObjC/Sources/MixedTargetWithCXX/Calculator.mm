#import <Foundation/Foundation.h>

#import "include/Calculator.h"

// Import C++ header.
#import "FactorialFinder.hpp"

@implementation Calculator

+ (long)factorialForInt:(int)integer {
    FactorialFinder ff;
    return ff.factorial(integer);
}

@end
