
//
//  RNFetchBlobNetwork.m
//  RNFetchBlob
//
//  Created by wkh237 on 2016/6/6.
//  Copyright © 2016 wkh237. All rights reserved.
//


#import <Foundation/Foundation.h>
#import "RNFetchBlobNetwork.h"

#import "RNFetchBlob.h"
#import "RNFetchBlobConst.h"
#import "RNFetchBlobProgress.h"
#import "Reachability.h"

#if __has_include(<React/RCTAssert.h>)
#import <React/RCTRootView.h>
#import <React/RCTLog.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTBridge.h>
#else
#import "RCTRootView.h"
#import "RCTLog.h"
#import "RCTEventDispatcher.h"
#import "RCTBridge.h"
#endif

////////////////////////////////////////
//
//  HTTP request handler
//
////////////////////////////////////////

NSMapTable * expirationTable;

__attribute__((constructor))
static void initialize_tables() {
  if (expirationTable == nil) {
    expirationTable = [[NSMapTable alloc] init];
  }
}

@interface RNFetchBlobNetwork()

@property (nonatomic) Reachability *internetReachability;
@property(nonnull, nonatomic) NSOperationQueue *taskQueue;
@property(nonatomic, assign) BOOL isActive;
@property(nonatomic, nonnull) NSURLSession *bgSession;
@property(nonnull, nonatomic) NSMapTable<NSString*, RNFetchBlobRequest*> * requestsTable;
@property(nonatomic) NSMutableArray *resumedTasks;

@end

@implementation RNFetchBlobNetwork

NSString *const BGSessionIdentifier = @"RNFetchBlodBackgroundSession";

- (id)init {
  self = [super init];
  if (self) {
    self.requestsTable = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory valueOptions:NSMapTableStrongMemory];
    
    self.taskQueue = [[NSOperationQueue alloc] init];
    self.taskQueue.qualityOfService = NSQualityOfServiceUtility;
    self.taskQueue.maxConcurrentOperationCount = 10;
    self.internetReachability = [Reachability reachabilityForInternetConnection];
    [self.internetReachability startNotifier];
    self.isActive = true;
    self.resumedTasks = [NSMutableArray new];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachabilityChanged) name:kReachabilityChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachabilityChanged) name:@"kSEGReachabilityChangedNotification" object:nil];
    
    /// Initialize background session
    // the session trust any SSL certification
    
    NSURLSessionConfiguration *defaultConfigObject = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:BGSessionIdentifier];
    defaultConfigObject.sessionSendsLaunchEvents = YES;
    defaultConfigObject.discretionary = YES;
    defaultConfigObject.timeoutIntervalForRequest = 30.0;
    defaultConfigObject.HTTPMaximumConnectionsPerHost = 10;
    NSUInteger mb = 1024 * 1024;
    defaultConfigObject.URLCache = [[NSURLCache alloc] initWithMemoryCapacity:10 * mb
                                                                 diskCapacity:20 * 1024 * 1024
                                                                     diskPath:nil];
    self.bgSession = [NSURLSession sessionWithConfiguration:defaultConfigObject delegate:self delegateQueue:self.taskQueue];
    
    [[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:[RNFetchBlobFS getDocumentDir] error:NULL];
  }
  
  return self;
}

+ (RNFetchBlobNetwork* _Nullable)sharedInstance {
  static id _sharedInstance = nil;
  static dispatch_once_t onceToken;
  
  dispatch_once(&onceToken, ^{
    _sharedInstance = [[self alloc] init];
  });
  
  return _sharedInstance;
}

- (void)setCompletionHandlerWithIdentifier:(NSString *)identifier completionHandler:(void (^)(void))completionHandler;
{
  if ([BGSessionIdentifier isEqualToString:identifier]) {
    self.completion = completionHandler;
  }
}

- (void) sendRequest:(__weak NSDictionary  * _Nullable )options
       contentLength:(long) contentLength
              bridge:(RCTBridge * _Nullable)bridgeRef
              taskId:(NSString * _Nullable)taskId
         withRequest:(__weak NSURLRequest * _Nullable)req
            callback:(_Nullable RCTResponseSenderBlock) callback
{
  
  RNFetchBlobRequest *runningReq = [self.requestsTable objectForKey:req.URL.absoluteString];
  if (runningReq) {
    if (runningReq.task.state == NSURLSessionTaskStateRunning) {
      callback(@[
                 @"The file is already being downloaded.",
                 [NSNull null],
                 [NSNull null]
                 ]);
      return;
    } else {
      [self.requestsTable removeObjectForKey:req.URL.absoluteString];
    }
  }
  
  RNFetchBlobRequest *request = [[RNFetchBlobRequest alloc] init];
  [request sendRequest:options
                bridge:bridgeRef
                taskId:taskId
           withRequest:req
             inSession:self.bgSession
              callback:callback];
  request.progressConfig = [[RNFetchBlobProgress alloc] initWithType:Download interval:@(500) count:@(100)];
  
  @synchronized ([RNFetchBlobNetwork class]) {
    [self.requestsTable setObject:request forKey:req.URL.absoluteString];
    [self storePath:request.destPath withURL:req.URL.absoluteString];
  }
}

