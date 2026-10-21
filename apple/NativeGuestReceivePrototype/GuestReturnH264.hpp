#pragma once
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace stream_guest_return {
struct NAL { size_t offset = 0, bytes = 0; };
struct AccessUnit { std::array<NAL, 64> nals{}; size_t count = 0; };

// Validate the complete bounded access unit before its first packet can leave.
// VideoToolbox's AVCC conversion emits four-byte separators and escaped EBSP.
inline bool parse(const uint8_t *data, size_t bytes, AccessUnit &unit) {
    unit.count = 0;
    if (!data || bytes < 5 || bytes > 65536 || data[0] || data[1] || data[2] || data[3] != 1) return false;
    size_t begin = 4;
    for (size_t i = begin; i + 3 <= bytes; ++i) {
        if (data[i] || data[i + 1]) continue;
        if (i + 4 <= bytes && !data[i + 2] && data[i + 3] == 1) {
            if (i == begin || unit.count >= unit.nals.size()) return false;
            unit.nals[unit.count++] = {begin, i - begin}; begin = i + 4; i += 3;
        } else if (data[i + 2] == 1) { return false; } // mixed short separator
    }
    if (begin >= bytes || unit.count >= unit.nals.size()) return false;
    unit.nals[unit.count++] = {begin, bytes - begin};
    for (size_t index = 0; index < unit.count; ++index) {
        const auto &nal = unit.nals[index];
        const auto type = data[nal.offset] & 31;
        if ((data[nal.offset] & 128) || !type || type >= 24) return false;
    }
    return true;
}

inline void store32(uint8_t *p, uint32_t value) {
    for (int i = 0; i < 4; ++i) p[i] = uint8_t(value >> (24 - 8 * i));
}

// All packets fit a 1200-byte RTP datagram. The callback must synchronously
// copy/send the stack bytes; it cannot retain this borrowed storage. False
// stops the AU immediately. A consumed sequence is never reused after failure.
template <typename Send>
bool packetize(const uint8_t *data, const AccessUnit &unit, uint32_t timestamp, uint32_t ssrc,
               uint16_t &sequence, uint32_t &packets, uint32_t &octets, Send send) {
    std::array<uint8_t, 1200> packet{};
    for (size_t index = 0; index < unit.count; ++index) {
        const auto [offset, count] = unit.nals[index];
        const bool fragment = count > 1188;
        size_t consumed = fragment ? 1 : 0;
        do {
            const auto payload = std::min(count - consumed, size_t(fragment ? 1186 : 1188));
            const bool final = consumed + payload == count;
            auto p = packet.data();
            p[0] = 128; p[1] = 96 | (final && index + 1 == unit.count ? 128 : 0);
            p[2] = uint8_t(sequence >> 8); p[3] = uint8_t(sequence);
            store32(p + 4, timestamp); store32(p + 8, ssrc);
            size_t header = 12;
            if (fragment) {
                p[header++] = (data[offset] & 224) | 28;
                p[header++] = (data[offset] & 31) | (consumed == 1 ? 128 : 0) | (final ? 64 : 0);
            }
            std::memcpy(p + header, data + offset + consumed, payload);
            ++sequence;
            if (!send(p, header + payload)) return false;
            ++packets; octets += uint32_t(header + payload - 12);
            consumed += payload;
        } while (consumed < count);
    }
    return true;
}
// Exact next-AU admission charge, using the shipping packetizer with local
// counters only. No network callback, sequence reservation or sender mutation.
inline uint32_t rtpBytes(const uint8_t *data, size_t bytes) {
    AccessUnit unit;
    if (!parse(data, bytes, unit)) return 0;
    uint16_t sequence = 0;
    uint32_t packets = 0, octets = 0;
    if (!packetize(data, unit, 0, 1, sequence, packets, octets,
                   [](const uint8_t *, size_t) { return true; })) return 0;
    return octets + 12 * packets;
}
}
