#import "ClaireAudioBridge.h"
#include "SmplZipperClientApi.h"
#include <memory>

class ClaireZipperListener : public ZipperClientListenerI {
public:
    __weak id<ClaireAudioBridgeDelegate> delegate = nil;

    void OnEncodedPayload(const uint8_t data[], int numBytes, int32_t startTimeMs, int32_t timeMs) override {
        NSLog(@"[ClaireAudio] OnEncodedPayload: %d bytes, timeMs=%d", numBytes, timeMs);
        NSData *nsData = [NSData dataWithBytes:data length:numBytes];
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) [d onEncodedPayload:nsData startTimeMs:startTimeMs timeMs:timeMs];
    }

    void OnSegmentFinished(int32_t timeMs) override {
        NSLog(@"[ClaireAudio] OnSegmentFinished: timeMs=%d", timeMs);
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) [d onSegmentFinished:timeMs];
    }

    void OnSegmentCancelled(int32_t timeMs) override {
        NSLog(@"[ClaireAudio] OnSegmentCancelled: timeMs=%d", timeMs);
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) [d onSegmentCancelled:timeMs];
    }

    void OnSegmentStarted(int32_t timeMs) override {
        NSLog(@"[ClaireAudio] OnSegmentStarted: timeMs=%d", timeMs);
    }

    void OnUserSpeechChanged(bool active) override {
        NSLog(@"[ClaireAudio] OnUserSpeechChanged: %d", active);
        id<ClaireAudioBridgeDelegate> d = delegate;
        BOOL a = active;
        if (d) [d onUserSpeechChanged:a];
    }

    void OnStreamingStarted(int32_t sid) override {
        NSLog(@"[ClaireAudio] OnStreamingStarted: %d", sid);
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) [d onStreamingStarted:sid];
    }

    void OnStreamingStopped(int32_t sid, int32_t timeMs) override {
        NSLog(@"[ClaireAudio] OnStreamingStopped: %d timeMs=%d", sid, timeMs);
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
        NSLog(@"[ClaireAudio] Initializing Zipper SDK...");
        NSLog(@"[ClaireAudio]   Model dir: %@", modelDir);
        int result = _client->Initialize(path, _listener, ENC_PCM16_16KHZ);
        NSLog(@"[ClaireAudio]   Init result: %d (0=success)", result);
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
    if (_running || !_client) {
        NSLog(@"[ClaireAudio] Start skipped: running=%d client=%p", _running, _client);
        return;
    }
    NSLog(@"[ClaireAudio] Starting audio engine (encoder=%d)...", encoderType);
    int result = _client->Start();
    _running = (result == 0);
    NSLog(@"[ClaireAudio] Start result: %d (0=success), running=%d", result, _running);
}

- (void)stop {
    if (!_running || !_client) return;
    NSLog(@"[ClaireAudio] Stopping...");
    _client->Stop();
    _running = NO;
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
