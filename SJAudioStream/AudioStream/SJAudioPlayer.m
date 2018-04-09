//
//  SJAudioPlayer.m
//  AudioTest
//
//  Created by 张诗健 on 16/4/29.
//  Copyright © 2016年 张诗健. All rights reserved.
//

#import "SJAudioPlayer.h"
#import <pthread.h>
#import <AVFoundation/AVFoundation.h>
#import "SJAudioDataProvider.h"
#import "SJAudioFileStream.h"
#import "SJAudioOutputQueue.h"
#import "SJParsedAudioData.h"
#import "SJAudioBuffer.h"


@interface SJAudioPlayer ()<SJAudioFileStreamDelegate>
{
    pthread_mutex_t _mutex;
    pthread_cond_t  _cond;
}

@property (nonatomic, strong) SJAudioFileStream *audioFileStream;

@property (nonatomic, strong) SJAudioOutputQueue *audioQueue;

@property (nonatomic, strong) SJAudioDataProvider *dataProvider;

@property (nonatomic, strong) SJAudioBuffer *buffer;

@property (nonatomic, strong) NSString *cachePath;

@property (nonatomic, assign) NSUInteger byteOffset;

@property (nonatomic, assign) NSUInteger bufferSize;

@property (nonatomic, assign) BOOL started;

@property (nonatomic, assign) BOOL pausedByInterrupt;

@property (nonatomic, assign) BOOL completed;

@property (nonatomic, assign) BOOL userStop;

@property (nonatomic, assign) BOOL seekRequired;

@property (nonatomic, assign) BOOL pauseRequired;

@property (nonatomic, assign) NSTimeInterval seekTime;

@property (nonatomic,readwrite, strong) NSString *urlString;

@property (nonatomic,readwrite, assign) NSUInteger contentLength;

@property (nonatomic,readwrite, assign) NSTimeInterval duration;

@property (nonatomic,readwrite, assign) SJAudioPlayerStatus status;

@end



@implementation SJAudioPlayer


- (void)dealloc
{
    pthread_mutex_destroy(&_mutex);
    pthread_cond_destroy(&_cond);
}


- (instancetype)initWithUrlString:(NSString *)url cachePath:(NSString *)cachePath
{
    NSAssert(url, @"url should be not nil");
    
    self = [super init];
    
    if (self)
    {
        self.urlString  = url;
        self.cachePath  = cachePath;
        self.bufferSize = kDefaultBufferSize;
        self.started    = NO;
        
        pthread_mutex_init(&_mutex, NULL);
        pthread_cond_init(&_cond, NULL);
    }
    return self;
}

// 在播放停止或者出错时会进入到清理流程，这里需要一大堆操作，清理各种数据，关闭AudioSession，清除各种标记等;
- (void)cleanUp
{
    [self.audioFileStream close];
    self.audioFileStream = nil;
    
    self.started   = NO;
    self.completed = NO;
    self.contentLength = 0;
    self.buffer        = nil;
    self.byteOffset    = 0;
    self.dataProvider  = nil;
    self.audioQueue    = nil;
    self.status        = SJAudioPlayerStatusStopped;
}


#pragma mark - methods
/**
 *  播放
 */
- (void)play
{
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    
    // 激活音频会话控制
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    
    if (!self.started)
    {
        [self start];
        
    }else
    {
        if (self.status == SJAudioPlayerStatusPaused)
        {
            [self resume];
        }
    }
}



- (void)start
{
    self.started = YES;
    
    NSThread  *readDataThread = [[NSThread alloc] initWithTarget:self selector:@selector(enqueneAudioData) object:nil];
    
    [readDataThread setName:@"Read Data Thread"];
    
    [readDataThread start];
    
    NSThread *playAudioThread = [[NSThread alloc] initWithTarget:self selector:@selector(playAudioData) object:nil];
    
    [playAudioThread setName:@"Play Audio Thread"];
    
    [playAudioThread start];
}


- (void)pause
{
    pthread_mutex_lock(&_mutex);
    self.pauseRequired = YES;
    pthread_mutex_unlock(&_mutex);
}


- (void)resume
{
    pthread_mutex_lock(&_mutex);
    
    if (self.pauseRequired)
    {
        pthread_cond_signal(&_cond);    // 解除阻塞
    }
    
    pthread_mutex_unlock(&_mutex);
}


- (void)stop
{
    pthread_mutex_lock(&_mutex);
    self.userStop = YES;
    pthread_mutex_unlock(&_mutex);
}


- (void)seekToProgress:(NSTimeInterval)timeOffset
{
    self.seekTime = timeOffset;
    
    if (self.completed)
    {
        self.byteOffset = [self.audioFileStream seekToTime:&_seekTime];
    }else
    {
        if (self.byteOffset < [self.buffer bufferedSize])
        {
            self.byteOffset = [self.audioFileStream seekToTime:&_seekTime];
        }else
        {
            self.byteOffset = [self.audioFileStream seekToTime:&_seekTime];
            [self.buffer clean];
            [self.audioQueue reset];
            self.dataProvider = nil;
        }
    }
}


