#ifndef ClaireAudioBridge_h
#define ClaireAudioBridge_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ClaireAudioBridgeDelegate <NSObject>
- (void)onEncodedPayload:(NSData *)data startTimeMs:(int)startTimeMs timeMs:(int)timeMs;
- (void)onSegmentFinished:(int)timeMs;
- (void)onSegmentCancelled:(int)timeMs;
- (void)onUserSpeechChanged:(BOOL)active;
- (void)onStreamingStarted:(int)streamId;
- (void)onStreamingStopped:(int)streamId timeMs:(int)timeMs;
@end

@interface ClaireAudioBridge : NSObject

@property (nonatomic, weak, nullable) id<ClaireAudioBridgeDelegate> delegate;
@property (nonatomic, readonly) float userSpeechLevel;
@property (nonatomic, readonly) float streamingLevel;

/// Initialize with path to directory containing AFE model files
- (instancetype)initWithModelDirectory:(NSString *)modelDir;

/// Start audio engine + VAD. encoderType: 0=Mel, 1=PCM24k, 2=PCM16k, 3=Opus
- (void)startWithEncoderType:(int)encoderType;
- (void)stop;

/// Feed TTS audio for playout. format: DEC_MP3=0, DEC_OPUS=1, DEC_PCM16_24KHZ=2, DEC_PCM16_16KHZ=3
- (void)addStreamingData:(NSData *)data streamId:(int)streamId decoderFormat:(int)format isEnd:(BOOL)isEnd;
- (void)stopStreaming;
- (void)muteMic:(BOOL)muted;

@end

NS_ASSUME_NONNULL_END

#endif
