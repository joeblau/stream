#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>
#include <unistd.h>
#include <pthread.h>
#include <stdatomic.h>

static void check(Boolean passed, const char *name) { if (!passed) { fprintf(stderr, "FAIL: %s\n", name); exit(1); } }
static OSStatus changed(AudioServerPlugInHostRef host, AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress *addresses) { return noErr; }
static OSStatus copy(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef *value) { *value = NULL; return noErr; }
static OSStatus writeStorage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef value) { return noErr; }
static OSStatus deleteStorage(AudioServerPlugInHostRef host, CFStringRef key) { return noErr; }
static OSStatus configuration(AudioServerPlugInHostRef host, AudioObjectID device, UInt64 action, void *info) { return noErr; }

typedef struct { AudioServerPlugInDriverRef driver; _Atomic UInt32 progress, reads; _Atomic Boolean done; } ConcurrentIO;
static Float32 concurrentSample(UInt32 frame) { return (Float32)(frame % 8191 + 1) / 16384; }
static void *concurrentWriter(void *argument) {
    ConcurrentIO *test = argument; Float32 samples[256 * 2];
    AudioServerPlugInIOCycleInfo cycle = {0};
    for (UInt32 start = 0; start < 524288; start += 256) {
        for (UInt32 n = 0; n < 256; n++) { samples[n*2] = concurrentSample(start+n); samples[n*2+1] = -samples[n*2]; }
        cycle.mOutputTime.mSampleTime = start;
        check((*test->driver)->DoIOOperation(test->driver, 3, 8, 5, kAudioServerPlugInIOOperationWriteMix, 256, &cycle, samples, NULL) == noErr, "concurrent callback write");
        atomic_store(&test->progress, start + 256);
    }
    atomic_store(&test->done, true); return NULL;
}
static void *concurrentReader(void *argument) {
    ConcurrentIO *test = argument; Float32 samples[256 * 2]; AudioServerPlugInIOCycleInfo cycle = {0};
    do {
        UInt32 end = atomic_load(&test->progress);
        // Read slots at the wrap boundary while the producer replaces them.
        UInt32 start = end > 16384 ? end - 16384 : 0;
        cycle.mInputTime.mSampleTime = start + 512;
        check((*test->driver)->DoIOOperation(test->driver, 3, 4, 6, kAudioServerPlugInIOOperationReadInput, 256, &cycle, samples, NULL) == noErr, "concurrent callback read");
        for (UInt32 n = 0; n < 256; n++) {
            Float32 expected = concurrentSample(start+n);
            check((samples[n*2] == 0 && samples[n*2+1] == 0) ||
                (samples[n*2] == expected && samples[n*2+1] == -expected), "concurrent overwrite never substitutes another timestamp or splits stereo");
        }
        atomic_fetch_add(&test->reads, 1);
    } while (!atomic_load(&test->done));
    return NULL;
}

