//
//  RNFetchBlobRequest.m
//  RNFetchBlob
//
//  Created by Artur Chrusciel on 15.01.18.
//  Copyright © 2018 wkh237.github.io. All rights reserved.
//

#import "RNFetchBlobRequest.h"

#import "RNFetchBlobFS.h"
#import "RNFetchBlobConst.h"
#import "RNFetchBlobReqBuilder.h"
#import "RNFetchBlobNetwork.h"

#import "IOS7Polyfill.h"
#import <CommonCrypto/CommonDigest.h>


typedef NS_ENUM(NSUInteger, ResponseFormat) {
    UTF8,
    BASE64,
    AUTO
};

@interface RNFetchBlobRequest ()
{
    BOOL respFile;
    BOOL isNewPart;
    BOOL isIncrement;
    NSMutableData * partBuffer;
    NSString * destPath;
    NSOutputStream * writeStream;
    long bodyLength;
    NSInteger respStatus;
    NSMutableArray * redirects;
    ResponseFormat responseFormat;
    BOOL followRedirect;
    BOOL backgroundTask;
    BOOL shouldCompleteTask;
    NSURLRequest *crrReq;
    NSLock *lock;
}

@end

@implementation RNFetchBlobRequest

@synthesize taskId;
@synthesize expectedBytes;
@synthesize receivedBytes;
@synthesize respData;
@synthesize callback;
@synthesize bridge;
@synthesize options;
@synthesize error;


- (NSString *)md5:(NSString *)input {
    const char* str = [input UTF8String];
    unsigned char result[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), result);
    
    NSMutableString *ret = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH*2];
    for (int i = 0; i<CC_MD5_DIGEST_LENGTH; i++) {
        [ret appendFormat:@"%02x",result[i]];
    }
    return ret;
}

// send HTTP request
- (void) sendRequest:(__weak NSDictionary  * _Nullable )options
       contentLength:(long) contentLength
              bridge:(RCTBridge * _Nullable)bridgeRef
              taskId:(NSString * _Nullable)taskId
         withRequest:(__weak NSURLRequest * _Nullable)req
  taskOperationQueue:(NSOperationQueue * _Nonnull)operationQueue
            callback:(_Nullable RCTResponseSenderBlock) callback
{
    self.taskId = taskId;
    self.respData = [[NSMutableData alloc] initWithLength:0];
    self.callback = callback;
    self.bridge = bridgeRef;
    self.expectedBytes = 0;
    self.receivedBytes = 0;
    self.options = options;
    lock = [NSLock new];
    shouldCompleteTask = true;
    
    backgroundTask = [[options valueForKey:@"IOSBackgroundTask"] boolValue];
    // when followRedirect not set in options, defaults to TRUE
    followRedirect = [options valueForKey:@"followRedirect"] == nil ? YES : [[options valueForKey:@"followRedirect"] boolValue];
    isIncrement = [[options valueForKey:@"increment"] boolValue];
    redirects = [[NSMutableArray alloc] init];
    
    if (req.URL) {
        [redirects addObject:req.URL.absoluteString];
    }
    
    // set response format
    NSString * rnfbResp = [req.allHTTPHeaderFields valueForKey:@"RNFB-Response"];
    
    if ([[rnfbResp lowercaseString] isEqualToString:@"base64"]) {
        responseFormat = BASE64;
    } else if ([[rnfbResp lowercaseString] isEqualToString:@"utf8"]) {
        responseFormat = UTF8;
    } else {
        responseFormat = AUTO;
    }
    
    NSString * path = [self correctPath:[self.options valueForKey:CONFIG_FILE_PATH]];
    NSString * key = [self.options valueForKey:CONFIG_KEY];
    NSURLSession * session;
    
    bodyLength = contentLength;
    
    // the session trust any SSL certification
    NSURLSessionConfiguration *defaultConfigObject;
    
    defaultConfigObject = [NSURLSessionConfiguration defaultSessionConfiguration];
    
    if (backgroundTask) {
        defaultConfigObject = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:taskId];
        defaultConfigObject.sessionSendsLaunchEvents = YES;
        defaultConfigObject.discretionary = YES;
    }
    NSMutableURLRequest *mutableReq = (NSMutableURLRequest *)req;
    // set request/resource timeout
    if (@available(iOS 8.0, *)) {
        mutableReq.timeoutInterval = 30.0;
    }
    defaultConfigObject.timeoutIntervalForRequest = 30.0;
    defaultConfigObject.HTTPMaximumConnectionsPerHost = 1;
    session = [NSURLSession sessionWithConfiguration:defaultConfigObject delegate:self delegateQueue:operationQueue];
    self.session = session;
    
    if (path || [self.options valueForKey:CONFIG_USE_TEMP]) {
        respFile = YES;
        
        NSString* cacheKey = taskId;
        if (key) {
            cacheKey = [self md5:key];
            
            if (!cacheKey) {
                cacheKey = taskId;
            }
            
            destPath = [RNFetchBlobFS getTempPath:cacheKey withExtension:[self.options valueForKey:CONFIG_FILE_EXT]];
            
            if ([[NSFileManager defaultManager] fileExistsAtPath:destPath]) {
                callback(@[[NSNull null], RESP_TYPE_PATH, destPath]);
                
                return;
            }
        }
        
        if (path) {
            destPath = path;
        } else {
            destPath = [RNFetchBlobFS getTempPath:cacheKey withExtension:[self.options valueForKey:CONFIG_FILE_EXT]];
        }
    } else {
        respData = [[NSMutableData alloc] init];
        respFile = NO;
    }
    crrReq = (NSURLRequest *)mutableReq;
    if (!backgroundTask) {
        NSURLSessionDataTask *task = [session dataTaskWithRequest:mutableReq];
        [task resume];
        self.task = task;
    } else {
        if ([[options valueForKey:@"IOSUploadTask"] boolValue]) {
            NSURLSessionUploadTask *task = [session uploadTaskWithRequest:mutableReq fromFile:[NSURL URLWithString: destPath]];
            [task resume];
            self.task = task;
        } else if ([[options valueForKey:@"IOSDownloadTask"] boolValue]) {
            NSURLSessionDownloadTask *task;
            NSData *resumeableData = [self retrieveResumeData];
            if (resumeableData) {
                task = [self correctedDownloadTaskWithResumeData:resumeableData withSession:session];
            } else {
                task = [session downloadTaskWithRequest:mutableReq];
                [task resume];
            }
            self.task = task;
            shouldCompleteTask = false;
        } else {
            NSURLSessionDataTask *task = [session dataTaskWithRequest:mutableReq];
            [task resume];
            self.task = task;
        }
    }
    
    // network status indicator
    if ([[options objectForKey:CONFIG_INDICATOR] boolValue]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
        });
    }
}

