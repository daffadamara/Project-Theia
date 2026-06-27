#pragma once
//
// Node — base class for graph nodes. A node has an id, a type string, a set of
// scalar parameters, some number of heightfield inputs, and produces one
// heightfield output. PRIVATE header (uses Heightfield/GPUContext internally).
//
#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace theia {

class GPUContext;
class Heightfield;

// All node parameters are scalars stored as double (cast as needed by nodes).
// Ordered map => deterministic iteration for hashing/serialization.
struct ParamSet {
    std::map<std::string, double> values;

    double get(const std::string& key, double fallback) const {
        auto it = values.find(key);
        return it == values.end() ? fallback : it->second;
    }
    void set(const std::string& key, double v) { values[key] = v; }
};

class Node {
public:
    Node(std::string id, std::string type)
        : id_(std::move(id)), type_(std::move(type)) {}
    virtual ~Node() = default;

    const std::string& id() const { return id_; }
    const std::string& type() const { return type_; }

    ParamSet params;

    // Number of heightfield inputs this node consumes (0 for generators).
    virtual std::size_t inputCount() const = 0;

    // Produce this node's output into `out` (already allocated at the graph
    // resolution). `inputs` holds inputCount() resolved upstream heightfields.
    virtual bool evaluate(GPUContext& ctx,
                          const std::vector<const Heightfield*>& inputs,
                          Heightfield& out, std::string& error) = 0;

    // Content hash of type + parameters. Basis for incremental cache keys: if a
    // param changes, this changes, which changes the node's (and descendants')
    // cache key, triggering recomputation. (Salsa/rustc-query-style memoization.)
    std::uint64_t signature() const;

private:
    std::string id_;
    std::string type_;
};

// Factory: construct a node of `type` with the given `id`, or nullptr if the
// type is unknown.
std::unique_ptr<Node> createNode(const std::string& type, const std::string& id);

// All registered node type names (for diagnostics / validation).
std::vector<std::string> registeredNodeTypes();

} // namespace theia
