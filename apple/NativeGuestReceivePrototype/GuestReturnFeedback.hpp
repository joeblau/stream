#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

namespace stream_guest_feedback {
struct Update {
    uint64_t rr_reports = 0, remb_reports = 0, remb_bits_per_second = 0;
    uint32_t extended_highest_sequence = 0, jitter_90khz = 0;
    int32_t cumulative_lost = 0;
    uint8_t fraction_lost = 0;
};
inline uint16_t read16(const uint8_t *p) { return uint16_t(p[0]) << 8 | p[1]; }
inline uint32_t read32(const uint8_t *p) { return uint32_t(read16(p)) << 16 | read16(p + 2); }

// Parse authenticated RTCP before any SDK cast or state publication. A bad
// trailing member rejects the entire compound, including an earlier valid RR.
// RFC3550 report fields and the deployed goog-remb format are wire values;
// neither received throughput nor an aggregate multi-source estimate is spare
// video capacity. The caller separately requires negotiated goog-remb.
inline bool parse(const uint8_t *data, size_t size, uint32_t remoteSSRC,
                  uint32_t returnVideoSSRC, Update &result) {
    if (!data || size < 4 || size > 4096) return false;
    Update pending;
    size_t offset = 0, packets = 0;
    while (offset < size) {
        if (++packets > 32 || size - offset < 4) return false;
        const auto p = data + offset;
        if ((p[0] >> 6) != 2 || (p[0] & 32)) return false;
        const size_t length = 4 * (size_t(read16(p + 2)) + 1), count = p[0] & 31;
        if (length > size - offset) return false;
        const auto type = p[1];
        if (type == 200 || type == 201) {
            const size_t base = type == 200 ? 28 : 8;
            if (length != base + 24 * count || (type == 200 && read32(p + 4) != remoteSSRC)) return false;
            for (size_t i = 0; i < count; ++i) {
                const auto block = p + base + 24 * i;
                if (!returnVideoSSRC || read32(block) != returnVideoSSRC) continue;
                ++pending.rr_reports;
                pending.fraction_lost = block[4];
                const uint32_t lost = uint32_t(block[5]) << 16 | uint32_t(block[6]) << 8 | block[7];
                pending.cumulative_lost = int32_t(lost) - ((lost & 0x800000U) ? 0x1000000 : 0);
                pending.extended_highest_sequence = read32(block + 8);
                pending.jitter_90khz = read32(block + 12);
            }
        } else if (type == 206 && count == 15) {
            // Other application feedback is ignored, but must have its common
            // sender/media header. REMB itself has an exact bounded SSRC list.
            if (length < 12) return false;
            if (length >= 16 && std::memcmp(p + 12, "REMB", 4) == 0) {
                if (length < 20 || read32(p + 8) != 0) return false;
                const size_t sources = p[16];
                if (!sources || length != 20 + sources * 4) return false;
                const unsigned exponent = p[17] >> 2;
                const uint64_t mantissa = uint64_t(p[17] & 3) << 16 | uint64_t(p[18]) << 8 | p[19];
                if (mantissa > (std::numeric_limits<uint64_t>::max() >> exponent)) return false;
                if (sources == 1 && returnVideoSSRC && read32(p + 20) == returnVideoSSRC) {
                    ++pending.remb_reports;
                    pending.remb_bits_per_second = mantissa << exponent;
                }
            }
        }
        offset += length;
    }
    result = pending;
    return true;
}
}
