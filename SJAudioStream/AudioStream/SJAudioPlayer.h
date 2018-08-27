//
//  SJAudioPlayer.h
//  SJAudioStream
//
//  Created by 张诗健 on 16/4/29.
//  Copyright © 2016年 张诗健. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, SJAudioPlayerStatus)
{
    SJAudioPlayerStatusIdle     = 0,
    SJAudioPlayerStatusWaiting  = 1,
    SJAudioPlayerStatusPlaying  = 2,
    SJAudioPlayerStatusPaused   = 3,
    SJAudioPlayerStatusFinished = 4
};



@interface SJAudioPlayer : NSObject

@property (nonatomic, readonly, strong) NSURL *url;

@property (nonatomic, readonly, assign) NSUInteger contentLength;

@property (nonatomic, readonly, assign) NSTimeInterval duration;

@property (nonatomic, readonly, assign) NSTimeInterval playedTime;

@property (nonatomic, readonly, assign) SJAudioPlayerStatus status;


- (instancetype)initWithUrl:(NSURL *)url;

- (void)play;

- (void)pause;

- (void)seekToProgress:(NSTimeInterval)timeOffset;

- (void)stop;

@end
