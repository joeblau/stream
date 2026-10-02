#include "StreamLoopback.h"
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

// A stamp and a packed stereo sample avoid C data races when HAL read/write
// overlap. Sequential consistency makes stamp invalidation precede replacement
// samples for readers, so a matching pair of stamps cannot accept another frame.
// No allocation, locks, logging, IPC, or waits on the device's IO callback.
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Requires lock-free 64-bit atomics");
typedef struct { _Atomic uint64_t stamp, stereo; } Frame;
static Frame ring[STREAM_LOOPBACK_CAPACITY];
static _Atomic uint64_t writtenEnd;
static Boolean valid(Float64 sampleTime, UInt32 frames, const void *samples, Float32 gain) {
    return samples != NULL && frames <= STREAM_LOOPBACK_MAX_CALLBACK && isfinite(sampleTime) &&
        sampleTime >= 0 && sampleTime <= (Float64)(INT64_MAX - STREAM_LOOPBACK_MAX_CALLBACK) &&
        floor(sampleTime) == sampleTime && isfinite(gain) && gain >= 0 && gain <= 2;
}
static uint64_t bits(Float32 left, Float32 right) { Float32 stereo[2] = {left, right}; uint64_t result; memcpy(&result, stereo, 8); return result; }
void StreamLoopbackReset(void) {
    for (UInt32 n = 0; n < STREAM_LOOPBACK_CAPACITY; n++) atomic_store_explicit(&ring[n].stamp, 0, memory_order_seq_cst);
    atomic_store_explicit(&writtenEnd, 0, memory_order_release);
}
OSStatus StreamLoopbackWrite(Float64 sampleTime, UInt32 frames, const Float32 *samples, Float32 gain) {
    if (!valid(sampleTime, frames, samples, gain)) return kAudioHardwareIllegalOperationError;
    uint64_t start = (uint64_t)sampleTime;
    uint64_t previous = atomic_load_explicit(&writtenEnd, memory_order_acquire);
    if (start < previous || !atomic_compare_exchange_strong_explicit(&writtenEnd, &previous, start + frames, memory_order_acq_rel, memory_order_acquire))
        return kAudioHardwareIllegalOperationError;
    for (UInt32 n = 0; n < frames; n++) {
        Frame *slot = &ring[(start + n) % STREAM_LOOPBACK_CAPACITY];
        atomic_store_explicit(&slot->stamp, 0, memory_order_seq_cst);
        Float32 l = samples[n*2], r = samples[n*2+1];
        l = isfinite(l) ? fmaxf(-1, fminf(1, l * gain)) : 0;
        r = isfinite(r) ? fmaxf(-1, fminf(1, r * gain)) : 0;
        atomic_store_explicit(&slot->stereo, bits(l, r), memory_order_seq_cst);
        atomic_store_explicit(&slot->stamp, start + n + 1, memory_order_seq_cst);
    }
    return noErr;
}
OSStatus StreamLoopbackRead(Float64 sampleTime, UInt32 frames, Float32 *samples, Float32 gain) {
    if (!valid(sampleTime, frames, samples, gain)) return kAudioHardwareIllegalOperationError;
    int64_t start = (int64_t)sampleTime - STREAM_LOOPBACK_LATENCY;
    for (UInt32 n = 0; n < frames; n++) {
        int64_t wanted = start + n;
        Float32 l = 0, r = 0;
        if (wanted >= 0) {
            Frame *slot = &ring[(uint64_t)wanted % STREAM_LOOPBACK_CAPACITY];
            uint64_t stamp = atomic_load_explicit(&slot->stamp, memory_order_seq_cst);
            if (stamp == (uint64_t)wanted + 1) {
                uint64_t packed = atomic_load_explicit(&slot->stereo, memory_order_seq_cst);
                Float32 stereo[2]; memcpy(stereo, &packed, 8); l = stereo[0]; r = stereo[1];
                if (atomic_load_explicit(&slot->stamp, memory_order_seq_cst) != stamp) { l = 0; r = 0; }
            }
        }
        samples[n*2] = fmaxf(-1, fminf(1, l * gain));
        samples[n*2+1] = fmaxf(-1, fminf(1, r * gain));
    }
    return noErr;
}
