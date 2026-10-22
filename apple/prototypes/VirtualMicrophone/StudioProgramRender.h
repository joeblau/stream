#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#define STREAM_PROGRAM_RATE 48000
#define STREAM_PROGRAM_CHANNELS 2
#define STREAM_PROGRAM_CAPACITY 32768
#define STREAM_PROGRAM_MAX_CALLBACK 4096
#define STREAM_PROGRAM_DELAY_FRAMES 12288 /* explicit evaluation latency: 256 ms */

typedef struct StreamProgramRender StreamProgramRender;
typedef struct {
    uint64_t submittedFrames, renderedFrames, silenceFrames, rejectedChunks, invalidCallbacks;
    bool active, clockFault;
} StreamProgramRenderStatistics;

/* One allocation per evaluation session. Never rearm a retired instance. */
StreamProgramRender *StreamProgramRenderCreate(void);
void StreamProgramRenderDestroy(StreamProgramRender *core);
void StreamProgramRenderRetire(StreamProgramRender *core);
bool StreamProgramRenderSubmit(StreamProgramRender *core, int64_t originalHostFrame,
                               uint32_t frames, const float *stereo);
StreamProgramRenderStatistics StreamProgramRenderSnapshot(StreamProgramRender *core);
int64_t StreamProgramHostFrameAtTicks(uint64_t ticks);
OSStatus StreamProgramHALIOProc(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context);
OSStatus StreamProgramHALCreateIOProc(AudioDeviceID device, StreamProgramRender *core, AudioDeviceIOProcID *result);

/* Read-only identity/format checks. No device/rate/default property setters. */
typedef struct {
    OSStatus (*get)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *, void *);
    OSStatus (*size)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
} StreamProgramHALReads;
bool StreamProgramHALPreflightWithReads(AudioDeviceID device, const StreamProgramHALReads *reads);
AudioDeviceID StreamProgramHALFindDeviceWithReads(const StreamProgramHALReads *reads);
bool StreamProgramHALPreflight(AudioDeviceID device);
AudioDeviceID StreamProgramHALFindDevice(void);
