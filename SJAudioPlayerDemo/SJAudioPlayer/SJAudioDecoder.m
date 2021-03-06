//
//  SJAudioDecoder.m
//  SJAudioPlayerDemo
//
//  Created by 张诗健 on 2020/5/22.
//  Copyright © 2020 张诗健. All rights reserved.
//

#import "SJAudioDecoder.h"



@interface SJAudioDecoder()

@property (nonatomic, weak) id<SJAudioDecoderDelegate> delegate;

@property (nonatomic, assign) NSUInteger audioContentLength;

@property (nonatomic, assign) AudioFileStreamID audioFileStreamID;

@property (nonatomic, assign) AudioStreamBasicDescription format;

@property (nonatomic, assign) NSTimeInterval duration;

@property (nonatomic, assign) UInt32 bitRate;

@property (nonatomic, assign) UInt64 audioDataByteCount;

@property (nonatomic, assign) SInt64 dataOffset;

@property (nonatomic, assign) BOOL discontinuous;

@property (nonatomic, assign) NSTimeInterval packetDuration;

@end



@implementation SJAudioDecoder




+ (instancetype)startDecodeAudioWithAudioType:(NSString *)audioType
                           audioContentLength:(NSUInteger)audioContentLength
                                     delegate:(id<SJAudioDecoderDelegate>)delegate
{
    SJAudioDecoder *decoder = [[SJAudioDecoder alloc] initWithAudioContentLength:audioContentLength delegate:delegate];
    
    BOOL success = [decoder openAudioFileStreamWithFileTypeID:SJAudioFileTypeIdForFileExtension(audioType)];
    
    return success ? decoder : nil;
}



- (instancetype)initWithAudioContentLength:(NSUInteger)audioContentLength delegate:(id<SJAudioDecoderDelegate>)delegate
{
    self = [super init];
    
    if (self)
    {
        self.discontinuous = NO;
        
        self.audioContentLength = audioContentLength;
        
        self.delegate = delegate;
    }
    
    return self;
}



- (BOOL)openAudioFileStreamWithFileTypeID:(AudioFileTypeID)fileTypeID
{
    // 打开AudioFileStream来读取采样率、码率、时长等基本信息以及分离音频帧。
    OSStatus status = AudioFileStreamOpen((__bridge void * _Nullable)(self), SJAudioFileStreamPropertyListener, SJAudioFileStreamPacketsCallBack, fileTypeID, &_audioFileStreamID);
    
    if (status != noErr)
    {
        self.audioFileStreamID = NULL;
    }
    
    return status == noErr;
}



- (void)endDecode
{
    if (self.audioFileStreamID != NULL)
    {
        AudioFileStreamClose(self.audioFileStreamID);
        
        self.audioFileStreamID = NULL;
    }
}




- (BOOL)parseAudioData:(NSData *)data
{
    /*
     AudioFileStreamID: 初始化时返回的id
     inDataByteSize   : 本次解析的数据长度
     inData : 本次要解析的数据
     inFlags: 本次解析和上一次解析是否是连续的关系，如果是连续的传入0，否则传入kAudioFileStreamParseFlag_Discontinuity。
     
     MP3的数据都以帧的形式存在的，解析时也需要以帧为单位解析。但在解码之前我们不可能知道每个帧的边界在第几个
     字节，所以就会出现这样的情况：我们传给`AudioFileStreamParseBytes`的数据在解析完成之后会有一部分数据
     余下来，这部分数据是接下去那一帧的前半部分，如果再次有数据输入需要继续解析时就必须要用到前一次解析余下来
     的数据才能保证帧数据完整，所以在正常播放的情况下传入0即可。
     
     在seek完毕之后，seek后的数据和之前的数据完全无关，需要传入
     kAudioFileStreamParseFlag_Discontinuity。
     */
    OSStatus status = AudioFileStreamParseBytes(self.audioFileStreamID, (UInt32)[data length], [data bytes], self.discontinuous ? kAudioFileStreamParseFlag_Discontinuity : 0);
    
    return status == noErr;
}

