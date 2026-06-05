//
//  HereURLSessionSafe.m
//  Here
//
//  See HereURLSessionSafe.h for rationale.
//

#import "HereURLSessionSafe.h"

NSErrorDomain const HereURLSessionSafeErrorDomain = @"app.here-macos.URLSessionSafe";

static NSError *HereWrapException(NSException *exception) {
    NSString *name = exception.name ?: @"<unnamed>";
    NSString *reason = exception.reason ?: @"<no reason>";
    NSString *desc = [NSString stringWithFormat:@"URLSession threw NSException: %@ — %@",
                      name, reason];
    return [NSError errorWithDomain:HereURLSessionSafeErrorDomain
                               code:1
                           userInfo:@{
        NSLocalizedDescriptionKey: desc,
        @"NSExceptionName": name,
        @"NSExceptionReason": reason,
    }];
}

NSURLSessionDataTask * _Nullable
HereSafeDataTask(NSURLSession *session,
                 NSURLRequest *request,
                 void (^completion)(NSData * _Nullable data,
                                    NSURLResponse * _Nullable response,
                                    NSError * _Nullable error),
                 NSError * _Nullable * _Nullable outError) {
    @try {
        return [session dataTaskWithRequest:request completionHandler:completion];
    } @catch (NSException *exception) {
        if (outError) { *outError = HereWrapException(exception); }
        return nil;
    }
}

NSURLSessionDataTask * _Nullable
HereSafeDataTaskWithoutCompletion(NSURLSession *session,
                                  NSURLRequest *request,
                                  NSError * _Nullable * _Nullable outError) {
    @try {
        return [session dataTaskWithRequest:request];
    } @catch (NSException *exception) {
        if (outError) { *outError = HereWrapException(exception); }
        return nil;
    }
}
