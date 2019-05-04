//
//  RNFetchBlobRequest.h
//  RNFetchBlob
//
//  Created by Artur Chrusciel on 15.01.18.
//  Copyright © 2018 wkh237.github.io. All rights reserved.
//

#ifndef RNFetchBlobRequest_h
#define RNFetchBlobRequest_h

#import <Foundation/Foundation.h>

#import "RNFetchBlobProgress.h"

#if __has_include(<React/RCTAssert.h>)
#import <React/RCTBridgeModule.h>
#else
#import "RCTBridgeModule.h"
#endif

@interface RNFetchBlobRequest : NSObject

@property (nullable, nonatomic) NSString * taskId;
@property (nullable, strong, nonatomic) RCTResponseSenderBlock callback;
@property (nullable, nonatomic) RCTBridge * bridge;
@property (nullable, nonatomic) RNFetchBlobProgress *progressConfig;
@property (nullable, nonatomic) NSError* customError;
@property (nonnull, nonatomic) NSString *reqURL;
@property (nonnull, nonatomic) NSString *destPath;
@property (nonatomic, assign) BOOL shouldCompleteTask;
@property (nonatomic, nullable) NSURLSessionDownloadTask *task;

- (void) sendRequest:(__weak NSDictionary  * _Nullable )options
              bridge:(RCTBridge * _Nullable)bridgeRef
              taskId:(NSString * _Nullable)taskId
         withRequest:(__weak NSURLRequest * _Nullable)req
           inSession:(NSURLSession *_Nullable)session
            callback:(_Nullable RCTResponseSenderBlock) callback;

/// Path handlings
- (void)removeResumeData;
- (void)writeResumeData:(NSData *_Nullable)data;
- (NSString *_Nullable)correctPath:(NSString *_Nullable)path;
- (NSString *_Nullable)correctTempPath;
- (NSString *_Nullable)correctFilePath;

@end

#endif /* RNFetchBlobRequest_h */