int main(int argc, const char *argv[]) {
    check(argc == 2, "driver binary argument");
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    check(library != NULL, "load actual universal AudioServerPlugIn bundle binary");
    void *(*factory)(CFAllocatorRef, CFUUIDRef) = dlsym(library, "StreamVirtualMicrophone_Create");
    check(factory != NULL, "exported public plug-in factory");
    AudioServerPlugInDriverRef driver = factory(kCFAllocatorDefault, kAudioServerPlugInTypeUUID);
    check(driver != NULL, "actual driver interface");
    AudioServerPlugInHostInterface host = { changed, copy, writeStorage, deleteStorage, configuration };
    check((*driver)->Initialize(driver, &host) == noErr, "initialize against host interface");
    AudioObjectPropertyAddress formatProperty = {kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioStreamBasicDescription format; UInt32 used = 0;
    check((*driver)->GetPropertyData(driver, 4, getpid(), &formatProperty, 0, NULL, sizeof(format), &used, &format) == noErr, "read actual input stream format");
    check(format.mSampleRate == 48000 && format.mChannelsPerFrame == 2 && format.mBitsPerChannel == 32 && format.mBytesPerFrame == 8, "48 kHz stereo Float32 interleaved");
    check((*driver)->StartIO(driver, 3, 1) == noErr && (*driver)->StartIO(driver, 3, 2) == noErr, "independent producer/consumer starts");
    Float64 sample0; UInt64 host0, seed0;
    check((*driver)->GetZeroTimeStamp(driver, 3, 1, &sample0, &host0, &seed0) == noErr, "host sample clock");
    enum { frames = 1024 }; Float32 sent[frames*2], received[frames*2];
    for (int n=0; n<frames; n++) { sent[n*2] = .25f * sinf((Float32)n / 48000 * 2 * (Float32)M_PI * 440); sent[n*2+1] = -.125f; }
    AudioServerPlugInIOCycleInfo cycle = {0}; cycle.mOutputTime.mSampleTime = 0; cycle.mInputTime.mSampleTime = 512;
    check((*driver)->DoIOOperation(driver, 3, 8, 1, kAudioServerPlugInIOOperationWriteMix, frames, &cycle, sent, NULL) == noErr, "write actual driver output operation");
    check((*driver)->DoIOOperation(driver, 3, 4, 2, kAudioServerPlugInIOOperationReadInput, frames, &cycle, received, NULL) == noErr, "read actual driver input operation");
    double energy = 0;
    for (int n=0; n<frames*2; n++) { check(fabsf(sent[n] - received[n]) < .000001f, "timestamped stereo PCM transfer"); energy += received[n]*received[n]; }
    check(energy > 20, "non-silent measured loopback");
    check((*driver)->DoIOOperation(driver, 3, 8, 1, kAudioServerPlugInIOOperationWriteMix, frames, &cycle, sent, NULL) != noErr, "duplicate write timestamps refused");
    AudioObjectPropertyAddress mute = {kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 muted = 1;
    check((*driver)->SetPropertyData(driver, 6, getpid(), &mute, 0, NULL, sizeof(muted), &muted) == noErr, "actual input mute control");
    (*driver)->DoIOOperation(driver, 3, 4, 2, kAudioServerPlugInIOOperationReadInput, frames, &cycle, received, NULL);
    for (int n=0; n<frames*2; n++) check(received[n] == 0, "mute applies to real input PCM");
    muted = 0; (*driver)->SetPropertyData(driver, 6, getpid(), &mute, 0, NULL, sizeof(muted), &muted);
    AudioObjectPropertyAddress volume = {kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    Float32 db = NAN;
    check((*driver)->SetPropertyData(driver, 5, getpid(), &volume, 0, NULL, sizeof(db), &db) != noErr, "non-finite volume rejected");
    db = -6;
    check((*driver)->SetPropertyData(driver, 5, getpid(), &volume, 0, NULL, sizeof(db), &db) == noErr, "actual input gain control");
    (*driver)->DoIOOperation(driver, 3, 4, 2, kAudioServerPlugInIOOperationReadInput, frames, &cycle, received, NULL);
    check(fabsf(received[1] - sent[1] * powf(10, -.3f)) < .000001f, "gain applies to actual PCM");
    db = 0; (*driver)->SetPropertyData(driver, 5, getpid(), &volume, 0, NULL, sizeof(db), &db);
    cycle.mInputTime.mSampleTime = 2048 + 512;
    memset(received, 0xff, sizeof(received));
    check((*driver)->DoIOOperation(driver, 3, 4, 2, kAudioServerPlugInIOOperationReadInput, frames, &cycle, received, NULL) == noErr, "underrun operation");
    for (int n=0; n<frames*2; n++) check(received[n] == 0, "underrun deterministic silence");
    cycle.mOutputTime.mSampleTime = 4096; sent[0] = NAN; sent[1] = 9;
    check((*driver)->DoIOOperation(driver, 3, 8, 1, kAudioServerPlugInIOOperationWriteMix, frames, &cycle, sent, NULL) == noErr, "bounded non-finite/clipping input");
    cycle.mInputTime.mSampleTime = 4096 + 512;
    (*driver)->DoIOOperation(driver, 3, 4, 2, kAudioServerPlugInIOOperationReadInput, frames, &cycle, received, NULL);
    check(received[0] == 0 && received[1] == 1, "NaN becomes silence and over-range clamps");
    check((*driver)->DoIOOperation(driver, 3, 4, 2, kAudioServerPlugInIOOperationReadInput, 8192, &cycle, received, NULL) != noErr, "oversized callback refused before buffer access");
    cycle.mInputTime.mSampleTime = NAN;
    check((*driver)->DoIOOperation(driver, 3, 4, 2, kAudioServerPlugInIOOperationReadInput, frames, &cycle, received, NULL) != noErr, "malformed timing refused");
    usleep(30000);
    Float64 sample1; UInt64 host1, seed1;
    (*driver)->GetZeroTimeStamp(driver, 3, 1, &sample1, &host1, &seed1);
    check(sample1 >= sample0 + 1024 && host1 > host0 && seed1 == seed0, "clock catches up after missed callbacks");
    check((*driver)->StopIO(driver, 3, 1) == noErr, "producer stops independently");
    cycle.mInputTime.mSampleTime = 8192 + 512;
    (*driver)->DoIOOperation(driver, 3, 4, 2, kAudioServerPlugInIOOperationReadInput, frames, &cycle, received, NULL);
    for (int n=0; n<frames*2; n++) check(received[n] == 0, "stopped producer gives subsequent consumers silence");
    check((*driver)->StopIO(driver, 3, 2) == noErr, "consumer stops");
    check((*driver)->PerformDeviceConfigurationChange(driver, 3, 44100, NULL) == noErr, "public sample-rate change");
    (*driver)->GetPropertyData(driver, 4, getpid(), &formatProperty, 0, NULL, sizeof(format), &used, &format);
    check(format.mSampleRate == 44100, "negotiated stream rate follows configuration");
    check((*driver)->PerformDeviceConfigurationChange(driver, 3, 96000, NULL) != noErr, "unsupported rate refused");
    check((*driver)->StartIO(driver, 3, 3) == noErr, "new session starts");
    (*driver)->GetZeroTimeStamp(driver, 3, 3, &sample1, &host1, &seed1);
    check(seed1 > seed0, "new session changes clock seed");
    cycle.mInputTime.mSampleTime = 4096 + 512;
    (*driver)->DoIOOperation(driver, 3, 4, 3, kAudioServerPlugInIOOperationReadInput, frames, &cycle, received, NULL);
    for (int n=0; n<frames*2; n++) check(received[n] == 0, "new session cannot replay old ring samples");
    (*driver)->StopIO(driver, 3, 3);
    (*driver)->PerformDeviceConfigurationChange(driver, 3, 48000, NULL);
    (*driver)->StartIO(driver, 3, 4);
    uint64_t before = mach_absolute_time();
    for (int n=0; n<2000; n++) {
        cycle.mOutputTime.mSampleTime = n * 256; cycle.mInputTime.mSampleTime = n * 256 + 512;
        check((*driver)->DoIOOperation(driver, 3, 8, 4, kAudioServerPlugInIOOperationWriteMix, 256, &cycle, sent, NULL) == noErr, "benchmark write");
        check((*driver)->DoIOOperation(driver, 3, 4, 4, kAudioServerPlugInIOOperationReadInput, 256, &cycle, received, NULL) == noErr, "benchmark read");
    }
    uint64_t elapsed = mach_absolute_time() - before;
    mach_timebase_info_data_t clock; mach_timebase_info(&clock);
    double milliseconds = (double)elapsed * clock.numer / clock.denom / 1e6;
    (*driver)->StopIO(driver, 3, 4);
    (*driver)->StartIO(driver, 3, 5); (*driver)->StartIO(driver, 3, 6);
    ConcurrentIO concurrent = {.driver = driver}; pthread_t producer, consumer;
    check(pthread_create(&consumer, NULL, concurrentReader, &concurrent) == 0, "launch concurrent reader");
    check(pthread_create(&producer, NULL, concurrentWriter, &concurrent) == 0, "launch concurrent writer");
    pthread_join(producer, NULL); pthread_join(consumer, NULL);
    check(atomic_load(&concurrent.reads) > 0, "concurrent wrap reads observed");
    (*driver)->StopIO(driver, 3, 5); (*driver)->StopIO(driver, 3, 6);
    printf("PASS: actual universal AudioServerPlugIn factory/interface, 48k stereo PCM energy=%.5f, 512-frame (10.667 ms) loopback, bounded/malformed/NaN/underrun handling, independent stop, 44.1k change, clock catch-up/session reset, concurrent ring-wrap stereo/timestamp integrity (%u reads); 512000 callback frames write+read in %.3f ms; no HAL installation\n", energy, atomic_load(&concurrent.reads), milliseconds);
    (*driver)->Release(driver); dlclose(library);
    return 0;
}
