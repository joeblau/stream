#pragma once
#include <CoreAudio/AudioServerPlugIn.h>

#define STREAM_LOOPBACK_CAPACITY 16384
#define STREAM_LOOPBACK_LATENCY 512
#define STREAM_LOOPBACK_MAX_CALLBACK 4096
void StreamLoopbackReset(void);
OSStatus StreamLoopbackWrite(Float64 sampleTime, UInt32 frames, const Float32 *samples, Float32 gain);
OSStatus StreamLoopbackRead(Float64 sampleTime, UInt32 frames, Float32 *samples, Float32 gain);
