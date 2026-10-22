#include "StudioProgramRender.h"
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "The callback requires lock-free 64-bit atomics");
typedef struct { _Atomic uint64_t stamp, stereo; } ProgramFrame;
struct StreamProgramRender {
    ProgramFrame frames[STREAM_PROGRAM_CAPACITY];
    _Atomic bool active, clockFault, writing, rendering;
    _Atomic uint64_t submitted, rendered, silence, rejected, invalid;
    mach_timebase_info_data_t clock;
    /* Exactly one submit/render invocation at a time, enforced by atomic flags. */
    int64_t writtenEnd, outputEnd, anchorHostFrame;
    bool hasWritten, anchored;
};

int64_t StreamProgramHostFrameAtTicks(uint64_t ticks) {
    mach_timebase_info_data_t clock;
    mach_timebase_info(&clock);
    long double frames = (long double)ticks * clock.numer * STREAM_PROGRAM_RATE / ((long double)clock.denom * 1e9L);
    return frames >= INT64_MAX ? -1 : (int64_t)llroundl(frames);
}
static int64_t hostFrame(StreamProgramRender *core, uint64_t ticks) {
    long double frames = (long double)ticks * core->clock.numer * STREAM_PROGRAM_RATE / ((long double)core->clock.denom * 1e9L);
    return frames >= INT64_MAX ? -1 : (int64_t)llroundl(frames);
}
StreamProgramRender *StreamProgramRenderCreate(void) {
    StreamProgramRender *core = calloc(1, sizeof(*core));
    if (core == NULL) return NULL;
    for (uint32_t n = 0; n < STREAM_PROGRAM_CAPACITY; n++) {
        atomic_init(&core->frames[n].stamp, 0); atomic_init(&core->frames[n].stereo, 0);
    }
    atomic_init(&core->active, false); atomic_init(&core->clockFault, false);
    atomic_init(&core->writing, false); atomic_init(&core->rendering, false);
    atomic_init(&core->submitted, 0); atomic_init(&core->rendered, 0); atomic_init(&core->silence, 0);
    atomic_init(&core->rejected, 0); atomic_init(&core->invalid, 0);
    mach_timebase_info(&core->clock);
    atomic_store(&core->active, true);
    return core;
}
void StreamProgramRenderRetire(StreamProgramRender *core) { if (core != NULL) atomic_store(&core->active, false); }
void StreamProgramRenderDestroy(StreamProgramRender *core) { free(core); }
static bool reject(StreamProgramRender *core) { atomic_fetch_add(&core->rejected, 1); return false; }
bool StreamProgramRenderSubmit(StreamProgramRender *core, int64_t start, uint32_t frames, const float *stereo) {
    if (core == NULL) return false;
    if (!atomic_load(&core->active) || start < 0 || start > INT64_MAX - STREAM_PROGRAM_CAPACITY ||
        frames == 0 || frames > STREAM_PROGRAM_MAX_CALLBACK || stereo == NULL) return reject(core);
    bool expected = false;
    if (!atomic_compare_exchange_strong(&core->writing, &expected, true)) return reject(core);
    int64_t now = hostFrame(core, mach_absolute_time());
    if (!atomic_load(&core->active) || (core->hasWritten && start < core->writtenEnd) ||
        start < now - STREAM_PROGRAM_CAPACITY || start + frames > now + STREAM_PROGRAM_MAX_CALLBACK) {
        atomic_store(&core->writing, false); return reject(core);
    }
    core->hasWritten = true; core->writtenEnd = start + frames;
    for (uint32_t n = 0; n < frames; n++) {
        ProgramFrame *slot = &core->frames[(uint64_t)(start + n) % STREAM_PROGRAM_CAPACITY];
        atomic_store(&slot->stamp, 0);
        float pair[2] = {stereo[n * 2], stereo[n * 2 + 1]};
        for (int c = 0; c < 2; c++) pair[c] = isfinite(pair[c]) ? fmaxf(-1, fminf(1, pair[c])) : 0;
        uint64_t packed; memcpy(&packed, pair, sizeof(packed));
        atomic_store(&slot->stereo, packed);
        atomic_store(&slot->stamp, (uint64_t)(start + n) + 1);
    }
    atomic_fetch_add(&core->submitted, frames);
    atomic_store(&core->writing, false);
    return atomic_load(&core->active);
}

