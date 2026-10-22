// Optional SDK qualification only. Private loopback TURN credentials enter on
// stdin; only fixed outcome metadata leaves stdout. No capture devices.
#include <rtc/rtc.hpp>
#include <atomic>
#include <chrono>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <sys/sysctl.h>

extern "C" int stream_rtc_nice_relay_policy_20261021_v1();
extern "C" int stream_rtc_turn_transports_20261021_v1();

static bool line(std::string &value, size_t maximum) {
    for (int c; (c = std::cin.get()) != EOF;) {
        if (c == '\n') return !value.empty();
        if (c < 32 || c == 127 || value.size() >= maximum) return false;
        value.push_back(char(c));
    }
    return false;
}
struct Receipts {
    std::atomic<bool> received{false}, replied{false}, failed{false}, nonrelay{false};
    std::mutex mutex;
    std::vector<std::shared_ptr<rtc::DataChannel>> channels;
};
int main() {
    rtc::InitLogger(rtc::LogLevel::None);
    std::string port, username, credential;
    if (!line(port, 5) || !line(username, 256) || !line(credential, 2048)) return 2;
    try {
        if (port.find_first_not_of("0123456789") != std::string::npos || std::stoul(port) < 1024 || std::stoul(port) > 65535) return 2;
        if (stream_rtc_nice_relay_policy_20261021_v1() != 1 || stream_rtc_turn_transports_20261021_v1() != 3) return 3;
        rtc::Configuration config;
        config.iceTransportPolicy = rtc::TransportPolicy::Relay;
        config.iceServers.emplace_back("127.0.0.1", uint16_t(std::stoul(port)), username, credential, rtc::IceServer::RelayType::TurnTcp);
        auto state = std::make_shared<Receipts>();
        auto a = std::make_shared<rtc::PeerConnection>(config), b = std::make_shared<rtc::PeerConnection>(config);
        auto connect = [state](const auto &from, const auto &to) {
            std::weak_ptr<rtc::PeerConnection> weak = to;
            from->onLocalDescription([weak, state](rtc::Description description) {
                try { if (auto peer = weak.lock()) peer->setRemoteDescription(description); }
                catch (...) { state->failed = true; }
            });
            from->onLocalCandidate([weak, state](rtc::Candidate candidate) {
                if (candidate.type() != rtc::Candidate::Type::Relayed) state->nonrelay = true;
                try { if (auto peer = weak.lock()) peer->addRemoteCandidate(candidate); }
                catch (...) { state->failed = true; }
            });
        };
        connect(a, b); connect(b, a);
        b->onDataChannel([state](std::shared_ptr<rtc::DataChannel> channel) {
            std::weak_ptr<rtc::DataChannel> weak = channel;
            channel->onMessage([weak, state](rtc::message_variant message) {
                if (auto text = std::get_if<std::string>(&message); text && *text == "owned-host-control") {
                    state->received = true;
                    try { if (auto peer = weak.lock()) peer->send("owned-guest-receipt"); }
                    catch (...) { state->failed = true; }
                }
            });
            std::lock_guard<std::mutex> lock(state->mutex); state->channels.push_back(channel);
        });
        auto control = a->createDataChannel("owned-control");
        std::weak_ptr<rtc::DataChannel> weak = control;
        control->onOpen([weak, state] {
            try { if (auto channel = weak.lock()) channel->send("owned-host-control"); }
            catch (...) { state->failed = true; }
        });
        control->onMessage([state](rtc::message_variant message) {
            if (auto text = std::get_if<std::string>(&message); text && *text == "owned-guest-receipt") state->replied = true;
        });
        const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(12);
        while (!state->replied && !state->failed && std::chrono::steady_clock::now() < end) std::this_thread::sleep_for(std::chrono::milliseconds(10));
        rtc::Candidate al, ar, bl, br;
        const bool passed = state->received && state->replied && !state->failed && !state->nonrelay
            && a->getSelectedCandidatePair(&al, &ar) && b->getSelectedCandidatePair(&bl, &br)
            && al.type() == rtc::Candidate::Type::Relayed && bl.type() == rtc::Candidate::Type::Relayed;
        int translated = 0; size_t translatedSize = sizeof(translated);
        (void)sysctlbyname("sysctl.proc_translated", &translated, &translatedSize, nullptr, 0);
#if defined(__x86_64__)
        const char *architecture = "x86_64";
#else
        const char *architecture = "arm64";
#endif
        if (passed) std::cout << "PASS owned optional SDK relay-only bidirectional control over sole TCP TURN endpoint; arch="
            << architecture << "; translated=" << translated << '\n' << std::flush;
        // Keep the live sockets briefly for an independent parent process
        // selected-transport receipt, without publishing endpoint addresses.
        if (passed) std::this_thread::sleep_for(std::chrono::seconds(2));
        control->close(); a->close(); b->close();
        { std::lock_guard<std::mutex> lock(state->mutex); state->channels.clear(); }
        return passed ? 0 : 4;
    } catch (...) { return 5; }
}
