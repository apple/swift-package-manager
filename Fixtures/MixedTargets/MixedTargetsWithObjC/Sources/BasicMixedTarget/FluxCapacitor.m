#import "FluxCapacitor.h"

@implementation FluxCapacitor

- (instancetype)initWithSerialNumber:(NSString *)serialNumber {
  self = [super init];
  if (self) {
    _serialNumber = serialNumber;
  }
  return self;
}

@end
