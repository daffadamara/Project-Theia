#pragma once
//
// Tiny 64-bit hashing helpers for content-addressed cache keys. PRIVATE header.
//
#include <cstdint>
#include <cstring>
#include <string>

namespace theia {

// boost::hash_combine-style 64-bit mixer.
inline std::uint64_t hashMix(std::uint64_t seed, std::uint64_t value) {
    seed ^= value + 0x9E3779B97F4A7C15ULL + (seed << 6) + (seed >> 2);
    return seed;
}

// FNV-1a over raw bytes, folded into an existing seed.
inline std::uint64_t hashBytes(std::uint64_t seed, const void* data, std::size_t n) {
    const auto* p = static_cast<const unsigned char*>(data);
    std::uint64_t h = seed ^ 0xCBF29CE484222325ULL;
    for (std::size_t i = 0; i < n; ++i) {
        h ^= p[i];
        h *= 0x100000001B3ULL;
    }
    return h;
}

inline std::uint64_t hashString(std::uint64_t seed, const std::string& s) {
    return hashBytes(seed, s.data(), s.size());
}

inline std::uint64_t hashDouble(std::uint64_t seed, double v) {
    std::uint64_t bits;
    std::memcpy(&bits, &v, sizeof(bits));
    return hashMix(seed, bits);
}

} // namespace theia
