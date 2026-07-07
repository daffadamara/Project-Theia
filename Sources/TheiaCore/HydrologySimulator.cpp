#include "HydrologySimulator.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>
#include <queue>

namespace theia {
namespace {

struct Vec2 {
    float x = 0.0f;
    float y = 0.0f;
};

float clamp01(float v) {
    if (!std::isfinite(v)) return 0.0f;
    return std::min(1.0f, std::max(0.0f, v));
}

float length(Vec2 v) {
    return std::sqrt(v.x * v.x + v.y * v.y);
}

Vec2 normalized(Vec2 v) {
    const float len = length(v);
    if (len <= 1e-7f) return {};
    return {v.x / len, v.y / len};
}

float smoothStep(float edge0, float edge1, float x) {
    if (edge1 <= edge0) return x >= edge1 ? 1.0f : 0.0f;
    const float t = std::min(1.0f, std::max(0.0f, (x - edge0) / (edge1 - edge0)));
    return t * t * (3.0f - 2.0f * t);
}

float hashUnit(std::uint32_t seed, std::uint32_t value) {
    std::uint32_t x = value + 0x9e3779b9u + (seed << 6u) + (seed >> 2u);
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return float(x >> 8u) * (1.0f / 16777216.0f);
}

std::size_t idx(std::uint32_t x, std::uint32_t y, std::uint32_t w) {
    return std::size_t(y) * w + x;
}

struct RNG {
    std::uint32_t state = 0;

    explicit RNG(std::uint32_t seed) : state(seed ? seed : 1u) {}

    std::uint32_t nextU32() {
        // xorshift32: compact deterministic generator, sufficient for stable
        // procedural droplet spawn positions.
        std::uint32_t x = state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        state = x ? x : 0x9e3779b9u;
        return state;
    }

    float uniform() {
        return float(nextU32() >> 8) * (1.0f / 16777216.0f);
    }
};

struct Sim {
    std::uint32_t w = 0;
    std::uint32_t h = 0;
    HydrologyParams p;
    std::vector<float> sourceTerrain;
    std::vector<float> terrain;
    std::vector<float> discharge;
    std::vector<float> dischargeTrack;
    std::vector<Vec2> momentum;
    std::vector<Vec2> momentumTrack;
    RNG rng;

    Sim(const float* input, std::uint32_t width, std::uint32_t height,
        HydrologyParams params)
        : w(width), h(height), p(params), sourceTerrain(std::size_t(width) * height),
          terrain(std::size_t(width) * height),
          discharge(std::size_t(width) * height, 0.0f),
          dischargeTrack(std::size_t(width) * height, 0.0f),
          momentum(std::size_t(width) * height),
          momentumTrack(std::size_t(width) * height), rng(params.seed) {
        // Run the simulation in vertically-scaled space (heights * heightScale)
        // so per-step height drops are O(1) — matching SimpleHydrology's native
        // scale — then divide back out on output. sourceTerrain stays [0,1] for
        // the drainage/flow-accumulation pass.
        for (std::size_t i = 0; i < terrain.size(); ++i) {
            sourceTerrain[i] = clamp01(input[i]);
            terrain[i] = sourceTerrain[i] * p.heightScale;
        }
    }

    float sample(float x, float y) const {
        x = std::min(float(w - 1), std::max(0.0f, x));
        y = std::min(float(h - 1), std::max(0.0f, y));
        const std::uint32_t x0 = std::uint32_t(std::floor(x));
        const std::uint32_t y0 = std::uint32_t(std::floor(y));
        const std::uint32_t x1 = std::min(x0 + 1, w - 1);
        const std::uint32_t y1 = std::min(y0 + 1, h - 1);
        const float fx = x - float(x0);
        const float fy = y - float(y0);
        const float a = terrain[idx(x0, y0, w)];
        const float b = terrain[idx(x1, y0, w)];
        const float c = terrain[idx(x0, y1, w)];
        const float d = terrain[idx(x1, y1, w)];
        return (a * (1.0f - fx) + b * fx) * (1.0f - fy) +
               (c * (1.0f - fx) + d * fx) * fy;
    }

