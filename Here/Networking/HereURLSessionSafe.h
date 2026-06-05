//
//  HereURLSessionSafe.h
//  Here
//
//  Objective-C barrier around NSURLSession task creation. The async
//  variants of `NSURLSession.data(for:)` can throw an `NSException`
//  from `-[__NSURLSessionLocal taskForClassInfo:]` during task
//  construction (observed on macOS 26.5 under transparent-proxy /
//  utun setups). NSException is **not** a Swift `Error` — `do/catch`
//  in Swift cannot intercept it, so the exception propagates to
//  `objc_terminate` and SIGABRTs the process.
//
//  v0.32.1: route all session.dataTask creation through `HereSafeDataTask`
//  so a thrown NSException becomes a plain `NSError` (Swift can `catch`)
//  instead of killing the app.
//

#ifndef HereURLSessionSafe_h
#define HereURLSessionSafe_h

@import Foundation;

NS_ASSUME_NONNULL_BEGIN

/// NSError domain used when an NSException is caught during task creation.
/// `code == 1` is the only code emitted today; `userInfo` carries the
/// exception's `name` and `reason` under the same string keys.
extern NSErrorDomain const HereURLSessionSafeErrorDomain;

/// Create an `NSURLSessionDataTask` inside `@try`/`@catch`. On exception,
/// returns `nil` and (if `outError` is non-NULL) populates it with the
/// exception's name + reason. The task is **not** resumed — the caller
/// is responsible for `[task resume]`.
///
/// Pass a non-nil `completion` block; it is forwarded to URLSession
/// unchanged and is called on URLSession's delegate queue per the usual
/// `dataTaskWithRequest:completionHandler:` contract.
NSURLSessionDataTask * _Nullable
HereSafeDataTask(NSURLSession *session,
                 NSURLRequest *request,
                 void (^completion)(NSData * _Nullable data,
                                    NSURLResponse * _Nullable response,
                                    NSError * _Nullable error),
                 NSError * _Nullable * _Nullable outError);

/// Delegate-style variant of `HereSafeDataTask` — no completion block,
/// the caller's `URLSessionDataDelegate` receives the response. Same
/// `@try`/`@catch` barrier: returns `nil` + NSError on exception
/// instead of crashing.
NSURLSessionDataTask * _Nullable
HereSafeDataTaskWithoutCompletion(NSURLSession *session,
                                  NSURLRequest *request,
                                  NSError * _Nullable * _Nullable outError);

NS_ASSUME_NONNULL_END

#endif /* HereURLSessionSafe_h */
