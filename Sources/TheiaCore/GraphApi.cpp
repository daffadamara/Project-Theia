#include "Theia/Theia.hpp"

#include <algorithm>
#include <cstring>
#include <fstream>
#include <sstream>

#include "GPUContext.hpp"
#include "Graph.hpp"
#include "Heightfield.hpp"
#include "Node.hpp"
#include "io/ImageWriter.hpp"

namespace theia {

namespace {
std::size_t copyOutStr(const std::string& s, char* out, std::size_t cap) {
    if (out && cap > 0) {
        const std::size_t n = std::min(cap - 1, s.size());
        std::memcpy(out, s.data(), n);
        out[n] = '\0';
    }
    return s.size();
}
} // namespace

// Concrete definition of the opaque handle from the public header. Owns the
// graph and a lazily-created GPU context.
struct GraphHandle {
    Graph graph;
    std::unique_ptr<GPUContext> ctx;  // created on first evaluate
    std::string lastError;

    bool ensureGPU() {
        if (ctx) return true;
        ctx = GPUContext::create(lastError);
        return ctx != nullptr;
    }
};

GraphHandle* graph_create() { return new GraphHandle(); }

void graph_destroy(GraphHandle* g) { delete g; }

bool graph_add_node(GraphHandle* g, const char* id, const char* type) {
    if (!g) return false;
    return g->graph.addNode(id ? id : "", type ? type : "", g->lastError) != nullptr;
}

bool graph_set_param(GraphHandle* g, const char* id, const char* key, double value) {
    if (!g) return false;
    return g->graph.setParam(id ? id : "", key ? key : "", value, g->lastError);
}

bool graph_connect(GraphHandle* g, const char* fromId, const char* toId,
                   std::uint32_t inputIndex) {
    if (!g) return false;
    return g->graph.connect(fromId ? fromId : "", toId ? toId : "", inputIndex,
                            g->lastError);
}

bool graph_load_json_file(GraphHandle* g, const char* path) {
    if (!g || !path) return false;
    std::ifstream f(path);
    if (!f) {
        g->lastError = std::string("cannot open ") + path;
        return false;
    }
    std::stringstream ss;
    ss << f.rdbuf();
    return g->graph.fromJSON(ss.str(), g->lastError);
}

bool graph_save_json_file(GraphHandle* g, const char* path) {
    if (!g || !path) return false;
    std::ofstream f(path);
    if (!f) {
        g->lastError = std::string("cannot write ") + path;
        return false;
    }
    f << g->graph.toJSON();
    return static_cast<bool>(f);
}

GraphEvalResult graph_evaluate(GraphHandle* g, const char* sinkId,
                               std::uint32_t width, std::uint32_t height,
                               const char* pngPath, const char* pfmPath) {
    GraphEvalResult r;
    if (!g) return r;

    if (!g->ensureGPU()) {
        // lastError already set by ensureGPU.
        return r;
    }

    std::string sink = (sinkId && sinkId[0]) ? sinkId : g->graph.defaultSink();
    if (sink.empty()) {
        g->lastError = "no sink specified and graph has no default sink";
        return r;
    }
    const std::uint32_t w = width ? width : g->graph.defaultWidth();
    const std::uint32_t h = height ? height : g->graph.defaultHeight();

    EvalStats stats;
    const Heightfield* out =
        g->graph.evaluate(*g->ctx, sink, w, h, stats, g->lastError);
    if (!out) return r;

    r.width = w;
    r.height = h;
    r.evaluated = stats.evaluated;
    r.reused = stats.reused;

    float mn, mx;
    double mean, var;
    out->stats(mn, mx, mean, var);
    r.minHeight = mn;
    r.maxHeight = mx;
    r.mean = mean;
    r.variance = var;

    if (pfmPath && pfmPath[0]) {
        if (!writePFM(pfmPath, out->data(), w, h, g->lastError)) return r;
    }
    if (pngPath && pngPath[0]) {
        if (!writePNG16(pngPath, out->data(), w, h, mn, mx, g->lastError)) return r;
    }

    r.ok = true;
    return r;
}

GraphEvalResult graph_evaluate_heights(GraphHandle* g, const char* sinkId,
                                       std::uint32_t width, std::uint32_t height,
                                       float* dst, std::size_t capElems) {
    GraphEvalResult r;
    if (!g) return r;
    if (!g->ensureGPU()) return r;

    std::string sink = (sinkId && sinkId[0]) ? sinkId : g->graph.defaultSink();
    if (sink.empty()) {
        g->lastError = "no sink specified and graph has no default sink";
        return r;
    }
    const std::uint32_t w = width ? width : g->graph.defaultWidth();
    const std::uint32_t h = height ? height : g->graph.defaultHeight();

    EvalStats stats;
    const Heightfield* out =
        g->graph.evaluate(*g->ctx, sink, w, h, stats, g->lastError);
    if (!out) return r;

    r.width = w;
    r.height = h;
    r.evaluated = stats.evaluated;
    r.reused = stats.reused;
    float mn, mx;
    double mean, var;
    out->stats(mn, mx, mean, var);
    r.minHeight = mn;
    r.maxHeight = mx;
    r.mean = mean;
    r.variance = var;

    const std::size_t need = std::size_t(w) * h;
    if (dst && capElems >= need) {
        std::memcpy(dst, out->data(), need * sizeof(float));
    }
    r.ok = true;
    return r;
}

std::uint32_t graph_node_count(GraphHandle* g) {
    if (!g) return 0;
    return static_cast<std::uint32_t>(g->graph.nodeCount());
}

std::size_t graph_node_id(GraphHandle* g, std::uint32_t index,
                          char* out, std::size_t cap) {
    const Node* n = g ? g->graph.nodeAt(index) : nullptr;
    static const std::string empty;
    return copyOutStr(n ? n->id() : empty, out, cap);
}

std::size_t graph_node_type(GraphHandle* g, std::uint32_t index,
                            char* out, std::size_t cap) {
    const Node* n = g ? g->graph.nodeAt(index) : nullptr;
    static const std::string empty;
    return copyOutStr(n ? n->type() : empty, out, cap);
}

std::uint32_t graph_param_count(GraphHandle* g, const char* nodeId) {
    if (!g) return 0;
    return static_cast<std::uint32_t>(
        g->graph.paramCount(nodeId ? nodeId : ""));
}

std::size_t graph_param_name(GraphHandle* g, const char* nodeId,
                             std::uint32_t index, char* out, std::size_t cap) {
    std::string key;
    double value = 0.0;
    if (g) {
        (void)g->graph.paramAt(nodeId ? nodeId : "", index, key, value);
    }
    return copyOutStr(key, out, cap);
}

double graph_param_value(GraphHandle* g, const char* nodeId, const char* key,
                         double fallback) {
    if (!g) return fallback;
    return g->graph.paramValue(nodeId ? nodeId : "", key ? key : "", fallback);
}

std::size_t graph_last_error(GraphHandle* g, char* out, std::size_t cap) {
    static const std::string empty;
    return copyOutStr(g ? g->lastError : empty, out, cap);
}

std::size_t node_type_list(char* out, std::size_t cap) {
    std::string joined;
    for (const auto& t : registeredNodeTypes()) {
        if (!joined.empty()) joined += ", ";
        joined += t;
    }
    return copyOutStr(joined, out, cap);
}

} // namespace theia