/*
 seek : 拖动到xx分xx秒，而实际操作时我们需要操作的是文件，就是要从第几个字节开始读取音频数据。对于原始的PCM数据来说，每一个PCM帧都是固定长度的，对应的播放时长也是固定的。但一旦转换成压缩后的音频数据就会因为编码形式的不同而不同了，对于CBR（固定码率）而言每个帧中所包含的PCM数据帧是恒定的，所以每一帧对应的播放时长也是恒定的；而VBR（可变码率）则不同，为了保证数据最优并且文件大小最小，VBR的每一帧中所包含的PCM数据帧是不固定的，这就导致在流播放的情况下VBR的数据想要做seek并不容易。
 
 CBR下的seek：
 
 double seekToTime ＝ ...; // 需要seek到哪个时间，秒为单位
 Uint64 audioDataByteCount = ...; // 通过kAudioFileStreamProperty_AudioDataByteCount获取的值
 Sint64 dataOffset = ...; // 通过kAudioFileStreamProperty_DataOffset获取的值
 double duration = ...; // 通过公式(AudioDataByteCount * 8) / BitRate 计算得到时长
 
 按照`seekByteOffset`读取对应的数据继续使用`AudioFileStreamParseByte`方法来进行解析
 如果是网络流可以通过设置range头来获取字节，本地文件的话直接seek就好。
 调用`AudioFileStreamParseByte`函数时，注意刚seek完后第一次parse数据时，需要加参数kAudioFileStreamParseFlag_Discontinuity。
 */
- (SInt64)seekToTime:(NSTimeInterval *)time
{
    // 近似seekOffset = 数据偏移 + seekToTime对应的近似字节数
    SInt64 approximateSeekoffset = self.dataOffset + (*time / self.duration) * self.audioDataByteCount;
    
    // 计算packet位置
    SInt64 seekToPacket = floor(*time / self.packetDuration);
    SInt64 seekByteOffset;
    UInt32 ioFlags = 0;
    SInt64 outDataByteOffset;
    
    
    // 使用`AudioStreamSeek`计算精确的字节偏移和时间。可以用该函数来寻找某一个帧（packet）对应的字节偏移（byte offset）：如果`ioFlags`里有`kAudioFileStreamFlag_OffsetIsEstimated`，说明给出的`outDataByteOffset`是估算的，并不准确，那么还是应该用第一步计算出来的`approximateSeekOffset`来做seek；如果`ioFlags`里没有 kAudioFileStreamFlag_OffsetIsEstimated 说明给出了准确的outDataByteOffset， 其就是输入的`seekToPacket`对应的字节偏移量，可以根据`outDataByteOffset`来计算出精确的`seekOffset`和`seekToTime`。
    OSStatus status = AudioFileStreamSeek(self.audioFileStreamID, seekToPacket, &outDataByteOffset, &ioFlags);
    
    if (status == noErr && !(ioFlags & kAudioFileStreamSeekFlag_OffsetIsEstimated))
    {
        // 如果AudioFileStreamSeek方法找到了准确的帧字节偏移，就需要修正一下时间
        *time -= ((approximateSeekoffset - self.dataOffset) - outDataByteOffset) * 8.0 / self.bitRate;
        
        seekByteOffset = outDataByteOffset + self.dataOffset;
    }else
    {
        self.discontinuous = YES;
        
        seekByteOffset = approximateSeekoffset;
    }
    
    return seekByteOffset;
}





/*
 获取时长的最佳方法是从ID3信息中去读取，那样是最准确的。如果ID3信息中没有存，那就依赖于文件头中的信息去计算。
 
 音频数据的字节总量`audioDataByteCount`可以通`kAudioFileStreamProperty_AudioDataByteCount`获取，
 码率`bitRate`可以通过`kAudioFileStreamProperty_BitRate`获取，也可以通过解析一部分数据后计算平均码率
 来得到。
 */
- (void)calculateDuration
{
    if (self.audioContentLength && self.bitRate)
    {
        self.duration = (self.audioDataByteCount * 8.0) / self.bitRate;
    }
}



/*
 利用之前解析得到的音频格式信息来计算PacketDuration（每一帧数据对应的时长）。
 */
- (void)calculatePacketDuration
{
    if (self.format.mSampleRate > 0.0)
    {
        self.packetDuration = self.format.mFramesPerPacket / self.format.mSampleRate;
    }
}



/*
 在调用`AudioFileStreamParseBytes`方法进行解析时会首先读取格式信息，每解析出一个音频的格式信息都会同步调
 用一次此方法。
 
 注意`AudioFileStreamParseBytes`方法每一次调用都应该注意返回值，一旦出现错误就可以不用继续解析了。
 */
static void SJAudioFileStreamPropertyListener(void *inClientData, AudioFileStreamID inAudioFileStream, AudioFileStreamPropertyID inPropertyID, UInt32 *ioFlags)
{
    SJAudioDecoder *decoder = (__bridge SJAudioDecoder *)inClientData;
    
    [decoder handleAudioFileStreamProperty:inPropertyID];
}