    Vec2 gradient(std::uint32_t x, std::uint32_t y) const {
        const std::uint32_t xl = x > 0 ? x - 1 : x;
        const std::uint32_t xr = x + 1 < w ? x + 1 : x;
        const std::uint32_t yt = y > 0 ? y - 1 : y;
        const std::uint32_t yb = y + 1 < h ? y + 1 : y;
        const float xSpan = float(std::max(1u, xr - xl));
        const float ySpan = float(std::max(1u, yb - yt));
        // terrain is already in scaled space, so no extra heightScale here.
        const float gx = (terrain[idx(xr, y, w)] - terrain[idx(xl, y, w)]) / xSpan;
        const float gy = (terrain[idx(x, yb, w)] - terrain[idx(x, yt, w)]) / ySpan;
        return {gx, gy};
    }

    Vec2 downhillNormalXZ(std::uint32_t x, std::uint32_t y) const {
        const Vec2 g = gradient(x, y);
        const float invLen = 1.0f / std::sqrt(g.x * g.x + g.y * g.y + 1.0f);
        return {-g.x * invLen, -g.y * invLen};
    }

    void cascade(std::uint32_t x, std::uint32_t y) {
        if (p.settling <= 0.0f || p.maxDiff <= 0.0f) return;
        struct Neighbor {
            std::uint32_t x;
            std::uint32_t y;
            float h;
            float dist;
        };
        Neighbor ns[8];
        int count = 0;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                if (dx == 0 && dy == 0) continue;
                const int nx = int(x) + dx;
                const int ny = int(y) + dy;
                if (nx < 0 || ny < 0 || nx >= int(w) || ny >= int(h)) continue;
                const float dist = (dx != 0 && dy != 0) ? 1.41421356f : 1.0f;
                ns[count++] = {std::uint32_t(nx), std::uint32_t(ny),
                               terrain[idx(std::uint32_t(nx), std::uint32_t(ny), w)],
                               dist};
            }
        }
        std::sort(ns, ns + count, [](const Neighbor& a, const Neighbor& b) {
            return a.h < b.h;
        });

        // In-descent talus (angle of repose). Threshold is a small fraction of
        // the vertical scale so `settling` visibly relaxes ordinary slopes, not
        // just rare extreme spikes.
        const std::size_t center = idx(x, y, w);
        const float talus = 0.0035f * p.heightScale;
        for (int i = 0; i < count; ++i) {
            const std::size_t ni = idx(ns[i].x, ns[i].y, w);
            const float diff = terrain[center] - terrain[ni];
            const float excess = std::fabs(diff) - talus * ns[i].dist;
            if (excess <= 0.0f) continue;
            const float transfer = p.settling * excess * 0.5f;
            if (diff > 0.0f) {
                terrain[center] -= transfer;
                terrain[ni] += transfer;
            } else {
                terrain[center] += transfer;
                terrain[ni] -= transfer;
            }
        }
    }

