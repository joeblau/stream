#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct SGReceiver SGReceiver;
// Track roles are negotiated explicitly. They are never inferred from order.
enum { SG_CAMERA = 0, SG_SCREEN = 1, SG_AUDIO = 2 };
enum { SG_FRAME = 0, SG_SENDER_REPORT = 1 };
typedef void (*SGMediaCallback)(void *, uint64_t generation, int role, int event,
                              const uint8_t *, size_t, uint32_t rtp, uint64_t ntp);
typedef void (*SGSignalCallback)(void *, const char *type, const char *value, const char *mid);
typedef struct {
    uint64_t frames, rejected, dropped, peak_bytes, extension_packets;
    size_t pending_bytes, pending_packets;
} SGReceiveStats;
// Prototype transport binds loopback only and uses no STUN/TURN service. Caller
// must supply a current explicit admission generation before constructing it.
SGReceiver *SGReceiverCreate(uint64_t admitted_generation, const char *camera_mid,
                             const char *screen_mid, const char *audio_mid,
                             SGMediaCallback, SGSignalCallback, void *context);
int SGReceiverOffer(SGReceiver *, const char *sdp);
int SGReceiverStartHost(SGReceiver *);
int SGReceiverAnswer(SGReceiver *, const char *sdp);
int SGReceiverHostReady(SGReceiver *);
int SGReceiverSendControl(SGReceiver *, const char *message);
int SGReceiverCandidate(SGReceiver *, const char *candidate, const char *mid);
void SGReceiverExpire(SGReceiver *);
int SGReceiverRequestKeyframe(SGReceiver *, int role);
SGReceiveStats SGReceiverStats(SGReceiver *, int role);
void SGReceiverStop(SGReceiver *);
void SGReceiverDestroy(SGReceiver *);
#ifdef STREAM_GUEST_VALIDATION
// Native validation feeds the ACTUAL guard when SRTP's own header/replay
// validation rejects a malformed datagram before it could reach that guard.
int SGReceiverValidationPacket(SGReceiver *, int role, const uint8_t *, size_t);
#endif
#ifdef __cplusplus
}
#endif
