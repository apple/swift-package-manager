#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, TransmissionKind) {
  TransmissionKindManual,
  TransmissionKindAutomatic
};

NS_SWIFT_NAME(Transmission)
@interface ABCTransmission : NSObject
@property (nonatomic, readonly, assign) TransmissionKind transmissionKind;
@end
