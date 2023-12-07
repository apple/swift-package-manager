#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, TransmissionKind) {
  TransmissionKindManual,
  TransmissionKindAutomatic
};

@interface Transmission : NSObject
@property (nonatomic, readonly, assign) TransmissionKind transmissionKind;
@end
