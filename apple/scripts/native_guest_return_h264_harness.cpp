#include "../NativeGuestReceivePrototype/GuestReturnH264.hpp"
#include "../NativeGuestReceivePrototype/GuestReturnClock.hpp"
#include <cassert>
#include <iostream>
#include <vector>

using namespace stream_guest_return;
static std::vector<uint8_t> unit(const std::vector<size_t> &sizes) {
    std::vector<uint8_t> data;
    for (auto size : sizes) {
        data.insert(data.end(), {0, 0, 0, 1});
        data.insert(data.end(), size, 0x55); data[data.size() - size] = 0x65;
    }
    return data;
}
static uint32_t read32(const uint8_t *p) {
    return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
}
static void roundTrip(const std::vector<size_t> &sizes) {
    const auto data = unit(sizes);
    AccessUnit au; assert(parse(data.data(), data.size(), au));
    uint16_t sequence = 65534;
    uint32_t packets = 0, octets = 0;
    std::vector<std::vector<uint8_t>> captured;
    assert(packetize(data.data(), au, 0xfffffff0, 0x12345678, sequence, packets, octets,
        [&](const uint8_t *bytes, size_t count) { captured.emplace_back(bytes, bytes + count); return true; }));
    assert(sequence == uint16_t(65534 + captured.size()) && packets == captured.size());
    std::vector<uint8_t> decoded;
    size_t payloadBytes = 0;
    for (size_t index = 0; index < captured.size(); ++index) {
        const auto &p = captured[index];
        assert(p.size() <= 1200 && p.size() > 12 && p[0] == 128 && (p[1] & 127) == 96);
        assert(bool(p[1] & 128) == (index + 1 == captured.size()));
        assert((uint16_t(p[2]) << 8 | p[3]) == uint16_t(65534 + index));
        assert(read32(p.data() + 4) == 0xfffffff0 && read32(p.data() + 8) == 0x12345678);
        payloadBytes += p.size() - 12;
        if ((p[12] & 31) == 28) {
            assert(p.size() >= 15 && !(p[13] & 32) && !((p[13] & 128) && (p[13] & 64)));
            if (p[13] & 128) { decoded.insert(decoded.end(), {0, 0, 0, 1}); decoded.push_back((p[12] & 224) | (p[13] & 31)); }
            decoded.insert(decoded.end(), p.begin() + 14, p.end());
        } else {
            decoded.insert(decoded.end(), {0, 0, 0, 1}); decoded.insert(decoded.end(), p.begin() + 12, p.end());
        }
    }
    assert(octets == payloadBytes && decoded == data);
    assert(rtpBytes(data.data(), data.size()) == payloadBytes + 12 * captured.size());
    assert(sendBytes(data.data(), data.size()) == payloadBytes + 12 * captured.size() + 52);
}
int main() {
    const uint64_t sourceTime = 100ULL << 32;
    assert(reportRtp(1000, sourceTime, sourceTime + (3ULL << 31), 48000) == 73000);
    assert(reportRtp(1000, sourceTime, sourceTime - (1ULL << 31), 48000) == uint32_t(1000 - 24000));
    assert(reportRtp(0xfffffff0, sourceTime, sourceTime + (3ULL << 31), 90000) == uint32_t(0xfffffff0 + 135000ULL));
    assert(reportRtp(1234, UINT64_MAX - (1ULL << 31) + 1, 1ULL << 31, 48000) == 49234);
    assert(reportRtp(1234, 0, 1, 48000) == 1234);
    for (const auto &sizes : std::vector<std::vector<size_t>>{{2}, {1188}, {1189}, {2373}, {2374}, {65532}, {7, 6, 4000}, std::vector<size_t>(64, 2)}) roundTrip(sizes);
    AccessUnit au;
    const auto reject = [&](const std::vector<uint8_t> &bytes) {
        assert(!parse(bytes.data(), bytes.size(), au));
        assert(rtpBytes(bytes.data(), bytes.size()) == 0);
        assert(sendBytes(bytes.data(), bytes.size()) == 0);
    };
    reject({}); reject({0, 0, 0, 1}); reject({1, 0, 0, 0, 1, 0x65});
    reject({0, 0, 1, 0x65, 0x55});
    reject({0, 0, 0, 1, 0x65, 0x55, 0, 0, 1, 0x61, 0x55});
    reject({0, 0, 0, 1, 0x65, 0, 0, 0, 1});
    reject({0, 0, 0, 1, 0x65, 0, 0, 0, 1, 0, 0, 0, 1, 0x65});
    reject({0, 0, 0, 1, 0xe5}); reject({0, 0, 0, 1, 0x00}); reject({0, 0, 0, 1, 0x78});
    reject(unit(std::vector<size_t>(65, 2))); reject(unit({65533}));
    // Real H264 emulation-prevention bytes must not be mistaken for a separator.
    const std::vector<uint8_t> escaped{0, 0, 0, 1, 0x65, 0, 0, 3, 1, 0x55};
    assert(parse(escaped.data(), escaped.size(), au) && au.count == 1);
    const auto data = unit({4000}); assert(parse(data.data(), data.size(), au));
    uint16_t sequence = 100;
    uint32_t packets = 0, octets = 0; size_t attempts = 0;
    assert(!packetize(data.data(), au, 1, 2, sequence, packets, octets,
        [&](const uint8_t *, size_t) { return ++attempts < 2; }));
    assert(attempts == 2 && sequence == 102 && packets == 1 && octets == 1188);
    assert(rtpBytes(data.data(), data.size()) > octets + 12 * packets);
    assert(sendBytes(data.data(), data.size()) > octets + 12 * packets + 52);
    assert(sequence == 102 && packets == 1 && octets == 1188); // Forecast reserves nothing.
    std::cout << "PASS: actual bounded H264 parser/packetizer, FU-A byte round trips, RTP marker/SSRC/PTS, sequence wrap, 64NAL/64KiB/1200byte caps, malformed rejection and failed-send sequence consumption\n";
    std::cout << "PASS: sender-report send-time clock extrapolation preserves original packet mapping across fractional, negative and NTP/RTP rollover cases\n";
    std::cout << "PASS: exact next-AU RTP+compound-RTCP admission charges match captured shipping packets and sender-report size without changing sequence or successful partial-send counters\n";
}
