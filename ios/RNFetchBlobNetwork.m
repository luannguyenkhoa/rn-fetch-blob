
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

@end

@implementation RNFetchBlobNetwork


- (id)init {
    self = [super init];
    if (self) {
        self.requestsTable = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory valueOptions:NSMapTableWeakMemory];
        
        self.taskQueue = [[NSOperationQueue alloc] init];
        self.taskQueue.qualityOfService = NSQualityOfServiceUtility;
        self.taskQueue.maxConcurrentOperationCount = 10;
        self.rebindProgressDict = [NSMutableDictionary dictionary];
        self.rebindUploadProgressDict = [NSMutableDictionary dictionary];
        self.internetReachability = [Reachability reachabilityForInternetConnection];
        [self.internetReachability startNotifier];
        self.isActive = true;
        
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachabilityChanged) name:kReachabilityChangedNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachabilityChanged) name:@"kSEGReachabilityChangedNotification" object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
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

- (void) sendRequest:(__weak NSDictionary  * _Nullable )options
       contentLength:(long) contentLength
              bridge:(RCTBridge * _Nullable)bridgeRef
              taskId:(NSString * _Nullable)taskId
         withRequest:(__weak NSURLRequest * _Nullable)req
            callback:(_Nullable RCTResponseSenderBlock) callback
{
    /// Turn back immediately if no network connection
    if (self.internetReachability.currentReachabilityStatus == NotReachable) {
        callback(@[
                   @"No network connection",
                   [NSNull null],
                   [NSNull null]
                   ]);
        return;
    }
    RNFetchBlobRequest *request = [[RNFetchBlobRequest alloc] init];
    [request sendRequest:options
           contentLength:contentLength
                  bridge:bridgeRef
                  taskId:taskId
             withRequest:req
      taskOperationQueue:self.taskQueue
                callback:callback];
    request.progressConfig = [[RNFetchBlobProgress alloc] initWithType:Download interval:@(500) count:@(200)];
    self.latestTaskId = taskId;
    @synchronized([RNFetchBlobNetwork class]) {
        [self.requestsTable setObject:request forKey:taskId];
    }
}

- (void) checkProgressConfig {
    //reconfig progress
    [self.rebindProgressDict enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, RNFetchBlobProgress * _Nonnull config, BOOL * _Nonnull stop) {
        [self enableProgressReport:key config:config];
    }];
    [self.rebindProgressDict removeAllObjects];
    
    //reconfig uploadProgress
    [self.rebindUploadProgressDict enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, RNFetchBlobProgress * _Nonnull config, BOOL * _Nonnull stop) {
        [self enableUploadProgress:key config:config];
    }];
    [self.rebindUploadProgressDict removeAllObjects];
}

- (void) enableProgressReport:(NSString *) taskId config:(RNFetchBlobProgress *)config
{
    //    if (config) {
    //        @synchronized ([RNFetchBlobNetwork class]) {
    //            if (![self.requestsTable objectForKey:taskId]) {
    //                [self.rebindProgressDict setValue:config forKey:taskId];
    //            } else {
    //                [self.requestsTable objectForKey:taskId].progressConfig = config;
    //            }
    //        }
    //    }
}

- (void) enableUploadProgress:(NSString *) taskId config:(RNFetchBlobProgress *)config
{
    if (config) {
        @synchronized ([RNFetchBlobNetwork class]) {
            if (![self.requestsTable objectForKey:taskId]) {
                [self.rebindUploadProgressDict setValue:config forKey:taskId];
            } else {
                [self.requestsTable objectForKey:taskId].uploadProgressConfig = config;
            }
        }
    }
}

- (void) cancelRequest:(NSString *)taskId
{
    RNFetchBlobRequest * req;
    
    @synchronized ([RNFetchBlobNetwork class]) {
        req = [self.requestsTable objectForKey:taskId];
    }
    
    if (req.task && req.task.state == NSURLSessionTaskStateRunning) {
        [self cancelTask:req.task req:req];
        [self.requestsTable removeObjectForKey:taskId];
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
    /// Otherwise start resuming unique running tasks
    NSMutableArray *urls = [NSMutableArray new];
    @synchronized ([RNFetchBlobNetwork class]) {
        for (RNFetchBlobRequest *req in self.requestsTable.objectEnumerator) {
            [req.session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> * _Nonnull dataTasks, NSArray<NSURLSessionUploadTask *> * _Nonnull uploadTasks, NSArray<NSURLSessionDownloadTask *> * _Nonnull downloadTasks) {
                for (NSURLSessionDownloadTask *task in downloadTasks) {
                    if (task.state == NSURLSessionTaskStateRunning && ![urls containsObject:task.currentRequest.URL.absoluteString]) {
                        [urls addObject:task.currentRequest.URL.absoluteString];
                        [task resume];
                    } else {
                        [task suspend];
                    }
                }
            }];
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
                [req.session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> * _Nonnull tasks) {
                    for (NSURLSessionTask *task in tasks) {
                        req.customError = [NSError errorWithDomain:@"NSErrorDomain" code:NSURLErrorNetworkConnectionLost userInfo:userInfo];
                        [self cancelTask:task req:req];
                    }
                }];
            }
            [self.requestsTable removeAllObjects];
        }
    }
}

- (void)appDidEnterBackground
{
  self.isActive = false;
}

@end
