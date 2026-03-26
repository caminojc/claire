#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * SMPLAFEProcessor
 *
 * SMPL Acoustic Front End (AFE) — echo cancellation, noise suppression,
 * and related audio processing for voice applications.
 *
 * Lifecycle
 * ---------
 *  1. Allocate with -initWithModelPath:configPath:recordingOutputPath:startupFilePath:compressorMode:useAgc:
 *  2. Optionally set postProcessingCallback
 *  3. For each render buffer:  -processRenderChannels:frameCount:numChannels:
 *  4. For each capture buffer: -processCaptureChannels:frameCount:numChannels:
 *
 * Both process methods modify the float buffers in-place.
 *
 * Thread safety
 * -------------
 * Render and capture may be called from different threads concurrently.
 * Internally, a lock-free FIFO transfers render reference frames to the
 * capture thread, so no external synchronisation is needed.
 */
@interface SMPLAFEProcessor : NSObject

/**
 * Initialise the AFE.
 *
 * @param modelPath           Full path to the AFE model file (e.g. .smpl or .zip).
 * @param configPath          Full path to the AFE JSON config file.
 * @param recordingOutputPath File-path prefix for API recording output, or nil to disable.
 *                            The AFE appends suffixes like _capture.raw, _reference.raw, etc.
 * @param startupFilePath     Full path to a wav/mp3 startup chime file, or nil to disable.
 * @param compressorMode      Compressor mode (0 = bypass).
 * @param useAgc              Enable automatic gain control (default NO).
 */
- (instancetype)initWithModelPath:(NSString *)modelPath
                       configPath:(NSString *)configPath
              recordingOutputPath:(nullable NSString *)recordingOutputPath
                  startupFilePath:(nullable NSString *)startupFilePath
                   compressorMode:(int)compressorMode
                           useAgc:(BOOL)useAgc NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/**
 * Process a render (speaker / far-end) buffer in-place.
 *
 * Feeds the render signal as echo reference to the AFE, applies ducking,
 * and mixes in the startup chime if configured.
 *
 * Any sample rate is accepted (auto-detected from frameCount).
 * If numChannels > 1, only channel 0 is processed; the result is copied to all channels.
 *
 * @param channels      Array of @p numChannels float pointers; each pointer
 *                      holds @p frameCount samples in FloatS16 range [-32768, 32767].
 * @param frameCount    Number of samples per channel (10 ms block).
 * @param numChannels   Number of channels (typically 1).
 */
- (void)processRenderChannels:(float * _Nonnull * _Nonnull)channels
                   frameCount:(int)frameCount
                  numChannels:(int)numChannels;

/**
 * Process a capture (microphone / near-end) buffer in-place.
 *
 * Runs echo cancellation, noise suppression, and other AFE processing.
 * After processing, if @p postProcessingCallback is set it is called with
 * the processed samples (mono, channel 0 only).
 *
 * Any sample rate is accepted (auto-detected from frameCount).
 * If numChannels > 1, only channel 0 is processed; the result is copied to all channels.
 *
 * @param channels      Array of @p numChannels float pointers; each pointer
 *                      holds @p frameCount samples in FloatS16 range [-32768, 32767].
 *                      Channel 0 is modified in-place with the processed output.
 * @param frameCount    Number of samples per channel (10 ms block).
 * @param numChannels   Number of channels (typically 1).
 */
- (void)processCaptureChannels:(float * _Nonnull * _Nonnull)channels
                    frameCount:(int)frameCount
                   numChannels:(int)numChannels;

// ── Optional properties ─────────────────────────────────────────────────────

/**
 * Optional callback fired after each capture frame is processed.
 *
 * Called on the capture thread.  The float buffer is valid only for the
 * duration of the call.
 *
 *  @param samples      Processed capture samples (mono, [-1, 1] range).
 *  @param frameCount   Number of samples.
 *  @param sampleRate   Sample rate in Hz.
 *  @param sequenceNum  Monotonically increasing frame counter.
 */
@property (nonatomic, copy, nullable)
    void (^postProcessingCallback)(const float *samples,
                                   NSInteger     frameCount,
                                   NSInteger     sampleRate,
                                   uint32_t      sequenceNum);

/** Smoothed energy level (dB) of capture signal before AFE processing. */
- (float)preAfeLevel;
/** Smoothed energy level (dB) of capture signal after AFE processing. */
- (float)postAfeLevel;
/** Smoothed energy level (dB) of playout/render signal. */
- (float)playoutLevel;

@end

NS_ASSUME_NONNULL_END
