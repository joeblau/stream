#pragma once
#include "../NativeGuestReceivePrototype/GuestReceive.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct SGPeerFixture SGPeerFixture;
SGPeerFixture *SGPeerFixtureCreate(SGSignalCallback, void *);
int SGPeerFixtureStart(SGPeerFixture *);
int SGPeerFixtureSignal(SGPeerFixture *, const char *type, const char *value, const char *mid);
int SGPeerFixtureReady(SGPeerFixture *);
int SGPeerFixtureSend(SGPeerFixture *, int role, const uint8_t *, size_t);
void SGPeerFixtureDestroy(SGPeerFixture *);
#ifdef __cplusplus
}
#endif
