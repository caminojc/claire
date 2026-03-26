#import "ClaireAudioBridge.h"

// Zipper SDK C++ API
#include "SmplZipperClientApi.h"

// Forward declare the C++ listener bridge
class ClaireZipperListener;

@interface ClaireAudioBridge () {
    SmplZipperClient *_zipperClient;
    ClaireZipperListener *_listener;
    BOOL _isRunning;
}
@end

// C++ listener that forwards callbacks to the Objective-C delegate
class ClaireZipperListener : public ZipperClientListenerI {
public:
    __weak id<ClaireAudioBridgeDelegate> delegate = nil;

    void OnEncodedPayload(const uint8_t *data, int numBytes, int startTimeMs, int timeMs) override {
        NSData *nsData = [NSData dataWithBytes:data length:numBytes];
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [d onEncodedPayload:nsData startTimeMs:startTimeMs timeMs:timeMs];
            });
        }
    }

    void OnSegmentFinished(int timeMs) override {
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [d onSegmentFinished:timeMs];
            });
        }
    }

    void OnSegmentCancelled(int timeMs) override {
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [d onSegmentCancelled:timeMs];
            });
        }
    }

    void OnSegmentStarted(int timeMs) override {
        // No-op for Claire
    }

    void OnUserSpeechChanged(bool active) override {
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [d onUserSpeechChanged:active];
            });
        }
    }

    void OnStreamingStarted(int id) override {
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [d onStreamingStarted:id];
            });
        }
    }

    void OnStreamingStopped(int id, int timeMs) override {
        id<ClaireAudioBridgeDelegate> d = delegate;
        if (d) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [d onStreamingStopped:id timeMs:timeMs];
            });
        }
    }
};

@implementation ClaireAudioBridge

- (instancetype)initWithAFEModelPath:(NSString *)afeModelPath
                        aecModelPath:(NSString *)aecModelPath
                        vadModelPath:(NSString *)vadModelPath
                       afeConfigPath:(NSString *)afeConfigPath {
    self = [super init];
    if (self) {
        _listener = new ClaireZipperListener();
        _zipperClient = new SmplZipperClient();
        _isRunning = NO;

        // Initialize with model paths
        _zipperClient->Initialize(
            [afeModelPath UTF8String],
            _listener,
            ENC_MelCodec  // Default encoder
        );
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
    if (_listener) {
        delete _listener;
        _listener = nullptr;
    }
}

- (void)setDelegate:(id<ClaireAudioBridgeDelegate>)delegate {
    _delegate = delegate;
    if (_listener) {
        _listener->delegate = delegate;
    }
}

- (void)startWithEncoderType:(int)encoderType {
    if (_isRunning) return;
    _zipperClient->Start();
    _isRunning = YES;
}

- (void)stop {
    if (!_isRunning) return;
    _zipperClient->Stop();
    _isRunning = NO;
}

- (void)addStreamingData:(NSData *)data
                streamId:(int)streamId
                  format:(NSString *)format
                   isEnd:(BOOL)isEnd {
    if (!_zipperClient) return;
    _zipperClient->addStreamingData(
        (const uint8_t *)[data bytes],
        (int)[data length],
        streamId,
        [format UTF8String],
        isEnd
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
