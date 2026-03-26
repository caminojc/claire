#import "ClaireAudioBridge.h"
#import <Foundation/Foundation.h>

// Zipper SDK C++ API
#include "SmplZipperClientApi.h"

// C++ listener that forwards callbacks to Objective-C delegate
class ClaireZipperListener : public ZipperClientListenerI {
public:
    __weak id<ClaireAudioBridgeDelegate> delegate = nil;

    void OnEncodedPayload(const uint8_t data[], int numBytes, int32_t startTimeMs, int32_t timeMs) override {
        NSData *nsData = [NSData dataWithBytes:data length:numBytes];
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [d onEncodedPayload:nsData startTimeMs:startTimeMs timeMs:timeMs];
            });
        }
    }

    void OnSegmentFinished(int32_t timeMs) override {
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [d onSegmentFinished:timeMs];
            });
        }
    }

    void OnSegmentCancelled(int32_t timeMs) override {
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [d onSegmentCancelled:timeMs];
            });
        }
    }

    void OnSegmentStarted(int32_t timeMs) override {
        // No-op for Claire
    }

    void OnUserSpeechChanged(bool active) override {
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) {
            BOOL isActive = active;
            dispatch_async(dispatch_get_main_queue(), ^{
                [d onUserSpeechChanged:isActive];
            });
        }
    }

    void OnStreamingStarted(int32_t streamId) override {
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [d onStreamingStarted:streamId];
            });
        }
    }

    void OnStreamingStopped(int32_t streamId, int32_t timeMs) override {
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [d onStreamingStopped:streamId timeMs:timeMs];
            });
        }
    }
};

@interface ClaireAudioBridge () {
    SmplZipperClient *_zipperClient;
    std::shared_ptr<ClaireZipperListener> _listener;
    BOOL _isRunning;
}
@end

@implementation ClaireAudioBridge

- (instancetype)initWithAFEModelPath:(NSString *)afeModelPath
                        aecModelPath:(NSString *)aecModelPath
                        vadModelPath:(NSString *)vadModelPath
                       afeConfigPath:(NSString *)afeConfigPath {
    self = [super init];
    if (self) {
        _listener = std::make_shared<ClaireZipperListener>();
        _zipperClient = new SmplZipperClient();
        _isRunning = NO;

        // Initialize with model path and mel codec encoder
        std::string modelPath = [afeModelPath UTF8String];
        int result = _zipperClient->Initialize(modelPath, _listener, ENC_MelCodec);
        NSLog(@"[ClaireAudio] Zipper SDK initialized: %d", result);
    }
    return self;
}

- (void)dealloc {
    [self stop];
    if (_zipperClient) {
        _zipperClient->DeInitialize();
        delete _zipperClient;
        _zipperClient = nullptr;
    }
    _listener = nullptr;
}

- (void)setDelegate:(id<ClaireAudioBridgeDelegate>)delegate {
    _delegate = delegate;
    if (_listener) {
        _listener->delegate = delegate;
    }
}

- (void)startWithEncoderType:(int)encoderType {
    if (_isRunning) return;
    int result = _zipperClient->Start();
    _isRunning = (result == 0);
    NSLog(@"[ClaireAudio] Zipper SDK started: %d", result);
}

- (void)stop {
    if (!_isRunning) return;
    _zipperClient->Stop();
    _isRunning = NO;
    NSLog(@"[ClaireAudio] Zipper SDK stopped");
}

- (void)addStreamingData:(NSData *)data
                streamId:(int)streamId
                  format:(NSString *)format
                   isEnd:(BOOL)isEnd {
    if (!_zipperClient || !_isRunning) return;

    // Map format string to Decoder enum
    enum Decoder dec = DEC_PCM16_24KHZ;
    if ([format isEqualToString:@"pcm_24000"] || [format isEqualToString:@"pcm"]) {
        dec = DEC_PCM16_24KHZ;
    } else if ([format isEqualToString:@"pcm_16000"]) {
        dec = DEC_PCM16_16KHZ;
    } else if ([format containsString:@"opus"]) {
        dec = DEC_OPUS;
    } else if ([format containsString:@"mp3"]) {
        dec = DEC_MP3;
    }

    _zipperClient->addStreamingData(
        (const uint8_t *)[data bytes],
        (int)[data length],
        (int32_t)streamId,
        dec,
        (bool)isEnd
    );
}

- (void)stopStreaming {
    if (_zipperClient) {
        _zipperClient->StopStreaming();
    }
}

- (void)muteMic:(BOOL)muted {
    if (_zipperClient) {
        _zipperClient->MuteMic(muted);
    }
}

- (void)pausePlayout:(BOOL)paused {
    if (_zipperClient) {
        _zipperClient->SetPausePlayout(paused);
    }
}

- (float)userSpeechLevel {
    return _zipperClient ? _zipperClient->getUserSpeechLevel() : 0.0f;
}

- (float)streamingLevel {
    return _zipperClient ? _zipperClient->getStreamingLevel() : 0.0f;
}

@end
