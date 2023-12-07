#import <Foundation/Foundation.h>

@interface ObjcCalculator : NSObject
+ (long)factorialForInt:(int)integer;
+ (long)sumX:(int)x andY:(int)y NS_SWIFT_NAME(sum(x:y:));
@end