OSStatus StreamProgramHALIOProc(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)input; (void)inputTime;
    StreamProgramRender *core = context;
    /* Always clear a valid bounded buffer before inspecting state or clocks. */
    if (output == NULL || output->mNumberBuffers != 1 || output->mBuffers[0].mData == NULL ||
        output->mBuffers[0].mNumberChannels != 2 || output->mBuffers[0].mDataByteSize % 8 != 0 ||
        output->mBuffers[0].mDataByteSize > STREAM_PROGRAM_MAX_CALLBACK * 8) {
        if (core != NULL) atomic_fetch_add(&core->invalid, 1);
        return kAudioHardwareIllegalOperationError;
    }
    uint32_t count = output->mBuffers[0].mDataByteSize / 8;
    float *samples = output->mBuffers[0].mData;
    memset(samples, 0, count * 8);
    if (core == NULL || !atomic_load(&core->active) || atomic_load(&core->clockFault)) return noErr;
    if (outputTime == NULL || (outputTime->mFlags & (kAudioTimeStampHostTimeValid | kAudioTimeStampSampleTimeValid)) !=
        (kAudioTimeStampHostTimeValid | kAudioTimeStampSampleTimeValid) || !isfinite(outputTime->mSampleTime) ||
        outputTime->mSampleTime < 0 || outputTime->mSampleTime > (double)(INT64_MAX / 2) ||
        floor(outputTime->mSampleTime) != outputTime->mSampleTime) {
        atomic_fetch_add(&core->invalid, 1); return kAudioHardwareIllegalOperationError;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong(&core->rendering, &expected, true)) {
        atomic_fetch_add(&core->invalid, 1); return kAudioHardwareIllegalOperationError;
    }
    int64_t deviceFrame = (int64_t)outputTime->mSampleTime;
    int64_t observed = hostFrame(core, outputTime->mHostTime);
    if (!core->anchored) {
        core->anchorHostFrame = observed - deviceFrame; core->anchored = true;
        core->outputEnd = deviceFrame;
    }
    int64_t mapped = core->anchorHostFrame + deviceFrame;
    /* A clock/sample discontinuity requires an explicit fresh session. Never
       rebase to callback arrival or play previously queued PCM at a new epoch. */
    if (observed < 0 || llabs(observed - mapped) > 2 || deviceFrame < core->outputEnd) {
        atomic_store(&core->clockFault, true); atomic_fetch_add(&core->invalid, 1);
        atomic_store(&core->rendering, false); return kAudioHardwareIllegalOperationError;
    }
    core->outputEnd = deviceFrame + count;
    int64_t start = mapped - STREAM_PROGRAM_DELAY_FRAMES;
    uint64_t silence = 0;
    for (uint32_t n = 0; n < count; n++) {
        int64_t wanted = start + n;
        bool found = false;
        if (wanted >= 0) {
            ProgramFrame *slot = &core->frames[(uint64_t)wanted % STREAM_PROGRAM_CAPACITY];
            uint64_t stamp = atomic_load(&slot->stamp);
            if (stamp == (uint64_t)wanted + 1) {
                uint64_t pair = atomic_load(&slot->stereo);
                if (atomic_load(&slot->stamp) == stamp) { memcpy(samples + n * 2, &pair, 8); found = true; }
            }
        }
        if (!found) silence++;
    }
    if (!atomic_load(&core->active)) { memset(samples, 0, count * 8); silence = count; }
    atomic_fetch_add(&core->rendered, count); atomic_fetch_add(&core->silence, silence);
    atomic_store(&core->rendering, false);
    return noErr;
}
StreamProgramRenderStatistics StreamProgramRenderSnapshot(StreamProgramRender *core) {
    StreamProgramRenderStatistics value = {0};
    if (core != NULL) {
        value.submittedFrames = atomic_load(&core->submitted); value.renderedFrames = atomic_load(&core->rendered);
        value.silenceFrames = atomic_load(&core->silence); value.rejectedChunks = atomic_load(&core->rejected);
        value.invalidCallbacks = atomic_load(&core->invalid); value.active = atomic_load(&core->active);
        value.clockFault = atomic_load(&core->clockFault);
    }
    return value;
}
OSStatus StreamProgramHALCreateIOProc(AudioDeviceID device, StreamProgramRender *core, AudioDeviceIOProcID *result) {
    return AudioDeviceCreateIOProcID(device, StreamProgramHALIOProc, core, result);
}