- (void) enableProgressReport:(NSString *) taskId config:(RNFetchBlobProgress *)config
{
  
}

- (void) enableUploadProgress:(NSString *) taskId config:(RNFetchBlobProgress *)config
{
  
}

- (void)storePath:(NSString *)path withURL:(NSString *)url {
  NSMutableDictionary *dict = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"BG_STORAGE_CACHE"] mutableCopy];
  if (!dict) {
    dict = [NSMutableDictionary new];
  }
  dict[url] = path;
  [[NSUserDefaults standardUserDefaults] setObject:dict forKey:@"BG_STORAGE_CACHE"];
}

- (NSString *)retrievePathFrom:(NSString *)url {
  NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"BG_STORAGE_CACHE"];
  return dict[url];
}

- (void)removePathFrom:(NSString *)url {
  NSMutableDictionary *dict = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"BG_STORAGE_CACHE"] mutableCopy];
  if (dict) {
    [dict removeObjectForKey:url];
  }
}

- (void)cacheExistDownloadsIfNeeded {
  __weak typeof(RNFetchBlobNetwork) *wself = self;
  [self.bgSession getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> * _Nonnull dataTasks, NSArray<NSURLSessionUploadTask *> * _Nonnull uploadTasks, NSArray<NSURLSessionDownloadTask *> * _Nonnull downloadTasks) {
    for (NSURLSessionDownloadTask *task in downloadTasks) {
      NSData *resumedData = task.error.userInfo[NSURLSessionDownloadTaskResumeData];
      if (resumedData) {
        RNFetchBlobRequest *req = [[RNFetchBlobRequest alloc] init];
        NSString *path = [wself retrievePathFrom:task.currentRequest.URL.absoluteString];
        if (path) {
          req.destPath = [req correctPath: path];
          req.reqURL = task.currentRequest.URL.absoluteString;
          [req writeResumeData:resumedData];
        }
      }
      [task cancel];
    }
  }];
}

- (void) cancelRequest:(NSString *)taskId
{
  RNFetchBlobRequest * req;
  
  @synchronized ([RNFetchBlobNetwork class]) {
    for (RNFetchBlobRequest *request in self.requestsTable.objectEnumerator) {
      if ([request.taskId isEqualToString:taskId]) {
        req = request;
      }
    }
  }
  
  if (req.task && req.task.state == NSURLSessionTaskStateRunning) {
    [self cancelTask:req.task req:req];
  }
}

- (void)cancelTask:(NSURLSessionTask *)task req:(RNFetchBlobRequest *)req;
{
  if ([task isKindOfClass:[NSURLSessionDownloadTask class]]) {
    [(NSURLSessionDownloadTask *)task cancelByProducingResumeData:^(NSData * _Nullable resumeData) {
      if (resumeData) {
        /// Cache resumeable data in storage
        [req writeResumeData:resumeData];
      }
    }];
  } else {
    [task cancel];
  }
}

// removing case from headers
+ (NSMutableDictionary *) normalizeHeaders:(NSDictionary *)headers
{
  NSMutableDictionary * mheaders = [[NSMutableDictionary alloc]init];
  for (NSString * key in headers) {
    [mheaders setValue:[headers valueForKey:key] forKey:[key lowercaseString]];
  }
  
  return mheaders;
}

// #115 Invoke fetch.expire event on those expired requests so that the expired event can be handled
+ (void) emitExpiredTasks
{
  @synchronized ([RNFetchBlobNetwork class]){
    NSEnumerator * emu =  [expirationTable keyEnumerator];
    NSString * key;
    
    while ((key = [emu nextObject]))
    {
      RCTBridge * bridge = [RNFetchBlob getRCTBridge];
      id args = @{ @"taskId": key };
      [bridge.eventDispatcher sendDeviceEventWithName:EVENT_EXPIRE body:args];
      
    }
    
    // clear expired task entries
    [expirationTable removeAllObjects];
    expirationTable = [[NSMapTable alloc] init];
  }
}

- (void)appBecomeActive
{
  self.isActive = true;
  /// Do nothing if no internet connection
  if (self.internetReachability.currentReachabilityStatus == NotReachable) {
    return;
  }
  @synchronized ([RNFetchBlobNetwork class]) {
    for (RNFetchBlobRequest *req in self.requestsTable.objectEnumerator) {
      [req.task resume];
    }
  }
}