////////////////////////////////////////
//
//  NSURLSession delegates
//
////////////////////////////////////////


#pragma mark NSURLSession delegate methods
- (void)configureWriteStream {
    if (respFile)
    {
        @try{
            NSFileManager * fm = [NSFileManager defaultManager];
            NSString * folder = [destPath stringByDeletingLastPathComponent];
            
            if (![fm fileExistsAtPath:folder]) {
                [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:NULL error:nil];
            }
            
            // if not set overwrite in options, defaults to TRUE
            BOOL overwrite = [options valueForKey:@"overwrite"] == nil ? YES : [[options valueForKey:@"overwrite"] boolValue];
            BOOL appendToExistingFile = [destPath RNFBContainsString:@"?append=true"];
            
            appendToExistingFile = !overwrite;
            
            // For solving #141 append response data if the file already exists
            // base on PR#139 @kejinliang
            if (appendToExistingFile) {
                destPath = [destPath stringByReplacingOccurrencesOfString:@"?append=true" withString:@""];
            }
            
            if (![fm fileExistsAtPath:destPath]) {
                [fm createFileAtPath:destPath contents:[[NSData alloc] init] attributes:nil];
            }
            
            writeStream = [[NSOutputStream alloc] initToFileAtPath:destPath append:appendToExistingFile];
            [writeStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
            [writeStream open];
        }
        @catch(NSException * ex)
        {
            NSLog(@"write file error");
        }
    }
}

#pragma mark - Received Response
// set expected content length on response received
- (void) URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    expectedBytes = [response expectedContentLength];
    
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
    NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
    NSString * respType = @"";
    respStatus = statusCode;
    
    if ([response respondsToSelector:@selector(allHeaderFields)])
    {
        NSDictionary *headers = [httpResponse allHeaderFields];
        NSString * respCType = [[RNFetchBlobReqBuilder getHeaderIgnoreCases:@"Content-Type" fromHeaders:headers] lowercaseString];
        
        if (self.isServerPush) {
            if (partBuffer) {
                [self.bridge.eventDispatcher
                 sendDeviceEventWithName:EVENT_SERVER_PUSH
                 body:@{
                        @"taskId": taskId,
                        @"chunk": [partBuffer base64EncodedStringWithOptions:0],
                        }
                 ];
            }
            
            partBuffer = [[NSMutableData alloc] init];
            completionHandler(NSURLSessionResponseAllow);
            
            return;
        } else {
            self.isServerPush = [[respCType lowercaseString] RNFBContainsString:@"multipart/x-mixed-replace;"];
        }
        
        if(respCType)
        {
            NSArray * extraBlobCTypes = [options objectForKey:CONFIG_EXTRA_BLOB_CTYPE];
            
            if ([respCType RNFBContainsString:@"text/"]) {
                respType = @"text";
            } else if ([respCType RNFBContainsString:@"application/json"]) {
                respType = @"json";
            } else if(extraBlobCTypes) { // If extra blob content type is not empty, check if response type matches
                for (NSString * substr in extraBlobCTypes) {
                    if ([respCType RNFBContainsString:[substr lowercaseString]]) {
                        respType = @"blob";
                        respFile = YES;
                        destPath = [RNFetchBlobFS getTempPath:taskId withExtension:nil];
                        break;
                    }
                }
            } else {
                respType = @"blob";
                
                // for XMLHttpRequest, switch response data handling strategy automatically
                if ([options valueForKey:@"auto"]) {
                    respFile = YES;
                    destPath = [RNFetchBlobFS getTempPath:taskId withExtension:@""];
                }
            }
        } else {
            respType = @"text";
        }
        
#pragma mark - handling cookies
        // # 153 get cookies
        if (response.URL) {
            NSHTTPCookieStorage * cookieStore = [NSHTTPCookieStorage sharedHTTPCookieStorage];
            NSArray<NSHTTPCookie *> * cookies = [NSHTTPCookie cookiesWithResponseHeaderFields: headers forURL:response.URL];
            if (cookies.count) {
                [cookieStore setCookies:cookies forURL:response.URL mainDocumentURL:nil];
            }
        }
        
        [self.bridge.eventDispatcher
         sendDeviceEventWithName: EVENT_STATE_CHANGE
         body:@{
                @"taskId": taskId,
                @"state": @"2",
                @"headers": headers,
                @"redirects": redirects,
                @"respType" : respType,
                @"timeout" : @NO,
                @"status": [NSNumber numberWithInteger:statusCode]
                }
         ];
    } else {
        NSLog(@"oops");
    }
    
    [self configureWriteStream];
    
    completionHandler(NSURLSessionResponseAllow);
}


