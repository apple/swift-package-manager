#import <Foundation/Foundation.h>

// This type is Swift compatible and used in `NewCar`.
// `My` prefix is to avoid naming collision in test bundle.
@interface MyDriver : NSObject
@property(nonnull) NSString* name;
@end
