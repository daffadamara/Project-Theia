#include "Theia/Theia.hpp"

#include <algorithm>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <vector>

#include "GPUContext.hpp"
#include "Graph.hpp"
#include "Heightfield.hpp"
#include "Node.hpp"
#include "io/ExportWriter.hpp"
#include "io/ImageWriter.hpp"
#include "json.hpp"

using json = nlohmann::json;

namespace theia {

namespace {
constexpr const char* kTheiaVersion = "0.9.0-alpha.1";
constexpr std::uint32_t kTheiaAPIVersion = 2;

std::size_t copyOutStr(const std::string& s, char* out, std::size_t cap) {
    if (out && cap > 0) {
        const std::size_t n = std::min(cap - 1, s.size());
        std::memcpy(out, s.data(), n);
        out[n] = '\0';
    }
    return s.size();
}

struct DiagnosticIssue {
    std::string severity;
    std::string code;
    std::string message;
    std::string node;
    std::string edge;
    std::uint32_t input = std::numeric_limits<std::uint32_t>::max();
};

void addIssue(std::vector<DiagnosticIssue>& issues,
              std::string severity,
              std::string code,
              std::string message,
              std::string node = {},
              std::uint32_t input = std::numeric_limits<std::uint32_t>::max(),
              std::string edge = {}) {
    issues.push_back(DiagnosticIssue{std::move(severity), std::move(code),
                                     std::move(message), std::move(node),
                                     std::move(edge), input});
}

bool readJsonString(const json& obj, const char* key, std::string& out) {
    if (!obj.contains(key) || !obj[key].is_string()) return false;
    out = obj[key].get<std::string>();
    return true;
}

bool readJsonU32(const json& obj, const char* key, std::uint32_t& out) {
    if (!obj.contains(key) || !obj[key].is_number_integer()) return false;
    if (obj[key].is_number_unsigned()) {
        const auto wide = obj[key].get<std::uint64_t>();
        if (wide > std::numeric_limits<std::uint32_t>::max()) return false;
        out = static_cast<std::uint32_t>(wide);
        return true;
    }
    const auto signedValue = obj[key].get<std::int64_t>();
    if (signedValue < 0 ||
        static_cast<std::uint64_t>(signedValue) > std::numeric_limits<std::uint32_t>::max()) {
        return false;
    }
    out = static_cast<std::uint32_t>(signedValue);
    return true;
}

bool isHeavySimulationNode(const std::string& type) {
    return type == "dropleterosion" || type == "hydraulic";
}

double jsonParamValue(const json& params, const char* key, double fallback) {
    if (!params.is_object() || !params.contains(key) || !params[key].is_number()) {
        return fallback;
    }
    return params[key].get<double>();
}

std::string makeDiagnosticsJSON(const std::string& text) {
    json result;
    std::vector<DiagnosticIssue> issues;
    std::map<std::string, std::string> nodeTypes;
    std::map<std::string, std::uint32_t> inputCounts;
    std::map<std::string, json> nodeParams;
    std::map<std::string, std::map<std::uint32_t, std::string>> inbound;
    std::map<std::string, std::vector<std::string>> outgoing;
    std::string sink;

    json j = json::parse(text, nullptr, /*allow_exceptions=*/false);
    if (j.is_discarded()) {
        addIssue(issues, "error", "invalid_json", "Graph JSON could not be parsed");
        result["ok"] = false;
        result["summary"] = {
            {"nodes", 0}, {"connections", 0}, {"errors", 1},
            {"warnings", 0}, {"sink", ""}
        };
        result["issues"] = json::array();
        for (const auto& issue : issues) {
            result["issues"].push_back({
                {"severity", issue.severity},
                {"code", issue.code},
                {"message", issue.message}
            });
        }
        return result.dump(2);
    }
    if (!j.is_object()) {
        addIssue(issues, "error", "invalid_shape", "Graph JSON must be an object");
    }

    if (j.is_object() && j.contains("sink")) {
        if (j["sink"].is_string()) {
            sink = j["sink"].get<std::string>();
            if (sink.empty()) {
                addIssue(issues, "warning", "empty_sink", "Graph has no active preview/output sink");
            }
        } else {
            addIssue(issues, "error", "invalid_sink", "Graph sink must be a string");
        }
    } else {
        addIssue(issues, "warning", "empty_sink", "Graph has no active preview/output sink");
    }

    if (!j.is_object() || !j.contains("nodes")) {
        addIssue(issues, "warning", "empty_graph", "Graph contains no nodes");
    } else if (!j["nodes"].is_array()) {
        addIssue(issues, "error", "invalid_nodes", "Graph nodes must be an array");
    } else {
        if (j["nodes"].empty()) {
            addIssue(issues, "warning", "empty_graph", "Graph contains no nodes");
        }
        for (const auto& nodeJson : j["nodes"]) {
            if (!nodeJson.is_object()) {
                addIssue(issues, "error", "invalid_node", "Node entries must be objects");
                continue;
            }
            std::string id;
            std::string type;
            if (!readJsonString(nodeJson, "id", id) || id.empty()) {
                addIssue(issues, "error", "invalid_node_id", "Node id must be a non-empty string");
                continue;
            }
            if (!readJsonString(nodeJson, "type", type) || type.empty()) {
                addIssue(issues, "error", "invalid_node_type",
                         "Node '" + id + "' type must be a non-empty string", id);
                continue;
            }
            if (nodeTypes.count(id)) {
                addIssue(issues, "error", "duplicate_node",
                         "Duplicate node id '" + id + "'", id);
                continue;
            }
            auto defaults = createNode(type, "__diagnostics__");
            if (!defaults) {
                addIssue(issues, "error", "unknown_node_type",
                         "Node '" + id + "' has unknown type '" + type + "'", id);
                continue;
            }
            nodeTypes[id] = type;
            inputCounts[id] = static_cast<std::uint32_t>(defaults->inputCount());
            json params = json::object();
            if (nodeJson.contains("params")) {
                if (!nodeJson["params"].is_object()) {
                    addIssue(issues, "error", "invalid_params",
                             "Node '" + id + "' params must be an object", id);
                } else {
                    params = nodeJson["params"];
                    for (auto it = params.begin(); it != params.end(); ++it) {
                        if (!it.value().is_number()) {
                            addIssue(issues, "error", "invalid_param_value",
                                     "Node '" + id + "' param '" + it.key() +
                                         "' must be numeric",
                                     id);
                        }
                    }
                }
            }
            nodeParams[id] = params;
        }
    }

    int connectionCount = 0;
    if (j.is_object() && j.contains("connections")) {
        if (!j["connections"].is_array()) {
            addIssue(issues, "error", "invalid_connections", "Graph connections must be an array");
        } else {
            for (const auto& connJson : j["connections"]) {
                if (!connJson.is_object()) {
                    addIssue(issues, "error", "invalid_connection",
                             "Connection entries must be objects");
                    continue;
                }
                std::string from;
                std::string to;
                std::uint32_t input = 0;
                const bool okFrom = readJsonString(connJson, "from", from) && !from.empty();
                const bool okTo = readJsonString(connJson, "to", to) && !to.empty();
                const bool okInput = readJsonU32(connJson, "input", input);
                const std::string edge = from + "->" + to + "." + std::to_string(input);
                if (!okFrom || !okTo || !okInput) {
                    addIssue(issues, "error", "invalid_connection",
                             "Connection requires string from/to and non-negative integer input",
                             to, input, edge);
                    continue;
                }
                ++connectionCount;
                if (!nodeTypes.count(from)) {
                    addIssue(issues, "error", "missing_source",
                             "Connection references missing source node '" + from + "'",
                             to, input, edge);
                }
                if (!nodeTypes.count(to)) {
                    addIssue(issues, "error", "missing_target",
                             "Connection references missing target node '" + to + "'",
                             to, input, edge);
                    continue;
                }
                if (input >= inputCounts[to]) {
                    addIssue(issues, "error", "invalid_input_port",
                             "Connection targets unavailable input port " +
                                 std::to_string(input) + " on node '" + to + "'",
                             to, input, edge);
                    continue;
                }
                if (inbound[to].count(input)) {
                    addIssue(issues, "warning", "duplicate_input_connection",
                             "Multiple connections target node '" + to + "' input " +
                                 std::to_string(input) + "; last connection wins",
                             to, input, edge);
                }
                inbound[to][input] = from;
                outgoing[from].push_back(to);
            }
        }
    }

    std::set<std::string> reachable;
    std::map<std::string, int> color;
    if (!sink.empty()) {
        if (!nodeTypes.count(sink)) {
            addIssue(issues, "error", "missing_sink",
                     "Sink node '" + sink + "' does not exist", sink);
        } else {
            std::function<void(const std::string&)> dfs = [&](const std::string& id) {
                color[id] = 1;
                reachable.insert(id);
                for (const auto& kv : inbound[id]) {
                    const std::string& src = kv.second;
                    if (!nodeTypes.count(src)) continue;
                    if (color[src] == 1) {
                        addIssue(issues, "error", "cycle",
                                 "Cycle detected while tracing sink dependencies at node '" +
                                     src + "'",
                                 src);
                        continue;
                    }
                    if (color[src] == 0) dfs(src);
                }
                color[id] = 2;
            };
            dfs(sink);
        }
    }

    for (const auto& kv : nodeTypes) {
        const std::string& id = kv.first;
        const std::string& type = kv.second;
        const bool sinkReachable = !sink.empty() && reachable.count(id) > 0;
        for (std::uint32_t input = 0; input < inputCounts[id]; ++input) {
            if (!inbound[id].count(input)) {
                addIssue(issues, sinkReachable ? "error" : "warning", "missing_input",
                         "Node '" + id + "' input " + std::to_string(input) +
                             " is not connected",
                         id, input);
            }
        }
        if (!sink.empty() && !sinkReachable) {
            addIssue(issues, "warning", "orphan_node",
                     "Node '" + id + "' is not upstream of the active sink", id);
        }
        if (type == "export" && !outgoing[id].empty()) {
            addIssue(issues, "warning", "export_not_terminal",
                     "Export node '" + id + "' is connected downstream; export nodes should be graph terminals",
                     id);
        }
        if (isHeavySimulationNode(type)) {
            const json params = nodeParams[id];
            if (type == "dropleterosion") {
                const double particles = jsonParamValue(params, "particles", 8000.0);
                const double maxAge = jsonParamValue(params, "maxAge", 80.0);
                if (particles >= 20000.0 || maxAge >= 220.0) {
                    addIssue(issues, "warning", "heavy_simulation",
                             "Droplet erosion node '" + id +
                                 "' may slow live preview with current particles/maxAge",
                             id);
                }
            } else if (type == "hydraulic") {
                const double iterations = jsonParamValue(params, "iterations", 80.0);
                if (iterations >= 180.0) {
                    addIssue(issues, "warning", "heavy_simulation",
                             "Hydraulic node '" + id +
                                 "' may slow live preview with current iteration count",
                             id);
                }
            }
        }
    }

    int errors = 0;
    int warnings = 0;
    for (const auto& issue : issues) {
        if (issue.severity == "error") ++errors;
        if (issue.severity == "warning") ++warnings;
    }

    result["ok"] = errors == 0;
    result["summary"] = {
        {"nodes", nodeTypes.size()},
        {"connections", connectionCount},
        {"errors", errors},
        {"warnings", warnings},
        {"sink", sink}
    };
    result["issues"] = json::array();
    for (const auto& issue : issues) {
        json item = {
            {"severity", issue.severity},
            {"code", issue.code},
            {"message", issue.message}
        };
        if (!issue.node.empty()) item["node"] = issue.node;
        if (!issue.edge.empty()) item["edge"] = issue.edge;
        if (issue.input != std::numeric_limits<std::uint32_t>::max()) {
            item["input"] = issue.input;
        }
        result["issues"].push_back(std::move(item));
    }
    return result.dump(2);
}
} // namespace

std::size_t theia_version_string(char* out, std::size_t cap) {
    return copyOutStr(kTheiaVersion, out, cap);
}

std::uint32_t theia_api_version() {
    return kTheiaAPIVersion;
}

std::size_t theia_capabilities_json(char* out, std::size_t cap) {
    json caps;
    caps["version"] = kTheiaVersion;
    caps["apiVersion"] = kTheiaAPIVersion;
    caps["swiftPM"] = true;
    caps["stableCABI"] = false;
    caps["heightmapFormats"] = {"png16", "r16", "pfm32"};
    caps["meshFormats"] = {"obj"};
    caps["commands"] = {"smoke", "demo", "run", "export", "diagnose", "nodes", "doctor", "version"};
    caps["nodes"] = registeredNodeTypes();
    const std::string text = caps.dump(2);
    return copyOutStr(text, out, cap);
}

// Concrete definition of the opaque handle from the public header. Owns the
// graph and a lazily-created GPU context.
struct GraphHandle {
    Graph graph;
    std::unique_ptr<GPUContext> ctx;  // created on first evaluate
    std::string lastError;
    GraphErrorCode lastErrorCode = GraphErrorCode::none;