// download progress handler
- (void) URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    // For #143 handling multipart/x-mixed-replace response
    if (self.isServerPush)
    {
        [partBuffer appendData:data];
        
        return ;
    }
    
    NSNumber * received = [NSNumber numberWithLong:[data length]];
    receivedBytes += [received longValue];
    NSString * chunkString = @"";
    
    if (isIncrement) {
        chunkString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    
    if (respFile) {
        [writeStream write:[data bytes] maxLength:[data length]];
    } else {
        [respData appendData:data];
    }
    
    if (expectedBytes == 0) {
        return;
    }
    
    NSNumber * now =[NSNumber numberWithFloat:((float)receivedBytes/(float)expectedBytes)];
    if ([self.progressConfig shouldReport:now]) {
        [self.bridge.eventDispatcher
         sendDeviceEventWithName:EVENT_PROGRESS
         body:@{
                @"taskId": taskId,
                @"written": [NSString stringWithFormat:@"%lld", (long long) receivedBytes],
                @"total": [NSString stringWithFormat:@"%lld", (long long) expectedBytes],
                @"chunk": chunkString
                }
         ];
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
    self.error = error;
    NSString * errMsg;
    NSString * respStr;
    NSString * rnfbRespType;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
    });
    
    if (error) {
        if (self.customError) {
            errMsg = [self.customError localizedDescription];
        } else {
            if (error.code == NSURLErrorCannotWriteToFile) {
                [self removeResumeData];
                errMsg = NSLocalizedString(@"Something went wrong. Let's retry!", nil);
            } else {
                errMsg = [error localizedDescription];
            }
        }
    } else if (!shouldCompleteTask) {
        return;
    }
    
    [lock lock];
    if (respFile) {
        [writeStream close];
        rnfbRespType = RESP_TYPE_PATH;
        respStr = [self correctFilePath];
    } else { // base64 response
        // #73 fix unicode data encoding issue :
        // when response type is BASE64, we should first try to encode the response data to UTF8 format
        // if it turns out not to be `nil` that means the response data contains valid UTF8 string,
        // in order to properly encode the UTF8 string, use URL encoding before BASE64 encoding.
        NSString * utf8 = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding];
        
        if (responseFormat == BASE64) {
            rnfbRespType = RESP_TYPE_BASE64;
            respStr = [respData base64EncodedStringWithOptions:0];
        } else if (responseFormat == UTF8) {
            rnfbRespType = RESP_TYPE_UTF8;
            respStr = utf8;
        } else {
            if (utf8) {
                rnfbRespType = RESP_TYPE_UTF8;
                respStr = utf8;
            } else {
                rnfbRespType = RESP_TYPE_BASE64;
                respStr = [respData base64EncodedStringWithOptions:0];
            }
        }
    }
    
    if (callback) {
        callback(@[
                   errMsg ?: [NSNull null],
                   rnfbRespType ?: @"",
                   respStr ?: [NSNull null]
                   ]);
    }
    callback = nil;
    respData = nil;
    receivedBytes = 0;
    self.task = nil;
    /// Remove cached resumeable data in storage if exists
    if (!error) {
        [self removeResumeData];
    }
    [session invalidateAndCancel];
    /// Remove the self from caching table
    [[[RNFetchBlobNetwork sharedInstance] requestsTable] removeObjectForKey:taskId];
    [lock unlock];
}

