// Controlled public libjuice boundary: owned loopback TURN credentials arrive
// only on stdin; output contains no address, SDP or credentials.
#include <juice/juice.h>
#include <arpa/inet.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <memory>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

struct Socket {
    int fd = -1;
    ~Socket() { if (fd >= 0) close(fd); }
};
static bool line(std::string &value, size_t limit) {
    for (int c; (c = std::cin.get()) != EOF;) {
        if (c == '\n') return !value.empty();
        if (c < 32 || c == 127 || value.size() >= limit) return false;
        value.push_back(char(c));
    }
    return false;
}
static void candidate(juice_agent_t *, const char *value, void *context) {
    if (std::strstr(value, " typ relay")) static_cast<std::atomic<bool> *>(context)->store(true);
}
static bool check(bool relay, uint16_t turnPort, const std::string &user, const std::string &credential) {
    Socket listener;
    listener.fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (listener.fd < 0 || bind(listener.fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0
        || listen(listener.fd, 1) != 0 || fcntl(listener.fd, F_SETFL, O_NONBLOCK) != 0) return false;
    socklen_t size = sizeof(address);
    if (getsockname(listener.fd, reinterpret_cast<sockaddr *>(&address), &size) != 0) return false;
    const int port = ntohs(address.sin_port);
    juice_turn_server_t server{};
    server.host = "127.0.0.1"; server.port = turnPort; server.username = user.c_str(); server.password = credential.c_str();
    std::atomic<bool> gathered{false};
    juice_config_t config{}; config.bind_address = "127.0.0.1";
    config.turn_servers = &server; config.turn_servers_count = 1;
    config.cb_candidate = candidate; config.user_ptr = &gathered;
    std::unique_ptr<juice_agent_t, decltype(&juice_destroy)> agent(juice_create(&config), juice_destroy);
    if (!agent || juice_set_relay_only(agent.get(), relay) != JUICE_ERR_SUCCESS
        || juice_set_ice_tcp_mode(agent.get(), JUICE_ICE_TCP_MODE_ACTIVE) != JUICE_ERR_SUCCESS) return false;
    const std::string remote = "a=ice-ufrag:fixture\r\na=ice-pwd:fixture-owned-check-only-password\r\n"
        "a=candidate:fixture 1 TCP 2122316799 127.0.0.1 " + std::to_string(port) + " typ host tcptype passive\r\n";
    if (juice_set_remote_description(agent.get(), remote.c_str()) != JUICE_ERR_SUCCESS
        || juice_gather_candidates(agent.get()) != JUICE_ERR_SUCCESS) return false;
    bool connected = false;
    auto end = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (std::chrono::steady_clock::now() < end && !gathered.load()) {
        int accepted = accept(listener.fd, nullptr, nullptr);
        if (accepted >= 0) { connected = true; close(accepted); }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    if (!gathered.load()) { std::cout << "FAIL: actual local TURN relay candidate was not gathered\n"; return false; }
    end = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    while (std::chrono::steady_clock::now() < end) {
        int accepted = accept(listener.fd, nullptr, nullptr);
        if (accepted >= 0) { connected = true; close(accepted); }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    agent.reset();
    const bool passed = relay ? !connected : connected;
    std::cout << (passed ? "PASS" : "FAIL") << ": actual " << (relay ? "Relay" : "All")
        << " ICE-TCP active, TURN relay gathered, owned remote TCP listener "
        << (connected ? "connected" : "unconnected") << '\n';
    return passed;
}
int main() {
    juice_set_log_level(JUICE_LOG_LEVEL_NONE);
    std::string port, user, credential;
    if (!line(port, 5) || !line(user, 256) || !line(credential, 2048)
        || !std::all_of(port.begin(), port.end(), [](unsigned char c) { return c >= '0' && c <= '9'; })) return 2;
    unsigned long parsed = std::stoul(port);
    if (!parsed || parsed > 65535 || parsed == 53) return 2;
    const bool all = check(false, uint16_t(parsed), user, credential);
    const bool relay = check(true, uint16_t(parsed), user, credential);
    std::fill(user.begin(), user.end(), '\0'); std::fill(credential.begin(), credential.end(), '\0');
    return all && relay ? 0 : 3;
}