    void descend(float sx, float sy) {
        Vec2 pos{sx, sy};
        Vec2 speed{};
        float volume = 1.0f;
        float sediment = 0.0f;

        for (std::uint32_t age = 0; age < p.maxAge && volume > 0.01f; ++age) {
            const std::uint32_t x = std::min(w - 1, std::uint32_t(std::floor(pos.x)));
            const std::uint32_t y = std::min(h - 1, std::uint32_t(std::floor(pos.y)));
            const std::size_t i = idx(x, y, w);
            const Vec2 downhill = downhillNormalXZ(x, y);
            speed.x += downhill.x * p.gravity / std::max(0.05f, volume);
            speed.y += downhill.y * p.gravity / std::max(0.05f, volume);

            const Vec2 flow = momentum[i];
            const float flowLen = length(flow);
            const float speedLen0 = length(speed);
            if (flowLen > 1e-6f && speedLen0 > 1e-6f && p.momentumTransfer > 0.0f) {
                const Vec2 fd{flow.x / flowLen, flow.y / flowLen};
                const Vec2 sd{speed.x / speedLen0, speed.y / speedLen0};
                const float align = fd.x * sd.x + fd.y * sd.y;
                const float denom = std::max(0.05f, volume + discharge[i]);
                speed.x += p.momentumTransfer * align * flow.x / denom;
                speed.y += p.momentumTransfer * align * flow.y / denom;
            }

            Vec2 dir = normalized(speed);
            if (length(dir) <= 1e-7f) dir = normalized(downhill);
            if (length(dir) <= 1e-7f) {
                const float a = rng.uniform() * 6.2831853f;
                dir = {std::cos(a), std::sin(a)};
            }

            // SimpleHydrology normalizes droplet speed to a roughly diagonal
            // cell-to-cell step after forces are applied. Keeping mass transfer
            // independent from raw velocity avoids spike artifacts when users
            // raise gravity or the terrain height scale.
            speed = {dir.x * 1.41421356f, dir.y * 1.41421356f};
            const float h0 = terrain[i];
            pos.x += speed.x;
            pos.y += speed.y;

            dischargeTrack[i] += volume;
            momentumTrack[i].x += volume * speed.x;
            momentumTrack[i].y += volume * speed.y;

            bool outOfBounds = false;
            float h1 = 0.0f;
            if (pos.x < 0.0f || pos.y < 0.0f || pos.x > float(w - 1) ||
                pos.y > float(h - 1)) {
                outOfBounds = true;
                h1 = terrain[i] - 0.002f * p.heightScale;
            } else {
                h1 = sample(pos.x, pos.y);
            }

            // SimpleHydrology mass transfer: equilibrium sediment scales with
            // discharge and the step's height drop; move (capacity - carried)
            // unclamped (deposition acts as the transfer rate). Heights are in
            // scaled space so this erodes visibly.
            const float dischargeNorm = std::erf(0.4f * discharge[i]);
            const float capacity =
                std::max(0.0f, (1.0f + p.entrainment * dischargeNorm) * (h0 - h1));
            // maxDiff bounds the per-step erode/deposit transfer: one step can
            // never erupt a needle no matter how extreme deposition/entrainment
            // are. This is also what gives `maxDiff` a visible function.
            const float maxStep = std::max(1e-4f, p.maxDiff) * p.heightScale;
            float delta = p.deposition * (capacity - sediment);
            delta = std::min(maxStep, std::max(-maxStep, delta));
            sediment += delta;
            terrain[i] -= delta;
            if (!std::isfinite(sediment)) sediment = 0.0f;
            if (!std::isfinite(terrain[i])) terrain[i] = 0.0f;
            const float hLo = -0.1f * p.heightScale, hHi = 1.1f * p.heightScale;
            terrain[i] = std::min(hHi, std::max(hLo, terrain[i]));

            // Guard the mass-conservative concentration so high evaporation can't
            // blow sediment up to infinity (the source of the evap=1 spikes).
            const float keep = std::max(0.05f, 1.0f - p.evaporation);
            sediment /= keep;
            volume *= keep;

            if (outOfBounds) return;

            pos.x = std::min(float(w - 1), std::max(0.0f, pos.x));
            pos.y = std::min(float(h - 1), std::max(0.0f, pos.y));
            const std::uint32_t cx = std::min(w - 1, std::uint32_t(std::floor(pos.x)));
            const std::uint32_t cy = std::min(h - 1, std::uint32_t(std::floor(pos.y)));
            cascade(cx, cy);
        }

        const std::uint32_t x = std::min(w - 1, std::uint32_t(std::floor(pos.x)));
        const std::uint32_t y = std::min(h - 1, std::uint32_t(std::floor(pos.y)));
        const float hLo = -0.1f * p.heightScale, hHi = 1.1f * p.heightScale;
        terrain[idx(x, y, w)] =
            std::min(hHi, std::max(hLo, terrain[idx(x, y, w)] + sediment));
    }

    void blendTracks() {
        constexpr float lrate = 0.1f;
        for (std::size_t i = 0; i < discharge.size(); ++i) {
            discharge[i] = (1.0f - lrate) * discharge[i] + lrate * dischargeTrack[i];
            momentum[i].x = (1.0f - lrate) * momentum[i].x + lrate * momentumTrack[i].x;
            momentum[i].y = (1.0f - lrate) * momentum[i].y + lrate * momentumTrack[i].y;
            dischargeTrack[i] = 0.0f;
            momentumTrack[i] = {};
        }
    }

