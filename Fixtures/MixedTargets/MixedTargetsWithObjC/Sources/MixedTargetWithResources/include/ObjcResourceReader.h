#import <Foundation/Foundation.h>

@interface ObjcResourceReader : NSObject
+ (NSString *)readResource:(NSString*)resource
                    ofType:(NSString*)type;
@end
