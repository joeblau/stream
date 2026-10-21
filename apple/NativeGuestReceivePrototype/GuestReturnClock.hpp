#pragma once
#include <chrono>
#include <cstdint>
#include <limits>

namespace stream_guest_return {
inline uint64_t reportNtpNow() {
    const auto nanos = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    if (nanos < 0) return 0;
    const uint64_t seconds = uint64_t(nanos / 1000000000) + 2208988800ULL;
    const uint64_t fraction = uint64_t(nanos % 1000000000) * (1ULL << 32) / 1000000000ULL;
    return (seconds << 32) | fraction;
}

// RFC 3550 6.4.1: an SR describes its sending instant. Extrapolate the same
// source-clock mapping to that instant; never change an RTP media timestamp.
inline uint32_t reportRtp(uint32_t sourceRtp, uint64_t sourceNtp, uint64_t reportNtp, uint32_t rate) {
    if (!rate || rate > 90000) return sourceRtp;
    const uint64_t forward = reportNtp - sourceNtp;
    const int64_t delta = forward <= uint64_t(std::numeric_limits<int64_t>::max())
        ? int64_t(forward) : -1 - int64_t(std::numeric_limits<uint64_t>::max() - forward);
    constexpr int64_t scale = 1LL << 32;
    // Splitting seconds/fraction keeps every product within int64_t, including
    // a negative clock correction and NTP/RTP rollover.
    const int64_t ticks = (delta / scale) * rate + (delta % scale) * rate / scale;
    return sourceRtp + uint32_t(ticks);
}
}
