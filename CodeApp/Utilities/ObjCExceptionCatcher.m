//
//  ObjCExceptionCatcher.m
//  CodifyOne
//

#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)catchExceptionInBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError * _Nullable * _Nullable)error
{
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != nil) {
            NSString *reason = exception.reason ?: @"Objective-C exception";
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: reason,
                @"ExceptionName": exception.name ?: @"NSException"
            };
            *error = [NSError errorWithDomain:@"ObjCExceptionCatcher"
                                         code:1
                                     userInfo:userInfo];
        }
        return NO;
    }
}

@end
