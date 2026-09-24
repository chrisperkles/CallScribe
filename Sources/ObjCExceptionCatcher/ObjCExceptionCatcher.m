#import "ObjCExceptionCatcher.h"

BOOL CSCatchObjCException(NS_NOESCAPE void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
            info[@"ExceptionName"] = exception.name;
            *error = [NSError errorWithDomain:@"at.skyline.CallScribe.ObjCException" code:1 userInfo:info];
        }
        return NO;
    }
}
