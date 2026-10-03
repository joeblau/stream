#include "GuestReceive.h"
#include <rtc/rtc.hpp>
#include <rtc/version.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <mutex>
#include <map>
#include <sstream>

static_assert(RTC_VERSION_MAJOR == 0 && RTC_VERSION_MINOR == 24 && RTC_VERSION_PATCH == 0,
              "Guest receive requires the qualified public libdatachannel 0.24.0 ABI");

namespace {
using Clock = std::chrono::steady_clock;
uint16_t u16(const uint8_t *p) { return uint16_t(p[0]) << 8 | p[1]; }
uint32_t u32(const uint8_t *p) { return uint32_t(u16(p)) << 16 | u16(p + 2); }
bool qualifiedH264(const rtc::Description::Media::RtpMap &codec) {
    std::map<std::string, std::string> values;
    if (codec.fmtps.size() > 4) return false;
    for (const auto &line : codec.fmtps) {
        if (line.size() > 4096) return false;
        std::istringstream stream(line); std::string parameter;
        while (std::getline(stream, parameter, ';')) {
            const auto first = parameter.find_first_not_of(" \t"), last = parameter.find_last_not_of(" \t");
            if (first == std::string::npos) continue;
            parameter = parameter.substr(first, last - first + 1);
            const auto equals = parameter.find('=');
            if (equals == std::string::npos || !equals || equals + 1 == parameter.size() || values.size() >= 16) return false;
            auto key = parameter.substr(0, equals), value = parameter.substr(equals + 1);
            if (key.find_first_not_of("abcdefghijklmnopqrstuvwxyz-") != std::string::npos || value.find_first_of("\r\n\t ") != std::string::npos || !values.emplace(key, value).second) return false;
        }
    }
    auto profile = values.find("profile-level-id"), mode = values.find("packetization-mode");
    return mode != values.end() && mode->second == "1" && profile != values.end() && profile->second.size() == 6 &&
        profile->second.substr(0, 4) == "42e0" && profile->second.find_first_not_of("0123456789abcdef") == std::string::npos;
}
struct State {
    std::recursive_mutex mutex;
    bool active = true;
    uint64_t generation;
    SGMediaCallback media;
    SGSignalCallback signal;
    void *context;
};
struct ValidatedRTP {
    rtc::message_ptr packet;
    const uint8_t *payload;
    size_t bytes;
    uint32_t timestamp;
    uint16_t sequence;
    bool marker;
};
bool rtp(const rtc::message_ptr &message, int pt, uint32_t ssrc, ValidatedRTP &out) {
    const auto n = message->size();
    if (n < 13 || n > 4096) return false;
    const auto p = reinterpret_cast<const uint8_t *>(message->data());
    if ((p[0] >> 6) != 2 || (p[1] & 127) != pt || u32(p + 8) != ssrc) return false;
    size_t header = 12 + 4 * (p[0] & 15);
    if (header > n) return false;
    if (p[0] & 16) {
        if (header + 4 > n) return false;
        const size_t extension = 4 + 4 * size_t(u16(p + header + 2));
        if (extension > 1028 || extension > n - header) return false;
        header += extension;
    }
    size_t padding = (p[0] & 32) ? p[n - 1] : 0;
    if ((p[0] & 32) && (padding == 0 || padding > n - header)) return false;
    if (header + padding >= n) return false;
    // Strip validated CSRC/extensions/padding privately, avoiding the pinned
    // generic depacketizer's CSRC offset bug. Clock and source fields survive.
    auto copy = rtc::make_message(12 + n - header - padding);
    std::memcpy(copy->data(), p, 12);
    reinterpret_cast<uint8_t *>(copy->data())[0] = 128;
    std::memcpy(copy->data() + 12, p + header, n - header - padding);
    out = {copy, reinterpret_cast<const uint8_t *>(copy->data()) + 12,
           n - header - padding, u32(p + 4), u16(p + 2), bool(p[1] & 128)};
    return true;
}
class Guard final : public rtc::MediaHandler {
    std::shared_ptr<State> state;
    int role, payloadType;
    uint32_t ssrc;
    rtc::RtcpReceivingSession receiving;
    rtc::message_vector pending;
    size_t bytes = 0;
    Clock::time_point began;
    uint32_t timestamp = 0;
    uint16_t nextSequence = 0;
    bool fragment = false, idr = false, needsIDR = true;
    uint8_t fragmentIdentity = 0;
    bool audioStarted = false;
    uint16_t audioSequence = 0;
    uint32_t audioTimestamp = 0;
    bool videoStarted = false;
    uint32_t videoTimestamp = 0;
    Clock::time_point lastPLI{};
    SGReceiveStats stats{};
    void clear(bool drop) {
        if (drop && !pending.empty()) ++stats.dropped;
        pending.clear(); bytes = 0; fragment = false; fragmentIdentity = 0; idr = false;
        if (drop) needsIDR = true;
    }
    bool nal(const uint8_t *p, size_t n) {
        if (!n || (p[0] & 128)) return false;
        const int type = p[0] & 31;
        if (type > 0 && type < 24) { if (fragment) return false; idr |= type == 5; return true; }
        if (type == 24) {
            if (fragment) return false;
            size_t offset = 1, entries = 0;
            while (offset < n) {
                if (++entries > 32) return false;
                if (offset + 2 > n) return false;
                const size_t count = u16(p + offset); offset += 2;
                if (!count || count > n - offset || (p[offset] & 128) || !(p[offset] & 31) || (p[offset] & 31) >= 24) return false;
                idr |= (p[offset] & 31) == 5; offset += count;
            }
            return offset == n && n > 1;
        }
        if (type == 28 && n >= 3) {
            const bool start = p[1] & 128, end = p[1] & 64;
            const int original = p[1] & 31;
            if ((p[1] & 32) || !original || original >= 24 || (start && end) || (start ? fragment : !fragment)) return false;
            const uint8_t identity = (p[0] & 0x60) | original;
            if (!start && identity != fragmentIdentity) return false;
            if (start) { fragment = true; fragmentIdentity = identity; idr |= original == 5; }
            if (end) fragment = false;
            return true;
        }
        return false;
    }
    void emit(rtc::message_vector &frames) {
        for (const auto &frame : frames) {
            if (!state->active || !state->media) break;
            if (!frame->frameInfo || frame->empty() || frame->size() > 2 * 1024 * 1024) { ++stats.rejected; continue; }
            ++stats.frames;
            state->media(state->context, state->generation, role, SG_FRAME,
                         reinterpret_cast<const uint8_t *>(frame->data()), frame->size(), frame->frameInfo->timestamp, 0);
        }
    }
    void control(const rtc::message_ptr &message, const rtc::message_callback &send) {
        // Validate every compound packet before any SDK reinterpret_cast.
        const auto n = message->size();
        if (n < 4 || n > 4096) { ++stats.rejected; return; }
        const auto p = reinterpret_cast<const uint8_t *>(message->data());
        size_t offset = 0, packets = 0;
        rtc::message_vector reports;
        while (offset < n) {
            if (++packets > 32 || offset + 4 > n || (p[offset] >> 6) != 2 || (p[offset] & 32)) { ++stats.rejected; return; }
            const size_t count = 4 * (size_t(u16(p + offset + 2)) + 1), rc = p[offset] & 31;
            if (count < 4 || count > n - offset) { ++stats.rejected; return; }
            if (p[offset + 1] == 200) {
                if (count != 28 + 24 * rc || u32(p + offset + 4) != ssrc) { ++stats.rejected; return; }
                reports.push_back(rtc::make_message(message->begin() + offset, message->begin() + offset + count, rtc::Message::Control));
            }
            offset += count;
        }
        for (auto &report : reports) {
            rtc::message_vector one{report}; receiving.incoming(one, send);
            auto sync = receiving.getSyncTimestamps();
            if (!state->active || !state->media) break;
            state->media(state->context, state->generation, role, SG_SENDER_REPORT, nullptr, 0, sync.rtpTimestamp, sync.ntpTimestamp);
        }
    }
public:
    Guard(std::shared_ptr<State> state_, int role_, int pt, uint32_t ssrc_) : state(state_), role(role_), payloadType(pt), ssrc(ssrc_) {}
    bool requestKeyframe(const rtc::message_callback &send) override {
        const auto now = Clock::now();
        if (now - lastPLI < std::chrono::milliseconds(250)) return false;
        lastPLI = now; return receiving.requestKeyframe(send);
    }
    bool expire() {
        std::lock_guard lock(state->mutex);
        if (!pending.empty() && Clock::now() - began > std::chrono::milliseconds(250)) { clear(true); return true; }
        return false;
    }
    SGReceiveStats snapshot() {
        std::lock_guard lock(state->mutex);
        auto value = stats; value.pending_bytes = bytes; value.pending_packets = pending.size(); return value;
    }
    void incoming(rtc::message_vector &messages, const rtc::message_callback &send) override {
        std::lock_guard lock(state->mutex);
        if (!state->active) { messages.clear(); clear(false); return; }
        for (auto &message : messages) {
            if (message->type == rtc::Message::Control) { control(message, send); continue; }
            ValidatedRTP packet{};
            if (!rtp(message, payloadType, ssrc, packet)) { ++stats.rejected; clear(true); continue; }
            if (reinterpret_cast<const uint8_t *>(message->data())[0] & 16) ++stats.extension_packets;
            // Track the validated ORIGINAL sequence/SSRC for RR/PLI. The
            // AU-private sequence normalization below is never a transport stat.
            rtc::message_vector observed{packet.packet}; receiving.incoming(observed, send);
            if (role == SG_AUDIO) {
                if (packet.bytes > 1275) { ++stats.rejected; continue; }
                if (audioStarted && (int16_t(packet.sequence - audioSequence) <= 0 || int32_t(packet.timestamp - audioTimestamp) <= 0)) { ++stats.rejected; continue; }
                audioStarted = true; audioSequence = packet.sequence; audioTimestamp = packet.timestamp;
                rtc::message_vector audio{packet.packet}; rtc::OpusRtpDepacketizer depacketizer;
                depacketizer.incoming(audio, send); emit(audio); continue;
            }
            if (pending.empty() && videoStarted && int32_t(packet.timestamp - videoTimestamp) <= 0) { ++stats.rejected; continue; }
            if (!pending.empty() && (packet.timestamp != timestamp || packet.sequence != nextSequence || Clock::now() - began > std::chrono::milliseconds(250))) {
                clear(true); requestKeyframe(send);
            }
            if (pending.empty()) { timestamp = packet.timestamp; began = Clock::now(); }
            if (pending.size() >= 512 || bytes + packet.packet->size() > 2 * 1024 * 1024 || !nal(packet.payload, packet.bytes) || (packet.marker && fragment)) {
                ++stats.rejected; clear(true); requestKeyframe(send); continue;
            }
            // A complete private AU is normalized to avoid the SDK's unsigned
            // sequence comparison at wrap. Original continuity was checked above.
            auto p = reinterpret_cast<uint8_t *>(packet.packet->data());
            p[2] = uint8_t(pending.size() >> 8); p[3] = uint8_t(pending.size());
            pending.push_back(packet.packet); bytes += packet.packet->size();
            stats.peak_bytes = std::max(stats.peak_bytes, uint64_t(bytes)); nextSequence = packet.sequence + 1;
            if (!packet.marker) continue;
            if (needsIDR && !idr) { clear(true); requestKeyframe(send); continue; }
            try {
                rtc::H264RtpDepacketizer depacketizer(rtc::NalUnit::Separator::LongStartSequence);
                depacketizer.incomingChain(pending, send); emit(pending); needsIDR = false;
                videoStarted = true; videoTimestamp = timestamp;
            } catch (...) { ++stats.rejected; clear(true); continue; }
            clear(false);
        }
        messages.clear(); // no raw packet or unknown control escapes this guard
    }
};
}
struct SGReceiver {
    std::shared_ptr<State> state;
    std::shared_ptr<rtc::PeerConnection> peer;
    std::array<std::string, 3> mids;
    std::array<uint32_t, 3> ssrcs{};
    bool configured = false;
    bool host = false;
    bool returnAudio = false, relayRequired = false, returnStarted = false;
    uint16_t returnSequence = 0;
    uint32_t returnSSRC = 0, returnLastRTP = 0, returnPackets = 0, returnBytes = 0;
    std::shared_ptr<rtc::DataChannel> control;
    std::array<std::shared_ptr<rtc::Track>, 3> tracks;
    std::array<std::shared_ptr<Guard>, 3> guards;
};
namespace {
SGReceiver *createReceiver(uint64_t generation, const char *camera, const char *screen, const char *audio,
                           SGMediaCallback media, SGSignalCallback signal, void *context,
                           const rtc::Configuration &configuration) {
    if (!generation || !camera || !screen || !audio || !media || !signal || !context) return nullptr;
    std::array<std::string, 3> mids{camera, screen, audio};
    for (auto &mid : mids) if (mid.empty() || mid.size() > 64 || mid.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != std::string::npos) return nullptr;
    if (mids[0] == mids[1] || mids[0] == mids[2] || mids[1] == mids[2]) return nullptr;
    try {
        auto owner = std::make_unique<SGReceiver>(); auto result = owner.get();
        result->mids = mids; result->state = std::make_shared<State>();
        result->relayRequired = configuration.iceTransportPolicy == rtc::TransportPolicy::Relay;
        result->returnSSRC = 0x5354524dU ^ uint32_t(generation);
        if (!result->returnSSRC) result->returnSSRC = 1;
        auto state = result->state;
        state->generation = generation; state->media = media; state->signal = signal; state->context = context;
        result->peer = std::make_shared<rtc::PeerConnection>(configuration);
        result->peer->onLocalDescription([state](rtc::Description description) {
            std::lock_guard lock(state->mutex); if (!state->active) return;
            const std::string sdp = description; state->signal(state->context, description.typeString().c_str(), sdp.c_str(), "");
        });
        result->peer->onLocalCandidate([state](rtc::Candidate candidate) {
            std::lock_guard lock(state->mutex); if (!state->active) return;
            const std::string value = candidate; state->signal(state->context, "candidate", value.c_str(), candidate.mid().c_str());
        });
        // Registration occurs synchronously during offer setup; a closed
        // receiver fences this callback before its handle can be destroyed.
        result->peer->onTrack([result, state](std::shared_ptr<rtc::Track> track) {
            std::lock_guard lock(state->mutex); if (!state->active) { track->close(); return; }
            int role = -1; for (int i = 0; i < 3; ++i) if (track->mid() == result->mids[i]) role = i;
            if (role < 0 || result->tracks[role]) { track->close(); return; }
            const auto description = track->description();
            const int pt = role == SG_AUDIO ? 111 : 96;
            const auto codec = description.rtpMap(pt);
            // Reciprocal local descriptions deliberately clear remote SSRCs.
            // Use the validated original offer's source identity instead.
            if (!result->ssrcs[role] || !codec || codec->format != (role == SG_AUDIO ? "opus" : "H264") || codec->clockRate != (role == SG_AUDIO ? 48000 : 90000)) { track->close(); return; }
            auto guard = std::make_shared<Guard>(state, role, pt, result->ssrcs[role]);
            result->tracks[role] = track; result->guards[role] = guard; track->setMediaHandler(guard);
        });
        return owner.release();
    } catch (...) { return nullptr; }
}
bool boundedText(const char *value, size_t maximum, bool required) {
    if (!value) return !required;
    const auto count = strnlen(value, maximum + 1);
    if (count > maximum || (required && !count)) return false;
    for (size_t i = 0; i < count; ++i) if (uint8_t(value[i]) < 32 || uint8_t(value[i]) == 127) return false;
    return true;
}
struct TemporaryRelayConfiguration {
    rtc::Configuration value;
    ~TemporaryRelayConfiguration() {
        // Best effort for application-owned copies. SDK copies are retained
        // solely by this peer and released on its synchronous destruction.
        for (auto &server : value.iceServers) {
            for (auto *text : {&server.username, &server.password}) {
                volatile char *bytes = text->data();
                for (size_t i = 0; i < text->size(); ++i) bytes[i] = 0;
                text->clear();
            }
        }
    }
};
}
extern "C" SGReceiver *SGReceiverCreate(uint64_t generation, const char *camera, const char *screen, const char *audio,
                                        SGMediaCallback media, SGSignalCallback signal, void *context) {
    rtc::Configuration configuration; configuration.bindAddress = "127.0.0.1";
    configuration.disableAutoNegotiation = true; configuration.maxMessageSize = 1024;
    return createReceiver(generation, camera, screen, audio, media, signal, context, configuration);
}
extern "C" SGReceiver *SGReceiverCreateConfigured(uint64_t generation, const char *camera, const char *screen, const char *audio,
                                                  const SGIceServer *servers, size_t count,
                                                  SGMediaCallback media, SGSignalCallback signal, void *context) {
    if (!servers || !count || count > 64) return nullptr;
    try {
        TemporaryRelayConfiguration configuration;
        configuration.value.disableAutoNegotiation = true; configuration.value.maxMessageSize = 1024;
        configuration.value.iceTransportPolicy = rtc::TransportPolicy::Relay;
        bool hasRelay = false;
        for (size_t i = 0; i < count; ++i) {
            const auto &entry = servers[i];
            if (!boundedText(entry.url, 512, true)) return nullptr;
            const std::string url(entry.url);
            const auto separator = url.find(':');
            const auto scheme = url.substr(0, separator);
            if (separator == std::string::npos || (scheme != "stun" && scheme != "stuns" && scheme != "turn" && scheme != "turns")) return nullptr;
            const auto query = url.find('?');
            if (query != std::string::npos && url.substr(query) != "?transport=udp" && url.substr(query) != "?transport=tcp") return nullptr;
            auto authority = url.substr(separator + 1, (query == std::string::npos ? url.size() : query) - separator - 1);
            const auto portSeparator = authority.find(':');
            auto host = authority.substr(0, portSeparator);
            if (host.empty() || host.size() > 253 || host.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-") != std::string::npos) return nullptr;
            if (portSeparator != std::string::npos) {
                const auto port = authority.substr(portSeparator + 1);
                if (port.empty() || port.size() > 5 || port.find_first_not_of("0123456789") != std::string::npos) return nullptr;
                const auto number = std::stoul(port);
                if (!number || number > 65535 || number == 53) return nullptr;
            }
            rtc::IceServer server(url);
            const bool relay = scheme == "turn" || scheme == "turns";
            if (relay) {
                if (server.type != rtc::IceServer::Type::Turn || !boundedText(entry.username, 256, true) || !boundedText(entry.credential, 2048, true)) return nullptr;
                // The pinned public libjuice transport supports UDP TURN only.
                // Validate every descriptor, but do not claim an unusable
                // TCP/TLS relay as the configuration's required capability.
                if (server.relayType != rtc::IceServer::RelayType::TurnUdp) continue;
                server.username = entry.username; server.password = entry.credential; hasRelay = true;
            } else if (server.type != rtc::IceServer::Type::Stun || entry.username || entry.credential) return nullptr;
            configuration.value.iceServers.push_back(std::move(server));
        }
        if (!hasRelay) return nullptr;
        return createReceiver(generation, camera, screen, audio, media, signal, context, configuration.value);
    } catch (...) { return nullptr; }
}
extern "C" void SGReceiverWipeBuffer(void *buffer, size_t bytes) {
    if (!buffer || bytes > 4096) return;
    volatile uint8_t *owned = static_cast<uint8_t *>(buffer);
    for (size_t i = 0; i < bytes; ++i) owned[i] = 0;
}
extern "C" int SGReceiverOffer(SGReceiver *receiver, const char *sdp) {
    if (!receiver || !sdp || std::strlen(sdp) > 65536) return 0;
    try {
        rtc::Description offer(sdp, "offer");
        if (offer.mediaCount() != 3) return 0;
        std::array<uint32_t, 3> ssrcs{};
        for (int i = 0; i < offer.mediaCount(); ++i) {
            auto entry = offer.media(i);
            if (!std::holds_alternative<rtc::Description::Media *>(entry)) return 0;
            auto media = std::get<rtc::Description::Media *>(entry);
            int role = -1; for (int j = 0; j < 3; ++j) if (media->mid() == receiver->mids[j]) role = j;
            if (role < 0 || ssrcs[role] || media->direction() != rtc::Description::Direction::SendOnly || media->type() != (role == SG_AUDIO ? "audio" : "video")) return 0;
            const auto sources = media->getSSRCs(); const auto codec = media->rtpMap(role == SG_AUDIO ? 111 : 96);
            if (sources.size() != 1 || !sources[0] || !codec || codec->format != (role == SG_AUDIO ? "opus" : "H264") || codec->clockRate != (role == SG_AUDIO ? 48000 : 90000)) return 0;
            ssrcs[role] = sources[0];
        }
        if (ssrcs[0] == ssrcs[1] || ssrcs[0] == ssrcs[2] || ssrcs[1] == ssrcs[2]) return 0;
        { std::lock_guard lock(receiver->state->mutex); if (!receiver->state->active || receiver->configured || receiver->host) return 0;
          receiver->ssrcs = ssrcs; receiver->configured = true; }
        receiver->peer->setRemoteDescription(offer);
        receiver->peer->setLocalDescription(rtc::Description::Type::Answer); return 1;
    } catch (...) { return 0; }
}
extern "C" int SGReceiverStartHost(SGReceiver *receiver) {
    if (!receiver) return 0;
    try {
        std::lock_guard lock(receiver->state->mutex);
        if (!receiver->state->active || receiver->configured || receiver->host) return 0;
        receiver->host = true;
        // Offer only qualified primary H264 mode1 and Opus. No RTX, other video
        // codec or payload-type assumptions inherited from a browser's offer.
        for (int role : {SG_AUDIO, SG_CAMERA, SG_SCREEN}) {
            if (role == SG_AUDIO) {
                rtc::Description::Audio audio(receiver->mids[role], receiver->returnAudio ?
                    rtc::Description::Direction::SendRecv : rtc::Description::Direction::RecvOnly);
                audio.addOpusCodec(111, "minptime=10;useinbandfec=1;stereo=1;sprop-stereo=1");
                audio.addExtMap(rtc::Description::Entry::ExtMap(1, "urn:ietf:params:rtp-hdrext:sdes:mid"));
                if (receiver->returnAudio) audio.addSSRC(receiver->returnSSRC, "stream-return", "stream-return", "audio-return");
                receiver->tracks[role] = receiver->peer->addTrack(audio);
            } else {
                rtc::Description::Video video(receiver->mids[role], rtc::Description::Direction::RecvOnly);
                video.addH264Codec(96, "profile-level-id=42e01f;packetization-mode=1;level-asymmetry-allowed=1");
                video.addExtMap(rtc::Description::Entry::ExtMap(1, "urn:ietf:params:rtp-hdrext:sdes:mid"));
                receiver->tracks[role] = receiver->peer->addTrack(video);
            }
        }
        auto state = receiver->state;
        receiver->control = receiver->peer->createDataChannel("stream-interview-control-v1");
        receiver->control->onOpen([state] {
            std::lock_guard lock(state->mutex); if (state->active) state->signal(state->context, "control-open", "", "");
        });
        receiver->control->onClosed([state] {
            std::lock_guard lock(state->mutex); if (state->active) state->signal(state->context, "control-closed", "", "");
        });
        receiver->control->onError([state](rtc::string) {
            std::lock_guard lock(state->mutex); if (state->active) state->signal(state->context, "control-closed", "", "");
        });
        receiver->control->onMessage([](rtc::binary) {}, [state](rtc::string message) {
            std::lock_guard lock(state->mutex);
            if (state->active && message.size() <= 1024) state->signal(state->context, "control", message.c_str(), "");
        });
        receiver->peer->setLocalDescription(rtc::Description::Type::Offer); return 1;
    } catch (...) { return 0; }
}
extern "C" int SGReceiverAnswer(SGReceiver *receiver, const char *sdp) {
    if (!receiver || !sdp || std::strlen(sdp) > 65536) return 0;
    try {
        rtc::Description answer(sdp, "answer");
        if (answer.mediaCount() != 4 || !answer.hasApplication()) return 0;
        std::array<uint32_t, 3> ssrcs{};
        for (int i = 0; i < answer.mediaCount(); ++i) {
            auto entry = answer.media(i);
            if (std::holds_alternative<rtc::Description::Application *>(entry)) continue;
            auto media = std::get<rtc::Description::Media *>(entry);
            int role = -1; for (int j = 0; j < 3; ++j) if (media->mid() == receiver->mids[j]) role = j;
            if (role < 0 || ssrcs[role] || media->direction() !=
                (role == SG_AUDIO && receiver->returnAudio ? rtc::Description::Direction::SendRecv : rtc::Description::Direction::SendOnly) ||
                media->type() != (role == SG_AUDIO ? "audio" : "video")) return 0;
            const int pt = role == SG_AUDIO ? 111 : 96;
            const auto codec = media->rtpMap(pt); const auto sources = media->getSSRCs();
            if (!codec || codec->format != (role == SG_AUDIO ? "opus" : "H264") || codec->clockRate != (role == SG_AUDIO ? 48000 : 90000) || sources.size() != 1 || !sources[0]) return 0;
            // Every negotiated payload must be the primary codec we offered.
            if (media->payloadTypes().size() != 1 || media->payloadTypes()[0] != pt) return 0;
            if (role != SG_AUDIO && !qualifiedH264(*codec)) return 0;
            ssrcs[role] = sources[0];
        }
        if (!ssrcs[0] || !ssrcs[1] || !ssrcs[2] || ssrcs[0] == ssrcs[1] || ssrcs[0] == ssrcs[2] || ssrcs[1] == ssrcs[2]) return 0;
        {
            std::lock_guard lock(receiver->state->mutex);
            if (!receiver->state->active || !receiver->host || receiver->configured) return 0;
            receiver->configured = true; receiver->ssrcs = ssrcs;
            for (int role = 0; role < 3; ++role) {
                auto guard = std::make_shared<Guard>(receiver->state, role, role == SG_AUDIO ? 111 : 96, ssrcs[role]);
                receiver->guards[role] = guard; receiver->tracks[role]->setMediaHandler(guard);
            }
        }
        receiver->peer->setRemoteDescription(answer); return 1;
    } catch (...) { return 0; }
}
extern "C" int SGReceiverHostReady(SGReceiver *receiver) {
    if (!receiver) return 0;
    std::lock_guard lock(receiver->state->mutex);
    return receiver->state->active && receiver->configured && receiver->control && receiver->control->isOpen() && receiver->peer->state() == rtc::PeerConnection::State::Connected;
}
extern "C" int SGReceiverEnableReturnAudio(SGReceiver *receiver, uint64_t generation) {
    if (!receiver) return 0;
    std::lock_guard lock(receiver->state->mutex);
    if (!receiver->state->active || generation != receiver->state->generation || receiver->configured || receiver->host) return 0;
    receiver->returnAudio = true; return 1;
}
extern "C" int SGReceiverSendReturnOpus(SGReceiver *receiver, uint64_t generation,
                                         const uint8_t *data, size_t bytes, uint32_t timestamp, uint64_t ntp) {
    if (!receiver || !data || !bytes || bytes > 1275 || !ntp) return 0;
    const unsigned configuration = data[0] >> 3;
    const unsigned perFrame = configuration < 12 ? std::array<unsigned, 4>{480, 960, 1920, 2880}[configuration & 3]
        : configuration < 16 ? std::array<unsigned, 2>{480, 960}[configuration & 1]
        : std::array<unsigned, 4>{120, 240, 480, 960}[configuration & 3];
    unsigned count = 1;
    switch (data[0] & 3) { case 1: case 2: count = 2; break;
        case 3: if (bytes < 2) return 0; count = data[1] & 63; break; default: break; }
    if (!count || count > 48 || perFrame * count != 960) return 0;
    try {
        std::lock_guard lock(receiver->state->mutex);
        if (!receiver->state->active || generation != receiver->state->generation || !receiver->returnAudio ||
            !receiver->host || !receiver->configured || !receiver->control || !receiver->control->isOpen() ||
            receiver->peer->state() != rtc::PeerConnection::State::Connected) return 0;
        auto track = receiver->tracks[SG_AUDIO];
        if (!track || !track->isOpen() || track->bufferedAmount() > 16384) return 0;
        if (receiver->relayRequired) {
            rtc::Candidate local, remote;
            if (!receiver->peer->getSelectedCandidatePair(&local, &remote) || local.type() != rtc::Candidate::Type::Relayed) return 0;
        }
        if (receiver->returnStarted && int32_t(timestamp - receiver->returnLastRTP) <= 0) return 0;
        // Only one20ms packet is admitted per source window. There is no
        // application-owned outbound byte queue, retry backlog or clock rebase.
        const auto store32 = [](uint8_t *p, uint32_t value) {
            for (int i = 0; i < 4; ++i) p[i] = uint8_t(value >> (24 - 8 * i));
        };
        rtc::binary packet(12 + bytes);
        auto p = reinterpret_cast<uint8_t *>(packet.data());
        p[0] = 128; p[1] = 111 | (receiver->returnStarted ? 0 : 128);
        p[2] = uint8_t(receiver->returnSequence >> 8); p[3] = uint8_t(receiver->returnSequence);
        store32(p + 4, timestamp); store32(p + 8, receiver->returnSSRC);
        std::memcpy(p + 12, data, bytes);
        if (!track->send(std::move(packet))) return 0;
        ++receiver->returnSequence; ++receiver->returnPackets; receiver->returnBytes += uint32_t(bytes);
        const bool report = !receiver->returnStarted || receiver->returnPackets % 25 == 0;
        receiver->returnStarted = true; receiver->returnLastRTP = timestamp;
        if (report) {
            // Compound SR+SDES describes the captured source time, not encode
            // or network arrival. Future return video can use this same map.
            rtc::binary sr(52); auto r = reinterpret_cast<uint8_t *>(sr.data());
            std::memset(r, 0, sr.size()); r[0] = 128; r[1] = 200; r[3] = 6;
            store32(r + 4, receiver->returnSSRC); store32(r + 8, uint32_t(ntp >> 32));
            store32(r + 12, uint32_t(ntp)); store32(r + 16, timestamp);
            store32(r + 20, receiver->returnPackets); store32(r + 24, receiver->returnBytes);
            r[28] = 129; r[29] = 202; r[31] = 5; store32(r + 32, receiver->returnSSRC);
            r[36] = 1; r[37] = 13; std::memcpy(r + 38, "stream-return", 13);
            (void)track->send(std::move(sr));
        }
        return 1;
    } catch (...) { return 0; }
}
extern "C" int SGReceiverSendControl(SGReceiver *receiver, const char *message) {
    if (!receiver || !message || std::strlen(message) > 1024) return 0;
    try { std::lock_guard lock(receiver->state->mutex);
        if (!receiver->state->active || !receiver->control || !receiver->control->isOpen() || receiver->control->bufferedAmount() > 8192) return 0;
        receiver->control->send(rtc::string(message)); return 1;
    } catch (...) { return 0; }
}
extern "C" int SGReceiverCandidate(SGReceiver *receiver, const char *candidate, const char *mid) {
    if (!receiver || !candidate || !mid || std::strlen(candidate) > 4096 || std::strlen(mid) > 64) return 0;
    try { std::lock_guard lock(receiver->state->mutex); if (!receiver->state->active) return 0;
        receiver->peer->addRemoteCandidate(rtc::Candidate(candidate, mid)); return 1; } catch (...) { return 0; }
}
extern "C" void SGReceiverExpire(SGReceiver *receiver) {
    if (!receiver) return;
    std::lock_guard lock(receiver->state->mutex);
    for (int role = 0; role < 3; ++role) if (receiver->guards[role] && receiver->guards[role]->expire() && receiver->tracks[role]) receiver->tracks[role]->requestKeyframe();
}
extern "C" int SGReceiverRequestKeyframe(SGReceiver *receiver, int role) {
    if (!receiver || role < 0 || role > 1) return 0;
    std::lock_guard lock(receiver->state->mutex);
    return receiver->state->active && receiver->tracks[role] && receiver->tracks[role]->requestKeyframe();
}
extern "C" SGReceiveStats SGReceiverStats(SGReceiver *receiver, int role) {
    if (!receiver || role < 0 || role > 2) return {};
    std::lock_guard lock(receiver->state->mutex);
    return receiver->guards[role] ? receiver->guards[role]->snapshot() : SGReceiveStats{};
}
extern "C" SGIcePair SGReceiverSelectedIcePair(SGReceiver *receiver) {
    if (!receiver) return {};
    try {
        std::lock_guard lock(receiver->state->mutex);
        if (!receiver->state->active) return {};
        rtc::Candidate local, remote;
        if (!receiver->peer->getSelectedCandidatePair(&local, &remote)) return {};
        const auto type = [](rtc::Candidate::Type value) {
            switch (value) {
                case rtc::Candidate::Type::Host: return 1;
                case rtc::Candidate::Type::ServerReflexive: return 2;
                case rtc::Candidate::Type::PeerReflexive: return 3;
                case rtc::Candidate::Type::Relayed: return 4;
                default: return 0;
            }
        };
        return {1, type(local.type()), type(remote.type()),
                local.transportType() == rtc::Candidate::TransportType::Udp ? 1 : 0};
    } catch (...) { return {}; }
}
extern "C" void SGReceiverStop(SGReceiver *receiver) {
    if (!receiver) return;
    { std::lock_guard lock(receiver->state->mutex);
      receiver->state->active = false; receiver->state->media = nullptr; receiver->state->signal = nullptr; receiver->state->context = nullptr; }
    receiver->peer->resetCallbacks(); receiver->peer->close();
    if (receiver->control) { receiver->control->resetCallbacks(); receiver->control->close(); }
}
extern "C" void SGReceiverDestroy(SGReceiver *receiver) { SGReceiverStop(receiver); delete receiver; }
#ifdef STREAM_GUEST_VALIDATION
extern "C" int SGReceiverValidationPacket(SGReceiver *receiver, int role, const uint8_t *data, size_t count) {
    if (!receiver || role < 0 || role > 2 || !data || count > 4096) return 0;
    std::lock_guard lock(receiver->state->mutex);
    if (!receiver->state->active || !receiver->guards[role]) return 0;
    rtc::message_vector packets{rtc::make_message(reinterpret_cast<const rtc::byte *>(data), reinterpret_cast<const rtc::byte *>(data + count))};
    receiver->guards[role]->incoming(packets, [](rtc::message_ptr) {}); return 1;
}
#endif
