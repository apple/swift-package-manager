@import Foundation;

#import <CarPart.h>
#import "CarPart.h"

@interface FluxCapacitor : CarPart
@property (nonatomic, readonly) NSString *serialNumber;
- (instancetype)initWithSerialNumber:(NSString *)serialNumber;
@end