    std::vector<float> conditionedDrainageSurface(const std::vector<float>& surface) const {
        struct Cell {
            float z;
            std::size_t i;
        };
        struct Greater {
            bool operator()(const Cell& a, const Cell& b) const {
                return a.z > b.z;
            }
        };

        const std::size_t n = surface.size();
        std::vector<float> route(n, std::numeric_limits<float>::infinity());
        std::vector<std::uint8_t> visited(n, 0);
        std::priority_queue<Cell, std::vector<Cell>, Greater> open;

        auto push = [&](std::uint32_t x, std::uint32_t y, float z) {
            const std::size_t i = idx(x, y, w);
            if (visited[i]) return;
            visited[i] = 1;
            route[i] = z;
            open.push({z, i});
        };

        for (std::uint32_t x = 0; x < w; ++x) {
            push(x, 0, surface[idx(x, 0, w)]);
            push(x, h - 1, surface[idx(x, h - 1, w)]);
        }
        for (std::uint32_t y = 1; y + 1 < h; ++y) {
            push(0, y, surface[idx(0, y, w)]);
            push(w - 1, y, surface[idx(w - 1, y, w)]);
        }

        constexpr float eps = 1.0e-6f;
        while (!open.empty()) {
            const Cell c = open.top();
            open.pop();
            const std::uint32_t x = std::uint32_t(c.i % w);
            const std::uint32_t y = std::uint32_t(c.i / w);
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dx = -1; dx <= 1; ++dx) {
                    if (dx == 0 && dy == 0) continue;
                    const int nx = int(x) + dx;
                    const int ny = int(y) + dy;
                    if (nx < 0 || ny < 0 || nx >= int(w) || ny >= int(h)) continue;
                    const std::size_t ni =
                        idx(std::uint32_t(nx), std::uint32_t(ny), w);
                    if (visited[ni]) continue;
                    const float z = std::max(surface[ni], c.z + eps);
                    visited[ni] = 1;
                    route[ni] = z;
                    open.push({z, ni});
                }
            }
        }
        return route;
    }

    std::vector<std::size_t> drainageReceivers(const std::vector<float>& route) const {
        const std::size_t n = route.size();
        std::vector<std::size_t> receiver(n);
        for (std::size_t i = 0; i < n; ++i) receiver[i] = i;
        for (std::uint32_t y = 0; y < h; ++y) {
            for (std::uint32_t x = 0; x < w; ++x) {
                const std::size_t i = idx(x, y, w);
                std::size_t best = i;
                float bestSlope = 0.0f;
                for (int dy = -1; dy <= 1; ++dy) {
                    for (int dx = -1; dx <= 1; ++dx) {
                        if (dx == 0 && dy == 0) continue;
                        const int nx = int(x) + dx;
                        const int ny = int(y) + dy;
                        if (nx < 0 || ny < 0 || nx >= int(w) || ny >= int(h)) continue;
                        const float dist = (dx != 0 && dy != 0) ? 1.41421356f : 1.0f;
                        const std::size_t ni =
                            idx(std::uint32_t(nx), std::uint32_t(ny), w);
                        const float jitter =
                            (hashUnit(p.seed, std::uint32_t(i ^ (ni * 1664525u))) - 0.5f) *
                            1.0e-7f;
                        const float slope = (route[i] - route[ni] + jitter) / dist;
                        if (slope > bestSlope) {
                            bestSlope = slope;
                            best = ni;
                        }
                    }
                }
                receiver[i] = best;
            }
        }
        return receiver;
    }

    std::vector<float> flowAccumulationMask() const {
        // Gaea's Rivers/HydroFix workflow emphasizes unbroken flow paths. We
        // emulate that in Theia's single-channel graph by priority-flooding the
        // preview DEM, routing D8 flow down the conditioned surface, then
        // tracing seeded headwaters from high terrain to low outlets.
        const std::size_t n = sourceTerrain.size();
        const std::vector<float> route = conditionedDrainageSurface(sourceTerrain);
        const std::vector<std::size_t> receiver = drainageReceivers(route);
        std::vector<float> acc(n, 0.0f);
        std::vector<std::size_t> order(n);
        for (std::size_t i = 0; i < n; ++i) {
            order[i] = i;
            acc[i] = 0.15f + 0.85f * smoothStep(0.35f, 0.95f, sourceTerrain[i]);
        }
        std::sort(order.begin(), order.end(), [&](std::size_t a, std::size_t b) {
            return route[a] > route[b];
        });

        for (std::size_t oi : order) {
            if (receiver[oi] != oi) acc[receiver[oi]] += acc[oi];
        }

        std::vector<std::size_t> candidates = order;
        std::sort(candidates.begin(), candidates.end(), [&](std::size_t a, std::size_t b) {
            const float as = sourceTerrain[a] + 0.025f * hashUnit(p.seed, std::uint32_t(a));
            const float bs = sourceTerrain[b] + 0.025f * hashUnit(p.seed, std::uint32_t(b));
            return as > bs;
        });

        const std::uint32_t headwaters =
            std::max(8u, std::min<std::uint32_t>(256u, p.particles / 250u + 1u));
        const float minSep =
            std::max(3.0f, std::min(float(w), float(h)) /
                              (std::sqrt(float(headwaters)) * 1.8f));
        const float minSep2 = minSep * minSep;
        std::vector<std::size_t> selected;
        selected.reserve(headwaters);
        for (std::size_t candidate : candidates) {
            if (selected.size() >= headwaters) break;
            if (receiver[candidate] == candidate) continue;
            const std::uint32_t x = std::uint32_t(candidate % w);
            const std::uint32_t y = std::uint32_t(candidate / w);
            if (x == 0 || y == 0 || x + 1 == w || y + 1 == h) continue;
            if (sourceTerrain[candidate] < 0.48f) break;
            bool farEnough = true;
            for (std::size_t s : selected) {
                const float dx = float(int(x) - int(s % w));
                const float dy = float(int(y) - int(s / w));
                if (dx * dx + dy * dy < minSep2) {
                    farEnough = false;
                    break;
                }
            }
            if (farEnough) selected.push_back(candidate);
        }

        std::vector<float> trace(n, 0.0f);
        const std::uint32_t maxSteps = std::max<std::uint32_t>(w + h, p.maxAge * 2u);
        for (std::size_t start : selected) {
            std::size_t cur = start;
            float volume = 1.0f + sourceTerrain[start];
            for (std::uint32_t step = 0; step < maxSteps; ++step) {
                trace[cur] += volume;
                const std::size_t next = receiver[cur];
                if (next == cur) break;
                cur = next;
                volume += 0.025f;
            }
        }

        std::vector<float> accRaw(n);
        for (std::size_t i = 0; i < n; ++i) accRaw[i] = std::log1p(acc[i]);
        std::vector<float> sortedAcc = accRaw;
        std::sort(sortedAcc.begin(), sortedAcc.end());
        const float density =
            std::min(8.0f, std::max(0.25f, float(p.particles) / 8000.0f));
        const float pct =
            std::min(0.99f, std::max(0.94f, 0.975f - 0.012f * std::log2(density)));
        const std::size_t loIndex =
            std::min(sortedAcc.size() - 1,
                     std::size_t(float(sortedAcc.size() - 1) * pct));
        const float accLo = sortedAcc.empty() ? 0.0f : sortedAcc[loIndex];
        const float accHi = sortedAcc.empty() ? 1.0f :
            sortedAcc[std::min(sortedAcc.size() - 1,
                               std::size_t(float(sortedAcc.size() - 1) * 0.999f))];
        const float accSpan = std::max(1e-5f, accHi - accLo);

        std::vector<float> sortedTrace = trace;
        std::sort(sortedTrace.begin(), sortedTrace.end());
        const float traceHi = sortedTrace.empty() ? 1.0f :
            sortedTrace[std::min(sortedTrace.size() - 1,
                                 std::size_t(float(sortedTrace.size() - 1) * 0.995f))];
        const float traceScale = std::max(1e-5f, traceHi);

        std::vector<float> mask(n);
        for (std::size_t i = 0; i < n; ++i) {
            const float drainage =
                smoothStep(0.0f, 1.0f, (accRaw[i] - accLo) / accSpan);
            const float river = trace[i] > 0.0f
                ? 0.35f + 0.65f * smoothStep(0.0f, 1.0f, trace[i] / traceScale)
                : 0.0f;
            mask[i] = clamp01(std::max(drainage, river));
        }
        return mask;
    }

    void relaxNeedles() {
        if (w < 3 || h < 3) return;
        const float limit =
            std::max(0.04f, std::min(0.08f, p.maxDiff * 1.5f)) * p.heightScale;
        for (int pass = 0; pass < 2; ++pass) {
            const std::vector<float> src = terrain;
            for (std::uint32_t y = 1; y + 1 < h; ++y) {
                for (std::uint32_t x = 1; x + 1 < w; ++x) {
                    float low = std::numeric_limits<float>::infinity();
                    float high = -std::numeric_limits<float>::infinity();
                    for (int dy = -1; dy <= 1; ++dy) {
                        for (int dx = -1; dx <= 1; ++dx) {
                            if (dx == 0 && dy == 0) continue;
                            const float v =
                                src[idx(std::uint32_t(int(x) + dx),
                                        std::uint32_t(int(y) + dy), w)];
                            low = std::min(low, v);
                            high = std::max(high, v);
                        }
                    }
                    const std::size_t i = idx(x, y, w);
                    if (src[i] > high + limit) {
                        terrain[i] = high + limit;
                    } else if (src[i] < low - limit) {
                        terrain[i] = low - limit;
                    }
                }
            }
        }
    }

    void run() {
        const std::uint32_t batches =
            std::max(1u, std::min<std::uint32_t>(8u, p.particles / 512u + 1u));
        const std::uint32_t perBatch = (p.particles + batches - 1u) / batches;
        std::uint32_t emitted = 0;
        for (std::uint32_t b = 0; b < batches && emitted < p.particles; ++b) {
            const std::uint32_t count = std::min(perBatch, p.particles - emitted);
            for (std::uint32_t n = 0; n < count; ++n) {
                const std::uint32_t x =
                    std::min(w - 1, std::uint32_t(rng.uniform() * float(w)));
                const std::uint32_t y =
                    std::min(h - 1, std::uint32_t(rng.uniform() * float(h)));
                if (terrain[idx(x, y, w)] < 0.1f * p.heightScale) continue;
                descend(float(x), float(y));
            }
            emitted += count;
            blendTracks();
        }
        relaxNeedles();
        // Scale back to [0,1] for output.
        const float inv = 1.0f / std::max(1e-6f, p.heightScale);
        for (float& v : terrain) v = clamp01(v * inv);
        discharge = flowAccumulationMask();
    }
};

