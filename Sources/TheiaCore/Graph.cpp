#include "Graph.hpp"

#include <functional>

#include "Hash.hpp"
#include "Heightfield.hpp"
#include "Node.hpp"
#include "json.hpp"

using json = nlohmann::json;

namespace theia {

Graph::Graph() = default;
Graph::~Graph() = default;

Node* Graph::addNode(const std::string& id, const std::string& type,
                     std::string& error) {
    if (id.empty()) {
        error = "node id must not be empty";
        return nullptr;
    }
    if (nodes_.count(id)) {
        error = "duplicate node id: " + id;
        return nullptr;
    }
    auto n = createNode(type, id);
    if (!n) {
        error = "unknown node type: " + type;
        return nullptr;
    }
    Node* raw = n.get();
    nodes_[id] = std::move(n);
    inputs_[id].assign(raw->inputCount(), std::string{});
    return raw;
}

Node* Graph::node(const std::string& id) {
    auto it = nodes_.find(id);
    return it == nodes_.end() ? nullptr : it->second.get();
}

std::size_t Graph::nodeCount() const {
    return nodes_.size();
}

const Node* Graph::nodeAt(std::size_t index) const {
    if (index >= nodes_.size()) return nullptr;
    auto it = nodes_.begin();
    std::advance(it, index);
    return it->second.get();
}

std::size_t Graph::paramCount(const std::string& id) const {
    auto it = nodes_.find(id);
    return it == nodes_.end() ? 0 : it->second->params.values.size();
}

bool Graph::paramAt(const std::string& id, std::size_t index,
                    std::string& key, double& value) const {
    auto nit = nodes_.find(id);
    if (nit == nodes_.end() || index >= nit->second->params.values.size()) {
        return false;
    }
    auto pit = nit->second->params.values.begin();
    std::advance(pit, index);
    key = pit->first;
    value = pit->second;
    return true;
}

double Graph::paramValue(const std::string& id, const std::string& key,
                         double fallback) const {
    auto it = nodes_.find(id);
    return it == nodes_.end() ? fallback : it->second->params.get(key, fallback);
}

bool Graph::setParam(const std::string& id, const std::string& key, double value,
                     std::string& error) {
    Node* n = node(id);
    if (!n) {
        error = "no such node: " + id;
        return false;
    }
    n->params.set(key, value);
    return true;
}

bool Graph::connect(const std::string& fromId, const std::string& toId,
                    std::uint32_t inputIndex, std::string& error) {
    Node* from = node(fromId);
    Node* to = node(toId);
    if (!from) { error = "connect: no such source node: " + fromId; return false; }
    if (!to) { error = "connect: no such target node: " + toId; return false; }
    if (inputIndex >= to->inputCount()) {
        error = "connect: node '" + toId + "' has no input port " +
                std::to_string(inputIndex);
        return false;
    }
    auto& srcs = inputs_[toId];
    if (srcs.size() < to->inputCount()) srcs.resize(to->inputCount());
    srcs[inputIndex] = fromId;
    return true;
}

bool Graph::topoOrder(const std::string& sinkId, std::vector<std::string>& order,
                      std::string& error) const {
    if (!nodes_.count(sinkId)) {
        error = "sink node not found: " + sinkId;
        return false;
    }
    // 0=unvisited, 1=on-stack (gray), 2=done (black).
    std::map<std::string, int> color;
    bool ok = true;

    std::function<void(const std::string&)> dfs = [&](const std::string& id) {
        if (!ok) return;
        color[id] = 1;
        auto it = inputs_.find(id);
        if (it != inputs_.end()) {
            for (const std::string& src : it->second) {
                if (src.empty()) continue;  // unconnected port: eval will report
                if (!nodes_.count(src)) {
                    error = "node '" + id + "' references missing input '" + src + "'";
                    ok = false;
                    return;
                }
                const int c = color[src];
                if (c == 1) {
                    error = "cycle detected at node '" + src + "'";
                    ok = false;
                    return;
                }
                if (c == 0) dfs(src);
            }
        }
        color[id] = 2;
        order.push_back(id);
    };

    dfs(sinkId);
    return ok;
}

const Heightfield* Graph::evaluate(GPUContext& ctx, const std::string& sinkId,
                                   std::uint32_t w, std::uint32_t h,
                                   EvalStats& stats, std::string& error) {
    stats = {};
    if (w == 0 || h == 0) {
        error = "evaluate: resolution must be > 0";
        return nullptr;
    }
    std::vector<std::string> order;
    if (!topoOrder(sinkId, order, error)) return nullptr;

    for (const std::string& id : order) {
        Node* n = nodes_[id].get();
        const auto& srcs = inputs_[id];

        // Content-hash cache key = node signature + resolution + input keys.
        std::uint64_t key = n->signature();
        key = hashMix(key, w);
        key = hashMix(key, h);

        std::vector<const Heightfield*> ins;
        ins.reserve(n->inputCount());
        for (std::size_t p = 0; p < n->inputCount(); ++p) {
            const std::string src = (p < srcs.size()) ? srcs[p] : std::string{};
            if (src.empty()) {
                error = "node '" + id + "' input port " + std::to_string(p) +
                        " is not connected";
                return nullptr;
            }
            auto cit = cache_.find(src);
            if (cit == cache_.end() || !cit->second.output) {
                error = "internal: input '" + src + "' not evaluated before '" + id + "'";
                return nullptr;
            }
            key = hashMix(key, cit->second.key);
            ins.push_back(cit->second.output.get());
        }

        // Reuse if we have a matching, correctly-sized cached output.
        auto existing = cache_.find(id);
        if (existing != cache_.end() && existing->second.output &&
            existing->second.key == key &&
            existing->second.output->width() == w &&
            existing->second.output->height() == h) {
            stats.reused++;
            continue;
        }

        auto out = std::make_unique<Heightfield>(ctx, w, h);
        if (!out->valid()) {
            error = "failed to allocate output for node '" + id + "'";
            return nullptr;
        }
        if (!n->evaluate(ctx, ins, *out, error)) return nullptr;

        cache_[id] = CacheEntry{key, std::move(out)};
        stats.evaluated++;
    }

    return cache_[sinkId].output.get();
}

void Graph::setDefaults(const std::string& sink, std::uint32_t w, std::uint32_t h) {
    defaultSink_ = sink;
    if (w > 0) defaultWidth_ = w;
    if (h > 0) defaultHeight_ = h;
}

std::string Graph::toJSON() const {
    json j;
    j["resolution"] = {{"width", defaultWidth_}, {"height", defaultHeight_}};
    if (!defaultSink_.empty()) j["sink"] = defaultSink_;

    j["nodes"] = json::array();
    for (const auto& kv : nodes_) {
        const Node* n = kv.second.get();
        json params = json::object();
        for (const auto& pv : n->params.values) params[pv.first] = pv.second;
        j["nodes"].push_back({{"id", n->id()}, {"type", n->type()}, {"params", params}});
    }

    j["connections"] = json::array();
    for (const auto& kv : inputs_) {
        const std::string& toId = kv.first;
        const auto& srcs = kv.second;
        for (std::size_t p = 0; p < srcs.size(); ++p) {
            if (srcs[p].empty()) continue;
            j["connections"].push_back(
                {{"from", srcs[p]}, {"to", toId}, {"input", p}});
        }
    }
    return j.dump(2);
}

bool Graph::fromJSON(const std::string& text, std::string& error) {
    json j = json::parse(text, nullptr, /*allow_exceptions=*/false);
    if (j.is_discarded()) {
        error = "invalid JSON";
        return false;
    }

    Graph next;
    next.defaultWidth_ = defaultWidth_;
    next.defaultHeight_ = defaultHeight_;

    if (j.contains("resolution")) {
        const auto& r = j["resolution"];
        next.defaultWidth_ = r.value("width", next.defaultWidth_);
        next.defaultHeight_ = r.value("height", next.defaultHeight_);
    }
    next.defaultSink_ = j.value("sink", std::string{});

    if (j.contains("nodes")) {
        for (const auto& jn : j["nodes"]) {
            const std::string id = jn.value("id", std::string{});
            const std::string type = jn.value("type", std::string{});
            Node* n = next.addNode(id, type, error);
            if (!n) return false;
            if (jn.contains("params")) {
                for (auto it = jn["params"].begin(); it != jn["params"].end(); ++it) {
                    if (it.value().is_number()) {
                        n->params.set(it.key(), it.value().get<double>());
                    }
                }
            }
        }
    }

    if (j.contains("connections")) {
        for (const auto& jc : j["connections"]) {
            const std::string from = jc.value("from", std::string{});
            const std::string to = jc.value("to", std::string{});
            const std::uint32_t input = jc.value("input", 0u);
            if (!next.connect(from, to, input, error)) return false;
        }
    }

    // Preserve the cache across successful reloads: cache keys are content
    // hashes, so unchanged nodes can reuse outputs and changed subgraphs still
    // recompute. Failed reloads leave the previous graph intact.
    nodes_ = std::move(next.nodes_);
    inputs_ = std::move(next.inputs_);
    defaultSink_ = std::move(next.defaultSink_);
    defaultWidth_ = next.defaultWidth_;
    defaultHeight_ = next.defaultHeight_;

    // Drop cache entries for nodes that no longer exist.
    for (auto it = cache_.begin(); it != cache_.end();) {
        it = nodes_.count(it->first) ? std::next(it) : cache_.erase(it);
    }
    return true;
}

} // namespace theia
