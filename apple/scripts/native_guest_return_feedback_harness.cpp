#include "../NativeGuestReceivePrototype/GuestReturnFeedback.hpp"
#include <cassert>
#include <cstdio>
#include <random>
#include <vector>
using stream_guest_feedback::Update;
using Bytes = std::vector<uint8_t>;
constexpr uint32_t remote = 0x76543210, video = 0x5354524d;
static void put32(Bytes &bytes, size_t index, uint32_t value) {
    for (unsigned i = 0; i < 4; ++i) bytes[index + i] = uint8_t(value >> (24 - i * 8));
}
static Bytes rr(uint32_t target = video) {
    Bytes bytes(32);
    bytes[0] = 129; bytes[1] = 201; bytes[3] = 7;
    put32(bytes, 4, remote); put32(bytes, 8, target);
    bytes[12] = 64; bytes[13] = 255; bytes[14] = 255; bytes[15] = 254;
    put32(bytes, 16, 0xfffffff0); put32(bytes, 20, 1350);
    return bytes;
}
static Bytes remb(uint32_t target = video, unsigned exponent = 1, uint32_t mantissa = 200000) {
    Bytes bytes(24);
    bytes[0] = 143; bytes[1] = 206; bytes[3] = 5;
    put32(bytes, 4, remote);
    bytes[12] = 'R'; bytes[13] = 'E'; bytes[14] = 'M'; bytes[15] = 'B';
    bytes[16] = 1; bytes[17] = uint8_t(exponent << 2 | (mantissa >> 16));
    bytes[18] = uint8_t(mantissa >> 8); bytes[19] = uint8_t(mantissa);
    put32(bytes, 20, target); return bytes;
}
static bool parse(const Bytes &bytes, Update &value, uint32_t target = video) {
    return stream_guest_feedback::parse(bytes.data(), bytes.size(), remote, target, value);
}
int main() {
    Update value;
    auto report = rr();
    assert(parse(report, value) && value.rr_reports == 1 && value.remb_reports == 0);
    assert(value.fraction_lost == 64 && value.cumulative_lost == -2);
    assert(value.extended_highest_sequence == 0xfffffff0 && value.jitter_90khz == 1350);
    report[13] = 0x7f; report[14] = report[15] = 0xff;
    assert(parse(report, value) && value.cumulative_lost == 8388607);
    report[13] = 0x80; report[14] = report[15] = 0;
    assert(parse(report, value) && value.cumulative_lost == -8388608);
    assert(parse(rr(video + 1), value) && value.rr_reports == 0);
    assert(parse(rr(), value, 0) && value.rr_reports == 0);
    assert(parse(remb(), value) && value.remb_reports == 1 && value.remb_bits_per_second == 400000);
    assert(parse(remb(video, 63, 1), value) && value.remb_bits_per_second == (uint64_t(1) << 63));
    assert(!parse(remb(video, 63, 2), value));
    assert(parse(remb(video, 63, 0), value) && value.remb_bits_per_second == 0);
    assert(parse(remb(video + 1), value) && value.remb_reports == 0);
    auto aggregate = remb(); aggregate.resize(28); aggregate[3] = 6; aggregate[16] = 2;
    put32(aggregate, 24, video + 1);
    assert(parse(aggregate, value) && value.remb_reports == 0);
    aggregate[16] = 3; assert(!parse(aggregate, value));
    auto invalid = remb(); invalid[11] = 1; assert(!parse(invalid, value));
    invalid = remb(); invalid[16] = 0; assert(!parse(invalid, value));
    invalid = rr(); invalid[0] |= 32; assert(!parse(invalid, value));
    invalid = rr(); invalid[0] = 128; assert(!parse(invalid, value));
    Bytes sr(52); sr[0] = 129; sr[1] = 200; sr[3] = 12; put32(sr, 4, remote);
    auto block = rr(); std::copy(block.begin() + 8, block.end(), sr.begin() + 28);
    assert(parse(sr, value) && value.rr_reports == 1 && value.jitter_90khz == 1350);
    put32(sr, 4, remote + 1); assert(!parse(sr, value));
    auto compound = rr(); auto estimate = remb(); compound.insert(compound.end(), estimate.begin(), estimate.end());
    assert(parse(compound, value) && value.rr_reports == 1 && value.remb_reports == 1);
    // Ignored RTPFB/PSFB still require the RFC4585 common sender/media
    // header. Every malformed trailing member rejects the whole publication.
    for (auto type : {205, 206}) for (auto format : {1, 4, 15, 31}) for (auto length : {4, 8}) {
        auto tail = compound;
        Bytes member(length); member[0] = uint8_t(128 | format); member[1] = uint8_t(type); member[3] = uint8_t(length / 4 - 1);
        tail.insert(tail.end(), member.begin(), member.end());
        value.rr_reports = 987; value.remb_reports = 654; value.remb_bits_per_second = 321;
        assert(!parse(tail, value) && value.rr_reports == 987 && value.remb_reports == 654 && value.remb_bits_per_second == 321);
    }
    const auto feedback = [](uint8_t type, uint8_t format, size_t length) {
        Bytes member(length); member[0] = uint8_t(128 | format); member[1] = type; member[3] = uint8_t(length / 4 - 1);
        put32(member, 4, remote);
        if (type == 206 && format == 4) {
            // FIR identifies its target in each FCI entry, not the common media SSRC.
            for (size_t offset = 12; offset + 8 <= length; offset += 8) put32(member, offset, video);
        } else { put32(member, 8, video); }
        return member;
    };
    for (const auto &valid : {feedback(206, 1, 12), feedback(205, 1, 16), feedback(205, 1, 20), feedback(206, 4, 20), feedback(206, 4, 28)}) {
        // Reduced-size standalone feedback remains accepted and adds no
        // measured capacity or receive statistics of its own.
        assert(parse(valid, value) && value.rr_reports == 0 && value.remb_reports == 0);
        auto joined = compound; joined.insert(joined.end(), valid.begin(), valid.end());
        assert(parse(joined, value) && value.rr_reports == 1 && value.remb_reports == 1);
    }
    for (const auto &invalidMember : {feedback(205, 1, 12), feedback(206, 1, 16), feedback(206, 4, 12), feedback(206, 4, 16), feedback(206, 4, 24)}) {
        auto tail = compound; tail.insert(tail.end(), invalidMember.begin(), invalidMember.end());
        value.rr_reports = 987;
        assert(!parse(tail, value) && value.rr_reports == 987);
    }
    auto truncated = compound; truncated.pop_back(); value.rr_reports = 987;
    assert(!parse(truncated, value) && value.rr_reports == 987); // transactional
    compound.insert(compound.end(), {0, 0, 0, 0});
    assert(!parse(compound, value) && value.rr_reports == 987);
    Bytes many;
    for (unsigned i = 0; i < 32; ++i) many.insert(many.end(), {128, 202, 0, 0});
    assert(parse(many, value)); many.insert(many.end(), {128, 202, 0, 0}); assert(!parse(many, value));
    Bytes oversized(4097); assert(!parse(oversized, value));
    assert(!stream_guest_feedback::parse(nullptr, 4, remote, video, value));
    // All truncation boundaries and deterministic untrusted-wire mutations run
    // under ASan/UBSan; no network, signing, permissions or fixture SDK needed.
    auto seed = rr(); seed.insert(seed.end(), estimate.begin(), estimate.end());
    for (size_t size = 0; size < seed.size(); ++size) {
        Bytes prefix(seed.begin(), seed.begin() + size); (void)parse(prefix, value);
    }
    std::mt19937 generator(0x20261021);
    for (unsigned i = 0; i < 100000; ++i) {
        auto mutation = seed;
        for (unsigned j = 0, count = 1 + generator() % 8; j < count; ++j)
            mutation[generator() % mutation.size()] = uint8_t(generator());
        if (i & 1) mutation.resize(generator() % (seed.size() + 32));
        (void)parse(mutation, value);
    }
    std::puts("PASS: bounded atomic RTCP RR/SR report blocks and scoped REMB, signed loss, ignored feedback common/PLI/NACK/FIR bounds, generation-independent wire bounds, overflow/aggregate rejection, truncations and 100000 ASan/UBSan mutations");
}