- (void)handleAudioFileStreamProperty:(AudioFileStreamPropertyID)propertyID
{
    switch (propertyID)
    {
        case kAudioFileStreamProperty_BitRate:
        {
            UInt32 bitRateSize = sizeof(self.bitRate);
            
            AudioFileStreamGetProperty(self.audioFileStreamID, kAudioFileStreamProperty_BitRate, &bitRateSize, &_bitRate);
        }
            break;
            
        case kAudioFileStreamProperty_DataFormat:
        {
            UInt32 asbdSize = sizeof(self.format);
            
            // kAudioFileStreamProperty_DataFormat用来描述音频数据的格式
            AudioFileStreamGetProperty(self.audioFileStreamID, kAudioFileStreamProperty_DataFormat, &asbdSize, &_format);
            
            [self calculatePacketDuration];
        }
            break;
            
        case kAudioFileStreamProperty_FormatList:
        {
            Boolean outWriteable;
            UInt32 formatListSize;
            
            // kAudioFileStreamProperty_FormatList (为了支持包括AAC和SBR格式编码的数据流可以被解码到多个目的地的格式，此属性返回包含这些格式的AudioFormatListItems数组（见AudioFormat.h）。默认行为是与kAudioFileStreamProperty_DataFormat属性返回相同的AudioStreamBasicDescription的一个AudioFormatListItem。)
            // 该方法用来获取某个属性对应的数据的大小(outDataSize)以及该属性是否可以被write（isWriteable）AudioFileStreamGetProperty用来获取属性对应的数据.对于一些大小可变的属性需要先使用 AudioFileStreamGetPropertyInfo获取数据大小，之后才能获取数据(例如formatList)。而有些确定类型单个属性则不必先调用AudioFileGetPropertyInfo，直接调用AudioFileGetProperty即可（比如BitRate）。
            OSStatus status = AudioFileStreamGetPropertyInfo(self.audioFileStreamID, kAudioFileStreamProperty_FormatList, &formatListSize, &outWriteable);
            
            if (status == noErr)
            {
                // 获取formatlist
                AudioFormatListItem *formatlist = malloc(formatListSize);
                
                OSStatus status = AudioFileStreamGetProperty(self.audioFileStreamID, kAudioFileStreamProperty_FormatList, &formatListSize, formatlist);
                
                if (status == noErr)
                {
                    UInt32 supportedFormatsSize;
                    
                    status = AudioFormatGetPropertyInfo(kAudioFormatProperty_DecodeFormatIDs, 0, NULL, &supportedFormatsSize);
                    
                    if (status != noErr)
                    {
                        // 错误处理
                        free(formatlist);
                        return;
                    }
                    
                    UInt32 supportedFormatCount = supportedFormatsSize / sizeof(OSType);
                    
                    OSType *supportedFormats = (OSType *)malloc(supportedFormatsSize);
                    
                    status = AudioFormatGetProperty(kAudioFormatProperty_DecodeFormatIDs, 0, NULL, &supportedFormatCount, supportedFormats);
                    
                    if (status != noErr)
                    {
                        // 错误处理
                        free(formatlist);
                        free(supportedFormats);
                        return;
                    }
                    
                    // 选择需要的格式
                    for (int i = 0; i * sizeof(AudioFormatListItem) < formatListSize; i += sizeof(AudioFormatListItem))
                    {
                        AudioStreamBasicDescription format = formatlist[i].mASBD;
                        
                        for (UInt32 j = 0; j < supportedFormatCount; ++j)
                        {
                            if (format.mFormatID == supportedFormats[j])
                            {
                                self.format = format;
                                
                                [self calculatePacketDuration];
                                
                                break;
                            }
                        }
                    }
                    free(supportedFormats);
                }
                free(formatlist);
            }
        }
            break;
            
        case kAudioFileStreamProperty_DataOffset:
        {
            UInt32 offsetSize = sizeof(self.dataOffset);
            
            // kAudioFileStreamProperty_DataOffset表示音频数据在整个音频文件中的offset，因为大多数音频文件都会有一个文件头，之后才是真正的音频数据。这个值在seek时会发挥比较大的作用，音频的seek并不是直接seek文件位置而seek时间（比如seek到2分10秒的位置），seek时会根据时间计算出音频数据的字节offset然后需要再加上音频数据的offset才能得到在文件中的真正offset。
            AudioFileStreamGetProperty(self.audioFileStreamID, kAudioFileStreamProperty_DataOffset, &offsetSize, &_dataOffset);
            
            self.audioDataByteCount = self.audioContentLength - self.dataOffset;
            
            [self calculateDuration];
        }
            break;
            
        case kAudioFileStreamProperty_ReadyToProducePackets:
        {
            self.discontinuous = YES;
            
            if (self.delegate && [self.delegate respondsToSelector:@selector(audioDecoder:readyToProducePacketsAndGetMagicCookieData:)])
            {
                UInt32 cookieSize;
                
                Boolean writable;
                
                NSData *cookie;
                
                OSStatus status = AudioFileStreamGetPropertyInfo(self.audioFileStreamID, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable);
                
                if (status == noErr)
                {
                    void *cookieData = malloc(cookieSize);
                    
                    status = AudioFileStreamGetProperty(self.audioFileStreamID, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData);
                    
                    if (status == noErr)
                    {
                        cookie = [NSData dataWithBytes:cookieData length:cookieSize];
                    }else
                    {
                        cookie = nil;
                    }
                    
                    free(cookieData);
                    
                }else
                {
                    cookie = nil;
                }
                
                [self.delegate audioDecoder:self readyToProducePacketsAndGetMagicCookieData:cookie];
            }
        }
            break;
            
        default:
            break;
    }
}