static AudioObjectPropertyAddress property(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress value = {selector, scope, kAudioObjectPropertyElementMain}; return value;
}
static bool streamFormat(AudioDeviceID device, AudioObjectPropertyScope scope, const StreamProgramHALReads *reads) {
    AudioObjectPropertyAddress address = property(kAudioDevicePropertyStreams, scope);
    UInt32 bytes = 0; AudioStreamID stream;
    if (reads->size(device, &address, 0, NULL, &bytes) != noErr || bytes != sizeof(stream) ||
        reads->get(device, &address, 0, NULL, &bytes, &stream) != noErr) return false;
    address = property(kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal);
    AudioStreamBasicDescription format; bytes = sizeof(format);
    return reads->get(stream, &address, 0, NULL, &bytes, &format) == noErr &&
        format.mSampleRate == STREAM_PROGRAM_RATE && format.mFormatID == kAudioFormatLinearPCM &&
        format.mFormatFlags == kAudioFormatFlagsNativeFloatPacked && format.mChannelsPerFrame == 2 &&
        format.mBitsPerChannel == 32 && format.mBytesPerFrame == 8 && format.mBytesPerPacket == 8 && format.mFramesPerPacket == 1;
}
bool StreamProgramHALPreflightWithReads(AudioDeviceID device, const StreamProgramHALReads *reads) {
    if (reads == NULL || reads->get == NULL || reads->size == NULL) return false;
    AudioObjectPropertyAddress address = property(kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal);
    CFStringRef uid = NULL; UInt32 bytes = sizeof(uid);
    if (reads->get(device, &address, 0, NULL, &bytes, &uid) != noErr || uid == NULL) return false;
    bool correct = CFEqual(uid, CFSTR("com.joeblau.Stream.VirtualMicrophonePrototype.device")); CFRelease(uid);
    if (!correct) return false;
    UInt32 alive = 0; bytes = sizeof(alive); address.mSelector = kAudioDevicePropertyDeviceIsAlive;
    if (reads->get(device, &address, 0, NULL, &bytes, &alive) != noErr || alive != 1) return false;
    UInt32 frames = 0; bytes = sizeof(frames); address.mSelector = kAudioDevicePropertyBufferFrameSize;
    return reads->get(device, &address, 0, NULL, &bytes, &frames) == noErr &&
        frames > 0 && frames <= STREAM_PROGRAM_MAX_CALLBACK &&
        streamFormat(device, kAudioObjectPropertyScopeInput, reads) && streamFormat(device, kAudioObjectPropertyScopeOutput, reads);
}
AudioDeviceID StreamProgramHALFindDeviceWithReads(const StreamProgramHALReads *reads) {
    if (reads == NULL || reads->get == NULL || reads->size == NULL) return kAudioObjectUnknown;
    AudioValueTranslation translation;
    CFStringRef uid = CFSTR("com.joeblau.Stream.VirtualMicrophonePrototype.device");
    AudioDeviceID device = kAudioObjectUnknown;
    translation.mInputData = &uid; translation.mInputDataSize = sizeof(uid);
    translation.mOutputData = &device; translation.mOutputDataSize = sizeof(device);
    UInt32 size = sizeof(translation);
    AudioObjectPropertyAddress address = property(kAudioHardwarePropertyDeviceForUID, kAudioObjectPropertyScopeGlobal);
    return reads->get(kAudioObjectSystemObject, &address, 0, NULL, &size, &translation) == noErr &&
        StreamProgramHALPreflightWithReads(device, reads) ? device : kAudioObjectUnknown;
}
bool StreamProgramHALPreflight(AudioDeviceID device) {
    const StreamProgramHALReads reads = {AudioObjectGetPropertyData, AudioObjectGetPropertyDataSize};
    return StreamProgramHALPreflightWithReads(device, &reads);
}
AudioDeviceID StreamProgramHALFindDevice(void) {
    const StreamProgramHALReads reads = {AudioObjectGetPropertyData, AudioObjectGetPropertyDataSize};
    return StreamProgramHALFindDeviceWithReads(&reads);
}
