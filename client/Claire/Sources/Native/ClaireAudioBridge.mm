#import "ClaireAudioBridge.h"
#include "SmplZipperClientApi.h"
#include <memory>

class ClaireZipperListener : public ZipperClientListenerI {
public:
    __weak id<ClaireAudioBridgeDelegate> delegate = nil;

    void OnEncodedPayload(const uint8_t data[], int numBytes, int32_t startTimeMs, int32_t timeMs) override {
        NSData *nsData = [NSData dataWithBytes:data length:numBytes];
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) [d onEncodedPayload:nsData startTimeMs:startTimeMs timeMs:timeMs];
    }

    void OnSegmentFinished(int32_t timeMs) override {
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) [d onSegmentFinished:timeMs];
    }

    void OnSegmentCancelled(int32_t timeMs) override {
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) [d onSegmentCancelled:timeMs];
    }

    void OnSegmentStarted(int32_t timeMs) override {}

    void OnUserSpeechChanged(bool active) override {
        id<ClaireAudioBridgeDelegate> d = delegate;
        BOOL a = active;
        if (d) [d onUserSpeechChanged:a];
    }

    void OnStreamingStarted(int32_t sid) override {
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) [d onStreamingStarted:sid];
    }

    void OnStreamingStopped(int32_t sid, int32_t timeMs) override {
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) [d onStreamingStopped:sid timeMs:timeMs];
    }
};

@implementation ClaireAudioBridge {
    SmplZipperClient *_client;
    std::shared_ptr<ClaireZipperListener> _listener;
    BOOL _running;
}

- (instancetype)initWithModelDirectory:(NSString *)modelDir {
    self = [super init];
    if (self) {
        _listener = std::make_shared<ClaireZipperListener>();
        _client = new SmplZipperClient();
        _running = NO;

        std::string path = [modelDir UTF8String];
        int result = _client->Initialize(path, _listener, ENC_MelCodec);
        NSLog(@"[ClaireAudio] Zipper SDK init: %d (model dir: %@)", result, modelDir);
    }
    return self;
}

- (void)dealloc {
    [self stop];
    if (_client) { _client->DeInitialize(); delete _client; _client = nullptr; }
    _listener = nullptr;
}

- (void)setDelegate:(id<ClaireAudioBridgeDelegate>)delegate {
    _delegate = delegate;
    if (_listener) _listener->delegate = delegate;
}

- (void)startWithEncoderType:(int)encoderType {
    if (_running || !_client) return;
    int result = _client->Start();
    _running = (result == 0);
    NSLog(@"[ClaireAudio] Start: %d", result);
}

- (void)stop {
    if (!_running || !_client) return;
    _client->Stop();
    _running = NO;
    NSLog(@"[ClaireAudio] Stopped");
}

- (void)addStreamingData:(NSData *)data streamId:(int)streamId decoderFormat:(int)format isEnd:(BOOL)isEnd {
    if (!_client || !_running) return;
    _client->addStreamingData((const uint8_t *)[data bytes], (int)[data length],
                               (int32_t)streamId, (enum Decoder)format, (bool)isEnd);
}

- (void)stopStreaming {
    if (_client) _client->StopStreaming();
}

- (void)muteMic:(BOOL)muted {
    if (_client) _client->MuteMic(muted);
}

- (float)userSpeechLevel {
    return _client ? _client->getUserSpeechLevel() : 0;
}

- (float)streamingLevel {
    return _client ? _client->getStreamingLevel() : 0;
}

@end