/*
 读取格式信息完成之后，继续调用`AudioFileStreamParseBytes`方法可以对帧进行分离，每解析出一部分帧就会同步调用一次此方法。
 
 inNumberBytes :　本次处理的数据大小
 inNumberPackets　:　本次总共处理了多少帧（即代码里的packet）
 inInputData : 本次处理的所有数据
 AudioStreamPacketDescription : 数组，存储了每一帧数据是从第几个字节开始的，这一帧总共多少字节。
 */
static void SJAudioFileStreamPacketsCallBack(void *inClientData, UInt32 inNumberBytes, UInt32 inNumberPackets, const void *inInputData, AudioStreamPacketDescription *inPacketDescription)
{
    SJAudioDecoder *decoder = (__bridge SJAudioDecoder *)inClientData;
    
    [decoder handleAudioFileStreamPackets:inInputData numberOfBytes:inNumberBytes numberOfPackets:inNumberPackets packetDescriptions:inPacketDescription];
}


- (void)handleAudioFileStreamPackets:(const void *)packets
                       numberOfBytes:(UInt32)numberOfBytes
                     numberOfPackets:(UInt32)numberOfPackets
                  packetDescriptions:(AudioStreamPacketDescription *)packetDescriptions
{
    if (self.discontinuous)
    {
        self.discontinuous = NO;
    }
    
    if (numberOfBytes == 0 || numberOfPackets == 0)
    {
        return;
    }
    
    if (self.delegate && [self.delegate respondsToSelector:@selector(audioDecoder:receiveInputData:numberOfBytes:numberOfPackets:packetDescriptions:)])
    {
        [self.delegate audioDecoder:self receiveInputData:packets numberOfBytes:numberOfBytes numberOfPackets:numberOfPackets packetDescriptions:packetDescriptions];
    }
}



AudioFileTypeID SJAudioFileTypeIdForFileExtension(NSString *fileExtension)
{
    AudioFileTypeID fileTypeHint = 0;
    
    if ([fileExtension isEqualToString:@"mp3"])
    {
        fileTypeHint = kAudioFileMP3Type;
        
    }else if ([fileExtension isEqualToString:@"wav"])
    {
        fileTypeHint = kAudioFileWAVEType;
        
    }else if ([fileExtension isEqualToString:@"aifc"])
    {
        fileTypeHint = kAudioFileAIFCType;
        
    }else if ([fileExtension isEqualToString:@"aiff"])
    {
        fileTypeHint = kAudioFileAIFFType;
        
    }else if ([fileExtension isEqualToString:@"m4a"])
    {
        fileTypeHint = kAudioFileM4AType;
        
    }else if ([fileExtension isEqualToString:@"mp4"])
    {
        fileTypeHint = kAudioFileMPEG4Type;
        
    }else if ([fileExtension isEqualToString:@"caf"])
    {
        fileTypeHint = kAudioFileCAFType;
        
    }else if ([fileExtension isEqualToString:@"aac"])
    {
        fileTypeHint = kAudioFileAAC_ADTSType;
    }
    
    return fileTypeHint;
}


@end