- (void)removeResumeData
{
    NSString *tempPath = [self correctTempPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:tempPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
    }
}

- (void)writeResumeData:(NSData *)data;
{
    NSString *tempPath = [self correctTempPath];
    NSString *tempFile = [[RNFetchBlobFS getTempPath] stringByAppendingPathComponent:[tempPath lastPathComponent]];
    BOOL written = [[NSFileManager defaultManager] createFileAtPath:tempFile contents:data attributes:nil];
    if (!written) {
        NSLog(@"cannot write");
    }
    [RNFetchBlobFS exists:tempPath callback:^(NSArray *response) {
        NSError *err;
        if ([response.firstObject boolValue]) {
            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:&err];
        }
        [[NSFileManager defaultManager] moveItemAtPath:tempFile toPath:tempPath error:&err];
        if (err) {
            NSLog(@"error: %@", err);
        }
    }];
}

- (NSData *)retrieveResumeData;
{
    NSString *tempPath = [self correctTempPath];
    return [[NSFileManager defaultManager] contentsAtPath:tempPath];
}

- (NSString *)correctPath:(NSString *)path;
{
    if (!path) {
        return path;
    }
    NSArray *crrComps = [[RNFetchBlobFS getDocumentDir] componentsSeparatedByString:@"/"];
    NSUInteger crrIdx = [crrComps indexOfObject:@"Application"];
    NSMutableArray *preferComps = [NSMutableArray arrayWithArray:[path componentsSeparatedByString:@"/"]];
    NSUInteger preferIdx = [preferComps indexOfObject:@"Application"];
    if (crrIdx != NSNotFound && preferIdx != NSNotFound && ![crrComps[crrIdx + 1] isEqualToString:preferComps[preferIdx + 1]]) {
        preferComps[preferIdx + 1] = crrComps[crrIdx + 1];
        NSString *newPath = [preferComps componentsJoinedByString:@"/"];
        return newPath;
    }
    return path;
}

- (NSString *)correctTempPath;
{
    if ([destPath containsString:@".download"]) {
        return destPath;
    }
    return [destPath stringByAppendingString:@".download"];
}

- (NSString *)correctFilePath;
{
    if ([destPath containsString:@".download"]) {
        return [destPath stringByDeletingPathExtension];
    }
    return destPath;
}