- (void)enqueneAudioData
{
    self.completed = NO;
    self.userStop  = NO;
    
    NSError *error = nil;
    NSError *readDataError = nil;
    NSError *parseDataError = nil;
    
    while (!self.completed && !self.userStop)
    {
        if (!self.dataProvider)
        {
            self.dataProvider = [[SJAudioDataProvider alloc] initWithURL:[NSURL URLWithString:self.urlString] cacheFilePath:self.cachePath byteOffset:self.byteOffset];
        }
        
        NSData *data = [self.dataProvider readDataWithMaxLength:self.bufferSize error:&readDataError completed:&_completed];
        
        if (readDataError)
        {
            NSLog(@"read data: error");
            break;
        }
        
        if (self.completed)
        {
            [self.dataProvider close];
            
            NSLog(@"read data: complete");
        }
        
        if (self.userStop)
        {
            [self.dataProvider close];
            self.dataProvider = nil;
            NSLog(@"read data: stop");
            break;
        }
        
        if (self.dataProvider.contentLength && !self.audioFileStream)
        {
            self.contentLength   = self.dataProvider.contentLength;
            
            self.audioFileStream = [[SJAudioFileStream alloc] initWithFileType:hintForFileExtension([NSURL URLWithString:self.urlString].pathExtension) fileSize:self.contentLength error:&error];
            
            self.audioFileStream.delegate = self;
            
            self.buffer = [SJAudioBuffer buffer];
            
        }
        
        if (self.audioFileStream)
        {
            [self.audioFileStream parseData:data error:&parseDataError];
        }
    }
}


- (void)playAudioData
{
    while (!self.userStop && self.byteOffset <= self.contentLength && self.status != SJAudioPlayerStatusFinished) {
        
        if (self.userStop)
        {
            [self.audioQueue stop:YES];
            
            NSLog(@"play audio: stop");
            
            break;
        }
        
        pthread_mutex_lock(&_mutex);
        
        if (self.pauseRequired)
        {
            NSLog(@"play audio: pause");
            
            [self.audioQueue pause];
            
            self.status = SJAudioPlayerStatusPaused;
            
            pthread_cond_wait(&_cond, &_mutex); // 阻塞
            
            [self.audioQueue resume];

            self.pauseRequired = NO;
                
            self.status = SJAudioPlayerStatusPlaying;
            
            NSLog(@"play audio: play");
        }
        
        pthread_mutex_unlock(&_mutex);
        
        if (self.audioQueue)
        {
            if ([self.buffer hasData])
            {
                UInt32 packetCount;
                
                AudioStreamPacketDescription *desces = NULL;
                
                if ([self.buffer bufferedSize] >= self.bufferSize)
                {
                    NSData *data = [self.buffer dequeueDataWithSize:(UInt32)self.bufferSize packetCount:&packetCount descriptions:&desces];
                    
                    [self.audioQueue playData:data packetCount:packetCount packetDescriptions:desces completed:self.completed];
                    
                }else
                {
                    NSData *data = [self.buffer dequeueDataWithSize:[self.buffer bufferedSize] packetCount:&packetCount descriptions:&desces];
                    
                    [self.audioQueue playData:data packetCount:packetCount packetDescriptions:desces completed:self.completed];
                }
                
                free(desces);
                
                self.status = SJAudioPlayerStatusPlaying;
                
            }else
            {
                NSLog(@"%u",(unsigned int)[self.buffer bufferedSize]);
                
                [self.audioQueue stop:NO];
                
                self.status = SJAudioPlayerStatusFinished;
                
                NSLog(@"play audio: complete");
            }
        }else
        {
            if ([self.buffer hasData])
            {
                [self createAudioQueue];
            }
        }
    }
    
    [self cleanUp];
}


- (void)createAudioQueue
{
    NSData *magicCookie = [self.audioFileStream fetchMagicCookie];
    
    AudioStreamBasicDescription format = self.audioFileStream.format;
    
    self.audioQueue = [[SJAudioOutputQueue alloc] initWithFormat:format bufferSize:(UInt32)self.bufferSize macgicCookie:magicCookie];
    
    if (!self.audioQueue.available)
    {
        self.audioQueue = nil;
    }
}


- (NSTimeInterval)duration
{
    return self.audioFileStream.duration;
}

#pragma mark -delegate
- (void)audioFileStream:(SJAudioFileStream *)audioFileStream audioDataParsed:(NSArray *)audioData
{
    [self.buffer enqueueFromDataArray:audioData];
}



/**
 *  根据 URL的pathExtension 识别音频格式
 */
AudioFileTypeID hintForFileExtension(NSString *fileExtension)
{
    AudioFileTypeID fileTypeHint = 0;
    if ([fileExtension isEqual:@"mp3"])
    {
        fileTypeHint = kAudioFileMP3Type;
    }
    else if ([fileExtension isEqual:@"wav"])
    {
        fileTypeHint = kAudioFileWAVEType;
    }
    else if ([fileExtension isEqual:@"aifc"])
    {
        fileTypeHint = kAudioFileAIFCType;
    }
    else if ([fileExtension isEqual:@"aiff"])
    {
        fileTypeHint = kAudioFileAIFFType;
    }
    else if ([fileExtension isEqual:@"m4a"])
    {
        fileTypeHint = kAudioFileM4AType;
    }
    else if ([fileExtension isEqual:@"mp4"])
    {
        fileTypeHint = kAudioFileMPEG4Type;
    }
    else if ([fileExtension isEqual:@"caf"])
    {
        fileTypeHint = kAudioFileCAFType;
    }
    else if ([fileExtension isEqual:@"aac"])
    {
        fileTypeHint = kAudioFileAAC_ADTSType;
    }
    return fileTypeHint;
}

@end
