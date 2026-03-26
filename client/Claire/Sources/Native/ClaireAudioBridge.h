#ifndef ClaireAudioBridge_h
#define ClaireAudioBridge_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Callback protocol for audio events from the Zipper SDK
@protocol ClaireAudioBridgeDelegate <NSObject>

/// Encoded audio payload ready to send to server (mel or PCM)
- (void)onEncodedPayload:(NSData *)data startTimeMs:(int)startTimeMs timeMs:(int)timeMs;

/// Speech segment finished — payload is complete, send it
- (void)onSegmentFinished:(int)timeMs;

/// Speech segment cancelled (user kept speaking)
- (void)onSegmentCancelled:(int)timeMs;

/// User speech state changed (VAD)
- (void)onUserSpeechChanged:(BOOL)active;

/// TTS streaming started for given ID
- (void)onStreamingStarted:(int)streamId;

/// TTS streaming stopped for given ID
- (void)onStreamingStopped:(int)streamId timeMs:(int)timeMs;

@end

/// Objective-C++ bridge to SMPL Zipper SDK + CoreAudio Engine.
/// Wraps the full Atria audio pipeline for use from Swift.
@interface ClaireAudioBridge : NSObject

@property (nonatomic, weak, nullable) id<ClaireAudioBridgeDelegate> delegate;

/// Audio levels (0.0 - 1.0)
@property (nonatomic, readonly) float userSpeechLevel;
@property (nonatomic, readonly) float streamingLevel;

/// Initialize the audio bridge with AFE model paths
- (instancetype)initWithAFEModelPath:(NSString *)afeModelPath
                        aecModelPath:(NSString *)aecModelPath
                        vadModelPath:(NSString *)vadModelPath
                      afeConfigPath:(NSString *)afeConfigPath;

/// Start the audio engine and STT processing
/// @param encoderType 0=MelCodec, 1=PCM16_24kHz, 2=PCM16_16kHz, 3=Opus
- (void)startWithEncoderType:(int)encoderType;

/// Stop the audio engine
- (void)stop;

/// Add TTS audio data for playout
/// @param data Audio bytes
/// @param streamId Stream identifier
/// @param format Audio format string (e.g. "pcm_24000", "opus_ogg", "mp3")
/// @param isEnd Whether this is the last chunk
- (void)addStreamingData:(NSData *)data
                streamId:(int)streamId
                  format:(NSString *)format
                   isEnd:(BOOL)isEnd;

/// Stop all TTS playout (for barge-in)
- (void)stopStreaming;

/// Mute/unmute microphone
- (void)muteMic:(BOOL)muted;

/// Pause/resume TTS playout
- (void)pausePlayout:(BOOL)paused;

@end

NS_ASSUME_NONNULL_END

#endif /* ClaireAudioBridge_h */