// upload progress handler
- (void) URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didSendBodyData:(int64_t)bytesSent totalBytesSent:(int64_t)totalBytesWritten totalBytesExpectedToSend:(int64_t)totalBytesExpectedToWrite
{
    if (totalBytesExpectedToWrite == 0) {
        return;
    }
    
    NSNumber * now = [NSNumber numberWithFloat:((float)totalBytesWritten/(float)totalBytesExpectedToWrite)];
    
    if ([self.uploadProgressConfig shouldReport:now]) {
        [self.bridge.eventDispatcher
         sendDeviceEventWithName:EVENT_PROGRESS_UPLOAD
         body:@{
                @"taskId": taskId,
                @"written": [NSString stringWithFormat:@"%ld", (long) totalBytesWritten],
                @"total": [NSString stringWithFormat:@"%ld", (long) totalBytesExpectedToWrite]
                }
         ];
    }
}


- (void) URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable credantial))completionHandler
{
    if ([[options valueForKey:CONFIG_TRUSTY] boolValue]) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
    }
}


- (void) URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session
{
    if ([RNFetchBlobNetwork sharedInstance].completion) {
        [RNFetchBlobNetwork sharedInstance].completion();
    }
}

- (void) URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler
{
    
    if (followRedirect) {
        if (request.URL) {
            [redirects addObject:[request.URL absoluteString]];
        }
        
        completionHandler(request);
    } else {
        completionHandler(nil);
    }
}

// MARK: - For Download Task delegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didResumeAtOffset:(int64_t)fileOffset expectedTotalBytes:(int64_t)expectedTotalBytes {
    [self handleDownloadProgress:(float)fileOffset total:(float)expectedTotalBytes url:downloadTask.currentRequest.URL.absoluteString];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error;
    [fileManager removeItemAtPath:destPath error:NULL];
    NSString *filePath = [self correctFilePath];
    [fileManager removeItemAtPath:filePath error:NULL];
    [fileManager copyItemAtPath:location.path toPath:filePath error:&error];
    if (error) {
        NSLog(@"Moved with error: %@", error);
    }
    respData = [NSMutableData dataWithData:[fileManager contentsAtPath:filePath]];
    shouldCompleteTask = true;
    [self URLSession:session task:downloadTask didCompleteWithError:error];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (totalBytesExpectedToWrite == 0) {
        return;
    }
    [self handleDownloadProgress:(float)totalBytesWritten total:(float)totalBytesExpectedToWrite url:downloadTask.currentRequest.URL.absoluteString];
}

- (void)handleDownloadProgress:(float)totalBytesWritten total:(float)totalBytesExpectedToWrite url:(NSString *)url
{
    NSNumber *now = [NSNumber numberWithFloat:(totalBytesWritten/totalBytesExpectedToWrite)];
    /// Send progress event continuously without condition checker
    if ([self.progressConfig shouldReport:now]) {
        if (RNFetchBlobNetwork.sharedInstance.isActive) {
            [self.bridge.eventDispatcher
             sendDeviceEventWithName:EVENT_PROGRESS
             body:@{
                    @"taskId": taskId,
                    @"written": [NSString stringWithFormat:@"%lld", (long long) totalBytesWritten],
                    @"total": [NSString stringWithFormat:@"%lld", (long long) totalBytesExpectedToWrite]
                    }
             ];
        }
    }
}

