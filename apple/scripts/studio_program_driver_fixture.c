#include "studio_program_driver_fixture.h"
#include <CoreAudio/AudioServerPlugIn.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static AudioServerPlugInDriverRef driver;
static bool foreignUID;
static OSStatus changed(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a) { return noErr; }
static OSStatus copy(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef *v) { *v = NULL; return noErr; }
static OSStatus writeStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef v) { return noErr; }
static OSStatus deleteStorage(AudioServerPlugInHostRef h, CFStringRef k) { return noErr; }
static OSStatus configuration(AudioServerPlugInHostRef h, AudioObjectID d, UInt64 a, void *v) { return noErr; }
static AudioServerPlugInHostInterface host = {changed, copy, writeStorage, deleteStorage, configuration};

bool StudioProgramFixtureLoad(const char *binary) {
    void *library = dlopen(binary, RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) return false;
    void *(*factory)(CFAllocatorRef, CFUUIDRef) = dlsym(library, "StreamVirtualMicrophone_Create");
    if (factory == NULL) return false;
    driver = factory(kCFAllocatorDefault, kAudioServerPlugInTypeUUID);
    return driver != NULL && (*driver)->Initialize(driver, &host) == noErr;
}
/* Only HAL's system-owned UID lookup and IO buffer size are modeled. All
   device UID/alive/stream/ASBD reads below call the actual loaded driver. */
