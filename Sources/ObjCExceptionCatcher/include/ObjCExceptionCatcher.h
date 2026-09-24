#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift cannot catch Objective-C exceptions, and letting one unwind through
/// Swift (especially async) frames corrupts the runtime. AVAudioEngine throws
/// them for recoverable conditions like a tap format mismatch, so calls that
/// can raise go through here and come back as an ordinary NSError instead.
BOOL CSCatchObjCException(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