/// MARK: - Correct Resumeable data
- (NSData *)correctRequestData:(NSData *)data
{
    if (!data) {
        return nil;
    }
    if ([NSKeyedUnarchiver unarchiveObjectWithData:data]) {
        return data;
    }
    
    NSMutableDictionary *archive = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainersAndLeaves format:nil error:nil];
    if (!archive) {
        return nil;
    }
    int k = 0;
    while ([[archive[@"$objects"] objectAtIndex:1] objectForKey:[NSString stringWithFormat:@"$%d", k]]) {
        k += 1;
    }
    
    int i = 0;
    while ([[archive[@"$objects"] objectAtIndex:1] objectForKey:[NSString stringWithFormat:@"__nsurlrequest_proto_prop_obj_%d", i]]) {
        NSMutableArray *arr = archive[@"$objects"];
        NSMutableDictionary *dic = [arr objectAtIndex:1];
        id obj;
        if (dic) {
            obj = [dic objectForKey:[NSString stringWithFormat:@"__nsurlrequest_proto_prop_obj_%d", i]];
            if (obj) {
                [dic setObject:obj forKey:[NSString stringWithFormat:@"$%d",i + k]];
                [dic removeObjectForKey:[NSString stringWithFormat:@"__nsurlrequest_proto_prop_obj_%d", i]];
                arr[1] = dic;
                archive[@"$objects"] = arr;
            }
        }
        i += 1;
    }
    if ([[archive[@"$objects"] objectAtIndex:1] objectForKey:@"__nsurlrequest_proto_props"]) {
        NSMutableArray *arr = archive[@"$objects"];
        NSMutableDictionary *dic = [arr objectAtIndex:1];
        if (dic) {
            id obj;
            obj = [dic objectForKey:@"__nsurlrequest_proto_props"];
            if (obj) {
                [dic setObject:obj forKey:[NSString stringWithFormat:@"$%d",i + k]];
                [dic removeObjectForKey:@"__nsurlrequest_proto_props"];
                arr[1] = dic;
                archive[@"$objects"] = arr;
            }
        }
    }
    
    id obj = [archive[@"$top"] objectForKey:@"NSKeyedArchiveRootObjectKey"];
    if (obj) {
        [archive[@"$top"] setObject:obj forKey:NSKeyedArchiveRootObjectKey];
        [archive[@"$top"] removeObjectForKey:@"NSKeyedArchiveRootObjectKey"];
    }
    NSData *result = [NSPropertyListSerialization dataWithPropertyList:archive format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return result;
}

- (NSMutableDictionary *)getResumDictionary:(NSData *)data
{
    NSMutableDictionary *iresumeDictionary;
    if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion >= 10) {
        NSMutableDictionary *root;
        NSKeyedUnarchiver *keyedUnarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:data];
        NSError *error = nil;
        root = [keyedUnarchiver decodeTopLevelObjectForKey:@"NSKeyedArchiveRootObjectKey" error:&error];
        if (!root) {
            root = [keyedUnarchiver decodeTopLevelObjectForKey:NSKeyedArchiveRootObjectKey error:&error];
        }
        [keyedUnarchiver finishDecoding];
        iresumeDictionary = root;
    }
    
    if (!iresumeDictionary) {
        iresumeDictionary = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
    }
    return iresumeDictionary;
}

static NSString * kResumeCurrentRequest = @"NSURLSessionResumeCurrentRequest";
static NSString * kResumeOriginalRequest = @"NSURLSessionResumeOriginalRequest";
- (NSData *)correctResumData:(NSData *)data
{
    NSMutableDictionary *resumeDictionary = [self getResumDictionary:data];
    if (!data || !resumeDictionary) {
        return nil;
    }
    
    resumeDictionary[kResumeCurrentRequest] = [self correctRequestData:[resumeDictionary objectForKey:kResumeCurrentRequest]];
    resumeDictionary[kResumeOriginalRequest] = [self correctRequestData:[resumeDictionary objectForKey:kResumeOriginalRequest]];
    
    NSData *result = [NSPropertyListSerialization dataWithPropertyList:resumeDictionary format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    return result;
}

- (NSURLSessionDownloadTask *)correctedDownloadTaskWithResumeData:(NSData *)data withSession:(NSURLSession *)session {
    NSString *kResumeCurrentRequest = @"NSURLSessionResumeCurrentRequest";
    NSString *kResumeOriginalRequest = @"NSURLSessionResumeOriginalRequest";
    
    NSData *cData = [self correctResumData:data];
    cData = cData ? cData : data;
    NSURLSessionDownloadTask *task = [session downloadTaskWithResumeData:cData];
    NSMutableDictionary *resumeDic = [self getResumDictionary:cData];
    if (resumeDic) {
        if (task.originalRequest == nil) {
            NSData *originalReqData = resumeDic[kResumeOriginalRequest];
            NSURLRequest *originalRequest = [NSKeyedUnarchiver unarchiveObjectWithData:originalReqData ];
            if (originalRequest) {
                [task setValue:originalRequest forKey:@"originalRequest"];
            }
        }
        if (task.currentRequest == nil) {
            NSData *currentReqData = resumeDic[kResumeCurrentRequest];
            NSURLRequest *currentRequest = [NSKeyedUnarchiver unarchiveObjectWithData:currentReqData];
            if (currentRequest) {
                [task setValue:currentRequest forKey:@"currentRequest"];
            }
        }
        
    }
    [task resume];
    return task;
}

@end