static OSStatus get(AudioObjectID object, const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize, const void *qualifier, UInt32 *size, void *data) {
    if (object == kAudioObjectSystemObject && address->mSelector == kAudioHardwarePropertyDeviceForUID) {
        if (*size != sizeof(AudioValueTranslation)) return kAudioHardwareBadPropertySizeError;
        AudioValueTranslation *translation = data;
        if (translation->mOutputDataSize != sizeof(AudioDeviceID)) return kAudioHardwareBadPropertySizeError;
        *(AudioDeviceID *)translation->mOutputData = 3; return noErr;
    }
    if (object == 3 && address->mSelector == kAudioDevicePropertyBufferFrameSize) {
        if (*size != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        *(UInt32 *)data = 512; return noErr;
    }
    if (object == 3 && address->mSelector == kAudioDevicePropertyDeviceUID && foreignUID) {
        if (*size != sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
        *(CFStringRef *)data = CFSTR("foreign.audio.device"); return noErr;
    }
    UInt32 used = 0;
    OSStatus status = (*driver)->GetPropertyData(driver, object, getpid(), address, qualifierSize, qualifier, *size, &used, data);
    *size = used; return status;
}
static OSStatus size(AudioObjectID object, const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize, const void *qualifier, UInt32 *bytes) {
    return (*driver)->GetPropertyDataSize(driver, object, getpid(), address, qualifierSize, qualifier, bytes);
}
AudioDeviceID StudioProgramFixtureFind(void) {
    const StreamProgramHALReads reads = {get, size}; return StreamProgramHALFindDeviceWithReads(&reads);
}
bool StudioProgramFixturePreflight(AudioDeviceID device) {
    const StreamProgramHALReads reads = {get, size}; return StreamProgramHALPreflightWithReads(device, &reads);
}
void StudioProgramFixtureForeignUID(bool value) { foreignUID = value; }
OSStatus StudioProgramFixtureRate(uint64_t rate) { return (*driver)->PerformDeviceConfigurationChange(driver, 3, rate, NULL); }
OSStatus StudioProgramFixtureStart(uint32_t client) { return (*driver)->StartIO(driver, 3, client); }
OSStatus StudioProgramFixtureStop(uint32_t client) { return (*driver)->StopIO(driver, 3, client); }
bool StudioProgramFixtureTime(double *sample, uint64_t *ticks) {
    UInt64 seed;
    return (*driver)->GetZeroTimeStamp(driver, 3, 1, sample, ticks, &seed) == noErr;
}
OSStatus StudioProgramFixtureRead(double sample, uint32_t frames, float *received) {
    AudioServerPlugInIOCycleInfo cycle = {0}; cycle.mInputTime.mSampleTime = sample;
    return (*driver)->DoIOOperation(driver, 3, 4, 99, kAudioServerPlugInIOOperationReadInput, frames, &cycle, received, NULL);
}
OSStatus StudioProgramFixtureTransfer(StreamProgramRender *core, const AudioTimeStamp *time,
    uint32_t frames, float *rendered, float *received) {
    AudioBufferList output = {.mNumberBuffers = 1, .mBuffers = {{2, frames * 8, rendered}}};
    OSStatus status = StreamProgramHALIOProc(3, time, NULL, NULL, &output, time, core);
    if (status != noErr) return status;
    AudioServerPlugInIOCycleInfo cycle = {0}; cycle.mOutputTime = *time;
    status = (*driver)->DoIOOperation(driver, 3, 8, 1, kAudioServerPlugInIOOperationWriteMix, frames, &cycle, rendered, NULL);
    if (status != noErr) return status;
    return StudioProgramFixtureRead(time->mSampleTime + 512, frames, received);
}

typedef struct {
    StreamProgramRender *core; int64_t original;
    _Atomic bool go; bool wrote; OSStatus rendered;
    float output[3072 * 2], replacement[3072 * 2];
} ConcurrentRender;
static void *replaceProgram(void *argument) {
    ConcurrentRender *test = argument;
    while (!atomic_load(&test->go)) {}
    test->wrote = StreamProgramRenderSubmit(test->core, test->original + STREAM_PROGRAM_CAPACITY, 3072, test->replacement);
    return NULL;
}
static void *readProgram(void *argument) {
    ConcurrentRender *test = argument;
    AudioTimeStamp time = {0};
    mach_timebase_info_data_t clock; mach_timebase_info(&clock);
    long double ticks = (long double)(test->original + STREAM_PROGRAM_DELAY_FRAMES) * 1e9L * clock.denom / ((long double)48000 * clock.numer);
    time.mHostTime = (uint64_t)llroundl(ticks);
    time.mSampleTime = 0; time.mFlags = kAudioTimeStampHostTimeValid | kAudioTimeStampSampleTimeValid;
    AudioBufferList list = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof(test->output), test->output}}};
    while (!atomic_load(&test->go)) {}
    test->rendered = StreamProgramHALIOProc(3, &time, NULL, NULL, &list, &time, test->core);
    return NULL;
}
bool StudioProgramFixtureConcurrentRender(void) {
    for (int run = 0; run < 32; run++) {
        ConcurrentRender *test = calloc(1, sizeof(*test));
        if (test == NULL) return false;
        test->core = StreamProgramRenderCreate(); atomic_init(&test->go, false);
        if (test->core == NULL) { free(test); return false; }
        test->original = StreamProgramHostFrameAtTicks(mach_absolute_time()) - STREAM_PROGRAM_CAPACITY + 1024;
        for (int n = 0; n < 3072; n++) {
            test->output[n*2] = (float)(n + 1) / 8192; test->output[n*2+1] = -test->output[n*2];
            test->replacement[n*2] = .75f; test->replacement[n*2+1] = -.75f;
        }
        bool initial = StreamProgramRenderSubmit(test->core, test->original, 3072, test->output);
        pthread_t writer, reader;
        if (!initial || pthread_create(&writer, NULL, replaceProgram, test) != 0) return false;
        if (pthread_create(&reader, NULL, readProgram, test) != 0) { atomic_store(&test->go, true); pthread_join(writer, NULL); return false; }
        atomic_store(&test->go, true); pthread_join(writer, NULL); pthread_join(reader, NULL);
        bool valid = test->wrote && test->rendered == noErr;
        for (int n = 0; n < 3072; n++) {
            float expected = (float)(n + 1) / 8192;
            float l = test->output[n*2], r = test->output[n*2+1];
            valid = valid && ((l == 0 && r == 0) || (l == expected && r == -expected));
        }
        StreamProgramRenderRetire(test->core); StreamProgramRenderDestroy(test->core); free(test);
        if (!valid) return false;
    }
    return true;
}