    void clearError() {
        lastError.clear();
        lastErrorCode = GraphErrorCode::none;
    }

    void setError(GraphErrorCode code, std::string message) {
        lastErrorCode = code;
        lastError = std::move(message);
    }

    bool ensureGPU() {
        if (ctx) return true;
        ctx = GPUContext::create(lastError);
        if (!ctx) lastErrorCode = GraphErrorCode::evaluation;
        return ctx != nullptr;
    }
};

GraphHandle* graph_create() { return new GraphHandle(); }

void graph_destroy(GraphHandle* g) { delete g; }

bool graph_add_node(GraphHandle* g, const char* id, const char* type) {
    if (!g) return false;
    g->clearError();
    if (g->graph.addNode(id ? id : "", type ? type : "", g->lastError) == nullptr) {
        g->lastErrorCode = GraphErrorCode::validation;
        return false;
    }
    return true;
}

bool graph_set_param(GraphHandle* g, const char* id, const char* key, double value) {
    if (!g) return false;
    g->clearError();
    if (!g->graph.setParam(id ? id : "", key ? key : "", value, g->lastError)) {
        g->lastErrorCode = GraphErrorCode::validation;
        return false;
    }
    return true;
}

bool graph_connect(GraphHandle* g, const char* fromId, const char* toId,
                   std::uint32_t inputIndex) {
    if (!g) return false;
    g->clearError();
    if (!g->graph.connect(fromId ? fromId : "", toId ? toId : "", inputIndex,
                          g->lastError)) {
        g->lastErrorCode = GraphErrorCode::validation;
        return false;
    }
    return true;
}

bool graph_load_json_file(GraphHandle* g, const char* path) {
    if (!g || !path) return false;
    g->clearError();
    std::ifstream f(path);
    if (!f) {
        g->setError(GraphErrorCode::load, std::string("cannot open ") + path);
        return false;
    }
    std::stringstream ss;
    ss << f.rdbuf();
    if (!g->graph.fromJSON(ss.str(), g->lastError)) {
        g->lastErrorCode = GraphErrorCode::load;
        return false;
    }
    return true;
}

bool graph_load_json_text(GraphHandle* g, const char* text) {
    if (!g || !text) return false;
    g->clearError();
    if (!g->graph.fromJSON(text, g->lastError)) {
        g->lastErrorCode = GraphErrorCode::load;
        return false;
    }
    return true;
}

bool graph_save_json_file(GraphHandle* g, const char* path) {
    if (!g || !path) return false;
    g->clearError();
    std::ofstream f(path);
    if (!f) {
        g->setError(GraphErrorCode::exportError, std::string("cannot write ") + path);
        return false;
    }
    f << g->graph.toJSON();
    if (!f) {
        g->setError(GraphErrorCode::exportError, std::string("cannot write ") + path);
        return false;
    }
    return true;
}

std::size_t graph_diagnostics_json_text(const char* text,
                                        char* out, std::size_t cap) {
    const std::string diagnostics = makeDiagnosticsJSON(text ? text : "");
    return copyOutStr(diagnostics, out, cap);
}

GraphEvalResult graph_evaluate(GraphHandle* g, const char* sinkId,
                               std::uint32_t width, std::uint32_t height,
                               const char* pngPath, const char* pfmPath) {
    GraphEvalResult r;
    if (!g) return r;
    g->clearError();

    if (!g->ensureGPU()) {
        // lastError already set by ensureGPU.
        return r;
    }

    std::string sink = (sinkId && sinkId[0]) ? sinkId : g->graph.defaultSink();
    if (sink.empty()) {
        g->setError(GraphErrorCode::validation,
                    "no sink specified and graph has no default sink");
        return r;
    }
    const std::uint32_t w = width ? width : g->graph.defaultWidth();
    const std::uint32_t h = height ? height : g->graph.defaultHeight();

    EvalStats stats;
    const Heightfield* out =
        g->graph.evaluate(*g->ctx, sink, w, h, stats, g->lastError);
    if (!out) {
        g->lastErrorCode = GraphErrorCode::evaluation;
        return r;
    }

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
        if (!writePFM(pfmPath, out->data(), w, h, g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            return r;
        }
    }
    if (pngPath && pngPath[0]) {
        if (!writePNG16(pngPath, out->data(), w, h, mn, mx, g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            return r;
        }
    }

    r.ok = true;
    return r;
}

GraphEvalResult graph_evaluate_heights(GraphHandle* g, const char* sinkId,
                                       std::uint32_t width, std::uint32_t height,
                                       float* dst, std::size_t capElems) {
    GraphEvalResult r;
    if (!g) return r;
    g->clearError();
    if (!g->ensureGPU()) return r;

    std::string sink = (sinkId && sinkId[0]) ? sinkId : g->graph.defaultSink();
    if (sink.empty()) {
        g->setError(GraphErrorCode::validation,
                    "no sink specified and graph has no default sink");
        return r;
    }
    const std::uint32_t w = width ? width : g->graph.defaultWidth();
    const std::uint32_t h = height ? height : g->graph.defaultHeight();

    EvalStats stats;
    const Heightfield* out =
        g->graph.evaluate(*g->ctx, sink, w, h, stats, g->lastError);
    if (!out) {
        g->lastErrorCode = GraphErrorCode::evaluation;
        return r;
    }

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

GraphEvalResult graph_export(GraphHandle* g, const char* sinkId,
                             std::uint32_t width, std::uint32_t height,
                             const char* heightPngPath,
                             const char* pfmPath,
                             const char* normalPngPath,
                             const char* slopePngPath,
                             const char* maskPngPath,
                             const char* objPath,
                             float verticalScale,
                             std::uint32_t meshStride) {
    GraphEvalResult r;
    if (!g) return r;
    g->clearError();
    if (!g->ensureGPU()) return r;
    if (width == 0 || height == 0) {
        width = g->graph.defaultWidth();
        height = g->graph.defaultHeight();
    }
    if (width < 2 || height < 2) {
        g->setError(GraphErrorCode::validation, "export resolution must be at least 2x2");
        return r;
    }
    if (meshStride == 0) {
        g->setError(GraphErrorCode::validation, "mesh stride must be > 0");
        return r;
    }
    if (!(verticalScale > 0.0f)) {
        g->setError(GraphErrorCode::validation, "vertical scale must be > 0");
        return r;
    }

    const std::string sink = (sinkId && sinkId[0]) ? sinkId : g->graph.defaultSink();
    if (sink.empty()) {
        g->setError(GraphErrorCode::validation,
                    "no sink specified and graph has no default sink");
        return r;
    }

    EvalStats stats;
    const Heightfield* out =
        g->graph.evaluate(*g->ctx, sink, width, height, stats, g->lastError);
    if (!out) {
        g->lastErrorCode = GraphErrorCode::evaluation;
        return r;
    }

    r.width = width;
    r.height = height;
    r.evaluated = stats.evaluated;
    r.reused = stats.reused;
    float mn, mx;
    double mean, var;
    out->stats(mn, mx, mean, var);
    r.minHeight = mn;
    r.maxHeight = mx;
    r.mean = mean;
    r.variance = var;

    const float* data = out->data();
    if (heightPngPath && heightPngPath[0]) {
        if (!writePNG16(heightPngPath, data, width, height, mn, mx, g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            return r;
        }
    }
    if (pfmPath && pfmPath[0]) {
        if (!writePFM(pfmPath, data, width, height, g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            return r;
        }
    }
    if (normalPngPath && normalPngPath[0]) {
        if (!writeNormalPNG(normalPngPath, data, width, height, verticalScale,
                            g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            return r;
        }
    }
    if (slopePngPath && slopePngPath[0]) {
        if (!writeSlopePNG16(slopePngPath, data, width, height, verticalScale,
                             g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            return r;
        }
    }
    if (maskPngPath && maskPngPath[0]) {
        if (!writePNG16(maskPngPath, data, width, height, 0.0f, 1.0f,
                        g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            return r;
        }
    }
    if (objPath && objPath[0]) {
        if (!writeOBJ(objPath, data, width, height, verticalScale, meshStride,
                      g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            return r;
        }
    }

    r.ok = true;
    return r;
}

GraphEvalResult graph_export2(GraphHandle* g, const GraphExportOptions& options) {
    GraphEvalResult r;
    if (!g) return r;
    g->clearError();

    const bool writeHeight = options.heightmapFormat != HeightmapFormat::none;
    const bool writeMesh = options.meshFormat != MeshFormat::none;
    if (!writeHeight && !writeMesh) {
        g->setError(GraphErrorCode::validation, "choose at least one export output");
        return r;
    }
    if (options.heightmapFormat != HeightmapFormat::none &&
        options.heightmapFormat != HeightmapFormat::png16 &&
        options.heightmapFormat != HeightmapFormat::r16 &&
        options.heightmapFormat != HeightmapFormat::pfm32) {
        g->setError(GraphErrorCode::validation, "unknown heightmap format");
        return r;
    }
    if (options.meshFormat != MeshFormat::none && options.meshFormat != MeshFormat::obj) {
        g->setError(GraphErrorCode::validation, "unknown mesh format");
        return r;
    }
    if (!options.outDir || !options.outDir[0]) {
        g->setError(GraphErrorCode::validation, "export outDir is required");
        return r;
    }
    if (!options.basename || !options.basename[0]) {
        g->setError(GraphErrorCode::validation, "export basename is required");
        return r;
    }

    std::error_code ec;
    std::filesystem::create_directories(options.outDir, ec);
    if (ec) {
        g->setError(GraphErrorCode::exportError,
                    std::string("cannot create ") + options.outDir + ": " + ec.message());
        return r;
    }

    const std::filesystem::path dir(options.outDir);
    const std::string base(options.basename);
    const std::string pngPath =
        options.heightmapFormat == HeightmapFormat::png16
            ? (dir / (base + "_height.png")).string()
            : "";
    const std::string pfmPath =
        options.heightmapFormat == HeightmapFormat::pfm32
            ? (dir / (base + ".pfm")).string()
            : "";
    const std::string objPath =
        options.meshFormat == MeshFormat::obj
            ? (dir / (base + ".obj")).string()
            : "";

    r = graph_export(g, options.sinkId, options.width, options.height,
                     pngPath.c_str(), pfmPath.c_str(), "", "", "",
                     objPath.c_str(), options.verticalScale, options.meshStride);
    if (!r.ok) return r;

    if (options.heightmapFormat == HeightmapFormat::r16) {
        const std::uint32_t w = r.width;
        const std::uint32_t h = r.height;
        const std::size_t n = std::size_t(w) * h;
        std::vector<float> heights(n);
        GraphEvalResult rawEval =
            graph_evaluate_heights(g, options.sinkId, w, h, heights.data(), heights.size());
        if (!rawEval.ok) return rawEval;
        const std::string rawPath = (dir / (base + "_height.r16")).string();
        if (!writeR16(rawPath.c_str(), heights.data(), w, h,
                      rawEval.minHeight, rawEval.maxHeight, g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            GraphEvalResult failed = rawEval;
            failed.ok = false;
            return failed;
        }
    }
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

std::uint32_t graph_node_type_input_count(const char* type) {
    auto n = createNode(type ? type : "", "__defaults__");
    return n ? static_cast<std::uint32_t>(n->inputCount()) : 0;
}

std::uint32_t graph_default_param_count(const char* type) {
    auto n = createNode(type ? type : "", "__defaults__");
    return n ? static_cast<std::uint32_t>(n->params.values.size()) : 0;
}

std::size_t graph_default_param_name(const char* type, std::uint32_t index,
                                     char* out, std::size_t cap) {
    auto n = createNode(type ? type : "", "__defaults__");
    std::string key;
    if (n && index < n->params.values.size()) {
        auto it = n->params.values.begin();
        std::advance(it, index);
        key = it->first;
    }
    return copyOutStr(key, out, cap);
}

double graph_default_param_value(const char* type, const char* key,
                                 double fallback) {
    auto n = createNode(type ? type : "", "__defaults__");
    return n ? n->params.get(key ? key : "", fallback) : fallback;
}

std::size_t graph_last_error(GraphHandle* g, char* out, std::size_t cap) {
    static const std::string empty;
    return copyOutStr(g ? g->lastError : empty, out, cap);
}

GraphErrorCode graph_last_error_code(GraphHandle* g) {
    return g ? g->lastErrorCode : GraphErrorCode::none;
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
