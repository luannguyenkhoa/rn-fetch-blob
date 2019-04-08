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

@implementation RNFetchBlobRequest

@synthesize taskId;
@synthesize callback;
@synthesize bridge;

// send HTTP request
- (void) sendRequest:(__weak NSDictionary  * _Nullable )options
              bridge:(RCTBridge * _Nullable)bridgeRef
              taskId:(NSString * _Nullable)taskId
         withRequest:(__weak NSURLRequest * _Nullable)req
           inSession:(NSURLSession * _Nullable)session
            callback:(_Nullable RCTResponseSenderBlock) callback
{
  self.taskId = taskId;
  self.callback = callback;
  self.bridge = bridgeRef;
  self.shouldCompleteTask = false;
  self.lock = [[NSLock alloc] init];
  
  self.destPath = [self correctPath:[options valueForKey:CONFIG_FILE_PATH]];
  NSMutableURLRequest *mutableReq = (NSMutableURLRequest *)req;
  // set request/resource timeout
  if (@available(iOS 8.0, *)) {
    mutableReq.timeoutInterval = 30.0;
  }
  self.reqURL = mutableReq.URL.absoluteString;
  NSURLSessionDownloadTask *task;
  NSData *resumeableData = [self retrieveResumeData];
  [self removeResumeData];
  if (resumeableData) {
    task = [session downloadTaskWithResumeData:resumeableData];
  } else {
    task = [session downloadTaskWithRequest:mutableReq];
  }
  self.task = task;
  [task resume];
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
  [self.lock lock];
  NSString *tempPath = [self correctTempPath];
  if ([[NSFileManager defaultManager] contentsAtPath:tempPath].length == data.length) {
    return;
  }
  
  NSString *tempFile = [[RNFetchBlobFS getTempPath] stringByAppendingPathComponent:[tempPath lastPathComponent]];
  BOOL written = [[NSFileManager defaultManager] createFileAtPath:tempFile contents:data attributes:nil];
  if (!written) {
    NSLog(@"cannot write");
  }
  NSError *err;
  if ([[NSFileManager defaultManager] fileExistsAtPath:tempPath]) {
    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:&err];
  }
  [[NSFileManager defaultManager] moveItemAtPath:tempFile toPath:tempPath error:&err];
  if (err) {
    NSLog(@"error move: %@", err);
  }
  
  [self.lock unlock];
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
  if ([self.destPath containsString:@".download"]) {
    return self.destPath;
  }
  return [self.destPath stringByAppendingString:@".download"];
}

- (NSString *)correctFilePath;
{
  if ([self.destPath containsString:@".download"]) {
    return [self.destPath stringByDeletingPathExtension];
  }
  return self.destPath;
}

@end


