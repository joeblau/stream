#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Explicit installed-device probe, separate from the in-process CI fixture.
// Never installs a driver or changes the machine's default audio devices.
static _Atomic uint64_t inputFrames, outputFrames, lateFrames, lateNonzero;
static _Atomic uint64_t silenceAfter;
static _Atomic uint32_t peakBits;
static double phase;
static OSStatus writer(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                       const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    if (output == NULL) return noErr;
    for (UInt32 n=0; n<output->mNumberBuffers; n++) {
        AudioBuffer *buffer = &output->mBuffers[n];
        if (buffer->mData == NULL || buffer->mNumberChannels != 2) continue;
        Float32 *samples = buffer->mData; UInt32 frames = buffer->mDataByteSize / 8;
        for (UInt32 f=0; f<frames; f++) { Float32 value = .1f * sin(phase); phase += 2*M_PI*440/48000; if (phase >= 2*M_PI) phase -= 2*M_PI; samples[f*2] = value; samples[f*2+1] = value; }
        atomic_fetch_add(&outputFrames, frames);
    }
    return noErr;
}
static OSStatus reader(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                       const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    if (output != NULL) for (UInt32 n=0; n<output->mNumberBuffers; n++) if (output->mBuffers[n].mData != NULL) memset(output->mBuffers[n].mData, 0, output->mBuffers[n].mDataByteSize);
    if (input == NULL) return noErr;
    Boolean late = atomic_load(&silenceAfter) != 0 && mach_absolute_time() > atomic_load(&silenceAfter);
    for (UInt32 n=0; n<input->mNumberBuffers; n++) {
        const AudioBuffer *buffer = &input->mBuffers[n];
        if (buffer->mData == NULL || buffer->mNumberChannels != 2) continue;
        const Float32 *samples = buffer->mData; UInt32 frames = buffer->mDataByteSize / 8;
        atomic_fetch_add(&inputFrames, frames);
        if (late) atomic_fetch_add(&lateFrames, frames);
        for (UInt32 f=0; f<frames*2; f++) {
            Float32 magnitude = fabsf(samples[f]); uint32_t bits; memcpy(&bits, &magnitude, 4);
            uint32_t previous = atomic_load(&peakBits);
            while (bits > previous && !atomic_compare_exchange_weak(&peakBits, &previous, bits)) {}
            if (late && magnitude > .000001f) atomic_fetch_add(&lateNonzero, 1);
        }
    }
    return noErr;
}
static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress value = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}; return value;
}
static Boolean supportedStream(AudioDeviceID device, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress property = address(kAudioDevicePropertyStreams); property.mScope = scope;
    UInt32 bytes = 0;
    if (AudioObjectGetPropertyDataSize(device, &property, 0, NULL, &bytes) != noErr || bytes != sizeof(AudioStreamID)) return false;
    AudioStreamID stream;
    if (AudioObjectGetPropertyData(device, &property, 0, NULL, &bytes, &stream) != noErr) return false;
    property = address(kAudioStreamPropertyVirtualFormat);
    AudioStreamBasicDescription format; bytes = sizeof(format);
    return AudioObjectGetPropertyData(stream, &property, 0, NULL, &bytes, &format) == noErr &&
        format.mFormatID == kAudioFormatLinearPCM && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
        (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0 && format.mChannelsPerFrame == 2 &&
        format.mBitsPerChannel == 32 && format.mBytesPerFrame == 8 && format.mSampleRate == 48000;
}
int main(int argc, const char *argv[]) {
    Boolean test = argc == 2 && strcmp(argv[1], "--test") == 0;
    AudioObjectPropertyAddress property = address(kAudioHardwarePropertyDevices); UInt32 bytes = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &property, 0, NULL, &bytes) != noErr || bytes > 4096) return 1;
    AudioDeviceID devices[1024], selected = kAudioObjectUnknown;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &bytes, devices) != noErr) return 1;
    for (UInt32 n=0; n<bytes/sizeof(AudioDeviceID); n++) {
        CFStringRef uid = NULL; UInt32 size = sizeof(uid); property = address(kAudioDevicePropertyDeviceUID);
        if (AudioObjectGetPropertyData(devices[n], &property, 0, NULL, &size, &uid) == noErr && uid != NULL) {
            if (CFEqual(uid, CFSTR("com.joeblau.Stream.VirtualMicrophonePrototype.device"))) selected = devices[n];
            CFRelease(uid);
        }
    }
    if (selected == kAudioObjectUnknown) { puts("Prototype HAL device unavailable; no installation or default-device changes performed."); return test ? 2 : 0; }
    puts("Installed prototype HAL device discovered by stable UID.");
    if (!test) { puts("Use --test explicitly to render a 440 Hz fixture and record the input side. Normal microphone consent applies."); return 0; }
    Float64 rate = 48000; bytes = sizeof(rate); property = address(kAudioDevicePropertyNominalSampleRate);
    if (AudioObjectSetPropertyData(selected, &property, 0, NULL, bytes, &rate) != noErr) return 3;
    Boolean configured = false;
    for (int n=0; n<100; n++) {
        if (supportedStream(selected, kAudioObjectPropertyScopeInput) && supportedStream(selected, kAudioObjectPropertyScopeOutput)) { configured = true; break; }
        usleep(10000);
    }
    if (!configured) { fprintf(stderr, "The installed prototype did not negotiate stereo Float32 48 kHz.\n"); return 3; }
    AudioDeviceIOProcID inputID = NULL, outputID = NULL;
    OSStatus result = AudioDeviceCreateIOProcID(selected, reader, NULL, &inputID);
    if (result == noErr) result = AudioDeviceCreateIOProcID(selected, writer, NULL, &outputID);
    if (result == noErr) result = AudioDeviceStart(selected, inputID);
    if (result == noErr) result = AudioDeviceStart(selected, outputID);
    if (result != noErr) fprintf(stderr, "HAL IO failed: %d. Check installation, format and microphone consent.\n", (int)result);
    else {
        sleep(3); AudioDeviceStop(selected, outputID);
        mach_timebase_info_data_t clock; mach_timebase_info(&clock);
        atomic_store(&silenceAfter, mach_absolute_time() + (uint64_t)(.1 * 1e9 * clock.denom / clock.numer));
        usleep(400000);
    }
    if (inputID != NULL) { AudioDeviceStop(selected, inputID); AudioDeviceDestroyIOProcID(selected, inputID); }
    if (outputID != NULL) { AudioDeviceStop(selected, outputID); AudioDeviceDestroyIOProcID(selected, outputID); }
    Float32 peak; uint32_t bits = atomic_load(&peakBits); memcpy(&peak, &bits, 4);
    printf("inputFrames=%llu outputFrames=%llu peak=%.6f postStopFrames=%llu postStopNonzeroSamples=%llu\n",
        (unsigned long long)atomic_load(&inputFrames), (unsigned long long)atomic_load(&outputFrames), peak,
        (unsigned long long)atomic_load(&lateFrames), (unsigned long long)atomic_load(&lateNonzero));
    return result == noErr && atomic_load(&inputFrames) > 48000 && atomic_load(&outputFrames) > 48000 && peak > .05 &&
        peak <= 1 && atomic_load(&lateFrames) > 0 && atomic_load(&lateNonzero) == 0 ? 0 : 4;
}
