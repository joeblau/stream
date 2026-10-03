#include "guest_receive_peer_fixture.h"
#include <rtc/rtc.hpp>
#include <array>
#include <atomic>
#include <mutex>

struct SGPeerFixture {
    struct Callbacks { std::recursive_mutex mutex; bool active = true; SGSignalCallback signal; void *context; };
    std::shared_ptr<Callbacks> callbacks;
    std::shared_ptr<rtc::PeerConnection> peer;
    std::array<std::shared_ptr<rtc::Track>, 3> tracks;
};
extern "C" SGPeerFixture *SGPeerFixtureCreate(SGSignalCallback callback, void *context) {
    try {
        auto holder = std::make_unique<SGPeerFixture>();
        holder->callbacks = std::make_shared<SGPeerFixture::Callbacks>();
        auto state = holder->callbacks; state->signal = callback; state->context = context;
        rtc::Configuration config; config.bindAddress = "127.0.0.1"; config.disableAutoNegotiation = true;
        holder->peer = std::make_shared<rtc::PeerConnection>(config);
        holder->peer->onLocalDescription([state](rtc::Description description) {
            std::lock_guard lock(state->mutex); if (!state->active) return;
            std::string sdp = description; state->signal(state->context, description.typeString().c_str(), sdp.c_str(), "");
        });
        holder->peer->onLocalCandidate([state](rtc::Candidate candidate) {
            std::lock_guard lock(state->mutex); if (!state->active) return;
            std::string value = candidate; state->signal(state->context, "candidate", value.c_str(), candidate.mid().c_str());
        });
        // Deliberately different from semantic role order.
        for (int role : {SG_SCREEN, SG_AUDIO, SG_CAMERA}) {
            const char *mid = role == SG_CAMERA ? "camera-mid" : role == SG_SCREEN ? "screen-mid" : "audio-mid";
            if (role == SG_AUDIO) {
                rtc::Description::Audio audio(mid, rtc::Description::Direction::SendOnly); audio.addOpusCodec(111);
                audio.addSSRC(1001 + role, "same-guest"); holder->tracks[role] = holder->peer->addTrack(audio);
            } else {
                rtc::Description::Video video(mid, rtc::Description::Direction::SendOnly); video.addH264Codec(96);
                video.addSSRC(1001 + role, "same-guest"); holder->tracks[role] = holder->peer->addTrack(video);
            }
        }
        return holder.release();
    } catch (...) { return nullptr; }
}
extern "C" int SGPeerFixtureStart(SGPeerFixture *fixture) {
    try { fixture->peer->setLocalDescription(rtc::Description::Type::Offer); return 1; } catch (...) { return 0; }
}
extern "C" int SGPeerFixtureSignal(SGPeerFixture *fixture, const char *type, const char *value, const char *mid) {
    if (!fixture) return 0;
    try {
        if (std::string(type) == "candidate") fixture->peer->addRemoteCandidate(rtc::Candidate(value, mid));
        else fixture->peer->setRemoteDescription(rtc::Description(value, type));
        return 1;
    } catch (...) { return 0; }
}
extern "C" int SGPeerFixtureReady(SGPeerFixture *fixture) {
    if (!fixture) return 0;
    for (auto &track : fixture->tracks) if (!track->isOpen()) return 0;
    return fixture->peer->state() == rtc::PeerConnection::State::Connected;
}
extern "C" int SGPeerFixtureSend(SGPeerFixture *fixture, int role, const uint8_t *bytes, size_t count) {
    if (!fixture || role < 0 || role > 2 || !bytes || count > 4096) return 0;
    try { return fixture->tracks[role]->send(reinterpret_cast<const rtc::byte *>(bytes), count); } catch (...) { return 0; }
}
extern "C" void SGPeerFixtureDestroy(SGPeerFixture *fixture) {
    if (!fixture) return;
    { std::lock_guard lock(fixture->callbacks->mutex); fixture->callbacks->active = false; }
    fixture->peer->resetCallbacks(); fixture->peer->close(); delete fixture;
}