HydrologyParams sanitized(HydrologyParams p) {
    // Ranges chosen so even the slider extremes stay numerically stable (no
    // needles / blown-up sediment / degenerate craters).
    p.particles = std::min<std::uint32_t>(250000, std::max<std::uint32_t>(1, p.particles));
    p.maxAge = std::min<std::uint32_t>(1000, std::max<std::uint32_t>(1, p.maxAge));
    p.evaporation = std::min(0.4f, std::max(0.0f, p.evaporation));
    p.deposition = std::min(0.6f, std::max(0.0f, p.deposition));
    p.entrainment = std::min(24.0f, std::max(0.0f, p.entrainment));
    p.gravity = std::min(6.0f, std::max(0.0f, p.gravity));
    p.momentumTransfer = std::min(4.0f, std::max(0.0f, p.momentumTransfer));
    p.settling = std::min(1.0f, std::max(0.0f, p.settling));
    p.maxDiff = std::min(0.2f, std::max(0.001f, p.maxDiff));
    p.heightScale = std::min(512.0f, std::max(0.01f, p.heightScale));
    return p;
}

} // namespace

bool runHydrologySimulation(const float* input, std::uint32_t width,
                            std::uint32_t height, const HydrologyParams& params,
                            HydrologyResult& result, std::string& error) {
    if (!input || width < 2 || height < 2) {
        error = "hydrology: need at least a 2x2 input heightfield";
        return false;
    }
    const std::size_t n = std::size_t(width) * height;
    if (n > std::numeric_limits<std::uint32_t>::max()) {
        error = "hydrology: heightfield too large";
        return false;
    }

    Sim sim(input, width, height, sanitized(params));
    sim.run();
    result.terrain = std::move(sim.terrain);
    result.discharge = std::move(sim.discharge);
    return true;
}

} // namespace theia