- (void) reachabilityChanged
{
  if (self.internetReachability.currentReachabilityStatus == NotReachable) {
    @synchronized ([RNFetchBlobNetwork class]) {
      NSDictionary *userInfo = @{
                                 NSLocalizedDescriptionKey: NSLocalizedString(@"The connection failed because the network connection was lost.", nil),
                                 NSLocalizedFailureReasonErrorKey: NSLocalizedString(@"The network connection was lost", nil),
                                 NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"Have you tried turning it off and on again?", nil)};
      for (RNFetchBlobRequest *req in self.requestsTable.objectEnumerator) {
        req.customError = [NSError errorWithDomain:@"NSErrorDomain" code:NSURLErrorNetworkConnectionLost userInfo:userInfo];
        [self cancelTask:req.task req:req];
      }
    }
  }
}

- (void)appDidEnterBackground
{
  self.isActive = false;
}

// MARK: - Delegate
- (RNFetchBlobRequest *)requestFrom:(NSURLSessionTask *)task {
  NSString *url = task.originalRequest.URL.absoluteString;
  if (!url) {
    url = task.currentRequest.URL.absoluteString;
  }
  RNFetchBlobRequest *req;
  @synchronized ([RNFetchBlobNetwork class]) {
    req = [self.requestsTable objectForKey:url];
  }
  return req;
}


- (void) URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session
{
  if (self.completion) {
    self.completion();
  }
}


- (void) URLSession:(NSURLSession *)session didBecomeInvalidWithError:(nullable NSError *)error
{
  if ([session isEqual:session]) {
    session = nil;
  }
}


- (void) URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
  RNFetchBlobRequest *req = [self requestFrom:task];
  if (!req) {
    return;
  }
  NSString * errMsg;
  NSString * respStr;
  NSString * rnfbRespType;
  
  dispatch_async(dispatch_get_main_queue(), ^{
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
  });
  
  if (error) {
    if (req.customError) {
      errMsg = [req.customError localizedDescription];
    } else {
      if (error.code == NSURLErrorCannotWriteToFile) {
        [req removeResumeData];
        errMsg = NSLocalizedString(@"Something went wrong. Let's retry!", nil);
      } else {
        errMsg = [error localizedDescription];
      }
    }
  } else if (!req.shouldCompleteTask) {
    return;
  }
  
  respStr = [req correctFilePath];
  rnfbRespType = RESP_TYPE_PATH;
  
  if (req.callback) {
    req.callback(@[
                   errMsg ?: [NSNull null],
                   rnfbRespType ?: @"",
                   respStr ?: [NSNull null]
                   ]);
  }
  req.callback = nil;
  /// Remove cached resumeable data in storage if exists
  if (!error) {
    [req removeResumeData];
  }
  /// Remove the self from caching table
  @synchronized ([RNFetchBlobNetwork class]) {
    [self.resumedTasks removeObject:req.reqURL];
    [self.requestsTable removeObjectForKey:req.reqURL];
    [self removePathFrom:req.reqURL];
  }
}

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
  NSURLCredential *credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
  completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
}

// MARK: - For Download Task delegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didResumeAtOffset:(int64_t)fileOffset expectedTotalBytes:(int64_t)expectedTotalBytes {
  RNFetchBlobRequest *req = [self requestFrom:downloadTask];
  if (!req) {
    return;
  }
  [self handleDownloadProgress:(float)fileOffset total:(float)expectedTotalBytes request:req];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
  RNFetchBlobRequest *req = [self requestFrom:downloadTask];
  if (!req) {
    return;
  }
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSError *error;
  [fileManager removeItemAtPath:req.destPath error:NULL];
  NSString *filePath = [req correctFilePath];
  [fileManager removeItemAtPath:filePath error:NULL];
  [fileManager copyItemAtPath:location.path toPath:filePath error:&error];
  if (error) {
    NSLog(@"Moved with error: %@", error);
  }
  req.shouldCompleteTask = true;
  [self URLSession:session task:downloadTask didCompleteWithError:error];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
  if (totalBytesExpectedToWrite == 0) {
    return;
  }
  RNFetchBlobRequest *req = [self requestFrom:downloadTask];
  if (!req) {
    return;
  }
  [self handleDownloadProgress:(float)totalBytesWritten total:(float)totalBytesExpectedToWrite request:req];
}

- (void)handleDownloadProgress:(float)totalBytesWritten total:(float)totalBytesExpectedToWrite request:(RNFetchBlobRequest *)req
{
  NSNumber *now = [NSNumber numberWithFloat:(totalBytesWritten/totalBytesExpectedToWrite)];
  /// Send progress event continuously without condition checker
  if ([req.progressConfig shouldReport:now] && self.isActive) {
    [req.bridge.eventDispatcher
     sendDeviceEventWithName:EVENT_PROGRESS
     body:@{
            @"taskId": req.taskId,
            @"written": [NSString stringWithFormat:@"%lld", (long long) totalBytesWritten],
            @"total": [NSString stringWithFormat:@"%lld", (long long) totalBytesExpectedToWrite]
            }
     ];
  }
}

@end

