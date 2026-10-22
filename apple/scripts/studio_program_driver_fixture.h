#pragma once
#include "../prototypes/VirtualMicrophone/StudioProgramRender.h"
bool StudioProgramFixtureLoad(const char *binary);
AudioDeviceID StudioProgramFixtureFind(void);
bool StudioProgramFixturePreflight(AudioDeviceID device);
void StudioProgramFixtureForeignUID(bool value);
OSStatus StudioProgramFixtureRate(uint64_t rate);
OSStatus StudioProgramFixtureStart(uint32_t client);
OSStatus StudioProgramFixtureStop(uint32_t client);
bool StudioProgramFixtureTime(double *sample, uint64_t *host);
OSStatus StudioProgramFixtureTransfer(StreamProgramRender *core, const AudioTimeStamp *time,
    uint32_t frames, float *rendered, float *received);
OSStatus StudioProgramFixtureRead(double sample, uint32_t frames, float *received);
bool StudioProgramFixtureConcurrentRender(void);
